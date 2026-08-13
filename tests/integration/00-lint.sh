#!/bin/bash
# tests/integration/00-lint.sh — static/lint gates L-01..L-09 (strategy §10)
# plus SK-03 (namespace-consistency, gate advisory).
#
# TDD baseline (plan Task 2 step 7): this gate FAILS until skills/ and
# scripts/py/ exist — it must pass unmodified by Task 10.
#
# Verdict protocol: every check runs and reports; exit 1 if any failed;
# exit 75 (SKIP) only when all present checks passed but the `claude` CLI is
# absent so L-08 could not run (RELEASE=1 turns that into a failure upstream).
set -u
PLUGIN_ROOT=${PLUGIN_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
cd "$PLUGIN_ROOT" || exit 1

FAILURES=0
lfail() { echo "LINT FAIL [$1] $2"; FAILURES=$((FAILURES+1)); }

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH (environment floor is jq 1.6)"; exit 75; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not on PATH"; exit 75; }

HJ=hooks/hooks.json
PJ=.claude-plugin/plugin.json

# ---------------- L-01: hooks.json shape ----------------
if ! jq -e . "$HJ" >/dev/null 2>&1; then
  lfail L-01 "$HJ missing or not valid JSON"
else
  jq -e '.hooks | type == "object"' "$HJ" >/dev/null 2>&1 \
    || lfail L-01 "top-level .hooks is not an object"
  for ev in $(jq -r '.hooks | keys[]' "$HJ"); do
    case "$ev" in
      SessionStart|PostToolUse|PostToolUseFailure|SessionEnd|Stop|StopFailure|SubagentStart|SubagentStop) : ;;
      *) lfail L-01 "unknown/mis-cased event name: $ev" ;;
    esac
  done
  jq -e '[.hooks[][] | has("hooks")] | all' "$HJ" >/dev/null 2>&1 \
    || lfail L-01 "a matcher entry has no hooks[] array"
  jq -e '[.hooks[][].hooks[].type] | all(. == "command")' "$HJ" >/dev/null 2>&1 \
    || lfail L-01 "hook entry with type != \"command\""
  jq -e '[.hooks[][].hooks[] | select(has("async"))] | all(.type == "command")' "$HJ" >/dev/null 2>&1 \
    || lfail L-01 "async on a non-command hook"
fi

# ---------------- L-02: matcher floor ----------------
if jq -e . "$HJ" >/dev/null 2>&1; then
  if jq -r '.hooks[][] | .matcher // empty' "$HJ" | grep -q ','; then
    lfail L-02 "comma in a matcher (comma forms need >=2.1.191)"
  fi
  SFM=$(jq -r '(.hooks.StopFailure // [])[] | .matcher // empty' "$HJ")
  if [ -n "$SFM" ] && ! printf '%s\n' "$SFM" | LC_ALL=C grep -Eq '^[A-Za-z0-9_|]+$'; then
    lfail L-02 "StopFailure matcher outside [A-Za-z0-9_|]: $SFM"
  fi
  SSM=$(jq -r '.hooks.SessionStart[0].matcher // empty' "$HJ")
  [ "$SSM" = "startup|resume|clear" ] \
    || lfail L-02 "SessionStart matcher [$SSM] != design-pinned [startup|resume|clear]"
fi

# ---------------- L-03: script hygiene ----------------
if jq -e . "$HJ" >/dev/null 2>&1; then
  cmds_f=$(mktemp)
  jq -r '.hooks[][].hooks[].command' "$HJ" > "$cmds_f" 2>/dev/null
  while IFS= read -r cmd; do
    case "$cmd" in
      '"${CLAUDE_PLUGIN_ROOT}"/'*) : ;;
      *) lfail L-03 "command not in quoted-placeholder form: $cmd"; continue ;;
    esac
    rel=${cmd#'"${CLAUDE_PLUGIN_ROOT}"/'}
    if [ -f "$rel" ]; then
      [ -x "$rel" ] || lfail L-03 "referenced script not executable: $rel"
      [ "$(head -c 2 "$rel")" = "#!" ] || lfail L-03 "referenced script has no shebang: $rel"
    else
      lfail L-03 "referenced script missing: $rel"
    fi
  done < "$cmds_f"
  rm -f "$cmds_f"
fi

# ---------------- L-04: banned tokens over scripts/ hooks/ skills/ ----------------
scan_dirs=""
for d in scripts hooks skills; do [ -d "$d" ] && scan_dirs="$scan_dirs $d"; done
if [ -n "$scan_dirs" ]; then
  # Fixed-string bans (wrong field names, absent CLI flag, bash-4isms, config back doors).
  for tok in 'tool_output' 'tool_error' '--strict' 'declare -A' 'mapfile' 'readarray' '${user_config.' 'CLAUDE_PLUGIN_OPTION_'; do
    hits=$(grep -RInF -- "$tok" $scan_dirs 2>/dev/null)
    [ -z "$hits" ] || lfail L-04 "banned token [$tok]:
$hits"
  done
  # bash-4 case modification ${var,,} / ${var^^} for any var name.
  hits=$(grep -RInE '\$\{[^}]*(,,|\^\^)[^}]*\}' $scan_dirs 2>/dev/null)
  [ -z "$hits" ] || lfail L-04 "bash-4 case modification found:
$hits"
  # Permission-bypass strings: the only allowed occurrences are the whitelist
  # rejector lines in scripts/py/supervisor_common.py annotated '# LINT-ALLOW'.
  hits=$(grep -RInE 'bypassPermissions|dangerously-skip' $scan_dirs 2>/dev/null \
         | grep -v 'scripts/py/supervisor_common\.py:.*# LINT-ALLOW')
  [ -z "$hits" ] || lfail L-04 "permission-bypass token outside the annotated rejector:
$hits"
  # transcript_path may be passed through/logged but never read.
  hits=$(grep -RIn 'transcript_path' scripts 2>/dev/null \
         | grep -E '(cat |jq |grep |head |tail |sed |awk |less |open\()')
  [ -z "$hits" ] || lfail L-04 "transcript_path appears to be read (unstable format):
$hits"
fi
# User-facing docs must never claim data survives uninstall (FACTS §9.2).
docs_scan=""
[ -f README.md ] && docs_scan="README.md"
[ -d skills ] && docs_scan="$docs_scan skills"
if [ -n "$docs_scan" ]; then
  hits=$(grep -RIni 'survives uninstall' $docs_scan 2>/dev/null)
  [ -z "$hits" ] || lfail L-04 "forbidden uninstall-persistence claim:
$hits"
fi

# ---------------- L-05: plugin.json ----------------
NAME=""
if ! jq -e . "$PJ" >/dev/null 2>&1; then
  lfail L-05 "$PJ missing or not valid JSON"
else
  NAME=$(jq -r '.name // empty' "$PJ")
  if [ -z "$NAME" ]; then
    lfail L-05 "manifest name missing"
  elif ! printf '%s\n' "$NAME" | LC_ALL=C grep -Eq '^[a-z0-9]+(-[a-z0-9]+)*$'; then
    lfail L-05 "manifest name not kebab-case: [$NAME]"
  fi
  for d in hooks skills scripts; do
    [ -d "$d" ] || lfail L-05 "component dir missing at plugin root: $d/"
  done
  # .claude-plugin/ holds only manifests: plugin.json (required) and the optional
  # marketplace.json (this repo is its own single-plugin marketplace). Component
  # dirs (hooks/skills/scripts) must be at the plugin root, never in here.
  extra=$(ls -A .claude-plugin 2>/dev/null | grep -vE '^(plugin|marketplace)\.json$')
  [ -z "$extra" ] || lfail L-05 ".claude-plugin/ must contain only plugin.json / marketplace.json; extras: $extra"
fi

# ---------------- L-06: digest header wording (anti-injection, hooks.md:848) ----------------
DP=scripts/py/digest.py
if [ ! -f "$DP" ]; then
  lfail L-06 "scripts/py/digest.py missing — envelope/header wording unverifiable"
else
  # Whole-file scope is deliberate: an over-approximation that keeps the gate
  # simple; digest.py must contain no imperative system-command framing at all.
  hits=$(grep -Ein 'you must|system:|important:' "$DP")
  [ -z "$hits" ] || lfail L-06 "imperative framing in digest.py:
$hits"
  grep -qF 'Supervisor digest (an automated, untrusted log' "$DP" \
    || lfail L-06 "design §11.1 factual envelope text not found in digest.py"
fi

# ---------------- L-07: skills ----------------
for s in recap log forget config statusline; do
  f="skills/$s/SKILL.md"
  if [ ! -f "$f" ]; then lfail L-07 "missing $f"; continue; fi
  [ "$(head -n 1 "$f")" = "---" ] || lfail L-07 "$f: first line is not the frontmatter delimiter ---"
  awk 'NR>1 && /^---[[:space:]]*$/{found=1; exit} END{exit !found}' "$f" \
    || lfail L-07 "$f: unclosed frontmatter block"
  fm=$(awk 'NR==1{next} /^---[[:space:]]*$/{exit} {print}' "$f")
  printf '%s\n' "$fm" | grep -q '^description:' || lfail L-07 "$f: frontmatter description missing"
  # No name: frontmatter anywhere (design §15; pre-2.1.216 it replaces the
  # whole command and drops the plugin prefix, FACTS §9.7).
  if printf '%s\n' "$fm" | grep -q '^name:'; then
    lfail L-07 "$f: frontmatter name: is forbidden"
  fi
  # Booleans must be the literal lowercase true/false (2.1.126 floor).
  bad=$(printf '%s\n' "$fm" | grep -E '^disable-model-invocation:' | grep -vE '^disable-model-invocation:[[:space:]]*(true|false)[[:space:]]*$')
  [ -z "$bad" ] || lfail L-07 "$f: disable-model-invocation not a literal true/false: $bad"
  case "$s" in
    forget|config|statusline)
      printf '%s\n' "$fm" | grep -Eq '^disable-model-invocation:[[:space:]]*true[[:space:]]*$' \
        || lfail L-07 "$f: disable-model-invocation: true is required (critic SEC-02)"
      ;;
  esac
  # Every supervisorctl.sh invocation carries --data-dir "${CLAUDE_PLUGIN_DATA}" (CT-12).
  bad=$(grep -n 'supervisorctl\.sh' "$f" | grep -vF -- '--data-dir "${CLAUDE_PLUGIN_DATA}"')
  [ -z "$bad" ] || lfail L-07 "$f: supervisorctl.sh without --data-dir \"\${CLAUDE_PLUGIN_DATA}\":
$bad"
done
f=skills/statusline/SKILL.md
if [ -f "$f" ]; then
  grep -qi 'reply yes' "$f" \
    || lfail L-07 "statusline skill: explicit-yes install gate wording missing (design §14.3/§18.25)"
  grep -qi 'second confirmation' "$f" \
    || lfail L-07 "statusline skill: overwrite second-confirmation gate wording missing (design §14.3/§18.25)"
  grep -qF 'install_statusline.py' "$f" \
    || lfail L-07 "statusline skill: settings mechanics must run via install_statusline.py"
  hits=$(grep -Ein '(use|run|call|invoke|with) the (edit|write) tool' "$f")
  [ -z "$hits" ] || lfail L-07 "statusline skill instructs Edit/Write tool use on settings:
$hits"
fi

# ---------------- SK-03: namespace consistency (gate advisory) ----------------
# Every /<ns>:<skill> reference in user-facing docs must use the manifest name.
if [ -n "$NAME" ]; then
  sk_scan=""
  [ -f README.md ] && sk_scan="README.md"
  [ -f CHANGELOG.md ] && sk_scan="$sk_scan CHANGELOG.md"
  [ -d skills ] && sk_scan="$sk_scan skills"
  if [ -n "$sk_scan" ]; then
    hits=$(grep -RIoE '/[a-z][a-z0-9-]*:(recap|log|forget|config|statusline)' $sk_scan 2>/dev/null \
           | grep -v ":/$NAME:")
    [ -z "$hits" ] || lfail SK-03 "doc references a non-manifest command namespace (manifest name: $NAME):
$hits"
  fi
fi

# ---------------- L-09: DIGEST_MAX_CHARS mirror (CT-4) ----------------
LIBV=$(sed -n 's/^DIGEST_MAX_CHARS=\([0-9][0-9]*\).*/\1/p' tests/lib.sh | head -n 1)
[ -n "$LIBV" ] || lfail L-09 "DIGEST_MAX_CHARS not found in tests/lib.sh"
if [ ! -f "$DP" ]; then
  lfail L-09 "scripts/py/digest.py missing — DIGEST_MAX_CHARS mirror unverifiable"
else
  PYV=$(sed -n 's/^DIGEST_MAX_CHARS[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$DP" | head -n 1)
  [ -n "$PYV" ] || lfail L-09 "DIGEST_MAX_CHARS not found in digest.py"
  [ -n "$PYV" ] && [ "$LIBV" = "$PYV" ] || lfail L-09 "constant drift: tests/lib.sh=$LIBV scripts/py/digest.py=$PYV"
fi

# ---------------- L-08: claude plugin validate (AC8) — runs last ----------------
CLAUDE_SKIP=0
if command -v claude >/dev/null 2>&1; then
  out=$(claude plugin validate "$PLUGIN_ROOT" 2>&1); rc=$?
  if [ $rc -ne 0 ] || ! printf '%s\n' "$out" | grep -q 'Validation passed'; then
    lfail L-08 "claude plugin validate failed (rc=$rc):
$out"
  elif printf '%s\n' "$out" | grep -qi 'warning'; then
    echo "LINT WARN [L-08] validate emitted warnings (target: zero):"
    printf '%s\n' "$out" | sed 's/^/    /'
  fi
  # --strict probe: absent on 2.1.126 (FACTS §9.1); if a newer CLI accepts it,
  # strict must also pass.
  sout=$(claude plugin validate "$PLUGIN_ROOT" --strict 2>&1); src=$?
  if printf '%s\n' "$sout" | grep -qi 'unknown option'; then
    : # 2.1.126 floor — probe skipped
  elif [ $src -ne 0 ]; then
    lfail L-08 "--strict accepted by this CLI but failed (rc=$src):
$sout"
  fi
else
  CLAUDE_SKIP=1
fi

# ---------------- verdict ----------------
if [ $FAILURES -gt 0 ]; then
  echo "$FAILURES lint check(s) failed"
  exit 1
fi
if [ $CLAUDE_SKIP -eq 1 ]; then
  echo "SKIP: claude CLI not on PATH — L-08 validate not exercised"
  exit 75
fi
echo "lint clean"
exit 0
