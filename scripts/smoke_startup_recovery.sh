#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
tmp_root="/private/tmp/narwhal-startup-recovery-smoke"
config="$tmp_root/config/init.lua"
state_path="$tmp_root/state/state.json"
log_path="$tmp_root/log/narwhal.log"
socket_path="/tmp/narwhal-$(id -u).sock"
export NARWHAL_LOG_PATH="$log_path"
app_pid=""
ctl=""

cleanup() {
  if [ -n "$app_pid" ] && kill -0 "$app_pid" 2>/dev/null; then
    if [ -x "$ctl" ]; then
      "$ctl" quit >/dev/null 2>&1 || true
      sleep 0.5
    fi
    kill "$app_pid" 2>/dev/null || true
    wait "$app_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT

fail() {
  echo "smoke_startup_recovery failed: $*" >&2
  if [ -f "$log_path" ]; then
    tail -n 160 "$log_path" >&2 || true
  fi
  exit 1
}

wait_for_log() {
  local pattern="$1"
  local timeout_seconds="$2"
  local deadline=$((SECONDS + timeout_seconds))
  while [ "$SECONDS" -le "$deadline" ]; do
    if [ -f "$log_path" ] && grep -Fq "$pattern" "$log_path"; then
      return 0
    fi
    sleep 0.2
  done
  fail "timed out waiting for log pattern: $pattern"
}

wait_for_process_exit() {
  local pid="$1"
  local timeout_seconds="$2"
  local deadline=$((SECONDS + timeout_seconds))
  while [ "$SECONDS" -le "$deadline" ]; do
    if ! kill -0 "$pid" 2>/dev/null; then
      return 0
    fi
    sleep 0.2
  done
  fail "timed out waiting for NarwhalApp to exit"
}

assert_status_value() {
  local expected="$1"
  local status_json
  status_json="$("$ctl" status --json)" || fail "narwhalctl status failed"
  printf '%s\n' "$status_json" \
    | grep -Eq "\"configHealthy\"[[:space:]]*:[[:space:]]*$expected" \
    || fail "expected configHealthy=$expected"
}

if pgrep -x NarwhalApp >/dev/null 2>&1; then
  fail "NarwhalApp is already running; stop it before running this smoke"
fi

rm -rf "$tmp_root"
mkdir -p "$tmp_root/config" "$tmp_root/state" "$tmp_root/log"
printf '%s\n' 'return false' > "$config"
printf '%s\n' 'not-json' > "$state_path"
rm -f "$socket_path"

cd "$repo_root"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/private/tmp/narwhal-clang-module-cache}"
swift build --disable-sandbox --product NarwhalApp
swift build --disable-sandbox --product NarwhalCtl
bin_path="$(swift build --disable-sandbox --show-bin-path)"
app="$bin_path/NarwhalApp"
ctl="$bin_path/NarwhalCtl"

if "$app" --check-config --config "$config"; then
  fail "strict --check-config accepted an invalid config"
fi
rm -f "$log_path"

"$app" --config "$config" --restore-state "$state_path" &
app_pid="$!"

wait_for_log "Startup config failed; using built-in defaults" 20
wait_for_log "Invalid restore state quarantined as state.json.corrupt-" 20
wait_for_log "Layout command loop ready" 20
assert_status_value false

quarantine_count="$(find "$tmp_root/state" -maxdepth 1 -type f -name 'state.json.corrupt-*' -print | wc -l | tr -d ' ')"
[ "$quarantine_count" -eq 1 ] || fail "expected exactly one quarantined restore file"
quarantined_path="$(find "$tmp_root/state" -maxdepth 1 -type f -name 'state.json.corrupt-*' -print)"
[ "$(stat -f '%Lp' "$quarantined_path")" = "600" ] \
  || fail "quarantined restore file permissions were not 600"

cp "$repo_root/DefaultConfig/init.lua" "$config"
wait_for_log "Config reload completed (file watcher)" 10
wait_for_log "Rebound hotkeys" 10
assert_status_value true

"$ctl" quit | grep -Eq '^ok ipc-' || fail "narwhalctl quit did not return ok"
wait_for_process_exit "$app_pid" 10
app_pid=""
wait_for_log "NarwhalApp stopped" 5

echo "smoke_startup_recovery passed"
