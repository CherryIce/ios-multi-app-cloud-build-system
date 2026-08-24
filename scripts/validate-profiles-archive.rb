#!/usr/bin/env ruby
# frozen_string_literal: true

require "pathname"
require "rubygems/package"
require "zlib"

abort "usage: validate-profiles-archive.rb ARCHIVE" unless ARGV.length == 1

begin
  archive_path = ARGV.fetch(0)
  file_count = 0
  total_size = 0

  Zlib::GzipReader.open(archive_path) do |gzip|
    Gem::Package::TarReader.new(gzip) do |tar|
      tar.each do |entry|
        name = entry.full_name
        path = Pathname.new(name)
        if path.absolute? || path.each_filename.any? { |component| component == ".." } || name.include?("\0")
          abort "unsafe archive member: #{name.inspect}"
        end
        next if entry.directory?

        abort "archive links and special files are not allowed: #{name.inspect}" unless entry.file?
        abort "archive contains a non-mobileprovision file: #{name.inspect}" unless name.end_with?(".mobileprovision")

        file_count += 1
        total_size += entry.header.size
        abort "profile archive contains more than 64 files" if file_count > 64
        abort "profile archive expands beyond 10 MiB" if total_size > 10 * 1024 * 1024
      end
    end
  end

  abort "profile archive contains no .mobileprovision files" if file_count.zero?

  puts "profile archive is safe (#{file_count} profiles)"
rescue Errno::ENOENT, Zlib::GzipFile::Error, Gem::Package::TarInvalidError => e
  warn e.message
  exit 1
end
