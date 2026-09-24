# frozen_string_literal: true

require "time"

module IOSBuild
  module ASC
    class ReviewStatusError < StandardError; end

    class ReviewStatus
      STATE_GROUPS = {
        "PREPARE_FOR_SUBMISSION" => "draft",
        "READY_FOR_REVIEW" => "review_queue",
        "WAITING_FOR_REVIEW" => "review_queue",
        "IN_REVIEW" => "in_review",
        "ACCEPTED" => "approved",
        "PENDING_APPLE_RELEASE" => "approved",
        "PENDING_DEVELOPER_RELEASE" => "approved",
        "PROCESSING_FOR_DISTRIBUTION" => "processing",
        "PROCESSING_FOR_APP_STORE" => "processing",
        "READY_FOR_DISTRIBUTION" => "released",
        "READY_FOR_SALE" => "released",
        "WAITING_FOR_EXPORT_COMPLIANCE" => "attention_required",
        "INVALID_BINARY" => "attention_required",
        "METADATA_REJECTED" => "attention_required",
        "REJECTED" => "attention_required",
        "DEVELOPER_REJECTED" => "attention_required",
        "REPLACED_WITH_NEW_VERSION" => "superseded"
      }.freeze
      TERMINAL_GROUPS = %w[released superseded].freeze

      def initialize(client:, app_id:)
        @client = client
        @app_id = app_id
      end

      def query(marketing_version:, now: Time.now)
        records = @client.paginate(
          "/v1/apps/#{@app_id}/appStoreVersions",
          {
            "filter[versionString]" => marketing_version,
            "filter[platform]" => "IOS",
            "limit" => "200"
          }
        )
        versions = records.select do |candidate|
          candidate.dig("attributes", "versionString") == marketing_version &&
            candidate.dig("attributes", "platform") == "IOS"
        end
        raise ReviewStatusError, "iOS App Store version #{marketing_version} was not found" if versions.empty?
        if versions.length > 1
          raise ReviewStatusError, "multiple iOS App Store versions found for #{marketing_version}"
        end

        version = versions.fetch(0)
        state = version.dig("attributes", "appVersionState") ||
          version.dig("attributes", "appStoreState")
        raise ReviewStatusError, "App Store version #{marketing_version} has no review state" if state.to_s.empty?

        group = STATE_GROUPS.fetch(state, "unknown")
        {
          "schema_version" => 1,
          "source" => "manual_query",
          "app_id" => @app_id,
          "app_store_version_id" => version.fetch("id"),
          "marketing_version" => marketing_version,
          "platform" => "IOS",
          "app_store_version_state" => state,
          "status_group" => group,
          "attention_required" => group == "attention_required",
          "terminal" => TERMINAL_GROUPS.include?(group),
          "checked_at" => now.utc.iso8601
        }
      end
    end
  end
end
