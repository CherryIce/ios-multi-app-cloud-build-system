#!/usr/bin/env bash
set -euo pipefail

: "${ASC_API_KEY_P8_BASE64:?ASC_API_KEY_P8_BASE64 is required}"
: "${ASC_KEY_ID:?ASC_KEY_ID is required}"
: "${ASC_ISSUER_ID:?ASC_ISSUER_ID is required}"
: "${IOS_BUILD_SENSITIVE_DIR:?IOS_BUILD_SENSITIVE_DIR is required}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"

if [[ ! "$ASC_KEY_ID" =~ ^[A-Z0-9]{10}$ ]]; then
  echo "ASC_KEY_ID must contain 10 uppercase letters or digits" >&2
  exit 1
fi
if [[ ! "$ASC_ISSUER_ID" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
  echo "ASC_ISSUER_ID must be a UUID" >&2
  exit 1
fi

key_directory="${IOS_BUILD_SENSITIVE_DIR}/private_keys"
key_path="${key_directory}/AuthKey_${ASC_KEY_ID}.p8"
mkdir -p "$key_directory"
chmod 700 "$key_directory"

printf '%s' "$ASC_API_KEY_P8_BASE64" | base64 -D > "$key_path"
chmod 600 "$key_path"
openssl pkey -in "$key_path" -check -noout >/dev/null

echo "asc_key_path=$key_path" >> "$GITHUB_OUTPUT"
echo "Prepared ASC key in the isolated sensitive directory"
