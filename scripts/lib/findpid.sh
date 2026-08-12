#!/bin/sh
# lib/findpid.sh - sup_find_claude_pid: print the owning claude PID or nothing.
sup_find_claude_pid() {
  if [ "${SUPERVISOR_TEST_MODE:-}" = "1" ] && [ -n "${SUPERVISOR_FAKE_CLAUDE_PID:-}" ]; then
    printf '%s\n' "$SUPERVISOR_FAKE_CLAUDE_PID"; return 0
  fi
  _fp_pid=$$; _fp_i=0
  while [ "$_fp_i" -lt 15 ]; do
    _fp_ppid=$(ps -p "$_fp_pid" -o ppid= 2>/dev/null | tr -d ' ')
    [ -z "$_fp_ppid" ] && return 0
    [ "$_fp_ppid" -le 1 ] 2>/dev/null && return 0
    _fp_cmd=$(ps -p "$_fp_ppid" -o command= 2>/dev/null)
    case "$_fp_cmd" in
      claude|claude\ *|*/claude|*/claude\ *) printf '%s\n' "$_fp_ppid"; return 0 ;;
      *node*claude*|*bun*claude*)            printf '%s\n' "$_fp_ppid"; return 0 ;;
    esac
    _fp_pid=$_fp_ppid; _fp_i=$((_fp_i+1))
  done
  return 0
}
