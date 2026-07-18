# Development

Internal reference for working on the plugin itself: tests, lint, watchdogs, signals, and the deeper details of acceptance evaluation.

## Setup

```
brew install shellcheck shfmt bats-core
brew install gum         # optional: nicer interactive UI
brew install parallel    # optional: bats --jobs N parallel test execution
brew install coreutils   # provides gtimeout for the gate-timeout watchdog on macOS
```

## Testing

Behavioral tests use [bats-core](https://github.com/bats-core/bats-core):

```
bats tests/
```

Tests cover:

- `gate-run.sh` — timeout, exit codes, log retention, mkdir-mutex serialization
- `stream-parser.sh` — signal detection (ROTATE, WARN, GUTTER, TURN_END, DEFER, COMPLETE, RECOVER, HEARTBEAT), stall patterns, heartbeat sidecar
- `prompt-resolver.sh` — caching, hash checks, fallbacks, multi-line `{{ACTIVITY_TAIL}}` rendering, `task-file-path` breadcrumb across all prompt modes
- `ralph-evaluate.sh` — flag parsing, ground-truth resolution, report seeding, orchestrator prompt rendering
- `ralph-status.sh` — PROGRESS banner, PREVIOUS/CURRENT/NEXT sections, terminal-width-aware wrapping
- `ralph-common.sh` — `build_prompt` framing, recovery hint consumption
- `skills/*/SKILL.md` — frontmatter validation against [Anthropic's best practices](https://platform.claude.com/docs/en/agents-and-tools/agent-skills/best-practices) (name format, length, no reserved words, description trigger phrasing)

`./lint.sh` runs everything (shellcheck → shfmt → bats) and short-circuits on the first failure. With GNU parallel installed it runs ~3× faster.

## Linting & formatting

```
./lint.sh           # check only (CI-friendly)
./lint.sh --fix     # auto-format with shfmt
```

`RALPH_LINT_JOBS=N` overrides the default parallel-worker count (default 4).

## Pre-commit hook

```
git config core.hooksPath .githooks
```

The hook runs shellcheck and shfmt on staged `.sh` files. Bypass with `git commit --no-verify` only if the environment genuinely cannot run the checks (e.g. CI container missing the binaries) — and document the reason in the commit body.

## Watchdogs

Two watchdogs prevent the loop from hanging indefinitely.

| Watchdog | Env var | Default | What it does |
|---|---|---|---|
| **Heartbeat timeout** | `RALPH_HEARTBEAT_TIMEOUT` | 300s | If the stream parser produces no output for this long, kills the agent and retries via DEFER with exponential backoff. The 0.5.3 sidecar emits a synthetic `HEARTBEAT` every 60s so this only fires when the agent is genuinely silent (not just deep in a long tool call). |
| **Gate timeout** | `RALPH_GATE_TIMEOUT` (blanket) / `RALPH_BASIC_GATE_TIMEOUT` / `RALPH_FULL_GATE_TIMEOUT` / `RALPH_FINAL_GATE_TIMEOUT` | 1200s all tiers | If a gate command doesn't finish within this time, kills it and returns exit 124. Catches hung nx daemons and build processes. Requires `timeout` (Linux) or `gtimeout` (macOS via `brew install coreutils`). |

## Signals the loop understands

Emitted by the stream parser to the loop on stdout:

- `ROTATE` — token threshold hit; loop kills the agent and starts a fresh loop.
- `WARN` — approaching the threshold; agent is told to wrap up.
- `GUTTER` — hard stuck pattern (e.g., 10 writes/edits to the same file inside a 5-min window with no commit; 5 consecutive shell failures of the same shape), OR agent self-signals via `<ralph>GUTTER</ralph>`. Loop ends with a postmortem bundle. Thresholds tunable via `RALPH_FILE_THRASH_THRESHOLD`, `RALPH_FILE_THRASH_WINDOW_SECONDS`, `RALPH_SHELL_FAIL_THRESHOLD`.
- `RECOVER` — emitted on every successful `git commit`. Clears any latched GUTTER, the per-loop shell-failure counter, and the per-file write/edit thrash history (a successful commit is evidence of progress).
- `COMPLETE` — agent emits `<ralph>COMPLETE</ralph>` or `<promise>ALL_TASKS_DONE</promise>`. The parser re-checks the real checkbox state before honoring.
- `DEFER` — retryable API / network error (rate limit, 5xx, timeout). Loop waits with exponential backoff (15s → 120s + 0–25% jitter) and retries.
- `HEARTBEAT` — synthetic liveness ping from the parser sidecar (0.5.3+). Resets the loop's `read -t` timer; never causes any agent-side action.

## Acceptance evaluation loop — internals

The acceptance evaluator is a separate Ralph loop that runs *after* the main loop completes, with an independent orchestrator prompt and a sub-agent delegation pattern. The high-level "what / when" is in [the README](../README.md#spec-kit-mode); this section covers the implementation.

**Orchestrator → sub-agent delegation.** The orchestrator stays lean (reads the report, picks a mode, dispatches) so context pollution across loops stays bounded. The sub-agent does the heavy lifting (file reads, gate runs, Playwright probes, report edits). This requires the driving CLI to support sub-agent spawning (`claude` does natively; `cursor-agent` falls back to in-context orchestration).

**Modes.** Per loop, the orchestrator picks one based on the current state of `.ralph/acceptance-report.md`:

- **VERIFIER** — independently checks every requirement (file reads, grep for conventions, Playwright MCP for UI behavior if available, gate runs under the `final` label). Records every unmet requirement as a `[ ]` line in the report's **Gaps** section. Only the verifier may flip the report's top-level `- [ ] All acceptance criteria met and verified` checkbox to `[x]`, and only after a clean independent pass.
- **REWORK** — works the verifier's Gaps list, resolving as many as possible and checking them off. Unresolvable ones get a `(blocked: reason)` suffix.

**Exit conditions.** Cleanly when the verifier flips the top-level checkbox. Otherwise at the loop cap (default 10; override with `--eval-loops N` or `RALPH_EVAL_MAX_LOOPS` env var — the older `--eval-iterations` flag is kept as a deprecated alias).

**Artifacts.**
- `.ralph/acceptance-report.md` — the report the orchestrator maintains. Git-ignored. Copy out after the loop exits if you want a persistent audit trail.
- `.ralph/eval-ground-truth` — breadcrumb recording which file served as ground truth for the last eval run.

**Template overrides (0.17.0).** A consuming project can reroute the eval loop through its own orchestrator without forking the loop machinery:
- `RALPH_EVAL_FRAMING_TEMPLATE` — replaces `templates/evaluator-framing.md`. Point it at a framing that invokes the project's own orchestrator skill (e.g. a ticket-based verify/rework flow). Rendered with `{{GROUND_TRUTH_PATH}}` and `{{REPORT_PATH}}`.
- `RALPH_EVAL_REPORT_TEMPLATE` — replaces `templates/acceptance-report-template.md` as the `seed_report` source. Rendered with `{{GROUND_TRUTH_PATH}}` only. The seeded report must keep the checkbox contract: the loop's task-counter treats every `- [ ]` / `- [x]` line as completion state, and `RALPH_EVAL_LOOP=1` still requires a fresh green `final`-tier gate at COMPLETE.

Both accept absolute paths or paths relative to the workspace root, and fail loudly when set but unreadable (no silent fallback to stock templates). Both are ordinary env vars, so they survive the `ralph-setup.sh --evaluate` chain into `ralph-evaluate.sh` when set in the launching environment.

**Limitations.**
- **Sub-agent support depends on the driving CLI** (above).
- **UI verification requires Playwright MCP.** When the MCP server isn't installed, the verifier notes the limitation in the relevant gap rather than silently skipping UI requirements.
- **The verifier is only as good as the ground-truth requirements.** Vague requirements in `PROMPT.md` produce vague gap reports.

## Prompt generation deep details

When the project has `.claude/skills/speckit-implement/SKILL.md` (or the legacy `.claude/commands/speckit.implement.md`), Ralph **generates the loop prompt from it** rather than using the static fallback. This keeps the loop in sync with your version of Spec Kit.

The generation:

1. Computes the SHA-256 of the source skill.
2. Compares to the cached hash at `<spec_dir>/.ralph-prompt-hash`.
3. On hash match: uses the cached prompt at `<spec_dir>/ralph-prompt.md` directly.
4. On hash miss (or no cache): invokes `claude -p --model sonnet --effort medium` with the adaptation guide (`shared-references/templates/speckit-adaptation-guide.md`) plus the source skill, expecting an adapted prompt back. Caches the result + new hash. Commits both files.
5. The cached prompt is then rendered through `_render_template`: placeholders like `{{TASK_FILE}}`, `{{GATE_RUN}}`, `{{ACTIVITY_TAIL}}` get substituted. Final output goes to `.ralph/effective-prompt.md`, which is what the agent sees on every loop.

Override knobs:
- `RALPH_SKIP_GENERATION=1` — force use of the built-in fallback template.
- `RALPH_TEMPLATES_DIR=...` — point at a different templates directory (useful when developing the plugin itself).
- `RALPH_EXTRA_PLUGIN_DIRS=path1:path2` — append extra `--plugin-dir` flags to the claude invocation. The setup script auto-populates this for Playwright when detected.

## Project layout

```
ralph-wiggum-plugin/
├── .claude-plugin/
│   └── plugin.json              # Single source of truth for version
├── commands/                    # Slash commands (/ralph, /ralph-once, /ralph-evaluate, /ralph-cancel)
├── skills/                      # Plugin skills (eval loop + maintenance)
│   ├── running-acceptance-evaluation/SKILL.md
│   ├── verifying-acceptance-criteria/SKILL.md
│   ├── addressing-acceptance-gaps/SKILL.md
│   └── ralph-plugin-speckit-update/SKILL.md
├── shared-scripts/              # The actual loop machinery
│   ├── ralph-setup.sh           # Interactive launcher
│   ├── ralph-loop.sh            # Scripted launcher
│   ├── ralph-common.sh          # Shared functions
│   ├── stream-parser.sh         # Reads agent stream-json, emits signals
│   ├── prompt-resolver.sh       # Resolves & renders the effective prompt
│   ├── agent-adapter.sh         # CLI-agnostic invocation layer
│   ├── gate-run.sh              # Verification-gate wrapper
│   ├── ralph-evaluate.sh        # Acceptance evaluator
│   ├── ralph-status.sh          # Operator status snapshot
│   └── ralph-retry.sh           # DEFER retry orchestration
├── shared-references/templates/
│   ├── speckit-prompt.md        # Cache-miss fallback for spec mode
│   ├── speckit-adaptation-guide.md  # Transformation rules for generation
│   ├── loop-guardrails.md       # Universal preamble (anti-patterns)
│   ├── evaluator-orchestrator.md
│   ├── evaluator-verifier-role.md
│   └── evaluator-rework-role.md
├── docs/
│   ├── development.md           # This file
│   ├── skills.md                # Per-skill operator reference
│   └── gate-run.md              # Gate-runner full reference
├── tests/                       # bats-core test suites
└── lint.sh                      # Pipeline: shellcheck → shfmt → bats
```
