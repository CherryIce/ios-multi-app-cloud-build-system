#!/usr/bin/env ruby
# frozen_string_literal: true

require "cgi"
require "json"
require "optparse"
require_relative "lib/config"

options = {}
OptionParser.new do |parser|
  parser.on("--config PATH") { |value| options[:config] = value }
  parser.on("--profile-map PATH") { |value| options[:profile_map] = value }
  parser.on("--identity SHA1") { |value| options[:identity] = value }
  parser.on("--output PATH") { |value| options[:output] = value }
end.parse!

begin
  missing = %i[config profile_map identity output].reject { |key| options[key] && !options[key].empty? }
  abort "missing options: #{missing.join(', ')}" unless missing.empty?
  abort "identity must be a SHA-1 fingerprint" unless options.fetch(:identity).match?(/\A[0-9A-Fa-f]{40}\z/)

  config = IOSBuild::Config.load_file(options.fetch(:config))
  profiles = JSON.parse(File.read(options.fetch(:profile_map)))
  expected = IOSBuild::Config.dig(config, "app.bundle_ids").map { |entry| entry.fetch("bundle_id") }
  missing_profiles = expected - profiles.keys
  raise IOSBuild::ConfigError, "profile map is missing: #{missing_profiles.join(', ')}" unless missing_profiles.empty?

  escape = ->(value) { CGI.escapeHTML(value.to_s) }
  provisioning_rows = expected.sort.map do |bundle_id|
    "    <key>#{escape.call(bundle_id)}</key>\n    <string>#{escape.call(profiles.fetch(bundle_id).fetch("name"))}</string>"
  end.join("\n")
  bool_tag = ->(value) { value ? "<true/>" : "<false/>" }

  plist = <<~PLIST
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>method</key>
      <string>#{escape.call(IOSBuild::Config.dig(config, "export.method"))}</string>
      <key>destination</key>
      <string>export</string>
      <key>signingStyle</key>
      <string>manual</string>
      <key>teamID</key>
      <string>#{escape.call(IOSBuild::Config.dig(config, "app.team_id"))}</string>
      <key>signingCertificate</key>
      <string>#{escape.call(options.fetch(:identity).upcase)}</string>
      <key>manageAppVersionAndBuildNumber</key>
      <false/>
      <key>provisioningProfiles</key>
      <dict>
    #{provisioning_rows}
      </dict>
      <key>uploadSymbols</key>
      #{bool_tag.call(IOSBuild::Config.dig(config, "export.upload_symbols"))}
      <key>stripSwiftSymbols</key>
      #{bool_tag.call(IOSBuild::Config.dig(config, "export.strip_swift_symbols"))}
    </dict>
    </plist>
  PLIST

  File.open(options.fetch(:output), "w", 0o600) { |file| file.write(plist) }
  puts "Generated ExportOptions.plist"
rescue IOSBuild::ConfigError, JSON::ParserError, KeyError, Errno::ENOENT => e
  warn e.message
  exit 1
end
