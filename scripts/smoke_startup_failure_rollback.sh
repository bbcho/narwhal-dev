#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
tmp_root="/private/tmp/narwhal-startup-failure-smoke"
config="$tmp_root/init.lua"
state_path="$tmp_root/state.json"
log_path="$tmp_root/narwhal.log"
export NARWHAL_LOG_PATH="$log_path"
socket_path="/tmp/narwhal-$(id -u).sock"
app_pid=""

cleanup() {
  if [ -n "$app_pid" ] && kill -0 "$app_pid" 2>/dev/null; then
    kill "$app_pid" 2>/dev/null || true
    wait "$app_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT

fail() {
  echo "smoke_startup_failure_rollback failed: $*" >&2
  if [ -f "$log_path" ]; then
    echo "---- $log_path tail ----" >&2
    tail -n 120 "$log_path" >&2 || true
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

assert_log_absent() {
  local pattern="$1"
  if [ -f "$log_path" ] && grep -Fq "$pattern" "$log_path"; then
    fail "unexpected log pattern found: $pattern"
  fi
}

wait_for_process_exit() {
  local pid="$1"
  local timeout_seconds="$2"
  local timeout_marker="$tmp_root/process-exit-timeout"
  rm -f "$timeout_marker"
  (
    sleep "$timeout_seconds"
    if kill -0 "$pid" 2>/dev/null; then
      touch "$timeout_marker"
      kill "$pid" 2>/dev/null || true
    fi
  ) &
  local watchdog_pid="$!"

  wait "$pid" 2>/dev/null || true
  kill "$watchdog_pid" 2>/dev/null || true
  wait "$watchdog_pid" 2>/dev/null || true

  if [ -f "$timeout_marker" ]; then
    fail "timed out waiting for NarwhalApp to exit"
  fi
}

wait_for_socket_absent() {
  local timeout_seconds="$1"
  local deadline=$((SECONDS + timeout_seconds))
  while [ "$SECONDS" -le "$deadline" ]; do
    if [ ! -e "$socket_path" ]; then
      return 0
    fi
    sleep 0.2
  done
  fail "IPC socket still exists after rollback: $socket_path"
}

if pgrep -x NarwhalApp >/dev/null 2>&1; then
  fail "NarwhalApp is already running; stop it before running this smoke"
fi

rm -rf "$tmp_root"
mkdir -p "$tmp_root"
cp "$repo_root/DefaultConfig/init.lua" "$config"
rm -f "$log_path" "$socket_path"

cd "$repo_root"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/private/tmp/narwhal-clang-module-cache}"

swift build --disable-sandbox --product NarwhalApp
bin_path="$(swift build --disable-sandbox --show-bin-path)"

"$bin_path/NarwhalApp" --config "$config" --restore-state "$state_path" --debug-fail-service-start dragZones &
app_pid="$!"

wait_for_log "IPC server ready at $socket_path" 20
wait_for_log "service startup failed at dragZones after starting menubar, hotkeys, axObserver, displayObserver, configWatcher, ipcServer: injected startup failure at service dragZones" 20
wait_for_log "Runtime service startup failed; terminating" 20
wait_for_log "NarwhalApp stopped" 20
wait_for_process_exit "$app_pid" 10
wait "$app_pid" 2>/dev/null || true
app_pid=""
wait_for_socket_absent 5
assert_log_absent "Drag zones ready"
assert_log_absent "Layout command loop ready"

echo "smoke_startup_failure_rollback passed"
