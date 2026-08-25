#!/usr/bin/env ruby
# frozen_string_literal: true

require "openssl"

abort "usage: verify-code-signing-identity.rb CERTIFICATE" unless ARGV.length == 1

begin
  certificate = OpenSSL::X509::Certificate.new(File.binread(ARGV.fetch(0)))
  expected_fingerprint = OpenSSL::Digest::SHA1.hexdigest(certificate.to_der).upcase
  valid_fingerprints = STDIN.read.scan(/\b[0-9A-Fa-f]{40}\b/).map(&:upcase)

  abort "Imported certificate is not available as a valid code-signing identity" unless valid_fingerprints.include?(expected_fingerprint)

  puts "Imported certificate is available as a valid code-signing identity"
rescue Errno::ENOENT, OpenSSL::X509::CertificateError => e
  warn e.message
  exit 1
end
