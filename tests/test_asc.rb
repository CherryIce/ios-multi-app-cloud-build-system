# frozen_string_literal: true

require "base64"
require "json"
require "minitest/autorun"
require "openssl"
require "tempfile"
require_relative "../scripts/lib/asc_client"
require_relative "../scripts/lib/asc_state"

class ASCTest < Minitest::Test
  def test_es256_token_has_expected_claims_and_verifiable_signature
    key = OpenSSL::PKey::EC.generate("prime256v1")
    Tempfile.create(["AuthKey_TEST123456", ".p8"]) do |file|
      file.write(key.to_pem)
      file.flush
      token = IOSBuild::ASC::Token.new(
        key_id: "TEST123456",
        issuer_id: "11111111-2222-3333-4444-555555555555",
        key_path: file.path
      ).generate(now: 1_800_000_000, lifetime: 600)

      encoded_header, encoded_payload, encoded_signature = token.split(".")
      header = JSON.parse(Base64.urlsafe_decode64(pad(encoded_header)))
      payload = JSON.parse(Base64.urlsafe_decode64(pad(encoded_payload)))
      raw_signature = Base64.urlsafe_decode64(pad(encoded_signature))

      assert_equal "ES256", header["alg"]
      assert_equal "TEST123456", header["kid"]
      assert_equal "appstoreconnect-v1", payload["aud"]
      assert_equal 64, raw_signature.bytesize
      assert key.dsa_verify_asn1(
        OpenSSL::Digest::SHA256.digest([encoded_header, encoded_payload].join(".")),
        raw_to_der(raw_signature)
      )
    end
  end

  def test_state_snapshot_selects_exact_marketing_version
    fixtures = File.join(__dir__, "fixtures/asc")
    snapshot = IOSBuild::ASC::State.snapshot(
      uploads_response: JSON.parse(File.read(File.join(fixtures, "build-uploads.json"))),
      builds_response: JSON.parse(File.read(File.join(fixtures, "builds.json"))),
      marketing_version: "2.3.0"
    )

    assert_equal "upload-123", snapshot["build_upload_id"]
    assert_equal "COMPLETE", snapshot["build_upload_state"]
    assert_equal "build-123", snapshot["asc_build_id"]
    assert_equal "VALID", snapshot["processing_state"]
    assert_equal "READY_FOR_BETA_TESTING", snapshot["testflight_internal_state"]
  end

  private

  def pad(value)
    value + ("=" * ((4 - value.length % 4) % 4))
  end

  def raw_to_der(raw)
    r = OpenSSL::BN.new(raw.byteslice(0, 32), 2)
    s = OpenSSL::BN.new(raw.byteslice(32, 32), 2)
    OpenSSL::ASN1::Sequence([
      OpenSSL::ASN1::Integer(r),
      OpenSSL::ASN1::Integer(s)
    ]).to_der
  end
end
