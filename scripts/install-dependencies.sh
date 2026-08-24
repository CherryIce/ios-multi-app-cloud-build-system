#!/usr/bin/env bash
set -euo pipefail

: "${IOS_BUILD_ACTION_PATH:?IOS_BUILD_ACTION_PATH is required}"
: "${IOS_CONFIG_PATH:?IOS_CONFIG_PATH is required}"
: "${IOS_BUILD_LOGS_DIR:?IOS_BUILD_LOGS_DIR is required}"
: "${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is required}"

config_value() {
  ruby "${IOS_BUILD_ACTION_PATH}/scripts/config-value.rb" "$IOS_CONFIG_PATH" "$1"
}

require_tracked_file() {
  local path="$1"
  test -f "$path" || { echo "$path must exist" >&2; exit 1; }
  git ls-files --error-unmatch -- "$path" >/dev/null 2>&1 || {
    echo "$path must be committed" >&2
    exit 1
  }
}

mode="$(config_value build.dependency_mode)"
container_type="$(config_value build.container_type)"
container_path="$(config_value build.container_path)"
scheme="$(config_value build.scheme)"
xcode_path="$(config_value build.xcode_path)"
export DEVELOPER_DIR="${xcode_path}/Contents/Developer"

cd "$GITHUB_WORKSPACE"

case "$mode" in
  none)
    echo "No dependency installation requested"
    ;;
  cocoapods)
    require_tracked_file Podfile.lock
    if [[ -f Gemfile ]]; then
      require_tracked_file Gemfile.lock
      bundle config set path vendor/bundle
      bundle install --jobs 4 --retry 3
      bundle exec pod install --deployment | tee "${IOS_BUILD_LOGS_DIR}/dependencies.log"
    else
      pod install --deployment | tee "${IOS_BUILD_LOGS_DIR}/dependencies.log"
    fi
    ;;
  spm)
    package_resolved="$(find . -type f -name Package.resolved -print -quit)"
    [[ -n "$package_resolved" ]] || { echo "A committed Package.resolved is required for SPM" >&2; exit 1; }
    require_tracked_file "${package_resolved#./}"
    container_flag="-${container_type}"
    xcodebuild -resolvePackageDependencies \
      "$container_flag" "$container_path" \
      -scheme "$scheme" | tee "${IOS_BUILD_LOGS_DIR}/dependencies.log"
    ;;
  flutter)
    require_tracked_file pubspec.lock
    flutter pub get | tee "${IOS_BUILD_LOGS_DIR}/dependencies.log"
    if [[ -f ios/Podfile ]]; then
      require_tracked_file ios/Podfile.lock
      if [[ -f Gemfile ]]; then
        bundle exec pod install --project-directory=ios --deployment
      else
        pod install --project-directory=ios --deployment
      fi
    fi
    ;;
  custom)
    custom_command="$(config_value build.dependency_command)"
    /bin/bash -euo pipefail -c "$custom_command" | tee "${IOS_BUILD_LOGS_DIR}/dependencies.log"
    ;;
  *)
    echo "Unsupported dependency mode: $mode" >&2
    exit 1
    ;;
esac

if ! git diff --exit-code -- .; then
  echo "Dependency installation modified tracked files; commit the resolved state before release" >&2
  exit 1
fi
