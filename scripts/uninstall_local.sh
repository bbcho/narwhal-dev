#!/usr/bin/env bash
set -euo pipefail

app_dir="$HOME/Applications"
keep_app="false"

usage() {
  cat <<'USAGE'
usage: scripts/uninstall_local.sh [options]

Unregisters Launch at Login, requests a graceful quit, and removes Narwhal.app
and its retained previous version unless --keep-app is set.

Options:
  --app-dir DIR   Directory containing Narwhal.app. Default: ~/Applications.
  --keep-app      Leave Narwhal.app installed after disabling Launch at Login.
  --help          Show this help.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --app-dir)
      [ "$#" -ge 2 ] || { echo "--app-dir requires a directory" >&2; exit 2; }
      app_dir="$2"
      shift 2
      ;;
    --keep-app)
      keep_app="true"
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
case "$app_dir" in
  ""|/)
    echo "refusing unsafe application directory: $app_dir" >&2
    exit 2
    ;;
esac

installed_app="$app_dir/Narwhal.app"
previous_app="$app_dir/Narwhal.app.previous"
ctl="$installed_app/Contents/MacOS/narwhalctl"
app_executable="$installed_app/Contents/MacOS/NarwhalApp"
socket_path="/tmp/narwhal-$(id -u).sock"
unregister_status="app-not-found"

wait_for_socket_absent() {
  local attempts=50
  for ((i = 0; i < attempts; i++)); do
    [ ! -S "$socket_path" ] && return 0
    sleep 0.1
  done
  [ ! -S "$socket_path" ]
}

if [ -x "$ctl" ] && [ -S "$socket_path" ]; then
  echo "Requesting Narwhal quit"
  "$ctl" quit >/dev/null
  wait_for_socket_absent || {
    echo "Narwhal did not stop; refusing to remove a running app" >&2
    exit 1
  }
fi

if [ -x "$app_executable" ]; then
  unregister_status="completed"
  "$app_executable" --unregister-login-item || {
    unregister_status="failed"
    echo "warning: Launch at Login could not be unregistered automatically" >&2
  }
fi

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
fi

if [ "$keep_app" != "true" ]; then
  rm -rf "$installed_app" "$previous_app" "$app_dir/WinMgr.app"
fi

cat <<EOF
Launch at Login unregister: $unregister_status
Removed app: $([ "$keep_app" = "true" ] && echo false || echo true)
Accessibility approval was not reset.
EOF
