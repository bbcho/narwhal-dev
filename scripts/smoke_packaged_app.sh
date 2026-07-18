#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
package_root="/private/tmp/narwhal-packaged-smoke"
tmp_root="/private/tmp/narwhal-packaged-smoke-state"
config="$tmp_root/init.lua"
state_path="$tmp_root/state.json"
log_path="$tmp_root/narwhal.log"
export NARWHAL_LOG_PATH="$log_path"
socket_path="/tmp/narwhal-$(id -u).sock"
app_pid=""

cleanup() {
  if [ -n "$app_pid" ] && kill -0 "$app_pid" 2>/dev/null; then
    "$package_root/Narwhal.app/Contents/MacOS/narwhalctl" quit >/dev/null 2>&1 || true
    sleep 0.5
    kill "$app_pid" 2>/dev/null || true
    wait "$app_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT

fail() {
  echo "smoke_packaged_app failed: $*" >&2
  if [ -f "$log_path" ]; then
    echo "---- $log_path tail ----" >&2
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

run_ok() {
  local label="$1"
  shift
  local output
  output="$("$@" 2>&1)" || fail "$label failed unexpectedly: $output"
  grep -Eq '^ok ipc-' <<<"$output" || fail "$label did not return ok: $output"
}

run_expected_error() {
  local label="$1"
  local pattern="$2"
  shift 2
  local output
  set +e
  output="$("$@" 2>&1)"
  local status="$?"
  set -e
  [ "$status" -ne 0 ] || fail "$label unexpectedly succeeded: $output"
  grep -Eq "$pattern" <<<"$output" || fail "$label returned unexpected error: $output"
}

if pgrep -x NarwhalApp >/dev/null 2>&1; then
  fail "NarwhalApp is already running; stop it before running this smoke"
fi

rm -rf "$tmp_root"
mkdir -p "$tmp_root"
cp "$repo_root/DefaultConfig/init.lua" "$config"
rm -f "$log_path" "$socket_path"

cd "$repo_root"
"$script_dir/build_app_bundle.sh" --configuration debug --output "$package_root" --replace

app="$package_root/Narwhal.app/Contents/MacOS/NarwhalApp"
ctl="$package_root/Narwhal.app/Contents/MacOS/narwhalctl"

"$app" --check-config --config "$config" --restore-state "$state_path" >/tmp/narwhal-packaged-check-config.log 2>&1 \
  || fail "packaged --check-config failed"

"$app" --config "$config" --restore-state "$state_path" &
app_pid="$!"

wait_for_log "Using restore state path $state_path" 20
wait_for_log "IPC server ready at $socket_path" 20
wait_for_log "Layout command loop ready" 20

missing_window="4294967294"
run_ok "packaged reset" "$ctl" reset
run_ok "packaged balance" "$ctl" balance

run_expected_error "packaged push focused" 'error push_failed:' "$ctl" push left
run_expected_error "packaged swap focused" 'error swap_failed:' "$ctl" swap right
run_expected_error "packaged resize focused" 'error resize_failed:' "$ctl" resize up --delta 0.25
run_expected_error "packaged focus direction" 'error focus_failed:' "$ctl" focus-direction down

run_expected_error "packaged push explicit" 'error window_not_found:' "$ctl" push left --window "$missing_window"
run_expected_error "packaged swap explicit" 'error window_not_found:' "$ctl" swap left --window "$missing_window"
run_expected_error "packaged resize explicit" 'error window_not_found:' "$ctl" resize right --delta 0.25 --window "$missing_window"
run_expected_error "packaged center explicit" 'error window_not_found:' "$ctl" center --window "$missing_window"
run_expected_error "packaged eject explicit" 'error window_not_found:' "$ctl" eject --window "$missing_window"
run_expected_error "packaged toggle-float explicit" 'error window_not_found:' "$ctl" toggle-float --window "$missing_window"
run_expected_error "packaged focus explicit" 'error window_not_found:' "$ctl" focus --window "$missing_window"

run_ok "packaged quit" "$ctl" quit
wait_for_log "IPC quit requested" 10
wait_for_process_exit "$app_pid" 10
app_pid=""

echo "smoke_packaged_app passed"
