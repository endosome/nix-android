#!/usr/bin/env bash
# Probe-gated fallbacks for Android older than 7 (SDK < 24), sourced by converge.sh.
#
# Contract: the modern command always runs first, exactly as before. A fallback
# runs only when that command's output positively names it as missing. Legacy
# `adb shell` does not return the remote exit status, so a missing command is
# recognised by its text, never by status; any other failure is passed on
# unchanged. Evidence: docs/PRIMITIVES.md (SM-G900F, Android 6.0.1, SDK 23).
#
# Expects `adb_shell` and, for ime_command, `$user` from the caller.

legacy_missing_cmd() { grep -Fq 'cmd: not found' <<<"$1"; }
legacy_unknown_user_option() { grep -Fq 'Error: Unknown option: --user' <<<"$1"; }
legacy_unknown_write_settings() { grep -Fq "Error: Unknown command: 'write-settings'" <<<"$1"; }

# Print the output of a modern attempt that did not hit a legacy signature, or
# fail with it. $1 = output, $2 = status of the attempt.
legacy_pass_through() {
  [ "$2" -eq 0 ] || {
    printf '%s\n' "$1" >&2
    return "$2"
  }
  printf '%s\n' "$1"
}

# `cmd deviceidle whitelist [+pkg|-pkg]`; legacy: `dumpsys deviceidle whitelist ...`.
deviceidle_whitelist() {
  local out rc=0
  out=$(adb_shell cmd deviceidle whitelist "$@" 2>&1) || rc=$?
  if legacy_missing_cmd "$out"; then
    adb_shell dumpsys deviceidle whitelist "$@"
    return
  fi
  legacy_pass_through "$out" "$rc"
}

# `appops write-settings`; legacy appops has no such command, dumpsys does.
appops_write_settings() {
  local out rc=0
  out=$(adb_shell appops write-settings 2>&1) || rc=$?
  if legacy_unknown_write_settings "$out"; then
    adb_shell dumpsys appops write-settings
    return
  fi
  legacy_pass_through "$out" "$rc"
}

# Legacy `ime` has no --user and acts on the current user, so the fallback is
# only taken when the active user is exactly the target user.
legacy_require_active_user() {
  local dump fields target=${user:?legacy fallbacks need the target user}
  dump=$(adb_shell dumpsys activity activities | tr -d '\r')
  fields=$(grep -E '^[[:space:]]*mCurrentUser=' <<<"$dump" | tr -d '[:space:]' || true)
  [ "$fields" = "mCurrentUser=$target" ] || {
    echo "legacy ime cannot select a user: refusing because the active user is not $target" >&2
    return 1
  }
}

# Legacy `ime` is only recognisable through `ime list`, which prints
# `Error: Unknown option: --user`. The write subcommands (enable/disable/set) do
# NOT: Android 6 takes `--user` as the input-method id and prints
# `Error: Unknown id: ...`. So legacy-ness is decided once, from `ime list`,
# and a legacy device never receives `--user` on a write.
legacy_ime_mode=

legacy_ime_probe() {
  [ -z "$legacy_ime_mode" ] || return 0
  local out
  out=$(adb_shell ime list -s --user "${user:?legacy fallbacks need the target user}" 2>&1) || true
  if legacy_unknown_user_option "$out"; then legacy_ime_mode=legacy; else legacy_ime_mode=modern; fi
}

legacy_strip_user() {
  local arg skip=0
  for arg in "$@"; do
    if [ "$skip" -eq 1 ]; then
      skip=0
    elif [ "$arg" = --user ]; then
      skip=1
    else
      printf '%s\n' "$arg"
    fi
  done
}

# ime_command SUBCOMMAND [-s] --user N [ID]  (arguments exactly as for modern ime)
# Call it directly (not inside $(...)) for writes so the probe result is kept.
ime_command() {
  local out rc=0 stripped=()
  if [ "$1" = list ]; then
    out=$(adb_shell ime "$@" 2>&1) || rc=$?
    if legacy_unknown_user_option "$out"; then
      legacy_require_active_user || return 1
      mapfile -t stripped < <(legacy_strip_user "$@")
      adb_shell ime "${stripped[@]}"
      return
    fi
    legacy_pass_through "$out" "$rc"
    return
  fi
  legacy_ime_probe
  if [ "$legacy_ime_mode" = legacy ]; then
    legacy_require_active_user || return 1
    mapfile -t stripped < <(legacy_strip_user "$@")
    adb_shell ime "${stripped[@]}"
    return
  fi
  adb_shell ime "$@"
}
