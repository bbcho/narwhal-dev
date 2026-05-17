#!/usr/bin/env bash
set -euo pipefail

configuration="release"
output_root=""
replace_existing="false"

usage() {
  cat <<'USAGE'
usage: scripts/build_app_bundle.sh [--configuration debug|release] [--output DIR] [--replace]

Builds WinMgrApp and WinMgrCtl, then assembles:
  DIR/WinMgr.app
  DIR/com.ben.winmgr.plist

Default DIR is .build/winmgr-package.
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

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
if [ -z "$output_root" ]; then
  output_root="$repo_root/.build/winmgr-package"
elif [[ "$output_root" != /* ]]; then
  output_root="$repo_root/$output_root"
fi

bundle="$output_root/WinMgr.app"
contents="$bundle/Contents"
macos="$contents/MacOS"
resources="$contents/Resources"
frameworks="$contents/Frameworks"
app_executable="$macos/WinMgrApp"
ctl_executable="$macos/winmgrctl"
launch_agent="$output_root/com.ben.winmgr.plist"
lua_dylib="/opt/homebrew/opt/lua/lib/liblua.dylib"

if [ -e "$bundle" ] || [ -e "$launch_agent" ]; then
  if [ "$replace_existing" != "true" ]; then
    echo "package output exists; rerun with --replace: $output_root" >&2
    exit 1
  fi
  rm -rf "$bundle" "$launch_agent"
fi

if [ ! -f "$lua_dylib" ]; then
  echo "Lua dylib not found at $lua_dylib" >&2
  echo "Install Lua with: brew install lua" >&2
  exit 1
fi

cd "$repo_root"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/private/tmp/winmgr-clang-module-cache}"
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

swift build "${swift_build_args[@]}" --product WinMgrApp
swift build "${swift_build_args[@]}" --product WinMgrCtl

bin_path="$(swift build "${swift_build_args[@]}" --show-bin-path)"
mkdir -p "$macos" "$resources/DefaultConfig" "$frameworks"

cp "$bin_path/WinMgrApp" "$app_executable"
cp "$bin_path/WinMgrCtl" "$ctl_executable"
cp "$repo_root/Packaging/WinMgrInfo.plist" "$contents/Info.plist"
cp "$repo_root/DefaultConfig/init.lua" "$resources/DefaultConfig/init.lua"
cp "$lua_dylib" "$frameworks/liblua.dylib"
chmod 755 "$app_executable" "$ctl_executable" "$frameworks/liblua.dylib"

install_name_tool -id "@rpath/liblua.dylib" "$frameworks/liblua.dylib"
install_name_tool -change "$lua_dylib" "@executable_path/../Frameworks/liblua.dylib" "$app_executable"

cp "$repo_root/Packaging/com.ben.winmgr.plist" "$launch_agent"
plutil -insert ProgramArguments.0 -string "$app_executable" "$launch_agent"
plutil -replace WorkingDirectory -string "$repo_root" "$launch_agent"

plutil -lint "$contents/Info.plist" "$launch_agent"
codesign --force --deep --sign - "$bundle"

cat <<EOF
Built $bundle
Built $launch_agent

Install LaunchAgent:
  mkdir -p "$HOME/Library/LaunchAgents"
  cp "$launch_agent" "$HOME/Library/LaunchAgents/com.ben.winmgr.plist"
  launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.ben.winmgr.plist"

Unload LaunchAgent:
  launchctl bootout "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.ben.winmgr.plist"
EOF
