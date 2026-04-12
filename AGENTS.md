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

## Pre-commit hook

A git pre-commit hook (`.githooks/pre-commit`) enforces these checks on staged `.sh` files. It is wired up via `git config core.hooksPath .githooks`.

## Testing

Behavioral tests use [bats-core](https://github.com/bats-core/bats-core). Install: `brew install bats-core`.

- All behavioral changes must include tests in `tests/*.bats`
- Run `bats tests/` to execute, or `./lint.sh` (runs tests if bats available)
- Tests verify **behavior** (exit codes, output signals, file creation) — not implementation details
- Mock workspaces are created in `$BATS_TMPDIR` for isolation
- Shared fixtures are in `tests/test_helper.bash` — source via `load test_helper`
- Tests that call the API use `RALPH_SKIP_GENERATION=1` to skip and supply fixture prompts

## Prompt Architecture

The prompt sent to the agent has two layers:

1. **Framing** (`build_prompt()` in `ralph-common.sh`, ~25 lines) — iteration awareness, state file reading, signals, loop hygiene. Keep this under 30 lines.
2. **Body** (`.ralph/effective-prompt.md`) — the task execution instructions. In Spec Kit mode, this is generated from `speckit.implement.md` via the adaptation guide.

Key rules:
- The adaptation guide at `shared-references/templates/speckit-adaptation-guide.md` is the durable recipe for transforming speckit.implement into a loop prompt
- Generated prompts should stay under 120 lines
- Never duplicate guidance that belongs in the project's constitution (naming conventions, architecture rules, etc.)
- The framing and body should not have competing instruction sets — if both cover the same topic (git protocol, error handling), keep it in one place only

## Shell conventions

- All scripts use `#!/bin/bash` and `set -euo pipefail`
- Use `local` for function variables; declare and assign separately (`local x; x=$(cmd)`)
- Guard `cd` with `|| return` or `|| exit`
- Use `read -r` to prevent backslash mangling
- Single-quote trap strings to defer variable expansion
