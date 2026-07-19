#!/usr/bin/env bash
set -euo pipefail

configuration="release"
output_root=""
replace_existing="false"
display_version=""
build_number=""
architecture=""

usage() {
  cat <<'USAGE'
usage: scripts/build_app_bundle.sh [options]

Builds NarwhalApp and NarwhalCtl, then assembles:
  DIR/Narwhal.app

Default DIR is .build/narwhal-package.

Options:
  --configuration debug|release   Build configuration. Default: release.
  --output DIR                    Package output directory.
  --version MAJOR.MINOR.PATCH     Override CFBundleShortVersionString.
  --build-number INTEGER          Override CFBundleVersion.
  --architecture arm64|x86_64     Build and validate one explicit architecture.
  --replace                       Replace an existing package output.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --configuration)
      [ "$#" -ge 2 ] || { echo "--configuration requires debug or release" >&2; exit 2; }
      configuration="$2"
      shift 2
      ;;
    --output)
      [ "$#" -ge 2 ] || { echo "--output requires a directory" >&2; exit 2; }
      output_root="$2"
      shift 2
      ;;
    --replace)
      replace_existing="true"
      shift
      ;;
    --version)
      [ "$#" -ge 2 ] || { echo "--version requires MAJOR.MINOR.PATCH" >&2; exit 2; }
      display_version="$2"
      shift 2
      ;;
    --build-number)
      [ "$#" -ge 2 ] || { echo "--build-number requires an integer" >&2; exit 2; }
      build_number="$2"
      shift 2
      ;;
    --architecture)
      [ "$#" -ge 2 ] || { echo "--architecture requires arm64 or x86_64" >&2; exit 2; }
      architecture="$2"
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

case "$configuration" in
  debug|release) ;;
  *)
    echo "--configuration must be debug or release" >&2
    exit 2
    ;;
esac

if [ -n "$display_version" ]; then
  if [[ ! "$display_version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
    echo "--version must be a canonical MAJOR.MINOR.PATCH value" >&2
    exit 2
  fi
fi
if [ -n "$build_number" ]; then
  if [[ ! "$build_number" =~ ^[1-9][0-9]*$ ]]; then
    echo "--build-number must be a positive integer" >&2
    exit 2
  fi
fi
case "$architecture" in
  ""|arm64|x86_64) ;;
  *)
    echo "--architecture must be arm64 or x86_64" >&2
    exit 2
    ;;
esac

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
if [ -z "$output_root" ]; then
  output_root="$repo_root/.build/narwhal-package"
elif [[ "$output_root" != /* ]]; then
  output_root="$repo_root/$output_root"
fi

bundle="$output_root/Narwhal.app"
legacy_bundle="$output_root/WinMgr.app"
contents="$bundle/Contents"
macos="$contents/MacOS"
resources="$contents/Resources"
frameworks="$contents/Frameworks"
app_executable="$macos/NarwhalApp"
ctl_executable="$macos/narwhalctl"
lua_dylib="/opt/homebrew/opt/lua/lib/liblua.dylib"
minimum_macos_version="26.0"

if [ -e "$bundle" ] || [ -e "$legacy_bundle" ]; then
  if [ "$replace_existing" != "true" ]; then
    echo "package output exists; rerun with --replace: $output_root" >&2
    exit 1
  fi
  rm -rf "$bundle" "$legacy_bundle"
fi

if [ ! -f "$lua_dylib" ]; then
  echo "Lua dylib not found at $lua_dylib" >&2
  echo "Install Lua with: brew install lua" >&2
  exit 1
fi
if [ -n "$architecture" ] && ! lipo -archs "$lua_dylib" | tr ' ' '\n' | grep -Fxq "$architecture"; then
  echo "Lua dylib does not contain requested architecture $architecture: $lua_dylib" >&2
  exit 1
fi

macos_version_greater() {
  local actual="$1"
  local maximum="$2"
  awk -v actual="$actual" -v maximum="$maximum" '
    BEGIN {
      split(actual, a, ".")
      split(maximum, m, ".")
      for (i = 1; i <= 3; i++) {
        av = (a[i] == "" ? 0 : a[i]) + 0
        mv = (m[i] == "" ? 0 : m[i]) + 0
        if (av > mv) exit 0
        if (av < mv) exit 1
      }
      exit 1
    }
  '
}

lua_minos="$(vtool -show-build "$lua_dylib" 2>/dev/null | awk '
  /platform MACOS/ { in_macos = 1; next }
  in_macos && /minos/ { print $2; exit }
')"
if [ -z "$lua_minos" ]; then
  echo "Could not determine Lua dylib minimum macOS version: $lua_dylib" >&2
  exit 1
fi
if macos_version_greater "$lua_minos" "$minimum_macos_version"; then
  echo "Lua dylib minimum macOS $lua_minos exceeds Narwhal target macOS $minimum_macos_version: $lua_dylib" >&2
  echo "Build or provide a Lua dylib with minimum macOS <= $minimum_macos_version before packaging." >&2
  exit 1
fi

cd "$repo_root"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/private/tmp/narwhal-clang-module-cache}"
swiftpm_cache="$repo_root/.build/swiftpm-cache"
mkdir -p "$swiftpm_cache/cache" "$swiftpm_cache/config" "$swiftpm_cache/security"
swift_build_args=(
  --disable-sandbox
  --disable-dependency-cache
  --disable-build-manifest-caching
  --disable-experimental-prebuilts
  --cache-path "$swiftpm_cache/cache"
  --config-path "$swiftpm_cache/config"
  --security-path "$swiftpm_cache/security"
  --manifest-cache local
  --configuration "$configuration"
)
if [ -n "$architecture" ]; then
  swift_build_args+=(--arch "$architecture")
fi

swift build "${swift_build_args[@]}" --product NarwhalApp
swift build "${swift_build_args[@]}" --product NarwhalCtl

bin_path="$(swift build "${swift_build_args[@]}" --show-bin-path)"
mkdir -p "$macos" "$resources/DefaultConfig" "$frameworks"

cp "$bin_path/NarwhalApp" "$app_executable"
cp "$bin_path/NarwhalCtl" "$ctl_executable"
cp "$repo_root/Packaging/NarwhalInfo.plist" "$contents/Info.plist"
if [ -n "$display_version" ]; then
  plutil -replace CFBundleShortVersionString -string "$display_version" "$contents/Info.plist"
fi
if [ -n "$build_number" ]; then
  plutil -replace CFBundleVersion -string "$build_number" "$contents/Info.plist"
fi
cp "$repo_root/DefaultConfig/init.lua" "$resources/DefaultConfig/init.lua"
cp "$repo_root/Packaging/Assets/NarwhalIcon.icns" "$resources/NarwhalIcon.icns"
cp "$repo_root/Packaging/Assets/NarwhalToolbarIcon.png" "$resources/NarwhalToolbarIcon.png"
cp "$repo_root/Packaging/Assets/NarwhalToolbarIcon@2x.png" "$resources/NarwhalToolbarIcon@2x.png"
cp "$repo_root/Packaging/Assets/NarwhalToolbarIconDark.png" "$resources/NarwhalToolbarIconDark.png"
cp "$repo_root/Packaging/Assets/NarwhalToolbarIconDark@2x.png" "$resources/NarwhalToolbarIconDark@2x.png"
cp "$lua_dylib" "$frameworks/liblua.dylib"
chmod 755 "$app_executable" "$ctl_executable" "$frameworks/liblua.dylib"

if [ -n "$architecture" ]; then
  for binary in "$app_executable" "$ctl_executable" "$frameworks/liblua.dylib"; do
    binary_arches="$(lipo -archs "$binary")"
    if [ "$binary_arches" != "$architecture" ]; then
      echo "unexpected architectures for $binary: $binary_arches (expected $architecture)" >&2
      exit 1
    fi
  done
fi

lua_linked_path="$(otool -L "$app_executable" | awk '
  $1 ~ /\/liblua(\.[0-9]+)*\.dylib$/ { print $1; exit }
')"
if [ -z "$lua_linked_path" ]; then
  echo "Could not determine NarwhalApp Lua dependency install name" >&2
  exit 1
fi

install_name_tool -id "@rpath/liblua.dylib" "$frameworks/liblua.dylib"
install_name_tool -change "$lua_linked_path" "@executable_path/../Frameworks/liblua.dylib" "$app_executable"
if ! otool -L "$app_executable" | awk '$1 == "@executable_path/../Frameworks/liblua.dylib" { found = 1 } END { exit !found }'; then
  echo "NarwhalApp still references an external Lua dylib after packaging" >&2
  exit 1
fi

plutil -lint "$contents/Info.plist"

# Mode selected by NARWHAL_SIGNING_IDENTITY:
#   unset / "-" / "ad-hoc"          ad-hoc. cdhash drifts per build → TCC grant resets per install.
#   "<self-signed common name>"     local cert in login keychain. Stable TCC grant across rebuilds.
#   "Developer ID Application: ..." release. Adds hardened runtime, entitlements, timestamp.
signing_identity="${NARWHAL_SIGNING_IDENTITY:--}"
codesign_nested_args=(--force)
codesign_bundle_args=(--force --identifier "com.ben.narwhal")
signing_mode="ad-hoc"

case "$signing_identity" in
  ""|"-"|"ad-hoc")
    signing_identity="-"
    ;;
  "Developer ID Application: "*)
    signing_mode="developer-id"
    entitlements="$repo_root/Packaging/Narwhal.entitlements"
    if [ ! -f "$entitlements" ]; then
      echo "missing entitlements file: $entitlements" >&2
      exit 1
    fi
    codesign_nested_args+=(--options runtime --timestamp)
    codesign_bundle_args+=(--options runtime --timestamp --entitlements "$entitlements")
    ;;
  *)
    signing_mode="self-signed"
    if ! security find-identity -v -p codesigning | grep -F "\"$signing_identity\"" >/dev/null; then
      echo "code-signing identity not found in keychain: $signing_identity" >&2
      echo "create via Keychain Access → Certificate Assistant → Create a Certificate (Code Signing)" >&2
      exit 1
    fi
    ;;
esac

codesign_nested_args+=(--sign "$signing_identity")
codesign_bundle_args+=(--sign "$signing_identity")
echo "Signing: identity=$signing_identity mode=$signing_mode"
codesign "${codesign_nested_args[@]}" "$frameworks/liblua.dylib"
codesign "${codesign_nested_args[@]}" "$ctl_executable"
codesign "${codesign_bundle_args[@]}" "$bundle"
codesign --verify --deep --strict --verbose=2 "$bundle"

cat <<EOF
Built $bundle
Launch at Login is user-controlled from the Narwhal menu through SMAppService.
EOF
