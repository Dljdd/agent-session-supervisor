# Sources — every link, what it does, what to reuse

---

## The five tools

### 1. Recall — local project memory for Claude Code
- **Repo:** https://github.com/raiyanyahya/recall
- **Licence:** MIT · **Stars:** 679 · **Language:** Python
- **HN:** 138 points, 85 comments (21 June 2026)
- **Install:** `/plugin marketplace add raiyanyahya/recall` → `/plugin install recall@recall`
- **Commands:** `/recall:save`, `/recall:show`, `/recall:log`

**How it works:** two markdown files in `.recall/` — `history.md` (append-only session log) and `context.md` (auto-generated summary). Summarisation is **TF-IDF + TextRank**, classical extractive ranking. Uses numpy if importable, pure-Python fallback otherwise.

**Their pitch:** *"the summary is built locally, so capturing and updating your memory spends **zero** model tokens"* and *"Nothing leaves your machine."*

**Admitted weakness:** redaction is *"Best-effort, not a guarantee"*; they advise gitignoring `.recall/` because a shared context file is a prompt-injection vector.

**Reuse:** the zero-token/fully-local principle and the two-file layout are both good. Replace the summarisation approach entirely — see the structural-signals section in the README.

---

### 2. claude-thermos — keeps your prompt cache warm
- **Repo:** https://github.com/izeigerman/claude-thermos
- **Licence:** MIT · **Stars:** 4 · **Language:** Python
- **HN:** 111 points, 86 comments (23 July 2026)
- **Run:** `uvx claude-thermos` (drop-in for `claude`; args pass through)
- **Disable:** `CLAUDE_WARMER_DISABLE=1` · **Requires:** Python 3.11+, `claude` on PATH

**How it works:** a local reverse proxy. Anthropic's prompt cache has a 5-minute TTL. When the main agent sits idle waiting on a subagent for longer than that, the cache dies silently and the next turn re-encodes at expensive *write* rates instead of cheap *read* rates. Thermos detects that state and, before the TTL expires, replays the last request with **`max_tokens: 1`** — a cheap read that resets the clock.

**Their pitch:** *"Stop paying to rebuild your Claude Code cache."*

**Reuse:** the *technique* (`max_tokens: 1` replay of an identical cacheable prefix), not the code. The proxy architecture is the part a plugin can't adopt.

---

### 3. adrafinil — sleep prevention scoped to agent activity
- **Repo:** https://github.com/kageroumado/adrafinil
- **Licence:** MIT · **Stars:** 6 · **Language:** Swift (macOS only)
- **HN:** 124 points, 78 comments (27 June 2026)
- **CLI:** `adrafinil acquire <session-key> --tool claude-code` / `adrafinil release`
- **Install:** signed, notarised DMG from releases

**How it works:** three tiers — a CLI agents call via hooks, a LaunchAgent daemon holding reference-counted assertions and watching thermal and lid state, and a minimal LaunchDaemon privileged helper that is the only component touching sleep APIs. Keeps the Mac awake with the lid closed, but only while agents are working.

**Positioned against `caffeinate`,** which stays on indefinitely.

**Reuse:** **call its CLI directly** — it's explicitly designed to be driven from agent hooks. This is the cleanest wrap of the five. Fall back to `caffeinate` when adrafinil isn't installed.

---

### 4. coldstart
- **Source:** Ask HN: What are you working on? (July 2026) — https://news.ycombinator.com/item?id=48884984
- **Problem:** AI agents *"re-learn the codebase on every new session"*, wasting tokens and time.
- **Repo:** none found. ⚠️ Needs a search through the thread comments for a link.

---

### 5. Session resumption tool
- **Source:** Ask HN: What are you working on? (June 2026) — https://news.ycombinator.com/item?id=48528779
- **Problem:** *"I hate waking up and typing 'please continue'"* — auto-resume when quota resets.
- **Repo:** none found. ⚠️ Same.

---

## Adjacent, worth knowing about

- **OneCLI** — open-source credential gateway that keeps secrets out of AI agents. https://github.com/onecli/onecli · HN 110 pts, 23 July 2026. Relevant to the secret-leakage risk.
- **Ask HN: Has anyone replaced Claude/GPT with a local model for daily coding?** — https://news.ycombinator.com/item?id=48542100 · **1,318 points, 563 comments**, 15 June 2026. Where the cache-invalidation and edit-tool complaints are documented in depth. Useful background even though you're not building for local models.

---

## Official documentation

- Plugins reference — https://code.claude.com/docs/en/plugins-reference.md
- Plugins overview — https://code.claude.com/docs/en/plugins.md
- Hooks — https://code.claude.com/docs/en/hooks.md
- Sessions — https://code.claude.com/docs/en/sessions.md
- Statusline — https://code.claude.com/docs/en/statusline.md

---

## Licence summary

| Tool | Licence | Can you reuse the code? |
|---|---|---|
| Recall | MIT | Yes — retain copyright notice + licence text |
| claude-thermos | MIT | Yes — same |
| adrafinil | MIT | Yes — same |
| coldstart | unknown | ⚠️ Find the repo first |
| session resumption | unknown | ⚠️ Same |

MIT permits commercial use, modification and redistribution. The only obligation is preserving the copyright notice and licence text in any substantial portion you copy.

**Note:** if you *call* adrafinil's CLI rather than copying its code, you have no licence obligation at all — but credit them anyway.

---

## Hook events this project depends on

Verified against the current Claude Code docs:

| Event | Matcher | Use |
|---|---|---|
| `SessionStart` | `startup\|resume` | Inject memory via `additionalContext`; acquire wake-lock |
| `SessionEnd` | — | Release wake-lock; write final digest |
| `PostToolUse` | `Write\|Edit`, `Read` | Capture which files changed and which were re-read |
| `PostToolUseFailure` | `Bash` | Capture failed commands + errors — highest-value signal |
| `StopFailure` | `rate_limit` | Auto-resume when quota runs out |
| `SubagentStart` / `SubagentStop` | — | Detect main-agent idle windows for cache warming |
| `Stop` | — | End-of-turn bookkeeping |

**Hook input provides:** `session_id`, `transcript_path`, `cwd`, `permission_mode`, `tool_name`, `tool_input`, `tool_output`, `tool_error`.

**Hook output can return:** `additionalContext` (inject into context), `systemMessage` (show the user), `decision`/`reason`, `continue`/`stopReason`.

**Statusline receives:** `cost.total_cost_usd`, `cost.total_lines_added/removed`, `context_window.used_percentage`, `rate_limits.five_hour.resets_at`, `session_id`, `transcript_path`.

⚠️ **The transcript JSONL format is explicitly not a stable API** and changes between releases. Use hook payloads as the primary data source, not transcript parsing.
