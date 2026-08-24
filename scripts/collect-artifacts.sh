#!/usr/bin/env bash
set -euo pipefail

: "${IOS_BUILD_ACTION_PATH:?IOS_BUILD_ACTION_PATH is required}"
: "${IOS_CONFIG_PATH:?IOS_CONFIG_PATH is required}"
: "${IOS_BUILD_OUTPUT_DIR:?IOS_BUILD_OUTPUT_DIR is required}"
: "${IOS_BUILD_LOGS_DIR:?IOS_BUILD_LOGS_DIR is required}"

mkdir -p "${IOS_BUILD_OUTPUT_DIR}/logs"
find "$IOS_BUILD_LOGS_DIR" -maxdepth 1 -type f -exec cp -p {} "${IOS_BUILD_OUTPUT_DIR}/logs/" \;

if [[ -n "${IOS_ARCHIVE_PATH:-}" && -d "${IOS_ARCHIVE_PATH}/dSYMs" ]]; then
  ditto -c -k --keepParent "${IOS_ARCHIVE_PATH}/dSYMs" "${IOS_BUILD_OUTPUT_DIR}/dSYMs.zip"
fi

keep_archive="false"
if ruby "${IOS_BUILD_ACTION_PATH}/scripts/validate-config.rb" "$IOS_CONFIG_PATH" >/dev/null 2>&1; then
  keep_archive="$(ruby "${IOS_BUILD_ACTION_PATH}/scripts/config-value.rb" "$IOS_CONFIG_PATH" artifacts.keep_xcarchive)"
fi
if [[ "$keep_archive" == "true" && -n "${IOS_ARCHIVE_PATH:-}" && -d "$IOS_ARCHIVE_PATH" ]]; then
  ditto -c -k --keepParent "$IOS_ARCHIVE_PATH" "${IOS_BUILD_OUTPUT_DIR}/App.xcarchive.zip"
fi

forbidden_file="$(find "$IOS_BUILD_OUTPUT_DIR" -type f \( \
  -name '*.p12' -o \
  -name '*.p8' -o \
  -name '*.mobileprovision' -o \
  -name '*.keychain' -o \
  -name '*.keychain-db' \
\) -print -quit)"
if [[ -n "$forbidden_file" ]]; then
  echo "Artifact directory contains a forbidden sensitive file type: ${forbidden_file##*/}" >&2
  exit 1
fi

find "$IOS_BUILD_OUTPUT_DIR" -type f -print | sort
