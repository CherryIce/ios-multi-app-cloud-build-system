#!/usr/bin/env bash
set -euo pipefail

: "${IOS_BUILD_ACTION_PATH:?IOS_BUILD_ACTION_PATH is required}"
: "${IOS_CONFIG_PATH:?IOS_CONFIG_PATH is required}"
: "${IOS_IPA_PATH:?IOS_IPA_PATH is required}"
: "${IOS_MARKETING_VERSION:?IOS_MARKETING_VERSION is required}"
: "${IOS_RESOLVED_BUILD_NUMBER:?IOS_RESOLVED_BUILD_NUMBER is required}"
: "${IOS_BUILD_WORK_DIR:?IOS_BUILD_WORK_DIR is required}"
: "${IOS_BUILD_OUTPUT_DIR:?IOS_BUILD_OUTPUT_DIR is required}"

ruby "${IOS_BUILD_ACTION_PATH}/scripts/inspect-ipa.rb" \
  --config "$IOS_CONFIG_PATH" \
  --ipa "$IOS_IPA_PATH" \
  --work-dir "$IOS_BUILD_WORK_DIR" \
  --marketing-version "$IOS_MARKETING_VERSION" \
  --build-number "$IOS_RESOLVED_BUILD_NUMBER" \
  --output "${IOS_BUILD_OUTPUT_DIR}/ipa-inspection.json"
