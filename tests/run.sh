#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repository_root"

for script in scripts/*.sh tests/*.sh; do
  bash -n "$script"
done

for script in scripts/*.rb scripts/lib/*.rb tests/test_*.rb; do
  ruby -c "$script" >/dev/null
done

python3 -c 'import pathlib; compile(pathlib.Path("scripts/plist-to-json.py").read_text(), "scripts/plist-to-json.py", "exec")'

ruby -rjson -e 'JSON.parse(File.read(ARGV.fetch(0)))' schemas/ios-build-config.schema.json
ruby scripts/validate-config.rb tests/fixtures/config/valid.yml
if ruby scripts/validate-config.rb tests/fixtures/config/invalid.yml >/dev/null 2>&1; then
  echo "Invalid configuration fixture unexpectedly passed" >&2
  exit 1
fi

ruby -Itests -e 'Dir["tests/test_*.rb"].sort.each { |file| require File.expand_path(file) }'

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck scripts/*.sh tests/*.sh
fi

git diff --check
echo "Core self-test passed"
