# frozen_string_literal: true

module IOSBuild
  module ASC
    module State
      module_function

      def related_resource(response, resource, relationship_name, included_type)
        relationship_id = resource.dig("relationships", relationship_name, "data", "id")
        Array(response["included"]).find do |item|
          item["type"] == included_type && item["id"] == relationship_id
        end
      end

      def normalized_build_upload_state(upload)
        value = upload&.dig("attributes", "state")
        value.is_a?(Hash) ? value["state"] : value
      end

      def build_upload_messages(upload, key)
        value = upload&.dig("attributes", "state")
        value.is_a?(Hash) ? Array(value[key]) : []
      end

      def snapshot(uploads_response:, builds_response:, marketing_version:)
        uploads = Array(uploads_response["data"])
        builds = Array(builds_response["data"])
        upload = uploads.max_by do |candidate|
          candidate.dig("attributes", "uploadedDate").to_s
        end
        build = builds.find do |candidate|
          prerelease = related_resource(builds_response, candidate, "preReleaseVersion", "preReleaseVersions")
          prerelease&.dig("attributes", "version") == marketing_version
        end
        beta_detail = build && related_resource(builds_response, build, "buildBetaDetail", "buildBetaDetails")

        {
          "build_upload_count" => uploads.length,
          "build_count" => builds.length,
          "build_upload_id" => upload && upload["id"],
          "build_upload_state" => normalized_build_upload_state(upload),
          "build_upload_errors" => build_upload_messages(upload, "errors"),
          "build_upload_warnings" => build_upload_messages(upload, "warnings"),
          "build_upload_infos" => build_upload_messages(upload, "infos"),
          "asc_build_id" => build && build["id"],
          "processing_state" => build&.dig("attributes", "processingState"),
          "testflight_internal_state" => beta_detail&.dig("attributes", "internalBuildState"),
          "observation_source" => build ? "builds" : (upload ? "build_uploads" : nil)
        }
      end

      def exact_app_store_version(response, marketing_version)
        Array(response["data"]).find do |candidate|
          candidate.dig("attributes", "versionString") == marketing_version &&
            candidate.dig("attributes", "platform") == "IOS"
        end
      end

      def wait_satisfied?(snapshot, wait_level)
        case wait_level
        when "asc_appeared"
          !snapshot["build_upload_id"].to_s.empty? || !snapshot["asc_build_id"].to_s.empty?
        when "processing_complete"
          !snapshot["asc_build_id"].to_s.empty? && snapshot["processing_state"] == "VALID"
        when "testflight_internal_ready"
          %w[READY_FOR_BETA_TESTING IN_BETA_TESTING].include?(snapshot["testflight_internal_state"])
        else
          false
        end
      end

      def app_store_version_build_snapshot(
        versions_response:, build_relationship_response:, build_response:,
        marketing_version:, build_number:
      )
        versions = Array(versions_response["data"])
        version = exact_app_store_version(versions_response, marketing_version)
        result = {
          "app_store_version_count" => versions.length,
          "app_store_version_id" => version && version["id"],
          "app_store_version_state" => version&.dig("attributes", "appVersionState") ||
            version&.dig("attributes", "appStoreState"),
          "app_store_attached_build_id" => nil,
          "app_store_fallback_status" => version ? "build_not_attached" : "version_not_found"
        }
        return result unless version

        attached_build_id = build_relationship_response.dig("data", "id")
        result["app_store_attached_build_id"] = attached_build_id
        return result unless attached_build_id

        build = build_response["data"]
        unless build && build["id"] == attached_build_id
          return result.merge("app_store_fallback_status" => "attached_build_not_returned")
        end
        unless build.dig("attributes", "version").to_s == build_number.to_s
          return result.merge("app_store_fallback_status" => "build_number_mismatch")
        end

        prerelease = related_resource(build_response, build, "preReleaseVersion", "preReleaseVersions")
        unless prerelease&.dig("attributes", "version") == marketing_version
          return result.merge("app_store_fallback_status" => "marketing_version_mismatch")
        end

        beta_detail = related_resource(build_response, build, "buildBetaDetail", "buildBetaDetails")
        result.merge(
          "asc_build_id" => build["id"],
          "processing_state" => build.dig("attributes", "processingState"),
          "testflight_internal_state" => beta_detail&.dig("attributes", "internalBuildState"),
          "observation_source" => "app_store_version_build",
          "app_store_fallback_status" => "matched"
        )
      end
    end
  end
end
