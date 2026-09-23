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
    assert_empty snapshot["build_upload_errors"]
    assert_empty snapshot["build_upload_warnings"]
    assert_empty snapshot["build_upload_infos"]
    assert_equal "build-123", snapshot["asc_build_id"]
    assert_equal "VALID", snapshot["processing_state"]
    assert_equal "READY_FOR_BETA_TESTING", snapshot["testflight_internal_state"]
    assert_equal "builds", snapshot["observation_source"]
    assert_equal 1, snapshot["build_upload_count"]
    assert_equal 1, snapshot["build_count"]
  end

  def test_build_upload_state_remains_compatible_with_the_legacy_string_shape
    upload = { "attributes" => { "state" => "PROCESSING" } }

    assert_equal "PROCESSING", IOSBuild::ASC::State.normalized_build_upload_state(upload)
  end

  def test_app_store_version_build_is_a_strict_fallback_for_an_already_submitted_version
    snapshot = IOSBuild::ASC::State.app_store_version_build_snapshot(
      versions_response: app_store_versions_response,
      build_relationship_response: {
        "data" => { "type" => "builds", "id" => "build-101-3" }
      },
      build_response: attached_build_response(build_number: "3", marketing_version: "1.0.1"),
      marketing_version: "1.0.1",
      build_number: "3"
    )

    assert_equal "version-101", snapshot["app_store_version_id"]
    assert_equal "WAITING_FOR_REVIEW", snapshot["app_store_version_state"]
    assert_equal "build-101-3", snapshot["asc_build_id"]
    assert_equal "VALID", snapshot["processing_state"]
    assert_equal "app_store_version_build", snapshot["observation_source"]
    assert_equal "matched", snapshot["app_store_fallback_status"]
  end

  def test_app_store_version_build_fallback_rejects_a_different_build_number
    snapshot = IOSBuild::ASC::State.app_store_version_build_snapshot(
      versions_response: app_store_versions_response,
      build_relationship_response: {
        "data" => { "type" => "builds", "id" => "build-101-4" }
      },
      build_response: attached_build_response(build_number: "4", marketing_version: "1.0.1", id: "build-101-4"),
      marketing_version: "1.0.1",
      build_number: "3"
    )

    assert_nil snapshot["asc_build_id"]
    assert_equal "WAITING_FOR_REVIEW", snapshot["app_store_version_state"]
    assert_equal "build_number_mismatch", snapshot["app_store_fallback_status"]
  end

  def test_app_store_version_build_fallback_rejects_a_different_marketing_version
    snapshot = IOSBuild::ASC::State.app_store_version_build_snapshot(
      versions_response: app_store_versions_response,
      build_relationship_response: {
        "data" => { "type" => "builds", "id" => "build-101-3" }
      },
      build_response: attached_build_response(build_number: "3", marketing_version: "1.0.2"),
      marketing_version: "1.0.1",
      build_number: "3"
    )

    assert_nil snapshot["asc_build_id"]
    assert_equal "marketing_version_mismatch", snapshot["app_store_fallback_status"]
  end

  def test_processing_complete_does_not_depend_on_a_lagging_build_upload_record
    snapshot = {
      "build_upload_id" => nil,
      "build_upload_state" => nil,
      "asc_build_id" => "build-101-3",
      "processing_state" => "VALID"
    }

    assert IOSBuild::ASC::State.wait_satisfied?(snapshot, "asc_appeared")
    assert IOSBuild::ASC::State.wait_satisfied?(snapshot, "processing_complete")
  end

  def test_processing_complete_rejects_a_build_that_is_still_processing
    snapshot = {
      "asc_build_id" => "build-101-3",
      "processing_state" => "PROCESSING"
    }

    refute IOSBuild::ASC::State.wait_satisfied?(snapshot, "processing_complete")
  end

  private

  def app_store_versions_response
    {
      "data" => [
        {
          "type" => "appStoreVersions",
          "id" => "version-101",
          "attributes" => {
            "versionString" => "1.0.1",
            "platform" => "IOS",
            "appVersionState" => "WAITING_FOR_REVIEW"
          }
        }
      ]
    }
  end

  def attached_build_response(build_number:, marketing_version:, id: "build-101-3")
    {
      "data" => {
        "type" => "builds",
        "id" => id,
        "attributes" => {
          "version" => build_number,
          "processingState" => "VALID"
        },
        "relationships" => {
          "preReleaseVersion" => {
            "data" => { "type" => "preReleaseVersions", "id" => "prerelease-101" }
          }
        }
      },
      "included" => [
        {
          "type" => "preReleaseVersions",
          "id" => "prerelease-101",
          "attributes" => { "version" => marketing_version, "platform" => "IOS" }
        }
      ]
    }
  end

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
