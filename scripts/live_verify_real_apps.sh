#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

cd "$repo_root"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/private/tmp/narwhal-clang-module-cache}"
export NARWHAL_REQUIRE_STABLE_TCC_SIGNING=true

case "${NARWHAL_SIGNING_IDENTITY:-}" in
  ""|"-"|"ad-hoc")
    cat >&2 <<'EOF'
live_verify_real_apps requires stable code signing for Accessibility trust.

Ad-hoc Narwhal apps and SwiftPM test bundles get a new cdhash after rebuilds,
so macOS can drop or ignore their Accessibility grant. Create a local identity
once, then rerun:

  scripts/create_local_codesign_identity.sh
  export NARWHAL_SIGNING_IDENTITY="Narwhal Local Code Signing"
  scripts/live_verify_real_apps.sh
EOF
    exit 2
    ;;
esac

if ! security find-identity -v -p codesigning | grep -F "\"$NARWHAL_SIGNING_IDENTITY\"" >/dev/null; then
  cat >&2 <<EOF
code-signing identity not found in keychain: $NARWHAL_SIGNING_IDENTITY

Create the local Narwhal identity once:
  scripts/create_local_codesign_identity.sh
  export NARWHAL_SIGNING_IDENTITY="Narwhal Local Code Signing"
EOF
  exit 1
fi

real_log_file="$(mktemp "${TMPDIR:-/tmp}/narwhal-real-app-verify.XXXXXX")"
trap 'rm -f "$real_log_file"' EXIT

echo "This verifier runs fake-window workflows first, then launches installed real apps, drives Narwhal command workflows, verifies WindowServer frames, restores pre-existing app windows, and quits apps it opened only for verification."

echo "Phase 1/2: fake AppKit workflows and packaged smoke"
env -u NARWHAL_RUN_REAL_APP_VERIFIERS "$script_dir/live_verify_next_level.sh"

echo "Phase 2/2: real application workflows"
export NARWHAL_RUN_REAL_APP_VERIFIERS=1
bin_path="$(swift build --show-bin-path)"
test_executable="$bin_path/narwhalPackageTests.xctest/Contents/MacOS/narwhalPackageTests"
build_stamp="$bin_path/narwhal-live-verifier-build.stamp"
needs_build=false

if [ ! -f "$test_executable" ] || [ ! -f "$build_stamp" ]; then
  needs_build=true
elif find Package.swift Package.resolved Sources Tests -type f -newer "$build_stamp" 2>/dev/null | grep -q .; then
  needs_build=true
fi

if [ "$needs_build" = "true" ]; then
  swift build \
    --build-tests \
    -Xswiftc -DNARWHAL_ENABLE_VERIFIERS
  touch "$build_stamp"
else
  echo "Skipping real-app verifier build; existing test bundle is up to date"
fi
"$script_dir/sign_live_test_bundle.sh"
set +e
swift test \
  --skip-build \
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
