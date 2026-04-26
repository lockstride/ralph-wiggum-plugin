---
name: running-gates
description: Wraps verification gates (lint, test, build, e2e) for the Ralph autonomous loop with pipefail-safe execution, persisted logs, and bounded summaries. Use when invoking any test/build/lint command inside the Ralph loop, or when diagnosing a failed gate. Replaces bare `pnpm`/`cargo`/`go test` calls with `gate-run.sh` so exit codes are not swallowed and full output is on disk for targeted reads.
---

# Running gates

This skill governs **every verification command** the loop runs: pre-commit gates, phase-close gates, lint, e2e. Bare commands swallow exit codes through pipes and force expensive re-runs to see more output. The wrapper fixes both.

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

Pick `final` when the task touches risky areas (module wiring, schema, auth, barrel exports) or when it's the last unchecked task in a phase. Pick `basic` for everything else.

## The one hard rule

**Never pipe, redirect, or filter the gate command.** The wrapper already tails to a bounded summary and writes the full log to `.ralph/gates/<label>-latest.log`. Forbidden suffixes:

- `| tail`, `| head`, `| grep`, `| awk`, `| sed`
- `> /tmp/…`, `>> …`, `| tee`
- `2>&1 | anything`

If you catch yourself writing one of these, rewrite to bare `{{GATE_RUN}} <label> <cmd>` and use `Read` / `Grep` against the persisted log instead. The wrapper's exit code is authoritative — if the summary ends with `exit=0` the gate passed, regardless of how the inline output looks.

## When a gate fails

Understand why before doing anything else. The log at `.ralph/gates/<label>-latest.log` is one source of evidence. There are usually others:

- UI tests (Cypress, Playwright) write **screenshots** to `<project>/cypress/screenshots/<spec>/<test> (failed).png`. The image often shows the URL bar, the network panel, the page state — three layers of indirection collapsed into one glance. You can `Read` images directly.
- Network errors (`ECONNREFUSED`, timeouts) usually answer faster to a direct `curl` against the endpoint than to another full gate run.
- Container / port issues: `lsof -i :<port>` and `docker ps` tell you in seconds what a gate retry can't.
- Schema, migration, env-var failures: read the relevant config or `.env*` file rather than re-running.

Pick the cheapest evidence that answers your question. Re-running the same gate to "see if it's really broken" is the wrong move — the gate isn't lying.

## When a gate passes

Your next tool call should be `git status`, then `git add <explicit paths>` (never `git add .` / `git add -A` / `git add <directory>`), then commit with Conventional Commits format. Do not re-read the log after a passing gate — the summary printed everything you need.

If `git status` shows files you didn't intend to touch (orphans, IDE droppings, prior-loop leftovers), surface them before committing.

## When you're stuck

If you've made a real fix and the gate still fails for the same reason, you're probably looking at the wrong layer. Switch to the `diagnosing-stuck-tasks` skill — that's the explicit permission to step out of the procedural cycle and investigate however the situation actually demands.
