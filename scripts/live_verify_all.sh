#!/usr/bin/env bash
set -euo pipefail

if [[ "${NARWHAL_LIVE_VERIFY_CAFFEINATED:-0}" != "1" ]]; then
  exec /usr/bin/env \
    NARWHAL_LIVE_VERIFY_CAFFEINATED=1 \
    /usr/bin/caffeinate -dimsu "$0" "$@"
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

cd "$repo_root"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/private/tmp/narwhal-clang-module-cache}"
export NARWHAL_RUN_LIVE_VERIFIERS=1

log_root="$(mktemp -d "${TMPDIR:-/tmp}/narwhal-live-verify.XXXXXX")"
trap 'rm -rf "$log_root"' EXIT

run_phase() {
  local label="$1"
  local filter="$2"
  local required_suite="$3"
  local log_file="$log_root/$label.log"

  echo "live_verify_all: $label"
  set +e
  swift test \
    --disable-sandbox \
    -Xswiftc -DNARWHAL_ENABLE_VERIFIERS \
    --filter "$filter" \
    2>&1 | tee "$log_file"
  local test_status="${PIPESTATUS[0]}"
  set -e

  if grep -Eq 'No matching test cases were run|Test run with 0 tests' "$log_file"; then
    echo "live_verify_all failed: $label ran no tests" >&2
    exit 1
  fi

  if ! grep -Eq "Suite \"$required_suite\" started" "$log_file"; then
    echo "live_verify_all failed: $label suite did not start" >&2
    exit 1
  fi

  if [ "$test_status" -ne 0 ]; then
    exit "$test_status"
  fi

  local unexpected_skips
  unexpected_skips="$(
    grep -Ei 'skipped:|skipped after|test .* skipped|↳ .*requires ' "$log_file" \
      | grep -Fv 'Test "Live multi-display workflow" skipped: "Requires at least two displays."' \
      || true
  )"
  if [ -n "$unexpected_skips" ]; then
    printf '%s\n' "$unexpected_skips" >&2
    echo "live_verify_all failed: $label contains skipped tests" >&2
    exit 1
  fi

  if grep -Eq 'recorded an issue|failed after .* with [1-9][0-9]* issue' "$log_file"; then
    echo "live_verify_all failed: $label contains failing issues" >&2
    exit 1
  fi

  if ! grep -Eq 'Test run with [1-9][0-9]* tests? in [1-9][0-9]* suites? passed' "$log_file"; then
    echo "live_verify_all failed: $label did not report a completed passing test run" >&2
    exit 1
  fi
}

run_phase "appkit" "NarwhalLiveVerifierTests.LiveAppKitVerifierTests" "Live AppKit verifiers"

export NARWHAL_RUN_REAL_APP_VERIFIERS=1
run_phase "real-apps" "NarwhalLiveVerifierTests.RealAppWindowVerificationTests" "Real app window verifiers"

echo "live_verify_all passed"
