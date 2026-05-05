# gate-run.sh — the gate-runner wrapper

`shared-scripts/gate-run.sh` is a thin, project-agnostic shell wrapper for running **verification gates** (tests, lint, build, E2E, whatever your project uses to confirm changes are green). It exists because:

- A gate run bare either overwhelms the terminal scrollback or, worse, a coding agent's context window. The agent then re-runs the gate to see more output — burning minutes per retry for zero new information.
- Piping (`| grep`, `| tail`, `> /tmp/…`) hides exit codes and breaks `pipefail`, so downstream logic (CI steps, loop completion guards) misreads red as green.
- Most agent harnesses lack a durable place to store full run output. Without persistence, failure diagnosis means "run it again with `VERBOSE=1`."

The wrapper solves all three in one call.

## Why an autonomous-loop agent should care

If you are driving this plugin's Ralph loop, your prompt framing already points at the wrapper. **Read this file once** to internalize the protocol; afterwards the inline reminders in your loop prompt are enough.

If you are not in Ralph and just reading this because you landed here from the README or a grep result, the wrapper is still useful standalone — `gate-run.sh basic pnpm test` gives you the same benefits.

## Usage

```bash
gate-run.sh <label> <cmd> [args...]
gate-run.sh -h | --help
```

### Labels

Fixed set. Pick the closest match; use `custom` for anything that doesn't fit.

| Label    | Typical use                                                        | Default timeout |
| -------- | ------------------------------------------------------------------ | --------------- |
| `basic`  | Fast pre-commit gate (format, lint, unit tests)                    | 300 s           |
| `final`  | Full verification (basic + integration + E2E)                      | 900 s           |
| `e2e`    | Targeted E2E, browser, or container suites                         | 300 s           |
| `lint`   | Lint-only or type-check-only runs                                  | 300 s           |
| `custom` | Anything outside the four above                                    | 300 s           |

Each label gets its own artifact namespace — so `basic` and `final` don't overwrite each other's `-latest.log` or `-latest.exit`.

### Exit codes

- `0` — the wrapped command succeeded.
- `N≠0` — the wrapped command exited `N`. Passed through verbatim via `PIPESTATUS`.
- `64` — usage error (missing args, invalid label).
- `124` — timed out (matches the GNU/BSD `timeout` convention).

The wrapper **always** reflects the real status of the wrapped command, even when `tee` succeeds and the command fails.

## What it produces

For a call like `gate-run.sh basic pnpm test` inside a workspace at `$WS`:

```
$WS/.ralph/gates/
├── basic-20260420T103045Z.log   # full output, one per run
├── basic-20260420T104211Z.log
├── basic-latest.log              # symlink to most recent (copy on FAT32)
├── basic-latest.exit             # single decimal, no newline — the exit code
└── activity.log                  # best-effort one-liner per gate (shared)
```

**Stdout** from the wrapper call itself is a compact summary:

```
=== gate-run label=basic ts=20260420T103045Z cwd=/abs/path ===
=== cmd: pnpm test
===
<…live streamed tee output during the run…>
=== GATE basic exit=1 duration=12s log=.ralph/gates/basic-20260420T103045Z.log latest=.ralph/gates/basic-latest.log ===
--- tail (last 60 lines) ---
<last 60 lines of the combined stream>
--- failing-tests (first 80 matches) ---
<line-numbered grep matches for common failure signatures>
=== END GATE ===
```

Configurable via `RALPH_GATE_TAIL` (default 60) and `RALPH_GATE_FAIL_HEAD` (default 80). Set either to 0 to suppress that block.

## Environment variables

| Variable                   | Default              | Meaning                                                                          |
| -------------------------- | -------------------- | -------------------------------------------------------------------------------- |
| `RALPH_WORKSPACE`          | `$PWD`               | Workspace root. Logs land under `$RALPH_WORKSPACE/.ralph/gates/`.                |
| `RALPH_GATES_DIR`          | `$WS/.ralph/gates`   | Full override for the log directory.                                             |
| `RALPH_GATE_KEEP`          | `10`                 | How many timestamped logs to keep per label. 0 keeps everything (be careful).    |
| `RALPH_GATE_TAIL`          | `60`                 | Lines of tail included in the summary.                                           |
| `RALPH_GATE_FAIL_HEAD`     | `80`                 | Failure-match lines in the summary.                                              |
| `RALPH_GATE_TIMEOUT`       | *(unset)*            | Blanket timeout override (seconds). Wins over the per-label vars below.          |
| `RALPH_FINAL_GATE_TIMEOUT` | `900`                | Timeout when `label=final`.                                                      |
| `RALPH_BASIC_GATE_TIMEOUT` | `600`                | Timeout for every other label.                                                   |

The timeout mechanism prefers GNU `timeout`, falls back to `gtimeout` (macOS via `brew install coreutils`), and degrades to no timeout if neither is installed. The degraded case is explicit — the wrapper does not pretend to enforce a limit it can't.

## Failure-pattern matching

After each run the wrapper greps the full log for common failure signatures and prints up to `RALPH_GATE_FAIL_HEAD` line-numbered matches. The current regex targets Node-ecosystem tooling:

```
^\s*(FAIL|✗|× |Error:|AssertionError|TypeError|ReferenceError|SyntaxError|\s+at\s|expected|Expected|    [0-9]+\)|ERROR in|error TS[0-9]+|error\s+@|✖ )
```

This catches the signal-rich lines for:

- **Vitest / Jest** — `FAIL`, `AssertionError`, `TypeError`, expected/received, stack frames (`at …`).
- **Cypress / Mocha** — `✗`, `× `, `    1)` numbered failures.
- **TypeScript** — `error TS1234`, `ERROR in`.
- **ESLint** — `error  @<rule>`, `✖ N problems`.
- **NestJS / Node generic** — `Error:`, stack frames.

### What it will **not** catch

The regex is Node/TS-biased. These ecosystems need a different pattern set (either tail the log directly or wrap the script):

| Tool          | Representative failure lines                                   |
| ------------- | -------------------------------------------------------------- |
| Rust / cargo  | `thread '.*' panicked at …` · `test result: FAILED`            |
| Go            | `--- FAIL: TestName (0.01s)` · `FAIL\t./pkg`                   |
| Python pytest | `FAILED tests/test_x.py::…` · `Traceback (most recent call last):` · `^E   AssertionError` |
| Ruby RSpec    | `Failures:` · `  Failure/Error:` · `^rspec ./spec/…`           |
| Elixir        | `** (AssertionError)` · `1 failure`                            |

If you adopt the wrapper in a project that uses one of these, either:

1. Skip the failure-match block (set `RALPH_GATE_FAIL_HEAD=0`) and read the tail / full log directly, or
2. Wrap `gate-run.sh` with a thin shell function that `grep`s the log with your own pattern after it returns.

A `RALPH_GATE_FAIL_REGEX` env hook may land in a future release if demand justifies it.

## Agent protocol (read this once, then follow it)

This is the discipline that makes the wrapper pay off. Skipping it is why agents end up running the same gate three or four times.

### 1. Run every gate via the wrapper — no exceptions, no piping.

```bash
# ✅ Good
bash .claude/ralph-scripts/gate-run.sh basic pnpm basic-check
bash .claude/ralph-scripts/gate-run.sh final pnpm all-check

# ❌ Bad — breaks exit code, forces re-runs
pnpm basic-check | tail -50
pnpm all-check 2>&1 | grep -i fail
pnpm test > /tmp/out
```

The wrapper already prints a bounded summary and persists the full log. Piping removes both benefits and hides the exit code.

### 2. When a gate fails — do NOT re-run it.

The summary you already saw, plus the persisted log at `.ralph/gates/<label>-latest.log`, contains everything you need.

**Read the log with targeted, bounded reads:**

- `Read .ralph/gates/final-latest.log` — first 2000 lines (usually covers the failure block and the tail).
- `Read .ralph/gates/final-latest.log` with `offset=500 limit=200` — slice around a specific region.
- `Grep pattern="^\s*(FAIL|✗|×)" path=.ralph/gates/final-latest.log` — list failing test titles.
- `Grep pattern="AssertionError|Error:" path=.ralph/gates/final-latest.log -A 5` — error sites with context.
- `Grep pattern="error TS[0-9]+" path=.ralph/gates/final-latest.log` — TypeScript errors.

Prefer the `Grep` tool over a shell `grep` in a second process — it produces cleaner, cheaper output.

Fix the smallest thing that could be wrong, then re-run the gate **once**. Two consecutive gate runs without any edits in between is a wasted cycle — the result will be identical.

### 3. When a gate passes — do NOT re-read the log.

The summary you already saw ended with `exit=0`. That is authoritative. Commit and move on.

Re-reading a green gate log is the second-most common waste pattern (after blind re-runs). The persisted log exists for the failure-diagnosis path only.

### 4. The exit-code breadcrumb is for automation, not agents.

`.ralph/gates/<label>-latest.exit` is a single-decimal breadcrumb read by Ralph's completion guard (`_complete_allowed` in `ralph-common.sh`) to refuse `<promise>ALL_TASKS_DONE</promise>` when the most recent gate was red. It is not something an agent needs to `cat` or `Read` — the summary line `exit=<N>` is the same fact in a more readable form.

## Integration notes

### In Spec Kit loops

Prompts generated from the `speckit-implement` skill get a `{{GATE_RUN}}` placeholder resolved to `bash /abs/path/to/gate-run.sh`. The built-in `shared-references/templates/speckit-prompt.md` has the full gate-invocation contract; loops using the generated prompt inherit the same rules via the adaptation guide at `shared-references/templates/speckit-adaptation-guide.md`.

### In non-Spec Kit loops

The `build_prompt()` framing in `ralph-common.sh` auto-detects `gate-run.sh` sitting next to it and injects a compact `## Gate Runner` section into every loop prompt. Custom-prompt and `PROMPT.md` loops therefore get the same "don't pipe, don't re-run to verify" guidance that Spec Kit loops do.

### Standalone (no Ralph)

You can invoke the wrapper outside the loop entirely. Install it via `install.sh` (drops it at `.claude/ralph-scripts/gate-run.sh`) and call it from your shell, your CI, or a git hook:

```bash
bash .claude/ralph-scripts/gate-run.sh basic pnpm basic-check
echo $?  # exits with the real command status
```

The `.ralph/gates/` directory name is hard-coded today (modulo `RALPH_GATES_DIR`) — a standalone user inherits that convention. If that bothers you, set `RALPH_GATES_DIR=.test-output/gates` or similar and the wrapper respects it.

## Portability notes

The wrapper is written for **bash 3.2** (the default on macOS) — no `mapfile`, no `${var@Q}`, no associative arrays. It has been tested under both GNU (Linux) and BSD (macOS) userspace. The inline comments in `gate-run.sh` call out specific portability tradeoffs (symlink → copy fallback, portable UTC date, `read`-loop instead of `mapfile`).

## See also

- `gate-run.sh --help` — the same surface in a condensed form, always in sync with the shipping script.
- `shared-scripts/gate-run.sh` — the implementation. Header doc-comment is the source of truth for env vars and exit codes.
- `shared-references/templates/speckit-prompt.md` §"Gate invocation contract" — the Spec Kit-specific version of the agent protocol.
- `tests/gate-run.bats` — behavioral tests (exit codes, timeouts, log retention, breadcrumbs).
