#!/usr/bin/env bash
set -euo pipefail

: "${RUNNER_TEMP:?RUNNER_TEMP is required}"
: "${GITHUB_ENV:?GITHUB_ENV is required}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
: "${GITHUB_RUN_ID:?GITHUB_RUN_ID is required}"

umask 077
task_dir="$(mktemp -d "${RUNNER_TEMP}/ios-build-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT:-1}-XXXXXX")"
output_dir="${task_dir}/artifacts"
logs_dir="${task_dir}/logs"
sensitive_dir="${task_dir}/sensitive"
work_dir="${task_dir}/work"

mkdir -p "$output_dir" "$logs_dir" "$sensitive_dir" "$work_dir"
chmod 700 "$task_dir" "$output_dir" "$logs_dir" "$sensitive_dir" "$work_dir"

{
  echo "IOS_BUILD_TASK_DIR=$task_dir"
  echo "IOS_BUILD_OUTPUT_DIR=$output_dir"
  echo "IOS_BUILD_LOGS_DIR=$logs_dir"
  echo "IOS_BUILD_SENSITIVE_DIR=$sensitive_dir"
  echo "IOS_BUILD_WORK_DIR=$work_dir"
} >> "$GITHUB_ENV"

{
  echo "task_dir=$task_dir"
  echo "output_dir=$output_dir"
} >> "$GITHUB_OUTPUT"

echo "Initialized isolated task directory: $task_dir"
