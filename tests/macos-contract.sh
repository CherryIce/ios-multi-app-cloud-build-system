#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "macos-contract.sh requires macOS" >&2
  exit 1
fi

for command_name in security codesign plutil xcodebuild xcrun ditto; do
  command -v "$command_name" >/dev/null
done

xcodebuild -version
xcodebuild -help 2>&1 | grep -q -- '-exportArchive'
bash "$(dirname "$0")/run.sh"
echo "macOS release-tool contract passed"
