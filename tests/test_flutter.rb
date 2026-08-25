# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "open3"
require "tmpdir"

class FlutterContractTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  CONFIG = File.join(__dir__, "fixtures/config/valid.yml")
  PROFILE_MAP = File.join(__dir__, "fixtures/config/profile-map.json")
  IDENTITY = "A" * 40

  def test_dependencies_run_from_nested_flutter_project
    Dir.mktmpdir do |directory|
      workspace = File.join(directory, "workspace")
      logs = File.join(directory, "logs")
      bin = File.join(directory, "bin")
      project = File.join(workspace, "Hearthio")
      FileUtils.mkdir_p([logs, bin, project])
      File.write(File.join(project, "pubspec.lock"), "packages: {}\n")

      pwd_capture = File.join(directory, "flutter-pwd.txt")
      args_capture = File.join(directory, "flutter-args.txt")
      write_executable(File.join(bin, "flutter"), <<~SH)
        #!/usr/bin/env bash
        pwd > "#{pwd_capture}"
        printf '%s\n' "$*" > "#{args_capture}"
      SH

      system("git", "-C", workspace, "init", "-q")
      system("git", "-C", workspace, "add", "Hearthio/pubspec.lock")

      stdout, stderr, status = Open3.capture3(
        {
          "IOS_BUILD_ACTION_PATH" => ROOT,
          "IOS_CONFIG_PATH" => CONFIG,
          "IOS_BUILD_LOGS_DIR" => logs,
          "IOS_FLUTTER_VERSION" => "3.35.7",
          "GITHUB_WORKSPACE" => workspace,
          "PATH" => "#{bin}:#{ENV.fetch('PATH')}"
        },
        "bash", File.join(ROOT, "scripts/install-dependencies.sh")
      )

      assert status.success?, [stdout, stderr].join("\n")
      assert_equal File.realpath(project), File.read(pwd_capture).strip
      assert_equal "pub get", File.read(args_capture).strip
    end
  end

  def test_archive_passes_flutter_and_native_version_variables
    Dir.mktmpdir do |directory|
      workspace = File.join(directory, "workspace")
      work = File.join(directory, "work")
      output = File.join(directory, "output")
      logs = File.join(directory, "logs")
      bin = File.join(directory, "bin")
      FileUtils.mkdir_p([workspace, work, output, logs, bin])
      write_signable_project(workspace)

      args_capture = File.join(directory, "xcodebuild-args.txt")
      write_executable(File.join(bin, "xcodebuild"), <<~SH)
        #!/usr/bin/env bash
        printf '%s\n' "$@" > "#{args_capture}"
        archive_path=""
        while [[ "$#" -gt 0 ]]; do
          if [[ "$1" == "-archivePath" ]]; then
            shift
            archive_path="$1"
          fi
          shift
        done
        mkdir -p "$archive_path/Products/Applications/Runner.app"
        touch "$archive_path/Info.plist"
      SH

      github_env = File.join(directory, "github-env")
      github_output = File.join(directory, "github-output")
      stdout, stderr, status = Open3.capture3(
        {
          "IOS_BUILD_ACTION_PATH" => ROOT,
          "IOS_CONFIG_PATH" => CONFIG,
          "IOS_PROFILE_MAP_PATH" => PROFILE_MAP,
          "IOS_CODE_SIGN_IDENTITY" => IDENTITY,
          "IOS_MARKETING_VERSION" => "1.2.3",
          "IOS_RESOLVED_BUILD_NUMBER" => "42",
          "IOS_BUILD_WORK_DIR" => work,
          "IOS_BUILD_OUTPUT_DIR" => output,
          "IOS_BUILD_LOGS_DIR" => logs,
          "GITHUB_WORKSPACE" => workspace,
          "GITHUB_ENV" => github_env,
          "GITHUB_OUTPUT" => github_output,
          "PATH" => "#{bin}:#{ENV.fetch('PATH')}"
        },
        "bash", File.join(ROOT, "scripts/archive.sh")
      )

      assert status.success?, [stdout, stderr].join("\n")
      arguments = File.readlines(args_capture, chomp: true)
      assert_includes arguments, "MARKETING_VERSION=1.2.3"
      assert_includes arguments, "CURRENT_PROJECT_VERSION=42"
      assert_includes arguments, "FLUTTER_BUILD_NAME=1.2.3"
      assert_includes arguments, "FLUTTER_BUILD_NUMBER=42"
      refute arguments.any? { |argument| argument.start_with?("DEVELOPMENT_TEAM=") }
      refute arguments.any? { |argument| argument.start_with?("CODE_SIGN_IDENTITY=") }
    end
  end

  private

  def write_executable(path, contents)
    File.write(path, contents)
    FileUtils.chmod(0o755, path)
  end

  def write_signable_project(workspace)
    ios_directory = File.join(workspace, "Hearthio/ios")
    FileUtils.mkdir_p(File.join(ios_directory, "Runner.xcworkspace"))
    project_directory = File.join(ios_directory, "Runner.xcodeproj")
    FileUtils.mkdir_p(project_directory)
    File.write(File.join(project_directory, "project.pbxproj"), <<~PBXPROJ)
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
  end
end
