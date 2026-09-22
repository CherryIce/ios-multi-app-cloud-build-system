# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "open3"
require "tmpdir"
require_relative "../scripts/lib/config"

class ConfigTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  VALID = File.join(__dir__, "fixtures/config/valid.yml")
  INVALID = File.join(__dir__, "fixtures/config/invalid.yml")

  def test_valid_fixture_passes_runtime_validator
    config = IOSBuild::Config.load_file(VALID)
    assert_equal "com.example.app", IOSBuild::Config.dig(config, "app.primary_bundle_id")
    assert_equal "github_run_number", IOSBuild::Config.dig(config, "versioning.build_number_strategy")
    assert_equal true, IOSBuild::Config.dig(config, "app_store.automatic_release")
  end

  def test_invalid_fixture_fails_closed
    error = assert_raises(IOSBuild::ConfigError) { IOSBuild::Config.load_file(INVALID) }
    assert_includes error.message, "unexpected"
    assert_includes error.message, "normalized repository-relative path"
    assert_includes error.message, "testflight_internal_ready"
  end

  def test_schema_and_runtime_required_top_level_keys_match
    schema_path = File.join(ROOT, "schemas/ios-build-config.schema.json")
    schema = JSON.parse(File.read(schema_path))
    assert_equal IOSBuild::Config::REQUIRED_TOP_LEVEL_KEYS.sort, schema.fetch("required").sort
    assert_equal IOSBuild::Config::TOP_LEVEL_KEYS.sort, schema.fetch("properties").keys.sort
    assert_equal IOSBuild::Config::SCHEMA_VERSION, schema.dig("properties", "schema_version", "const")
  end

  def test_app_store_section_is_backward_compatible_when_absent
    config = IOSBuild::Config.load_file(VALID, validate: false)
    config.delete("app_store")

    assert IOSBuild::Config.validate!(config)
    assert_equal false, IOSBuild::Config.optional_dig(config, "app_store.enabled", false)
  end

  def test_flutter_configuration_is_required_only_for_flutter_dependencies
    config = IOSBuild::Config.load_file(VALID, validate: false)
    config["build"]["dependency_mode"] = "flutter"

    error = assert_raises(IOSBuild::ConfigError) { IOSBuild::Config.validate!(config) }
    assert_includes error.message, "root.flutter is required"

    config["flutter"] = {
      "project_directory" => "apps/example",
      "version" => "3.35.7",
      "channel" => "stable",
      "architecture" => "arm64",
      "sdk_sha256" => "4d7aaadc4893f9216d4e2ecbe0e8fb4213e9bd49d29fd5f441f34fcc05758e2b"
    }
    config["build"]["container_path"] = "apps/example/ios/Runner.xcworkspace"

    assert IOSBuild::Config.validate!(config)
  end

  def test_app_store_requires_processing_complete_wait_level
    config = IOSBuild::Config.load_file(VALID, validate: false)
    config["upload"]["wait_level"] = "asc_appeared"

    error = assert_raises(IOSBuild::ConfigError) { IOSBuild::Config.validate!(config) }
    assert_includes error.message, "processing_complete or testflight_internal_ready"
  end

  def test_runtime_rejects_duplicate_release_and_group_values
    config = IOSBuild::Config.load_file(VALID, validate: false)
    config["release"]["allowed_events"] = %w[workflow_dispatch workflow_dispatch]
    config["upload"]["internal_beta_group_ids"] = %w[group-1 group-1]

    error = assert_raises(IOSBuild::ConfigError) { IOSBuild::Config.validate!(config) }
    assert_includes error.message, "duplicate allowed event"
    assert_includes error.message, "duplicate internal beta group ID"
  end

  def test_export_options_are_generated_from_profile_map
    Dir.mktmpdir do |directory|
      output = File.join(directory, "ExportOptions.plist")
      script = File.join(ROOT, "scripts/make-export-options.rb")
      profile_map = File.join(__dir__, "fixtures/config/profile-map.json")
      stdout, stderr, status = Open3.capture3(
        "ruby", script,
        "--config", VALID,
        "--profile-map", profile_map,
        "--identity", "A" * 40,
        "--output", output
      )
      assert status.success?, [stdout, stderr].join("\n")
      plist = File.read(output)
      assert_includes plist, "<string>app-store-connect</string>"
      assert_includes plist, "<key>com.example.app.widget</key>"
      assert_includes plist, "<string>Example Widget App Store Profile</string>"
      assert_includes plist, "<key>signingCertificate</key>\n  <string>#{'A' * 40}</string>"
    end
  end
end
