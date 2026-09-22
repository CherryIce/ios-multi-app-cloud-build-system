#!/usr/bin/env bash
set -euo pipefail

: "${IOS_BUILD_ACTION_PATH:?IOS_BUILD_ACTION_PATH is required}"
: "${IOS_CONFIG_PATH:?IOS_CONFIG_PATH is required}"
: "${IOS_MARKETING_VERSION:?IOS_MARKETING_VERSION is required}"
: "${IOS_RESOLVED_BUILD_NUMBER:?IOS_RESOLVED_BUILD_NUMBER is required}"
: "${IOS_BUILD_OUTPUT_DIR:?IOS_BUILD_OUTPUT_DIR is required}"
: "${ASC_KEY_PATH:?ASC_KEY_PATH is required}"
: "${ASC_KEY_ID:?ASC_KEY_ID is required}"
: "${ASC_ISSUER_ID:?ASC_ISSUER_ID is required}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"

config_value() {
  ruby "${IOS_BUILD_ACTION_PATH}/scripts/config-value.rb" "$IOS_CONFIG_PATH" "$1"
}

ruby "${IOS_BUILD_ACTION_PATH}/scripts/wait-asc.rb" \
  --app-id "$(config_value app.asc_app_id)" \
  --marketing-version "$IOS_MARKETING_VERSION" \
  --build-number "$IOS_RESOLVED_BUILD_NUMBER" \
  --key-id "$ASC_KEY_ID" \
  --issuer-id "$ASC_ISSUER_ID" \
  --key-path "$ASC_KEY_PATH" \
  --wait-level "$(config_value upload.wait_level)" \
  --timeout-minutes "$(config_value upload.timeout_minutes)" \
  --poll-seconds "$(config_value upload.poll_interval_seconds)" \
  --output "${IOS_BUILD_OUTPUT_DIR}/asc-status.json" \
  --github-output "$GITHUB_OUTPUT"

ruby "${IOS_BUILD_ACTION_PATH}/scripts/assign-beta-groups.rb" \
  --config "$IOS_CONFIG_PATH" \
  --status "${IOS_BUILD_OUTPUT_DIR}/asc-status.json" \
  --key-id "$ASC_KEY_ID" \
  --issuer-id "$ASC_ISSUER_ID" \
  --key-path "$ASC_KEY_PATH"
