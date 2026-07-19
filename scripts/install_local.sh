#!/usr/bin/env bash
set -euo pipefail

configuration="release"
package_dir=""
app_dir="$HOME/Applications"
replace_existing="false"

usage() {
  cat <<'USAGE'
usage: scripts/install_local.sh [options]

Builds and installs Narwhal.app. Launch at Login remains user-controlled from
the Narwhal menu and Accessibility approval is never reset by this script.

Options:
  --configuration debug|release   Build configuration. Default: release.
  --package-dir DIR               Package output. Default: .build/narwhal-package-install.
  --app-dir DIR                   Directory containing Narwhal.app. Default: ~/Applications.
  --replace                       Replace an existing app and retain Narwhal.app.previous.
  --help                          Show this help.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --configuration)
      [ "$#" -ge 2 ] || { echo "--configuration requires debug or release" >&2; exit 2; }
      configuration="$2"
      shift 2
      ;;
    --package-dir)
      [ "$#" -ge 2 ] || { echo "--package-dir requires a directory" >&2; exit 2; }
      package_dir="$2"
      shift 2
      ;;
    --app-dir)
      [ "$#" -ge 2 ] || { echo "--app-dir requires a directory" >&2; exit 2; }
      app_dir="$2"
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
if [ -z "$package_dir" ]; then
  package_dir="$repo_root/.build/narwhal-package-install"
elif [[ "$package_dir" != /* ]]; then
  package_dir="$repo_root/$package_dir"
fi
if [[ "$app_dir" != /* ]]; then
  app_dir="$repo_root/$app_dir"
fi
case "$app_dir" in
  ""|/)
    echo "refusing unsafe application directory: $app_dir" >&2
    exit 2
    ;;
esac

source_app="$package_dir/Narwhal.app"
installed_app="$app_dir/Narwhal.app"
previous_app="$app_dir/Narwhal.app.previous"
staged_app="$app_dir/.Narwhal.app.installing.$$"
socket_path="/tmp/narwhal-$(id -u).sock"
installed_ctl="$installed_app/Contents/MacOS/narwhalctl"
legacy_app="$app_dir/WinMgr.app"
did_backup="false"
install_succeeded="false"

cleanup() {
  local status="$?"
  rm -rf "$staged_app"
  if [ "$install_succeeded" != "true" ] \
      && [ "$did_backup" = "true" ] \
      && [ ! -e "$installed_app" ] \
      && [ -e "$previous_app" ]; then
    mv "$previous_app" "$installed_app"
  fi
  return "$status"
}
trap cleanup EXIT

wait_for_socket_absent() {
  local attempts=50
  for ((i = 0; i < attempts; i++)); do
    [ ! -S "$socket_path" ] && return 0
    sleep 0.1
  done
  [ ! -S "$socket_path" ]
}

if [ "$replace_existing" != "true" ] && { [ -e "$installed_app" ] || [ -e "$legacy_app" ]; }; then
  echo "install target exists; rerun with --replace" >&2
  echo "  app: $installed_app" >&2
  echo "  legacy app: $legacy_app" >&2
  exit 1
fi

"$repo_root/scripts/build_app_bundle.sh" \
  --configuration "$configuration" \
  --output "$package_dir" \
  --replace

codesign --verify --deep --strict "$source_app"
mkdir -p "$app_dir"
cp -R "$source_app" "$staged_app"
codesign --verify --deep --strict "$staged_app"

if [ -x "$installed_ctl" ] && [ -S "$socket_path" ]; then
  echo "Requesting Narwhal quit before replacement"
  "$installed_ctl" quit >/dev/null
  wait_for_socket_absent || {
    echo "Narwhal did not stop before replacement" >&2
    exit 1
  }
fi

if [ -e "$installed_app" ]; then
  rm -rf "$previous_app"
  mv "$installed_app" "$previous_app"
  did_backup="true"
fi

mv "$staged_app" "$installed_app"
codesign --verify --deep --strict "$installed_app"

if [ "$app_dir" = "$HOME/Applications" ]; then
  launch_agent="$HOME/Library/LaunchAgents/com.ben.narwhal.plist"
  legacy_launch_agent="$HOME/Library/LaunchAgents/com.ben.winmgr.plist"
  if [ -e "$launch_agent" ]; then
    launchctl bootout "gui/$(id -u)" "$launch_agent" 2>/dev/null || true
    rm -f "$launch_agent"
  fi
  if [ -e "$legacy_launch_agent" ]; then
    launchctl bootout "gui/$(id -u)" "$legacy_launch_agent" 2>/dev/null || true
    rm -f "$legacy_launch_agent"
  fi
  rm -rf "$legacy_app"
fi

install_succeeded="true"
cat <<EOF
Installed $installed_app
Previous version retained: $([ -e "$previous_app" ] && echo "$previous_app" || echo none)
Accessibility approval was not changed.
Open Narwhal and use its menu to control Launch at Login.
EOF
