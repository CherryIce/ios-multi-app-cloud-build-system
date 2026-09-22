# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "open3"
require "tmpdir"
require "yaml"
require_relative "../scripts/lib/app_store_metadata"

class ContractTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  ACTION_PATH = File.join(ROOT, ".github/actions/build-upload/action.yml")

  def test_action_references_existing_root_scripts
    action_text = File.read(ACTION_PATH)
    referenced = action_text.scan(%r{scripts/([A-Za-z0-9_.-]+)}).flatten.uniq
    refute_empty referenced
    referenced.each do |filename|
      assert File.file?(File.join(ROOT, "scripts", filename)), "missing scripts/#{filename}"
    end
  end

  def test_external_actions_are_pinned_to_full_commit_shas
    action_text = File.read(ACTION_PATH)
    uses = action_text.scan(/^\s*uses:\s*([^\s#]+)/).flatten
    refute_empty uses
    uses.each do |reference|
      assert_match(/@[0-9a-f]{40}\z/, reference)
    end
  end

  def test_action_metadata_and_workflows_are_yaml
    YAML.load_file(ACTION_PATH)
    yaml_files = [
      *Dir.glob(File.join(ROOT, ".github/workflows/*.{yml,yaml}")),
      *Dir.glob(File.join(ROOT, "examples/**/*.{yml,yaml}")),
      *Dir.glob(File.join(ROOT, "ios-multi-app-cloud-build-system-additions/**/*.{yml,yaml}"))
    ]
    yaml_files.each do |yaml_file|
      YAML.load_file(yaml_file)
    end
  end

  def test_app_store_version_is_prepared_before_processing_wait_and_submission
    action_text = File.read(ACTION_PATH)
    upload = action_text.index("Upload validated IPA to App Store Connect")
    prepare = action_text.index("Create or update App Store version and metadata")
    wait = action_text.index("Wait for App Store Connect processing")
    submit = action_text.index("Attach processed build and optionally submit for review")

    refute_nil upload
    assert_operator upload, :<, prepare
    assert_operator prepare, :<, wait
    assert_operator wait, :<, submit
  end

  def test_processing_wait_receives_the_resolved_build_number
    action = YAML.load_file(ACTION_PATH)
    wait_step = action.fetch("runs").fetch("steps").find do |step|
      step["name"] == "Wait for App Store Connect processing"
    end

    refute_nil wait_step
    assert_equal "${{ steps.resolve.outputs.build_number }}",
                 wait_step.fetch("env").fetch("IOS_RESOLVED_BUILD_NUMBER")
  end

  def test_action_exposes_idempotent_app_store_results
    action = YAML.load_file(ACTION_PATH)
    inputs = action.fetch("inputs")
    outputs = action.fetch("outputs")

    assert_equal "false", inputs.fetch("update_asc_text_metadata").fetch("default")
    assert_equal "false", inputs.fetch("replace_asc_media").fetch("default")

    assert_equal "${{ steps.app_store.outputs.app_store_no_op }}",
                 outputs.fetch("app_store_no_op").fetch("value")
    assert_equal "${{ steps.app_store.outputs.app_store_no_op_reason }}",
                 outputs.fetch("app_store_no_op_reason").fetch("value")
    assert_equal "${{ steps.app_store.outputs.app_store_already_submitted }}",
                 outputs.fetch("app_store_already_submitted").fetch("value")
    assert_equal "${{ steps.app_store.outputs.app_store_already_released }}",
                 outputs.fetch("app_store_already_released").fetch("value")
    assert_equal "${{ steps.app_store.outputs.asc_text_metadata_updated }}",
                 outputs.fetch("asc_text_metadata_updated").fetch("value")
    assert_equal "${{ steps.app_store.outputs.asc_media_replaced }}",
                 outputs.fetch("asc_media_replaced").fetch("value")
  end

  def test_flutter_setup_is_conditionally_restored_for_monorepo_apps
    action = YAML.load_file(ACTION_PATH)
    flutter_step = action.fetch("runs").fetch("steps").find do |step|
      step["name"] == "Install verified Flutter SDK"
    end

    refute_nil flutter_step
    assert_equal "${{ steps.preflight.outputs.dependency_mode == 'flutter' }}", flutter_step["if"]
    assert_includes flutter_step.fetch("run"), "install-flutter.sh"
  end

  def test_app_repository_config_matches_runtime_contract
    config_path = File.join(ROOT, "examples/app-repository/.github/ios-build.yml")
    script_path = File.join(ROOT, "scripts/validate-config.rb")
    assert system("ruby", script_path, config_path, out: File::NULL)
  end

  def test_example_app_store_metadata_matches_runtime_contract_and_has_no_demo_credentials
    metadata_path = File.join(ROOT, "examples/app-repository/.github/app-store-metadata.yml")
    metadata = IOSBuild::ASC::AppStoreMetadata.load_file(metadata_path)
    assert_equal false, metadata["review_detail"]["demo_account_required"]

    text = File.read(metadata_path)
    refute_match(/demo_account_(?:name|password)/, text)
  end

  def test_plist_converter_handles_provisioning_profile_value_types
    Dir.mktmpdir do |directory|
      plist_path = File.join(directory, "profile.plist")
      File.write(plist_path, <<~PLIST)
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict>
          <key>ExpirationDate</key><date>2099-01-01T00:00:00Z</date>
          <key>DeveloperCertificates</key><array><data>AQID</data></array>
        </dict></plist>
      PLIST
      converter = File.join(ROOT, "scripts/plist-to-json.py")
      stdout, stderr, status = Open3.capture3("python3", converter, plist_path)
      assert status.success?, stderr
      data = JSON.parse(stdout)
      assert_equal "2099-01-01T00:00:00Z", data["ExpirationDate"]
      assert_equal ["AQID"], data["DeveloperCertificates"]
    end
  end

  def test_no_secret_material_is_committed
    forbidden = Dir.glob(File.join(ROOT, "**", "*.{p8,p12,mobileprovision}"), File::FNM_DOTMATCH)
    assert_empty forbidden
  end
end
