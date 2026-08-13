# Contributing

Thanks for looking at the internals. This plugin is deliberately small,
dependency-free, and defensive: a bug in a hook must never break or slow the
user's Claude Code session.

## Ground rules

- **No runtime dependencies.** Shell is POSIX `sh`/`bash` that must run on macOS
  `bash 3.2` (no associative arrays, no `mapfile`, no `${var,,}`). Python is
  `python3` standard library only, no pip.
- **Hooks fail safe.** Every hook entrypoint sources `scripts/lib/guard.sh`,
  exits `0` on any internal error, and no-ops silently when `python3` is missing.
- **Zero model calls, no network, no transcript parsing.** State is derived only
  from hook payloads and stored outside the repository.
- **Redaction happens before disk.** Any new captured field must pass through the
  redactor and gain a secret-vector test in `tests/fixtures/redaction-vectors.jsonl`.

## Developer loop

Load the plugin into a live session without installing it:

```
claude --plugin-dir /absolute/path/to/agent-session-supervisor
```

Then `/reload-plugins` (or relaunch) after edits. Dev-mode state lives under
`~/.claude/plugins/data/supervisor-inline/`.

## Tests

Run the suite from the repository root:

```
bash tests/run.sh          # lint + unit + integration
bash tests/run.sh lint     # just the structure / manifest / portability gate
python3 -m unittest discover -s tests/unit -p 'test_*.py'   # just the unit tests
```

- `tests/unit/` — `python3 unittest` for the pure logic (digest, redaction,
  common, capture). New pure logic gets a unit test.
- `tests/integration/` — `bash` tests that pipe real hook payload shapes
  (`tests/fixtures/payloads/`) through the actual scripts in a throwaway sandbox
  (`tests/lib.sh` sets up a temp `HOME`, data dir, and git fixture). New hook or
  skill behavior gets an integration test. Each test runs under a per-test
  timeout so nothing can hang the suite.
- `tests/integration/00-lint.sh` — the structure and portability gate.

TDD is the expectation: write the failing test first, then the smallest change
that makes it pass. Validate packaging with `claude plugin validate .`.

## Live smoke

Behavior that only a real model session exercises (digest injection, sleep
prevention, crash recovery, auto-resume) lives in `docs/MANUAL-SMOKE.md`. Record
results there.

## Layout

```
.claude-plugin/   plugin.json + marketplace.json (manifests only)
hooks/hooks.json  hook registrations
scripts/          entrypoints (hook-*.sh), lib/ helpers, py/ python core
skills/           the /supervisor:* commands
tests/            harness, fixtures, unit + integration
docs/             research notes, build FACTS, manual smoke checklist
```
