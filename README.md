# ralph-wiggum-plugin

A CLI-agnostic Ralph autonomous-development loop. Drives either the [Claude Code](https://docs.claude.com/en/docs/claude-code) (`claude`) or [Cursor](https://cursor.com) (`cursor-agent`) headless CLI from a terminal, with token accounting, context rotation, gutter detection, retry/backoff, Spec Kit integration, and (0.6.0+) plugin skills for cognitive-mode switching when the agent gets stuck.

> "That's the beauty of Ralph — the technique is deterministically bad in an undeterministic world." — Geoffrey Huntley

## What it is

The Ralph loop is a **shell script you run in a terminal**. It spawns the agent CLI as a subprocess, reads its stream-json output, tracks tokens, rotates context when the window fills, and keeps going until the task is done or the safety cap on agent respawns is reached. The loop is editor-agnostic: the editor you have open is irrelevant.

A healthy ralph **loop** runs as one continuous agent process — it commits as it goes and keeps moving until a real stop condition fires. It only respawns the agent (looping) on hard signals: context-window pressure, a genuine stuck pattern, a rate-limit backoff. Looping is fine when needed but flow is much better — a single small spec usually completes in one loop.

The Claude Code plugin wrapping (slash commands, plugin manifest, **and the cognitive-mode skills introduced in 0.6.0**) is a Claude Code-only enrichment. **For Claude Code users, install as a plugin** — it unlocks the specialist skills (`running-gates`, `diagnosing-stuck-tasks`, `reviewing-loop-progress`) that the loop suggests when stuck patterns fire. Standalone-script users still get the full loop infrastructure but the agent runs without those specialist prompts.

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

Unlocks slash commands AND the 0.6.0 specialist skills. The loop's stuck-pattern detection writes `.ralph/skill-suggestion` pointing at one of `diagnosing-stuck-tasks`, `running-gates`, or `reviewing-loop-progress`; those skills are only discovered by `claude` when this plugin is installed.

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
| `--eval-loops N` | Cap for the chained eval loop (`--eval-iterations` is the deprecated alias) | 5 |
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
- `handoff.md` — navigation breadcrumb between loops (used when the loop must respawn)
- `skill-suggestion` — present only when the loop has suggested the agent invoke a specific skill
- `diagnosis.md` — written by the `diagnosing-stuck-tasks` skill when escalating

Your commits are your durable memory. Ralph commits frequently during each loop so any involuntary kill is recoverable from the last commit.

## Spec Kit mode

If you use [Spec Kit](https://github.com/github/spec-kit), pick `--spec` and Ralph will:

1. Find the most-recent `specs/*` dir by mtime (or the one you name).
2. **Generate a loop-adapted prompt** from your project's `speckit-implement` skill (`.claude/skills/speckit-implement/SKILL.md`, with hash-based caching) — keeps the loop in sync with your version of Spec Kit. Falls back to the built-in template if the skill doesn't exist.
3. Substitute `{{SPEC_DIR}}`, `{{CONSTITUTION_PATH}}`, `{{TASK_FILE}}`, `{{PLAN_FILE}}`, `{{SPEC_FILE}}`, gate commands, and (0.6.0+) the recent activity-log tail into the prompt.
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
ralph --cli claude --spec --evaluate --eval-loops 5
```

For mode mechanics, artifacts, and limitations, see [docs/development.md → Acceptance evaluation loop](docs/development.md#acceptance-evaluation-loop--internals).

## Pointers

- **[`docs/gate-run.md`](docs/gate-run.md)** — full reference for the gate-runner wrapper (label enum, env vars, failure-pattern regex, agent protocol).
- **[`docs/skills.md`](docs/skills.md)** — operator reference for the 0.6.0 specialist skills (when each is suggested, how to override or disable).
- **[`docs/development.md`](docs/development.md)** — internals for working on the plugin: tests, lint, watchdogs, signals, project layout.
- **[Geoffrey Huntley's Ralph technique](https://ghuntley.com)** — original concept.

## Credits

- [@agrimsingh](https://github.com/agrimsingh) for [`ralph-wiggum-cursor`](https://github.com/agrimsingh/ralph-wiggum-cursor) — the proven cursor-agent implementation this plugin ports (MIT).
- [Geoffrey Huntley](https://ghuntley.com) for the original Ralph technique.

## License

MIT. See `LICENSE`.
