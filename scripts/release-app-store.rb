#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "optparse"
require "pathname"
require "time"
require_relative "lib/app_store_release"
require_relative "lib/asc_client"
require_relative "lib/config"

options = {}
OptionParser.new do |parser|
  parser.on("--config PATH") { |value| options[:config] = value }
  parser.on("--phase PHASE") { |value| options[:phase] = value }
  parser.on("--marketing-version VERSION") { |value| options[:marketing_version] = value }
  parser.on("--status PATH") { |value| options[:status] = value }
  parser.on("--key-id ID") { |value| options[:key_id] = value }
  parser.on("--issuer-id ID") { |value| options[:issuer_id] = value }
  parser.on("--key-path PATH") { |value| options[:key_path] = value }
  parser.on("--submit-to-review BOOLEAN") { |value| options[:submit_to_review] = value }
  parser.on("--output PATH") { |value| options[:output] = value }
  parser.on("--github-output PATH") { |value| options[:github_output] = value }
end.parse!

def resolve_workspace_file(workspace, relative_path, label)
  requested = Pathname.new(relative_path)
  invalid = requested.absolute? || relative_path.start_with?("~") ||
            ["\0", "\n", "\r"].any? { |character| relative_path.include?(character) } ||
            requested.each_filename.any? { |component| component == ".." } ||
            requested.cleanpath.to_s != relative_path
  raise IOSBuild::ConfigError, "#{label} must be a normalized repository-relative path" if invalid

  workspace_real = File.realpath(workspace)
  resolved = File.realpath(File.expand_path(relative_path, workspace_real))
  unless resolved.start_with?(workspace_real + File::SEPARATOR)
    raise IOSBuild::ConfigError, "#{label} must remain inside GITHUB_WORKSPACE"
  end
  resolved
end

def write_summary(path, summary)
  File.open(path, "w", 0o600) { |file| file.write(JSON.pretty_generate(summary) + "\n") }
end

begin
  required = %i[
    config phase marketing_version key_id issuer_id key_path submit_to_review output github_output
  ]
  missing = required.reject { |key| options[key] && !options[key].to_s.empty? }
  abort "missing options: #{missing.join(', ')}" unless missing.empty?
  unless %w[true false].include?(options.fetch(:submit_to_review))
    abort "submit-to-review must be true or false"
  end
  unless %w[prepare finalize].include?(options.fetch(:phase))
    abort "phase must be prepare or finalize"
  end

  config = IOSBuild::Config.load_file(options.fetch(:config))
  unless IOSBuild::Config.optional_dig(config, "app_store.enabled", false)
    abort "App Store release is disabled in configuration"
  end

  status = {}
  if options.fetch(:phase) == "finalize"
    abort "status is required for the finalize phase" if options[:status].to_s.empty?
    status = JSON.parse(File.read(options.fetch(:status)))
    build_id = status["asc_build_id"]
    raise IOSBuild::ASC::ReleaseError, "ASC build ID is unavailable" if build_id.to_s.empty?
    build_number = status["build_number"]
    raise IOSBuild::ASC::ReleaseError, "ASC build number is unavailable" if build_number.to_s.empty?
    unless status["processing_state"] == "VALID"
      raise IOSBuild::ASC::ReleaseError, "ASC build is not processing-complete and VALID"
    end
    unless status["marketing_version"] == options.fetch(:marketing_version)
      raise IOSBuild::ASC::ReleaseError, "ASC status marketing version does not match the requested version"
    end
  end

  workspace = ENV.fetch("GITHUB_WORKSPACE", Dir.pwd)
  metadata_path = resolve_workspace_file(
    workspace,
    IOSBuild::Config.dig(config, "app_store.metadata_path"),
    "app_store.metadata_path"
  )
  metadata = IOSBuild::ASC::AppStoreMetadata.load_file(metadata_path)
  client = IOSBuild::ASC::Client.new(
    key_id: options.fetch(:key_id),
    issuer_id: options.fetch(:issuer_id),
    key_path: options.fetch(:key_path)
  )
  release = IOSBuild::ASC::AppStoreRelease.new(
    client: client,
    app_id: IOSBuild::Config.dig(config, "app.asc_app_id"),
    marketing_version: options.fetch(:marketing_version),
    build_id: status["asc_build_id"],
    build_number: status["build_number"],
    metadata: metadata,
    automatic_release: IOSBuild::Config.dig(config, "app_store.automatic_release"),
    submit_to_review: options.fetch(:submit_to_review) == "true",
    demo_account_name: ENV.fetch("ASC_REVIEW_DEMO_ACCOUNT_NAME", ""),
    demo_account_password: ENV.fetch("ASC_REVIEW_DEMO_ACCOUNT_PASSWORD", "")
  )
  summary = (options.fetch(:phase) == "prepare" ? release.prepare : release.execute).merge(
    "phase" => options.fetch(:phase),
    "checked_at" => Time.now.utc.iso8601
  )
  write_summary(options.fetch(:output), summary)

  File.open(options.fetch(:github_output), "a", 0o600) do |output|
    output.puts "app_store_version_id=#{summary['app_store_version_id']}"
    output.puts "app_store_version_state=#{summary['app_store_version_state']}"
    output.puts "review_submission_id=#{summary['review_submission_id']}"
    output.puts "review_submission_state=#{summary['review_submission_state']}"
    output.puts "review_submitted=#{summary['review_submitted']}"
    output.puts "app_store_no_op=#{summary['no_op']}"
    output.puts "app_store_no_op_reason=#{summary['no_op_reason']}"
    output.puts "app_store_already_submitted=#{summary['already_submitted']}"
    output.puts "app_store_already_released=#{summary['already_released']}"
  end

  puts [
    "App Store release",
    "phase=#{summary['phase']}",
    "version=#{summary['marketing_version']}",
    "state=#{summary['app_store_version_state']}",
    "submitted=#{summary['review_submitted']}",
    "no_op=#{summary['no_op']}",
    "no_op_reason=#{summary['no_op_reason'] || 'none'}",
    "submission_state=#{summary['review_submission_state'] || 'not-submitted'}"
  ].join(" ")
rescue IOSBuild::ASC::APIError, IOSBuild::ASC::ReleaseError, IOSBuild::ASC::MetadataError,
       IOSBuild::ConfigError, JSON::ParserError, KeyError, Errno::ENOENT, OpenSSL::PKey::PKeyError => e
  failure = {
    "marketing_version" => options[:marketing_version],
    "review_submitted" => false,
    "error" => e.message,
    "checked_at" => Time.now.utc.iso8601
  }
  write_summary(options[:output], failure) if options[:output]
  warn e.message
  exit 1
end
