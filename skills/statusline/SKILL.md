---
description: Install or remove the supervisor statusline (cost, context %, rate-limit resets) — edits ~/.claude/settings.json only with your approval.
argument-hint: "[remove]"
disable-model-invocation: true
---

This command changes `~/.claude/settings.json`. Every change is made by the
helper script `install_statusline.py`; you never hand-edit that file yourself
with any tool, and you never touch it unless the user has explicitly approved
the change in this chat. If `$ARGUMENTS` is `remove`, follow the remove flow at
the bottom; otherwise follow the install flow.

Install flow:

1. Show what would change. Run this with the Bash tool:

```
"${CLAUDE_PLUGIN_ROOT}/scripts/py/install_statusline.py" show
```

   Present to the user: the current `statusLine` value (if any), any override
   found in `settings.local.json` or project settings, and the exact proposed
   value, which sets `statusLine` to a `command` type pointing at the installed
   copy under the plugin data dir.

2. Ask explicitly: "Reply yes to install". If the output showed a DIFFERENT
   existing `statusLine`, tell the user it will be replaced (the old value is
   backed up) and require an explicit second confirmation before proceeding.

3. Only after the explicit yes, install:

```
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/py/install_statusline.py" install --data-dir "${CLAUDE_PLUGIN_DATA}"
```

   Re-running when it is already installed simply reports "already installed".

Remove flow (`$ARGUMENTS` is `remove`): show the current value the same way, ask
for an explicit yes, and only then run:

```
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/py/install_statusline.py" remove
```

Disclosures to give the user before they approve:

- The statusline persists cost and rate-limit-reset telemetry into the plugin
  data dir; that telemetry is what powers scheduled auto-resume.
- Uninstalling the plugin without `--keep-data` deletes the installed copy, so
  the statusline stops working; re-run `/supervisor:statusline` after a
  reinstall to restore it.

All settings.json mechanics live in `install_statusline.py` (backup, minimal
edit, atomic replace). Never edit or write any settings file directly.
