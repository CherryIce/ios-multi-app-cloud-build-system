#!/usr/bin/env bash
set -euo pipefail

: "${IOS_BUILD_ACTION_PATH:?IOS_BUILD_ACTION_PATH is required}"
: "${IOS_CONFIG_PATH:?IOS_CONFIG_PATH is required}"
: "${IOS_BUILD_WORK_DIR:?IOS_BUILD_WORK_DIR is required}"
: "${IOS_BUILD_LOGS_DIR:?IOS_BUILD_LOGS_DIR is required}"
: "${GITHUB_ENV:?GITHUB_ENV is required}"
: "${GITHUB_PATH:?GITHUB_PATH is required}"

config_value() {
  ruby "${IOS_BUILD_ACTION_PATH}/scripts/config-value.rb" "$IOS_CONFIG_PATH" "$1"
}

for command_name in curl ruby unzip uname; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "Required Flutter setup command is unavailable: $command_name" >&2
    exit 1
  }
done

version="$(config_value flutter.version)"
channel="$(config_value flutter.channel)"
configured_architecture="$(config_value flutter.architecture)"
expected_sha256="$(config_value flutter.sdk_sha256)"

case "$(uname -m)" in
  arm64)
    runner_architecture="arm64"
    archive_name="flutter_macos_arm64_${version}-${channel}.zip"
    ;;
  x86_64)
    runner_architecture="x64"
    archive_name="flutter_macos_${version}-${channel}.zip"
    ;;
  *)
    echo "Unsupported macOS runner architecture: $(uname -m)" >&2
    exit 1
    ;;
esac

if [[ "$runner_architecture" != "$configured_architecture" ]]; then
  echo "Configured Flutter architecture ${configured_architecture} does not match runner ${runner_architecture}" >&2
  exit 1
fi

archive_url="https://storage.googleapis.com/flutter_infra_release/releases/${channel}/macos/${archive_name}"
archive_path="${IOS_BUILD_WORK_DIR}/flutter-sdk.zip"
sdk_parent="${IOS_BUILD_WORK_DIR}/flutter-sdk"
flutter_root="${sdk_parent}/flutter"
setup_log="${IOS_BUILD_LOGS_DIR}/flutter-setup.log"

mkdir -p "$sdk_parent"
curl \
  --fail \
  --silent \
  --show-error \
  --location \
  --proto '=https' \
  --tlsv1.2 \
  --retry 3 \
  --output "$archive_path" \
  "$archive_url"

actual_sha256="$(ruby -rdigest -e 'puts Digest::SHA256.file(ARGV.fetch(0)).hexdigest' "$archive_path")"
if [[ "$actual_sha256" != "$expected_sha256" ]]; then
  echo "Flutter SDK SHA-256 mismatch" >&2
  exit 1
fi

unzip -q "$archive_path" -d "$sdk_parent"
rm -f -- "$archive_path"

flutter_bin="${flutter_root}/bin/flutter"
test -x "$flutter_bin" || {
  echo "Flutter SDK archive did not contain bin/flutter" >&2
  exit 1
}

{
  "$flutter_bin" config --no-analytics
  "$flutter_bin" --version --machine
  "$flutter_bin" precache --ios
} | tee "$setup_log"

actual_version="$({ "$flutter_bin" --version --machine; } | ruby -rjson -e 'puts JSON.parse(STDIN.read).fetch("frameworkVersion")')"
if [[ "$actual_version" != "$version" ]]; then
  echo "Installed Flutter version ${actual_version} does not match configured ${version}" >&2
  exit 1
fi

{
  echo "FLUTTER_ROOT=$flutter_root"
  echo "IOS_FLUTTER_VERSION=$actual_version"
} >> "$GITHUB_ENV"
echo "${flutter_root}/bin" >> "$GITHUB_PATH"

echo "Installed verified Flutter ${actual_version} for ${runner_architecture}"
