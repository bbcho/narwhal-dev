#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
tmp_root="/private/tmp/winmgr-startup-shutdown-smoke"
config="$tmp_root/init.lua"
state_path="$tmp_root/state.json"
log_path="/tmp/winmgr.log"
socket_path="/tmp/winmgr-$(id -u).sock"
app_pid=""

cleanup() {
  if [ -n "$app_pid" ] && kill -0 "$app_pid" 2>/dev/null; then
    kill "$app_pid" 2>/dev/null || true
    wait "$app_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT

fail() {
  echo "smoke_startup_shutdown failed: $*" >&2
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
    fail "timed out waiting for WinMgrApp to exit"
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
  fail "IPC socket still exists after shutdown: $socket_path"
}

if pgrep -x WinMgrApp >/dev/null 2>&1; then
  fail "WinMgrApp is already running; stop it before running this smoke"
fi

rm -rf "$tmp_root"
mkdir -p "$tmp_root"
cp "$repo_root/DefaultConfig/init.lua" "$config"
rm -f "$log_path" "$socket_path"

cd "$repo_root"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/private/tmp/winmgr-clang-module-cache}"

swift build --disable-sandbox --product WinMgrApp --product WinMgrCtl
bin_path="$(swift build --disable-sandbox --show-bin-path)"

"$bin_path/WinMgrApp" --config "$config" --restore-state "$state_path" &
app_pid="$!"

wait_for_log "Using restore state path $state_path" 20
wait_for_log "Accessibility trusted" 20
wait_for_log "Registered hotkeys:" 20
wait_for_log "AX focus observer ready" 20
wait_for_log "Display observer ready" 20
wait_for_log "Config watcher ready" 20
wait_for_log "IPC server ready at $socket_path" 20
wait_for_log "Drag zones ready with modifier shift" 20
wait_for_log "Layout command loop ready" 20

"$bin_path/WinMgrCtl" balance | grep -Eq '^ok ipc-' || fail "winmgrctl balance did not return ok"
wait_for_log "IPC balance completed" 10

"$bin_path/WinMgrCtl" reset | grep -Eq '^ok ipc-' || fail "winmgrctl reset did not return ok"
wait_for_log "IPC reset layout memory" 10

"$bin_path/WinMgrCtl" quit | grep -Eq '^ok ipc-' || fail "winmgrctl quit did not return ok"
wait_for_log "IPC quit requested" 10
wait_for_process_exit "$app_pid" 10
wait "$app_pid" 2>/dev/null || true
app_pid=""
wait_for_log "WinMgrApp stopped" 5
wait_for_socket_absent 5

echo "smoke_startup_shutdown passed"
