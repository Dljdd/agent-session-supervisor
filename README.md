# Agent Session Supervisor

A Claude Code plugin that quietly watches your coding sessions and gives you
back four things: a memory of what the last session actually did, a machine that
stays awake while a long run is alive, an optional overnight auto-resume after a
rate limit, and an optional statusline showing cost, context, and quota resets.

It makes **zero model calls**, runs **fully local**, never parses your
transcript, and never stores file contents. Everything it records lives outside
your repository, redacted before it touches disk.

---

## What it does

Four capabilities ship in one plugin. Each degrades to a silent no-op rather than
ever breaking or slowing your session.

- **v0.1 - Flight recorder + start-of-session digest.** Hooks capture structural
  signals from tool events (which files were edited, which commands passed or
  failed, which reads never led to an edit, whether a change was reverted) into
  an append-only local log. At the next session start it injects a short factual
  digest (capped at 400 tokens) so the model already knows what mechanically
  happened last time, without reading a single file.

- **v0.2 - Leak-proof stay-awake.** While a session is alive the machine is kept
  awake, scoped to the owning `claude` process so the wake lock cannot outlive
  it. Prefers `adrafinil` when installed (the only option that survives a closed
  lid), falls back to `caffeinate` on macOS and `systemd-inhibit` on Linux.

- **v0.3 - Opt-in quota auto-resume.** Off by default. When enabled, a
  `rate_limit` stop schedules a single headless `claude -p --resume` after the
  quota window resets, so an unattended overnight run picks itself back up.

- **v0.4 - Opt-in cost/quota statusline.** A one-line status showing spend,
  context use, and rate-limit resets. It also persists the telemetry that the
  digest cost line and the auto-resume scheduler rely on.

**Non-goals in this build:** no cache warming (see the companion note below), no
transcript parsing ever, no cloud, no embeddings, no summarization by a model,
no Windows support, no `bypassPermissions` anywhere.

---

## Requirements

- Claude Code 2.1.126 or newer, on macOS or Linux.
- `python3` (standard library only, no pip) for capture, digest, and resume.
- `git` is optional: without it the recorder still works and the reverted-change
  signal is simply skipped.
- `jq` is optional: it is only a fast path for the statusline; `python3` covers
  the same job.

Windows is not supported; every hook exits cleanly as a no-op there.

---

## Install

### Today: via `--plugin-dir`

From the repository root, or any absolute path to it:

```
claude --plugin-dir /absolute/path/to/agent-session-supervisor
```

Then, inside the session, load it:

```
/reload-plugins
```

Recorded state for a `--plugin-dir` session lives under:

```
~/.claude/plugins/data/supervisor-inline/
```

### Via a plugin marketplace

This repository is its own single-plugin marketplace (`.claude-plugin/marketplace.json`),
so it installs directly:

```
/plugin marketplace add Dljdd/agent-session-supervisor
/plugin install supervisor@agent-session-supervisor
```

A marketplace install stores its state under
`~/.claude/plugins/data/supervisor-agent-session-supervisor/`.

> **Dev/install data split.** State does **not** migrate between the
> `--plugin-dir` (`supervisor-inline`) store and a marketplace store. They are
> separate histories by design.

---

## Commands

All commands live under the `/supervisor:` namespace.

| Command | What it does |
|---|---|
| `/supervisor:recap` | Print the digest of recent sessions in this project. Add `full` for the complete report. |
| `/supervisor:log` | Print the last raw events (paths, commands, pass/fail). Optional count, default 20. |
| `/supervisor:forget` | Delete this project's recorded history. Runs a dry-run first and asks before deleting. Add `all` to wipe everything. |
| `/supervisor:config` | Show or change settings. You type it; the model cannot flip settings on its own. |
| `/supervisor:statusline` | Install or remove the statusline. Edits `~/.claude/settings.json` only after you approve. Add `remove` to uninstall. |

Everything `recap` and `log` print is redacted at capture time and sanitized
again at print time, then shown as data inside a fenced block; it is never
treated as instructions.

---

## Configuration

Settings live in `config.json` inside the plugin data dir. Change them with
`/supervisor:config <key> <value>`; read them with `/supervisor:config` (no
arguments).

| Key | Default | Meaning |
|---|---|---|
| `capture_reads` | `true` | Record `Read` events (used for "read but never edited"). |
| `capture_commands` | `true` | Record Bash command strings. When `false`, only failure counts survive, commands hidden. |
| `capture_subagents` | `true` | Record events that originate inside subagents. |
| `git_snapshots` | `true` | Take a git snapshot at session start/end (enables the reverted-change signal). |
| `digest_enabled` | `true` | Inject the start-of-session digest. |
| `digest_max_tokens` | `400` | Hard cap on the injected digest size. |
| `awake` | `auto` | Stay-awake mode: `auto`, `adrafinil`, `caffeinate`, `inhibit`, or `off`. |
| `notify` | `true` | Allow best-effort desktop notifications (macOS). |
| `telemetry` | `true` | Let the statusline persist cost/rate-limit telemetry. |
| `debug` | `false` | Write a debug log (see the caveat under Privacy). |

### Protected keys (auto-resume)

These keys change behavior that can spend your quota unattended, so the setter
**refuses them unless you pass `--i-understand-quota-spend`** and prints the
consequences first. The `/supervisor:config` skill walks you through this and
asks for an explicit yes in chat.

| Key | Default | Meaning |
|---|---|---|
| `auto_resume` | `false` | Master switch for headless quota resume. |
| `resume_max_attempts` | `4` | Backoff-ladder attempts before giving up. |
| `resume_min_gap_hours` | `5` | Minimum gap between successful resumes. |
| `resume_max_minutes` | `30` | Hard wall-clock bound on one resume attempt. |
| `resume_extra_args` | `[]` | Extra CLI args for the resume command, validated against a strict whitelist (`--plugin-dir`, `--settings`, `--add-dir`, `--model`, `--fallback-model` only). Anything resembling a permission bypass is rejected. |

---

## Privacy and consent

The recorder is **on by default**. The first time it writes to a fresh data dir
it injects a one-time notice into the session telling you exactly what it records
and how to adjust or erase it.

### What is captured

- **Event kinds only:** file paths that were edited or read, command strings
  (redacted), pass/fail booleans, error strings (redacted, truncated), and
  session boundary markers.
- **Git snapshots** at session start and end carry only: the repo root, the HEAD
  commit, counts of dirty and untracked files, and 12-character SHA-256 hashes of
  the repo-relative paths that changed. Real untracked filenames never reach the
  store. This is what powers the reverted-change signal without ever recording a
  private filename like `.env.production` in plaintext.

### What is never captured

- File contents. Ever.
- The transcript (`transcript_path` JSONL) is never read or parsed.
- Command stdout beyond a redacted error string.

### Turning capture down or off

Use `/supervisor:config` to narrow or disable what is recorded:
`capture_commands false` hides command strings, `capture_reads false` stops read
tracking, `capture_subagents false` drops subagent events, `git_snapshots false`
turns off the reverted-change signal, and `digest_enabled false` stops the
start-of-session injection. To stop recording a project entirely, use
`/supervisor:forget` (per project) or `/supervisor:forget all` (everything).

### Redaction

Every stored string is scrubbed **before** it is written to disk, by a
deterministic, layered engine: private keys, JWTs, provider API keys (Anthropic,
OpenAI, Stripe, Slack, SendGrid, GitHub, GitLab, HuggingFace, DigitalOcean, AWS,
and more), `Bearer` tokens, URL credentials, `KEY=value` secret shapes
(including `DB_PASSWORD=...`, `AWS_SECRET_ACCESS_KEY=...`), and high-entropy
tokens. All-hex tokens of 32+ characters are redacted, **except** those exactly
40 or 64 characters long, which are kept because they are git SHA-1/SHA-256
hashes and keeping them makes command history readable. If the redactor ever
errors on a field, that whole field is stored as `[redaction-error]` (fail
closed, secret never written).

Redaction is layered and deterministic. It is not a guarantee. We enumerate the
layers and ship executable secret-vector tests rather than claim perfection.

### Where it lives, and permissions

State lives **outside your repository**, under the plugin data dir (see Install).
Every directory is created `0700`, every file `0600`. The plugin refuses to place
its store inside your project directory, your current working directory, or any
git worktree, so nothing secret-bearing can be committed by accident.

### Erasing history

`/supervisor:forget` shows a dry-run of exactly what will be deleted (and what
will not: account-scoped rate-limit telemetry and other projects) and waits for
your explicit yes. It then deletes this project's events, digests, reports, its
telemetry rows, ledger entries, pending resume timers, and wake locks, and
truncates the debug log. `/supervisor:forget all` removes the entire data dir.

### Uninstall

The data dir persists across plugin **updates**. Uninstalling the plugin from its
last scope **deletes the data dir by default**; pass
`claude plugin uninstall supervisor --keep-data` (or choose keep-data in the
`/plugin` UI) to retain it.

### Debug log caveat

When `debug: true`, raw third-party stderr (git output, tracebacks) can land in
`logs/debug.log` **unredacted**, because shell-level stderr cannot pass through
the Python redactor. It is off by default, written `0600`, truncated at 1 MB, and
wiped by `/supervisor:forget`. The plugin's own Python debug lines are redacted.

---

## Stay awake (v0.2)

While a session is alive, the machine is kept awake and the lock is scoped to the
owning `claude` process, so it cannot leak past the session:

- **adrafinil** (preferred when installed): the only option here that keeps a run
  going with the **lid closed**.
- **caffeinate** (macOS fallback): launched as `caffeinate -ims -w <claude-pid>`,
  detached into its own session so a hook timeout or terminal signal cannot reap
  it, and it exits the instant the `claude` process dies. Note: `caffeinate -ims`
  prevents idle, system, and disk sleep on AC power; it does **not** prevent
  lid-close sleep. That gap is exactly what adrafinil covers.
- **systemd-inhibit** (Linux fallback): an inhibitor tied to the `claude` pid.

A sweep at every session start cleans up any lock whose `claude` process is gone,
verifying the holder by command name so a recycled PID is never signalled.

---

## Auto-resume (v0.3)

> **Read this before enabling.** Auto-resume is **off by default** on purpose.

When enabled, hitting a rate limit schedules a single headless
`claude -p --resume` shortly after the quota window resets. This is the
walk-away overnight-run feature, and only that:

- **It spends your quota with nobody watching.** That is the whole point, and the
  reason it is opt-in.
- **It never types into your live terminal.** A hook has no controlling TTY, so
  auto-resume never continues your interactive REPL. If the interactive `claude`
  that hit the limit is still alive when the timer fires, the scheduler does
  **not** resume (it would fork history under you); it sends a notification and
  exits. It fully helps only the unattended case: a closed terminal or a `-p`
  run.
- **You are told when a resume is armed.** A desktop notification names the
  session and the approximate resume time, and how to cancel.
- **It cannot storm.** At most one resume timer is armed globally, at most one
  successful resume happens per quota window, and each attempt is bounded by
  `resume_max_minutes` of wall-clock time, so a hung `claude -p` is killed rather
  than blocking forever.

### Four ways to stop it

1. `/supervisor:config auto_resume false`
2. `touch <data-dir>/resume/DISABLED` (a kill-switch marker; presence blocks all resumes)
3. `kill <pid>` from any `resume/pending/*.json` file
4. Launch with `SUPERVISOR_DISABLE=1` to prevent scheduling entirely

### Known unknown

Claude Code shows a "Resume from summary / as-is / don't ask" dialog for Pro/Max
sessions that have been inactive for more than about an hour with large context,
which is exactly the post-reset situation. Its behavior under `claude -p` is not
yet documented or verified. The `resume_max_minutes` bound contains any blocking,
but this is confirmed only in the live smoke checklist
(`docs/MANUAL-SMOKE.md`, step 7). Enable auto-resume with that caveat in mind.

To enable: `/supervisor:config auto_resume true` (it will show the consequences
and ask you to confirm).

---

## Statusline (v0.4)

`/supervisor:statusline` installs a one-line status via a consent flow. A plugin
cannot contribute the main statusline on its own, so the skill edits
`~/.claude/settings.json` for you, but only after showing you the exact change
and getting an explicit yes. All file mechanics run inside a dedicated installer
that backs up your settings, makes a minimal edit, verifies the result parses,
and writes atomically; the model never hand-edits the file.

The rendered line looks like:

```
$0.42 · ctx 34% · 5h 62% ↺14:30 · 7d 18% · +120/-14
```

That is spend, context used, the 5-hour and 7-day quota windows with their reset
times, and lines added/removed. Segments with no data (for example, rate limits
on a non-Pro/Max account) are omitted.

The installed copy is fully self-contained with its data dir baked in, so it
keeps working across plugin updates. It also persists telemetry (cost and
rate-limit resets) into the plugin data dir, which is what feeds the digest cost
line and powers auto-resume scheduling. `/supervisor:statusline remove` restores
your previous statusline.

---

## Companion: cache warming with claude-thermos

This plugin does **not** warm the prompt cache (that needs API credentials and is
parked for a future version). If you want to keep the cache warm across idle gaps
during a long run, it composes cleanly with
[claude-thermos](https://github.com/izeigerman/claude-thermos): run your session
under it, for example

```
uvx claude-thermos
```

Nothing from claude-thermos is wrapped or bundled here; it is a separate,
compatible tool you run alongside the supervisor.

---

## Platform and degradation matrix

| Situation | Recorder | Awake | Resume | Statusline |
|---|---|---|---|---|
| macOS, full toolchain | full | adrafinil, else `caffeinate -ims -w` | full (opt-in) | full |
| Linux | full | `systemd-inhibit`, else no-op | full, minus desktop notify | full |
| Windows | no-op (unsupported) | no-op | no-op | not offered |
| Non-git project | full; reverted-change signal skipped | unaffected | unaffected | unaffected |
| `python3` absent | recorder/digest silently off | works (pure shell) | scheduling disabled | jq path works, telemetry off |
| `jq` absent | unaffected | unaffected | unaffected | python3 fallback |
| Plugin data dir unset (not a real hook) | hooks no-op, zero writes | no-op | no-op | resolves via baked dir |
| `disableAllHooks: true` | everything off | off | off | off |

Every hook is built so a missing interpreter or tool can disable a feature but
can never surface an error into, or add latency to, your session.

---

## Testing and verification

The plugin ships with a self-contained test harness (no framework dependencies)
and a live smoke checklist. See [CONTRIBUTING.md](CONTRIBUTING.md) for the
developer loop.

### Automated suite

Run everything from the repository root:

```
bash tests/run.sh
```

- **184 unit tests** (`python3 -m unittest`, standard library only) covering the
  digest builder, the redaction engine (31 secret-vector cases), project-key and
  containment logic, config, and capture.
- **50 integration tests** (pure `bash`, macOS `bash 3.2` compatible) that pipe
  the real hook payload shapes through the actual scripts in throwaway sandboxes:
  concurrent capture, self-noise exclusion, crash-without-`SessionEnd` rebuild,
  multi-session interleaving, the auto-resume state machine (with fake shims so no
  real quota is ever touched), and the statusline installer.
- A **lint gate** enforcing plugin structure, the hooks manifest, `bash 3.2`
  portability, and the injection-safety framing of the digest.
- `claude plugin validate .` passes for both the plugin and the marketplace
  manifest.

Latest run: **`50 passed, 0 failed, 3 skipped`**. The three skips are performance
latency gates that measure interpreter startup rather than the plugin; `RELEASE=1`
promotes any skip to a failure.

### Live verification

Everything that only a real model session can exercise is tracked in
[`docs/MANUAL-SMOKE.md`](docs/MANUAL-SMOKE.md). Verified in real
`claude --plugin-dir` sessions for 0.4.1:

| Check | Status |
|---|---|
| Start-of-session digest injected and used by the model, with no file reads | verified |
| `/clear` re-injects; `compact` deliberately does not | verified |
| Async capture keeps up (35 back-to-back reads, no slowdown) | verified |
| `/supervisor:recap` and the other skills | verified |
| Real sleep prevention (`caffeinate` assertion tied to the `claude` process) | verified |
| Crash recovery: `kill -9`, next start rebuilds the digest (synthetic end) | verified |
| First-run privacy notice appears once per data dir, then never again | verified |
| Auto-resume safety: nothing is armed unless you explicitly opt in | verified |
| Statusline installer: idempotent, backs settings up, never clobbers | verified |
| A real 5-hour rate-limit resume trigger | pending (needs organic conditions) |
| Interactive `/reload-plugins`; marketplace-install data split | pending |

---

## Attribution

This plugin was designed with lessons from three MIT-licensed projects. **No
source code from any of them is included.** If any is ever vendored, its MIT
copyright notice moves into a `NOTICE` file alongside this one.

- **Recall** - raiyanyahya, <https://github.com/raiyanyahya/recall> (MIT).
  Credited for the zero-token, fully-local principle and the lesson of keeping
  the store outside the repository. Its model-summarization approach was
  deliberately replaced here with structural signals.
- **claude-thermos** - izeigerman, <https://github.com/izeigerman/claude-thermos>
  (MIT). Credited for identifying the cache-TTL failure and the `max_tokens: 1`
  keepalive technique. Documented above as a compatible companion; nothing is
  wrapped in v0.1-v0.4.
- **adrafinil** - kageroumado, <https://github.com/kageroumado/adrafinil> (MIT).
  Wrapped through its public CLI exactly as documented; no code copied.
  Recommended for lid-closed operation.

---

## License

MIT, Copyright (c) 2026 Dylan Moraes. See [LICENSE](LICENSE).
