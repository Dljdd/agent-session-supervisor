# Changelog

All notable changes to this plugin are recorded here. This project adheres to
semantic versioning.

## 0.4.1

Live verification, one field fix that it surfaced, and marketplace installability.

### Fixed

- **Data-dir containment no longer refuses `~/.claude` when `$HOME` is a git
  repo.** `/supervisor:recap`, `log`, `forget`, and `status` shell out to
  `supervisorctl` from the model's Bash, which does not receive
  `CLAUDE_PLUGIN_DATA`; it resolves the canonical `~/.claude/plugins/data/<id>`,
  and the containment check's "inside any git worktree" clause wrongly matched
  when the user's home directory is itself a git repo, refusing the plugin's own
  store. `containment_ok()` (Python) and `sup_dir_contained()` (shell) now exempt
  `~/.claude/`; the project/cwd refusal is unchanged, and a regression test pins
  both directions. Found by live smoke testing, which the offline suite could not
  catch (its tests set `CLAUDE_PLUGIN_DATA` directly, the containment-exempt
  branch).

### Added

- **Marketplace manifest** (`.claude-plugin/marketplace.json`): the repository is
  now its own single-plugin marketplace and installs via
  `/plugin marketplace add Dljdd/agent-session-supervisor`.
- **CONTRIBUTING.md** and a README "Testing and verification" section documenting
  the automated suite and the live-smoke results.

### Verified live

Real `claude --plugin-dir` sessions confirmed: start-of-session digest injection
and model use, `/clear` re-injection, async capture under load, the skills, real
sleep-prevention, `kill -9` crash recovery, once-only first-run disclosure, the
auto-resume opt-in safety gate, and the statusline installer. The real 5-hour
rate-limit resume trigger and interactive `/reload-plugins` remain in
`docs/MANUAL-SMOKE.md` as environment-bound follow-ups.

## 0.4.0

Initial build of the Agent Session Supervisor plugin: a zero-token, fully-local
session flight recorder with three opt-in capabilities layered on top. No model
calls, no transcript parsing, no cloud. State is stored outside the repository at
`0700`/`0600` and redacted before every write.

### Added

- **v0.1 - Session flight recorder + digest.** Hook capture of structural tool
  events into an append-only local log; a deterministic, layered redaction engine
  applied before every disk write; a start-of-session digest (hard-capped at 400
  tokens) injected as untrusted context; and the `recap`, `log`, `forget`, and
  `config` skills under the `/supervisor:` namespace.
- **v0.2 - Leak-proof stay-awake.** adrafinil wrapped via its public CLI, with a
  `caffeinate -ims -w` (macOS) and `systemd-inhibit` (Linux) fallback, each scoped
  to the owning `claude` process and swept at session start so a wake lock can
  never outlive its session.
- **v0.3 - Opt-in quota auto-resume (default off).** A `rate_limit` stop schedules
  a single detached headless resume after the quota window resets, sourced from
  persisted telemetry with a deterministic backoff-ladder fallback. Guarded by an
  arm-time singleton, an atomic per-window cap, a wall-clock timeout, protected
  config keys, and a strict resume-argument whitelist.
- **v0.4 - Opt-in cost/quota statusline (consent install).** A self-contained,
  update-surviving statusline showing spend, context use, and rate-limit resets,
  installed only after explicit approval; plus an end-of-session report and the
  telemetry persistence that feeds the digest cost line and the resume scheduler.

### Privacy and safety defaults

- Recorder on by default with a one-time first-run disclosure per data dir.
- File contents and transcripts are never captured. Git snapshots store counts
  and hashed path membership, never plaintext worktree filenames.
- Uninstalling from the last scope deletes the data dir unless `--keep-data` is
  passed. History can be erased per-project or entirely via the forget skill.

### Status

Offline test suite green (unit + lint + integration). Live smoke steps that
require a real session, real sleep prevention, and a real rate-limit resume are
tracked in `docs/MANUAL-SMOKE.md` and are pending live verification before a
tagged release. Auto-resume is not recommended for general use until
`docs/MANUAL-SMOKE.md` step 7 is recorded.
