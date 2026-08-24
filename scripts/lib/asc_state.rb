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

      def snapshot(uploads_response:, builds_response:, marketing_version:)
        upload = Array(uploads_response["data"]).max_by do |candidate|
          candidate.dig("attributes", "uploadedDate").to_s
        end
        build = Array(builds_response["data"]).find do |candidate|
          prerelease = related_resource(builds_response, candidate, "preReleaseVersion", "preReleaseVersions")
          prerelease&.dig("attributes", "version") == marketing_version
        end
        beta_detail = build && related_resource(builds_response, build, "buildBetaDetail", "buildBetaDetails")

        {
          "build_upload_id" => upload && upload["id"],
          "build_upload_state" => upload&.dig("attributes", "state"),
          "asc_build_id" => build && build["id"],
          "processing_state" => build&.dig("attributes", "processingState"),
          "testflight_internal_state" => beta_detail&.dig("attributes", "internalBuildState")
        }
      end
    end
  end
end
