---
description: Show or change supervisor settings (capture, digest, awake, auto-resume, telemetry).
argument-hint: "[key] [value]"
disable-model-invocation: true
---

With NO arguments, show the current settings. Run this with the Bash tool and
present its JSON to the user as a readable table:

```
"${CLAUDE_PLUGIN_ROOT}/scripts/supervisorctl.sh" --data-dir "${CLAUDE_PLUGIN_DATA}" config list
```

Explain each key in one line when you show the table:

- `capture_reads` (default true): record the file paths that Read touches.
- `capture_commands` (default true): record Bash command text and pass/fail.
- `capture_subagents` (default true): also record events fired inside subagents.
- `git_snapshots` (default true): record repo root, HEAD, and dirty/untracked counts; enables REVERTED detection.
- `digest_enabled` (default true): inject the recent-history digest at session start.
- `digest_max_tokens` (default 400): soft size budget for the injected digest.
- `awake` (default auto): keep the machine awake during a session. One of `auto | adrafinil | caffeinate | inhibit | off`.
- `auto_resume` (default false, PROTECTED): schedule an unattended resume after a rate limit.
- `resume_max_attempts` (default 4, PROTECTED): how many unattended resume attempts to make.
- `resume_min_gap_hours` (default 5, PROTECTED): minimum hours between resume windows.
- `resume_max_minutes` (default 30, PROTECTED): wall-clock cap on one unattended resume run.
- `resume_extra_args` (default [], PROTECTED): extra resume CLI flags, restricted to a small safe allow-list.
- `notify` (default true): send desktop notifications for resume and limit events.
- `telemetry` (default true): let the opt-in statusline persist cost and rate-limit snapshots.
- `debug` (default false): write verbose logs to logs/debug.log.

With arguments (a key and a value), first check the key is one of the names
above; if it is not, tell the user it is unknown and stop.

If the key is one of the PROTECTED keys (`auto_resume`, `resume_extra_args`,
`resume_max_attempts`, `resume_min_gap_hours`, `resume_max_minutes`), first tell
the user the consequence: this schedules unattended runs that spend your quota
with nobody watching. Ask the user to confirm with an explicit yes in chat. Only
after an explicit yes, run the setter with the acknowledgement flag:

```
"${CLAUDE_PLUGIN_ROOT}/scripts/supervisorctl.sh" --data-dir "${CLAUDE_PLUGIN_DATA}" config set KEY VALUE --i-understand-quota-spend
```

For any other (non-protected) key, run the setter without the flag:

```
"${CLAUDE_PLUGIN_ROOT}/scripts/supervisorctl.sh" --data-dir "${CLAUDE_PLUGIN_DATA}" config set KEY VALUE
```

The setter prints the new stored value, or a refusal message on a non-zero exit.
Echo that new value back to the user. Never set a protected key without an
explicit yes in chat.
