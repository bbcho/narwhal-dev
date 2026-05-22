#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

cd "$repo_root"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/private/tmp/narwhal-clang-module-cache}"
export NARWHAL_RUN_LIVE_VERIFIERS=1

log_file="$(mktemp "${TMPDIR:-/tmp}/narwhal-live-verify.XXXXXX")"
trap 'rm -f "$log_file"' EXIT

set +e
swift test \
  --disable-sandbox \
  -Xswiftc -DNARWHAL_ENABLE_VERIFIERS \
  --filter NarwhalLiveVerifierTests.LiveAppKitVerifierTests \
  2>&1 | tee "$log_file"
test_status="${PIPESTATUS[0]}"
set -e

if grep -Eq 'No matching test cases were run|Test run with 0 tests' "$log_file"; then
  echo "live_verify_all failed: no live verifier tests ran" >&2
  exit 1
fi

if [ "$test_status" -ne 0 ]; then
  exit "$test_status"
fi

echo "live_verify_all passed"
