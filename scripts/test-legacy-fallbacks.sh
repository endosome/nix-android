#!/usr/bin/env bash
# Fake-device tests for engine/legacy.sh. No phone is enumerated or changed.
# Pins two things: modern devices see exactly the commands they always saw (no
# probe traffic, no fallback), and legacy signatures trigger exactly one
# documented fallback. Legacy outputs are captured from a Samsung SM-G900F
# (Android 6.0.1, SDK 23) on 2026-10-05; see docs/PRIMITIVES.md.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR/../engine
# shellcheck source=legacy.sh
source "$(dirname "${BASH_SOURCE[0]}")/../engine/legacy.sh"

fail() {
  echo "test-legacy-fallbacks: $1" >&2
  exit 1
}

user=0
log=$(mktemp)
trap 'rm -f -- "$log"' EXIT

legacy_usage=$'Error: Unknown option: --user\nusage: ime list [-a] [-s]\n       ime enable ID'
# adb_shell fake. MODE: modern | legacy | legacy-status127 | broken | other-user
adb_shell() {
  printf '%s\n' "$*" >>"$log"
  case "$MODE:$*" in
  modern:'cmd deviceidle whitelist'*) printf 'user,org.example.app,10001\n' ;;
  modern:'appops write-settings') ;;
  modern:'ime '*) printf 'org.example/.Ime\n' ;;
  legacy*:'cmd deviceidle whitelist'*)
    printf '/system/bin/sh: cmd: not found\n'
    [ "$MODE" = legacy ] || return 127
    ;;
  legacy*:'dumpsys deviceidle whitelist'*) printf 'system-excidle,org.example.app,10001\n' ;;
  legacy*:'appops write-settings')
    printf "Error: Unknown command: 'write-settings'.\nusage: appops set ...\n"
    ;;
  legacy*:'dumpsys appops write-settings') printf 'Current settings written.\n' ;;
  legacy*:'ime list'*--user*) printf '%s\n' "$legacy_usage" ;;
  legacy*:'ime enable --user'* | legacy*:'ime disable --user'* | legacy*:'ime set --user'*)
    # Real Android 6: --user is taken as the input-method id. It must never be sent.
    printf 'Error: Unknown id: --user\n'
    echo 'legacy device received a --user ime write' >>"$log.bad"
    ;;
  legacy*:'ime '*) printf 'org.example/.Ime\n' ;;
  legacy*:'dumpsys activity activities') printf '  mCurrentUser=0\r\n' ;;
  other-user:'ime list'*--user*) printf '%s\n' "$legacy_usage" ;;
  other-user:'dumpsys activity activities') printf '  mCurrentUser=10\n' ;;
  broken:*)
    printf 'Error: boom\n'
    return 1
    ;;
  *) fail "unexpected command in $MODE mode: $*" ;;
  esac
}

run_case() { # MODE; remaining arguments are the function call
  MODE=$1
  shift
  : >"$log"
  "$@"
}
logged() { paste -sd'|' "$log"; }

# --- modern device: commands byte-identical to before, no fallback -----------
run_case modern deviceidle_whitelist >/dev/null
[ "$(logged)" = 'cmd deviceidle whitelist' ] || fail "modern idle read issued: $(logged)"
run_case modern deviceidle_whitelist '+org.example.app' >/dev/null
[ "$(logged)" = 'cmd deviceidle whitelist +org.example.app' ] || fail "modern idle write issued: $(logged)"
run_case modern appops_write_settings
[ "$(logged)" = 'appops write-settings' ] || fail "modern appops flush issued: $(logged)"
run_case modern ime_command list -s --user 0 >/dev/null
[ "$(logged)" = 'ime list -s --user 0' ] || fail "modern ime list issued: $(logged)"
legacy_ime_mode=
run_case modern ime_command enable --user 0 'org.example/.Ime' >/dev/null
# One read-only probe precedes the first ime write; later writes reuse the answer.
[ "$(logged)" = 'ime list -s --user 0|ime enable --user 0 org.example/.Ime' ] || fail "modern ime enable issued: $(logged)"
run_case modern ime_command disable --user 0 'org.example/.Ime' >/dev/null
[ "$(logged)" = 'ime disable --user 0 org.example/.Ime' ] || fail "modern ime probe was repeated: $(logged)"

# --- legacy device: one documented fallback each ------------------------------
for mode in legacy legacy-status127; do
  out=$(run_case "$mode" deviceidle_whitelist)
  [ "$(logged)" = 'cmd deviceidle whitelist|dumpsys deviceidle whitelist' ] || fail "$mode idle read issued: $(logged)"
  grep -Fq 'system-excidle,org.example.app,10001' <<<"$out" || fail "$mode idle read lost the fallback output"
  grep -Fq 'not found' <<<"$out" && fail "$mode idle read leaked the probe error"
  run_case "$mode" deviceidle_whitelist '-org.example.app' >/dev/null
  [ "$(logged)" = 'cmd deviceidle whitelist -org.example.app|dumpsys deviceidle whitelist -org.example.app' ] \
    || fail "$mode idle write issued: $(logged)"
  run_case "$mode" appops_write_settings >/dev/null
  [ "$(logged)" = 'appops write-settings|dumpsys appops write-settings' ] || fail "$mode appops flush issued: $(logged)"
  run_case "$mode" ime_command list -s --user 0 >/dev/null
  [ "$(logged)" = 'ime list -s --user 0|dumpsys activity activities|ime list -s' ] || fail "$mode ime list issued: $(logged)"
  legacy_ime_mode=
  run_case "$mode" ime_command set --user 0 'org.example/.Ime' >/dev/null
  [ "$(logged)" = 'ime list -s --user 0|dumpsys activity activities|ime set org.example/.Ime' ] \
    || fail "$mode ime set issued: $(logged)"
  run_case "$mode" ime_command disable --user 0 'org.example/.Ime' >/dev/null
  [ "$(logged)" = 'dumpsys activity activities|ime disable org.example/.Ime' ] || fail "$mode ime probe repeated or --user leaked: $(logged)"
  [ ! -e "$log.bad" ] || fail 'a legacy device was sent a --user ime write'
done

# --- the legacy ime fallback never targets a user it cannot select -----------
legacy_ime_mode=
if run_case other-user ime_command enable --user 0 'org.example/.Ime' >/dev/null 2>&1; then
  fail 'legacy ime fallback ran while another user was active'
fi
grep -Fxq 'ime enable org.example/.Ime' "$log" && fail 'legacy ime wrote without a --user guarantee'
legacy_ime_mode=
if run_case other-user ime_command list -s --user 0 >/dev/null 2>&1; then
  fail 'legacy ime list ran while another user was active'
fi

# --- genuine failures pass through: no fallback, status preserved ------------
legacy_ime_mode=
for call in 'deviceidle_whitelist +org.example.app' 'appops_write_settings' 'ime_command list -s --user 0'; do
  # shellcheck disable=SC2086
  if run_case broken $call >/dev/null 2>&1; then fail "failure swallowed: $call"; fi
  [ "$(wc -l <"$log")" -eq 1 ] || fail "failure triggered a fallback: $call"
done

echo 'test-legacy-fallbacks: ok'
