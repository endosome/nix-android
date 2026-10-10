#!/usr/bin/env bash
# Fake-device tests for keyboard layouts (android.inputMethod.subtypes). No phone is enumerated or changed.
# The fake answers `dumpsys input_method` from tests/fixtures/dumpsys-input-method.txt (trimmed from a GrapheneOS
# Android 17 Pixel 8a, 2026-10-10) and keeps one value, Settings.Secure.enabled_input_methods, which it can also
# rewrite on its own (a device that does not keep the write) or refuse.
set -euo pipefail

src=${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
bash_bin=${2:-$(command -v bash)}
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
fail() { echo "test-ime-subtypes: $1" >&2; exit 1; }
LATIN=com.android.inputmethod.latin/.LatinIME
EN=-921088104 PL=1124698716 GB=-1337596075

# --- pure parsers -------------------------------------------------------------
# shellcheck source-path=SCRIPTDIR/../engine
# shellcheck source=../engine/read-state.sh
source "$src/engine/read-state.sh"
table=$(ime_subtype_table <"$src/tests/fixtures/dumpsys-input-method.txt")
[ "$(wc -l <<<"$table")" -eq 5 ] || fail "expected the 5 keyboard subtypes (the voice one excluded), got: $table"
[ "$(ime_subtype_hash "$LATIN" pl <<<"$table")" = "$PL" ] || fail 'pl did not resolve'
[ "$(ime_subtype_hash "$LATIN" en_US <<<"$table")" = "$EN" ] || fail 'en_US did not resolve'
rc=0; ime_subtype_hash "$LATIN" bg <<<"$table" >/dev/null || rc=$?; [ "$rc" -eq 2 ] || fail "an ambiguous locale gave $rc"
rc=0; ime_subtype_hash "$LATIN" pl_PL <<<"$table" >/dev/null || rc=$?; [ "$rc" -eq 1 ] || fail "an unknown locale gave $rc"
rc=0; ime_subtype_hash org.example.voice/.VoiceIme pl <<<"$table" >/dev/null || rc=$?; [ "$rc" -eq 1 ] || fail 'a voice subtype was taken for a keyboard'
[ "$(printf '\r\n' | ime_subtype_table | wc -c)" -eq 0 ] || fail 'an empty dump produced rows'

merge() { local value=$1; shift; ime_subtypes_merged "$@" <<<"$value"; }
[ "$(merge "$LATIN" "$LATIN" "$EN" "$PL")" = "$LATIN;$EN;$PL" ] || fail 'implicit entry'
[ "$(merge "$LATIN;$PL" "$LATIN" "$EN" "$PL")" = "$LATIN;$PL;$EN" ] || fail 'existing order must be kept'
[ "$(merge "$LATIN;$EN;$GB;$PL" "$LATIN" "$EN" "$PL")" = "$LATIN;$EN;$GB;$PL" ] || fail 'a satisfied entry must be unchanged'
[ "$(merge "a.b/.V:$LATIN;$GB:c.d/.W;9" "$LATIN" "$EN" "$PL")" = "a.b/.V:$LATIN;$GB;$EN;$PL:c.d/.W;9" ] || fail 'other entries must be kept in place'
[ "$(merge "com.android.inputmethod.latin/com.android.inputmethod.latin.LatinIME;$EN" "$LATIN" "$EN" "$PL")" \
  = "com.android.inputmethod.latin/com.android.inputmethod.latin.LatinIME;$EN;$PL" ] || fail 'a long component spelling must match and be kept'
[ "$(merge "$LATIN;12" "$LATIN" 1 2)" = "$LATIN;12;1;2" ] || fail 'hash matching must be exact'
for bad in "a.b/.V" "" "null"; do
  rc=0; merge "$bad" "$LATIN" "$EN" >/dev/null || rc=$?; [ "$rc" -eq 3 ] || fail "no entry for the component in '$bad' gave $rc"
done
for bad in "$LATIN;$EN;rm -rf" "$LATIN;;$EN" "$LATIN::a.b/.V" "$LATIN;\$(reboot)" "garbage"; do
  rc=0; merge "$bad" "$LATIN" "$EN" >/dev/null || rc=$?; [ "$rc" -eq 4 ] || fail "an unparseable value '$bad' gave $rc"
done
[ "$(ime_enabled_subtypes "$LATIN" <<<"a.b/.V;9:$LATIN;$PL;$EN" | paste -sd,)" = "$PL,$EN" ] || fail 'ime_enabled_subtypes'

# --- the engine against a stateful fake ------------------------------------------
export TEST_LOG=$tmp/adb.log TEST_IMES=$tmp/imes TEST_WRITES=$tmp/writes TEST_DUMP=$src/tests/fixtures/dumpsys-input-method.txt
fake="$tmp/fake adb"
printf '#!%s\n' "$bash_bin" > "$fake"
cat >> "$fake" <<'FAKE'
set -euo pipefail
[ "$1" = -s ] && [ "$2" = fixture ] || exit 92
shift 2
printf '%s\n' "$*" >> "$TEST_LOG"
case $* in
*ro.product.cpu.abi*) printf 'x86_64\n' ;;
*"'pm' 'list' 'packages' '-3' '--show-versioncode' '--user' '0'"*) ;;
*"'pm' 'list' 'packages' '--show-versioncode' '--user' '0'"*) printf 'package:com.android.inputmethod.latin versionCode:30\npackage:org.example.voice versionCode:1\n' ;;
*"'pm' 'list' 'packages' '--user' '0' "*) all=$*; p=${all##* }; printf 'package:%s\n' "${p//\'/}" ;;
*"'dumpsys' 'input_method'"*) cat "$TEST_DUMP" ;;
*"'ime' 'list' '-s' '--user' '0'"*) tr ':' '\n' < "$TEST_IMES" | cut -d';' -f1 ;;
*"'settings' 'get' '--user' '0' 'secure' 'enabled_input_methods'"*) cat "$TEST_IMES" ;;
*"'settings' 'put' '--user' '0' 'secure' 'enabled_input_methods' "*)
  all=$*; value=${all##* }; value=${value//\'/}
  printf '%s\n' "$value" >> "$TEST_WRITES"
  [ "${TEST_REFUSE:-0}" = 1 ] && { echo 'fake: refused' >&2; exit 1; }
  [ "${TEST_REWRITE:-0}" = 1 ] && value=${value%;*}
  printf '%s\n' "$value" > "$TEST_IMES"
  ;;
*) exit 99 ;;
esac
FAKE
chmod +x "$fake"
export NIX_ANDROID_ADB="$fake"

jq -n '{
  manifestVersion: 7, device: {name: "test", abi: "x86_64", user: 0},
  apps: {cleanup: "none", attended: [], play: [], managed: [], reown: false},
  android: {
    settings: {global: {}, secure: {}, system: {}}, darkMode: null,
    roles: {}, disabled: [], suspended: [], unsuspended: [], permissions: {},
    appOps: {}, locales: {}, inputMethod: {enabled: [], disabled: [], default: null, subtypes: {}},
    dataSaver: {enabled: null}, appLinks: {}, deviceidleExempt: [], deviceidleUnexempt: [],
    doNotDisturb: {mode: null}
  }
}' > "$tmp/base.json"
with_layouts() { jq --argjson l "$1" --arg c "$LATIN" '.android.inputMethod.subtypes = {($c): $l}' "$tmp/base.json" > "$tmp/m.json"; }
converge() { "$bash_bin" "$src/engine/converge.sh" "$tmp/m.json" "$@" --serial fixture; }
reset() { : > "$TEST_LOG"; : > "$TEST_WRITES"; printf '%s\n' "$1" > "$TEST_IMES"; }
writes() { paste -sd' ' "$TEST_WRITES"; }

# 1. implicit layouts (the Pixel today): the plan is read-only and names both, apply writes the explicit list once, a second apply is a no-op
with_layouts '["en_US", "pl"]'
reset "$LATIN"
# a pending plan exits 3 (exit-code contract, USING.md)
status=0; plan=$(converge) || status=$?
[ "$status" -eq 3 ] || fail "plan: expected exit 3, got $status"
grep -Fqx "ime-sub  $LATIN +en_US +pl" <<<"$plan" || fail "plan line missing: $plan"
[ -z "$(writes)" ] || fail 'the plan wrote'
converge --apply >/dev/null || fail 'apply failed'
[ "$(writes)" = "$LATIN;$EN;$PL" ] || fail "apply wrote: $(writes)"
: > "$TEST_WRITES"
converge --apply >/dev/null || fail 'second apply failed'
[ -z "$(writes)" ] || fail "second apply wrote: $(writes)"
grep -Fq 'device matches manifest' <<<"$(converge)" || fail 'plan after apply must be clean'

# 2. English already explicit, another layout and another input method present: only Polish is added, nothing else moves
reset "org.example.voice/.VoiceIme:$LATIN;$EN;$GB"
grep -Fqx "ime-sub  $LATIN +pl" <<<"$(converge)" || fail 'only pl should be planned'
converge --apply >/dev/null
[ "$(cat "$TEST_IMES")" = "org.example.voice/.VoiceIme:$LATIN;$EN;$GB;$PL" ] || fail "result: $(cat "$TEST_IMES")"

# 3. refusals: an unknown or ambiguous layout, a keyboard that is not enabled, an unreadable value; none writes
for case in '["pl_PL"]:offered' '["bg"]:more than once' ; do
  with_layouts "${case%%:*}"; reset "$LATIN"
  out=$(converge --apply 2>&1) && fail "accepted ${case%%:*}"
  grep -Fq "${case#*:}" <<<"$out" || fail "message for ${case%%:*}: $out"
  [ -z "$(writes)" ] || fail "wrote for ${case%%:*}"
done
with_layouts '["pl"]'; reset "org.example.voice/.VoiceIme"
out=$(converge --apply 2>&1) && fail 'accepted a keyboard that is not enabled'
grep -Fq 'neither enabled' <<<"$out" || fail "message: $out"
reset "$LATIN;garbage value"
out=$(converge --apply 2>&1) && fail 'accepted an unparseable value'
[ -z "$(writes)" ] || fail 'wrote over an unparseable value'

# 4. a write that does not stick, or is refused, fails the apply
with_layouts '["en_US", "pl"]'
reset "$LATIN"; export TEST_REWRITE=1
out=$(converge --apply 2>&1) && fail 'a write that did not stick passed'
grep -Fq 'did not stick' <<<"$out" || fail "message: $out"
unset TEST_REWRITE
reset "$LATIN"; export TEST_REFUSE=1
converge --apply >/dev/null 2>&1 && fail 'a refused write passed'
unset TEST_REFUSE

# 5. an older manifest (version 6) has no subtypes key and still validates; a version-7 one must have it
jq '.manifestVersion = 6 | del(.android.inputMethod.subtypes)' "$tmp/base.json" > "$tmp/m.json"
converge --validate-only || fail 'a version-6 manifest no longer validates'
jq 'del(.android.inputMethod.subtypes)' "$tmp/base.json" > "$tmp/m.json"
converge --validate-only 2>/dev/null && fail 'a version-7 manifest without subtypes validated'
for bad in '{"bad component": ["pl"]}' '{"a.b/.C": []}' '{"a.b/.C": ["pl", "pl"]}' '{"a.b/.C": ["p l"]}' '{"a.b/.C": "pl"}'; do
  jq --argjson s "$bad" '.android.inputMethod.subtypes = $s' "$tmp/base.json" > "$tmp/m.json"
  converge --validate-only 2>/dev/null && fail "validated $bad"
done

echo 'test-ime-subtypes: all checks passed'
