# Agent Session Supervisor
### One Claude Code plugin that does what five separate tools currently do

*Project brief · 28 July 2026*

Working names: **Sustain**, **Campfire**, **Vigil**, **Keepwarm**. Pick one later.

---

## The idea in one paragraph

Five people independently built five small tools in June–July 2026, each patching a different way that a long-running Claude Code session falls apart. Nobody built the thing underneath. This plugin is that thing: **a single install that keeps an agent session alive, cheap, and continuous** — machine stays awake while work is happening, cache doesn't expire during idle gaps, the next session starts knowing what the last one did, and the session picks itself back up when the quota resets.

You're not inventing the ideas. You're consolidating five proven ones into a thing people install once. That's a legitimate product and a much faster path than inventing.

---

## The five failures, and who patched each

| Failure mode | Existing tool | Stars | Licence |
|---|---|---|---|
| Machine sleeps mid-run | [adrafinil](https://github.com/kageroumado/adrafinil) | 6 | MIT |
| Cache expires during idle gaps, you pay to rebuild | [claude-thermos](https://github.com/izeigerman/claude-thermos) | 4 | MIT |
| Next session starts knowing nothing | [Recall](https://github.com/raiyanyahya/recall) | 679 | MIT |
| Agent re-learns the codebase every session | `coldstart` (Ask HN, July 2026 — no public repo found) | — | — |
| Session stops and waits for you to type "continue" | session resumption tool (Ask HN, June 2026 — no public repo found) | — | — |

**The number worth noticing:** claude-thermos and adrafinil each hit the HN front page (111 and 124 points, 86 and 78 comments) and have **4 and 6 stars**. Attention did not convert to adoption. People recognise the problem and won't install a point solution for each symptom. That's the argument for one plugin.

---

## Architecture — and a better plan than wrapping

I pulled the current Claude Code plugin and hooks reference. **Most of this doesn't need wrapping at all — the hook system can do it natively**, which is cleaner and far less brittle than shelling out to five tools.

### What maps to what

| Capability | How to build it |
|---|---|
| **Memory / continuity** | `PostToolUse` + `PostToolUseFailure` hooks capture structural signals during the session. `SessionStart` hook (matcher `startup\|resume`) injects the digest via `additionalContext`. |
| **Auto-resume on quota reset** | `StopFailure` hook with matcher `rate_limit`. This event exists specifically for turns that die on API errors — it's the exact hook for this. |
| **Stay awake while working** | `SessionStart` → acquire, `Stop`/`SessionEnd` → release. adrafinil already ships a CLI (`adrafinil acquire <key> --tool claude-code`) *designed* to be called from hooks, so wrap it when present and fall back to `caffeinate` when not. |
| **Session cost + what happened** | Statusline receives `cost.total_cost_usd`, `context_window`, `total_lines_added/removed`, and `rate_limits.five_hour.resets_at`. All of it is already handed to you. |
| **Cache warming** | ⚠️ The hard one — see below. |

### The one genuine integration problem

**claude-thermos can't be wrapped by a plugin.** It's a launcher — you run `uvx claude-thermos` *instead of* `claude`, and it proxies the API. A plugin loads inside a session that has already started, so it can't put itself in front of the API.

Two options:

1. **Reimplement warming via hooks.** `SubagentStart` and `SubagentStop` tell you exactly when the main agent goes idle waiting on a subagent — the precise condition thermos watches for. An `async: true` command hook could issue the keepalive request. Needs API credentials, which is a real design decision.
2. **Ship it as a documented companion.** "Run under thermos for cache warming." Honest, zero effort, weaker product.

**Start with option 2, move to option 1 if people care.** Don't let the hardest piece block v1.

### Storage

Use `${CLAUDE_PLUGIN_DATA}` (→ `~/.claude/plugins/data/{id}/`), **not** `${CLAUDE_PLUGIN_ROOT}`. Plugin root changes on every update; the data dir survives updates and uninstalls.

### Plugin layout

```
agent-session-supervisor/
├── .claude-plugin/
│   └── plugin.json          # manifest — only this file goes in here
├── hooks/
│   └── hooks.json           # all hook registrations
├── scripts/
│   ├── capture.sh           # PostToolUse / PostToolUseFailure → append signals
│   ├── digest.py            # build the session digest
│   ├── inject.sh            # SessionStart → emit additionalContext
│   ├── awake.sh             # acquire / release
│   └── resume.sh            # StopFailure(rate_limit) → schedule resume
├── skills/
│   └── recap/SKILL.md       # /supervisor:recap — what happened last session
└── settings.json            # optional statusline
```

Component directories go at plugin **root**, not inside `.claude-plugin/`. That's the single most common thing that breaks for plugin authors.

---

## The actual differentiator: the session recorder

**→ Full implementation spec: [`SPEC-01-session-recorder.md`](./SPEC-01-session-recorder.md)**

A naming note first, because it matters. I called this "memory" earlier and that was wrong — it points people at Supermemory, mem0, Zep and the whole semantic-memory category. **This is not that.** No embeddings, no vector store, no retrieval, no model calls. It's a flight recorder: it logs what mechanically happened to the codebase and hands a short digest to the next session. Closest analogue is `git log` crossed with a build log.

This is the part worth caring about, and it's where you beat Recall rather than repackaging it.

**Recall summarises with TF-IDF + TextRank** — classical algorithms that rank sentences by which words appear most. That surfaces what was *discussed*, not what *mattered*. A session where you burned an hour failing looks much like one where you succeeded immediately.

**Use structural signals instead.** Still zero tokens, still fully local, dramatically better signal:

| Signal | Captured from | Why it matters |
|---|---|---|
| Files edited, and how many times | `PostToolUse` matcher `Write\|Edit` | Repeated edits = where the difficulty was |
| Commands that **failed**, with the error | `PostToolUseFailure` matcher `Bash` | The single most useful thing to know next session |
| Tests red → green (or green → red) | Bash output parsing | Actual progress, not narrated progress |
| **Written then reverted** | Diff the edit stream | A dead end. Worth more than any summary sentence. |
| Files read repeatedly, never edited | `PostToolUse` matcher `Read` | Where confusion lived |

Deterministic, cheap, private, and genuinely more useful than sentence ranking. **Ship this piece standalone first** — it's the highest-value part, the least likely to be commoditised well by the platform, and it works on its own.

---

## Build order

**v0.1 — session recorder only.** Capture hooks, digest builder, `SessionStart` injection, `/recap` skill. Standalone value, no dependencies on the other four tools. **Spec written: [`SPEC-01-session-recorder.md`](./SPEC-01-session-recorder.md).**

**v0.2 — stay awake.** Wrap adrafinil's CLI where present, `caffeinate` fallback. Two hooks, half a day.

**v0.3 — auto-resume.** `StopFailure` + `rate_limit` matcher. Read `rate_limits.*.resets_at` to schedule.

**v0.4 — session report.** Statusline plus an end-of-session summary: cost, files touched, tests fixed, dead ends.

**v0.5 — cache warming.** Only if v0.1–0.4 got users.

---

## Honest risks

1. **Anthropic could ship most of this.** Memory, session persistence and resume are natural platform features. Mitigation: the structural-signal memory is a real insight and harder to copy casually; and being the consolidator has value even if individual pieces get absorbed.
2. **The transcript format is explicitly not a stable API** — it changes between releases. Don't parse `~/.claude/projects/**/*.jsonl` as your primary source. Use hook payloads, which are a supported interface.
3. **thermos is a launcher, not a library.** Covered above.
4. **adrafinil is macOS-only and Swift.** Linux and Windows need a different path.
5. **Secret leakage.** Recall admits redaction is *"best-effort, not a guarantee"* and warns to gitignore its directory. You'll inherit that problem the moment you capture command output. Decide early: store under `${CLAUDE_PLUGIN_DATA}` (outside the repo) rather than in-project.

---

## Licence position

All three public tools are **MIT**, so reuse, modification and commercial use are all permitted, provided you retain the copyright notice and licence text.

Attribute properly anyway — credit them in the README by name and link. This is a small community, these are individual authors, and being the person who consolidated their work generously is worth more than the code you'd save by not saying so.

---

## Open questions before you start

- Does `coldstart` have a public repo? I couldn't find one — it was only mentioned in the Ask HN thread.
- Same for the session-resumption tool.
- Does the plugin need API credentials for cache warming, and do you want that responsibility in v1? (Suggested answer: no.)
- Does this work for Codex/Cursor too, or is Claude Code-only the right v1 scope? (Suggested answer: Claude Code only — the hook system is what makes it feasible.)
