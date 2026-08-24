#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "lib/config"

begin
  abort "usage: config-value.rb CONFIG_PATH DOTTED_PATH [--json]" unless (2..3).cover?(ARGV.length)

  config_path, dotted_path, format = ARGV
  config = IOSBuild::Config.load_file(config_path)
  value = IOSBuild::Config.dig(config, dotted_path)

  if format == "--json" || value.is_a?(Array) || value.is_a?(Hash)
    puts JSON.generate(value)
  elsif value == true
    puts "true"
  elsif value == false
    puts "false"
  else
    puts value
  end
rescue IOSBuild::ConfigError => e
  warn e.message
  exit 1
end
