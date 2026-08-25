#!/usr/bin/env bash
set -euo pipefail

: "${IOS_DISTRIBUTION_P12_BASE64:?IOS_DISTRIBUTION_P12_BASE64 is required}"
: "${IOS_DISTRIBUTION_P12_PASSWORD:?IOS_DISTRIBUTION_P12_PASSWORD is required}"
: "${IOS_PROFILES_ARCHIVE_BASE64:?IOS_PROFILES_ARCHIVE_BASE64 is required}"
: "${IOS_BUILD_ACTION_PATH:?IOS_BUILD_ACTION_PATH is required}"
: "${IOS_CONFIG_PATH:?IOS_CONFIG_PATH is required}"
: "${IOS_BUILD_SENSITIVE_DIR:?IOS_BUILD_SENSITIVE_DIR is required}"
: "${IOS_BUILD_WORK_DIR:?IOS_BUILD_WORK_DIR is required}"
: "${GITHUB_ENV:?GITHUB_ENV is required}"
: "${HOME:?HOME is required}"

umask 077
p12_path="${IOS_BUILD_SENSITIVE_DIR}/distribution.p12"
p12_certificate_path="${IOS_BUILD_SENSITIVE_DIR}/distribution-certificate.pem"
profiles_archive="${IOS_BUILD_SENSITIVE_DIR}/profiles.tar.gz"
profiles_dir="${IOS_BUILD_SENSITIVE_DIR}/profiles"
decoded_dir="${IOS_BUILD_WORK_DIR}/profile-plists"
profile_map="${IOS_BUILD_WORK_DIR}/profile-map.json"
keychain_path="${IOS_BUILD_SENSITIVE_DIR}/ios-build.keychain-db"
keychain_state="${IOS_BUILD_WORK_DIR}/original-keychains.json"
installed_profiles="${IOS_BUILD_WORK_DIR}/installed-profiles.txt"

mkdir -p "$profiles_dir" "$decoded_dir"
: > "$installed_profiles"

{
  echo "IOS_PROFILE_MAP_PATH=$profile_map"
  echo "IOS_KEYCHAIN_PATH=$keychain_path"
  echo "IOS_KEYCHAIN_STATE_PATH=$keychain_state"
  echo "IOS_INSTALLED_PROFILES_PATH=$installed_profiles"
} >> "$GITHUB_ENV"

printf '%s' "$IOS_DISTRIBUTION_P12_BASE64" | base64 -D > "$p12_path"
printf '%s' "$IOS_PROFILES_ARCHIVE_BASE64" | base64 -D > "$profiles_archive"
chmod 600 "$p12_path" "$profiles_archive"

P12_PASSWORD="$IOS_DISTRIBUTION_P12_PASSWORD" \
  openssl pkcs12 \
    -legacy \
    -in "$p12_path" \
    -passin env:P12_PASSWORD \
    -clcerts \
    -nokeys \
    -out "$p12_certificate_path"
openssl x509 -in "$p12_certificate_path" -noout -checkend 0
certificate_count="$(grep -c -- '-----BEGIN CERTIFICATE-----' "$p12_certificate_path")"
if [[ "$certificate_count" != "1" ]]; then
  echo "P12 must contain exactly one leaf distribution certificate" >&2
  exit 1
fi
ruby "${IOS_BUILD_ACTION_PATH}/scripts/validate-profiles-archive.rb" "$profiles_archive"
tar -xzf "$profiles_archive" -C "$profiles_dir"

plist_arguments=()
profile_index=0
while IFS= read -r -d '' profile_path; do
  profile_index=$((profile_index + 1))
  plist_path="${decoded_dir}/profile-${profile_index}.plist"
  security cms -D -i "$profile_path" > "$plist_path"
  plutil -insert _source_path -string "$profile_path" "$plist_path"
  plist_arguments+=(--plist "$plist_path")
done < <(find "$profiles_dir" -type f -name '*.mobileprovision' -print0)

ruby "${IOS_BUILD_ACTION_PATH}/scripts/map-profiles.rb" \
  --config "$IOS_CONFIG_PATH" \
  --certificate "$p12_certificate_path" \
  --output "$profile_map" \
  "${plist_arguments[@]}"

keychain_password="$(openssl rand -hex 32)"
security list-keychains -d user | ruby -rjson -e '
  paths = STDIN.read.scan(/"([^"]+)"/).flatten
  puts JSON.generate(paths)
' > "$keychain_state"

security create-keychain -p "$keychain_password" "$keychain_path"
security set-keychain-settings -lut 21600 "$keychain_path"
security unlock-keychain -p "$keychain_password" "$keychain_path"
security import "$p12_path" \
  -k "$keychain_path" \
  -P "$IOS_DISTRIBUTION_P12_PASSWORD" \
  -T /usr/bin/codesign \
  -T /usr/bin/security
security set-key-partition-list \
  -S apple-tool:,apple: \
  -s \
  -k "$keychain_password" \
  "$keychain_path"

ruby -rjson -rfileutils -e '
  state_path, keychain = ARGV
  paths = JSON.parse(File.read(state_path))
  ok = system("/usr/bin/security", "list-keychains", "-d", "user", "-s", keychain, *paths)
  exit(ok ? 0 : 1)
' "$keychain_state" "$keychain_path"

if ! security find-identity -v -p codesigning "$keychain_path" | grep -q 'Apple Distribution'; then
  echo "No Apple Distribution identity was imported" >&2
  exit 1
fi

profiles_install_dir="${HOME}/Library/MobileDevice/Provisioning Profiles"
mkdir -p "$profiles_install_dir"
ruby -rjson -rfileutils -e '
  map_path, destination, installed = ARGV
  profiles = JSON.parse(File.read(map_path))
  File.open(installed, "a") do |record|
    profiles.each_value do |profile|
      target = File.join(destination, "#{profile.fetch("uuid")}.mobileprovision")
      source = profile.fetch("source_path")
      if File.exist?(target)
        abort "existing profile differs: #{target}" unless File.binread(target) == File.binread(source)
      else
        FileUtils.cp(source, target, preserve: true)
        File.chmod(0o600, target)
        record.puts target
      end
    end
  end
' "$profile_map" "$profiles_install_dir" "$installed_profiles"

rm -f "$p12_path" "$p12_certificate_path" "$profiles_archive"
rm -rf "$profiles_dir"

echo "Installed signing identity and provisioning profiles"
