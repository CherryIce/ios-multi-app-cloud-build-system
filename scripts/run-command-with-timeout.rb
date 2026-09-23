#!/usr/bin/env ruby
# frozen_string_literal: true

require "open3"
require "optparse"

options = { append: false, grace_seconds: 10 }
OptionParser.new do |parser|
  parser.on("--timeout-seconds SECONDS", Integer) { |value| options[:timeout_seconds] = value }
  parser.on("--grace-seconds SECONDS", Integer) { |value| options[:grace_seconds] = value }
  parser.on("--log PATH") { |value| options[:log] = value }
  parser.on("--append") { options[:append] = true }
end.parse!

abort "timeout-seconds must be positive" unless options[:timeout_seconds].to_i.positive?
abort "grace-seconds must be positive" unless options[:grace_seconds].to_i.positive?
abort "log is required" if options[:log].to_s.empty?
abort "command is required" if ARGV.empty?

def signal_process_group(signal, pid)
  Process.kill(signal, -pid)
rescue Errno::ESRCH
  nil
end

timed_out = false
exit_status = nil
mode = options.fetch(:append) ? "a" : "w"

File.open(options.fetch(:log), mode, 0o600) do |log|
  Open3.popen2e(*ARGV, pgroup: true) do |stdin, output, wait_thread|
    stdin.close
    reader = Thread.new do
      loop do
        chunk = output.readpartial(16 * 1024)
        STDOUT.write(chunk)
        STDOUT.flush
        log.write(chunk)
        log.flush
      end
    rescue EOFError
      nil
    end

    unless wait_thread.join(options.fetch(:timeout_seconds))
      timed_out = true
      warn "Command timed out after #{options.fetch(:timeout_seconds)} seconds; sending TERM"
      signal_process_group("TERM", wait_thread.pid)
      unless wait_thread.join(options.fetch(:grace_seconds))
        warn "Command did not stop after #{options.fetch(:grace_seconds)} seconds; sending KILL"
        signal_process_group("KILL", wait_thread.pid)
        wait_thread.join
      end
    end

    reader.value
    exit_status = wait_thread.value.exitstatus
  end
end

exit 124 if timed_out
exit(exit_status || 1)
