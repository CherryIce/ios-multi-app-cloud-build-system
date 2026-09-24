#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "optparse"
require "time"
require_relative "lib/asc_client"
require_relative "lib/review_status"
require_relative "lib/webhook_notifier"

options = {}
OptionParser.new do |parser|
  parser.on("--app-id ID") { |value| options[:app_id] = value }
  parser.on("--marketing-version VERSION") { |value| options[:marketing_version] = value }
  parser.on("--key-id ID") { |value| options[:key_id] = value }
  parser.on("--issuer-id ID") { |value| options[:issuer_id] = value }
  parser.on("--key-path PATH") { |value| options[:key_path] = value }
  parser.on("--output PATH") { |value| options[:output] = value }
  parser.on("--github-output PATH") { |value| options[:github_output] = value }
  parser.on("--github-summary PATH") { |value| options[:github_summary] = value }
end.parse!

def write_json(path, payload)
  FileUtils.mkdir_p(File.dirname(File.expand_path(path)), mode: 0o700)
  File.open(path, "w", 0o600) { |file| file.write(JSON.pretty_generate(payload) + "\n") }
end

def safe_output_value(value, name)
  text = value.to_s
  raise IOSBuild::ASC::ReviewStatusError, "#{name} contains a line break" if text.match?(/[\r\n]/)

  text
end

def append_github_outputs(path, summary)
  return if path.to_s.empty?

  values = {
    "app_store_version_id" => summary.fetch("app_store_version_id"),
    "marketing_version" => summary.fetch("marketing_version"),
    "app_store_version_state" => summary.fetch("app_store_version_state"),
    "status_group" => summary.fetch("status_group"),
    "attention_required" => summary.fetch("attention_required"),
    "terminal" => summary.fetch("terminal"),
    "checked_at" => summary.fetch("checked_at"),
    "notification_sent" => summary.fetch("notification_sent"),
    "status_path" => summary.fetch("status_path")
  }
  File.open(path, "a", 0o600) do |file|
    values.each do |name, value|
      file.puts "#{name}=#{safe_output_value(value, name)}"
    end
  end
end

def markdown_value(value)
  value.to_s.gsub("|", "\\|").gsub(/[\r\n]+/, " ")
end

def append_github_summary(path, summary)
  return if path.to_s.empty?

  notification = if summary["notification_sent"]
                   "sent"
                 elsif summary["notification_requested"]
                   "failed"
                 else
                   "not configured"
                 end
  File.open(path, "a", 0o600) do |file|
    file.puts "## App Store Connect review status"
    file.puts
    file.puts "| App | Version | State | Group | Notification | Checked at |"
    file.puts "|---|---|---|---|---|---|"
    file.puts "| #{markdown_value(summary['app_id'])} | #{markdown_value(summary['marketing_version'])} | " \
              "#{markdown_value(summary['app_store_version_state'])} | #{markdown_value(summary['status_group'])} | " \
              "#{markdown_value(notification)} | #{markdown_value(summary['checked_at'])} |"
  end
end

begin
  required = %i[app_id marketing_version key_id issuer_id key_path output]
  missing = required.reject { |key| options[key] && !options[key].to_s.empty? }
  abort "missing options: #{missing.join(', ')}" unless missing.empty?
  unless options.fetch(:app_id).match?(/\A[0-9]+\z/)
    raise IOSBuild::ASC::ReviewStatusError, "app-id must contain only digits"
  end
  unless options.fetch(:marketing_version).match?(/\A[0-9]+(?:\.[0-9]+){1,2}\z/)
    raise IOSBuild::ASC::ReviewStatusError, "marketing-version must contain two or three numeric components"
  end

  client = IOSBuild::ASC::Client.new(
    key_id: options.fetch(:key_id),
    issuer_id: options.fetch(:issuer_id),
    key_path: options.fetch(:key_path)
  )
  summary = IOSBuild::ASC::ReviewStatus.new(
    client: client,
    app_id: options.fetch(:app_id)
  ).query(marketing_version: options.fetch(:marketing_version))

  notification_url = ENV.fetch("ASC_NOTIFICATION_WEBHOOK_URL", "")
  notification = IOSBuild::ASC::WebhookNotifier.attempt_review_status(
    summary,
    url: notification_url,
    bearer_token: ENV.fetch("ASC_NOTIFICATION_WEBHOOK_BEARER", "")
  )
  if notification["error"]
    warn "Notification failed after successful ASC query: #{notification['error']}"
  end

  output_path = File.expand_path(options.fetch(:output))
  summary["notification_requested"] = notification.fetch("requested")
  summary["notification_sent"] = notification.fetch("sent")
  summary["notification_error"] = notification.fetch("error")
  summary["status_path"] = output_path
  write_json(output_path, summary)
  append_github_outputs(options[:github_output], summary)
  append_github_summary(options[:github_summary], summary)
  puts [
    "ASC review status",
    "app=#{summary['app_id']}",
    "version=#{summary['marketing_version']}",
    "state=#{summary['app_store_version_state']}",
    "group=#{summary['status_group']}",
    "notification_sent=#{summary['notification_sent']}"
  ].join(" ")
rescue IOSBuild::ASC::APIError, IOSBuild::ASC::ReviewStatusError,
       JSON::ParserError, KeyError,
       Errno::ENOENT, OpenSSL::PKey::PKeyError => e
  failure = {
    "schema_version" => 1,
    "source" => "manual_query",
    "app_id" => options[:app_id],
    "marketing_version" => options[:marketing_version],
    "error" => e.message,
    "checked_at" => Time.now.utc.iso8601
  }
  write_json(options[:output], failure) if options[:output]
  warn e.message
  exit 1
end
