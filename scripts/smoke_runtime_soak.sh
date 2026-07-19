#!/usr/bin/env bash
set -euo pipefail

duration_seconds="${NARWHAL_SOAK_DURATION_SECONDS:-300}"

usage() {
  cat <<'USAGE'
usage: scripts/smoke_runtime_soak.sh [--duration-seconds INTEGER]

Runs a trusted Narwhal process for five minutes by default while polling
diagnostics, issuing serialized IPC commands, checking log loss, and bounding
resident memory.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --duration-seconds)
      [ "$#" -ge 2 ] || { echo "--duration-seconds requires an integer" >&2; exit 2; }
      duration_seconds="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ ! "$duration_seconds" =~ ^[1-9][0-9]*$ ]]; then
  echo "--duration-seconds must be a positive integer" >&2
  exit 2
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
tmp_root="/private/tmp/narwhal-runtime-soak"
config="$tmp_root/config/init.lua"
state_path="$tmp_root/state/state.json"
log_path="$tmp_root/log/narwhal.log"
console_path="$tmp_root/log/console.log"
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
  echo "smoke_runtime_soak failed: $*" >&2
  if [ -f "$log_path" ]; then
    tail -n 160 "$log_path" >&2 || true
  fi
  if [ -f "$console_path" ]; then
    tail -n 80 "$console_path" >&2 || true
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

if pgrep -x NarwhalApp >/dev/null 2>&1; then
  fail "NarwhalApp is already running; stop it before running this smoke"
fi

rm -rf "$tmp_root"
mkdir -p "$tmp_root/config" "$tmp_root/state" "$tmp_root/log"
cp "$repo_root/DefaultConfig/init.lua" "$config"
rm -f "$socket_path"

cd "$repo_root"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/private/tmp/narwhal-clang-module-cache}"
swift build --disable-sandbox --product NarwhalApp
swift build --disable-sandbox --product NarwhalCtl
bin_path="$(swift build --disable-sandbox --show-bin-path)"
app="$bin_path/NarwhalApp"
ctl="$bin_path/NarwhalCtl"

"$app" --config "$config" --restore-state "$state_path" >"$console_path" 2>&1 &
app_pid="$!"
wait_for_log "Layout command loop ready" 30

deadline=$((SECONDS + duration_seconds))
sample_count=0
maximum_rss_kib=0
while [ "$SECONDS" -lt "$deadline" ]; do
  kill -0 "$app_pid" 2>/dev/null || fail "NarwhalApp exited during soak"
  status_json="$("$ctl" status --json)" || fail "narwhalctl status failed during soak"
  printf '%s\n' "$status_json" | grep -Eq '"accessibilityTrusted"[[:space:]]*:[[:space:]]*true' \
    || fail "Accessibility trust was lost during soak"
  printf '%s\n' "$status_json" | grep -Eq '"notificationFastPathActive"[[:space:]]*:[[:space:]]*true' \
    || fail "AX notification fast path became inactive during soak"
  printf '%s\n' "$status_json" | grep -Eq '"configHealthy"[[:space:]]*:[[:space:]]*true' \
    || fail "configuration became unhealthy during soak"
  printf '%s\n' "$status_json" | grep -Eq '"droppedLogLineCount"[[:space:]]*:[[:space:]]*0' \
    || fail "runtime dropped log lines during soak"

  if ((sample_count % 2 == 0)); then
    "$ctl" reset | grep -Eq '^ok ipc-' || fail "reset failed during soak"
  else
    "$ctl" balance | grep -Eq '^ok ipc-' || fail "balance failed during soak"
  fi

  rss_kib="$(ps -o rss= -p "$app_pid" | tr -d ' ')"
  [[ "$rss_kib" =~ ^[0-9]+$ ]] || fail "could not read Narwhal resident memory"
  ((rss_kib <= 524288)) || fail "resident memory exceeded 512 MiB: ${rss_kib} KiB"
  ((rss_kib > maximum_rss_kib)) && maximum_rss_kib="$rss_kib"
  sample_count=$((sample_count + 1))
  sleep 2
done

((sample_count > 0)) || fail "soak collected no diagnostic samples"
"$ctl" quit | grep -Eq '^ok ipc-' || fail "narwhalctl quit did not return ok"
wait_for_process_exit "$app_pid" 10
app_pid=""
wait_for_log "NarwhalApp stopped" 5

echo "smoke_runtime_soak passed: samples=$sample_count max_rss_kib=$maximum_rss_kib"
