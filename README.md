# ralph-wiggum-plugin

A CLI-agnostic Ralph autonomous-development loop — the successor to the in-session Stop-hook variant. Drives either the [Claude Code](https://docs.claude.com/en/docs/claude-code) (`claude`) or [Cursor](https://cursor.com) (`cursor-agent`) headless CLI from a terminal, with token accounting, context rotation, gutter detection, retry/backoff, and a Spec Kit mode.

> "That's the beauty of Ralph — the technique is deterministically bad in an undeterministic world." — Geoffrey Huntley

## Why this exists

Other Ralph plugins run as an in-session Stop-hook — that means no token tracking, no context rotation, no gutter detection, no learning loop. This plugin ports the proven machinery from [`agrimsingh/ralph-wiggum-cursor`](https://github.com/agrimsingh/ralph-wiggum-cursor) and wraps it behind a single agent-adapter layer so you can drive it with either CLI, and adds:

- **CLI picker** (`claude` or `cursor-agent`, chosen per-run)
- **Three prompt sources**: `PROMPT.md`, custom file, or Spec Kit spec dir (most-recent by mtime)
- **Spec Kit-aware prompt template** that enforces read order, one-task-per-iteration, checklist gates, and a hallucination-proof completion sigil
- **Token-accounting** with per-CLI thresholds (Claude gets more headroom than Cursor)
- **Unattended-by-default**: both CLIs are always invoked with their skip-approval flag
- **Claude Code slash commands** (`/ralph`, `/ralph-once`, `/ralph-cancel`) that launch the terminal loop

## How it runs

The Ralph loop is a **shell script you run in a terminal**. It is not tied to any editor session. You decide which agent CLI it drives (`claude` or `cursor-agent`) at shell script execution time — via the interactive picker, or a `--cli` flag.

There is no "inside Claude Code" vs "inside Cursor" distinction for the loop itself. The editor you happen to have open is irrelevant. Ralph spawns the agent CLI as a subprocess, reads its stream-json output, tracks tokens, rotates context when the window fills, and keeps going until the task is done or max iterations is reached.

The Claude Code plugin wrapping — the `/ralph` slash command, the plugin manifest — is only a discoverability convenience for Claude Code users. The slash command itself does nothing except print the same one-liner shell command you would run directly. Cursor users (or anyone else) can and should skip it.

## ⚠️ Blast radius

Ralph runs the agent **with all tool approvals pre-granted** — `--dangerously-skip-permissions` for `claude`, `--force` for `cursor-agent`. This is intentional: the loop runs unattended and cannot pause for permission prompts.

**Consequences:**

- Run **only in a dedicated worktree** with a clean git state.
- **Never** run against a repo holding uncommitted work you care about.
- Prefer a fresh branch; the loop will commit on whatever branch is checked out.
- The sandbox comes from your worktree isolation, not from per-tool approval.

There is no flag to disable YOLO mode. That is the point of Ralph.

## Prerequisites

- **git**
- **jq** (`brew install jq` on macOS, `apt-get install jq` on Debian)
- **At least one agent CLI**:
  - `claude`: `npm install -g @anthropic-ai/claude-code`, then `claude login`
  - `cursor-agent`: `curl https://cursor.com/install -fsS | bash`
- **gum** (optional, nicer UI): `brew install gum`

## Install

All three options give you the same loop scripts. Options A and B are standalone — they put the scripts on disk and you run them directly. Option C additionally registers the repo as a Claude Code plugin, which adds slash commands (`/ralph`, `/ralph-once`, `/ralph-cancel`) for discoverability. The slash commands themselves just print a shell command for you to copy-paste into a terminal; they don't execute anything.

### Option A — `install.sh` (recommended, editor-agnostic)

Works whether you use Claude Code, Cursor, Zed, Vim, or nothing at all. Drops the scripts + templates into `.claude/ralph-scripts/` and `.claude/ralph-templates/` inside the current repo:

```
curl -fsSL https://raw.githubusercontent.com/lockstride/ralph-wiggum-plugin/main/install.sh | bash
```

### Option B — git clone

```
git clone https://github.com/lockstride/ralph-wiggum-plugin.git ~/ralph-wiggum-plugin
~/ralph-wiggum-plugin/shared-scripts/ralph-setup.sh /path/to/your/repo
```

### Option C — Claude Code plugin (adds slash commands)

Installs the repo as a registered Claude Code plugin. You get the same loop scripts as A and B, plus `/ralph`, `/ralph-once`, and `/ralph-cancel` in the slash-command menu. Only useful if you run Claude Code and want that discoverability — the slash commands are convenience wrappers that print a terminal command, nothing more.

```
/plugin marketplace add lockstride/claude-marketplace
/plugin install ralph-wiggum-plugin@lockstride-marketplace
```

## Usage

### Interactive launcher

```
./.claude/ralph-scripts/ralph-setup.sh
```

Walks you through:

1. CLI (`claude` or `cursor-agent`)
2. Model
3. Prompt source (PROMPT.md / custom file / spec dir)
4. Max iterations

### Scripted / unattended

All interactive prompts are skipped when the corresponding flag is present:

```
# Drive Claude Code against the newest spec, 30 iters, no prompts
./.claude/ralph-scripts/ralph-setup.sh --cli claude -m opus --spec -n 30

# Drive Cursor against a specific prompt file
./.claude/ralph-scripts/ralph-setup.sh --cli cursor-agent --prompt-file PROMPT.md

# Drive Claude against a named spec, with a branch and PR
./.claude/ralph-scripts/ralph-setup.sh \
  --cli claude \
  --spec 20260131-example-feature \
  --branch feature/example \
  --pr
```

### Smoke test a single iteration

```
./.claude/ralph-scripts/ralph-once.sh --cli claude --spec
```

### Flags

Flags that take a required value are shown with `<value>`. When a flag is omitted, the interactive launcher prompts you to choose; the "if omitted" column shows what the picker pre-selects (accepted by pressing Enter).

| Flag | What it does | If omitted |
|---|---|---|
| `--cli <claude\|cursor-agent>` | Which agent CLI to drive | interactive picker (pre-selects `claude`) |
| `-m, --model <id>` | Model name | interactive picker (pre-selects `opus` for Claude, `composer-2` for Cursor) |
| `-n, --iterations N` | Max iterations | interactive picker (pre-fills `20`) |
| `--branch <name>` | Work on a named branch | current branch |
| `--pr` | Open a PR when complete; requires `--branch` | off |
| `-v, --version` | Print version and exit | — |
| `-h, --help` | Show help | — |

**Prompt source** — mutually exclusive, pick at most one:

| Flag | Behavior |
|---|---|
| *(none of the below)* | Interactive picker prompts you to choose |
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
- `effective-prompt.md` — the rendered prompt fed to the agent every iteration
- `.iteration` — current iteration counter
- `tasks.yaml` — cached task parsing

Your commits are your durable memory. Ralph commits frequently during each iteration so that if a context rotation happens, the next agent picks up from the last commit.

## Spec Kit mode

If you use [Spec Kit](https://github.com/github/spec-kit), pick `--spec` and Ralph will:

1. Find the most-recent `specs/*` dir by mtime (or the one you name).
2. **Generate a loop-adapted prompt** from your project's `speckit.implement.md` (see below), or fall back to the built-in template if that command file doesn't exist.
3. Substitute `{{SPEC_DIR}}`, `{{CONSTITUTION_PATH}}`, `{{TASK_FILE}}`, `{{PLAN_FILE}}`, `{{SPEC_FILE}}`, and gate commands into the prompt.
4. Enforce one phase per iteration, checklist gates, and the `<promise>ALL_TASKS_DONE</promise>` completion sigil (verified against the real checkbox state — no hallucinated promises).

The default basic check command is `pnpm basic-check`. Override by creating `.ralph/basic-check-command` in your repo. The default final check command is `pnpm all-check`, overridable via `.ralph/final-check-command`.

### Prompt generation

When your project has `.claude/commands/speckit.implement.md` (installed by Spec Kit), Ralph **generates the loop prompt from it** instead of using a static template. This keeps the loop prompt in sync with your version of Spec Kit as it evolves.

The generation uses a durable adaptation guide (`shared-references/templates/speckit-adaptation-guide.md`) that transforms the interactive skill into an unattended loop prompt — stripping user prompts, one-time setup, and hooks, while adding iteration handoff, gate wrappers, commit-per-task protocol, and completion signals.

The generated prompt is cached at `<spec_dir>/ralph-prompt.md` with a hash at `<spec_dir>/.ralph-prompt-hash`. It only regenerates when `speckit.implement.md` changes (hash mismatch). Both files are committed to git so you can review and edit the prompt before or during the loop.

Set `RALPH_SKIP_GENERATION=1` to force use of the built-in template instead.

## Watchdogs

Ralph includes three watchdogs to prevent the loop from hanging indefinitely:

| Watchdog | Env var | Default | What it does |
|----------|---------|---------|--------------|
| **Heartbeat timeout** | `RALPH_HEARTBEAT_TIMEOUT` | 300s | If the stream parser produces no output for this long, kills the agent and retries via DEFER with exponential backoff. Catches API stalls and rate-limit hangs. |
| **Gate timeout** | `RALPH_GATE_TIMEOUT` | 300s | If a gate command (e.g. `pnpm all-check`) doesn't finish within this time, kills it and returns exit 124. Catches hung nx daemons and build processes. Requires `timeout` (Linux) or `gtimeout` (macOS via `brew install coreutils`). |
| **Read-without-write stall** | `RALPH_MAX_READS_WITHOUT_WRITE` | 25 | If the agent executes this many consecutive Read/Shell operations without any Write/Edit, emits GUTTER. Catches diagnostic loops where the model reads file after file without making progress. |

## Signals the loop understands

Emitted by the stream parser to the loop on stdout:

- `ROTATE` — token threshold hit, loop kills the agent and starts a fresh iteration
- `WARN` — approaching the threshold, agent is told to wrap up
- `GUTTER` — stuck pattern (3× same shell failure, 5× writes to same file in 10 min, non-retryable API error, or agent emits `<ralph>GUTTER</ralph>`)
- `COMPLETE` — agent emits `<ralph>COMPLETE</ralph>` or `<promise>ALL_TASKS_DONE</promise>`, and the parser re-checks the real checkbox state before honoring it
- `DEFER` — retryable API / network error (rate limit, 5xx, timeout); loop waits with exponential backoff (15s → 120s + 0–25% jitter) and retries

## Development

### Prerequisites

Install the linting and formatting tools:

```
brew install shellcheck shfmt
```

### Testing

Behavioral tests use [bats-core](https://github.com/bats-core/bats-core):

```
brew install bats-core
bats tests/
```

Tests cover gate-run.sh (timeout, exit codes, log retention), stream-parser.sh (signal detection, stall patterns), prompt-resolver.sh (caching, hash checks, fallbacks), and build_prompt framing.

`./lint.sh` runs tests automatically if bats is installed.

### Linting & formatting

Run checks (and tests) across all shell scripts:

```
./lint.sh
```

Auto-format with shfmt:

```
./lint.sh --fix
```

### Pre-commit hook

The repo uses a git pre-commit hook (`.githooks/pre-commit`) that runs shellcheck and shfmt on staged `.sh` files. Wire it up once after cloning:

```
git config core.hooksPath .githooks
```

Commits that introduce lint or formatting issues will be blocked. Bypass with `git commit --no-verify` if needed.

## Changelog

### 0.2.0

- **Prompt generation from speckit.implement.md.** When the project has `.claude/commands/speckit.implement.md`, the loop prompt is generated from it using an adaptation guide + hand-tuned exemplar, instead of a static 232-line template. The generated prompt is cached at `<spec_dir>/ralph-prompt.md` and only regenerates when `speckit.implement.md` changes (hash-based invalidation). Falls back to the built-in template for projects without Spec Kit commands.
- **Trimmed framing prompt.** `build_prompt()` reduced from ~85 lines to ~25 lines. Removed competing instruction sets (naming hygiene, gate invocation contract, Signs/guardrails, zero-baseline duplication, working directory constraints) that overlapped with the generated prompt and caused cognitive overload.
- **Heartbeat timeout.** If the stream parser produces no output for `RALPH_HEARTBEAT_TIMEOUT` seconds (default 300), the agent is killed and retried via DEFER with exponential backoff. Catches hour-long API stalls.
- **Gate timeout.** Gate commands are wrapped with `timeout` / `gtimeout` (default `RALPH_GATE_TIMEOUT=300`). Catches hung nx daemons and build processes that previously blocked the loop for 30+ minutes.
- **Read-without-write stall detection.** New gutter pattern: if the agent executes `RALPH_MAX_READS_WITHOUT_WRITE` (default 25) consecutive Read/Shell operations without any Write/Edit, GUTTER is emitted. Catches degenerate diagnostic loops.
- **Test infrastructure.** Added behavioral tests using bats-core (30 tests across gate-run, stream-parser, prompt-resolver, and ralph-common). `./lint.sh` runs tests automatically.

### 0.1.10

- **Gate discipline.** Spec Kit task execution now runs exactly one gate per task (`{{BASIC_CHECK_COMMAND}}` or `{{FINAL_CHECK_COMMAND}}`, never both). The agent picks based on what the task touched — barrel exports, Prisma schema, module registration, app bootstrap, tsconfig paths, workspace deps, and auth middleware trigger the full final check; everything else uses basic check. Phase completion skips the redundant final-check run if the last task already ran it.
- **Gate before commit, always.** The task loop now runs the chosen gate *before* `git add` / `git commit`, so red code never enters HEAD. No `--amend` churn on test failures.
- **Explicit-file staging rule.** The Git Protocol now mandates `git add <exact paths>` and forbids `git add .`, `git add -A`, and `git add <dir>`. This closes the orphan-file sweep bug that caused stray `specs/005-comparison-*.md` files from a dropped stash to get committed into unrelated task work.
- **Orphan-file leak detector** in the loop. Each iteration captures a baseline of untracked files at start and compares it to the files committed during the iteration. Leaks get logged to `.ralph/errors.log` and `activity.log` as a non-blocking warning so the operator can spot broad-add problems immediately.
- **Post-mortem bundles** on GUTTER / STALL / max-iterations. When a loop ends abnormally, a tarball is written to `<workspace>/.ralph-postmortems/<timestamp>-<reason>.tar.gz` containing `.ralph/` state files and a git snapshot. Survives `/ralph-cancel` cleanup. Host projects should gitignore `.ralph-postmortems/`.
- **Tighter `check_gutter`.** The "same shell command failed" threshold in the stream parser dropped from 3 to 2. A second identical failure is already strong evidence of stuckness and the extra retry just burns tokens.

### 0.1.9

- Refactor and cleanup: removed `--completion-promise` flag, streamlined task file resolution to prioritize `.ralph/task-file-path` in Spec Kit mode, removed legacy command fallbacks.

### 0.1.8

- Phase-level iteration for Spec Kit mode: one iteration now completes an entire phase's worth of tasks instead of a single task, better matching 1M-context model capacity.
- Dual check commands: `{{BASIC_CHECK_COMMAND}}` for per-task gating and `{{FINAL_CHECK_COMMAND}}` for phase boundaries.
- Stall detector split into two counters: `zero_progress_count` (threshold 3) for natural-end iterations with zero task progress, and `stall_count` (threshold 10) for rate-limit/DEFER chains.
- `build_prompt` no longer feeds `activity.log` to the agent (human-only monitoring); `progress.md` is trimmed to last ~100 lines.

## Credits

- [@agrimsingh](https://github.com/agrimsingh) for [`ralph-wiggum-cursor`](https://github.com/agrimsingh/ralph-wiggum-cursor) — the proven cursor-agent implementation this plugin ports (MIT).
- [Geoffrey Huntley](https://ghuntley.com) for the original Ralph technique.

## License

MIT. See `LICENSE`.
