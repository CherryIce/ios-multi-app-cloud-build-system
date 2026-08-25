#!/usr/bin/env bash
set -euo pipefail

: "${IOS_BUILD_ACTION_PATH:?IOS_BUILD_ACTION_PATH is required}"
: "${IOS_CONFIG_PATH:?IOS_CONFIG_PATH is required}"
: "${IOS_MARKETING_VERSION:?IOS_MARKETING_VERSION is required}"
: "${IOS_RESOLVED_BUILD_NUMBER:?IOS_RESOLVED_BUILD_NUMBER is required}"
: "${IOS_BUILD_WORK_DIR:?IOS_BUILD_WORK_DIR is required}"
: "${IOS_BUILD_OUTPUT_DIR:?IOS_BUILD_OUTPUT_DIR is required}"
: "${IOS_BUILD_LOGS_DIR:?IOS_BUILD_LOGS_DIR is required}"
: "${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is required}"
: "${GITHUB_ENV:?GITHUB_ENV is required}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"

config_value() {
  ruby "${IOS_BUILD_ACTION_PATH}/scripts/config-value.rb" "$IOS_CONFIG_PATH" "$1"
}

container_type="$(config_value build.container_type)"
container_path="$(config_value build.container_path)"
scheme="$(config_value build.scheme)"
configuration="$(config_value build.configuration)"
xcode_path="$(config_value build.xcode_path)"
team_id="$(config_value app.team_id)"
export DEVELOPER_DIR="${xcode_path}/Contents/Developer"

archive_path="${IOS_BUILD_WORK_DIR}/App.xcarchive"
derived_data_path="${IOS_BUILD_WORK_DIR}/DerivedData"
result_path="${IOS_BUILD_OUTPUT_DIR}/archive.xcresult"
archive_log="${IOS_BUILD_LOGS_DIR}/archive.log"
container_flag="-${container_type}"

cd "$GITHUB_WORKSPACE"
set -o pipefail
xcodebuild \
  "$container_flag" "$container_path" \
  -scheme "$scheme" \
  -configuration "$configuration" \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$derived_data_path" \
  -archivePath "$archive_path" \
  -resultBundlePath "$result_path" \
  MARKETING_VERSION="$IOS_MARKETING_VERSION" \
  CURRENT_PROJECT_VERSION="$IOS_RESOLVED_BUILD_NUMBER" \
  FLUTTER_BUILD_NAME="$IOS_MARKETING_VERSION" \
  FLUTTER_BUILD_NUMBER="$IOS_RESOLVED_BUILD_NUMBER" \
  DEVELOPMENT_TEAM="$team_id" \
  CODE_SIGN_IDENTITY="Apple Distribution" \
  archive 2>&1 | tee "$archive_log"

test -f "${archive_path}/Info.plist"
app_count="$(find "${archive_path}/Products/Applications" -maxdepth 1 -type d -name '*.app' | wc -l | tr -d ' ')"
if [[ "$app_count" != "1" ]]; then
  echo "Archive must contain exactly one primary app, found $app_count" >&2
  exit 1
fi

echo "IOS_ARCHIVE_PATH=$archive_path" >> "$GITHUB_ENV"
echo "archive_path=$archive_path" >> "$GITHUB_OUTPUT"
echo "Archive completed: $archive_path"
