#!/usr/bin/env bash
set -euo pipefail

: "${IOS_IPA_PATH:?IOS_IPA_PATH is required}"
: "${IOS_BUILD_SENSITIVE_DIR:?IOS_BUILD_SENSITIVE_DIR is required}"
: "${IOS_BUILD_LOGS_DIR:?IOS_BUILD_LOGS_DIR is required}"
: "${ASC_KEY_ID:?ASC_KEY_ID is required}"
: "${ASC_ISSUER_ID:?ASC_ISSUER_ID is required}"

upload_log="${IOS_BUILD_LOGS_DIR}/upload.log"
command_runner="${IOS_BUILD_ACTION_PATH}/scripts/run-command-with-timeout.rb"
validate_timeout_seconds="${IOS_ALTOOL_VALIDATE_TIMEOUT_SECONDS:-900}"
upload_timeout_seconds="${IOS_ALTOOL_UPLOAD_TIMEOUT_SECONDS:-1800}"

for timeout_value in "$validate_timeout_seconds" "$upload_timeout_seconds"; do
  if [[ ! "$timeout_value" =~ ^[1-9][0-9]*$ ]]; then
    echo "altool timeout values must be positive integers" >&2
    exit 1
  fi
done

cd "$IOS_BUILD_SENSITIVE_DIR"
ruby "$command_runner" \
  --timeout-seconds "$validate_timeout_seconds" \
  --log "$upload_log" \
  -- \
  xcrun altool --validate-app \
  --type ios \
  --file "$IOS_IPA_PATH" \
  --apiKey "$ASC_KEY_ID" \
  --apiIssuer "$ASC_ISSUER_ID"

set +e
ruby "$command_runner" \
  --timeout-seconds "$upload_timeout_seconds" \
  --log "$upload_log" \
  --append \
  -- \
  xcrun altool --upload-app \
  --type ios \
  --file "$IOS_IPA_PATH" \
  --apiKey "$ASC_KEY_ID" \
  --apiIssuer "$ASC_ISSUER_ID"
upload_status=$?
set -e

case "$upload_status" in
  0)
    echo "Apple accepted the upload command; asynchronous processing is not yet verified"
    ;;
  124)
    message="Apple upload command timed out; continuing to exact ASC verification before deciding success"
    echo "$message" | tee -a "$upload_log"
    ;;
  *)
    echo "Apple upload command failed with exit status $upload_status" >&2
    exit "$upload_status"
    ;;
esac
