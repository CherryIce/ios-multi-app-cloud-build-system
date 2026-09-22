#!/usr/bin/env bash
set -euo pipefail

: "${IOS_IPA_PATH:?IOS_IPA_PATH is required}"
: "${IOS_BUILD_SENSITIVE_DIR:?IOS_BUILD_SENSITIVE_DIR is required}"
: "${IOS_BUILD_LOGS_DIR:?IOS_BUILD_LOGS_DIR is required}"
: "${ASC_KEY_ID:?ASC_KEY_ID is required}"
: "${ASC_ISSUER_ID:?ASC_ISSUER_ID is required}"

upload_log="${IOS_BUILD_LOGS_DIR}/upload.log"

cd "$IOS_BUILD_SENSITIVE_DIR"
set -o pipefail
xcrun altool --validate-app \
  --type ios \
  --file "$IOS_IPA_PATH" \
  --apiKey "$ASC_KEY_ID" \
  --apiIssuer "$ASC_ISSUER_ID" | tee "$upload_log"

xcrun altool --upload-app \
  --type ios \
  --file "$IOS_IPA_PATH" \
  --apiKey "$ASC_KEY_ID" \
  --apiIssuer "$ASC_ISSUER_ID" | tee -a "$upload_log"

echo "Apple accepted the upload command; asynchronous processing is not yet verified"
