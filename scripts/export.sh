#!/usr/bin/env bash
set -euo pipefail

: "${IOS_BUILD_ACTION_PATH:?IOS_BUILD_ACTION_PATH is required}"
: "${IOS_CONFIG_PATH:?IOS_CONFIG_PATH is required}"
: "${IOS_PROFILE_MAP_PATH:?IOS_PROFILE_MAP_PATH is required}"
: "${IOS_CODE_SIGN_IDENTITY:?IOS_CODE_SIGN_IDENTITY is required}"
: "${IOS_ARCHIVE_PATH:?IOS_ARCHIVE_PATH is required}"
: "${IOS_BUILD_WORK_DIR:?IOS_BUILD_WORK_DIR is required}"
: "${IOS_BUILD_OUTPUT_DIR:?IOS_BUILD_OUTPUT_DIR is required}"
: "${IOS_BUILD_LOGS_DIR:?IOS_BUILD_LOGS_DIR is required}"
: "${GITHUB_ENV:?GITHUB_ENV is required}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"

xcode_path="$(ruby "${IOS_BUILD_ACTION_PATH}/scripts/config-value.rb" "$IOS_CONFIG_PATH" build.xcode_path)"
export DEVELOPER_DIR="${xcode_path}/Contents/Developer"
export_options="${IOS_BUILD_WORK_DIR}/ExportOptions.plist"
export_path="${IOS_BUILD_OUTPUT_DIR}/export"
export_log="${IOS_BUILD_LOGS_DIR}/export.log"
mkdir -p "$export_path"

ruby "${IOS_BUILD_ACTION_PATH}/scripts/make-export-options.rb" \
  --config "$IOS_CONFIG_PATH" \
  --profile-map "$IOS_PROFILE_MAP_PATH" \
  --identity "$IOS_CODE_SIGN_IDENTITY" \
  --output "$export_options"
plutil -lint "$export_options"

set -o pipefail
xcodebuild -exportArchive \
  -archivePath "$IOS_ARCHIVE_PATH" \
  -exportPath "$export_path" \
  -exportOptionsPlist "$export_options" 2>&1 | tee "$export_log"

ipa_paths=()
while IFS= read -r -d '' ipa_path; do
  ipa_paths+=("$ipa_path")
done < <(find "$export_path" -maxdepth 1 -type f -name '*.ipa' -print0)

if [[ "${#ipa_paths[@]}" != "1" ]]; then
  echo "Export must produce exactly one IPA, found ${#ipa_paths[@]}" >&2
  exit 1
fi

ipa_path="${ipa_paths[0]}"
ipa_sha256="$(shasum -a 256 "$ipa_path" | awk '{print $1}')"
echo "IOS_IPA_PATH=$ipa_path" >> "$GITHUB_ENV"
echo "IOS_IPA_SHA256=$ipa_sha256" >> "$GITHUB_ENV"
echo "ipa_path=$ipa_path" >> "$GITHUB_OUTPUT"
echo "ipa_sha256=$ipa_sha256" >> "$GITHUB_OUTPUT"
echo "Exported IPA SHA-256: $ipa_sha256"
