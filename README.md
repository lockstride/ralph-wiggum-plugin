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

## Important: what this plugin is and isn't

The Ralph loop runs in a **terminal, outside any editor session**. Claude Code plugin wrapping is just a delivery mechanism — the `/ralph` slash command prints a one-liner that starts `shared-scripts/ralph-setup.sh` in your terminal. The loop then shells out to whichever agent CLI you picked.

Cursor users can skip the Claude Code plugin system entirely and use the `install.sh` script (see below).

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

## Install as a Claude Code plugin

Via a marketplace (recommended):

```
/plugin marketplace add lockstride/claude-marketplace
/plugin install ralph-wiggum-plugin@lockstride
```

Then from inside a Claude Code session:

```
/ralph --cli claude --spec --yes
```

The slash command prints a one-liner you paste into your terminal. The loop starts there and runs independently of the editor session.

## Install as plain scripts (Cursor users, or anyone who wants the raw loop)

```
curl -fsSL https://raw.githubusercontent.com/lockstride/ralph-wiggum-plugin/main/install.sh | bash
```

This drops the scripts into `.claude/ralph-scripts/` inside the current repo. You then run:

```
./.claude/ralph-scripts/ralph-setup.sh
```

## Usage

### Interactive launcher

```
bash shared-scripts/ralph-setup.sh
```

Walks you through:

1. CLI (`claude` or `cursor-agent`)
2. Prompt source (PROMPT.md / custom file / spec dir)
3. Model
4. Max iterations
5. Confirmation

### Scripted / unattended

All interactive prompts are skipped when the corresponding flag is present:

```
# Drive Claude Code against the newest spec, 30 iters, no prompts
bash shared-scripts/ralph-setup.sh --cli claude --spec -n 30 --yes

# Drive Cursor against a specific prompt file
bash shared-scripts/ralph-setup.sh --cli cursor-agent --prompt-file PROMPT.md --yes

# Drive Claude against a named spec, with a branch and PR
bash shared-scripts/ralph-setup.sh \
  --cli claude \
  --spec 20260131-example-feature \
  --branch feature/example \
  --pr --yes
```

### Smoke test a single iteration

```
bash shared-scripts/ralph-once.sh --cli claude --spec
```

### Flags

| Flag | What it does |
|---|---|
| `--cli <claude\|cursor-agent>` | Which agent CLI to drive. Default: `claude`. |
| `-m, --model <id>` | Model name. Default: `claude-sonnet-4-5` / `opus-4.5-thinking`. |
| `-n, --iterations N` | Max iterations. Default: 20. |
| `--prompt` | Use `PROMPT.md` at the workspace root. |
| `--prompt-file <path>` | Use a custom prompt file. |
| `--spec [name]` | Use a Spec Kit spec dir. No name = most recent by mtime. |
| `--completion-promise <text>` | Custom completion sigil (back-compat with the official plugin). |
| `--branch <name>` | Work on a named branch. |
| `--pr` | Open a PR when complete. Requires `--branch`. |
| `-y, --yes` | Skip confirmation prompt. |
| `-h, --help` | Show help. |

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
2. Render `shared-references/templates/speckit-prompt.md` with `{{SPEC_DIR}}`, `{{CONSTITUTION_PATH}}`, `{{TEST_COMMAND}}`, `{{TASK_FILE}}`, `{{PLAN_FILE}}`, and `{{SPEC_FILE}}` substituted.
3. Enforce the Spec Kit read order (constitution → spec → plan → tasks), one task per iteration, checklist gates, and the `<promise>ALL_TASKS_DONE</promise>` completion sigil (verified against the real checkbox state — no hallucinated promises).

The default test command is `pnpm test`. Override by creating `.ralph/test-command` in your repo with the command you want.

## Signals the loop understands

Emitted by the stream parser to the loop on stdout:

- `ROTATE` — token threshold hit, loop kills the agent and starts a fresh iteration
- `WARN` — approaching the threshold, agent is told to wrap up
- `GUTTER` — stuck pattern (3× same shell failure, 5× writes to same file in 10 min, non-retryable API error, or agent emits `<ralph>GUTTER</ralph>`)
- `COMPLETE` — agent emits `<ralph>COMPLETE</ralph>` or `<promise>ALL_TASKS_DONE</promise>`, and the parser re-checks the real checkbox state before honoring it
- `DEFER` — retryable API / network error (rate limit, 5xx, timeout); loop waits with exponential backoff (15s → 120s + 0–25% jitter) and retries

## Troubleshooting

- **`claude` won't start / hangs on permission prompts** — confirm `--dangerously-skip-permissions` is being passed. It is mandatory for unattended runs.
- **Tool calls don't appear in the stream** — Claude Code requires `--verbose` when combining `-p` with `--output-format stream-json`. The adapter passes this automatically.
- **Cursor stream events look different from what the parser expects** — run `cursor-agent -p --force --output-format stream-json "hello"` and diff the top-level shapes against the filter in `agent-adapter.sh` → `cursor-agent` branch.
- **`jq: error` in the pipeline** — install jq (`brew install jq`). The canonical-schema normalization pipeline needs it.
- **Context rotation never fires** — `ROTATE_THRESHOLD` defaults to 150k for Claude, 80k for Cursor. Override with `ROTATE_THRESHOLD=50000 ./ralph-loop.sh ...` to force it to fire sooner for debugging.
- **Agent keeps "completing" but checkboxes aren't updated** — the parser re-scans your task file before honoring the completion sigil. Check that your task file is where the parser expects (`RALPH_TASK.md`, `PROMPT.md`, or `.ralph/effective-prompt.md`) and uses real checkbox syntax (`- [ ]`, `* [x]`, `1. [ ]`).

## What's not in v0.1.0

- **Parallel mode** — Phase 5 of the plan (Worktrunk-based sub-worktrees with squash-merge-back) ships in v0.2.0. The prompt template already supports a parallel variant, so nothing is wasted.
- **Automatic spec analyzer** — determines whether a spec is parallel-friendly. Ships with parallel mode.

## Credits

- [@agrimsingh](https://github.com/agrimsingh) for [`ralph-wiggum-cursor`](https://github.com/agrimsingh/ralph-wiggum-cursor) — the proven cursor-agent implementation this plugin ports (MIT).
- [Geoffrey Huntley](https://ghuntley.com) for the original Ralph technique.

## License

MIT. See `LICENSE`.
