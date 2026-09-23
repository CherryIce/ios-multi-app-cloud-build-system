#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "optparse"
require "time"
require_relative "lib/asc_client"
require_relative "lib/asc_state"

options = {}
OptionParser.new do |parser|
  parser.on("--app-id ID") { |value| options[:app_id] = value }
  parser.on("--marketing-version VERSION") { |value| options[:marketing_version] = value }
  parser.on("--build-number NUMBER") { |value| options[:build_number] = value }
  parser.on("--key-id ID") { |value| options[:key_id] = value }
  parser.on("--issuer-id ID") { |value| options[:issuer_id] = value }
  parser.on("--key-path PATH") { |value| options[:key_path] = value }
  parser.on("--wait-level LEVEL") { |value| options[:wait_level] = value }
  parser.on("--timeout-minutes MINUTES", Integer) { |value| options[:timeout_minutes] = value }
  parser.on("--poll-seconds SECONDS", Integer) { |value| options[:poll_seconds] = value }
  parser.on("--output PATH") { |value| options[:output] = value }
  parser.on("--github-output PATH") { |value| options[:github_output] = value }
end.parse!

def write_summary(path, summary)
  File.open(path, "w", 0o600) { |file| file.write(JSON.pretty_generate(summary) + "\n") }
end

begin
  required = %i[
    app_id marketing_version build_number key_id issuer_id key_path wait_level
    timeout_minutes poll_seconds output github_output
  ]
  missing = required.reject { |key| options[key] && options[key].to_s != "" }
  abort "missing options: #{missing.join(', ')}" unless missing.empty?

  allowed_levels = %w[upload_accepted asc_appeared processing_complete testflight_internal_ready]
  abort "invalid wait level" unless allowed_levels.include?(options.fetch(:wait_level))

  summary = {
    "app_id" => options.fetch(:app_id),
    "marketing_version" => options.fetch(:marketing_version),
    "build_number" => options.fetch(:build_number),
    "upload_accepted" => true,
    "asc_build_id" => nil,
    "build_upload_id" => nil,
    "build_upload_state" => nil,
    "build_upload_errors" => [],
    "build_upload_warnings" => [],
    "build_upload_infos" => [],
    "processing_state" => nil,
    "testflight_internal_state" => nil,
    "observation_source" => nil,
    "app_store_version_id" => nil,
    "app_store_version_state" => nil,
    "app_store_attached_build_id" => nil,
    "app_store_fallback_status" => nil,
    "app_store_fallback_error" => nil,
    "poll_attempt" => 0,
    "elapsed_seconds" => 0,
    "last_api_error" => nil,
    "checked_at" => Time.now.utc.iso8601
  }

  if options.fetch(:wait_level) == "upload_accepted"
    write_summary(options.fetch(:output), summary)
  else
    client = IOSBuild::ASC::Client.new(
      key_id: options.fetch(:key_id),
      issuer_id: options.fetch(:issuer_id),
      key_path: options.fetch(:key_path)
    )
    started_at = Time.now
    deadline = started_at + (options.fetch(:timeout_minutes) * 60)
    last_error = nil
    poll_attempt = 0

    loop do
      poll_attempt += 1
      begin
        uploads_response = client.get(
          "/v1/apps/#{options.fetch(:app_id)}/buildUploads",
          {
            "filter[cfBundleShortVersionString]" => options.fetch(:marketing_version),
            "filter[cfBundleVersion]" => options.fetch(:build_number),
            "filter[platform]" => "IOS",
            "include" => "build",
            "limit" => "200"
          }
        )
        builds_response = client.get(
          "/v1/builds",
          {
            "filter[app]" => options.fetch(:app_id),
            "filter[version]" => options.fetch(:build_number),
            "include" => "preReleaseVersion,buildBetaDetail",
            "limit" => "200"
          }
        )
        summary.merge!(
          IOSBuild::ASC::State.snapshot(
            uploads_response: uploads_response,
            builds_response: builds_response,
            marketing_version: options.fetch(:marketing_version)
          )
        )
        %w[
          app_store_version_id app_store_version_state app_store_attached_build_id
          app_store_fallback_status app_store_fallback_error app_store_version_count
        ].each { |key| summary[key] = nil }

        needs_app_store_fallback = !summary["asc_build_id"] &&
          (!summary["build_upload_id"] || options.fetch(:wait_level) != "asc_appeared")
        if needs_app_store_fallback
          begin
            versions_response = client.get(
              "/v1/apps/#{options.fetch(:app_id)}/appStoreVersions",
              {
                "filter[versionString]" => options.fetch(:marketing_version),
                "filter[platform]" => "IOS",
                "limit" => "200"
              }
            )
            version = IOSBuild::ASC::State.exact_app_store_version(
              versions_response,
              options.fetch(:marketing_version)
            )
            relationship_response = version ? client.get(
              "/v1/appStoreVersions/#{version.fetch('id')}/relationships/build"
            ) : {}
            attached_build_id = relationship_response.dig("data", "id")
            attached_build_response = attached_build_id ? client.get(
              "/v1/builds/#{attached_build_id}",
              { "include" => "preReleaseVersion,buildBetaDetail" }
            ) : {}
            summary.merge!(
              IOSBuild::ASC::State.app_store_version_build_snapshot(
                versions_response: versions_response,
                build_relationship_response: relationship_response,
                build_response: attached_build_response,
                marketing_version: options.fetch(:marketing_version),
                build_number: options.fetch(:build_number)
              )
            )
            summary["app_store_fallback_error"] = nil
          rescue IOSBuild::ASC::APIError => e
            raise unless [403, 404].include?(e.status)

            summary["app_store_fallback_status"] = "unavailable_http_#{e.status}"
            summary["app_store_fallback_error"] = e.message
            warn "ASC App Store fallback unavailable: #{e.message}"
          end
        end

        summary["poll_attempt"] = poll_attempt
        summary["elapsed_seconds"] = (Time.now - started_at).round
        summary["last_api_error"] = nil
        summary["checked_at"] = Time.now.utc.iso8601
        write_summary(options.fetch(:output), summary)
        puts [
          "ASC status",
          "attempt=#{summary['poll_attempt']}",
          "elapsed=#{summary['elapsed_seconds']}s",
          "uploads=#{summary['build_upload_count'] || 0}",
          "builds=#{summary['build_count'] || 0}",
          "versions=#{summary['app_store_version_count'] || 'not-queried'}",
          "upload=#{summary['build_upload_state'] || 'not-found'}",
          "processing=#{summary['processing_state'] || 'not-found'}",
          "testflight=#{summary['testflight_internal_state'] || 'not-found'}",
          "app_store=#{summary['app_store_version_state'] || 'not-found'}",
          "source=#{summary['observation_source'] || 'not-found'}",
          "fallback=#{summary['app_store_fallback_status'] || 'not-used'}"
        ].join(" ")

        failure_states = %w[FAILED INVALID PROCESSING_EXCEPTION]
        observed_states = [
          summary["build_upload_state"],
          summary["processing_state"],
          summary["testflight_internal_state"]
        ].compact
        failed_state = observed_states.find { |state| failure_states.include?(state) }
        raise IOSBuild::ASC::APIError, "Apple processing failed with state #{failed_state}" if failed_state

        success = IOSBuild::ASC::State.wait_satisfied?(summary, options.fetch(:wait_level))
        break if success
        last_error = nil
      rescue IOSBuild::ASC::APIError => e
        raise unless e.status == 429 || (e.status && e.status >= 500)

        last_error = e.message
        summary["poll_attempt"] = poll_attempt
        summary["elapsed_seconds"] = (Time.now - started_at).round
        summary["last_api_error"] = last_error
        summary["checked_at"] = Time.now.utc.iso8601
        write_summary(options.fetch(:output), summary)
        warn "Transient ASC error: #{e.message}"
      end

      if Time.now >= deadline
        detail = last_error ? " (last API error: #{last_error})" : ""
        warn "Timed out waiting for #{options.fetch(:wait_level)}#{detail}"
        exit 2
      end
      sleep options.fetch(:poll_seconds)
    end
  end

  File.open(options.fetch(:github_output), "a", 0o600) do |output|
    output.puts "asc_build_id=#{summary['asc_build_id']}"
    output.puts "asc_upload_state=#{summary['build_upload_state']}"
    output.puts "asc_processing_state=#{summary['processing_state']}"
    output.puts "testflight_internal_state=#{summary['testflight_internal_state']}"
  end
rescue IOSBuild::ASC::APIError, JSON::ParserError, KeyError, Errno::ENOENT, OpenSSL::PKey::PKeyError => e
  warn e.message
  exit 1
end
