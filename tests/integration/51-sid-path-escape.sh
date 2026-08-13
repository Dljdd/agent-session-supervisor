#!/bin/bash
# tests/integration/51-sid-path-escape.sh — A-22 (critic SEC-12).
#
# Replay the session-start fixture (capture --start) with session_id set to
# `../../escape`, an empty string, and a 200-char string. Assert: nothing is
# created outside $CLAUDE_PLUGIN_DATA; the event `s` is the safe_sid substitute
# (`x` + 12 hex), never the raw; the raw value appears only inside the JSON body
# (`sid_raw`), never as a path component; sessions.index holds the safe_sid.
set -u
PLUGIN_ROOT=${PLUGIN_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
export PLUGIN_ROOT
. "$PLUGIN_ROOT/tests/lib.sh"

BIG=$(printf 'a%.0s' $(seq 1 200))   # 200-char session id

t_sandbox
mk_proj_plain

# Everything OUTSIDE the store must be byte-identical before and after.
outside_snapshot() { find "$T" -path "$CLAUDE_PLUGIN_DATA" -prune -o -print 2>/dev/null | LC_ALL=C sort; }
BEFORE=$(outside_snapshot)

run_start() {  # run_start <session_id>
  payload sessionstart-startup "session_id=$1" | "$PLUGIN_ROOT/scripts/hook-capture.sh" --start
}

run_start "../../escape"
run_start ""
run_start "$BIG"

AFTER=$(outside_snapshot)
[ "$BEFORE" = "$AFTER" ] || fail "something was created outside the store:
$(diff <(printf '%s' "$BEFORE") <(printf '%s' "$AFTER"))"

# No path component anywhere in $T carries the raw escape sequence.
if find "$T" -name '*..*' -o -name '*escape*' | grep -q .; then
  fail "raw sid leaked into a path component:
$(find "$T" -name '*..*' -o -name '*escape*')"
fi

EV=$(ls "$CLAUDE_PLUGIN_DATA"/projects/*/events.jsonl 2>/dev/null | head -n 1)
[ -n "$EV" ] || fail "no events.jsonl produced"
assert_json_lines "$EV"

# The escape sid: `s` is a safe substitute; the raw lives only in sid_raw.
esc_s=$(jq -r 'select(.sid_raw=="../../escape") | .s' "$EV" | head -n 1)
[ -n "$esc_s" ] || fail "no start event carrying sid_raw=../../escape"
printf '%s\n' "$esc_s" | LC_ALL=C grep -Eq '^x[0-9a-f]{12}$' \
  || fail "escape sid not sanitized to x+12hex: [$esc_s]"

# The 200-char sid is likewise substituted and recorded in sid_raw.
jq -e --arg b "$BIG" 'select(.sid_raw==$b) | .s | test("^x[0-9a-f]{12}$")' "$EV" >/dev/null \
  || fail "200-char sid not sanitized / sid_raw not recorded"

# sessions.index holds only safe_sids (x+12hex), never the raw.
IDX=$(ls "$CLAUDE_PLUGIN_DATA"/projects/*/sessions.index 2>/dev/null | head -n 1)
[ -n "$IDX" ] || fail "no sessions.index produced"
assert_not_grep_fixed "../../escape" "$IDX"
while IFS= read -r sid; do
  [ -n "$sid" ] || continue
  printf '%s\n' "$sid" | LC_ALL=C grep -Eq '^x[0-9a-f]{12}$' \
    || fail "sessions.index holds a non-safe sid: [$sid]"
done < "$IDX"

echo "A-22 ok: raw sids sanitized to x+12hex, raw only in sid_raw, nothing outside store"
