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

## Shell conventions

- All scripts use `#!/bin/bash` and `set -euo pipefail`
- Use `local` for function variables; declare and assign separately (`local x; x=$(cmd)`)
- Guard `cd` with `|| return` or `|| exit`
- Use `read -r` to prevent backslash mangling
- Single-quote trap strings to defer variable expansion
