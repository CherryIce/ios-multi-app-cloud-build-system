# frozen_string_literal: true

require "base64"
require "cgi"
require "minitest/autorun"
require "open3"
require "openssl"
require "tmpdir"

class SigningContractTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  CONFIG = File.join(__dir__, "fixtures/config/valid.yml")
  MAPPER = File.join(ROOT, "scripts/map-profiles.rb")

  def test_profiles_must_include_the_imported_distribution_certificate
    skip "macOS plutil is required" unless File.executable?("/usr/bin/plutil")

    Dir.mktmpdir do |directory|
      certificate = make_certificate("expected")
      other_certificate = make_certificate("other")
      certificate_path = File.join(directory, "distribution.pem")
      File.write(certificate_path, certificate.to_pem)
      profiles = [
        write_profile(directory, certificate, "com.example.app", "11111111-1111-1111-1111-111111111111"),
        write_profile(directory, certificate, "com.example.app.widget", "22222222-2222-2222-2222-222222222222")
      ]
      output_path = File.join(directory, "profile-map.json")

      stdout, stderr, status = run_mapper(certificate_path, profiles, output_path)
      assert status.success?, [stdout, stderr].join("\n")
      assert File.file?(output_path)

      File.write(certificate_path, other_certificate.to_pem)
      _stdout, stderr, status = run_mapper(certificate_path, profiles, output_path)
      refute status.success?
      assert_includes stderr, "does not include the imported distribution certificate"
    end
  end

  private

  def make_certificate(common_name)
    key = OpenSSL::PKey::RSA.new(2048)
    certificate = OpenSSL::X509::Certificate.new
    certificate.version = 2
    certificate.serial = rand(1..1_000_000)
    certificate.subject = OpenSSL::X509::Name.parse("/CN=#{common_name}")
    certificate.issuer = certificate.subject
    certificate.public_key = key.public_key
    certificate.not_before = Time.now - 60
    certificate.not_after = Time.now + 3600
    certificate.sign(key, OpenSSL::Digest::SHA256.new)
    certificate
  end

  def write_profile(directory, certificate, bundle_id, uuid)
    path = File.join(directory, "#{bundle_id}.plist")
    certificate_data = Base64.strict_encode64(certificate.to_der)
    escaped_path = CGI.escapeHTML(File.join(directory, "#{bundle_id}.mobileprovision"))
    File.write(path, <<~PLIST)
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0"><dict>
        <key>Name</key><string>#{bundle_id}</string>
        <key>UUID</key><string>#{uuid}</string>
        <key>ExpirationDate</key><date>2099-01-01T00:00:00Z</date>
        <key>TeamIdentifier</key><array><string>ABCDE12345</string></array>
        <key>Platform</key><array><string>iOS</string></array>
        <key>DeveloperCertificates</key><array><data>#{certificate_data}</data></array>
        <key>Entitlements</key><dict>
          <key>application-identifier</key><string>ABCDE12345.#{bundle_id}</string>
          <key>get-task-allow</key><false/>
        </dict>
        <key>_source_path</key><string>#{escaped_path}</string>
      </dict></plist>
    PLIST
    path
  end

  def run_mapper(certificate_path, profiles, output_path)
    command = [
      "ruby", MAPPER,
      "--config", CONFIG,
      "--certificate", certificate_path,
      "--output", output_path
    ]
    profiles.each { |profile| command.concat(["--plist", profile]) }
    Open3.capture3(*command)
  end
end
