#!/usr/bin/env bash

narwhal_runtime_dir() {
  local directory owner mode
  directory="$(/usr/bin/getconf DARWIN_USER_TEMP_DIR)" || return 2
  directory="${directory%/}"
  [ -n "$directory" ] && [ -d "$directory" ] || return 2
  owner="$(stat -f '%u' "$directory")" || return 2
  mode="$(stat -f '%Lp' "$directory")" || return 2
  [ "$owner" = "$(id -u)" ] || return 2
  [ $((8#$mode & 077)) -eq 0 ] || return 2
  printf '%s\n' "$directory"
}

narwhal_socket_path() {
  local directory
  directory="$(narwhal_runtime_dir)" || return 2
  printf '%s/narwhal.sock\n' "$directory"
}
