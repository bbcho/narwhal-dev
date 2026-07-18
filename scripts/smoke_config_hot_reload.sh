#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
tmp_root="/private/tmp/narwhal-hot-reload-smoke"
config="$tmp_root/init.lua"
log_path="$tmp_root/narwhal.log"
export NARWHAL_LOG_PATH="$log_path"
app_pid=""

cleanup() {
  if [ -n "$app_pid" ] && kill -0 "$app_pid" 2>/dev/null; then
    kill "$app_pid" 2>/dev/null || true
    wait "$app_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT

fail() {
  echo "smoke_config_hot_reload failed: $*" >&2
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

assert_app_running() {
  if [ -z "$app_pid" ] || ! kill -0 "$app_pid" 2>/dev/null; then
    fail "NarwhalApp process exited unexpectedly"
  fi
}

if pgrep -x NarwhalApp >/dev/null 2>&1; then
  fail "NarwhalApp is already running; stop it before running this smoke"
fi

rm -rf "$tmp_root"
mkdir -p "$tmp_root"
cp "$repo_root/DefaultConfig/init.lua" "$config"
rm -f "$log_path"

cd "$repo_root"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/private/tmp/narwhal-clang-module-cache}"

swift build --disable-sandbox --product NarwhalApp --product NarwhalCtl
bin_path="$(swift build --disable-sandbox --show-bin-path)"

"$bin_path/NarwhalApp" --config "$config" &
app_pid="$!"

wait_for_log "Config watcher ready for " 20

perl -0pi -e 's/duration_millis = 700/duration_millis = 701/' "$config"
wait_for_log "Config reload completed (file watcher)" 10
wait_for_log "Rebound hotkeys" 10
wait_for_log "Updated drag-zone modifier to shift" 10
assert_app_running

perl -0pi -e 's/return \{/return false/' "$config"
wait_for_log "Config reload failed (file watcher)" 10
assert_app_running

"$bin_path/NarwhalCtl" reset | grep -Eq '^ok ipc-' || fail "narwhalctl reset did not return ok"
wait_for_log "IPC reset layout memory" 10
assert_app_running

echo "smoke_config_hot_reload passed"
