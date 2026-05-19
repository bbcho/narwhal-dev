#!/usr/bin/env bash
set -euo pipefail

app_dir="$HOME/Applications"
launch_agents_dir="$HOME/Library/LaunchAgents"
keep_app="false"
use_launchctl="true"

usage() {
  cat <<'USAGE'
usage: scripts/uninstall_local.sh [options]

Boots out the local LaunchAgent, removes its plist, and removes Narwhal.app
unless --keep-app is set.

Options:
  --app-dir DIR             Directory containing Narwhal.app. Default: ~/Applications.
  --launch-agents-dir DIR   LaunchAgent directory. Default: ~/Library/LaunchAgents.
  --keep-app                Leave Narwhal.app installed.
  --no-launchctl            Do not run launchctl bootout.
  --help                    Show this help.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
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
    --keep-app)
      keep_app="true"
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

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
if [[ "$app_dir" != /* ]]; then
  app_dir="$repo_root/$app_dir"
fi
if [[ "$launch_agents_dir" != /* ]]; then
  launch_agents_dir="$repo_root/$launch_agents_dir"
fi

installed_app="$app_dir/Narwhal.app"
launch_agent="$launch_agents_dir/com.ben.narwhal.plist"
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

if [ "$use_launchctl" = "true" ] && [ -e "$launch_agent" ]; then
  graceful_quit_existing_app
  launchctl bootout "gui/$(id -u)" "$launch_agent" 2>/dev/null || true
fi

rm -f "$launch_agent"
if [ "$keep_app" != "true" ]; then
  rm -rf "$installed_app"
fi

cat <<EOF
Removed $launch_agent
Removed app: $([ "$keep_app" = "true" ] && echo false || echo true)
EOF
