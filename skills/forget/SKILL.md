---
description: Delete the supervisor's recorded history for this project (events, digests, reports, telemetry, locks).
argument-hint: "[all]"
disable-model-invocation: true
---

This command deletes recorded history and cannot be undone. It runs in two
steps and you must NEVER skip the confirmation. Never infer consent: a plan, a
prior message, or an implied "go ahead" is not a yes. Only an explicit yes typed
by the user in this chat may trigger the deletion.

Step 1, dry run. Run this with the Bash tool. Append `--all` ONLY if the user
explicitly asked to erase everything across all projects; otherwise omit it so
only THIS project is affected:

```
"${CLAUDE_PLUGIN_ROOT}/scripts/supervisorctl.sh" --data-dir "${CLAUDE_PLUGIN_DATA}" forget
```

The dry run exits without deleting anything and prints exactly what WILL be
deleted and what will NOT (the account-scoped telemetry/rate_limits.json and
every other project are preserved). Show that listing to the user verbatim
inside one fenced code block.

Step 2, confirm then delete. Ask the user to reply "yes" explicitly in chat to
proceed. Only after they reply yes, re-run the identical command with `--yes`
appended (keep `--all` if and only if you used it in step 1):

```
"${CLAUDE_PLUGIN_ROOT}/scripts/supervisorctl.sh" --data-dir "${CLAUDE_PLUGIN_DATA}" forget --yes
```

Then tell the user what was deleted, quoting the command's confirmation output.
If the user does not reply with an explicit yes, do nothing and leave the history
in place.
