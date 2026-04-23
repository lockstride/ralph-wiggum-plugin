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

## Gate runner (`gate-run.sh`)

The single most load-bearing utility in this plugin is **`shared-scripts/gate-run.sh`** — a project-agnostic wrapper you invoke instead of running `pnpm test`, `cargo test`, or any other verification command bare. It exists because agents (and humans) otherwise burn minutes re-running the same gate to see more output, or accidentally swallow exit codes through pipes. The wrapper:

- Tees the full combined stream to `.ralph/gates/<label>-<ts>.log` (and a `-latest.log` pointer) so failures can be diagnosed via targeted reads, not re-runs.
- Prints a bounded summary: header, `tail -n 60`, and up to 80 line-numbered matches for common failure signatures (vitest / jest / cypress / tsc / eslint / nestjs / generic stack traces).
- Exits with the real command status via `PIPESTATUS` (`pipefail`-safe).
- Enforces per-label timeouts (`basic`/`final`/`e2e`/`lint`/`custom`) to catch hung daemons instead of waiting forever.
- Writes a single-decimal exit breadcrumb to `.ralph/gates/<label>-latest.exit` that the loop's completion guard consults — a red gate blocks `<promise>ALL_TASKS_DONE</promise>` even if every checkbox is flipped.

**Usage — never pipe, never redirect:**

```bash
bash .claude/ralph-scripts/gate-run.sh basic pnpm basic-check
bash .claude/ralph-scripts/gate-run.sh final pnpm all-check
bash .claude/ralph-scripts/gate-run.sh e2e   pnpm test-e2e:local
```

**Full help** (env vars, exit codes, label enum, failure patterns):

```bash
bash .claude/ralph-scripts/gate-run.sh --help
```

**Agent protocol in one paragraph.** Run every gate via the wrapper. If the summary ends with `exit=0`, commit and move on — do not re-read the log. If it ends with `exit=N≠0`, **do not re-run the gate**; open `.ralph/gates/<label>-latest.log` with your `Read`/`Grep` tool (it's the full output, unfiltered), fix the smallest thing that could be wrong, then re-run **once**. Re-running the same gate twice in a row without any edits in between is pure waste.

See **[`docs/gate-run.md`](docs/gate-run.md)** for the complete spec: label enum, environment variables, failure-pattern regex, what it does and does not catch (Rust / Go / Python / Ruby notes), portability caveats, and the full agent protocol. Inside the Ralph loop, `build_prompt()` already injects a compact version of the protocol into every iteration prompt — the doc is the reference you (or a future coding agent) reach for when the inline reminders are not enough.

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

Installs the repo as a registered Claude Code plugin. You get the same loop scripts as A and B, plus `/ralph`, `/ralph-once`, `/ralph-evaluate`, and `/ralph-cancel` in the slash-command menu. Only useful if you run Claude Code and want that discoverability — the slash commands are convenience wrappers that print a terminal command, nothing more.

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
| `--evaluate` | Chain acceptance evaluation loop when the main loop completes (equivalent env var: `RALPH_CHAIN_EVALUATE=1`) | off |
| `--eval-iterations N` | Cap for the chained eval loop | 5 |
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

## Acceptance evaluation loop

When the main Ralph loop exits `COMPLETE`, all it has confirmed is that the agent checked every `[ ]` and the final gate was green. That's a self-assessment. The **acceptance evaluation loop** is a second Ralph loop that runs *after* the first one, with an independent orchestrator prompt that:

1. Re-reads the original ground truth (the same `PROMPT.md`, custom file, or `specs/*/tasks.md` the main loop worked from).
2. Picks one of two modes per iteration based on the current state of `.ralph/acceptance-report.md`:
   - **VERIFIER** — independently checks every requirement (file reads, grep for conventions, Playwright MCP for UI behavior if the server is available, gate runs under `eval-*` labels) and records every unmet requirement as a `[ ]` line in the report's **Gaps** section.
   - **REWORK** — works the verifier's Gaps list, resolving as many as possible and checking them off. Unresolvable ones get a `(blocked: reason)` suffix.
3. Delegates all mode work to a sub-agent via the Task tool. The orchestrator stays lean so context pollution across iterations stays bounded.

The loop exits cleanly when the verifier flips the report's top-level `- [ ] All acceptance criteria met and verified` checkbox to `[x]` (only the verifier is allowed to do this, and only after a clean independent pass). Otherwise it stops at the iteration cap (default 5).

### Invoke standalone

```
./shared-scripts/ralph-evaluate.sh --prompt
./shared-scripts/ralph-evaluate.sh --spec
./shared-scripts/ralph-evaluate.sh --prompt-file custom.md -n 8
./shared-scripts/ralph-evaluate.sh --prompt --fresh   # wipe prior report
```

Or via the slash command inside Claude Code: `/ralph-evaluate --prompt`.

### Chain after a main loop

Pass `--evaluate` to the main launcher (or set `RALPH_CHAIN_EVALUATE=1` as a durable opt-in):

```
./shared-scripts/ralph-setup.sh --cli claude --prompt --evaluate --eval-iterations 5
```

Chain fires only when the main loop exits cleanly. Failed / exhausted / gutter runs skip the eval pass — acceptance testing against known-broken state produces noise, not signal.

### Artifacts

- `.ralph/acceptance-report.md` — the report the orchestrator maintains. Git-ignored (same as the rest of `.ralph/`); if you want a persistent audit trail, copy it out after the loop exits.
- `.ralph/eval-ground-truth` — breadcrumb recording which file served as ground truth for the last eval run.

### Limitations

- **Sub-agent support depends on the driving CLI.** The orchestrator uses the Task tool to spawn role sub-agents. `claude` supports this natively; `cursor-agent` may fall back to in-context orchestration, which reduces the context-isolation benefit but does not break correctness.
- **UI verification requires Playwright MCP.** If the MCP server isn't installed, the verifier notes the limitation in the relevant gap rather than silently skipping UI requirements.
- **The verifier is only as good as the ground-truth requirements.** Vague requirements in `PROMPT.md` produce vague gap reports.

## Watchdogs

Ralph includes three watchdogs to prevent the loop from hanging indefinitely:

| Watchdog | Env var | Default | What it does |
|----------|---------|---------|--------------|
| **Heartbeat timeout** | `RALPH_HEARTBEAT_TIMEOUT` | 300s | If the stream parser produces no output for this long, kills the agent and retries via DEFER with exponential backoff. Catches API stalls and rate-limit hangs. |
| **Gate timeout** | `RALPH_GATE_TIMEOUT` (blanket) / `RALPH_BASIC_GATE_TIMEOUT` / `RALPH_FINAL_GATE_TIMEOUT` | 600s basic / 900s final | If a gate command (e.g. `pnpm all-check`) doesn't finish within this time, kills it and returns exit 124. Catches hung nx daemons and build processes. Requires `timeout` (Linux) or `gtimeout` (macOS via `brew install coreutils`). |
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

Tests cover gate-run.sh (timeout, exit codes, log retention), stream-parser.sh (signal detection, stall patterns), prompt-resolver.sh (caching, hash checks, fallbacks, task-file-path breadcrumb for all prompt modes), ralph-evaluate.sh (flag parsing, ground-truth resolution, report seeding, orchestrator prompt rendering), and build_prompt framing.

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

### 0.5.1

- **`ralph-status` eval badge.** When `.ralph/eval-ground-truth` exists (dropped by `ralph-evaluate.sh`), the status header now renders with an `[ACCEPTANCE EVAL]` suffix and the STATUS section gains a `mode: acceptance eval (ground truth: …)` row. Makes it obvious at a glance whether a running loop is an implementation pass or an acceptance re-check.

### 0.5.0

- **Acceptance evaluation loop (`ralph-evaluate.sh`, `/ralph-evaluate`).** A second Ralph loop that runs after the main one claims completion, with an orchestrator prompt that picks a VERIFIER or REWORK mode per iteration based on `.ralph/acceptance-report.md` and delegates the work to a sub-agent via the Task tool. The orchestrator keeps its own context lean; the sub-agent does the heavy lifting (file reads, gate runs, Playwright MCP for UI). Runs standalone, or chained after a main loop via `--evaluate` (flag) or `RALPH_CHAIN_EVALUATE=1` (env). Capped at 5 iterations by default; override with `--eval-iterations N`. Chain fires only when the main loop exits cleanly, so acceptance testing always runs against a claimed-done state.
- **Reliable task-file resolution for PROMPT.md and custom prompt-file modes.** Both now write the same `.ralph/task-file-path` breadcrumb the Spec Kit path has used since its introduction, pointing the loop's completion detector at the real task file instead of cascading through heuristic fallbacks. Fixes a long-standing ambiguity where edits to `.ralph/effective-prompt.md` mid-run could affect the counter in PROMPT.md mode. The eval loop relies on this breadcrumb to point the counter at its acceptance report instead.

### 0.4.0

- **Run-to-completion prompt.** Speckit prompt template and adaptation guide no longer cap each iteration at a single phase. The agent works every remaining unchecked task across every remaining phase in one iteration, yielding only on `ALL_TASKS_DONE`, rotation WARN, `.ralph/stop-requested`, or GUTTER. Before 0.4.0 the "one phase per iteration" rule was an artificial ceiling that ended iterations at ~10% of the model's rotation budget, multiplying cold-start orientation tax (re-reading tasks.md, spec, plan, contracts) across many short iterations. With modern 1M-context models this wastes 80%+ of available budget; with older 200K-window models it still pays the tax unnecessarily when the model could comfortably fit multiple phases. Session-id resume preserves context across rotations so even when rotation does fire, the next iteration picks up with full working memory.
- **Activity-based heartbeat.** Stream-parser now emits a `HEARTBEAT` token on every `log_activity` and `log_token_status` call, and the main loop consumes it as a no-op. The `RALPH_HEARTBEAT_TIMEOUT` timer now resets on real parser activity (reads, shells, token updates) rather than only on control signals (ROTATE/COMPLETE/DEFER/GUTTER/RECOVER/RECOVER_ATTEMPT/WARN). Before 0.4.0 the timer effectively measured "time since last commit," and a productive agent doing multi-minute work between commits would trip the 300s default and die at the 5-6 min mark every iteration. With the new heartbeat, only a genuinely stalled agent (no stream-json output at all for 300s) trips the timeout; the default can stay tight without killing real work.
- **Configurable stuck-pattern thresholds.** `RALPH_SHELL_FAIL_THRESHOLD` (default 4, up from a hardcoded 2) and `RALPH_FILE_THRASH_THRESHOLD` (default 5, unchanged) now gate the `RECOVER_ATTEMPT`-vs-`GUTTER` dispatch. The old threshold of 2 killed agents on normal red-state debug loops (run gate → read log → fix → re-run is 2 shell fails if the fix didn't work). 4 is still well below a genuine infinite loop but gives the agent a realistic debug budget.
- **Gentle DEFER.** On rate-limit or transient-error DEFER, the loop now writes a `.ralph/stop-requested` marker and waits `RALPH_DEFER_GRACE` seconds (default 30) before hard-killing. The agent's prompt tells it to check the marker after every commit and yield cleanly — which usually lets the current commit finish instead of getting torn up by the immediate SIGTERM.
- **Strict orphan reaping.** Iteration cleanup now uses an explicit kill ladder (SIGTERM all descendants → 1s grace → SIGKILL survivors → `pkill -9 -P` mop-up) and records any survivors to `.ralph/.orphan-claims.pid` for the next iteration to sweep at start. Plus a final `pkill -f` on the workspace-path-scoped argv signature as a safety net. Before 0.4.0, `kill -- -$agent_pid` silently failed to reach grandchildren in some process-group configurations, leaving stale `claude` CLIs alive across retries — they'd accumulate over a run, consume memory, and hold API auth state.
- **Full iteration label in the stream-parser session header.** The session-start banner in `activity.log` now reads `Ralph Session Started (Iteration 1.3)` for retries, matching the ITERATION START log line (0.3.7 retry counter was only half-wired; 0.3.10 completed the plumbing and 0.4.0 documents the result).

### 0.3.6

- **Gate runner documentation + discoverability.** Agents running the loop frequently didn't use `gate-run.sh` or didn't know where to find its persisted logs, leading to expensive re-runs on every failure. This release closes the discovery gap:
  - New **`--help` / `-h` flag** on `gate-run.sh` that prints the full surface (usage, labels, exit codes, env vars, failure-pattern coverage, agent protocol). First-line cold discovery from any shell.
  - New **[`docs/gate-run.md`](docs/gate-run.md)** — standalone reference covering labels, environment variables, failure-signature regex (with an explicit "what it won't catch" table for Rust / Go / Python / Ruby), portability notes, and the full agent protocol.
  - New **first-class "Gate runner" section in the README**, moved above the fold (between "How it runs" and "Blast radius") so anyone skimming the project learns the tool exists and why.
  - `build_prompt()` now **auto-injects a compact `## Gate Runner` section** into every non-Spec-Kit iteration prompt when `gate-run.sh` is installed next to it. Previously only Spec Kit mode surfaced the wrapper — custom-prompt and `PROMPT.md` loops had no gate awareness and agents would run bare commands. The block renders conditionally so older installs or standalone setups without the wrapper are not misled.
  - Usage-error messages (missing args, invalid label) now point at `--help` so cold discovery works even from a typo.
  - `AGENTS.md` gains a "Gate runner" subsection documenting the three-way contract (`docs/gate-run.md` ↔ `--help` ↔ `build_prompt()`) and the completion-guard breadcrumb format that must stay stable.

### 0.2.0

- **Prompt generation from speckit.implement.md.** When the project has `.claude/commands/speckit.implement.md`, the loop prompt is generated from it using an adaptation guide + hand-tuned exemplar, instead of a static 232-line template. The generated prompt is cached at `<spec_dir>/ralph-prompt.md` and only regenerates when `speckit.implement.md` changes (hash-based invalidation). Falls back to the built-in template for projects without Spec Kit commands.
- **Trimmed framing prompt.** `build_prompt()` reduced from ~85 lines to ~25 lines. Removed competing instruction sets (naming hygiene, gate invocation contract, Signs/guardrails, zero-baseline duplication, working directory constraints) that overlapped with the generated prompt and caused cognitive overload.
- **Heartbeat timeout.** If the stream parser produces no output for `RALPH_HEARTBEAT_TIMEOUT` seconds (default 300), the agent is killed and retried via DEFER with exponential backoff. As of 0.4.0 the parser emits a HEARTBEAT token on every logged activity (reads, shells, token updates), so the timeout measures real agent silence rather than commit cadence. Catches hour-long API stalls without killing productive agents.
- **Gate timeout.** Gate commands are wrapped with `timeout` / `gtimeout`. Per-label defaults: basic/e2e/lint/custom=600s, final=900s (0.3.9). Catches hung nx daemons and build processes that previously blocked the loop for 30+ minutes.
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
