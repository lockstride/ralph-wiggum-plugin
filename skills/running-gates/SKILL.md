---
name: running-gates
description: Wraps verification gates (lint, test, build, e2e) for the Ralph autonomous loop with pipefail-safe execution, persisted logs, bounded summaries, and exit-code passthrough. Use when invoking any test/build/lint command inside the Ralph loop, or when diagnosing a failed gate. Replaces bare `pnpm`/`cargo`/`go test` calls with `gate-run.sh` so exit codes are not swallowed and full output is on disk for targeted reads. Covers the gate-invocation contract (no piping, single-retry budget, failure-diagnosis protocol) the agent must follow.
---

# Running gates

This skill governs **every verification command** the loop runs: pre-commit gates, phase-close gates, lint, e2e. It exists because bare commands swallow exit codes through pipes and force expensive re-runs to see more output. The wrapper fixes both.

## When to use

- Before every commit: run a single gate, confirm exit 0, then commit.
- After fixing a failure: re-run the gate **once**.
- Diagnosing a failed gate: read the persisted log, do **not** re-run.
- Ad-hoc verification (e.g. targeted e2e debugging): use `e2e` or `custom` label.

## How to invoke

Always use the wrapper, never the bare command. The wrapper is at `{{GATE_RUN}}` in the rendered prompt; the literal command is `bash <plugin-root>/shared-scripts/gate-run.sh`.

| Label | When | Example |
|---|---|---|
| `basic` | Per-task gate (fast: lint + unit tests) | `{{GATE_RUN}} basic {{BASIC_CHECK_COMMAND}}` |
| `final` | Phase-close or risky-task gate (full: includes integration + e2e) | `{{GATE_RUN}} final {{FINAL_CHECK_COMMAND}}` |
| `e2e` | Targeted e2e debugging | `{{GATE_RUN}} e2e pnpm test-e2e:local` |
| `lint` | Lint-only check | `{{GATE_RUN}} lint pnpm lint:check` |
| `custom` | Anything else | `{{GATE_RUN}} custom <cmd>` |

Run `{{GATE_RUN}} --help` for the full surface (env vars, exit codes, retention).

## Hard rules

### 1. Never pipe, never redirect, never filter.

The wrapper already tails to a bounded summary and writes the full log to `.ralph/gates/<label>-latest.log`. Forbidden suffixes on any gate invocation:

- `| tail …`, `| head …`, `| grep …`, `| awk …`, `| sed …`
- `> /tmp/…`, `>> …`, `| tee …`
- `2>&1 | anything`

If you catch yourself writing one of these, rewrite to the bare `{{GATE_RUN}} <label> <cmd>` form and use `Read`/`Grep` against the persisted log instead.

### 2. One gate per task, one retry per failure.

- Per task: at most one gate run before commit. **Do not re-run a passing gate "to be safe"** — a green gate is authoritative.
- If a gate fails: read the log, fix the smallest thing that could be wrong, re-run **once**.
- If it fails again after the fix: re-read the log, attempt one more iteration. If still failing after that, switch to the `diagnosing-stuck-tasks` skill rather than running a fourth time.
- Never run a gate before you've made any edits in this iteration. The prior commit was already green.

### 3. The wrapper's exit code is authoritative.

If the summary ends with `exit=0` the gate passed. If `exit=N` where N≠0, it failed — regardless of how the inline output looks. Do not second-guess.

### 4. Gate selection per task.

- **Final gate** if the task touches any of: package barrel exports, Prisma schema, NestJS module wiring, app bootstrap, `tsconfig.json` paths, auth/authorization middleware, **or this is the last unchecked task in the current phase**.
- **Basic gate** otherwise (pure unit tests, in-memory logic, docs, type-only changes, self-contained refactors that aren't the last task in the phase).
- **Never run both for the same code state** — final is a strict superset.

## Failure diagnosis protocol

When a gate exits non-zero:

1. **Do not re-run.** The log at `.ralph/gates/<label>-latest.log` has everything you need.
2. `Read` the log with `offset`/`limit` for targeted slices. Default: read the tail; for stack traces, jump to the line numbers in the bounded summary.
3. `Grep` the log for specific symptoms (use the Grep tool, not a shell `grep` subprocess):
   - `Grep pattern="^\s*(FAIL|✗|×)" path=".ralph/gates/<label>-latest.log"` — failing test titles
   - `Grep pattern="Error:|AssertionError" path=".ralph/gates/<label>-latest.log" -A 5` — error sites
   - `Grep pattern="error TS[0-9]+" path=".ralph/gates/<label>-latest.log"` — TypeScript errors
4. Fix the smallest thing that could be wrong.
5. Re-run via `{{GATE_RUN}}` exactly once. If still failing, escalate via the `diagnosing-stuck-tasks` skill.

## Post-gate-success protocol

When a gate exits 0:

1. Your **next** tool call MUST be `git status`.
2. Then `git add <explicit paths>` (never `git add .` / `git add -A` / `git add <directory>`).
3. Then `git commit -m "<type>(<scope>): <description> (T###)"` (Conventional Commits).
4. Do **not** Read or Grep the log after a passing gate. The wrapper already printed everything you need.

The single exception: if `git status` shows files you didn't intend to touch (orphans, IDE droppings, prior-iteration leftovers), surface them before committing.

## Browser-flow debugging (when available)

For UI / Cypress / Nuxt server-route failures, file-based reasoning may not be enough. If `mcp__playwright__*` tools are available in the agent surface (the loop wires Playwright in when installed), use them to:

- Open the failing page interactively
- Submit forms and inspect network requests
- Read DOM state directly

This often identifies proxy/routing/cookie issues faster than re-reading the Cypress error trace. If Playwright is not available, `curl` against the failing endpoint with the right headers can isolate whether the bug is in the proxy, the server route, or the browser layer.
