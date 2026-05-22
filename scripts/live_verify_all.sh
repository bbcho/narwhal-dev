#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

cd "$repo_root"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/private/tmp/narwhal-clang-module-cache}"
export NARWHAL_RUN_LIVE_VERIFIERS=1

log_file="$(mktemp "${TMPDIR:-/tmp}/narwhal-live-verify.XXXXXX")"
trap 'rm -f "$log_file"' EXIT

swift test \
  --disable-sandbox \
  -Xswiftc -DNARWHAL_ENABLE_VERIFIERS \
  --filter NarwhalLiveVerifierTests.LiveAppKitVerifierTests \
  2>&1 | tee "$log_file"

if grep -Eq 'No matching test cases were run|Test run with 0 tests' "$log_file"; then
  echo "live_verify_all failed: no live verifier tests ran" >&2
  exit 1
fi

if grep -Eq '✘|recorded an issue|Test run .* failed| failed after .* issue' "$log_file"; then
  echo "live_verify_all failed: at least one live verifier failed" >&2
  exit 1
fi

echo "live_verify_all passed"
