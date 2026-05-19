#!/usr/bin/env bash
set -euo pipefail

configuration="release"
package_dir=""
app_dir="$HOME/Applications"
launch_agents_dir="$HOME/Library/LaunchAgents"
replace_existing="false"
use_launchctl="true"

usage() {
  cat <<'USAGE'
usage: scripts/install_local.sh [options]

Builds a local package, installs Narwhal.app, writes a LaunchAgent plist, and
bootstraps it unless --no-launchctl is set.

Options:
  --configuration debug|release   Build configuration. Default: release.
  --package-dir DIR               Temporary package output. Default: .build/narwhal-package-install.
  --app-dir DIR                   Directory that will contain Narwhal.app. Default: ~/Applications.
  --launch-agents-dir DIR         LaunchAgent directory. Default: ~/Library/LaunchAgents.
  --replace                       Replace an existing installed app/plist.
  --no-launchctl                  Do not run launchctl bootout/bootstrap.
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
    --launch-agents-dir)
      [ "$#" -ge 2 ] || { echo "--launch-agents-dir requires a directory" >&2; exit 2; }
      launch_agents_dir="$2"
      shift 2
      ;;
    --replace)
      replace_existing="true"
      shift
      ;;
    --no-launchctl)
      use_launchctl="false"
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
if [[ "$launch_agents_dir" != /* ]]; then
  launch_agents_dir="$repo_root/$launch_agents_dir"
fi

source_app="$package_dir/Narwhal.app"
installed_app="$app_dir/Narwhal.app"
launch_agent="$launch_agents_dir/com.ben.narwhal.plist"
app_executable="$installed_app/Contents/MacOS/NarwhalApp"
socket_path="/tmp/narwhal-$(id -u).sock"

wait_for_socket_absent() {
  local attempts="$1"
  local delay="$2"
  for ((i = 0; i < attempts; i++)); do
    [ ! -S "$socket_path" ] && return 0
    sleep "$delay"
  done
  [ ! -S "$socket_path" ]
}

graceful_quit_existing_app() {
  local ctl="$installed_app/Contents/MacOS/narwhalctl"
  if [ "$use_launchctl" != "true" ]; then
    return 0
  fi
  if [ -x "$ctl" ] && [ -S "$socket_path" ]; then
    echo "Requesting Narwhal quit before LaunchAgent bootout"
    "$ctl" quit >/dev/null 2>&1 || true
    wait_for_socket_absent 50 0.1 || true
  fi
}

if [ "$replace_existing" != "true" ] && { [ -e "$installed_app" ] || [ -e "$launch_agent" ]; }; then
  echo "install target exists; rerun with --replace" >&2
  echo "  app: $installed_app" >&2
  echo "  plist: $launch_agent" >&2
  exit 1
fi

build_args=(--configuration "$configuration" --output "$package_dir" --replace)
"$repo_root/scripts/build_app_bundle.sh" "${build_args[@]}"

if [ -e "$installed_app" ] || [ -e "$launch_agent" ]; then
  graceful_quit_existing_app
  if [ "$use_launchctl" = "true" ] && [ -e "$launch_agent" ]; then
    launchctl bootout "gui/$(id -u)" "$launch_agent" 2>/dev/null || true
  fi
  rm -rf "$installed_app" "$launch_agent"
fi

mkdir -p "$app_dir" "$launch_agents_dir"
cp -R "$source_app" "$installed_app"
cp "$repo_root/Packaging/com.ben.narwhal.plist" "$launch_agent"
plutil -insert ProgramArguments.0 -string "$app_executable" "$launch_agent"
plutil -replace WorkingDirectory -string "$HOME" "$launch_agent"
plutil -lint "$launch_agent"

if [ "$use_launchctl" = "true" ]; then
  launchctl bootout "gui/$(id -u)" "$launch_agent" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$launch_agent"
fi

cat <<EOF
Installed $installed_app
Installed $launch_agent
LaunchAgent active: $use_launchctl
EOF
