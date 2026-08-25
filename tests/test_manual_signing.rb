# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "open3"
require "fileutils"
require "tmpdir"

class ManualSigningTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  CONFIG = File.join(__dir__, "fixtures/config/valid.yml")
  PROFILE_MAP = File.join(__dir__, "fixtures/config/profile-map.json")
  PREPARER = File.join(ROOT, "scripts/prepare-manual-signing.rb")
  IDENTITY = "A" * 40

  def test_configured_targets_receive_their_own_manual_signing_profiles
    skip "macOS plutil is required" unless File.executable?("/usr/bin/plutil")

    Dir.mktmpdir do |workspace|
      project = write_project(workspace)
      stdout, stderr, status = Open3.capture3(
        "ruby", PREPARER,
        "--config", CONFIG,
        "--profile-map", PROFILE_MAP,
        "--identity", IDENTITY,
        "--workspace", workspace
      )
      assert status.success?, [stdout, stderr].join("\n")
      assert_includes stdout, "Configured manual signing for targets: ExampleApp, ExampleWidget"

      objects = plist_objects(project)
      assert_signing_settings(objects.fetch("APP_RELEASE").fetch("buildSettings"), "11111111-1111-1111-1111-111111111111")
      assert_signing_settings(objects.fetch("WIDGET_RELEASE").fetch("buildSettings"), "22222222-2222-2222-2222-222222222222")
    end
  end

  private

  def write_project(workspace)
    ios_directory = File.join(workspace, "Hearthio/ios")
    FileUtils.mkdir_p(File.join(ios_directory, "Runner.xcworkspace"))
    project_directory = File.join(ios_directory, "Runner.xcodeproj")
    FileUtils.mkdir_p(project_directory)
    project = File.join(project_directory, "project.pbxproj")
    File.write(project, <<~PBXPROJ)
      {
        archiveVersion = 1;
        classes = {};
        objectVersion = 54;
        objects = {
          APP_TARGET /* ExampleApp */ = {
            isa = PBXNativeTarget;
            buildConfigurationList = APP_CONFIG_LIST;
            name = ExampleApp;
          };
          APP_CONFIG_LIST /* Build configuration list for PBXNativeTarget "ExampleApp" */ = {
            isa = XCConfigurationList;
            buildConfigurations = (APP_RELEASE,);
          };
          APP_RELEASE /* Release */ = {
            isa = XCBuildConfiguration;
            buildSettings = {
              CODE_SIGN_STYLE = Automatic;
              DEVELOPMENT_TEAM = OLDTEAM123;
            };
            name = Release;
          };
          WIDGET_TARGET /* ExampleWidget */ = {
            isa = PBXNativeTarget;
            buildConfigurationList = WIDGET_CONFIG_LIST;
            name = ExampleWidget;
          };
          WIDGET_CONFIG_LIST /* Build configuration list for PBXNativeTarget "ExampleWidget" */ = {
            isa = XCConfigurationList;
            buildConfigurations = (WIDGET_RELEASE,);
          };
          WIDGET_RELEASE /* Release */ = {
            isa = XCBuildConfiguration;
            buildSettings = {
              CODE_SIGN_STYLE = Automatic;
            };
            name = Release;
          };
        };
        rootObject = APP_TARGET;
      }
    PBXPROJ
    project
  end

  def plist_objects(project)
    stdout, stderr, status = Open3.capture3("/usr/bin/plutil", "-convert", "json", "-o", "-", "--", project)
    assert status.success?, stderr
    JSON.parse(stdout).fetch("objects")
  end

  def assert_signing_settings(settings, profile_uuid)
    assert_equal "Manual", settings.fetch("CODE_SIGN_STYLE")
    assert_equal "ABCDE12345", settings.fetch("DEVELOPMENT_TEAM")
    assert_equal IDENTITY, settings.fetch("CODE_SIGN_IDENTITY")
    assert_equal IDENTITY, settings.fetch("CODE_SIGN_IDENTITY[sdk=iphoneos*]")
    assert_equal profile_uuid, settings.fetch("PROVISIONING_PROFILE")
    assert_equal profile_uuid, settings.fetch("PROVISIONING_PROFILE_SPECIFIER")
  end
end
