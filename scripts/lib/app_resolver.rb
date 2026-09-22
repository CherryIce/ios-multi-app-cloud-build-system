# frozen_string_literal: true

module IOSBuild
  module ASC
    class AppResolutionError < StandardError; end

    class AppResolver
      def initialize(client:)
        @client = client
      end

      def resolve(bundle_id:, configured_id:)
        apps = @client.paginate(
          "/v1/apps",
          { "filter[bundleId]" => bundle_id, "limit" => "2" }
        )
        if apps.empty?
          raise AppResolutionError, "no App Store Connect app found for bundle ID #{bundle_id}"
        end
        if apps.length > 1
          raise AppResolutionError, "multiple App Store Connect apps found for bundle ID #{bundle_id}"
        end

        resolved_id = apps.first.fetch("id")
        if configured_id != "0" && configured_id != resolved_id
          raise AppResolutionError,
                "configured ASC app ID #{configured_id} does not match bundle ID #{bundle_id} (#{resolved_id})"
        end
        resolved_id
      end
    end
  end
end
