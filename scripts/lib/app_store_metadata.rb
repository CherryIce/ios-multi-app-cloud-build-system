# frozen_string_literal: true

require "uri"
require_relative "config"

module IOSBuild
  module ASC
    class MetadataError < StandardError; end

    module AppStoreMetadata
      module_function

      ROOT_KEYS = %w[copyright uses_idfa uses_non_exempt_encryption localizations review_detail].freeze
      LOCALIZATION_KEYS = %w[
        description keywords marketing_url promotional_text support_url whats_new
      ].freeze
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

        localizations = data["localizations"]
        unless localizations.is_a?(Hash) && !localizations.empty?
          errors << "localizations must be a non-empty mapping"
        else
          localizations.each do |locale, attributes|
            path = "localizations.#{locale}"
            errors << "#{path} has an invalid locale" unless locale.match?(/\A[a-z]{2,3}(?:-[A-Za-z0-9]{2,8})*\z/)
            unless attributes.is_a?(Hash)
              errors << "#{path} must be a mapping"
              next
            end
            localization_unknown = attributes.keys - LOCALIZATION_KEYS
            errors << "#{path} contains unknown keys: #{localization_unknown.join(', ')}" unless localization_unknown.empty?
            LOCALIZATION_KEYS.each { |key| optional_string(attributes, key, "#{path}.#{key}", errors) }
            whats_new = attributes["whats_new"]
            errors << "#{path}.whats_new must be a non-empty string" unless whats_new.is_a?(String) && !whats_new.strip.empty?
            %w[marketing_url support_url].each do |key|
              validate_url(attributes[key], "#{path}.#{key}", errors) if attributes.key?(key)
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
