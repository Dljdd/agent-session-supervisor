# Manual smoke checklist

These are the acceptance criteria that **cannot be proven by the offline suite**:
real digest injection through a live model, real sleep prevention, a real
rate-limit resume, real async-hook latency, `/clear` behavior, `SessionEnd` on a
hard kill, and the dev/install data split. Everything else is automated in
`tests/`.

Run each step as written. For each, record: what you did, the expected result,
and where you looked. Do not mark the build fully done until these are recorded;
until then the correct status is "offline-complete, live smoke pending".

Install for all steps below is the verified developer flag:

```
claude --plugin-dir /absolute/path/to/agent-session-supervisor
```

after which `/reload-plugins` (or a relaunch) makes hooks live.

---

## 0. Prerequisite: authenticate

OAuth on the build machine may be expired. Run `claude`, complete login. Every
step needs it **except step 5** (sleep prevention), which is auth-free.

---

## 1. Live inject round-trip

**Do:** In a scratch git project, launch with `--plugin-dir`. Edit one file
twice, run a command that fails, then quit. Relaunch the same way in the same
project.

**Expect:** The model can answer "what does the recap say about last session?"
from injected context **without reading any files**. `/supervisor:recap` prints
the digest.

**Look:** `~/.claude/debug/<session-id>.txt` shows the `SessionStart` hook running
and the size of its output.

---

## 2. `/clear` behavior

**Do:** Run `/clear` mid-session.

**Expect:** The digest **re-injects** (the `SessionStart` matcher includes
`clear` by design). Confirm this matches the pinned decision in the design spec
(matcher `startup|resume|clear`, `compact` deliberately excluded).

**Look:** The re-injected context after `/clear`; ask the model what the
supervisor told it.

---

## 3. Async capture latency

**Do:** Ask the live session to read ~30 files back to back.

**Expect:** No perceptible tool slowdown. Afterwards, `events.jsonl` in the
project's store contains the read events.

**Look:** The debug file shows async hook spawns; the events file grows.

---

## 4. Skill invocations

**Do:** In the live session run `/supervisor:recap`, `/supervisor:log`, then
`/supervisor:forget`.

**Expect:** Each behaves as documented. After `/supervisor:forget` (confirmed),
`/supervisor:recap` reports an empty store. Confirm `/supervisor:forget` shows a
dry-run and waits for an explicit yes before deleting.

**Look:** The command output in chat; the store shrinks after forget.

---

## 5. Real sleep prevention (no auth needed)

**Do:** With v0.2 active and a long task running, inspect assertions.

**Expect:** `pmset -g assertions` (macOS) shows a `PreventUserIdleSystemSleep`
assertion attributable to adrafinil, or to `caffeinate` in the fallback case.
After the session exits, the assertion is gone.

**Optional hardware step:** With adrafinil installed, close the lid and confirm
the run continues.

**Look:** `pmset -g assertions` before, during, and after the session.

---

## 6. `SessionEnd` on a hard kill

**Do:** `kill -9` the CLI mid-session. Relaunch with `--plugin-dir` in the same
project.

**Expect:** The next session still injects a correct digest (the crash-rebuild
path: reconciliation appends a synthetic session end at the next start).

**Record:** Whether `SessionEnd` fired at all before the kill (undocumented
platform behavior), for the record.

**Look:** The injected digest after relaunch; the events file for a synthetic
`end` with `inf:1`.

---

## 7. Real rate-limit resume (Pro/Max account, patience required)

**Do:** Enable auto-resume:
`/supervisor:config auto_resume true` (confirm the consequence prompt). Then
drive or wait into a 5-hour-window rate limit.

**Expect:** A `rate_limit` stop appears in the debug file; a desktop notification
says a resume is armed; `resume/pending/<sid>.json` holds a sane `due` time. At
reset, the session resumes **exactly once** (`claude -p --resume <id> ...` visible
in `ps`/logs). No resume storm.

**CRITICAL to record (this gates the README recommendation):** the resumed
session is more than an hour inactive, so it may hit the "Resume from summary /
as-is / don't ask" dialog. Record whether that dialog appears under `-p`, whether
the run proceeds or blocks, and whether the `resume_max_minutes` bound had to fire
to kill a blocked attempt. Also record whether `error_details` carried any reset
hint (not relied upon). **Do not recommend auto-resume in general docs until this
step is recorded.**

**Look:** Debug file, notifications, `resume/pending/`, `resume/state.json`,
`resume/last.log`, and `ps`.

---

## 8. Statusline install and telemetry

**Do:** Install via `/supervisor:statusline` (consent flow, explicit yes).

**Expect:** The rendered line matches the documented format. On a Pro/Max account,
after the first response the rate-limit fields appear, and
`telemetry/rate_limits.json` in the data dir updates with `resets_at`. After a
plugin update (`/reload-plugins` with a bumped version), the statusline **keeps
working** (the installed copy is self-contained).

**Look:** The status line itself; `telemetry/rate_limits.json`;
`~/.claude/settings.json` and its `.supervisor-bak-<epoch>` backup.

---

## 9. First-run disclosure + config gates

**Do:** With a fresh data dir, start a first session; then start a second.

**Expect:** The one-time capture notice appears in context on the first session
(ask the model "what did the supervisor tell you?"); it does **not** appear on the
second. `/supervisor:config auto_resume true` surfaces the consequence text and
requires explicit confirmation. The model **cannot** invoke `/supervisor:config`
autonomously (`disable-model-invocation`); confirm by asking it to try.

**Look:** The first-vs-second session context; the `first_run_notified` marker in
the data dir; the config prompt.

---

## 10. `/reload-plugins` loop

**Do:** Edit `hooks/hooks.json`, run `/reload-plugins`.

**Expect:** The change is live without a full restart.

**Look:** Hook behavior reflects the edit.

---

## 11. Dev/install data split awareness

**Do:** After any marketplace-style install, inspect the data dir id.

**Expect:** State lives under a **different** id-dir than `supervisor-inline`
(for example `supervisor-<marketplace-name>`). Confirm the docs say state does
not migrate between the two.

**Look:** `~/.claude/plugins/data/` listing.
