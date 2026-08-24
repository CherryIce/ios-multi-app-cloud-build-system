#!/usr/bin/env bash
set -euo pipefail

: "${IOS_BUILD_ACTION_PATH:?IOS_BUILD_ACTION_PATH is required}"
: "${IOS_CONFIG_PATH:?IOS_CONFIG_PATH is required}"
: "${IOS_MARKETING_VERSION:?IOS_MARKETING_VERSION is required}"
: "${IOS_BUILD_OUTPUT_DIR:?IOS_BUILD_OUTPUT_DIR is required}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
: "${GITHUB_ENV:?GITHUB_ENV is required}"

config_value() {
  ruby "${IOS_BUILD_ACTION_PATH}/scripts/config-value.rb" "$IOS_CONFIG_PATH" "$1"
}

requested="${IOS_REQUESTED_BUILD_NUMBER:-}"
strategy="$(config_value versioning.build_number_strategy)"

if [[ -n "$requested" ]]; then
  resolved="$requested"
elif [[ "$strategy" == "github_run_number" ]]; then
  : "${GITHUB_RUN_NUMBER:?GITHUB_RUN_NUMBER is required for github_run_number strategy}"
  resolved="$GITHUB_RUN_NUMBER"
elif [[ "$strategy" == "asc_increment" ]]; then
  : "${ASC_KEY_PATH:?ASC_KEY_PATH is required for asc_increment strategy}"
  : "${ASC_KEY_ID:?ASC_KEY_ID is required for asc_increment strategy}"
  : "${ASC_ISSUER_ID:?ASC_ISSUER_ID is required for asc_increment strategy}"
  resolved="$(ruby "${IOS_BUILD_ACTION_PATH}/scripts/next-build-number.rb" \
    --app-id "$(config_value app.asc_app_id)" \
    --marketing-version "$IOS_MARKETING_VERSION" \
    --key-id "$ASC_KEY_ID" \
    --issuer-id "$ASC_ISSUER_ID" \
    --key-path "$ASC_KEY_PATH")"
else
  echo "Unsupported build number strategy: $strategy" >&2
  exit 1
fi

if [[ ! "$resolved" =~ ^[1-9][0-9]*$ ]]; then
  echo "Resolved build number is not a positive integer" >&2
  exit 1
fi

ruby -rjson -e '
  path, number = ARGV
  data = JSON.parse(File.read(path))
  data["build_number"] = number
  File.write(path, JSON.pretty_generate(data) + "\n")
' "${IOS_BUILD_OUTPUT_DIR}/build-metadata.json" "$resolved"

echo "build_number=$resolved" >> "$GITHUB_OUTPUT"
echo "IOS_RESOLVED_BUILD_NUMBER=$resolved" >> "$GITHUB_ENV"
echo "Resolved build number: $resolved"
