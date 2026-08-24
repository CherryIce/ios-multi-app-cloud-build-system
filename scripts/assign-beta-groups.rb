#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "optparse"
require_relative "lib/asc_client"
require_relative "lib/config"

options = {}
OptionParser.new do |parser|
  parser.on("--config PATH") { |value| options[:config] = value }
  parser.on("--status PATH") { |value| options[:status] = value }
  parser.on("--key-id ID") { |value| options[:key_id] = value }
  parser.on("--issuer-id ID") { |value| options[:issuer_id] = value }
  parser.on("--key-path PATH") { |value| options[:key_path] = value }
end.parse!

begin
  missing = %i[config status key_id issuer_id key_path].reject { |key| options[key] && !options[key].empty? }
  abort "missing options: #{missing.join(', ')}" unless missing.empty?

  config = IOSBuild::Config.load_file(options.fetch(:config))
  groups = IOSBuild::Config.dig(config, "upload.internal_beta_group_ids")
  exit 0 if groups.empty?

  status = JSON.parse(File.read(options.fetch(:status)))
  build_id = status.fetch("asc_build_id")
  raise IOSBuild::ConfigError, "ASC build ID is unavailable for beta group assignment" if build_id.to_s.empty?
  unless %w[READY_FOR_BETA_TESTING IN_BETA_TESTING].include?(status["testflight_internal_state"])
    raise IOSBuild::ConfigError, "build is not ready for internal beta group assignment"
  end

  client = IOSBuild::ASC::Client.new(
    key_id: options.fetch(:key_id),
    issuer_id: options.fetch(:issuer_id),
    key_path: options.fetch(:key_path)
  )
  groups.each do |group_id|
    relationship_path = "/v1/betaGroups/#{group_id}/relationships/builds"
    existing = client.paginate(relationship_path, { "limit" => "200" })
    next if existing.any? { |item| item["id"] == build_id }

    client.post(
      relationship_path,
      { "data" => [{ "type" => "builds", "id" => build_id }] }
    )
    relationship = client.paginate(relationship_path, { "limit" => "200" })
    unless relationship.any? { |item| item["id"] == build_id }
      raise IOSBuild::ConfigError, "failed to verify beta group assignment for #{group_id}"
    end
  end
  puts "Assigned build to #{groups.length} internal beta groups"
rescue IOSBuild::ASC::APIError, IOSBuild::ConfigError, JSON::ParserError, KeyError, Errno::ENOENT => e
  warn e.message
  exit 1
end
