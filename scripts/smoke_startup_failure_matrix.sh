#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
tmp_root="/private/tmp/narwhal-startup-failure-matrix"
config="$tmp_root/config/init.lua"
state_path="$tmp_root/state/state.json"
log_path="$tmp_root/log/narwhal.log"
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
  echo "smoke_startup_failure_matrix failed: $*" >&2
  if [ -f "$log_path" ]; then
    echo "---- $log_path tail ----" >&2
    tail -n 120 "$log_path" >&2 || true
  fi
  exit 1
}

expected_started_services() {
  case "$1" in
    hotkeys) echo "nothing" ;;
    axObserver) echo "hotkeys" ;;
    displayObserver) echo "hotkeys, axObserver" ;;
    configWatcher) echo "hotkeys, axObserver, displayObserver" ;;
    ipcServer) echo "hotkeys, axObserver, displayObserver, configWatcher" ;;
    dragZones) echo "hotkeys, axObserver, displayObserver, configWatcher, ipcServer" ;;
    *) fail "unknown matrix service: $1" ;;
  esac
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

run_case() {
  local service="$1"
  local started
  started="$(expected_started_services "$service")"

  if pgrep -x NarwhalApp >/dev/null 2>&1; then
    fail "NarwhalApp is already running before $service case"
  fi

  rm -f "$log_path" "$socket_path"
  "$bin_path/NarwhalApp" --config "$config" --restore-state "$state_path" --debug-fail-service-start "$service" &
  app_pid="$!"

  if [ "$service" = "dragZones" ]; then
    wait_for_log "IPC server ready at <path>" 20
  fi

  wait_for_log "service startup failed at $service after starting $started: injected startup failure at service $service" 20
  wait_for_log "Runtime service startup failed; recovery menu remains available" 20
  if ! kill -0 "$app_pid" 2>/dev/null; then
    fail "NarwhalApp exited instead of preserving the recovery menu"
  fi
  assert_log_absent "NarwhalApp stopped"
  wait_for_socket_absent 5
  kill "$app_pid" 2>/dev/null || true
  wait "$app_pid" 2>/dev/null || true
  app_pid=""

  assert_log_absent "Drag zones ready"
  assert_log_absent "Layout command loop ready"
  echo "matrix case passed: $service"
}

rm -rf "$tmp_root"
mkdir -p "$tmp_root/config" "$tmp_root/state" "$tmp_root/log"
cp "$repo_root/DefaultConfig/init.lua" "$config"
rm -f "$log_path" "$socket_path"

cd "$repo_root"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/private/tmp/narwhal-clang-module-cache}"

swift build --disable-sandbox --product NarwhalApp
bin_path="$(swift build --disable-sandbox --show-bin-path)"

for service in hotkeys axObserver displayObserver configWatcher ipcServer dragZones; do
  run_case "$service"
done

echo "smoke_startup_failure_matrix passed"
