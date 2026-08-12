#!/bin/sh
# lib/guard.sh - sourced prologue for every hook entrypoint (design U1).
# Contract: a supervisor hook NEVER breaks the user's session.
umask 077
trap 'exit 0' EXIT

sup_have() { command -v "$1" >/dev/null 2>&1; }
sup_py()   { command -v python3 2>/dev/null; }
sup_now()  { if [ -n "${SUPERVISOR_NOW:-}" ]; then printf '%s\n' "$SUPERVISOR_NOW"; else date +%s; fi; }

# --- design §4.1 containment (gate advisory: A-20 phase 2) -------------------
# sup_git_owned DIR: 0 iff DIR resolves inside a git worktree. Bounded ~2 s by
# a watchdog (macOS ships no timeout(1)). Both background jobs write only to
# /dev/null so a caller inside $(...) command substitution never blocks on the
# inherited pipe.
sup_git_owned() {
  sup_have git || return 1
  [ -d "$1" ] || return 1
  git -C "$1" rev-parse --show-toplevel >/dev/null 2>&1 &
  _go_pid=$!
  ( sleep 2; kill "$_go_pid" 2>/dev/null ) >/dev/null 2>&1 &
  _go_w=$!
  wait "$_go_pid" 2>/dev/null; _go_rc=$?
  kill "$_go_w" 2>/dev/null
  wait "$_go_w" 2>/dev/null
  return "$_go_rc"
}

# sup_dir_contained DIR: 0 (= REJECT) when DIR sits inside CLAUDE_PROJECT_DIR,
# inside $PWD, or inside any git worktree - the store must never live where a
# commit or a hostile .envrc can reach it (design §4.1, critic SEC-06). DIR
# may not exist yet, so its deepest existing ancestor stands in for path
# resolution and for the git probe. Applied to the user-supplied branch only;
# branch 1 (CLAUDE_PLUGIN_DATA) is exempt per design.
sup_dir_contained() {
  _ct_raw=$1
  _ct_anc=$_ct_raw
  _ct_i=0
  while [ ! -d "$_ct_anc" ] && [ "$_ct_i" -lt 64 ]; do
    _ct_up=$(dirname -- "$_ct_anc" 2>/dev/null) || break
    [ "$_ct_up" = "$_ct_anc" ] && break
    _ct_anc=$_ct_up
    _ct_i=$((_ct_i+1))
  done
  _ct_res=$(CDPATH= cd -- "$_ct_anc" 2>/dev/null && pwd -P) || _ct_res=$_ct_anc
  if [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
    _ct_p=$(CDPATH= cd -- "$CLAUDE_PROJECT_DIR" 2>/dev/null && pwd -P) || _ct_p=$CLAUDE_PROJECT_DIR
    case "$_ct_raw" in "$_ct_p"|"$_ct_p"/*) return 0 ;; esac
    case "$_ct_res" in "$_ct_p"|"$_ct_p"/*) return 0 ;; esac
  fi
  _ct_w=$(pwd -P 2>/dev/null) || _ct_w=${PWD:-}
  if [ -n "$_ct_w" ]; then
    case "$_ct_raw" in "$_ct_w"|"$_ct_w"/*) return 0 ;; esac
    case "$_ct_res" in "$_ct_w"|"$_ct_w"/*) return 0 ;; esac
  fi
  sup_git_owned "$_ct_res" && return 0
  return 1
}

sup_data_dir() {
  # CT-12: hooks have NO fallback; SUPERVISOR_DATA_DIR only under test mode.
  if [ -n "${CLAUDE_PLUGIN_DATA:-}" ]; then printf '%s\n' "$CLAUDE_PLUGIN_DATA"; return 0; fi
  if [ "${SUPERVISOR_TEST_MODE:-}" = "1" ] && [ -n "${SUPERVISOR_DATA_DIR:-}" ]; then
    sup_dir_contained "$SUPERVISOR_DATA_DIR" && return 1  # §4.1 containment (gate advisory)
    printf '%s\n' "$SUPERVISOR_DATA_DIR"; return 0
  fi
  return 1
}

sup_cfg() { # sup_cfg KEY DEFAULT
  _scp=$(sup_py) || { printf '%s\n' "$2"; return 0; }
  "$_scp" "$SUP_ROOT/scripts/py/supervisor_common.py" cfg "$1" "$2" 2>/dev/null || printf '%s\n' "$2"
}

if [ "${SUPERVISOR_DEBUG:-}" = "1" ] && _sdd=$(sup_data_dir 2>/dev/null); then
  mkdir -p "$_sdd/logs" 2>/dev/null && exec 2>>"$_sdd/logs/debug.log" || exec 2>/dev/null
else
  exec 2>/dev/null
fi
