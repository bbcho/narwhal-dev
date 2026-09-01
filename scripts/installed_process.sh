#!/usr/bin/env bash

narwhal_candidate_pids() {
  local output status
  if output="$(/usr/bin/pgrep -x NarwhalApp 2>/dev/null)"; then
    printf '%s\n' "$output"
    return 0
  else
    status="$?"
  fi
  [ "$status" -eq 1 ] && return 0
  echo "could not enumerate NarwhalApp processes" >&2
  return 2
}

narwhal_pid_is_candidate() {
  local target_pid="$1"
  local candidates candidate
  candidates="$(narwhal_candidate_pids)" || return 2
  while IFS= read -r candidate; do
    [ "$candidate" = "$target_pid" ] && return 0
  done <<< "$candidates"
  return 1
}

narwhal_matching_installed_pids() {
  local executable="$1"
  local lsof_command="${2:-/usr/sbin/lsof}"
  local target_identity target_device target_inode candidates pid output line device inode
  local attempt invalidated found_record matched
  local -a matches

  target_identity="$(stat -f '%d:%i' "$executable")" || {
    echo "could not inspect installed executable: $executable" >&2
    return 2
  }
  target_device="${target_identity%%:*}"
  target_inode="${target_identity##*:}"

  for attempt in 1 2 3; do
    candidates="$(narwhal_candidate_pids)" || return 2
    invalidated="false"
    matches=()

    while IFS= read -r pid; do
      [ -n "$pid" ] || continue
      if ! output="$("$lsof_command" -a -p "$pid" -d txt -F Din 2>/dev/null)"; then
        if narwhal_pid_is_candidate "$pid"; then
          echo "could not inspect NarwhalApp pid $pid" >&2
          return 2
        fi
        invalidated="true"
        break
      fi

      found_record="false"
      matched="false"
      device=""
      inode=""
      while IFS= read -r line; do
        case "$line" in
          ftxt)
            device=""
            inode=""
            ;;
          D*) device="${line#D}" ;;
          i*) inode="${line#i}" ;;
          n*)
            if [ -z "$device" ] || [ -z "$inode" ]; then
              echo "malformed text vnode data for NarwhalApp pid $pid" >&2
              return 2
            fi
            found_record="true"
            if [ $((device)) -eq "$target_device" ] && [ "$inode" = "$target_inode" ]; then
              matched="true"
            fi
            ;;
        esac
      done <<< "$output"
      [ "$invalidated" = "false" ] || break
      if [ "$found_record" != "true" ]; then
        echo "NarwhalApp pid $pid exposed no text vnodes" >&2
        return 2
      fi
      if [ "$matched" = "true" ]; then
        if narwhal_pid_is_candidate "$pid"; then
          matches+=("$pid")
        else
          invalidated="true"
          break
        fi
      fi
    done <<< "$candidates"

    if [ "$invalidated" = "true" ]; then
      continue
    fi
    if [ "${#matches[@]}" -gt 0 ]; then
      printf '%s\n' "${matches[@]}"
    fi
    return 0
  done

  echo "NarwhalApp identity scan was unstable" >&2
  return 2
}

narwhal_stop_installed_processes() {
  local executable="$1"
  local ctl="$2"
  local timeout_seconds="$3"
  local matches deadline

  matches="$(narwhal_matching_installed_pids "$executable")" || return 2
  [ -n "$matches" ] || return 0
  [ -x "$ctl" ] || {
    echo "installed NarwhalApp is running but narwhalctl is unavailable: $ctl" >&2
    return 2
  }

  if ! "$ctl" quit >/dev/null 2>&1; then
    matches="$(narwhal_matching_installed_pids "$executable")" || return 2
    [ -z "$matches" ] && return 0
    echo "installed narwhalctl could not stop the exact running app" >&2
    return 2
  fi

  deadline=$((SECONDS + timeout_seconds))
  while [ "$SECONDS" -le "$deadline" ]; do
    matches="$(narwhal_matching_installed_pids "$executable")" || return 2
    [ -z "$matches" ] && return 0
    sleep 0.1
  done
  echo "exact installed NarwhalApp process did not stop before deadline" >&2
  return 2
}
