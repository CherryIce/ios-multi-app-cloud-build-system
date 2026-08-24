#!/usr/bin/env ruby
# frozen_string_literal: true

require "base64"
require "json"
require "openssl"
require "open3"
require "optparse"
require "time"
require_relative "lib/config"

options = { plists: [] }
OptionParser.new do |parser|
  parser.on("--config PATH") { |value| options[:config] = value }
  parser.on("--certificate PATH") { |value| options[:certificate] = value }
  parser.on("--output PATH") { |value| options[:output] = value }
  parser.on("--plist PATH") { |value| options[:plists] << value }
end.parse!

def plist_json(path)
  converter = File.join(__dir__, "plist-to-json.py")
  stdout, stderr, status = Open3.capture3("python3", converter, path)
  raise IOSBuild::ConfigError, "unable to parse profile plist #{path}: #{stderr.strip}" unless status.success?

  JSON.parse(stdout)
end

begin
  missing = %i[config certificate output].reject { |key| options[key] && !options[key].empty? }
  abort "missing options: #{missing.join(', ')}" unless missing.empty?
  abort "at least one --plist is required" if options[:plists].empty?

  config = IOSBuild::Config.load_file(options.fetch(:config))
  team_id = IOSBuild::Config.dig(config, "app.team_id")
  signing_certificate = OpenSSL::X509::Certificate.new(File.binread(options.fetch(:certificate))).to_der
  expected = IOSBuild::Config.dig(config, "app.bundle_ids").map { |entry| entry.fetch("bundle_id") }
  profiles = {}

  options.fetch(:plists).each do |plist_path|
    profile = plist_json(plist_path)
    name = profile["Name"].to_s
    uuid = profile["UUID"].to_s
    expiration = Time.parse(profile.fetch("ExpirationDate"))
    profile_team = Array(profile["TeamIdentifier"]).first.to_s
    entitlements = profile.fetch("Entitlements", {})
    platforms = Array(profile["Platform"])
    developer_certificates = Array(profile["DeveloperCertificates"]).map { |certificate| Base64.strict_decode64(certificate) }
    application_identifier = entitlements["application-identifier"].to_s
    matched_bundle = expected.find { |bundle_id| application_identifier == "#{team_id}.#{bundle_id}" }

    raise IOSBuild::ConfigError, "profile #{name.inspect} has invalid UUID" unless uuid.match?(/\A[0-9A-Fa-f-]{36}\z/)
    raise IOSBuild::ConfigError, "profile #{name.inspect} is expired" unless expiration > Time.now
    raise IOSBuild::ConfigError, "profile #{name.inspect} has wrong TeamIdentifier" unless profile_team == team_id
    raise IOSBuild::ConfigError, "profile #{name.inspect} does not support iOS" unless platforms.include?("iOS")
    unless developer_certificates.include?(signing_certificate)
      raise IOSBuild::ConfigError, "profile #{name.inspect} does not include the imported distribution certificate"
    end
    raise IOSBuild::ConfigError, "profile #{name.inspect} does not match a configured bundle ID" unless matched_bundle
    if profile.key?("ProvisionedDevices") || profile["ProvisionsAllDevices"] == true || entitlements["get-task-allow"] == true
      raise IOSBuild::ConfigError, "profile #{name.inspect} is not an App Store distribution profile"
    end
    raise IOSBuild::ConfigError, "multiple profiles match #{matched_bundle}" if profiles.key?(matched_bundle)

    profiles[matched_bundle] = {
      "name" => name,
      "uuid" => uuid,
      "source_path" => profile.fetch("_source_path")
    }
  end

  missing_bundles = expected - profiles.keys
  raise IOSBuild::ConfigError, "missing profiles for: #{missing_bundles.join(', ')}" unless missing_bundles.empty?

  File.open(options.fetch(:output), "w", 0o600) do |file|
    file.write(JSON.pretty_generate(profiles) + "\n")
  end
  puts "Mapped #{profiles.length} provisioning profiles"
rescue IOSBuild::ConfigError, JSON::ParserError, KeyError, ArgumentError, OpenSSL::X509::CertificateError => e
  warn e.message
  exit 1
end
