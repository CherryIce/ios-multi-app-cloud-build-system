# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "open3"
require "tmpdir"
require "yaml"

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

  def test_app_repository_config_matches_runtime_contract
    config_path = File.join(ROOT, "examples/app-repository/.github/ios-build.yml")
    script_path = File.join(ROOT, "scripts/validate-config.rb")
    assert system("ruby", script_path, config_path, out: File::NULL)
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
