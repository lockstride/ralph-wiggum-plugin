# ralph-wiggum-plugin

A CLI-agnostic Ralph autonomous-development loop. Drives either the [Claude Code](https://docs.claude.com/en/docs/claude-code) (`claude`) or [Cursor](https://cursor.com) (`cursor-agent`) headless CLI from a terminal, with token accounting, context rotation, gate-run verification, guard hooks, retry/backoff, and Spec Kit integration.

> "That's the beauty of Ralph — the technique is deterministically bad in an undeterministic world." — Geoffrey Huntley

## What it is

The Ralph loop is a **shell script you run in a terminal**. It spawns the agent CLI as a subprocess, reads its stream-json output, tracks tokens, rotates context when the window fills, and keeps going until the task is done or the safety cap on agent respawns is reached. The loop is editor-agnostic: the editor you have open is irrelevant.

A healthy ralph **loop** runs as one continuous agent process — it commits as it goes and keeps moving until a real stop condition fires. It only respawns the agent (looping) on hard signals: context-window pressure, consecutive gate failures, or a rate-limit backoff. Looping is fine when needed but flow is much better — a single small spec usually completes in one loop.

The Claude Code plugin wrapping (slash commands, plugin manifest, and specialist skills) is a Claude Code-only enrichment. **For Claude Code users, install as a plugin** — it unlocks the acceptance-evaluation skills (`running-acceptance-evaluation`, `verifying-acceptance-criteria`, `addressing-acceptance-gaps`) and the guard hook that enforces gate discipline. Standalone-script users still get the full loop infrastructure but without those extras.

## ⚠️ Blast radius

Ralph runs the agent **with all tool approvals pre-granted** — `--dangerously-skip-permissions` for `claude`, `--force` for `cursor-agent`. This is intentional: the loop runs unattended and cannot pause for permission prompts.

**Consequences:**
- Run **only in a dedicated worktree** with a clean git state.
- **Never** run against a repo holding uncommitted work you care about.
- Prefer a fresh branch; the loop will commit on whatever branch is checked out.
- Sandboxing comes from your worktree isolation, not from per-tool approval.

There is no flag to disable YOLO mode. That's the point of Ralph.

## Get started

### Prerequisites

- **git**
- **jq** (`brew install jq` on macOS, `apt-get install jq` on Debian)
- **At least one agent CLI**:
  - `claude`: `npm install -g @anthropic-ai/claude-code`, then `claude login`
  - `cursor-agent`: `curl https://cursor.com/install -fsS | bash`
- **gum** (optional, nicer interactive UI): `brew install gum`

### Install

#### Recommended (Claude Code users) — install as a plugin

Unlocks slash commands, specialist skills, and the guard hook (blocks direct test-tool invocations, enforces gate-run.sh discipline).

```
/plugin marketplace add lockstride/claude-marketplace
/plugin install ralph-wiggum-plugin@lockstride-marketplace
```

Then from your project worktree:

```
ralph
```

#### Fallback (other CLIs / no plugin support) — standalone scripts

You get the full loop infrastructure, but the agent runs without the specialist skills. Functional, just less resilient on hard tasks.

```
# Option A: install.sh (drops scripts into .claude/ralph-{scripts,templates}/)
curl -fsSL https://raw.githubusercontent.com/lockstride/ralph-wiggum-plugin/main/install.sh | bash

# Option B: git clone
git clone https://github.com/lockstride/ralph-wiggum-plugin.git ~/ralph-wiggum-plugin
~/ralph-wiggum-plugin/shared-scripts/ralph-setup.sh /path/to/your/repo
```

### Smoke test a single loop

```
ralph-once --cli claude --spec
```

## Usage

### Interactive launcher

```
ralph
```

Walks you through:
1. CLI (`claude` or `cursor-agent`)
2. Model
3. Prompt source (`PROMPT.md` / custom file / Spec Kit spec dir)
4. Max loops (safety cap; 1 is the expected number for a well-flowing run)

### Scripted / unattended

All interactive prompts are skipped when the corresponding flag is present:

```
# Drive Claude Code against the newest spec, 30 iters
ralph --cli claude -m opus --spec -n 30

# Drive Cursor against a specific prompt file
ralph --cli cursor-agent --prompt-file PROMPT.md

# Drive Claude against a named spec, with a branch and PR
ralph --cli claude --spec 20260131-example-feature --branch feature/example --pr
```

### Flags

| Flag | What it does | If omitted |
|---|---|---|
| `--cli <claude\|cursor-agent>` | Which agent CLI to drive | interactive picker (pre-selects `claude`) |
| `-m, --model <id>` | Model name | interactive picker (pre-selects `opus` for Claude, `composer-2` for Cursor) |
| `-n, --loops N` | Max loops (safety cap; `--iterations` is the deprecated alias) | interactive picker (pre-fills `20`) |
| `--branch <name>` | Work on a named branch | current branch |
| `--pr` | Open a PR when complete; requires `--branch` | off |
| `--evaluate` | Chain acceptance evaluation loop after main loop completes (env: `RALPH_CHAIN_EVALUATE=1`) | off |
| `--eval-loops N` | Cap for the chained eval loop (`--eval-iterations` is the deprecated alias; env: `RALPH_EVAL_MAX_LOOPS`) | 10 |
| `-v, --version` | Print version and exit | — |
| `-h, --help` | Show help | — |

**Prompt source** — mutually exclusive, pick at most one:

| Flag | Behavior |
|---|---|
| *(none)* | Interactive picker prompts you to choose |
| `--prompt` | Uses `PROMPT.md` at the workspace root |
| `--prompt-file <path>` | Uses the file at `<path>` |
| `--spec` | Uses the most recent Spec Kit spec dir by mtime |
| `--spec <name>` | Uses the named Spec Kit spec dir |

### What runs in your repo

After the loop starts, Ralph writes to `.ralph/` (git-ignored automatically):

- `progress.md` — human-readable session log
- `guardrails.md` — lessons learned from past failures (the agent reads this)
- `errors.log` — failures detected by the stream parser
- `activity.log` — real-time token usage + tool calls
- `effective-prompt.md` — the rendered prompt fed to the agent at each loop start
- `handoff.md` — rolling state document, injected into the framing prompt every loop (see [Handoff state](#handoff-state) below)
- `gates/` — per-label logs, exit breadcrumbs, summary files, lock dirs for gate-run.sh

**Breadcrumb files** (optional, placed in `.ralph/` to configure behavior):

| File | Purpose |
|---|---|
| `basic-check-command` | Override the basic gate command (default: `pnpm basic-check`) |
| `final-check-command` | Override the final gate command (default: `pnpm all-check`) |
| `command-policy` | Unified rewrite/deny/protect rules — see [Command policy](#command-policy) below |
| `denied-commands` | *(deprecated, prefer `command-policy`)* Commands to block outright, `command\|reason` per line |
| `protected-scripts` | *(deprecated, prefer `command-policy`)* Commands that must not be piped/redirected, one prefix per line |
| `push-policy` | Push behavior: `never` (default), `completion-only` |
| `stop-requested` | Touch this file to signal the agent to stop after the current task |

Your commits are your durable memory. Ralph commits frequently during each loop so any involuntary kill is recoverable from the last commit.

### Handoff state

`.ralph/handoff.md` is a rolling state document the framing prompt injects at the start of every loop. It has two sections:

- **`## Last gate state`** — owned by the plugin. `gate-run.sh` writes a structured summary to `.ralph/gates/<label>-latest.summary` on every failed gate (parsed failure signatures + optional `coverage_gaps` block), and `stream-parser` rewrites this section on every gate-end. Do not edit it from the agent.
- **`## Working set`** — owned by the agent. Update this before yielding the turn — current task, files in flight, next planned step. The plugin emits a soft `Stop`-hook reminder when this section isn't refreshed during a loop.

A skeleton is seeded automatically by `init_ralph_dir` on first run.

### Command policy

`.ralph/command-policy` consolidates the rewrite / deny / gate-wrapped / protect rules into one file. Four sections, scanned in order: `[rewrite]` → `[deny]` → `[gate-wrapped]` → `[protect]`.

```
[rewrite]
# regex | replacement | reason  (backrefs \1, \2, … supported in replacement)
^pnpm -w run (.+)$ | pnpm \1 | this repo's package.json has no -w workspace flag

[deny]
# command-prefix | reason
pnpm test-e2e | containerized E2E is too expensive — use pnpm test-e2e:local

[gate-wrapped]
# MUST be invoked through gate-run.sh so the loop captures tracking artifacts
pnpm all-check
pnpm basic-check

[protect]
# bare OK, pipe/redirect denied
pnpm format:write
```

Section semantics:

- **`[rewrite]`** — regex match; blocks and tells the agent the canonical form via substitution. Use to retrain the agent on incorrect command shapes.
- **`[deny]`** — literal prefix match; blocks outright. Use for commands the agent should never run.
- **`[gate-wrapped]`** — listed command MUST be invoked through `gate-run.sh`, else blocked. The matcher strips env-var prefixes AND normalizes `pnpm run X` / `pnpm exec X` to `pnpm X` before prefix matching, so the agent can't slip past with `CI=true pnpm run all-check` or similar. Bare, piped, redirected, env-prefixed, and run/exec-prefixed forms are all caught. Use for the gates whose tracking the loop depends on (final / basic / test gates).
- **`[protect]`** — bare invocation OK; only pipe / redirect of the command is denied. Use for commands you want to allow bare but not let the agent dump into a sidecar log. Prefer `[gate-wrapped]` when you also want the loop's tracking artifacts.

The legacy `.ralph/denied-commands` + `.ralph/protected-scripts` are still read as a fallback when `command-policy` is absent (with a one-time deprecation notice in `.ralph/errors.log`); they only get `[deny]` + `[protect]` semantics — `[rewrite]` and `[gate-wrapped]` require the unified file. Migrate when convenient — the template at [`shared-references/templates/command-policy.md`](shared-references/templates/command-policy.md) is a starting point.

### Guard hook

When installed as a Claude Code plugin, Ralph registers a `PreToolUse` hook (`ralph-guard.sh`) that intercepts Bash and Write tool calls to enforce discipline:

- **Direct test-tool denial** — blocks `vitest`, `jest`, `cypress`, `tsc --noEmit` and their `npx`/`pnpm`/`pnpm exec` variants unless wrapped in `gate-run.sh`.
- **Command-policy enforcement** — rewrite/deny/protect from `.ralph/command-policy` (see above).
- **Gate-without-write detection** — blocks re-running a gate when no file has been written since the last gate, preventing pointless reruns.
- **State-file protection** — prevents the agent from tampering with `.ralph/gates/`, `.ralph/activity.log`, and other loop-owned state.

A `Stop` hook (`handoff-check.sh`) emits a soft reminder when the `## Working set` section of `handoff.md` wasn't updated during the loop. Advisory only — does not block the agent from yielding.

### Rotation signals

The stream parser emits signals that the main loop uses to decide when to rotate (kill the agent and respawn with fresh context):

| Signal | Trigger | Effect |
|---|---|---|
| `ROTATE` | Token usage exceeds threshold | Hard rotation — context window is full |
| `TURN_END` | 5 consecutive gate failures (configurable via `RALPH_GATE_FAIL_STREAK_THRESHOLD`) | Rotation; next loop reads the freshly-written handoff block |
| `WARN` | Approaching token threshold | Agent told to wrap up |
| `GUTTER` | Stuck pattern (repeated failures, file thrashing) or agent self-signal | Rotation with diagnostic context |
| `COMPLETE` | Agent emits `<promise>ALL_TASKS_DONE</promise>` | Loop exits successfully |
| `DEFER` | Rate limit or transient API error | Backoff and retry |

## Spec Kit mode

If you use [Spec Kit](https://github.com/github/spec-kit), pick `--spec` and Ralph will:

1. Find the most-recent `specs/*` dir by mtime (or the one you name).
2. **Generate a loop-adapted prompt** from your project's `speckit-implement` skill (`.claude/skills/speckit-implement/SKILL.md`, with hash-based caching) — keeps the loop in sync with your version of Spec Kit. Falls back to the built-in template if the skill doesn't exist.
3. Substitute `{{SPEC_DIR}}`, `{{CONSTITUTION_PATH}}`, `{{TASK_FILE}}`, `{{PLAN_FILE}}`, `{{SPEC_FILE}}`, gate commands, and the recent activity-log tail into the prompt.
4. Enforce one-task-per-commit, gate-discipline, and the `<promise>ALL_TASKS_DONE</promise>` completion sigil (verified against the real checkbox state — no hallucinated promises).

Default check commands: `pnpm basic-check` (basic gate) and `pnpm all-check` (final gate). Override via `.ralph/basic-check-command` and `.ralph/final-check-command` breadcrumbs.

For prompt-generation internals, see [docs/development.md → Prompt generation deep details](docs/development.md#prompt-generation-deep-details).

## Acceptance evaluation loop

When the main Ralph loop exits `COMPLETE`, all it has confirmed is that the agent checked every `[ ]` and the final gate was green. That's a self-assessment. The **acceptance evaluation loop** is a second Ralph loop that runs after the first one, with an independent verifier-vs-rework orchestrator pattern, to catch what the main loop missed.

```
# Standalone
ralph-evaluate --prompt          # against PROMPT.md
ralph-evaluate --spec            # against newest spec dir
ralph-evaluate --prompt --fresh  # wipe prior report

# Chain after a main loop
ralph --cli claude --spec --evaluate --eval-loops 10
```

For mode mechanics, artifacts, and limitations, see [docs/development.md → Acceptance evaluation loop](docs/development.md#acceptance-evaluation-loop--internals).

## Environment variables

| Variable | Default | Purpose |
|---|---|---|
| `RALPH_GATE_TIMEOUT` | — | Override all gate timeouts (seconds) |
| `RALPH_BASIC_GATE_TIMEOUT` | `1200` | Basic gate timeout |
| `RALPH_FINAL_GATE_TIMEOUT` | `1200` | Final gate timeout |
| `RALPH_GATE_KILL_GRACE` | `10` | Seconds between SIGTERM and SIGKILL on timeout |
| `RALPH_GATE_KEEP` | `5` | Number of timestamped gate logs to retain per label |
| `RALPH_GATE_LOCK_WAIT` | `300` | Seconds to wait for a gate lock before giving up |
| `RALPH_GATE_STALE_LOCK_SEC` | `600` | Steal locks older than this (seconds) |
| `RALPH_GATE_FAIL_STREAK_THRESHOLD` | `5` | Consecutive gate failures before TURN_END |
| `RALPH_MAX_LOOPS` | `10` | Safety cap on agent respawns |
| `RALPH_EVAL_MAX_LOOPS` | `10` | Safety cap on eval loop iterations |
| `RALPH_SKIP_GUARDRAILS` | — | Set to `1` to omit the guardrails preamble |
| `RALPH_SKIP_GENERATION` | — | Set to `1` to skip speckit prompt generation |

## Pointers

- **[`docs/gate-run.md`](docs/gate-run.md)** — full reference for the gate-runner wrapper (label enum, env vars, failure-pattern regex, agent protocol).
- **[`docs/skills.md`](docs/skills.md)** — operator reference for the specialist skills.
- **[`docs/development.md`](docs/development.md)** — internals for working on the plugin: tests, lint, watchdogs, signals, project layout.
- **[Geoffrey Huntley's Ralph technique](https://ghuntley.com)** — original concept.

## Credits

- [@agrimsingh](https://github.com/agrimsingh) for [`ralph-wiggum-cursor`](https://github.com/agrimsingh/ralph-wiggum-cursor) — the proven cursor-agent implementation this plugin ports (MIT).
- [Geoffrey Huntley](https://ghuntley.com) for the original Ralph technique.

## License

MIT. See `LICENSE`.
