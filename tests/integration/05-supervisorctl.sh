#!/bin/bash
# tests/integration/05-supervisorctl.sh — SK-02 + config gates + R-10 setter half
# (strategy §14 SK-02, §12 R-10; design U16). The one script the five skills
# delegate to, tested directly against a seeded tmp store: config list/get/set,
# the protected-key gate, the resume_extra_args whitelist (setter side of R-10),
# status (armed sleepers + statusline staleness), and — when digest.py is
# present — recap/log. forget SCOPING is A-11 (40-forget-scoping.sh); here we
# only assert its exit-code contract (3 dry-run, 0 confirmed).
set -u
PLUGIN_ROOT=${PLUGIN_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
export PLUGIN_ROOT
. "$PLUGIN_ROOT/tests/lib.sh"

t_sandbox
mk_proj_plain

CTL="$PLUGIN_ROOT/scripts/supervisorctl.sh"
# Skills always pass --data-dir "${CLAUDE_PLUGIN_DATA}" and run from the project
# cwd; mirror that. The subshell cd keeps $PWD == the project so project_key and
# the containment check resolve exactly as they will in a real session.
ctl() { ( cd "$CLAUDE_PROJECT_DIR" && "$CTL" --data-dir "$CLAUDE_PLUGIN_DATA" "$@" ); }

# ---- config list / get / set roundtrip (exit 0) ----
out=$(ctl config list); rc=$?
assert_exit0 $rc
printf '%s' "$out" | jq -e '.awake == "auto"' >/dev/null || fail "config list: awake default not auto"

ctl config set awake off >/dev/null; rc=$?
assert_exit0 $rc
got=$(ctl config get awake); assert_eq "off" "$got"

# ---- protected-key gate (exit 4 without the ack flag) ----
ctl config set auto_resume true >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ] || fail "auto_resume set WITHOUT --i-understand-quota-spend must be refused"
got=$(ctl config get auto_resume); assert_eq "false" "$got"

ctl config set auto_resume true --i-understand-quota-spend >/dev/null; rc=$?
assert_exit0 $rc
got=$(ctl config get auto_resume); assert_eq "true" "$got"

# ---- R-10 setter half: resume_extra_args whitelist (design §4.4, critic SEC-02) ----
before=$(ctl config get resume_extra_args)
for hostile in \
  '["--dangerously-skip-permissions"]' \
  '["--mcp-config","x"]' \
  '["--permission-mode","bypassPermissions"]' \
  '["--plugin-dir"]' ; do
  ctl config set resume_extra_args "$hostile" --i-understand-quota-spend >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] || fail "hostile resume_extra_args accepted: $hostile"
done
after=$(ctl config get resume_extra_args)
assert_eq "$before" "$after"   # config.json unchanged after every refusal

# a whitelisted flag/value pair succeeds WITH the ack flag
ctl config set resume_extra_args '["--model","opus"]' --i-understand-quota-spend >/dev/null; rc=$?
assert_exit0 $rc
got=$(ctl config get resume_extra_args); assert_eq '["--model","opus"]' "$got"

# a protected key still needs the flag even for a benign value
ctl config set resume_max_minutes 5 >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ] || fail "resume_max_minutes set without ack flag must be refused"

# ---- config usage errors (exit 2) ----
ctl config >/dev/null 2>&1; [ $? -eq 2 ] || fail "bare 'config' should be usage exit 2"
ctl config get >/dev/null 2>&1; [ $? -eq 2 ] || fail "'config get' with no key should be usage exit 2"
ctl bogus-command >/dev/null 2>&1; [ $? -eq 2 ] || fail "unknown command should be usage exit 2"

# ---- status: armed sleepers + statusline staleness (SK-02) ----
sid=sess-1111
mkdir -p "$CLAUDE_PLUGIN_DATA/resume/pending" "$CLAUDE_PLUGIN_DATA/bin"
cat > "$CLAUDE_PLUGIN_DATA/resume/pending/$sid.json" <<JSON
{"v":1,"pid":424242,"due":$((SUPERVISOR_NOW+3600)),"session":"$sid","cwd":"$CLAUDE_PROJECT_DIR","window_key":"w","attempt":1}
JSON
printf '#!/bin/sh\n' > "$CLAUDE_PLUGIN_DATA/bin/supervisor-statusline.sh"
: > "$CLAUDE_PLUGIN_DATA/bin/.stale"

st=$(ctl status); rc=$?
assert_exit0 $rc
printf '%s\n' "$st" | grep -q "armed sleepers:" || fail "status: no armed-sleepers section"
printf '%s\n' "$st" | grep -q "$sid" || fail "status: armed sleeper sid not listed"
printf '%s\n' "$st" | grep -q "pid=424242" || fail "status: armed sleeper pid not listed"
printf '%s\n' "$st" | grep -qi "outdated" || fail "status: stale statusline copy not reported"
printf '%s\n' "$st" | grep -q "data dir:" || fail "status: no data dir line"
printf '%s\n' "$st" | grep -q "project:" || fail "status: no project key line"

# ---- recap / log argument parsing (usage errors resolve before delegation) ----
ctl recap bogus >/dev/null 2>&1; [ $? -eq 2 ] || fail "recap with a bad arg should be usage exit 2"
ctl log abc     >/dev/null 2>&1; [ $? -eq 2 ] || fail "log with a non-numeric count should be usage exit 2"
ctl report junk >/dev/null 2>&1; [ $? -eq 2 ] || fail "report with an extra arg should be usage exit 2"

# ---- recap / log — delegate to digest.py (§11.3). Exercised only when present. ----
if [ -f "$PLUGIN_ROOT/scripts/py/digest.py" ]; then
  ctl recap >/dev/null; assert_exit0 $?
  ctl recap full >/dev/null; assert_exit0 $?      # bare-word "full" (skill $ARGUMENTS form)
  ctl recap --full >/dev/null; assert_exit0 $?
  ctl report >/dev/null; assert_exit0 $?
  ctl log >/dev/null; assert_exit0 $?
  ctl log 5 >/dev/null; assert_exit0 $?
  echo "recap/log/report delegation exercised (digest.py present)"
else
  echo "note: scripts/py/digest.py absent (Task 6) — recap/log/report delegation not exercised here"
fi

# ---- forget exit-code contract (scoping is A-11) ----
out=$(ctl forget); rc=$?
[ "$rc" -eq 3 ] || fail "forget dry-run should exit 3, got $rc"
printf '%s\n' "$out" | grep -q "WILL NOT DELETE" || fail "forget dry-run: no WILL-NOT section"
printf '%s\n' "$out" | grep -q "rate_limits.json" || fail "forget dry-run: rate_limits not named as preserved"
out=$(ctl forget --yes); rc=$?
[ "$rc" -eq 0 ] || fail "forget --yes should exit 0, got $rc"

echo "SK-02 ok: config gates, R-10 whitelist (setter), status, forget contract"
