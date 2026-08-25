#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "open3"
require "optparse"
require "pathname"
require "time"
require_relative "lib/config"

options = {}
OptionParser.new do |parser|
  parser.on("--config PATH") { |value| options[:config] = value }
  parser.on("--marketing-version VERSION") { |value| options[:marketing_version] = value }
  parser.on("--build-number NUMBER") { |value| options[:build_number] = value }
  parser.on("--upload-to-asc BOOLEAN") { |value| options[:upload_to_asc] = value }
  parser.on("--metadata PATH") { |value| options[:metadata] = value }
  parser.on("--github-output PATH") { |value| options[:github_output] = value }
end.parse!

def fail_with(message)
  warn "preflight failed: #{message}"
  exit 1
end

def repository_path(workspace_real, relative_path, label, allow_workspace: false)
  candidate = File.expand_path(relative_path, workspace_real)
  resolved = File.realpath(candidate)
  contained = resolved.start_with?(workspace_real + File::SEPARATOR)
  contained ||= allow_workspace && resolved == workspace_real
  fail_with("#{label} must remain inside GITHUB_WORKSPACE") unless contained
  resolved
end

begin
  required_options = %i[config marketing_version upload_to_asc metadata github_output]
  missing = required_options.reject { |key| options.key?(key) && !options[key].to_s.empty? }
  abort "missing options: #{missing.join(', ')}" unless missing.empty?

  workspace = ENV.fetch("GITHUB_WORKSPACE", Dir.pwd)
  workspace_real = File.realpath(workspace)
  requested_config = options.fetch(:config)
  config_path = Pathname.new(requested_config)
  has_control_character = ["\0", "\n", "\r"].any? { |character| requested_config.include?(character) }
  if config_path.absolute? || requested_config.start_with?("~") || has_control_character ||
     config_path.each_filename.any? { |component| component == ".." } || config_path.cleanpath.to_s != requested_config
    fail_with("configuration path must be a normalized repository-relative path")
  end
  config_real = repository_path(workspace_real, requested_config, "configuration path")

  config = IOSBuild::Config.load_file(config_real)

  event_name = ENV.fetch("GITHUB_EVENT_NAME", "")
  allowed_events = IOSBuild::Config.dig(config, "release.allowed_events")
  fail_with("event #{event_name.inspect} is not allowed") unless allowed_events.include?(event_name)

  source_ref = ENV.fetch("GITHUB_REF", "")
  patterns = IOSBuild::Config.dig(config, "release.allowed_ref_patterns")
  ref_allowed = patterns.any? { |pattern| File.fnmatch(pattern, source_ref, File::FNM_PATHNAME) }
  fail_with("ref #{source_ref.inspect} is not allowed") unless ref_allowed

  source_sha = ENV.fetch("GITHUB_SHA", "")
  fail_with("GITHUB_SHA is missing") unless source_sha.match?(/\A[0-9a-f]{40}\z/)
  head_sha, git_status = Open3.capture2("git", "-C", workspace_real, "rev-parse", "HEAD")
  fail_with("unable to resolve workspace HEAD") unless git_status.success?
  fail_with("workspace HEAD does not match GITHUB_SHA") unless head_sha.strip == source_sha

  marketing_version = options.fetch(:marketing_version)
  unless marketing_version.match?(/\A(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\z/)
    fail_with("marketing version must contain three dot-separated non-negative integers")
  end

  build_number = options.fetch(:build_number, "").to_s
  unless build_number.empty? || build_number.match?(/\A[1-9]\d*\z/)
    fail_with("build number override must be a positive integer")
  end
  if !build_number.empty? && !IOSBuild::Config.dig(config, "versioning.build_number_override_allowed")
    fail_with("build number override is disabled by configuration")
  end

  upload_to_asc = options.fetch(:upload_to_asc)
  fail_with("upload_to_asc must be true or false") unless %w[true false].include?(upload_to_asc)

  project_directory = IOSBuild::Config.dig(config, "flutter.project_directory")
  project_real = repository_path(workspace_real, project_directory, "Flutter project directory", allow_workspace: true)
  fail_with("Flutter project directory is not a directory") unless File.directory?(project_real)
  fail_with("Flutter project must contain pubspec.yaml") unless File.file?(File.join(project_real, "pubspec.yaml"))
  fail_with("Flutter project must contain pubspec.lock") unless File.file?(File.join(project_real, "pubspec.lock"))

  container_path = IOSBuild::Config.dig(config, "build.container_path")
  container_real = repository_path(workspace_real, container_path, "build container path")
  unless container_real.start_with?(project_real + File::SEPARATOR)
    fail_with("build container path must remain inside the Flutter project directory")
  end

  xcode_path = IOSBuild::Config.dig(config, "build.xcode_path")
  fail_with("configured Xcode does not exist: #{xcode_path}") unless File.directory?(xcode_path)

  metadata = {
    "repository" => ENV.fetch("GITHUB_REPOSITORY", ""),
    "workflow" => ENV.fetch("GITHUB_WORKFLOW", ""),
    "run_id" => ENV.fetch("GITHUB_RUN_ID", ""),
    "run_attempt" => ENV.fetch("GITHUB_RUN_ATTEMPT", ""),
    "run_url" => [ENV["GITHUB_SERVER_URL"], ENV["GITHUB_REPOSITORY"], "actions/runs", ENV["GITHUB_RUN_ID"]].compact.join("/"),
    "actor" => ENV.fetch("GITHUB_ACTOR", ""),
    "event_name" => event_name,
    "source_ref" => source_ref,
    "source_sha" => source_sha,
    "marketing_version" => marketing_version,
    "requested_build_number" => build_number,
    "upload_to_asc" => upload_to_asc == "true",
    "flutter" => {
      "project_directory" => project_directory,
      "version" => IOSBuild::Config.dig(config, "flutter.version"),
      "channel" => IOSBuild::Config.dig(config, "flutter.channel"),
      "architecture" => IOSBuild::Config.dig(config, "flutter.architecture")
    },
    "created_at" => Time.now.utc.iso8601
  }

  File.open(options.fetch(:metadata), "w", 0o600) do |file|
    file.write(JSON.pretty_generate(metadata) + "\n")
  end
  File.open(options.fetch(:github_output), "a", 0o600) do |output|
    output.puts "config_path=#{config_real}"
    output.puts "marketing_version=#{marketing_version}"
    output.puts "requested_build_number=#{build_number}"
    output.puts "upload_to_asc=#{upload_to_asc}"
    output.puts "source_sha=#{source_sha}"
    output.puts "flutter_project_directory=#{project_directory}"
    output.puts "flutter_version=#{IOSBuild::Config.dig(config, 'flutter.version')}"
    output.puts "flutter_architecture=#{IOSBuild::Config.dig(config, 'flutter.architecture')}"
    output.puts "build_number_strategy=#{IOSBuild::Config.dig(config, 'versioning.build_number_strategy')}"
    output.puts "retention_days=#{IOSBuild::Config.dig(config, 'artifacts.retention_days')}"
  end

  puts "Preflight passed for #{source_ref} at #{source_sha}"
rescue Errno::ENOENT, IOSBuild::ConfigError, KeyError => e
  fail_with(e.message)
end
