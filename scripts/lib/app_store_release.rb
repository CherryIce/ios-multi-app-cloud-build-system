# frozen_string_literal: true

require_relative "app_store_metadata"
require_relative "app_store_media"

module IOSBuild
  module ASC
    class ReleaseError < StandardError; end

    class AppStoreRelease
      MUTABLE_VERSION_STATES = %w[
        PREPARE_FOR_SUBMISSION DEVELOPER_REJECTED METADATA_REJECTED REJECTED
        INVALID_BINARY WAITING_FOR_EXPORT_COMPLIANCE
      ].freeze
      SUBMITTED_VERSION_STATES = %w[
        WAITING_FOR_REVIEW IN_REVIEW ACCEPTED PENDING_APPLE_RELEASE
        PENDING_CONTRACT PENDING_DEVELOPER_RELEASE PROCESSING_FOR_APP_STORE
        PROCESSING_FOR_DISTRIBUTION
      ].freeze
      RELEASED_VERSION_STATES = %w[
        READY_FOR_SALE READY_FOR_DISTRIBUTION PREORDER_READY_FOR_SALE
        DEVELOPER_REMOVED_FROM_SALE REMOVED_FROM_SALE REPLACED_WITH_NEW_VERSION
      ].freeze
      EDITABLE_VERSION_STATES = (MUTABLE_VERSION_STATES + ["READY_FOR_REVIEW"]).freeze
      MEDIA_EDITABLE_VERSION_STATES = %w[
        PREPARE_FOR_SUBMISSION INVALID_BINARY REJECTED METADATA_REJECTED DEVELOPER_REJECTED
      ].freeze
      BLOCKING_SUBMISSION_STATES = %w[
        WAITING_FOR_REVIEW IN_REVIEW UNRESOLVED_ISSUES CANCELING COMPLETING
      ].freeze
      SUBMITTED_REVIEW_STATES = %w[WAITING_FOR_REVIEW IN_REVIEW COMPLETING COMPLETE].freeze

      def initialize(
        client:, app_id:, marketing_version:, metadata:, build_id: nil, build_number: nil,
        automatic_release:, submit_to_review:, demo_account_name: "", demo_account_password: "",
        update_text_metadata: false, replace_media: false, workspace: Dir.pwd
      )
        @client = client
        @app_id = app_id
        @marketing_version = marketing_version
        @build_id = build_id
        @build_number = build_number
        @metadata = metadata
        @automatic_release = automatic_release
        @submit_to_review = submit_to_review
        @demo_account_name = demo_account_name
        @demo_account_password = demo_account_password
        @update_text_metadata = update_text_metadata
        @replace_media = replace_media
        @workspace = workspace
      end

      def prepare
        version, created = ensure_version
        version_state = state_of(version)
        summary = base_summary(version, version_state, created)

        if RELEASED_VERSION_STATES.include?(version_state)
          assert_no_requested_changes!(version_state)
          return no_op_summary(summary, reason: "already_released", released: true)
        end
        if SUBMITTED_VERSION_STATES.include?(version_state)
          assert_no_requested_changes!(version_state)
          return no_op_summary(summary, reason: "already_submitted", submitted: true)
        end
        unless EDITABLE_VERSION_STATES.include?(version_state)
          raise ReleaseError, "App Store version #{@marketing_version} is not editable in state #{version_state || 'UNKNOWN'}"
        end
        assert_media_editable!(version_state)

        version = update_version(version)
        assert_release_policy(version)
        summary = base_summary(version, state_of(version), created)
        if @update_text_metadata
          sync_app_info_localizations
          sync_localizations(version.fetch("id"))
          sync_review_detail(version.fetch("id"))
          summary = summary.merge("metadata_synced" => true, "text_metadata_updated" => true)
        end
        if @replace_media
          locales = @metadata.fetch("media").keys
          localizations = ensure_version_localizations(version.fetch("id"), locales)
          media_summary = AppStoreMedia.new(client: @client, workspace: @workspace).replace!(
            @metadata.fetch("media"),
            localizations
          )
          summary = summary.merge(
            "media_replaced" => true,
            "media_collections_replaced" => media_summary.fetch("collections"),
            "screenshots_uploaded" => media_summary.fetch("screenshots"),
            "previews_uploaded" => media_summary.fetch("previews")
          )
        end
        summary
      end

      def execute
        version, created = ensure_version
        version_state = state_of(version)
        summary = base_summary(version, version_state, created)

        if RELEASED_VERSION_STATES.include?(version_state)
          return no_op_summary(summary, reason: "already_released", released: true).merge(
            "text_metadata_updated" => @update_text_metadata,
            "media_replaced" => @replace_media
          )
        end

        if SUBMITTED_VERSION_STATES.include?(version_state)
          return no_op_summary(summary, reason: "already_submitted", submitted: true).merge(
            "text_metadata_updated" => @update_text_metadata,
            "media_replaced" => @replace_media
          )
        end

        unless EDITABLE_VERSION_STATES.include?(version_state)
          raise ReleaseError, "App Store version #{@marketing_version} is not editable in state #{version_state || 'UNKNOWN'}"
        end
        assert_media_editable!(version_state)

        verify_and_update_build
        version = update_version(version)
        assert_release_policy(version)
        if @update_text_metadata
          sync_app_info_localizations
          sync_localizations(version.fetch("id"))
          sync_review_detail(version.fetch("id"))
        end
        attach_build(version.fetch("id"))

        summary = base_summary(version, state_of(version), created).merge(
          "build_attached" => true,
          "metadata_synced" => @update_text_metadata,
          "text_metadata_updated" => @update_text_metadata,
          "media_replaced" => @replace_media
        )
        return summary unless @submit_to_review

        submission = ensure_review_submission(version.fetch("id"))
        summary.merge(submission_summary(submission), "review_submitted" => true)
      end

      private

      def ensure_version
        versions = @client.paginate(
          "/v1/apps/#{@app_id}/appStoreVersions",
          {
            "filter[versionString]" => @marketing_version,
            "filter[platform]" => "IOS",
            "limit" => "200"
          }
        )
        raise ReleaseError, "multiple iOS App Store versions found for #{@marketing_version}" if versions.length > 1
        return [versions.first, false] if versions.first

        assert_version_is_newer_than_distributed
        attributes = {
          "platform" => "IOS",
          "versionString" => @marketing_version
        }.merge(desired_version_attributes)
        response = @client.post(
          "/v1/appStoreVersions",
          {
            "data" => {
              "type" => "appStoreVersions",
              "attributes" => attributes,
              "relationships" => {
                "app" => { "data" => { "type" => "apps", "id" => @app_id } }
              }
            }
          }
        )
        [response.fetch("data"), true]
      end

      def assert_version_is_newer_than_distributed
        versions = @client.paginate(
          "/v1/apps/#{@app_id}/appStoreVersions",
          { "filter[platform]" => "IOS", "limit" => "200" }
        )
        distributed = versions.select { |version| RELEASED_VERSION_STATES.include?(state_of(version)) }
        newest = distributed.max_by { |version| version_parts(version.dig("attributes", "versionString")) }
        return unless newest

        current = newest.dig("attributes", "versionString")
        unless compare_versions(@marketing_version, current).positive?
          raise ReleaseError, "requested version #{@marketing_version} must be newer than distributed version #{current}"
        end
      end

      def update_version(version)
        desired = desired_version_attributes
        current = version.fetch("attributes", {})
        changes = desired.reject { |key, value| current[key] == value }
        return version if changes.empty?

        response = @client.patch(
          "/v1/appStoreVersions/#{version.fetch('id')}",
          {
            "data" => {
              "type" => "appStoreVersions",
              "id" => version.fetch("id"),
              "attributes" => changes
            }
          }
        )
        response.fetch("data")
      end

      def desired_version_attributes
        metadata = @update_text_metadata ? @metadata : {}
        AppStoreMetadata.version_attributes(metadata, automatic_release: @automatic_release)
      end

      def assert_release_policy(version)
        desired = @automatic_release ? "AFTER_APPROVAL" : "MANUAL"
        actual = version.dig("attributes", "releaseType")
        return if actual == desired

        raise ReleaseError, "App Store version releaseType is #{actual || 'UNKNOWN'}, expected #{desired}"
      end

      def sync_localizations(version_id)
        requested = @metadata.fetch("localizations", {})
        return {} if requested.empty?

        localizations = ensure_version_localizations(version_id, requested.keys)
        requested.each do |locale, source_attributes|
          localization = localizations.fetch(locale)
          attributes = AppStoreMetadata.localization_attributes(source_attributes)
          @client.patch(
            "/v1/appStoreVersionLocalizations/#{localization.fetch('id')}",
            {
              "data" => {
                "type" => "appStoreVersionLocalizations",
                "id" => localization.fetch("id"),
                "attributes" => attributes
              }
            }
          )
          verify_attributes(
            @client.get("/v1/appStoreVersionLocalizations/#{localization.fetch('id')}").fetch("data"),
            attributes,
            "App Store version localization #{locale}"
          )
        end
        localizations
      end

      def ensure_version_localizations(version_id, locales)
        existing = @client.paginate(
          "/v1/appStoreVersions/#{version_id}/appStoreVersionLocalizations",
          { "limit" => "200" }
        ).each_with_object({}) do |localization, result|
          result[localization.dig("attributes", "locale")] = localization
        end

        locales.each do |locale|
          next if existing[locale]

          response = @client.post(
              "/v1/appStoreVersionLocalizations",
              {
                "data" => {
                  "type" => "appStoreVersionLocalizations",
                  "attributes" => { "locale" => locale },
                  "relationships" => {
                    "appStoreVersion" => {
                      "data" => { "type" => "appStoreVersions", "id" => version_id }
                    }
                  }
                }
              }
            )
          existing[locale] = response.fetch("data")
        end
        existing.slice(*locales)
      end

      def sync_app_info_localizations
        requested = @metadata.fetch("app_info_localizations", {})
        return if requested.empty?

        infos = @client.paginate("/v1/apps/#{@app_id}/appInfos", { "limit" => "200" })
        editable = infos.select do |info|
          EDITABLE_VERSION_STATES.include?(info.dig("attributes", "state") || info.dig("attributes", "appStoreState"))
        end
        unless editable.length == 1
          raise ReleaseError, "expected exactly one editable App Info resource; found #{editable.length}"
        end
        info = editable.first
        existing = @client.paginate(
          "/v1/appInfos/#{info.fetch('id')}/appInfoLocalizations",
          { "limit" => "200" }
        ).each_with_object({}) do |localization, result|
          result[localization.dig("attributes", "locale")] = localization
        end

        requested.each do |locale, source_attributes|
          attributes = AppStoreMetadata.app_info_localization_attributes(source_attributes)
          localization = existing[locale]
          if localization
            @client.patch(
              "/v1/appInfoLocalizations/#{localization.fetch('id')}",
              {
                "data" => {
                  "type" => "appInfoLocalizations",
                  "id" => localization.fetch("id"),
                  "attributes" => attributes
                }
              }
            )
          else
            response = @client.post(
              "/v1/appInfoLocalizations",
              {
                "data" => {
                  "type" => "appInfoLocalizations",
                  "attributes" => { "locale" => locale }.merge(attributes),
                  "relationships" => {
                    "appInfo" => { "data" => { "type" => "appInfos", "id" => info.fetch("id") } }
                  }
                }
              }
            )
            localization = response.fetch("data")
          end
          verify_attributes(
            @client.get("/v1/appInfoLocalizations/#{localization.fetch('id')}").fetch("data"),
            attributes,
            "App Info localization #{locale}"
          )
        end
      end

      def sync_review_detail(version_id)
        attributes = AppStoreMetadata.review_detail_attributes(
          @metadata,
          demo_account_name: @demo_account_name,
          demo_account_password: @demo_account_password
        )
        return unless attributes

        response = @client.get("/v1/appStoreVersions/#{version_id}/appStoreReviewDetail")
        detail = response["data"]
        if detail
          @client.patch(
            "/v1/appStoreReviewDetails/#{detail.fetch('id')}",
            {
              "data" => {
                "type" => "appStoreReviewDetails",
                "id" => detail.fetch("id"),
                "attributes" => attributes
              }
            }
          )
        else
          response = @client.post(
            "/v1/appStoreReviewDetails",
            {
              "data" => {
                "type" => "appStoreReviewDetails",
                "attributes" => attributes,
                "relationships" => {
                  "appStoreVersion" => {
                    "data" => { "type" => "appStoreVersions", "id" => version_id }
                  }
                }
              }
            }
          )
          detail = response.fetch("data")
        end
        verify_attributes(
          @client.get("/v1/appStoreReviewDetails/#{detail.fetch('id')}").fetch("data"),
          attributes.reject { |key, _value| key == "demoAccountPassword" },
          "App Review detail"
        )
      end

      def verify_attributes(resource, expected, label)
        actual = resource.fetch("attributes", {})
        mismatches = expected.reject { |key, value| actual[key] == value }
        return if mismatches.empty?

        raise ReleaseError, "failed to verify #{label}: #{mismatches.keys.join(', ')}"
      end

      def assert_no_requested_changes!(version_state)
        return unless @update_text_metadata || @replace_media

        requested = []
        requested << "text metadata" if @update_text_metadata
        requested << "screenshots/app previews" if @replace_media
        raise ReleaseError,
              "requested ASC #{requested.join(' and ')} changes cannot be applied while version #{@marketing_version} is in state #{version_state}"
      end

      def assert_media_editable!(version_state)
        return unless @replace_media
        return if MEDIA_EDITABLE_VERSION_STATES.include?(version_state)

        raise ReleaseError,
              "ASC media cannot be replaced while App Store version #{@marketing_version} is in state #{version_state}"
      end

      def verify_and_update_build
        if @build_id.to_s.empty? || @build_number.to_s.empty?
          raise ReleaseError, "build ID and build number are required to finalize an App Store release"
        end
        response = @client.get("/v1/builds/#{@build_id}", { "include" => "preReleaseVersion" })
        build = response.fetch("data")
        raise ReleaseError, "ASC returned a different build than #{@build_id}" unless build.fetch("id") == @build_id
        unless build.dig("attributes", "processingState") == "VALID"
          raise ReleaseError, "build #{@build_id} is not VALID"
        end
        unless build.dig("attributes", "version").to_s == @build_number.to_s
          raise ReleaseError, "build #{@build_id} does not have build number #{@build_number}"
        end

        prerelease_id = build.dig("relationships", "preReleaseVersion", "data", "id")
        prerelease = Array(response["included"]).find do |item|
          item["type"] == "preReleaseVersions" && item["id"] == prerelease_id
        end
        unless prerelease&.dig("attributes", "version") == @marketing_version
          raise ReleaseError, "build #{@build_id} does not belong to marketing version #{@marketing_version}"
        end

        return unless @metadata.key?("uses_non_exempt_encryption")
        return if build.dig("attributes", "usesNonExemptEncryption") == @metadata["uses_non_exempt_encryption"]

        @client.patch(
          "/v1/builds/#{@build_id}",
          {
            "data" => {
              "type" => "builds",
              "id" => @build_id,
              "attributes" => {
                "usesNonExemptEncryption" => @metadata["uses_non_exempt_encryption"]
              }
            }
          }
        )
      end

      def attach_build(version_id)
        relationship_path = "/v1/appStoreVersions/#{version_id}/relationships/build"
        @client.patch(
          relationship_path,
          { "data" => { "type" => "builds", "id" => @build_id } }
        )
        assert_attached_build(version_id)
      end

      def assert_attached_build(version_id)
        relationship_path = "/v1/appStoreVersions/#{version_id}/relationships/build"
        response = @client.get(relationship_path)
        unless response.dig("data", "id") == @build_id
          raise ReleaseError, "failed to verify build #{@build_id} on App Store version #{@marketing_version}"
        end
      end

      def ensure_review_submission(version_id)
        target = find_target_submission(version_id, allowed_states: ["READY_FOR_REVIEW"])
        if target
          return submit_review(target)
        end

        submissions = review_submissions
        blocker = submissions.find { |submission| BLOCKING_SUBMISSION_STATES.include?(submission.dig("attributes", "state")) }
        if blocker
          raise ReleaseError, "another iOS review submission is active in state #{blocker.dig('attributes', 'state')}"
        end

        submission = submissions.find { |candidate| candidate.dig("attributes", "state") == "READY_FOR_REVIEW" }
        submission ||= create_review_submission
        create_review_item(submission.fetch("id"), version_id)
        submit_review(submission)
      end

      def review_submissions
        @client.paginate(
          "/v1/apps/#{@app_id}/reviewSubmissions",
          { "filter[platform]" => "IOS", "limit" => "200" }
        )
      end

      def find_target_submission(version_id, allowed_states: nil)
        review_submissions.find do |submission|
          state = submission.dig("attributes", "state")
          next false if allowed_states && !allowed_states.include?(state)

          items = @client.paginate(
            "/v1/reviewSubmissions/#{submission.fetch('id')}/items",
            { "limit" => "200" }
          )
          items.any? do |item|
            item.dig("relationships", "appStoreVersion", "data", "id") == version_id
          end
        end
      end

      def create_review_submission
        response = @client.post(
          "/v1/reviewSubmissions",
          {
            "data" => {
              "type" => "reviewSubmissions",
              "attributes" => { "platform" => "IOS" },
              "relationships" => {
                "app" => { "data" => { "type" => "apps", "id" => @app_id } }
              }
            }
          }
        )
        response.fetch("data")
      end

      def create_review_item(submission_id, version_id)
        @client.post(
          "/v1/reviewSubmissionItems",
          {
            "data" => {
              "type" => "reviewSubmissionItems",
              "relationships" => {
                "reviewSubmission" => {
                  "data" => { "type" => "reviewSubmissions", "id" => submission_id }
                },
                "appStoreVersion" => {
                  "data" => { "type" => "appStoreVersions", "id" => version_id }
                }
              }
            }
          }
        )
      end

      def submit_review(submission)
        @client.patch(
          "/v1/reviewSubmissions/#{submission.fetch('id')}",
          {
            "data" => {
              "type" => "reviewSubmissions",
              "id" => submission.fetch("id"),
              "attributes" => { "submitted" => true }
            }
          }
        )
        response = @client.get("/v1/reviewSubmissions/#{submission.fetch('id')}")
        observed = response.fetch("data")
        state = observed.dig("attributes", "state")
        unless SUBMITTED_REVIEW_STATES.include?(state)
          raise ReleaseError, "review submission did not enter a submitted state; observed #{state || 'UNKNOWN'}"
        end
        observed
      end

      def base_summary(version, version_state, created)
        {
          "app_id" => @app_id,
          "marketing_version" => @marketing_version,
          "app_store_version_id" => version.fetch("id"),
          "app_store_version_state" => version_state,
          "build_id" => @build_id,
          "build_number" => @build_number,
          "version_created" => created,
          "automatic_release" => @automatic_release,
          "metadata_synced" => false,
          "text_metadata_updated" => false,
          "media_replaced" => false,
          "media_collections_replaced" => 0,
          "screenshots_uploaded" => 0,
          "previews_uploaded" => 0,
          "build_attached" => false,
          "review_submitted" => false,
          "already_submitted" => false,
          "already_released" => false,
          "no_op" => false,
          "no_op_reason" => nil,
          "review_submission_id" => nil,
          "review_submission_state" => nil
        }
      end

      def no_op_summary(summary, reason:, submitted: false, released: false)
        summary.merge(
          "review_submitted" => submitted,
          "already_submitted" => submitted,
          "already_released" => released,
          "no_op" => true,
          "no_op_reason" => reason
        )
      end

      def submission_summary(submission)
        return {} unless submission

        {
          "review_submission_id" => submission.fetch("id"),
          "review_submission_state" => submission.dig("attributes", "state")
        }
      end

      def state_of(version)
        version.dig("attributes", "appVersionState") || version.dig("attributes", "appStoreState")
      end

      def version_parts(value)
        value.to_s.split(".").map { |part| Integer(part, 10) }
      rescue ArgumentError
        []
      end

      def compare_versions(left, right)
        left_parts = version_parts(left)
        right_parts = version_parts(right)
        length = [left_parts.length, right_parts.length].max
        (left_parts + [0] * (length - left_parts.length)) <=>
          (right_parts + [0] * (length - right_parts.length))
      end
    end
  end
end
