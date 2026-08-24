#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "optparse"
require_relative "lib/config"

options = {}
OptionParser.new do |parser|
  parser.on("--config PATH") { |value| options[:config] = value }
  parser.on("--ipa PATH") { |value| options[:ipa] = value }
  parser.on("--work-dir PATH") { |value| options[:work_dir] = value }
  parser.on("--marketing-version VERSION") { |value| options[:marketing_version] = value }
  parser.on("--build-number NUMBER") { |value| options[:build_number] = value }
  parser.on("--output PATH") { |value| options[:output] = value }
end.parse!

def command!(*command)
  stdout, stderr, status = Open3.capture3(*command)
  raise IOSBuild::ConfigError, "command failed: #{command.first}: #{stderr.strip}" unless status.success?

  [stdout, stderr]
end

def plist_json(path)
  converter = File.join(__dir__, "plist-to-json.py")
  stdout, = command!("python3", converter, path)
  JSON.parse(stdout)
end

begin
  missing = %i[config ipa work_dir marketing_version build_number output].reject { |key| options[key] && !options[key].empty? }
  abort "missing options: #{missing.join(', ')}" unless missing.empty?

  config = IOSBuild::Config.load_file(options.fetch(:config))
  inspection_dir = File.join(options.fetch(:work_dir), "ipa-inspection")
  FileUtils.rm_rf(inspection_dir)
  FileUtils.mkdir_p(inspection_dir, mode: 0o700)
  command!("/usr/bin/unzip", "-q", options.fetch(:ipa), "-d", inspection_dir)

  primary_apps = Dir.glob(File.join(inspection_dir, "Payload", "*.app"))
  raise IOSBuild::ConfigError, "IPA must contain exactly one primary app" unless primary_apps.length == 1

  bundles = (
    Dir.glob(File.join(inspection_dir, "Payload", "**", "*.app")) +
    Dir.glob(File.join(inspection_dir, "Payload", "**", "*.appex"))
  ).uniq.sort
  expected_ids = IOSBuild::Config.dig(config, "app.bundle_ids").map { |entry| entry.fetch("bundle_id") }.sort
  primary_id = IOSBuild::Config.dig(config, "app.primary_bundle_id")
  team_id = IOSBuild::Config.dig(config, "app.team_id")
  inspected = []

  bundles.each do |bundle_path|
    info = plist_json(File.join(bundle_path, "Info.plist"))
    bundle_id = info.fetch("CFBundleIdentifier")
    marketing_version = info.fetch("CFBundleShortVersionString")
    build_number = info.fetch("CFBundleVersion")
    raise IOSBuild::ConfigError, "unexpected bundle in IPA: #{bundle_id}" unless expected_ids.include?(bundle_id)
    raise IOSBuild::ConfigError, "wrong marketing version for #{bundle_id}" unless marketing_version == options.fetch(:marketing_version)
    raise IOSBuild::ConfigError, "wrong build number for #{bundle_id}" unless build_number == options.fetch(:build_number)

    command!("/usr/bin/codesign", "--verify", "--deep", "--strict", "--verbose=4", bundle_path)
    _stdout, signature = command!("/usr/bin/codesign", "-dv", "--verbose=4", bundle_path)
    signature_team = signature[/^TeamIdentifier=(.+)$/, 1]
    raise IOSBuild::ConfigError, "wrong signing team for #{bundle_id}" unless signature_team == team_id

    embedded_profile = File.join(bundle_path, "embedded.mobileprovision")
    raise IOSBuild::ConfigError, "missing embedded profile for #{bundle_id}" unless File.file?(embedded_profile)
    profile_plist = File.join(inspection_dir, "#{bundle_id}.profile.plist")
    stdout, = command!("/usr/bin/security", "cms", "-D", "-i", embedded_profile)
    File.write(profile_plist, stdout)
    profile = plist_json(profile_plist)
    application_identifier = profile.dig("Entitlements", "application-identifier").to_s
    expected_application_identifier = "#{team_id}.#{bundle_id}"
    unless application_identifier == expected_application_identifier
      raise IOSBuild::ConfigError, "embedded profile does not match #{bundle_id}"
    end

    inspected << {
      "bundle_id" => bundle_id,
      "marketing_version" => marketing_version,
      "build_number" => build_number,
      "team_id" => signature_team,
      "profile_uuid" => profile["UUID"]
    }
  end

  actual_ids = inspected.map { |item| item.fetch("bundle_id") }.sort
  raise IOSBuild::ConfigError, "IPA bundle set differs from configuration" unless actual_ids == expected_ids
  primary_info = plist_json(File.join(primary_apps.first, "Info.plist"))
  raise IOSBuild::ConfigError, "primary app bundle ID is incorrect" unless primary_info["CFBundleIdentifier"] == primary_id

  summary = {
    "primary_bundle_id" => primary_id,
    "marketing_version" => options.fetch(:marketing_version),
    "build_number" => options.fetch(:build_number),
    "bundles" => inspected
  }
  File.open(options.fetch(:output), "w", 0o600) { |file| file.write(JSON.pretty_generate(summary) + "\n") }
  puts "IPA inspection passed for #{inspected.length} bundles"
rescue IOSBuild::ConfigError, JSON::ParserError, KeyError, Errno::ENOENT => e
  warn e.message
  exit 1
end
