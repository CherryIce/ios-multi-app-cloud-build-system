#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "optparse"
require "yaml"
require_relative "lib/app_resolver"
require_relative "lib/asc_client"
require_relative "lib/config"

options = {}
OptionParser.new do |parser|
  parser.on("--config PATH") { |value| options[:config] = value }
  parser.on("--upload-to-asc BOOLEAN") { |value| options[:upload_to_asc] = value }
  parser.on("--key-id ID") { |value| options[:key_id] = value }
  parser.on("--issuer-id ID") { |value| options[:issuer_id] = value }
  parser.on("--key-path PATH") { |value| options[:key_path] = value }
  parser.on("--output PATH") { |value| options[:output] = value }
  parser.on("--github-output PATH") { |value| options[:github_output] = value }
end.parse!

begin
  required = %i[config upload_to_asc output github_output]
  missing = required.reject { |key| options[key] && !options[key].to_s.empty? }
  abort "missing options: #{missing.join(', ')}" unless missing.empty?
  unless %w[true false].include?(options.fetch(:upload_to_asc))
    abort "upload-to-asc must be true or false"
  end

  config = IOSBuild::Config.load_file(options.fetch(:config))
  app_id = IOSBuild::Config.dig(config, "app.asc_app_id")

  if options.fetch(:upload_to_asc) == "true"
    credentials = %i[key_id issuer_id key_path]
    missing_credentials = credentials.reject { |key| options[key] && !options[key].to_s.empty? }
    abort "missing ASC credentials: #{missing_credentials.join(', ')}" unless missing_credentials.empty?

    client = IOSBuild::ASC::Client.new(
      key_id: options.fetch(:key_id),
      issuer_id: options.fetch(:issuer_id),
      key_path: options.fetch(:key_path)
    )
    resolver = IOSBuild::ASC::AppResolver.new(client: client)
    app_id = resolver.resolve(
      bundle_id: IOSBuild::Config.dig(config, "app.primary_bundle_id"),
      configured_id: app_id
    )
    config.fetch("app")["asc_app_id"] = app_id
  end

  output_path = File.expand_path(options.fetch(:output))
  FileUtils.mkdir_p(File.dirname(output_path), mode: 0o700)
  File.open(output_path, "w", 0o600) { |file| file.write(YAML.dump(config)) }

  File.open(options.fetch(:github_output), "a", 0o600) do |output|
    output.puts "config_path=#{output_path}"
    output.puts "asc_app_id=#{app_id}"
  end
  puts "ASC app configuration prepared for #{IOSBuild::Config.dig(config, 'app.primary_bundle_id')}"
rescue IOSBuild::ASC::APIError, IOSBuild::ASC::AppResolutionError, IOSBuild::ConfigError,
       KeyError, Errno::ENOENT, OpenSSL::PKey::PKeyError => e
  warn e.message
  exit 1
end
