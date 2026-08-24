#!/usr/bin/env bash
set -euo pipefail

: "${IOS_BUILD_ACTION_PATH:?IOS_BUILD_ACTION_PATH is required}"
: "${IOS_CONFIG_PATH:?IOS_CONFIG_PATH is required}"
: "${IOS_MARKETING_VERSION:?IOS_MARKETING_VERSION is required}"
: "${IOS_UPLOAD_TO_ASC:?IOS_UPLOAD_TO_ASC is required}"
: "${IOS_BUILD_OUTPUT_DIR:?IOS_BUILD_OUTPUT_DIR is required}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "The build-upload action requires a macOS runner" >&2
  exit 1
fi

for command_name in git ruby python3 security codesign openssl xcodebuild xcrun plutil unzip ditto shasum tar base64; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Required command is unavailable: $command_name" >&2
    exit 1
  fi
done

ruby "${IOS_BUILD_ACTION_PATH}/scripts/validate-config.rb" "$IOS_CONFIG_PATH"
ruby "${IOS_BUILD_ACTION_PATH}/scripts/preflight.rb" \
  --config "$IOS_CONFIG_PATH" \
  --marketing-version "$IOS_MARKETING_VERSION" \
  --build-number "${IOS_BUILD_NUMBER:-}" \
  --upload-to-asc "$IOS_UPLOAD_TO_ASC" \
  --metadata "${IOS_BUILD_OUTPUT_DIR}/build-metadata.json" \
  --github-output "$GITHUB_OUTPUT"

xcode_path="$(ruby "${IOS_BUILD_ACTION_PATH}/scripts/config-value.rb" "$IOS_CONFIG_PATH" build.xcode_path)"
export DEVELOPER_DIR="${xcode_path}/Contents/Developer"
xcodebuild -version
xcrun --sdk iphoneos --show-sdk-version
