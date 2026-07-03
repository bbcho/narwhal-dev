#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

cd "$repo_root"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/private/tmp/narwhal-clang-module-cache}"

real_log_file="$(mktemp "${TMPDIR:-/tmp}/narwhal-real-app-verify.XXXXXX")"
trap 'rm -f "$real_log_file"' EXIT

echo "This verifier runs fake-window workflows first, then launches installed real apps, drives Narwhal command workflows, verifies WindowServer frames, restores pre-existing app windows, and quits apps it opened only for verification."

echo "Phase 1/2: fake AppKit workflows and packaged smoke"
env -u NARWHAL_RUN_REAL_APP_VERIFIERS "$script_dir/live_verify_next_level.sh"

echo "Phase 2/2: real application workflows"
export NARWHAL_RUN_REAL_APP_VERIFIERS=1
set +e
swift test \
  --disable-sandbox \
  -Xswiftc -DNARWHAL_ENABLE_VERIFIERS \
  --filter NarwhalLiveVerifierTests.RealAppWindowVerificationTests \
  2>&1 | tee "$real_log_file"
real_status="${PIPESTATUS[0]}"
set -e

if grep -Eq 'No matching test cases were run|Test run with 0 tests' "$real_log_file"; then
  echo "live_verify_real_apps failed: no real-app verifier tests ran" >&2
  exit 1
fi

if [ "$real_status" -ne 0 ]; then
  exit "$real_status"
fi

if grep -Eq 'recorded an issue|failed after .* with [1-9][0-9]* issue' "$real_log_file"; then
  echo "live_verify_real_apps failed: real-app verifier output contains failing issues" >&2
  exit 1
fi

if ! grep -Eq 'Test run with [1-9][0-9]* tests? in [1-9][0-9]* suites? passed' "$real_log_file"; then
  echo "live_verify_real_apps failed: Swift Testing did not report a completed passing real-app test run" >&2
  exit 1
fi

echo "live_verify_real_apps passed"
