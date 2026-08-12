#!/bin/bash
# 18-project-keying.sh — I-09. (a) Two dirs with the SAME origin URL key to the
# same <project-key>. (b) A plain dir keys off cwd. (c) A remote URL with
# embedded credentials keys to the CLEAN-URL key AND the raw token never appears
# anywhere in the data dir (including meta.json) — userinfo stripped before
# hashing (design §4.2).
set -u
PLUGIN_ROOT=${PLUGIN_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
export PLUGIN_ROOT
. "$PLUGIN_ROOT/tests/lib.sh"
t_sandbox
mk_proj_plain
awake_off
_py=$(command -v python3)
COMMON="$PLUGIN_ROOT/scripts/py/supervisor_common.py"
key_of() { "$_py" "$COMMON" key "$1"; }

# (a) same origin, two URL forms -> same key
mkdir -p "$T/a" "$T/b"
git -C "$T/a" init -q; git -C "$T/a" remote add origin https://github.com/acme/repo.git
git -C "$T/b" init -q; git -C "$T/b" remote add origin git@github.com:acme/repo.git
ka=$(key_of "$T/a"); kb=$(key_of "$T/b")
[ -n "$ka" ] || fail "empty key for a"
[ "$ka" = "$kb" ] || fail "same-origin dirs keyed differently: $ka vs $kb"

# (b) plain dir keys off cwd (differs from the remote key)
mkdir -p "$T/plain"
kp=$(key_of "$T/plain")
[ -n "$kp" ] || fail "empty key for plain dir"
[ "$kp" != "$ka" ] || fail "plain dir collided with remote key"

# (c) credentials in the URL -> clean-url key, token never stored
TOKEN='ghp_TOKENabcdef0123456789ABCDEFghij'
mkdir -p "$T/c"
git -C "$T/c" init -q
git -C "$T/c" remote add origin "https://alice:$TOKEN@github.com/acme/repo.git"
kc=$(key_of "$T/c")
[ "$kc" = "$ka" ] || fail "cred URL keyed to [$kc], want clean [$ka]"
# drive a real session-start so meta.json is written for project c, then grep.
payload sessionstart-startup session_id=s1 cwd="$T/c" | run_hook hook-session-start.sh >/dev/null
assert_not_grep_fixed "$TOKEN" "$CLAUDE_PLUGIN_DATA"
assert_file_exists "$CLAUDE_PLUGIN_DATA/projects/$kc/meta.json"

echo "I-09 ok: same-origin keys match, plain keys off cwd, cred token stripped+absent"
