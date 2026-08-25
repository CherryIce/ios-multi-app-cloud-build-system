# frozen_string_literal: true

require "json"
require "pathname"
require "yaml"

module IOSBuild
  class ConfigError < StandardError; end

  module Config
    module_function

    SCHEMA_VERSION = 2
    TOP_LEVEL_KEYS = %w[schema_version release app flutter build versioning export upload artifacts].freeze
    RELEASE_KEYS = %w[allowed_events allowed_ref_patterns].freeze
    APP_KEYS = %w[name team_id asc_app_id primary_bundle_id bundle_ids].freeze
    BUNDLE_KEYS = %w[bundle_id target profile_alias].freeze
    FLUTTER_KEYS = %w[project_directory version channel architecture sdk_sha256].freeze
    BUILD_KEYS = %w[
      container_type container_path scheme configuration runner xcode_path
      dependency_mode dependency_command
    ].freeze
    VERSIONING_KEYS = %w[
      marketing_version_source build_number_strategy build_number_override_allowed
    ].freeze
    EXPORT_KEYS = %w[method upload_symbols strip_swift_symbols].freeze
    UPLOAD_KEYS = %w[
      enabled_by_default asc_key_type wait_level timeout_minutes poll_interval_seconds
      internal_beta_group_ids
    ].freeze
    ARTIFACT_KEYS = %w[retention_days keep_xcarchive].freeze

    BUNDLE_ID_PATTERN = /\A[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+\z/
    TEAM_ID_PATTERN = /\A[A-Z0-9]{10}\z/
    ASC_ID_PATTERN = /\A\d+\z/
    SAFE_NAME_PATTERN = /\A[A-Za-z0-9_.+ -]+\z/

    def load_file(path, validate: true)
      text = File.read(path, encoding: "UTF-8")
      data = safe_yaml_load(text)
      raise ConfigError, "configuration root must be a mapping" unless data.is_a?(Hash)

      normalized = stringify_keys(data)
      validate!(normalized) if validate
      normalized
    rescue Errno::ENOENT
      raise ConfigError, "configuration file does not exist: #{path}"
    rescue Psych::Exception => e
      raise ConfigError, "invalid YAML: #{e.message}"
    end

    def safe_yaml_load(text)
      YAML.safe_load(
        text,
        permitted_classes: [],
        permitted_symbols: [],
        aliases: false
      )
    rescue ArgumentError
      YAML.safe_load(text, [], [], false)
    end

    def stringify_keys(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, child), result|
          result[key.to_s] = stringify_keys(child)
        end
      when Array
        value.map { |child| stringify_keys(child) }
      else
        value
      end
    end

    def validate!(data)
      errors = []
      exact_keys(data, TOP_LEVEL_KEYS, "root", errors)
      integer_value(data, "schema_version", "root", errors, allowed: [SCHEMA_VERSION])

      release = mapping(data, "release", "root", errors)
      app = mapping(data, "app", "root", errors)
      flutter = mapping(data, "flutter", "root", errors)
      build = mapping(data, "build", "root", errors)
      versioning = mapping(data, "versioning", "root", errors)
      export = mapping(data, "export", "root", errors)
      upload = mapping(data, "upload", "root", errors)
      artifacts = mapping(data, "artifacts", "root", errors)

      validate_release(release, errors) if release
      validate_app(app, errors) if app
      validate_flutter(flutter, errors) if flutter
      validate_build(build, errors) if build
      validate_flutter_build_paths(flutter, build, errors) if flutter && build
      validate_versioning(versioning, errors) if versioning
      validate_export(export, errors) if export
      validate_upload(upload, errors) if upload
      validate_artifacts(artifacts, errors) if artifacts

      raise ConfigError, errors.join("\n") unless errors.empty?

      true
    end

    def validate_flutter(flutter, errors)
      exact_keys(flutter, FLUTTER_KEYS, "flutter", errors)
      project_directory = string_value(flutter, "project_directory", "flutter", errors)
      validate_relative_path(project_directory, "flutter.project_directory", errors)
      string_value(flutter, "version", "flutter", errors, pattern: /\A\d+\.\d+\.\d+\z/)
      string_value(flutter, "channel", "flutter", errors, allowed: %w[stable])
      string_value(flutter, "architecture", "flutter", errors, allowed: %w[arm64 x64])
      string_value(flutter, "sdk_sha256", "flutter", errors, pattern: /\A[0-9a-f]{64}\z/)
    end

    def validate_release(release, errors)
      exact_keys(release, RELEASE_KEYS, "release", errors)
      events = string_array(release, "allowed_events", "release", errors, min_items: 1)
      patterns = string_array(release, "allowed_ref_patterns", "release", errors, min_items: 1)

      allowed_events = %w[workflow_dispatch push]
      Array(events).each do |event|
        errors << "release.allowed_events contains unsupported event: #{event}" unless allowed_events.include?(event)
      end
      duplicate_values(Array(events), "allowed event", errors)
      Array(patterns).each do |pattern|
        unless pattern.start_with?("refs/heads/", "refs/tags/") && !pattern.include?("\n")
          errors << "release.allowed_ref_patterns contains an invalid ref pattern: #{pattern}"
        end
      end
      duplicate_values(Array(patterns), "allowed ref pattern", errors)
    end

    def validate_app(app, errors)
      exact_keys(app, APP_KEYS, "app", errors)
      string_value(app, "name", "app", errors, pattern: SAFE_NAME_PATTERN)
      string_value(app, "team_id", "app", errors, pattern: TEAM_ID_PATTERN)
      string_value(app, "asc_app_id", "app", errors, pattern: ASC_ID_PATTERN)
      primary = string_value(app, "primary_bundle_id", "app", errors, pattern: BUNDLE_ID_PATTERN)

      bundles = app["bundle_ids"]
      unless bundles.is_a?(Array) && !bundles.empty?
        errors << "app.bundle_ids must be a non-empty array"
        return
      end

      bundle_ids = []
      aliases = []
      targets = []
      bundles.each_with_index do |bundle, index|
        path = "app.bundle_ids[#{index}]"
        unless bundle.is_a?(Hash)
          errors << "#{path} must be a mapping"
          next
        end
        exact_keys(bundle, BUNDLE_KEYS, path, errors)
        bundle_ids << string_value(bundle, "bundle_id", path, errors, pattern: BUNDLE_ID_PATTERN)
        targets << string_value(bundle, "target", path, errors, pattern: SAFE_NAME_PATTERN)
        aliases << string_value(bundle, "profile_alias", path, errors, pattern: /\A[a-z0-9][a-z0-9_-]*\z/)
      end

      duplicate_values(bundle_ids, "bundle ID", errors)
      duplicate_values(aliases, "profile alias", errors)
      duplicate_values(targets, "target", errors)
      errors << "app.primary_bundle_id must appear exactly once in app.bundle_ids" if primary && bundle_ids.count(primary) != 1
    end

    def validate_build(build, errors)
      exact_keys(build, BUILD_KEYS, "build", errors)
      container_type = string_value(build, "container_type", "build", errors, allowed: %w[workspace project])
      container_path = string_value(build, "container_path", "build", errors)
      validate_relative_path(container_path, "build.container_path", errors)
      if container_type == "workspace" && container_path && !container_path.end_with?(".xcworkspace")
        errors << "build.container_path must end in .xcworkspace for workspace builds"
      elsif container_type == "project" && container_path && !container_path.end_with?(".xcodeproj")
        errors << "build.container_path must end in .xcodeproj for project builds"
      end
      string_value(build, "scheme", "build", errors, pattern: SAFE_NAME_PATTERN)
      string_value(build, "configuration", "build", errors, pattern: SAFE_NAME_PATTERN)
      string_value(build, "runner", "build", errors, pattern: /\A[A-Za-z0-9_.-]+\z/)
      xcode_path = string_value(build, "xcode_path", "build", errors)
      unless xcode_path&.match?(%r{\A/Applications/Xcode[^/]*\.app\z})
        errors << "build.xcode_path must be an absolute Xcode app path under /Applications"
      end
      dependency_mode = string_value(
        build,
        "dependency_mode",
        "build",
        errors,
        allowed: %w[flutter]
      )
      command = string_value(build, "dependency_command", "build", errors, allow_empty: true)
      errors << "build.dependency_command must be empty on the Flutter branch" unless command.to_s.empty?
      errors << "build.dependency_mode must be flutter on the Flutter branch" if dependency_mode && dependency_mode != "flutter"
    end

    def validate_flutter_build_paths(flutter, build, errors)
      project_directory = flutter["project_directory"]
      container_path = build["container_path"]
      return unless project_directory.is_a?(String) && container_path.is_a?(String)

      return if project_directory == "."

      prefix = "#{project_directory}/"
      unless container_path.start_with?(prefix)
        errors << "build.container_path must be inside flutter.project_directory"
      end
    end

    def validate_versioning(versioning, errors)
      exact_keys(versioning, VERSIONING_KEYS, "versioning", errors)
      string_value(versioning, "marketing_version_source", "versioning", errors, allowed: %w[input])
      string_value(
        versioning,
        "build_number_strategy",
        "versioning",
        errors,
        allowed: %w[github_run_number asc_increment]
      )
      boolean_value(versioning, "build_number_override_allowed", "versioning", errors)
    end

    def validate_export(export, errors)
      exact_keys(export, EXPORT_KEYS, "export", errors)
      string_value(export, "method", "export", errors, allowed: %w[app-store-connect app-store])
      boolean_value(export, "upload_symbols", "export", errors)
      boolean_value(export, "strip_swift_symbols", "export", errors)
    end

    def validate_upload(upload, errors)
      exact_keys(upload, UPLOAD_KEYS, "upload", errors)
      boolean_value(upload, "enabled_by_default", "upload", errors)
      string_value(upload, "asc_key_type", "upload", errors, allowed: %w[team])
      string_value(
        upload,
        "wait_level",
        "upload",
        errors,
        allowed: %w[upload_accepted asc_appeared processing_complete testflight_internal_ready]
      )
      integer_value(upload, "timeout_minutes", "upload", errors, range: 1..180)
      integer_value(upload, "poll_interval_seconds", "upload", errors, range: 10..300)
      groups = string_array(upload, "internal_beta_group_ids", "upload", errors, min_items: 0)
      duplicate_values(Array(groups), "internal beta group ID", errors)
      Array(groups).each do |group_id|
        errors << "upload.internal_beta_group_ids contains an invalid ID: #{group_id}" unless group_id.match?(/\A[A-Za-z0-9-]+\z/)
      end
      if groups && !groups.empty? && upload["wait_level"] != "testflight_internal_ready"
        errors << "upload.wait_level must be testflight_internal_ready when internal beta groups are configured"
      end
    end

    def validate_artifacts(artifacts, errors)
      exact_keys(artifacts, ARTIFACT_KEYS, "artifacts", errors)
      integer_value(artifacts, "retention_days", "artifacts", errors, range: 1..90)
      boolean_value(artifacts, "keep_xcarchive", "artifacts", errors)
    end

    def exact_keys(mapping, allowed, path, errors)
      return unless mapping.is_a?(Hash)

      unknown = mapping.keys - allowed
      missing = allowed - mapping.keys
      errors << "#{path} contains unknown keys: #{unknown.join(', ')}" unless unknown.empty?
      errors << "#{path} is missing required keys: #{missing.join(', ')}" unless missing.empty?
    end

    def mapping(parent, key, path, errors)
      value = parent[key]
      unless value.is_a?(Hash)
        errors << "#{path}.#{key} must be a mapping"
        return nil
      end
      value
    end

    def string_value(parent, key, path, errors, allowed: nil, pattern: nil, allow_empty: false)
      value = parent[key]
      unless value.is_a?(String) && (allow_empty || !value.empty?) && !value.include?("\n")
        errors << "#{path}.#{key} must be #{allow_empty ? 'a string' : 'a non-empty single-line string'}"
        return nil
      end
      errors << "#{path}.#{key} must be one of: #{allowed.join(', ')}" if allowed && !allowed.include?(value)
      errors << "#{path}.#{key} has an invalid format" if pattern && !value.match?(pattern)
      value
    end

    def boolean_value(parent, key, path, errors)
      value = parent[key]
      errors << "#{path}.#{key} must be a boolean" unless value == true || value == false
      value
    end

    def integer_value(parent, key, path, errors, allowed: nil, range: nil)
      value = parent[key]
      unless value.is_a?(Integer)
        errors << "#{path}.#{key} must be an integer"
        return nil
      end
      errors << "#{path}.#{key} must be one of: #{allowed.join(', ')}" if allowed && !allowed.include?(value)
      errors << "#{path}.#{key} must be within #{range}" if range && !range.cover?(value)
      value
    end

    def string_array(parent, key, path, errors, min_items:)
      value = parent[key]
      unless value.is_a?(Array) && value.length >= min_items && value.all? { |item| item.is_a?(String) && !item.empty? && !item.include?("\n") }
        errors << "#{path}.#{key} must be an array of non-empty single-line strings"
        return nil
      end
      value
    end

    def validate_relative_path(value, path, errors)
      return unless value

      components = value.split("/")
      clean_path = Pathname.new(value).cleanpath.to_s
      if value.start_with?("/", "~") || components.include?("..") || components.include?("") ||
         value.include?("\0") || clean_path != value
        errors << "#{path} must be a normalized repository-relative path"
      end
    end

    def duplicate_values(values, label, errors)
      duplicates = values.compact.group_by(&:itself).select { |_value, matches| matches.length > 1 }.keys
      errors << "duplicate #{label} values: #{duplicates.join(', ')}" unless duplicates.empty?
    end

    def dig(data, dotted_path)
      dotted_path.split(".").reduce(data) do |value, key|
        raise ConfigError, "missing configuration value: #{dotted_path}" unless value.is_a?(Hash) && value.key?(key)

        value[key]
      end
    end
  end
end
