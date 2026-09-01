#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/installed_process.sh"

tmp_root="/private/tmp/narwhal process guard smoke"
app_root="$tmp_root/Applications With Spaces/Narwhal.app"
alias_root="$tmp_root/App Alias"
executable="$app_root/Contents/MacOS/NarwhalApp"
ctl="$app_root/Contents/MacOS/narwhalctl"
fixture_pid=""
unrelated_pid=""

cleanup() {
  for pid in "$fixture_pid" "$unrelated_pid"; do
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
  done
  rm -rf "$tmp_root"
}
trap cleanup EXIT

fail() {
  echo "smoke_installed_process_guard failed: $*" >&2
  exit 1
}

write_failing_ctl() {
  printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > "$ctl"
  chmod 755 "$ctl"
}

write_stopping_ctl() {
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'kill "$NARWHAL_FIXTURE_PID"' > "$ctl"
  chmod 755 "$ctl"
}

start_fixture() {
  "$executable" 60 &
  fixture_pid="$!"
}

rm -rf "$tmp_root"
mkdir -p "$app_root/Contents/MacOS"
clang "$script_dir/fixtures/narwhal_process_fixture.c" -o "$executable"
chmod 755 "$executable"
ln -s "$app_root" "$alias_root"

start_fixture
write_failing_ctl
if NARWHAL_FIXTURE_PID="$fixture_pid" narwhal_stop_installed_processes "$executable" "$ctl" 1; then
  fail "unresponsive installed process was accepted"
fi
kill -0 "$fixture_pid" 2>/dev/null || fail "failed guard terminated the installed process"

write_stopping_ctl
NARWHAL_FIXTURE_PID="$fixture_pid" narwhal_stop_installed_processes "$executable" "$ctl" 3 \
  || fail "responsive installed process was not stopped"
if kill -0 "$fixture_pid" 2>/dev/null; then
  fail "responsive installed process remained alive"
fi
wait "$fixture_pid" 2>/dev/null || true
fixture_pid=""

start_fixture
write_stopping_ctl
NARWHAL_FIXTURE_PID="$fixture_pid" narwhal_stop_installed_processes \
  "$alias_root/Contents/MacOS/NarwhalApp" "$ctl" 3 \
  || fail "symlinked app path did not match the installed executable inode"
wait "$fixture_pid" 2>/dev/null || true
fixture_pid=""

unrelated="$tmp_root/Unrelated/NarwhalApp"
mkdir -p "$(dirname "$unrelated")"
clang "$script_dir/fixtures/narwhal_process_fixture.c" -o "$unrelated"
chmod 755 "$unrelated"
"$unrelated" 60 &
unrelated_pid="$!"
matches="$(narwhal_matching_installed_pids "$executable")" \
  || fail "unrelated process scan failed"
[ -z "$matches" ] || fail "unrelated same-name executable matched installed inode"
kill -0 "$unrelated_pid" 2>/dev/null || fail "unrelated process was terminated"

start_fixture
if narwhal_matching_installed_pids "$executable" /bin/false >/dev/null; then
  fail "persistent inspection failure did not fail closed"
fi
kill "$fixture_pid"
wait "$fixture_pid" 2>/dev/null || true
fixture_pid=""

race_lsof="$tmp_root/race-lsof"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'pid=""' \
  'while [ "$#" -gt 0 ]; do' \
  '  if [ "$1" = "-p" ]; then pid="$2"; break; fi' \
  '  shift' \
  'done' \
  'if [ "$pid" = "$NARWHAL_FIXTURE_PID" ]; then kill "$pid" 2>/dev/null || true; exit 1; fi' \
  'exec /usr/sbin/lsof "$@"' > "$race_lsof"
chmod 755 "$race_lsof"
start_fixture
matches="$(NARWHAL_FIXTURE_PID="$fixture_pid" narwhal_matching_installed_pids "$executable" "$race_lsof")" \
  || fail "PID exit race did not retry identity enumeration"
[ -z "$matches" ] || fail "exited PID remained matched after identity retry"
wait "$fixture_pid" 2>/dev/null || true
fixture_pid=""

echo "smoke_installed_process_guard passed"
