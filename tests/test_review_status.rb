# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "time"
require_relative "../scripts/lib/review_status"
require_relative "../scripts/lib/webhook_notifier"

class ReviewStatusTest < Minitest::Test
  FakeResponse = Struct.new(:code)

  class FakeClient
    attr_reader :requests

    def initialize(records)
      @records = records
      @requests = []
    end

    def paginate(path, query)
      @requests << [path, query]
      @records
    end
  end

  def test_queries_an_exact_ios_version_and_classifies_review_state
    client = FakeClient.new([
      app_store_version(id: "ios-version", version: "2.3.0", platform: "IOS", state: "IN_REVIEW"),
      app_store_version(id: "mac-version", version: "2.3.0", platform: "MAC_OS", state: "READY_FOR_REVIEW")
    ])
    status = IOSBuild::ASC::ReviewStatus.new(client: client, app_id: "1234567890").query(
      marketing_version: "2.3.0",
      now: Time.parse("2026-09-24T01:02:03Z")
    )

    assert_equal "ios-version", status["app_store_version_id"]
    assert_equal "IN_REVIEW", status["app_store_version_state"]
    assert_equal "in_review", status["status_group"]
    refute status["attention_required"]
    refute status["terminal"]
    assert_equal "2026-09-24T01:02:03Z", status["checked_at"]
    assert_equal [
      "/v1/apps/1234567890/appStoreVersions",
      {
        "filter[versionString]" => "2.3.0",
        "filter[platform]" => "IOS",
        "limit" => "200"
      }
    ], client.requests.fetch(0)
  end

  def test_rejected_state_requires_attention_and_is_terminal
    client = FakeClient.new([
      app_store_version(id: "version-1", version: "1.0.0", platform: "IOS", state: "REJECTED")
    ])
    status = IOSBuild::ASC::ReviewStatus.new(client: client, app_id: "123").query(
      marketing_version: "1.0.0"
    )

    assert_equal "attention_required", status["status_group"]
    assert status["attention_required"]
    refute status["terminal"]
  end

  def test_missing_exact_version_fails_instead_of_reporting_another_version
    client = FakeClient.new([
      app_store_version(id: "version-2", version: "2.0.0", platform: "IOS", state: "IN_REVIEW")
    ])

    error = assert_raises(IOSBuild::ASC::ReviewStatusError) do
      IOSBuild::ASC::ReviewStatus.new(client: client, app_id: "123").query(marketing_version: "1.0.0")
    end
    assert_includes error.message, "was not found"
  end

  def test_notification_payload_and_bearer_header_do_not_mix_secrets_into_body
    captured = nil
    notifier = IOSBuild::ASC::WebhookNotifier.new(
      url: "https://notify.example.test/asc",
      bearer_token: "secret-token",
      transport: lambda do |_uri, request|
        captured = request
        FakeResponse.new("204")
      end
    )
    summary = {
      "app_id" => "123",
      "app_store_version_id" => "version-1",
      "marketing_version" => "1.2.3",
      "app_store_version_state" => "WAITING_FOR_REVIEW",
      "status_group" => "review_queue",
      "attention_required" => false,
      "terminal" => false,
      "checked_at" => "2026-09-24T01:02:03Z"
    }

    result = notifier.deliver(IOSBuild::ASC::WebhookNotifier.review_status_payload(summary))
    body = JSON.parse(captured.body)

    assert_equal 204, result["status_code"]
    assert_equal "Bearer secret-token", captured["Authorization"]
    assert_equal "WAITING_FOR_REVIEW", body["new_state"]
    assert_equal "manual_query", body["source"]
    assert_equal "review_queue", body["status_group"]
    assert_equal false, body["terminal"]
    assert_equal body["timestamp"], body["received_at"]
    refute_includes captured.body, "secret-token"
  end

  def test_notification_webhook_requires_https
    error = assert_raises(IOSBuild::ASC::WebhookDeliveryError) do
      IOSBuild::ASC::WebhookNotifier.new(url: "http://notify.example.test/asc")
    end
    assert_includes error.message, "HTTPS"
  end

  def test_optional_notification_failure_does_not_erase_a_successful_query_result
    summary = {
      "app_id" => "123",
      "app_store_version_id" => "version-1",
      "marketing_version" => "1.2.3",
      "app_store_version_state" => "IN_REVIEW",
      "status_group" => "in_review",
      "attention_required" => false,
      "terminal" => false,
      "checked_at" => "2026-09-24T01:02:03Z"
    }

    delivery = IOSBuild::ASC::WebhookNotifier.attempt_review_status(
      summary,
      url: "http://notify.example.test/asc"
    )

    assert_equal true, delivery["requested"]
    assert_equal false, delivery["sent"]
    assert_includes delivery["error"], "HTTPS"
    assert_equal "IN_REVIEW", summary["app_store_version_state"]
  end

  private

  def app_store_version(id:, version:, platform:, state:)
    {
      "type" => "appStoreVersions",
      "id" => id,
      "attributes" => {
        "versionString" => version,
        "platform" => platform,
        "appVersionState" => state
      }
    }
  end
end
