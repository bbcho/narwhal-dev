#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

cd "$repo_root"

identity="${NARWHAL_SIGNING_IDENTITY:-}"
require_stable="${NARWHAL_REQUIRE_STABLE_TCC_SIGNING:-false}"

case "$identity" in
  ""|"-"|"ad-hoc")
    if [ "$require_stable" = "true" ]; then
      cat >&2 <<'EOF'
live verifier requires stable code signing for real app Accessibility tests.

Ad-hoc SwiftPM test bundles get a new cdhash after rebuilds, so macOS can drop
or ignore their Accessibility grant. Create a local identity once, then rerun:

  scripts/create_local_codesign_identity.sh
  export NARWHAL_SIGNING_IDENTITY="Narwhal Local Code Signing"
  scripts/live_verify_real_apps.sh
EOF
      exit 2
    fi
    exit 0
    ;;
esac

if ! security find-identity -v -p codesigning | grep -F "\"$identity\"" >/dev/null; then
  cat >&2 <<EOF
code-signing identity not found in keychain: $identity

Create the local Narwhal identity once:
  scripts/create_local_codesign_identity.sh
  export NARWHAL_SIGNING_IDENTITY="Narwhal Local Code Signing"
EOF
  exit 1
fi

bin_path="$(swift build --show-bin-path)"
test_executable="$bin_path/narwhalPackageTests.xctest/Contents/MacOS/narwhalPackageTests"

if [ ! -f "$test_executable" ]; then
  echo "live verifier test executable not found: $test_executable" >&2
  echo "build tests before signing: swift build --build-tests -Xswiftc -DNARWHAL_ENABLE_VERIFIERS" >&2
  exit 1
fi

codesign \
  --force \
  --identifier "narwhalPackageTests" \
  --sign "$identity" \
  "$test_executable" >/dev/null

echo "Signed live verifier test bundle with identity: $identity"
