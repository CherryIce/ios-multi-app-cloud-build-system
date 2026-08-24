#!/usr/bin/env ruby
# frozen_string_literal: true

require "optparse"
require_relative "lib/asc_client"

options = {}
OptionParser.new do |parser|
  parser.on("--app-id ID") { |value| options[:app_id] = value }
  parser.on("--marketing-version VERSION") { |value| options[:marketing_version] = value }
  parser.on("--key-id ID") { |value| options[:key_id] = value }
  parser.on("--issuer-id ID") { |value| options[:issuer_id] = value }
  parser.on("--key-path PATH") { |value| options[:key_path] = value }
end.parse!

begin
  missing = %i[app_id marketing_version key_id issuer_id key_path].reject { |key| options[key] && !options[key].empty? }
  abort "missing options: #{missing.join(', ')}" unless missing.empty?

  client = IOSBuild::ASC::Client.new(
    key_id: options.fetch(:key_id),
    issuer_id: options.fetch(:issuer_id),
    key_path: options.fetch(:key_path)
  )

  numbers = []
  uploads = client.paginate(
    "/v1/apps/#{options.fetch(:app_id)}/buildUploads",
    {
      "filter[cfBundleShortVersionString]" => options.fetch(:marketing_version),
      "filter[platform]" => "IOS",
      "limit" => "200"
    }
  )
  numbers.concat(uploads.map { |upload| upload.dig("attributes", "cfBundleVersion") }.compact)

  prereleases = client.paginate(
    "/v1/preReleaseVersions",
    {
      "filter[app]" => options.fetch(:app_id),
      "filter[version]" => options.fetch(:marketing_version),
      "filter[platform]" => "IOS",
      "limit" => "200"
    }
  )
  prereleases.each do |prerelease|
    builds = client.paginate(
      "/v1/builds",
      {
        "filter[preReleaseVersion]" => prerelease.fetch("id"),
        "limit" => "200"
      }
    )
    numbers.concat(builds.map { |build| build.dig("attributes", "version") }.compact)
  end

  numeric = numbers.map { |value| Integer(value, 10) if value.to_s.match?(/\A[1-9]\d*\z/) }.compact
  puts((numeric.max || 0) + 1)
rescue IOSBuild::ASC::APIError, KeyError, Errno::ENOENT, OpenSSL::PKey::PKeyError => e
  warn e.message
  exit 1
end
