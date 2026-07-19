#!/usr/bin/env bash
set -euo pipefail

app_path=""
expected_version=""
expected_build=""
expected_architecture="arm64"
require_gatekeeper="false"

usage() {
  cat <<'USAGE'
usage: scripts/verify_app_bundle.sh --app PATH [options]

Options:
  --version MAJOR.MINOR.PATCH   Expected display version.
  --build-number INTEGER        Expected bundle build number.
  --architecture ARCH          Expected single architecture. Default: arm64.
  --gatekeeper                 Require a successful Gatekeeper assessment.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --app)
      [ "$#" -ge 2 ] || { echo "--app requires a path" >&2; exit 2; }
      app_path="$2"
      shift 2
      ;;
    --version)
      [ "$#" -ge 2 ] || { echo "--version requires a value" >&2; exit 2; }
      expected_version="$2"
      shift 2
      ;;
    --build-number)
      [ "$#" -ge 2 ] || { echo "--build-number requires a value" >&2; exit 2; }
      expected_build="$2"
      shift 2
      ;;
    --architecture)
      [ "$#" -ge 2 ] || { echo "--architecture requires a value" >&2; exit 2; }
      expected_architecture="$2"
      shift 2
      ;;
    --gatekeeper)
      require_gatekeeper="true"
      shift
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

[ -n "$app_path" ] || { echo "--app is required" >&2; exit 2; }
[ -d "$app_path" ] || { echo "app bundle not found: $app_path" >&2; exit 1; }

info_plist="$app_path/Contents/Info.plist"
app_executable="$app_path/Contents/MacOS/NarwhalApp"
ctl_executable="$app_path/Contents/MacOS/narwhalctl"
lua_dylib="$app_path/Contents/Frameworks/liblua.dylib"
third_party_notices="$app_path/Contents/Resources/THIRD_PARTY_NOTICES.md"

plutil -lint "$info_plist"
codesign --verify --deep --strict --verbose=2 "$app_path"

for binary in "$app_executable" "$ctl_executable" "$lua_dylib"; do
  [ -x "$binary" ] || { echo "missing executable: $binary" >&2; exit 1; }
  architectures="$(lipo -archs "$binary")"
  [ "$architectures" = "$expected_architecture" ] || {
    echo "unexpected architectures for $binary: $architectures" >&2
    exit 1
  }
done

actual_identifier="$(plutil -extract CFBundleIdentifier raw "$info_plist")"
[ "$actual_identifier" = "com.ben.narwhal" ] || {
  echo "unexpected bundle identifier: $actual_identifier" >&2
  exit 1
}
actual_minimum="$(plutil -extract LSMinimumSystemVersion raw "$info_plist")"
[ "$actual_minimum" = "26.0" ] || {
  echo "unexpected minimum macOS version: $actual_minimum" >&2
  exit 1
}
if [ -n "$expected_version" ]; then
  actual_version="$(plutil -extract CFBundleShortVersionString raw "$info_plist")"
  [ "$actual_version" = "$expected_version" ] || {
    echo "unexpected display version: $actual_version" >&2
    exit 1
  }
fi
if [ -n "$expected_build" ]; then
  actual_build="$(plutil -extract CFBundleVersion raw "$info_plist")"
  [ "$actual_build" = "$expected_build" ] || {
    echo "unexpected build number: $actual_build" >&2
    exit 1
  }
fi

otool -L "$app_executable" \
  | awk '$1 == "@executable_path/../Frameworks/liblua.dylib" { found = 1 } END { exit !found }'
if otool -L "$app_executable" | grep -Eq '/(opt/homebrew|usr/local)/.*liblua'; then
  echo "packaged app still references an external Lua installation" >&2
  exit 1
fi
if [ -e "$(dirname "$app_path")/com.ben.narwhal.plist" ]; then
  echo "legacy LaunchAgent was packaged beside the app" >&2
  exit 1
fi
if [ ! -s "$third_party_notices" ] \
    || ! grep -Fq 'Copyright (C) 1994-2025 Lua.org, PUC-Rio.' "$third_party_notices"; then
  echo "packaged app is missing the Lua license notice" >&2
  exit 1
fi

if [ "$require_gatekeeper" = "true" ]; then
  spctl --assess --type execute --verbose=4 "$app_path"
fi

echo "Verified $app_path"
