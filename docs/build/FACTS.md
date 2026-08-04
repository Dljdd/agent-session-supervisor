# FACTS.md — verified contract reference for the Agent Session Supervisor build

Produced by the FACTS agent, 2026-07-29. Every statement below is either
(a) quoted from the live doc dumps in `docs/build/dumps/` (fetched from
code.claude.com today, 2026-07-29), (b) quoted from the four project docs, or
(c) verified locally right now with a command (marked **VERIFIED-LOCAL**).
Anything uncertain is marked **UNVERIFIED**.

Doc dump citations use `<file>:<line>` referring to files in
`/Users/dylanmoraes/Documents/GitHub/agent-session-supervisor/docs/build/dumps/`:
`plugins-reference.md` (1303 lines), `hooks.md` (3161 lines), `statusline.md`
(1112 lines), `plugins.md` (504 lines), `sessions.md` (195 lines), `skills.md`
(927 lines).

---

## 0. Environment (VERIFIED-LOCAL, 2026-07-29)

The orchestrator's environment block arrived as "undefined" in this agent's
prompt, so everything here was re-verified directly:

| Fact | Value | How verified |
|---|---|---|
| Claude Code CLI version | **2.1.126** | `claude --version` → `2.1.126 (Claude Code)` |
| claude binary | `/Users/dylanmoraes/.local/bin/claude` | `which claude` |
| `--plugin-dir` flag | **EXISTS**: `--plugin-dir <path>  Load plugins from a directory for this session only (repeatable: --plugin-dir A --plugin-dir B) (default: [])` | `claude --help` |
| `claude plugin validate <path>` | **EXISTS**, options are `-h, --help` **only** | `claude plugin validate --help` |
| `claude plugin validate ./x --strict` | **FAILS**: `error: unknown option '--strict'` (exit 1) | run on a scaffolded test plugin |
| `claude plugin validate ./x` (no flag) | Works; prints warnings for missing description/author; `✔ Validation passed with warnings`, exit 0 | run on a scaffolded test plugin |
| `claude plugin init` | **DOES NOT EXIST** on 2.1.126 (subcommands: disable, enable, help, install, list, marketplace, prune, tag, uninstall, update, validate) | `claude plugin --help` |
| `claude plugin uninstall --keep-data` | EXISTS: `--keep-data  Preserve the plugin's persistent data directory (~/.claude/plugins/data/{id}/)` | `claude plugin uninstall --help` |
| macOS | 15.1 (Darwin 24.1.0, arm64) | `sw_vers` |
| bash | **3.2.57** (`/bin/bash`) — macOS default; NO bash-4 features (no associative arrays, no `${var,,}`) | `bash --version` |
| jq | 1.6 at `/usr/bin/jq` | `jq --version` |
| python3 | 3.11.9 (pyenv shim) | `python3 --version` |
| node | v23.7.0 | `node --version` |
| git | 2.39.5 (Apple Git-154) | `git --version` |
| Repo branch | `build/plugin-v0.1-0.4` (repo at `/Users/dylanmoraes/Documents/GitHub/agent-session-supervisor`, contains only the 4 research docs + this build dir) | `git branch` |
| **Anthropic auth** | **OAuth token EXPIRED**: `claude -p` fails with `API Error: 401 ... OAuth access token has expired. Re-authenticate to continue.` Hooks still fire (see §2.1) but any test needing a model response is blocked until the user re-authenticates. | live `claude -p` run |
| `~/.claude/plugins/` | contains `cache/`, `data/`, `installed_plugins.json`, `known_marketplaces.json`, `marketplaces/`, `blocklist.json` | `ls` |

### Live hook execution test (VERIFIED-LOCAL — the single most load-bearing verification)

A test plugin (`.claude-plugin/plugin.json` with `name: test-plugin`, plus
`hooks/hooks.json` with a SessionStart command hook) was run via
`claude -p "..." --plugin-dir ./test-plugin`. The hook **fired before/despite
the 401 auth failure** and dumped:

```
CLAUDE_PLUGIN_ROOT=/…/scratchpad/test-plugin                        (the --plugin-dir path, used in place)
CLAUDE_PLUGIN_DATA=/Users/dylanmoraes/.claude/plugins/data/test-plugin-inline
CLAUDE_PROJECT_DIR=/…/scratchpad                                    (the cwd)
CLAUDE_ENV_FILE=/Users/dylanmoraes/.claude/session-env/<session-id>/sessionstart-hook-0.sh
STDIN_JSON={"session_id":"b7780f89-…","transcript_path":"/Users/dylanmoraes/.claude/projects/<sanitized-cwd>/<session-id>.jsonl","cwd":"/…/scratchpad","hook_event_name":"SessionStart","source":"startup"}
```

Conclusions verified on installed 2.1.126:
1. All three path variables ARE exported as environment variables to hook processes.
2. `${CLAUDE_PLUGIN_DATA}` for a `--plugin-dir` plugin resolves to
   `~/.claude/plugins/data/<name>-inline/` (plugin id is `<name>@inline`,
   sanitized `@`→`-`). The directory was **created on first reference**
   (confirmed by `ls`; other plugins on this machine show the same pattern:
   `superpowers-inline`, `aws-core-claude-plugins-official`, …).
   **Consequence: dev-mode (`--plugin-dir`) data and marketplace-install data
   live in different directories; state does not migrate between them.**
3. SessionStart stdin on 2.1.126 carries exactly: `session_id`,
   `transcript_path`, `cwd`, `hook_event_name`, `source`. No `permission_mode`,
   no `model`, no `prompt_id` (docs mark `prompt_id` as ≥2.1.196).
4. SessionStart hooks fire in `-p` (headless) mode and fire even when API auth
   fails.
5. `CLAUDE_ENV_FILE` is present in the SessionStart hook environment.

---

## 1. Hook events used by this plugin — exact contracts

Source: `hooks.md` dump unless noted. Plugin hooks "respond to the same
lifecycle events as user-defined hooks" (plugins-reference.md:113).

Cadence (hooks.md:19-23): "once per session: `SessionStart` and `SessionEnd`;
once per turn: `UserPromptSubmit`, `Stop`, and `StopFailure`; on every tool
call inside the agentic loop: `PreToolUse` and `PostToolUse`".

### 1.1 Common stdin fields (hooks.md:618-639)

All events receive JSON on stdin with: `session_id`, `prompt_id` (≥2.1.196,
"Absent until the first user input"), `transcript_path`, `cwd`,
`permission_mode` ("Not all events receive this field"), `effort` (object with
`level`; only for tool-use-context events), `hook_event_name`. Inside
subagents, also `agent_id` and `agent_type`.

- `transcript_path` caveat (hooks.md:626): "The transcript file is written
  asynchronously and may lag the in-memory conversation".
- Only SessionStart can receive a `model` field, "not guaranteed to be
  present" (hooks.md:639). There is no `$CLAUDE_MODEL` env var.

### 1.2 SessionStart (hooks.md:932-1050)

- Fires "when Claude Code starts a new session or resumes an existing
  session". "Only `type: "command"` and `type: "mcp_tool"` hooks are
  supported." "SessionStart runs on every session, so keep these hooks fast."
- **Matcher values** (full set): `startup` (new session), `resume`
  (`--resume`, `--continue`, or `/resume`), `clear` (`/clear`), `compact`
  (auto or manual compaction), `fork` (≥2.1.214; "Before v2.1.214, forked
  sessions reported source `"resume"`"). SPEC-01's matcher `startup|resume`
  therefore deliberately excludes `clear`/`compact`/`fork` — after `/clear`
  the digest would NOT inject (decide intentionally; on installed 2.1.126
  `fork` doesn't exist and reports `resume`).
- **Input fields**: common fields + `source`, optional `model` ("can be
  omitted, for example after `/clear`"), optional `agent_type`, optional
  `session_title`.
- **Output contract** — exit 0 and either plain stdout ("Any text your hook
  script prints to stdout is added as context for Claude"; SessionStart is one
  of the three events where "stdout is added as context", hooks.md:668) or the
  exact JSON (hooks.md:984-992):

```json
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "…string injected at the start of the conversation, before the first prompt…"
  }
}
```

  Additional SessionStart-only output fields: `initialUserMessage` (headless
  `-p` first turn), `sessionTitle` (applies on `startup|resume|fork`, ignored
  on `clear`/`compact`), `watchPaths` (array of absolute paths for FileChanged),
  `reloadSkills` (bool, re-scan skill dirs after hooks complete).
- Exit 2 **cannot block** SessionStart: "Shows stderr to user only"
  (hooks.md:718); as of 2.1.199 the stderr shows in transcript, earlier only
  debug log — installed 2.1.126 = debug log only.
- Resume behavior (hooks.md:850): "`SessionStart` hooks run again on resume
  with `source` set to `"resume"` … so they can refresh their context." Mid-
  session hooks' saved `additionalContext` is replayed, not re-run.
- `CLAUDE_ENV_FILE` available (SessionStart, Setup, CwdChanged, FileChanged
  only) to persist env vars for subsequent Bash commands (hooks.md:1009-1050).

### 1.3 PostToolUse (hooks.md:1702-1770)

- "Runs immediately after a tool completes successfully." Matcher = tool name
  (`Write|Edit`, `Read`, `Bash`, regex allowed; `Edit, Write` comma form needs
  ≥2.1.191 — use `|` on 2.1.126).
- **Input**: common fields + `tool_name`, `tool_input`, **`tool_response`**
  (NOT `tool_output`), `tool_use_id`, `duration_ms` (optional, ms, "Excludes
  time spent in permission prompts and PreToolUse hooks").
- For `Write`: `tool_input.file_path`, `tool_input.content`; `tool_response`
  e.g. `{"filePath": "...", "success": true}`. For `Bash`: `tool_input.command`,
  `tool_input.description`; Bash output object shape is `{stdout, stderr,
  interrupted, isImage}` (hooks.md:1756-1761).
- **Output**: `decision: "block"` + `reason`, `hookSpecificOutput.
  additionalContext`, `updatedToolOutput`. Exit 2 = "Shows stderr to Claude;
  the tool already ran" (cannot un-run it).

### 1.4 PostToolUseFailure (hooks.md:1772-1826)

- "Runs when a tool that started executing fails: the tool threw an error, or
  an MCP tool returned an error result."
- **Does NOT fire** for: unknown tool name, input schema validation failures,
  or permission denials (hooks.md:1779).
- **Input**: common fields + `tool_name`, `tool_input`, `tool_use_id`, and
  top-level **`error`** (string, e.g. `"Command exited with non-zero status
  code 1"`), **`is_interrupt`** (optional bool, user interruption),
  `duration_ms` (optional). **There is NO `tool_error` field and NO numeric
  exit-code field** — the exit code must be parsed out of the `error` string
  or simply recorded as pass/fail.
- **Output**: only `hookSpecificOutput.additionalContext`. Exit 2 = stderr
  shown to Claude, nothing blocked.

### 1.5 Stop (hooks.md:2171-2269)

- "Runs when the main Claude Code agent has finished responding. Does not run
  if the stoppage occurred due to a user interrupt. API errors fire
  StopFailure instead." No matcher support.
- **Input**: common fields + `stop_hook_active` (true when already continuing
  due to a stop hook; "Claude Code overrides the hook and ends the turn after
  8 consecutive blocks"), `last_assistant_message` (final response text — use
  this, not the transcript), `background_tasks` array and `session_crons`
  array (both ≥2.1.145; distinguish "session done" from "paused waiting for
  background work"). `background_tasks` entries: `id`, `type`
  (shell|subagent|monitor|workflow|teammate|cloud session|MCP task), `status`,
  `description` (cap 1000 chars), plus type-specific `command`/`agent_type`/
  `server`/`tool`/`name`. `session_crons` entries: `id`, `schedule`,
  `recurring`, `prompt`.
- **Output**: `decision:"block"` + required `reason` (prevents stopping,
  reason becomes next instruction), or `hookSpecificOutput.additionalContext`
  (continues conversation as "Stop hook feedback", same 8-cap loop
  protection).

### 1.6 StopFailure (hooks.md:2271-2297)

- "Runs instead of Stop when the turn ends due to an API error. **Output and
  exit code are ignored.**" (also plugins-reference.md:134). "StopFailure
  hooks have no decision control. They run for notification and logging
  purposes only."
- **Matcher values (error types), full list** (hooks.md:233 & 2281):
  `rate_limit`, `overloaded`, `authentication_failed`,
  `oauth_org_not_allowed`, `billing_error`, `invalid_request`,
  `model_not_found`, `server_error`, `max_output_tokens`, `unknown`.
- **Matcher syntax restriction** (hooks.md:214): "`FileChanged` and
  `StopFailure` use a narrower exact-match set of letters, digits, `_`, and
  `|` only … only `|` separates alternatives" (no commas/spaces/hyphens).
- **Input**: common fields + `error` (the type string, used for matching),
  optional `error_details` ("Additional details about the error, when
  available", example: `"429 Too Many Requests"`), optional
  `last_assistant_message` ("the API error string itself, such as `"API
  Error: Rate limit reached"`").
- **⚠️ There is NO rate-limit reset timestamp anywhere in the StopFailure
  payload.** The docs' example `error_details` is just `"429 Too Many
  Requests"`. Whether `error_details` ever contains a reset time:
  **UNVERIFIED** — no doc states it. **Design implication: v0.3 resume
  scheduling cannot rely on StopFailure input for the reset time.** The only
  documented source of `resets_at` is the statusline stdin
  (`rate_limits.five_hour.resets_at` / `rate_limits.seven_day.resets_at`,
  epoch seconds — see §6), which a plugin cannot install (see §6.3). Options:
  have the resume daemon poll/backoff, or cache `resets_at` from a
  user-opt-in statusline script.

### 1.7 SessionEnd (hooks.md:2650-2686)

- "Runs when a Claude Code session ends." "SessionEnd hooks have no decision
  control."
- **Matcher values (`reason` field)**: `clear`, `resume` (switched via
  interactive `/resume`), `logout`, `prompt_input_exit`,
  `bypass_permissions_disabled`, `other`.
- **Input**: common fields + `reason`.
- **⚠️ Timeout budget** (hooks.md:2682, quoted in full): "SessionEnd hooks
  have a default timeout of 1.5 seconds. This applies to session exit,
  `/clear`, and switching sessions via interactive `/resume`. If a hook needs
  more time, set a per-hook `timeout` in the hook configuration. The overall
  budget is automatically raised to the highest per-hook timeout configured
  in settings files, up to 60 seconds. **Timeouts set on plugin-provided hooks
  don't raise the budget.** To override the budget explicitly, set the
  `CLAUDE_CODE_SESSIONEND_HOOKS_TIMEOUT_MS` environment variable in
  milliseconds."
  **Design implication: SPEC-01's `"timeout": 20` on the plugin's SessionEnd
  hook does NOT buy 20 s — the digest write must fit in ~1.5 s, or digest
  building must happen incrementally earlier (e.g. at capture/Stop time), or
  docs must tell users to set the env var.**
- Reliability: nothing documented about SessionEnd firing on crash/SIGKILL —
  **UNVERIFIED**; design for missed SessionEnd (idempotent digest rebuild at
  next SessionStart is the safe pattern).

### 1.8 SubagentStart / SubagentStop (hooks.md:1995-2058)

- SubagentStart input: common + `agent_id`, `agent_type`. Matcher = agent
  type; plugin-scoped names look like `my-plugin:reviewer` and the colon puts
  the matcher on the regex path — anchor as `^my-plugin:reviewer$`.
- SubagentStart output: `hookSpecificOutput.additionalContext` (into the
  subagent). Cannot block ("Shows stderr to user only").
- SubagentStop input: common + `stop_hook_active`, `agent_id`, `agent_type`,
  `agent_transcript_path`, `last_assistant_message`, plus `background_tasks`
  and `session_crons` (≥2.1.145, scoped to parent session). Decision control
  same as Stop.
- Hooks from plugins also run inside subagents (hooks.md:187): tool events
  fire the same configured hooks with `agent_id`/`agent_type` added —
  **capture hooks will see subagent tool calls too; use `agent_id` presence to
  distinguish.**

### 1.9 Exit codes and JSON output (hooks.md:664-758)

- Exit 0: stdout parsed for JSON. "JSON output is only processed on exit 0."
- Exit 2: blocking where supported; "stderr text is fed back to Claude".
- Any other exit code: non-blocking error; "transcript shows a `<hook name>
  hook error` notice followed by the first line of stderr".
- "For most hook events, only exit code 2 blocks the action. Claude Code
  treats exit code 1 as a non-blocking error".
- "Hook output strings, including `additionalContext`, `systemMessage`, and
  plain stdout, are capped at 10,000 characters" (larger values written to a
  file and passed as path+preview). SPEC-01's 400-token digest fits easily.
- Universal JSON fields: `continue` (false stops Claude entirely),
  `stopReason`, `suppressOutput`, `systemMessage`, `terminalSequence`
  (≥2.1.141, allowlisted OSC/BEL only).
- additionalContext phrasing guidance (hooks.md:848): "Write the text as
  factual statements rather than imperative system instructions … Text framed
  as out-of-band system commands can trigger Claude's prompt-injection
  defenses."

### 1.10 async / timeout semantics (hooks.md:337, 365-366, 2986-3087)

- `timeout` (common field): "Seconds before canceling. Defaults: 600 for
  `command`, `http`, and `mcp_tool`; 30 for `prompt`; 60 for `agent`."
  (UserPromptSubmit lowers command default to 30; MessageDisplay to 10.)
- `async` (command hooks only): "If `true`, runs in the background without
  blocking." "Async hooks can't block or control Claude's behavior." Output
  with `additionalContext` "is delivered to Claude as context on the next
  conversation turn"; if idle, waits for next interaction. "Each execution
  creates a separate background process. There is no deduplication across
  multiple firings of the same async hook." Async timeout default is the same
  600 s.
- `asyncRewake`: async + wakes Claude on exit code 2 even when idle.
- All matching hooks run in parallel; "identical handlers are deduplicated
  automatically. Command hooks are deduplicated by command string and `args`"
  (hooks.md:325). (SPEC-01's three PostToolUse matcher groups all pointing at
  `capture.sh` are fine — a given tool matches only one group — but a single
  matcher `Write|Edit|Read|Bash` would be equivalent and simpler.)
- Hooks run without a controlling terminal (≥2.1.139); no `/dev/tty`.

### 1.11 Plugin hooks.json exact schema

Location: `hooks/hooks.json` at plugin root, or inline/custom path via
`plugin.json` `hooks` field (string|array|object) (plugins-reference.md:89,
527). Optional top-level `description` field (hooks.md:531). Shape
(plugins-reference.md:95-111 and hooks.md:535-554):

```json
{
  "description": "optional",
  "hooks": {
    "<EventName>": [
      {
        "matcher": "optional-filter",
        "hooks": [
          {
            "type": "command",
            "command": "\"${CLAUDE_PLUGIN_ROOT}\"/scripts/x.sh",   // shell form
            "args": [],            // presence switches to exec form (preferred for placeholder paths)
            "timeout": 30,
            "async": true,
            "if": "Bash(git *)",   // tool events only
            "statusMessage": "…",
            "shell": "bash"
          }
        ]
      }
    ]
  }
}
```

- Hook types: `command`, `http`, `mcp_tool`, `prompt`, `agent`
  (plugins-reference.md:148-154).
- Exec form vs shell form (hooks.md:371-406): `args` present → spawned
  directly, no shell, placeholders substituted into `command` and each args
  element, no quoting needed. `args` absent → `sh -c` (macOS/Linux); wrap
  placeholders in double quotes: `"\"${CLAUDE_PLUGIN_ROOT}\"/scripts/x.sh"`.
  "Both forms … export them as the environment variables CLAUDE_PROJECT_DIR,
  CLAUDE_PLUGIN_ROOT, and CLAUDE_PLUGIN_DATA on the spawned process"
  (hooks.md:402).
- Hook event names are case-sensitive (`PostToolUse` not `postToolUse`)
  (plugins-reference.md:1223).
- Scripts need `chmod +x` and a shebang (plugins-reference.md:1216-1218).
- Hook entries merge across settings levels; plugin hooks merge with user and
  project hooks (hooks.md:191, 531). `disableAllHooks: true` disables all
  (including the statusline, statusline.md:1054).
- Matcher evaluation (hooks.md:200-216): `"*"`, `""`, or omitted = match all;
  only `[A-Za-z0-9_\- ,|]` = exact string/list; anything else = JS regex,
  unanchored (`RegExp.prototype.test`). Comma separators ≥2.1.191; hyphens in
  exact set ≥2.1.195. **On installed 2.1.126 use `|` separators and anchor
  any regex.**

---

## 2. `${CLAUDE_PLUGIN_ROOT}` / `${CLAUDE_PLUGIN_DATA}` / `${CLAUDE_PROJECT_DIR}`

- Definition table (plugins-reference.md:669-673): ROOT = "Absolute path to
  the plugin's installation directory"; DATA = "Persistent directory that
  survives plugin updates, created on first reference"; PROJECT_DIR = "The
  project root".
- **Export quote** (plugins-reference.md:675): "All three are exported as
  environment variables to hook processes and to MCP and LSP server
  subprocesses." **VERIFIED-LOCAL on 2.1.126** (§0).
- Inline substitution scope (plugins-reference.md:677-683): skill/agent
  content and hook/monitor commands substitute "anywhere the placeholder
  appears"; MCP stdio servers: `command`, `args`, `env`; LSP: `command`,
  `args`, `env`, `workspaceFolder`.
- ROOT instability (plugins-reference.md:704): "`${CLAUDE_PLUGIN_ROOT}`
  changes when the plugin updates. The previous version's directory remains on
  disk for about two weeks after an update before cleanup".
- **DATA resolution + id sanitization** (plugins-reference.md:712): "The
  `${CLAUDE_PLUGIN_DATA}` directory resolves to `~/.claude/plugins/data/{id}/`,
  where `{id}` is the plugin identifier with characters outside `a-z`, `A-Z`,
  `0-9`, `_`, and `-` replaced by `-`. For a plugin installed as
  `formatter@my-marketplace`, the directory is
  `~/.claude/plugins/data/formatter-my-marketplace/`."
  VERIFIED-LOCAL: `--plugin-dir` loads get id `<name>@inline` →
  `~/.claude/plugins/data/<name>-inline/`.
- **Uninstall deletes DATA by default** (plugins-reference.md:753): "The data
  directory is deleted automatically when you uninstall the plugin from the
  last scope where it is installed. The `/plugin` interface shows the
  directory size and prompts before deleting. The CLI deletes by default; pass
  `--keep-data` to preserve it." Also plugins-reference.md:984. VERIFIED-LOCAL
  (`uninstall --help` shows `--keep-data`).
  **→ Contradicts README.md:59 and SPEC-01:84 ("the data dir survives updates
  and uninstalls"). It survives UPDATES only; uninstall from last scope
  deletes it unless `--keep-data`.**
- Update-mid-session (plugins-reference.md:706): running hooks keep the old
  path until `/reload-plugins` (monitors need restart).
- Marketplace plugins are COPIED to `~/.claude/plugins/cache`; "Installed
  plugins cannot reference files outside their directory"
  (plugins-reference.md:764-772). `--plugin-dir` plugins are used in place
  (VERIFIED-LOCAL: ROOT = the given dir).

---

## 3. plugin.json manifest

- Lives at `.claude-plugin/plugin.json`. "The manifest is optional. If
  omitted, Claude Code auto-discovers components in default locations and
  derives the plugin name from the directory name" (plugins-reference.md:419).
- **Required**: "If you include a manifest, `name` is the only required
  field." `name`: "Unique identifier (kebab-case, no spaces)"
  (plugins-reference.md:456-462). Name is the namespace: agent
  `agent-creator` in plugin `plugin-dev` appears as `plugin-dev:agent-creator`.
- Metadata fields: `$schema`, `displayName` (≥2.1.143), `version`
  (optional; "If omitted, Claude Code falls back to the git commit SHA";
  plugin.json wins over marketplace entry), `description`, `author` (object:
  name/email/url), `homepage`, `repository`, `license`, `keywords`,
  `defaultEnabled` (≥2.1.154; earlier versions ignore it and enable on
  install) (plugins-reference.md:495-506).
- Component path fields: `skills` (string|array — ADDS to default `skills/`
  scan), `commands` (REPLACES default `commands/`), `agents`, `workflows`,
  `hooks` (string|array|object), `mcpServers` (string|array|object),
  `outputStyles`, `lspServers`, `experimental.themes`,
  `experimental.monitors`, `userConfig`, `channels`, `dependencies`
  (plugins-reference.md:519-535). All paths relative, must start with `./`.
- Unrecognized top-level fields: ignored at load; `claude plugin validate`
  reports them as warnings; wrong TYPES still fail (plugins-reference.md:
  468-483). Docs: "Pass `--strict` to treat warnings as errors"
  (plugins-reference.md:485) — **but `--strict` does not exist on installed
  2.1.126 (VERIFIED-LOCAL, §0)**.
- **Directory law** (plugins-reference.md:841): "The `.claude-plugin/`
  directory contains the `plugin.json` file. All other directories
  (commands/, agents/, skills/, workflows/, output-styles/, themes/,
  monitors/, hooks/) must be at the plugin root, not inside `.claude-plugin/`."
- "A `CLAUDE.md` file at the plugin root is not loaded as project context"
  (plugins-reference.md:845).
- Default file locations (plugins-reference.md:849-863): Manifest
  `.claude-plugin/plugin.json`; Skills `skills/`; Commands `commands/`
  ("Skills as flat Markdown files. Use `skills/` for new plugins"); Agents
  `agents/`; Hooks `hooks/hooks.json`; MCP `.mcp.json`; LSP `.lsp.json`;
  Monitors `monitors/monitors.json`; Executables `bin/` ("added to the Bash
  tool's PATH … invokable as bare commands … while the plugin is enabled");
  Settings `settings.json` ("Only the `agent` and `subagentStatusLine` keys
  are currently supported").
- Versioning: version is the update cache key; bump it or omit it (commit-SHA
  versioning) (plugins-reference.md:1267-1291).

---

## 4. Skills vs commands

- Both live in the plugin: `skills/<name>/SKILL.md` (directories, can bundle
  supporting files) or `commands/*.md` (flat markdown files). "Skills are
  directories with `SKILL.md`; commands are simple markdown files"
  (plugins-reference.md:25). Commands are legacy-flavored: "Use `skills/` for
  new plugins" (plugins-reference.md:853). A lone `SKILL.md` at plugin root =
  single-skill plugin (≥2.1.142).
- **Namespacing**: plugin skill command = `/plugin-name:skill-name`
  (skills.md:281: `my-plugin/skills/review/SKILL.md` → `/my-plugin:review`).
  "The bare `/fancy` also invokes the skill unless another command already
  uses that name" (skills.md:284). **Version gotcha: "Before v2.1.216, the
  frontmatter name replaced the whole command name, so the menu showed
  `/fancy` without the plugin prefix" — on installed 2.1.126, do NOT set a
  frontmatter `name` that differs from the directory name.**
- **Frontmatter fields** (skills.md:250-268, all optional): `name`,
  `description` (recommended; with `when_to_use` truncated at 1,536 chars in
  listing), `when_to_use`, `argument-hint` (autocomplete hint, e.g.
  `[issue-number]`), `arguments` (named positional args), 
  `disable-model-invocation` (true = manual `/name` only; not preloaded into
  subagents), `user-invocable` (false = hide from `/` menu), `allowed-tools`
  (turn-scoped pre-approval), `disallowed-tools`, `model`, `effort`,
  `context: fork` + `agent` + `background`, `hooks` (component-scoped),
  `paths`, `shell`.
  Booleans: `true`/`false` only on 2.1.126 (yes/no/on/off/1/0 need ≥2.1.218;
  plugins-reference.md:47).
- **String substitutions in skill/command content** (skills.md:288-325):
  `$ARGUMENTS` (all args; if absent from content, args appended as
  `ARGUMENTS: <value>`), `$ARGUMENTS[N]`, `$N` shorthand, `$name` (from
  `arguments` frontmatter), `${CLAUDE_SESSION_ID}`, `${CLAUDE_EFFORT}`,
  `${CLAUDE_SKILL_DIR}` (the skill's own dir; in `allowed-tools` needs
  ≥2.1.129), `${CLAUDE_PROJECT_DIR}` (in skills needs ≥2.1.196 — **NOT
  substituted in skill content on installed 2.1.126**). Plugin skills also
  substitute `${CLAUDE_PLUGIN_ROOT}`/`${CLAUDE_PLUGIN_DATA}` "anywhere the
  placeholder appears" (plugins-reference.md:679-680).
  **So yes: `$ARGUMENTS` interpolation exists, for `commands/*.md` files and
  `SKILL.md` alike (commands are flat-file skills).**
- Skill invocation loads content into context and it persists for the session
  (skills.md:401-409); `allowed-tools` grant clears next message.
- Live change detection: SKILL.md edits apply immediately; hooks/.mcp.json/
  agents changes need `/reload-plugins` or restart (plugins-reference.md:405).

---

## 5. user_config (`userConfig`)

- Declared in **plugin.json** under `userConfig`; "values that Claude Code
  prompts the user for when the plugin is enabled"
  (plugins-reference.md:543-560). Per-option fields: `type` (string|number|
  boolean|directory|file, required), `title` (required), `description`
  (required), `sensitive`, `required`, `default`, `multiple`, `min`/`max`.
- Substitution (plugins-reference.md:576): "Each value is available for
  substitution as `${user_config.KEY}` in MCP and LSP server configs and hook
  commands. Non-sensitive values can also be substituted in skill and agent
  content. **All values are exported to hook processes as
  `CLAUDE_PLUGIN_OPTION_<KEY>` environment variables, where `<KEY>` is the
  option key uppercased.**"
- Shell-safety rule (plugins-reference.md:578-586, hooks.md:404-406): fields
  that run in a shell REJECT `${user_config.*}` (the component errors instead
  of substituting). Shell-form hook commands → "Use exec form with `args`, or
  read `CLAUDE_PLUGIN_OPTION_<KEY>` from the hook's environment." Monitor
  commands → read from a config file. (Behavior since 2.1.207; before that,
  shell-form substituted. Installed 2.1.126 predates 2.1.207 —
  **UNVERIFIED which behavior 2.1.126 has; avoid `${user_config.*}` in
  shell-form commands regardless.**)
- Storage: non-sensitive → `pluginConfigs[<plugin-id>].options` in user
  `settings.json`; sensitive → macOS Keychain (~2 KB total shared limit) or
  `~/.claude/.credentials.json` (plugins-reference.md:588-590).
- `pluginConfigs` is read ONLY from user settings, `--settings`, and managed
  settings — project/local `.claude/settings*.json` entries are ignored
  (≥2.1.207) (plugins-reference.md:592-600).
- CLI: `claude plugin install <plugin> --config key=value` (repeatable)
  (plugins-reference.md:942).
- SPEC-01's `capture_commands: false` switch maps cleanly to a
  `userConfig` boolean read via `CLAUDE_PLUGIN_OPTION_CAPTURE_COMMANDS`.

---

## 6. Statusline

### 6.1 settings.json schema (statusline.md:44-71)

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/statusline.sh",
    "padding": 2,              // optional, default 0
    "refreshInterval": 5,      // optional, seconds, min 1; else event-driven only
    "hideVimModeIndicator": true // optional
  }
}
```

Goes in user settings (`~/.claude/settings.json`) or project settings.
`/statusline` command generates one. Script gets JSON on stdin, prints text
to stdout; runs on session start, new assistant message, `/compact` end,
permission-mode change, vim toggle, and `refreshInterval` ticks; 300 ms
debounce; in-flight script cancelled on new update (statusline.md:135-165).
Requires workspace trust; disabled by `disableAllHooks: true`
(statusline.md:1054, 1097-1100).

### 6.2 Full stdin JSON schema (statusline.md:167-339 — exact field names)

Top-level: `cwd`, `session_id`, `session_name` (may be absent), `prompt_id`
(≥2.1.196, absent until first input), `transcript_path`, `version`,
`exceeds_200k_tokens`, `fast_mode`, plus objects:

- `model`: `id`, `display_name`
- `workspace`: `current_dir`, `project_dir`, `added_dirs` (array),
  `git_worktree` (absent outside linked worktree), `repo` (`host`, `owner`,
  `name`; absent without an `origin` remote)
- `cost`: **`total_cost_usd`** (client-side estimate; resets to $0 on `/clear`
  ≥2.1.211), **`total_duration_ms`** (present — wall-clock since session
  start), `total_api_duration_ms`, **`total_lines_added`**,
  **`total_lines_removed`**
- `context_window`: `total_input_tokens`, `total_output_tokens` (current
  context, ≥2.1.132; before that cumulative — **installed 2.1.126 = cumulative
  session totals**), `context_window_size` (200000 or 1000000),
  `used_percentage` (input-only formula; may be null early),
  `remaining_percentage`, `current_usage` (`input_tokens`, `output_tokens`,
  `cache_creation_input_tokens`, `cache_read_input_tokens`; null before first
  API call and right after `/compact`)
- `effort`: `level` (low|medium|high|xhigh|max; absent if unsupported)
- `thinking`: `enabled`
- **`rate_limits`**: windows are **`five_hour`** and **`seven_day`** (NOT
  "weekly"), each with **`used_percentage`** (0–100) and **`resets_at`**
  ("Unix epoch seconds when the … rate limit window resets").
  Availability caveat (statusline.md:309): "`rate_limits`: appears only for
  Claude.ai subscribers (Pro/Max) after the first API response in the
  session. Each window (`five_hour`, `seven_day`) may be independently
  absent."
- `output_style`: `name`; `vim`: `mode`; `agent`: `name`; `pr`: `number`,
  `url`, `review_state`; `worktree`: `name`, `path`, `branch`,
  `original_cwd`, `original_branch`.

### 6.3 Can a plugin contribute a statusline without editing user settings?

**NO for the main statusline.** Grep of both plugin dumps: the ONLY statusline
mention in plugin context is plugin `settings.json`, and (plugins.md:296)
"Currently, only the `agent` and `subagentStatusLine` keys are supported."
(same at plugins-reference.md:863). "Unknown keys are silently ignored"
(plugins.md:306) — so shipping `statusLine` in plugin settings.json is
silently dropped, not an error.
**YES for the subagent panel only**: "Plugins can ship a default
`subagentStatusLine` in their settings.json" (statusline.md:1036).
`subagentStatusLine` receives one JSON object per refresh tick with base hook
fields + `columns` + `tasks[]` (`id`, `name`, `type`, `status`, `description`,
`label`, `startTime`, `model` ≥2.1.205, `effort` ≥2.1.214,
`contextWindowSize` ≥2.1.205, `tokenCount`, `tokenSamples`, `cwd`), and emits
`{"id": "...", "content": "..."}` lines (statusline.md:1015-1036).
**v0.4 consequence: the plugin ships a statusline SCRIPT + an installer step
(skill or documented `/statusline` usage) that writes the user's
`settings.json`; it cannot auto-activate the main statusline.**

---

## 7. Local dev loop (all VERIFIED-LOCAL unless cited)

- `claude --plugin-dir ./agent-session-supervisor` — works on 2.1.126;
  repeatable; plugin loaded in place; local copy takes precedence over a
  same-named installed plugin (plugins.md:330). `.zip` support needs ≥2.1.128
  (plugins.md:322) — **not available locally**. `--plugin-url` exists in docs
  (plugins-reference.md:761); presence on 2.1.126 UNVERIFIED.
- `/reload-plugins` reloads "plugins, skills, agents, hooks, plugin MCP
  servers, and plugin LSP servers" without restart (plugins.md:332).
- `claude plugin validate ./path` — validates "plugin.json, skill/agent/
  command frontmatter, and hooks/hooks.json for syntax and schema errors"
  (plugins-reference.md:1191). **No `--strict` on 2.1.126** (error: unknown
  option). Warnings don't fail validation.
- Debugging: `claude --debug` shows plugin loading, hook registration; hook
  execution details in `~/.claude/debug/<session-id>.txt`; `claude
  --debug-file <path>` (hooks.md:3148-3150).
- `claude plugin list --json`; `claude plugin details <name>` (component
  inventory + token cost estimate; hooks are "harness-only — no model context
  cost", plugins-reference.md:1131).
- `--plugin-dir` sessions: flag is NOT restored on resume — "If the session
  depended on `--mcp-config`, `--settings`, `--plugin-dir` … pass them again
  when you resume" (sessions.md:38). **v0.3 resume command for a dev-mode
  session must re-pass `--plugin-dir`.**
- Resume interfaces (sessions.md:15-25): `claude --continue`,
  `claude --resume <name|session-id>`, `claude -p --resume <session-id>
  "prompt"` (headless follow-up; session-ID lookup is scoped to the project
  directory it was started in).
- Headless mode: SessionStart hooks fire under `-p` (VERIFIED-LOCAL §0).

---

## 8. Other facts that materially affect this build

- **Monitors** (plugins-reference.md:287-335): experimental;
  `monitors/monitors.json` array with required `name`, `command`,
  `description`; optional `when`: `"always"` (default) or
  `"on-skill-invoke:<skill-name>"`. "They run only in interactive CLI
  sessions"; stdout lines delivered to Claude as notifications; disabling the
  plugin mid-session doesn't stop running monitors; no `${user_config.*}` in
  monitor commands. Could serve the v0.5 cache-warm idle watcher, but
  interactive-only.
- **Marketplaces**: community catalog lives at
  `anthropics/claude-plugins-community` `.claude-plugin/marketplace.json`;
  submission via Console form; `claude plugin marketplace add
  anthropics/claude-plugins-official` (plugins.md:375-397). Full
  marketplace.json schema is in the plugin-marketplaces doc (NOT dumped —
  fetch if/when shipping a marketplace; v0.1–0.4 uses `--plugin-dir`).
- **Transcript instability** (sessions.md:177): "The entry format is internal
  to Claude Code and changes between versions, so scripts that parse these
  files directly can break on any release." Confirms README risk #2 /
  SPEC-01's "Do not parse transcript_path".
- Transcript location: `~/.claude/projects/<project>/<session-id>.jsonl`
  where `<project>` = cwd path with non-alphanumerics → `-` (sessions.md:177;
  matches VERIFIED-LOCAL stdin dump).
- **Hook events beyond SPEC-01 worth knowing**: `PostToolBatch` (once per
  parallel batch, `tool_calls[]` array — an alternative to per-tool capture),
  `PreCompact`/`PostCompact`, `UserPromptSubmit`, `Setup` (only with
  `--init-only` / `-p --init` / `-p --maintenance` — one-time prep),
  `TaskCreated`/`TaskCompleted`, `TeammateIdle`, `FileChanged` (+
  SessionStart `watchPaths`), `CwdChanged`, `Notification` (matchers incl
  `idle_prompt`, `permission_prompt`).
- Plugin-bundled MCP tools get scoped names
  `mcp__plugin_<plugin-name>_<server-name>__<tool>`; `mcp_tool` hook `server`
  field takes `plugin:<plugin-name>:<server-name>` (plugins-reference.md:156).
- Skills-directory plugins: `~/.claude/skills/<name>/.claude-plugin/
  plugin.json` loads as `<name>@skills-dir`, discovered in place, no install
  (plugins-reference.md:373-411). Alternative dev path; `plugin init`
  scaffolds there — but `plugin init` is absent on 2.1.126.
- Plugin agents: frontmatter supports `name`, `description`, `model`,
  `effort`, `maxTurns`, `tools`, `disallowedTools`, `skills`, `memory`,
  `background`, `isolation` ("worktree" only); `hooks`, `mcpServers`,
  `permissionMode` NOT supported for plugin agents (plugins-reference.md:74).
- `SessionStart` + `Setup` MCP-tool hooks: servers usually not connected yet
  (hooks.md:463) — use command hooks there.
- Version-skew summary (docs describe current CLI; installed is 2.1.126):
  features requiring newer than 2.1.126 include `--strict` (validate),
  `plugin init`, `--plugin-dir` .zip (2.1.128), `${CLAUDE_SKILL_DIR}` in
  allowed-tools (2.1.129), context_window current-vs-cumulative semantics
  (2.1.132), `displayName` (2.1.143), Stop `background_tasks`/`session_crons`
  (2.1.145), `COLUMNS`/`LINES` for statusline (2.1.153), `defaultEnabled`
  (2.1.154), comma matchers (2.1.191), hyphen exact-matchers (2.1.195),
  `prompt_id` + `${CLAUDE_PROJECT_DIR}` in skills (2.1.196), exit-2 stderr
  visibility for SessionStart (2.1.199), skill re-invocation dedup (2.1.202),
  `userConfig` shell rejection semantics (2.1.207), `fork` source (2.1.214),
  plugin-skill name prefix fix (2.1.216), boolean frontmatter variants
  (2.1.218). **Design to the 2.1.126 floor; treat doc-only features as
  progressive enhancement.**

---

## 9. Corrections to SPEC-01 / README (verified contradictions)

1. **SPEC-01 acceptance criterion 8** (`claude plugin validate
   ./agent-session-supervisor --strict`): `--strict` does not exist on the
   installed CLI 2.1.126 (`error: unknown option '--strict'`). Docs document
   it for newer CLIs. Criterion must become: passes `claude plugin validate
   ./agent-session-supervisor` with zero errors (ideally zero warnings, which
   is what `--strict` would enforce on newer CLIs).
2. **README.md:59 & SPEC-01:84** "the data dir survives updates and
   uninstalls": FALSE for uninstalls. Uninstalling from the last scope
   deletes `${CLAUDE_PLUGIN_DATA}` by default; only `--keep-data` preserves
   it (plugins-reference.md:753; CLI help VERIFIED-LOCAL).
3. **SPEC-01:182 & SOURCES.md:115** claim hook stdin provides `tool_output`
   and `tool_error`. Real field names: PostToolUse provides **`tool_response`**
   (+ `tool_use_id`, `duration_ms`); PostToolUseFailure provides **`error`**
   (+ `is_interrupt`, `duration_ms`). No `tool_output`, no `tool_error`.
4. **SPEC-01 hooks.json `SessionEnd … "timeout": 20`**: a plugin hook's
   timeout does NOT raise the SessionEnd budget — "Timeouts set on
   plugin-provided hooks don't raise the budget" (default 1.5 s;
   settings-file hooks can raise to 60 s; `CLAUDE_CODE_SESSIONEND_HOOKS_
   TIMEOUT_MS` overrides). Digest generation must fit ~1.5 s or move earlier
   (incremental at capture/Stop time).
5. **SPEC-01 event format `"exit":1`** for Bash failures: hook payloads carry
   no numeric exit code; PostToolUseFailure gives an `error` STRING (e.g.
   "Command exited with non-zero status code 1"). Parse N from that string or
   store pass/fail; red→green tracking still works (PostToolUse=pass,
   PostToolUseFailure=fail per command string).
6. **README v0.3 "Read `rate_limits.*.resets_at` to schedule"**: `resets_at`
   exists ONLY in statusline stdin (`rate_limits.five_hour.resets_at`,
   `rate_limits.seven_day.resets_at`, epoch seconds, Pro/Max only, absent
   until first API response). The StopFailure payload has NO reset time, and
   a plugin cannot install a main statusline (only `agent` +
   `subagentStatusLine` keys work in plugin settings.json). v0.3 needs an
   alternative source (user-installed statusline caching `resets_at`,
   parsing `error_details` — UNVERIFIED, or polling/backoff).
7. **SPEC-01/README skill names `/supervisor:recap` etc.**: the namespace is
   the plugin `name`. With `name: agent-session-supervisor` the command is
   `/agent-session-supervisor:recap`. To get `/supervisor:recap`, the plugin
   must be named `supervisor`. Also: on 2.1.126 do not set a skill
   frontmatter `name` differing from its directory name (pre-2.1.216 it
   replaces the WHOLE command and drops the plugin prefix).
8. **SPEC-01 matcher `startup|resume` for SessionStart**: valid, but the full
   matcher set is `startup`, `resume`, `clear`, `compact`, `fork` — with
   `startup|resume` the digest will NOT re-inject after `/clear` (and `fork`
   reports `resume` on 2.1.126). Decide intentionally.
9. **SOURCES.md:117** "Hook output can return … `decision`/`reason`,
   `continue`/`stopReason`": true generally, but NOT for the events SPEC-01
   uses them with — StopFailure ignores ALL output and exit codes; SessionEnd
   and SubagentStart have no decision control; SessionStart cannot block.
10. **README §capability table "Statusline receives …
    `total_lines_added/removed`"**: correct fields are
    `cost.total_lines_added` / `cost.total_lines_removed` (under `cost`), and
    the second rate-limit window is `seven_day`, not "weekly".

---

## 10. Open risks / UNVERIFIED items

1. **Auth expired on this machine** — any end-to-end test that needs a model
   response (`-p` runs, PostToolUse firing from real tool calls, Stop hooks)
   will 401 until the user re-authenticates (`claude` → login). Hook firing
   itself was verified without auth (SessionStart only).
2. Whether StopFailure `error_details` ever includes a rate-limit reset time:
   UNVERIFIED (docs show only `"429 Too Many Requests"`). Do not depend on it.
3. SessionEnd firing on crash / SIGKILL / terminal close: UNVERIFIED (docs
   list reasons `clear|resume|logout|prompt_input_exit|
   bypass_permissions_disabled|other`). Build the digest idempotently so a
   missed SessionEnd only delays, never corrupts.
4. `userConfig` prompting/behavior on 2.1.126 (feature-set predates several
   documented changes, e.g. 2.1.207 shell-rejection): UNVERIFIED locally.
   Read `CLAUDE_PLUGIN_OPTION_<KEY>` env vars defensively with defaults.
5. `--plugin-url` presence on 2.1.126: UNVERIFIED (not needed for this build).
6. Dev-vs-installed data split: `<name>-inline` vs `<name>-<marketplace>`
   data dirs mean recorder state won't carry from `--plugin-dir` testing to a
   marketplace install. Acceptable for tests; document it.
7. macOS default bash is 3.2 — all shipped shell scripts must be bash-3.2
   compatible (or target `python3`/`jq`, both present).
