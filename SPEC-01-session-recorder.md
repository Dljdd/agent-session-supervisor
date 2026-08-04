# Spec 01 — Session Recorder
### v0.1 · the first thing to build · 28 July 2026

---

## What this is, and what it is emphatically not

**It is a flight recorder.** It logs what mechanically happened to a codebase during a Claude Code session, writes it to a local file, and pastes a short digest back in at the start of the next session.

**It is not a memory engine.** No embeddings. No vector store. No retrieval. No semantic understanding. No model calls. No cloud.

The distinction matters enough to write down, because "memory" points people at the wrong thing:

| | Supermemory / mem0 / Zep | This |
|---|---|---|
| Question answered | *"What does the AI know about me and my past conversations?"* | *"What happened to this code last time, and where did we get stuck?"* |
| Method | Embeddings + semantic retrieval | Counting tool calls |
| Storage | Vector DB, usually hosted | One JSONL file on disk |
| Cost per session | Model + infra | Zero |
| Can it hallucinate? | Yes | No — it can only report events that fired |

Closest existing analogue: `git log` crossed with a build log, formatted for an agent to read.

---

## The output — build toward exactly this

At the start of a session, the agent receives:

```
Last session — 2 days ago, 47 min, $1.20

  Edited src/auth/session.ts ×9        ← most churn, this is where you struggled
  FAILED ×4  npm run test:integration  ← "ECONNREFUSED 127.0.0.1:5432"
  Tests      npm test  red → green
  REVERTED   added src/cache/ (Redis layer), then removed it
  Read ×6    src/middleware/verify.ts  ← never changed it
```

**Hard cap: 400 tokens.** If the digest is long, it defeats its own purpose. Truncate by dropping the lowest-value lines first (reads, then successful commands).

The single most valuable line is `REVERTED`. "You already tried a Redis cache here and threw it away" is precisely what the agent will otherwise cheerfully re-suggest on Monday.

---

## Signals, and where each comes from

| Signal | Hook | Matcher | Notes |
|---|---|---|---|
| File edited | `PostToolUse` | `Write\|Edit` | Count per path. Repeated edits = difficulty. |
| File read but never edited | `PostToolUse` | `Read` | Where confusion lived. Fire `async: true` — this is high-frequency. |
| Command succeeded | `PostToolUse` | `Bash` | Record command + exit 0 |
| Command **failed** | `PostToolUseFailure` | `Bash` | Command + error, truncated. **Highest-value signal.** |
| Session boundaries | `SessionStart` / `SessionEnd` | `startup\|resume` | Capture git state at both ends |

### Red → green without parsing test output

Do **not** parse test framework output. It's fragile across jest, vitest, pytest, go test, cargo, and every custom runner.

Instead: **track exit status per command string over time.** If `npm test` exited non-zero at 14:02 and zero at 14:47, that's a red→green transition. Framework-agnostic, zero parsing, cannot break.

### Revert detection via git

Record at `SessionStart`:
```
git rev-parse HEAD
git status --porcelain
```
Record the same at `SessionEnd`. A file that appears in the edit events but shows **no net change** against the session-start state was written and then thrown away. That's a dead end worth reporting.

If the project isn't a git repo, skip revert detection entirely rather than guessing.

---

## Storage

```
${CLAUDE_PLUGIN_DATA}/<project-key>/
├── events.jsonl      # append-only, one event per line
├── sessions.jsonl    # one summary per completed session
└── digest.md         # current handoff note, regenerated at SessionEnd
```

**Use `${CLAUDE_PLUGIN_DATA}`, never `${CLAUDE_PLUGIN_ROOT}`.** Plugin root changes on every update; the data dir survives updates and uninstalls.

**`<project-key>`** = short hash of the git remote URL if present, else of `cwd`. Remote-based keying means the log follows the project across clones.

**Deliberately outside the repo.** Recall stores in-project and has to warn users to gitignore it, because a shared context file is a prompt-injection vector. Sidestep the whole problem.

### Event format

```jsonl
{"ts":1753689600,"s":"abc123","k":"edit","p":"src/auth/session.ts"}
{"ts":1753689612,"s":"abc123","k":"read","p":"src/middleware/verify.ts"}
{"ts":1753689655,"s":"abc123","k":"bash","cmd":"npm test","exit":1,"err":"2 failing"}
{"ts":1753692100,"s":"abc123","k":"bash","cmd":"npm test","exit":0}
```

Short keys because this file gets long. Rotate at 10 MB; keep the last 30 days.

---

## Hook registration

`hooks/hooks.json`:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "startup|resume",
        "hooks": [
          { "type": "command",
            "command": "\"${CLAUDE_PLUGIN_ROOT}\"/scripts/session-start.sh",
            "timeout": 10 }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Write|Edit",
        "hooks": [
          { "type": "command",
            "command": "\"${CLAUDE_PLUGIN_ROOT}\"/scripts/capture.sh",
            "async": true }
        ]
      },
      {
        "matcher": "Read",
        "hooks": [
          { "type": "command",
            "command": "\"${CLAUDE_PLUGIN_ROOT}\"/scripts/capture.sh",
            "async": true }
        ]
      },
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command",
            "command": "\"${CLAUDE_PLUGIN_ROOT}\"/scripts/capture.sh",
            "async": true }
        ]
      }
    ],
    "PostToolUseFailure": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command",
            "command": "\"${CLAUDE_PLUGIN_ROOT}\"/scripts/capture.sh",
            "async": true }
        ]
      }
    ],
    "SessionEnd": [
      {
        "hooks": [
          { "type": "command",
            "command": "\"${CLAUDE_PLUGIN_ROOT}\"/scripts/session-end.sh",
            "timeout": 20 }
        ]
      }
    ]
  }
}
```

**`session-start.sh`** must print JSON on stdout to inject the digest:

```json
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "Last session — 2 days ago, 47 min...\n  Edited src/auth/session.ts ×9..."
  }
}
```

### Hook input available on stdin

`session_id`, `transcript_path`, `cwd`, `permission_mode`, `hook_event_name`, `tool_name`, `tool_input`, `tool_output`, `tool_error`.

⚠️ **Do not parse `transcript_path`.** The JSONL transcript format is explicitly not a stable API and changes between releases. Hook payloads are the supported interface — use those.

---

## Secret handling — decide this before writing code

Captured command strings and error output *will* contain credentials eventually. Recall admits its redaction is *"best-effort, not a guarantee"*; don't repeat that framing, do better.

Required in v0.1:

1. **Store outside the repo** (already handled by `${CLAUDE_PLUGIN_DATA}`)
2. **Never store file contents** — paths and counts only
3. **Truncate error output to 200 characters**
4. **Redact on write**, minimum patterns: `sk-[A-Za-z0-9]{16,}`, `AKIA[0-9A-Z]{16}`, `Bearer\s+\S+`, `ghp_\S+`, `-----BEGIN.*PRIVATE KEY-----`, `(password|passwd|secret|token|api[_-]?key)\s*[=:]\s*\S+`, any bare string ≥32 chars of hex or base64
5. **Config switch** `capture_commands: false` for people who want paths only
6. Ship a `/supervisor:forget` command that wipes the store for the current project

Redaction happens **before** anything touches disk, not at digest time.

---

## Slash commands

| Command | Does |
|---|---|
| `/supervisor:recap` | Print the current digest |
| `/supervisor:forget` | Wipe this project's store |
| `/supervisor:log` | Show raw recent events |

Skills live at `skills/<name>/SKILL.md`. Namespacing is automatic — users invoke `/plugin-name:skill-name`.

---

## Acceptance criteria for v0.1

Build is done when all of these are true:

1. Edit `foo.ts` five times in a session; next session's digest says `foo.ts ×5`
2. Run a command that fails; digest shows the command and a truncated error
3. Fail `npm test`, then make it pass; digest shows `red → green`
4. Create a file, then delete it before session end; digest shows `REVERTED`
5. Digest never exceeds 400 tokens, even after a 4-hour session
6. `echo "export API_KEY=sk-abc123def456ghi789jkl"` never appears unredacted in `events.jsonl`
7. Non-git directory: everything still works, revert detection silently skipped
8. Plugin passes `claude plugin validate ./agent-session-supervisor --strict`

---

## Deliberately out of scope for v0.1

- Cache warming (needs API credentials — see README)
- Sleep prevention (v0.2)
- Auto-resume on quota (v0.3)
- Cross-machine sync
- Any model call, anywhere
- Codex / Cursor support — the hook system is what makes this feasible, so Claude Code only

---

## Build gotchas

- Component dirs go at plugin **root**, not inside `.claude-plugin/`. Only `plugin.json` lives there. This is the single most common plugin author mistake.
- Scripts need `chmod +x` and a shebang.
- Wrap path variables in quotes in shell form: `"\"${CLAUDE_PLUGIN_ROOT}\"/scripts/capture.sh"`
- Hook event names are case-sensitive — `PostToolUse`, not `postToolUse`
- Test locally with `claude --plugin-dir ./agent-session-supervisor`, reload with `/reload-plugins`
- Use `async: true` on the high-frequency capture hooks (`Read` especially) so you never add latency to a tool call
