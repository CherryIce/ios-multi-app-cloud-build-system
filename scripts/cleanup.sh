#!/usr/bin/env bash
set -u

cleanup_failed=0

if [[ -n "${IOS_KEYCHAIN_STATE_PATH:-}" && -f "$IOS_KEYCHAIN_STATE_PATH" ]]; then
  if ! ruby -rjson -e '
    paths = JSON.parse(File.read(ARGV.fetch(0)))
    ok = system("/usr/bin/security", "list-keychains", "-d", "user", "-s", *paths)
    exit(ok ? 0 : 1)
  ' "$IOS_KEYCHAIN_STATE_PATH"; then
    echo "Failed to restore original keychain search list" >&2
    cleanup_failed=1
  fi
fi

if [[ -n "${IOS_KEYCHAIN_PATH:-}" && -f "$IOS_KEYCHAIN_PATH" ]]; then
  if ! security delete-keychain "$IOS_KEYCHAIN_PATH"; then
    echo "Failed to delete temporary keychain" >&2
    cleanup_failed=1
  fi
fi

if [[ -n "${IOS_INSTALLED_PROFILES_PATH:-}" && -f "$IOS_INSTALLED_PROFILES_PATH" ]]; then
  while IFS= read -r profile_path; do
    case "$profile_path" in
      "${HOME}/Library/MobileDevice/Provisioning Profiles/"*.mobileprovision)
        rm -f -- "$profile_path" || cleanup_failed=1
        ;;
      "")
        ;;
      *)
        echo "Refusing to delete unexpected profile path: $profile_path" >&2
        cleanup_failed=1
        ;;
    esac
  done < "$IOS_INSTALLED_PROFILES_PATH"
fi

if [[ -n "${IOS_BUILD_SENSITIVE_DIR:-}" ]]; then
  case "$IOS_BUILD_SENSITIVE_DIR" in
    "${RUNNER_TEMP}/ios-build-"*/sensitive)
      rm -rf -- "$IOS_BUILD_SENSITIVE_DIR" || cleanup_failed=1
      ;;
    *)
      echo "Refusing to remove unexpected sensitive directory: $IOS_BUILD_SENSITIVE_DIR" >&2
      cleanup_failed=1
      ;;
  esac
fi

if [[ -n "${IOS_BUILD_WORK_DIR:-}" ]]; then
  case "$IOS_BUILD_WORK_DIR" in
    "${RUNNER_TEMP}/ios-build-"*/work)
      rm -rf -- "$IOS_BUILD_WORK_DIR" || cleanup_failed=1
      ;;
    *)
      echo "Refusing to remove unexpected work directory: $IOS_BUILD_WORK_DIR" >&2
      cleanup_failed=1
      ;;
  esac
fi

if [[ "$cleanup_failed" != "0" ]]; then
  exit 1
fi

echo "Temporary signing material and build work directory removed"
