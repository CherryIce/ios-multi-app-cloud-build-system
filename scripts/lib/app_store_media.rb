# frozen_string_literal: true

require "digest"
require "pathname"

module IOSBuild
  module ASC
    class AppStoreMedia
      COLLECTIONS = {
        "screenshots" => {
          set_type: "appScreenshotSets",
          set_path: "/v1/appScreenshotSets",
          set_relationship: "appScreenshotSet",
          set_attribute: "screenshotDisplayType",
          localization_relationship: "appScreenshotSets",
          asset_type: "appScreenshots",
          asset_path: "/v1/appScreenshots",
          asset_relationship: "appScreenshots",
          state_attribute: "assetDeliveryState"
        },
        "previews" => {
          set_type: "appPreviewSets",
          set_path: "/v1/appPreviewSets",
          set_relationship: "appPreviewSet",
          set_attribute: "previewType",
          localization_relationship: "appPreviewSets",
          asset_type: "appPreviews",
          asset_path: "/v1/appPreviews",
          asset_relationship: "appPreviews",
          state_attribute: "videoDeliveryState"
        }
      }.freeze

      def initialize(client:, workspace:, poll_interval_seconds: 10, timeout_seconds: 1200, sleeper: Kernel)
        @client = client
        @workspace = File.realpath(workspace)
        @poll_interval_seconds = poll_interval_seconds
        @timeout_seconds = timeout_seconds
        @sleeper = sleeper
      end

      def replace!(manifest, localizations)
        resolved = resolve_manifest(manifest)
        summary = { "screenshots" => 0, "previews" => 0, "collections" => 0 }

        resolved.each do |locale, kinds|
          localization = localizations.fetch(locale) do
            raise ReleaseError, "App Store version localization #{locale} is unavailable for media replacement"
          end
          COLLECTIONS.each do |kind, contract|
            Hash(kinds[kind]).each do |display_type, files|
              replace_collection(localization.fetch("id"), contract, display_type, files)
              summary[kind] += files.length
              summary["collections"] += 1
            end
          end
        end

        summary
      end

      private

      def resolve_manifest(manifest)
        manifest.each_with_object({}) do |(locale, kinds), result|
          result[locale] = COLLECTIONS.keys.each_with_object({}) do |kind, resolved_kinds|
            next unless kinds.key?(kind)

            resolved_kinds[kind] = kinds.fetch(kind).transform_values do |paths|
              paths.map { |path| resolve_file(path) }
            end
          end
        end
      end

      def resolve_file(relative_path)
        candidate = File.realpath(File.expand_path(relative_path, @workspace))
        unless candidate.start_with?(@workspace + File::SEPARATOR) && File.file?(candidate)
          raise ReleaseError, "ASC media path must resolve to a file inside GITHUB_WORKSPACE: #{relative_path}"
        end
        raise ReleaseError, "ASC media file is empty: #{relative_path}" unless File.size(candidate).positive?

        candidate
      rescue Errno::ENOENT, Errno::EACCES
        raise ReleaseError, "ASC media file is unavailable: #{relative_path}"
      end

      def replace_collection(localization_id, contract, display_type, files)
        set = find_or_create_set(localization_id, contract, display_type)
        existing_assets(set.fetch("id"), contract).each do |asset|
          @client.delete("#{contract.fetch(:asset_path)}/#{asset.fetch('id')}")
        end

        uploaded = files.map { |path| upload_asset(set.fetch("id"), contract, path) }
        relationship_path = "#{contract.fetch(:set_path)}/#{set.fetch('id')}/relationships/#{contract.fetch(:asset_relationship)}"
        expected = uploaded.map { |asset| { "type" => contract.fetch(:asset_type), "id" => asset.fetch("id") } }
        @client.patch(relationship_path, { "data" => expected })
        observed = Array(@client.get(relationship_path)["data"])
        unless observed.map { |item| item["id"] } == expected.map { |item| item["id"] }
          raise ReleaseError, "failed to verify ordered #{contract.fetch(:asset_relationship)} replacement"
        end
      end

      def find_or_create_set(localization_id, contract, display_type)
        path = "/v1/appStoreVersionLocalizations/#{localization_id}/#{contract.fetch(:localization_relationship)}"
        sets = @client.paginate(path, { "limit" => "200" })
        matches = sets.select { |set| set.dig("attributes", contract.fetch(:set_attribute)) == display_type }
        raise ReleaseError, "multiple ASC media sets found for #{display_type}" if matches.length > 1
        return matches.first if matches.first

        response = @client.post(
          contract.fetch(:set_path),
          {
            "data" => {
              "type" => contract.fetch(:set_type),
              "attributes" => { contract.fetch(:set_attribute) => display_type },
              "relationships" => {
                "appStoreVersionLocalization" => {
                  "data" => { "type" => "appStoreVersionLocalizations", "id" => localization_id }
                }
              }
            }
          }
        )
        response.fetch("data")
      end

      def existing_assets(set_id, contract)
        @client.paginate(
          "#{contract.fetch(:set_path)}/#{set_id}/#{contract.fetch(:asset_relationship)}",
          { "limit" => "200" }
        )
      end

      def upload_asset(set_id, contract, path)
        response = @client.post(
          contract.fetch(:asset_path),
          {
            "data" => {
              "type" => contract.fetch(:asset_type),
              "attributes" => {
                "fileName" => File.basename(path),
                "fileSize" => File.size(path)
              },
              "relationships" => {
                contract.fetch(:set_relationship) => {
                  "data" => { "type" => contract.fetch(:set_type), "id" => set_id }
                }
              }
            }
          }
        )
        asset = response.fetch("data")
        operations = Array(asset.dig("attributes", "uploadOperations"))
        validate_upload_operations!(operations, File.size(path))
        File.open(path, "rb") do |file|
          operations.each do |operation|
            file.seek(operation.fetch("offset"))
            bytes = file.read(operation.fetch("length"))
            headers = Array(operation["requestHeaders"]).to_h do |header|
              [header.fetch("name"), header.fetch("value")]
            end
            @client.upload_part(
              operation.fetch("url"),
              method: operation.fetch("method"),
              headers: headers,
              body: bytes
            )
          end
        end
        @client.patch(
          "#{contract.fetch(:asset_path)}/#{asset.fetch('id')}",
          {
            "data" => {
              "type" => contract.fetch(:asset_type),
              "id" => asset.fetch("id"),
              "attributes" => {
                "uploaded" => true,
                "sourceFileChecksum" => Digest::MD5.file(path).hexdigest
              }
            }
          }
        )
        wait_for_processing(asset.fetch("id"), contract)
      end

      def validate_upload_operations!(operations, file_size)
        ranges = operations.map do |operation|
          offset = operation["offset"]
          length = operation["length"]
          unless offset.is_a?(Integer) && length.is_a?(Integer) && offset >= 0 && length.positive? &&
                 offset + length <= file_size
            raise ReleaseError, "ASC returned an invalid media upload operation"
          end
          [offset, offset + length]
        end.sort
        cursor = 0
        ranges.each do |start_offset, end_offset|
          raise ReleaseError, "ASC media upload operations do not cover the file exactly" unless start_offset == cursor

          cursor = end_offset
        end
        raise ReleaseError, "ASC media upload operations do not cover the file exactly" unless cursor == file_size
      end

      def wait_for_processing(asset_id, contract)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @timeout_seconds
        loop do
          asset = @client.get("#{contract.fetch(:asset_path)}/#{asset_id}").fetch("data")
          state = asset.dig("attributes", contract.fetch(:state_attribute), "state")
          state ||= asset.dig("attributes", "assetDeliveryState", "state")
          return asset if state == "COMPLETE"
          if state == "FAILED"
            details = asset.dig("attributes", contract.fetch(:state_attribute), "errors") ||
                      asset.dig("attributes", "assetDeliveryState", "errors")
            raise ReleaseError, "ASC media processing failed: #{Array(details).first || 'no details'}"
          end
          if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
            raise ReleaseError, "timed out waiting for ASC media processing; observed #{state || 'UNKNOWN'}"
          end
          @sleeper.sleep(@poll_interval_seconds)
        end
      end
    end
  end
end
