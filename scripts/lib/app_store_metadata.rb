# frozen_string_literal: true

require "uri"
require "pathname"
require_relative "config"

module IOSBuild
  module ASC
    class MetadataError < StandardError; end

    module AppStoreMetadata
      module_function

      ROOT_KEYS = %w[
        copyright uses_idfa uses_non_exempt_encryption app_info_localizations
        localizations review_detail media
      ].freeze
      APP_INFO_LOCALIZATION_KEYS = %w[
        name subtitle privacy_policy_url privacy_choices_url
      ].freeze
      LOCALIZATION_KEYS = %w[
        description keywords marketing_url promotional_text support_url whats_new
      ].freeze
      MEDIA_KEYS = %w[screenshots previews].freeze
      REVIEW_DETAIL_KEYS = %w[
        contact_email contact_first_name contact_last_name contact_phone
        demo_account_required notes
      ].freeze
      LOCALIZATION_API_KEYS = {
        "description" => "description",
        "keywords" => "keywords",
        "marketing_url" => "marketingUrl",
        "promotional_text" => "promotionalText",
        "support_url" => "supportUrl",
        "whats_new" => "whatsNew"
      }.freeze
      APP_INFO_LOCALIZATION_API_KEYS = {
        "name" => "name",
        "subtitle" => "subtitle",
        "privacy_policy_url" => "privacyPolicyUrl",
        "privacy_choices_url" => "privacyChoicesUrl"
      }.freeze
      REVIEW_DETAIL_API_KEYS = {
        "contact_email" => "contactEmail",
        "contact_first_name" => "contactFirstName",
        "contact_last_name" => "contactLastName",
        "contact_phone" => "contactPhone",
        "demo_account_required" => "demoAccountRequired",
        "notes" => "notes"
      }.freeze

      def load_file(path)
        text = File.read(path, encoding: "UTF-8")
        data = IOSBuild::Config.safe_yaml_load(text)
        raise MetadataError, "App Store metadata root must be a mapping" unless data.is_a?(Hash)

        normalized = IOSBuild::Config.stringify_keys(data)
        validate!(normalized)
        normalized
      rescue Errno::ENOENT
        raise MetadataError, "App Store metadata file does not exist: #{path}"
      rescue Psych::Exception => e
        raise MetadataError, "invalid App Store metadata YAML: #{e.message}"
      end

      def validate!(data)
        errors = []
        unknown = data.keys - ROOT_KEYS
        errors << "App Store metadata contains unknown keys: #{unknown.join(', ')}" unless unknown.empty?

        optional_string(data, "copyright", "copyright", errors)
        optional_boolean(data, "uses_idfa", "uses_idfa", errors)
        optional_boolean(data, "uses_non_exempt_encryption", "uses_non_exempt_encryption", errors)

        app_info_localizations = data["app_info_localizations"]
        if app_info_localizations
          validate_localization_mapping(
            app_info_localizations,
            "app_info_localizations",
            APP_INFO_LOCALIZATION_KEYS,
            errors
          )
          (app_info_localizations.is_a?(Hash) ? app_info_localizations : {}).each do |locale, attributes|
            next unless attributes.is_a?(Hash)

            name = attributes["name"]
            if name && !(2..30).cover?(name.length)
              errors << "app_info_localizations.#{locale}.name must contain 2 to 30 characters"
            end
            subtitle = attributes["subtitle"]
            if subtitle && subtitle.length > 30
              errors << "app_info_localizations.#{locale}.subtitle must contain at most 30 characters"
            end
            %w[privacy_policy_url privacy_choices_url].each do |key|
              validate_url(attributes[key], "app_info_localizations.#{locale}.#{key}", errors) if attributes.key?(key)
            end
          end
        end

        localizations = data["localizations"]
        if localizations
          validate_localization_mapping(localizations, "localizations", LOCALIZATION_KEYS, errors)
          (localizations.is_a?(Hash) ? localizations : {}).each do |locale, attributes|
            next unless attributes.is_a?(Hash)

            if attributes.key?("whats_new") && attributes["whats_new"].to_s.strip.empty?
              errors << "localizations.#{locale}.whats_new must be a non-empty string when declared"
            end
            %w[marketing_url support_url].each do |key|
              validate_url(attributes[key], "localizations.#{locale}.#{key}", errors) if attributes.key?(key)
            end
          end
        end

        review_detail = data["review_detail"]
        if review_detail
          unless review_detail.is_a?(Hash)
            errors << "review_detail must be a mapping"
          else
            review_unknown = review_detail.keys - REVIEW_DETAIL_KEYS
            errors << "review_detail contains unknown keys: #{review_unknown.join(', ')}" unless review_unknown.empty?
            (REVIEW_DETAIL_KEYS - ["demo_account_required"]).each do |key|
              optional_string(review_detail, key, "review_detail.#{key}", errors)
            end
            optional_boolean(review_detail, "demo_account_required", "review_detail.demo_account_required", errors)
          end
        end

        validate_media(data["media"], errors) if data["media"]

        raise MetadataError, errors.join("\n") unless errors.empty?

        true
      end

      def version_attributes(metadata, automatic_release:)
        attributes = { "releaseType" => automatic_release ? "AFTER_APPROVAL" : "MANUAL" }
        attributes["copyright"] = metadata["copyright"] if metadata.key?("copyright")
        attributes["usesIdfa"] = metadata["uses_idfa"] if metadata.key?("uses_idfa")
        attributes
      end

      def localization_attributes(attributes)
        LOCALIZATION_API_KEYS.each_with_object({}) do |(source, destination), result|
          result[destination] = attributes[source] if attributes.key?(source)
        end
      end

      def app_info_localization_attributes(attributes)
        APP_INFO_LOCALIZATION_API_KEYS.each_with_object({}) do |(source, destination), result|
          result[destination] = attributes[source] if attributes.key?(source)
        end
      end

      def text_changes?(metadata)
        %w[copyright uses_idfa app_info_localizations localizations review_detail].any? do |key|
          value = metadata[key]
          metadata.key?(key) && value != {} && value != []
        end
      end

      def media_changes?(metadata)
        media = metadata["media"]
        media.is_a?(Hash) && !media.empty?
      end

      def validate_requested_changes!(metadata, update_text_metadata:, replace_media:)
        if update_text_metadata && !text_changes?(metadata)
          raise MetadataError, "update_asc_text_metadata=true requires at least one declared text metadata change"
        end
        if replace_media && !media_changes?(metadata)
          raise MetadataError, "replace_asc_media=true requires at least one declared media collection"
        end
        true
      end

      def media_files(metadata)
        return [] unless media_changes?(metadata)

        metadata.fetch("media").flat_map do |_locale, kinds|
          MEDIA_KEYS.flat_map do |kind|
            Hash(kinds[kind]).values.flatten
          end
        end.uniq
      end

      def review_detail_attributes(metadata, demo_account_name:, demo_account_password:)
        review_detail = metadata["review_detail"]
        return nil unless review_detail

        attributes = REVIEW_DETAIL_API_KEYS.each_with_object({}) do |(source, destination), result|
          result[destination] = review_detail[source] if review_detail.key?(source)
        end
        return attributes unless review_detail["demo_account_required"] == true

        if demo_account_name.to_s.empty? || demo_account_password.to_s.empty?
          raise MetadataError, "demo account credentials are required by review_detail but were not provided"
        end
        attributes["demoAccountName"] = demo_account_name
        attributes["demoAccountPassword"] = demo_account_password
        attributes
      end

      def optional_string(mapping, key, path, errors)
        return unless mapping.key?(key)

        value = mapping[key]
        errors << "#{path} must be a string without NUL characters" unless value.is_a?(String) && !value.include?("\0")
      end
      private_class_method :optional_string

      def validate_localization_mapping(mapping, path, allowed_keys, errors)
        unless mapping.is_a?(Hash) && !mapping.empty?
          errors << "#{path} must be a non-empty mapping"
          return
        end

        mapping.each do |locale, attributes|
          locale_path = "#{path}.#{locale}"
          unless locale.is_a?(String) && locale.match?(/\A[a-z]{2,3}(?:-[A-Za-z0-9]{2,8})*\z/)
            errors << "#{locale_path} has an invalid locale"
          end
          unless attributes.is_a?(Hash) && !attributes.empty?
            errors << "#{locale_path} must be a non-empty mapping"
            next
          end
          unknown = attributes.keys - allowed_keys
          errors << "#{locale_path} contains unknown keys: #{unknown.join(', ')}" unless unknown.empty?
          allowed_keys.each { |key| optional_string(attributes, key, "#{locale_path}.#{key}", errors) }
        end
      end
      private_class_method :validate_localization_mapping

      def validate_media(media, errors)
        unless media.is_a?(Hash) && !media.empty?
          errors << "media must be a non-empty mapping"
          return
        end

        media.each do |locale, kinds|
          path = "media.#{locale}"
          unless locale.is_a?(String) && locale.match?(/\A[a-z]{2,3}(?:-[A-Za-z0-9]{2,8})*\z/)
            errors << "#{path} has an invalid locale"
          end
          unless kinds.is_a?(Hash) && !kinds.empty?
            errors << "#{path} must be a non-empty mapping"
            next
          end
          unknown = kinds.keys - MEDIA_KEYS
          errors << "#{path} contains unknown keys: #{unknown.join(', ')}" unless unknown.empty?
          MEDIA_KEYS.each do |kind|
            next unless kinds.key?(kind)

            collections = kinds[kind]
            unless collections.is_a?(Hash) && !collections.empty?
              errors << "#{path}.#{kind} must be a non-empty mapping"
              next
            end
            collections.each do |display_type, files|
              collection_path = "#{path}.#{kind}.#{display_type}"
              unless display_type.is_a?(String) && display_type.match?(/\A[A-Z][A-Z0-9_]*\z/)
                errors << "#{collection_path} has an invalid display type"
              end
              maximum = kind == "screenshots" ? 10 : 3
              unless files.is_a?(Array) && (1..maximum).cover?(files.length)
                errors << "#{collection_path} must contain 1 to #{maximum} files"
                next
              end
              files.each_with_index do |file, index|
                validate_media_path(file, "#{collection_path}[#{index}]", kind, errors)
              end
              duplicates = files.group_by(&:itself).select { |_file, entries| entries.length > 1 }.keys
              errors << "#{collection_path} contains duplicate files: #{duplicates.join(', ')}" unless duplicates.empty?
            end
          end
        end
      end
      private_class_method :validate_media

      def validate_media_path(value, path, kind, errors)
        unless value.is_a?(String) && !value.empty? && !value.include?("\0")
          errors << "#{path} must be a non-empty repository-relative path"
          return
        end
        candidate = Pathname.new(value)
        if candidate.absolute? || value.start_with?("~") || candidate.each_filename.any? { |part| part == ".." } ||
           candidate.cleanpath.to_s != value
          errors << "#{path} must be a normalized repository-relative path"
          return
        end
        extensions = kind == "screenshots" ? %w[.png .jpg .jpeg] : %w[.mov .mp4 .m4v]
        unless extensions.include?(File.extname(value).downcase)
          errors << "#{path} must use one of: #{extensions.join(', ')}"
        end
      end
      private_class_method :validate_media_path

      def optional_boolean(mapping, key, path, errors)
        return unless mapping.key?(key)

        value = mapping[key]
        errors << "#{path} must be a boolean" unless value == true || value == false
      end
      private_class_method :optional_boolean

      def validate_url(value, path, errors)
        return unless value.is_a?(String)

        uri = URI.parse(value)
        errors << "#{path} must be an absolute HTTP(S) URL" unless %w[http https].include?(uri.scheme) && uri.host
      rescue URI::InvalidURIError
        errors << "#{path} must be an absolute HTTP(S) URL"
      end
      private_class_method :validate_url
    end
  end
end
