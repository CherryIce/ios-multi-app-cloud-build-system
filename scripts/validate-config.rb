#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "lib/config"

begin
  abort "usage: validate-config.rb CONFIG_PATH" unless ARGV.length == 1

  IOSBuild::Config.load_file(ARGV.fetch(0))
  puts "configuration is valid"
rescue IOSBuild::ConfigError => e
  warn e.message
  exit 1
end
