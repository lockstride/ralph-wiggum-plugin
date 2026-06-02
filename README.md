# ralph-wiggum-plugin

A CLI-agnostic Ralph autonomous-development loop. Drives either the [Claude Code](https://docs.claude.com/en/docs/claude-code) (`claude`) or [Cursor](https://cursor.com) (`cursor-agent`) headless CLI from a terminal, with token accounting, context rotation, gate-run verification, guard hooks, retry/backoff, and Spec Kit integration.

> "That's the beauty of Ralph — the technique is deterministically bad in an undeterministic world." — Geoffrey Huntley

## What it is

The Ralph loop is a **shell script you run in a terminal**. It spawns the agent CLI as a subprocess, reads its stream-json output, tracks tokens, rotates context when the window fills, and keeps going until the task is done or the safety cap on agent respawns is reached. The loop is editor-agnostic: the editor you have open is irrelevant.

A healthy ralph **loop** runs as one continuous agent process — it commits as it goes and keeps moving until a real stop condition fires. It only respawns the agent (looping) on hard signals: context-window pressure, consecutive gate failures, or a rate-limit backoff. Looping is fine when needed but flow is much better — a single small spec usually completes in one loop.

The Claude Code plugin wrapping (slash commands, plugin manifest, and specialist skills) is a Claude Code-only enrichment. **For Claude Code users, install as a plugin** — it unlocks the acceptance-evaluation skills (`running-acceptance-evaluation`, `verifying-acceptance-criteria`, `addressing-acceptance-gaps`) and the guard hook that enforces gate discipline. Standalone-script users still get the full loop infrastructure but without those extras.

## Feature set

The plugin's intended behaviors, with where each is implemented. Use this as
the inventory when reviewing the loop's reliability end-to-end.

### Graceful context management & restarts
- Stream parser fires `WARN` at 87.5% of the token threshold (`stream-parser.sh:emit_warn_or_rotate`) and touches `.ralph/context-warning-active`.
- The framing prompt instructs the agent to check `context-warning-active` and `stop-requested` after every commit and yield with a handoff write if either is present.
- Loop detects 🤝 `GRACEFUL YIELD` when handoff.md was written this iteration (`_detect_graceful_yield` in `ralph-common.sh`) — distinguishes a good yield from a force-killed `ROTATE` / `TURN_END`.
- At 100% (`ROTATE_THRESHOLD`), the loop force-kills the agent. The next session reads the inlined handoff block from `build_prompt`.

### Stop-signal adherence
- Touch `.ralph/stop-requested` to ask the loop to halt. Agent honors at the next post-commit breadcrumb check.
- The loop's driver-side check (`run_ralph_loop`) honors `stop-requested` if the agent didn't yield voluntarily — distinguishing graceful from forced via the same `_detect_graceful_yield` helper.
- `stop-requested` honored → loop writes `.ralph/.loop-stopped-by-user` → `--evaluate` chain is **skipped** (operator intent is "halt", not "ready for verification").

### Script call filters & transparent rewrites
- `PreToolUse` hook (`ralph-guard.sh`) registered via `hooks/hooks.json` (record-keyed-by-event-name schema; the wrong-schema 0.12.4 bug is fixed in 0.12.5).
- `.ralph/command-policy` has five sections, evaluated in order: `[gates] → [rewrite] → [deny] → [wrap] → [protect]`.
  - `[gates]` — **required.** Declares the three tier-gate commands (`basic | <cmd>`, `full | <cmd>`, `final | <cmd>`). Loop refuses to start if any are missing.
  - `[rewrite]` — project-specific regex transforms (e.g. `pnpm nx X → pnpm X`). Transparent via `updatedInput`.
  - `[deny]` — hard block with `permissionDecision: deny` (e.g. containerized E2E).
  - `[wrap]` — auto-routes other commands through `gate-run.sh <label> <cmd>` transparently. Labels: `basic | full | final | unit | integration | e2e | lint | format`.
  - `[protect]` — bare invocation OK; pipe/redirect denied.
- Canonicalization (`_canonicalize` in `ralph-guard.sh`): env-prefix stripped, pipes/redirects stripped, `pnpm run X` / `pnpm exec X` normalized to `pnpm X`. Compound chains (`pnpm A && pnpm B`) split — if any segment matches `[wrap]`, the whole chain is rewrapped on just that segment.
- Activity-log emoji: 🔀 `GUARD REWRITE` on transparent rewrites, ⛔ `GUARD DENY` on hard blocks.

### Multi-consecutive gate checks without interleaving writes/edits
- `ralph-guard.sh`'s gate-without-write check blocks re-running a gate when no Write/Edit happened since the last gate (`LAST_WRITE_TS` vs `LAST_GATE_TS` in `$XDG_STATE_HOME/ralph/<workspace-hash>/`).
- Prevents the "run gate → read output → re-run gate for more output" anti-pattern that wastes minutes per loop.

### Gate-level adherence (three-tier model)
- Framing's `## Gate Selection` block interpolates the project's `[gates].basic` (per-task default) and `[gates].full` (on `[risky]` tasks and at end-of-loop). The `final` tier is reserved for the eval loop.
- `gate-run.sh` enforces 8 canonical labels (3 tier labels `basic | full | final` + 5 kind labels `unit | integration | e2e | lint | format`) and writes `<label>-latest.{log,exit,cmd,summary}` per label.
- Tier-command label-lock: each of the three `[gates]` commands must run under its own tier label. Running `[gates].full` under any other label is denied — closes the "relabel to escape the gate cache and fish for green" anti-pattern.
- Completion guard `_complete_allowed` refuses `<promise>ALL_TASKS_DONE</promise>` unless `full-latest.cmd` matches `[gates].full` AND `full-latest.exit` is 0.

### Smooth handoff between loops
- `.ralph/handoff.md` has three managed sections:
  - `## Working set` — written by the agent before yielding (current task, files in flight, next planned step). The framing reminds it; the Stop hook (`handoff-check.sh`) emits a soft warning if it's stale.
  - `## Last gate state` — rewritten by `stream-parser.sh` after every gate-end.
  - `## Auto-enriched state` — appended by the loop on `ROTATE` / `TURN_END` (last commit SHA + subject, last `[x]` task, next unchecked task). Mechanical carry-over even when the agent was force-killed.
- The next loop inlines the whole file via `build_prompt`'s `## Handoff from previous loop` block.

### Effective and reliable eval loop
- `--evaluate` chains an acceptance-evaluation loop after the main loop emits `ALL_TASKS_DONE`.
- `ralph-evaluate.sh` orchestrates two roles in alternation: `running-acceptance-evaluation` skill (orchestrator), which delegates to `verifying-acceptance-criteria` (VERIFIER role) or `addressing-acceptance-gaps` (REWORK role) via the `Task` tool.
- Drives `.ralph/acceptance-report.md` — checkbox state advances the loop. Verifier runs the project's `[gates].final` command under label `final` independently; rework loops fix logged gaps.

### Proper dynamic prompt generation
- `prompt-resolver.sh` reads the project's `speckit-implement` skill, applies the adaptation guide, and invokes `claude -p --model sonnet --effort low` to produce a loop-adapted body.
- Composite hash cache (`<sha(speckit)>:<sha(guide)>`) regenerates on either input change.
- Safety addendum (`_ensure_breadcrumb_checks`) auto-injects the breadcrumb-check paragraph if the generator paraphrased it away.
- Framing (`build_prompt`) owns Stop conditions, the after-commit flow, and the handoff contract — the body is purely task-execution mechanics.

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
| `-n, --loops N` | Max loops (safety cap) | interactive picker (pre-fills `20`) |
| `--branch <name>` | Work on a named branch | current branch |
| `--pr` | Open a PR when complete; requires `--branch` | off |
| `--evaluate` | Chain acceptance evaluation loop after main loop completes (env: `RALPH_CHAIN_EVALUATE=1`) | off |
| `--eval-loops N` | Cap for the chained eval loop (env: `RALPH_EVAL_MAX_LOOPS`) | 10 |
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

**Breadcrumb files** (placed in `.ralph/`):

| File | Required | Purpose |
|---|---|---|
| `command-policy` | **yes** | Single source of truth for gate tiers + routing — see [Command policy](#command-policy) below. The loop refuses to start without a `[gates]` section declaring all three of `basic`, `full`, `final`. |
| `push-policy` | no | Push behavior: `never` (default), `per-commit`, `per-3-commits`, `phase-close`, `completion-only` |
| `stop-requested` | no | Touch this file to signal the agent to stop after the current task |

Your commits are your durable memory. Ralph commits frequently during each loop so any involuntary kill is recoverable from the last commit.

### Handoff state

`.ralph/handoff.md` is a rolling state document the framing prompt injects at the start of every loop. It has two sections:

- **`## Last gate state`** — owned by the plugin. `gate-run.sh` writes a structured summary to `.ralph/gates/<label>-latest.summary` on every failed gate (parsed failure signatures + optional `coverage_gaps` block), and `stream-parser` rewrites this section on every gate-end. Do not edit it from the agent.
- **`## Working set`** — owned by the agent. Update this before yielding the turn — current task, files in flight, next planned step. The plugin emits a soft `Stop`-hook reminder when this section isn't refreshed during a loop.

A skeleton is seeded automatically by `init_ralph_dir` on first run.

### Command policy

`.ralph/command-policy` is the single source of truth: gate tiers + transparent rewrites + denials + free-form routing + pipe protection. Five sections, scanned in order: `[gates]` → `[rewrite]` → `[deny]` → `[wrap]` → `[protect]`.

```
[gates]
# REQUIRED — the three tier-gate commands. Loop refuses to start if any are missing.
# tier  | command
basic | pnpm basic-check
full  | pnpm all-check
final | pnpm all-check

[rewrite]
# regex | replacement | reason  (backrefs \1, \2, … supported in replacement)
^pnpm -w run (.+)$ | pnpm \1 | this repo's package.json has no -w workspace flag
^pnpm nx (.+)$     | pnpm \1 | pnpm nx bypasses [wrap] enforcement; use root pnpm scripts

[deny]
# command-prefix | reason
pnpm test-e2e | containerized E2E is too expensive — use pnpm test-e2e:local

[wrap]
# command-prefix | label   label ∈ basic | full | final | unit | integration | e2e | lint | format
pnpm test-unit       | unit
pnpm test-integration| integration
pnpm test-e2e:local  | e2e
pnpm lint            | lint

[protect]
# bare OK, pipe/redirect denied
pnpm format:write
```

Section semantics:

- **`[gates]`** — the project's three tier-gate commands, exactly one per tier. The framing prompt's `## Gate Selection` block, the completion guard `_complete_allowed`, and the tier-command label-lock all read this. No defaults — every project must declare its own.
- **`[rewrite]`** — regex match; transparently rewrites the agent's command via the hook's `updatedInput` mechanism (no block, no retry puzzle). Use for incorrect command shapes the agent reaches for.
- **`[deny]`** — literal prefix match; blocks outright with `permissionDecision: deny`. Use for commands the agent should never run (containerized E2E, destructive ops).
- **`[wrap]`** — free-form routing table for commands NOT in `[gates]`. Listed command is **transparently auto-rewritten** to its `gate-run.sh <label> <cmd>` form via `updatedInput`, so the loop captures tracking artifacts (latest.log / .exit / .cmd / .summary) without the agent having to remember the wrapper. The label drives the artifact namespace and timeout bucket. Missing/unrecognized label → row skipped. The matcher strips env-var prefixes AND normalizes `pnpm run X` / `pnpm exec X` to `pnpm X` before matching. Compound chains (`pnpm format:write && pnpm test-coverage`) split — if any segment matches, the chain is rewrapped on just that segment.
- **`[protect]`** — bare invocation OK; only pipe / redirect of the command is denied. Use for commands you want to allow bare but not let the agent dump into a sidecar log.

Activity-log feedback: 🔀 `GUARD REWRITE` is logged when `[rewrite]` or `[wrap]` fires; ⛔ `GUARD DENY` when `[deny]` or a state-tampering check fires. The template at [`shared-references/templates/command-policy.md`](shared-references/templates/command-policy.md) is a starting point for a new project's `command-policy`.

### Guard hook

When installed as a Claude Code plugin, Ralph registers a `PreToolUse` hook (`ralph-guard.sh`) that intercepts Bash and Write/Edit tool calls to enforce discipline:

- **Transparent rewrites** — `[rewrite]` regex transforms and `[wrap]` auto-routing through `gate-run.sh` happen via `updatedInput` (no block, no agent retry). Logged to `activity.log` as 🔀 `GUARD REWRITE`.
- **Hard denies** — state tampering (`rm -rf .ralph/`), direct test-tool invocations (`vitest`/`jest`/`cypress`/`tsc --noEmit` and their `pnpm exec` variants), `[deny]` rules. Logged as ⛔ `GUARD DENY`.
- **Gate-without-write detection** — blocks re-running a gate when no file has been written since the last gate.
- **State-file protection** — prevents the agent from tampering with `.ralph/gates/`, `.ralph/activity.log`, and other loop-owned state.

A `Stop` hook (`handoff-check.sh`) emits a soft reminder (`systemMessage` payload) when the `## Working set` section of `handoff.md` wasn't updated during the loop. Advisory only — does not block the agent from yielding.

### Rotation signals

The stream parser emits signals that the main loop uses to decide when to rotate (kill the agent and respawn with fresh context):

| Signal | Trigger | Effect |
|---|---|---|
| `ROTATE` | Token usage ≥ `ROTATE_THRESHOLD` | Hard rotation — agent killed mid-task |
| `WARN` | Tokens ≥ `WARN_THRESHOLD` (87.5%) | Touches `.ralph/context-warning-active`; agent is supposed to yield at next post-commit check |
| `TURN_END` | 5 consecutive gate failures (configurable via `RALPH_GATE_FAIL_STREAK_THRESHOLD`) | Rotation; next loop reads the freshly-written handoff block |
| `GUTTER` | Stuck pattern (repeated failures, file thrashing) or agent self-signal `<ralph>GUTTER</ralph>` | Rotation with diagnostic post-mortem |
| `COMPLETE` | Agent emits `<promise>ALL_TASKS_DONE</promise>` | Loop exits successfully; chains `--evaluate` if set |
| `DEFER` | Rate limit or transient API error | Backoff and retry (does not increment respawn count) |
| `RECOVER` | Successful `git commit` after a gate failure | Resets the gate-fail streak counter |
| `HEARTBEAT` | Any tool activity | Resets the main loop's read-timeout — internal, not user-visible |

Loop-end activity-log labels: 🤝 `GRACEFUL YIELD` (agent honored a breadcrumb and wrote handoff), 🔄 `ROTATE` (context cliff), 🛑 `TURN_END` (gate-fail streak), 🛌 `NATURAL END` (agent bailed politely without yielding).

## Spec Kit mode

If you use [Spec Kit](https://github.com/github/spec-kit), pick `--spec` and Ralph will:

1. Find the most-recent `specs/*` dir by mtime (or the one you name).
2. **Generate a loop-adapted prompt** from your project's `speckit-implement` skill (`.claude/skills/speckit-implement/SKILL.md`, with hash-based caching) — keeps the loop in sync with your version of Spec Kit. Falls back to the built-in template if the skill doesn't exist.
3. Substitute `{{SPEC_DIR}}`, `{{CONSTITUTION_PATH}}`, `{{TASK_FILE}}`, `{{PLAN_FILE}}`, `{{SPEC_FILE}}`, `{{BASIC_CHECK_COMMAND}}` / `{{FULL_CHECK_COMMAND}}` / `{{FINAL_CHECK_COMMAND}}` (from `[gates]`), and the recent activity-log tail into the prompt.
4. Enforce one-task-per-commit, gate-discipline, and the `<promise>ALL_TASKS_DONE</promise>` completion sigil (verified against the real checkbox state — no hallucinated promises).

Gate commands come from `[gates]` in `.ralph/command-policy` — every project sets its own. There are no defaults.

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
| `RALPH_GATE_TIMEOUT` | — | Blanket gate-timeout override (seconds). Wins over the per-tier vars below. |
| `RALPH_BASIC_GATE_TIMEOUT` | `1200` | Timeout for tier label `basic` (and all kind labels: `unit | integration | e2e | lint | format`) |
| `RALPH_FULL_GATE_TIMEOUT` | `1200` | Timeout for tier label `full` |
| `RALPH_FINAL_GATE_TIMEOUT` | `1200` | Timeout for tier label `final` |
| `RALPH_GATE_KILL_GRACE` | `10` | Seconds between SIGTERM and SIGKILL on timeout |
| `RALPH_GATE_KEEP` | `5` | Number of timestamped gate logs to retain per label |
| `RALPH_GATE_LOCK_WAIT` | `60` | Seconds to wait for a gate lock before giving up. PID-aware steal kicks in immediately when the holder is dead. |
| `RALPH_GATE_STALE_LOCK_SEC` | `2700` | Time-based fallback: steal locks older than this (45 min) when no PID file exists (pre-0.12.5 leftover locks). |
| `RALPH_GATE_FAIL_STREAK_THRESHOLD` | `5` | Consecutive gate failures before TURN_END |
| `RALPH_COMPLETE_BLOCK_THRESHOLD` | `2` | Consecutive COMPLETE-BLOCKED loops with the same reason before failing loud (unsatisfiable completion bar) |
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
