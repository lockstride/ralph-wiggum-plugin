# Agent Guidelines

## Language & Tools

This project is entirely Bash shell scripts. There is no JavaScript, TypeScript, or Node.js.

## Linting & Formatting

All `.sh` files must pass **shellcheck** and **shfmt** before commit.

After modifying any `.sh` file, run:

```
./lint.sh
```

To auto-format:

```
./lint.sh --fix
```

### shfmt style

- 2-space indentation (`-i 2`)
- Case body indentation (`-ci`)

### shellcheck

- Project config is in `.shellcheckrc`
- Use `# shellcheck disable=SCXXXX` inline with a reason when suppressing a warning
- Prefer fixing over suppressing

## Testing

Behavioral tests use [bats-core](https://github.com/bats-core/bats-core). Install: `brew install bats-core`.

- All behavioral changes must include tests in `tests/*.bats`
- Run `bats tests/` to execute, or `./lint.sh` (runs tests if bats available)
- Tests verify **behavior** (exit codes, output signals, file creation) — not implementation details
- Mock workspaces are created in `$BATS_TMPDIR` for isolation
- Shared fixtures are in `tests/test_helper.bash` — source via `load test_helper`
- Tests that call the API use `RALPH_SKIP_GENERATION=1` to skip and supply fixture prompts

### Completeness bar (hard rule)

**ALL tests in `tests/*.bats` must pass before any change is considered complete.** This is non-negotiable and applies to every commit, PR, release, or version bump. "Pre-existing failure" is never a valid excuse — if a test was red on `main` when you started, fixing it is part of your change (or you open a separate PR to fix it first). Do not:

- Ship a commit, tag, or release with any failing test
- Describe failures as "unrelated" and move on
- Bypass the pre-commit hook with `--no-verify` except when the environment genuinely cannot run bats (e.g. CI container missing the binary) — and document the reason in the commit body when you do
- Rely on "it passes under my preferred bash" — the pre-commit hook runs under `/bin/bash` explicitly so portability regressions are caught at commit time, not by downstream users

If a test is flaky or legitimately wrong, fix or delete it — do not tolerate it.

## Pre-commit hook

A git pre-commit hook (`.githooks/pre-commit`) enforces two gates on every commit:

1. **Shell lint** (shellcheck + shfmt) on staged `.sh` files, if any.
2. **Full bats test suite** runs on every commit regardless of what is staged. Tests are fast (< 10 s) and shell-script changes routinely ripple through shared helpers, so partial-run surgery isn't worth the risk of missed regressions.

The hook is wired up via `git config core.hooksPath .githooks`. It runs bats under `PATH="/bin:$PATH"` so the system bash (3.2 on macOS) is used — this matches the portability floor the project targets and catches bash-4+ feature usage before it reaches users.

Emergency bypass is `--no-verify`, but this should be rare and justified in the commit message (e.g. "CI environment missing bats-core; tests verified locally"). A commit that intentionally skips the gate must say so.

## Prompt Architecture

The prompt sent to the agent has two layers:

1. **Framing** (`build_prompt()` in `ralph-common.sh`) — owns the load-bearing instructions that must not drift:
   - `## Completion` — gate-must-be-green-before-`[x]` rule.
   - `## State Files` — pointer block (handoff.md is already inlined; don't re-read).
   - `## Stop conditions (the only four)` — `ALL_TASKS_DONE`, `stop-requested`, `context-warning-active`, `GUTTER`.
   - `## After every commit` — the three-bullet breadcrumb check (stop-requested → context-warning-active → next task).
   - `## Handoff before yielding` — what to write to `## Working set`.
   - `## Git hygiene` — never-amend, never-`git add .ralph/`.
   - `## Gate Runner` (conditional on `gate-run.sh` being present) — compact pointer; the hook does the wrapping.
   - `## Gate Selection` — basic-check default; all-check only for `[risky]` tasks.
   - `## Handoff from previous loop` (conditional on `handoff.md` existing) — inlined verbatim.

2. **Body** (`.ralph/effective-prompt.md`) — purely task-execution mechanics (Paths, Recent activity, Per-task flow, Constitution). In Spec Kit mode, generated from the project's `speckit-implement` skill via the adaptation guide. **Must NOT restate Stop conditions, After-every-commit, or Handoff** — those live in the framing (see adaptation guide rules 7, 12, 13).

Key rules:
- The adaptation guide at `shared-references/templates/speckit-adaptation-guide.md` is the durable recipe for transforming speckit-implement into a loop prompt.
- Generated body should stay under 40 lines (warned at 50 in `prompt-resolver.sh`).
- The framing and body must not have competing instruction sets. Stop / Handoff / After-commit live in the framing only. Project-specific stuff (naming conventions, architecture rules) belongs in the constitution, not either layer.
- Safety net: `_ensure_breadcrumb_checks` in `prompt-resolver.sh` injects an addendum if the generator paraphrased the breadcrumb-check language out of the body.

## Gate runner (`shared-scripts/gate-run.sh`)

First-class utility — treat changes to it with the same care as `ralph-common.sh`. The wrapper is what makes failure diagnosis in the loop tractable: it persists full output to `.ralph/gates/<label>-latest.log`, prints a bounded summary, and exits with the real command status.

- **User-facing reference:** [`docs/gate-run.md`](docs/gate-run.md) — labels, env vars, exit codes, failure patterns, what it does and does not catch, agent protocol.
- **Inline help:** `bash shared-scripts/gate-run.sh --help`. Keep the `_print_help()` block in sync with `docs/gate-run.md` and the header doc-comment. If you change behavior, update all three.
- **Loop integration:** `build_prompt()` in `ralph-common.sh` auto-detects the wrapper sitting next to it and injects a compact `## Gate Runner` section into every iteration prompt. Spec-Kit mode also surfaces it via the `{{GATE_RUN}}` placeholder in `shared-references/templates/speckit-prompt.md`. Both paths should stay consistent.
- **Completion guard dependency:** `_complete_allowed()` reads `.ralph/gates/<label>-latest.exit` to refuse `<promise>ALL_TASKS_DONE</promise>` when the most recent gate was red. Do not change the breadcrumb format (single decimal, no newline) without updating that guard.
- **Tests:** `tests/gate-run.bats`. Any behavioral change — exit codes, log layout, breadcrumb format, env-var semantics — must ship with a bats test.

## Shell conventions

- All scripts use `#!/bin/bash` and `set -euo pipefail`
- Use `local` for function variables; declare and assign separately (`local x; x=$(cmd)`)
- Guard `cd` with `|| return` or `|| exit`
- Use `read -r` to prevent backslash mangling
- Single-quote trap strings to defer variable expansion
