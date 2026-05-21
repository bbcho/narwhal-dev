#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

cd "$repo_root"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/private/tmp/narwhal-clang-module-cache}"

run_required() {
  local flag="$1"
  echo "==> swift run NarwhalApp $flag"
  swift run --disable-sandbox NarwhalApp "$flag"
  sleep 0.2
}

run_optional_multi_display() {
  local output
  echo "==> swift run NarwhalApp --verify-live-multi-display"
  set +e
  output="$(swift run --disable-sandbox NarwhalApp --verify-live-multi-display 2>&1)"
  local status="$?"
  set -e
  printf '%s\n' "$output"
  if [ "$status" -eq 0 ]; then
    sleep 0.2
    return 0
  fi
  if printf '%s\n' "$output" | grep -Eq 'requires at least two displays|requires two usable displays'; then
    echo "live multi-display verifier skipped on this machine"
    sleep 0.2
    return 0
  fi
  return "$status"
}

run_required --verify-command-overlay-layout
run_required --verify-focus-border-radius
run_required --verify-menubar-icon
run_required --verify-observation-replay
run_required --verify-workspace-scope
run_optional_multi_display
run_required --verify-focused-unavailable-polling
run_required --verify-space-focus-recovery
run_required --verify-display-change-focus-border
run_required --verify-live-command-workflows

echo "live_verify_all passed"
