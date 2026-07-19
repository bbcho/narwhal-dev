#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
tmp_root="/private/tmp/narwhal-install-upgrade-smoke"
app_dir="$tmp_root/Applications"
package_dir="$tmp_root/package"
installed_app="$app_dir/Narwhal.app"
previous_app="$app_dir/Narwhal.app.previous"

fail() {
  echo "smoke_install_upgrade failed: $*" >&2
  exit 1
}

assert_version() {
  local app="$1"
  local version="$2"
  local build_number="$3"
  [ "$(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")" = "$version" ] \
    || fail "$app did not contain version $version"
  [ "$(plutil -extract CFBundleVersion raw "$app/Contents/Info.plist")" = "$build_number" ] \
    || fail "$app did not contain build $build_number"
  codesign --verify --deep --strict "$app" || fail "$app failed code-signature verification"
}

rm -rf "$tmp_root"
mkdir -p "$app_dir"

cd "$repo_root"
"$script_dir/install_local.sh" \
  --configuration debug \
  --package-dir "$package_dir" \
  --app-dir "$app_dir" \
  --version 1.0.0 \
  --build-number 100 \
  --architecture arm64
assert_version "$installed_app" 1.0.0 100
[ ! -e "$previous_app" ] || fail "initial install unexpectedly created a previous app"

"$script_dir/install_local.sh" \
  --configuration debug \
  --package-dir "$package_dir" \
  --app-dir "$app_dir" \
  --version 1.0.1 \
  --build-number 101 \
  --architecture arm64 \
  --replace
assert_version "$installed_app" 1.0.1 101
assert_version "$previous_app" 1.0.0 100

"$script_dir/uninstall_local.sh" --app-dir "$app_dir"
[ ! -e "$installed_app" ] || fail "uninstall retained the installed app"
[ ! -e "$previous_app" ] || fail "uninstall retained the previous app"

echo "smoke_install_upgrade passed"
