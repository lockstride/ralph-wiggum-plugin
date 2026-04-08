# Ralph × Spec Kit: Phase-Level Implementation

You are executing a Spec Kit spec using the Ralph methodology. The unit of
work for one iteration is an **entire Spec Kit phase**, not a single task.
Assume you are running unattended in a clean worktree on a 1M-context model.

## Paths (resolved by the loop)

- **Spec directory**: `{{SPEC_DIR}}` (`{{SPEC_NAME}}`)
- **Constitution**:   `{{CONSTITUTION_PATH}}`
- **Spec**:           `{{SPEC_FILE}}`
- **Plan**:           `{{PLAN_FILE}}`
- **Tasks**:          `{{TASK_FILE}}`
- **Basic check**:    `{{BASIC_CHECK_COMMAND}}` — fast per-task gate (no e2e)
- **Final check**:    `{{FINAL_CHECK_COMMAND}}` — full gate, run at phase boundaries and before completion

## Read order (targeted, not full-file)

1. **Constitution** — scan for any rules that affect this phase. Skip sections irrelevant to the current phase.
2. **Spec** — read only the user story or section this phase implements.
3. **Plan** — read only the architectural slice (module layout, tech decisions) this phase touches.
4. **Tasks** — find the next unchecked phase. Read the tasks belonging to *that phase only*. Use `grep -n '^## Phase'` and narrow `Read` ranges; do not slurp the whole file.

Each iteration is a fresh process with no memory of prior iterations. Rely on `git log`, `tasks.md` checkboxes, and the current code state — **not** on a narrative of what you "already read."

## One-phase-per-iteration rule (hard)

- **Pick the next unchecked phase** in `{{TASK_FILE}}`. A "phase" is a `## Phase N: …` section (Setup, Foundational, or a single user story US1/US2/…).
- **Work every unchecked task in that phase** within this iteration. Do not stop after a single task and do not skip to the next phase until every task in the current phase is checked and the phase gate is green.
- If `{{TASK_FILE}}` contains ultra-fine-grained atomic TDD pairs (e.g. `Write failing test for X` followed by `Implement X`), **batch them**: write the failing test and the implementation in the same iteration, producing one commit per conceptual unit. Do not split those pairs across iterations.
- If the entire phase is genuinely too large to fit in one iteration (rare — the 1M-context window can hold an entire user story), complete as many contiguous tasks as you can, commit your progress, and stop. The next iteration will pick up from your last commit.

## Task execution loop (inside a phase)

For each unchecked task in the phase, in order:

1. **Understand** — read only the files the task references.
2. **Implement** — make the minimum change. For test+implementation pairs, write the failing test first (TDD red), then the implementation (green), all in this iteration.
3. **Per-task gate** — run `{{BASIC_CHECK_COMMAND}}`. This is a fast smoke test (no e2e). **It must pass before you mark the task `[x]`.** If it fails, you caused the failure — diagnose and fix it in this iteration. Do not mark the task complete with a red basic check.
4. **Checklist gate** — scan `{{SPEC_DIR}}/checklists/` for unchecked items that block this task. If any exist, flag them in `.ralph/errors.log` and stop (do not mark complete).
5. **Mark complete** — edit `{{TASK_FILE}}` and change `[ ]` → `[x]` for this task.
6. **Commit** — `git commit -m "[ralph][speckit] T### <task title>"`. Use the real task ID and title. See Git Protocol below — **never include `.ralph/` paths**.
7. **Continue** to the next task in the same phase. Do not stop until the phase is complete or you are genuinely blocked.

## Phase completion protocol

After every task in the current phase is checked:

1. Run `{{FINAL_CHECK_COMMAND}}`. This is the full gate (includes e2e). It **must** pass.
2. If it fails: the phase is not complete. Diagnose and fix the regression in this same iteration before moving on. Never mark a phase complete with a red final check.
3. When it passes, commit any residual changes with `git commit -m "[ralph][speckit][phase-N] <phase title> complete"`.
4. Push if you have ≥ 2 unpushed commits: `git push`.

## Zero-baseline assumption (critical)

`main` is green. There are **no** pre-existing test failures, lint errors, or build breaks. Any failure you observe in `{{BASIC_CHECK_COMMAND}}` or `{{FINAL_CHECK_COMMAND}}` is a regression introduced by the in-progress refactor — yours or an earlier iteration's. **You must fix it in this iteration.** Do not:

- Assume failures are "pre-existing" and ignore them.
- Mark a task or phase complete while tests are red.
- Use `--no-verify`, `--skip-tests`, or any other bypass.
- Leave TODO comments to "fix later." Fix now.

## Git Protocol (hard rules)

1. **Never `git add .ralph/…`**. `.ralph/` is gitignored and `git add` on ignored paths fails with exit 1, aborting the whole commit. This is the single most common failure mode of past loops. Commit only source files, `tasks.md`, and other non-ignored content.
2. Write progress notes **directly** to `.ralph/progress.md` with the `Write`/`Edit` tool. Never via commits.
3. Commit after every completed task (not at the end of the phase). Each commit is a checkpoint the next iteration can resume from.
4. Never include `Co-authored-by` trailers. The commit message format is exactly `[ralph][speckit] T### <task title>`.
5. Never use `--amend`, `--force`, `reset --hard`, or any destructive git operation. If something went wrong, make a new commit that fixes it.
6. Push after every ~3 commits.

## Constitution compliance

Ground every decision in `{{CONSTITUTION_PATH}}`. If a task would violate it, mark the task blocked (see Blocked-phase protocol) and stop — do not work around the constitution.

## Blocked-phase protocol

If you cannot complete a task or phase:

- Append `<!-- blocked: <one-line reason> -->` to the blocking task's line in `{{TASK_FILE}}`.
- Write a longer explanation to `.ralph/errors.log` with the task ID, what you tried, and what the human needs to decide.
- Do **not** mark `[x]` for the blocked task.
- If ≥ 2 tasks in the current phase are blocked, or the phase is structurally impossible, emit `<ralph>GUTTER</ralph>` so the human is pulled in.

## Completion protocol

- When every `[ ]` in `{{TASK_FILE}}` is checked **and** `{{FINAL_CHECK_COMMAND}}` passes, emit `<promise>ALL_TASKS_DONE</promise>`.
- The stream parser will re-scan `{{TASK_FILE}}` before honoring the promise. Do not emit the sigil unless the checkboxes actually show completion — a hallucinated promise wastes an iteration.

## Commit message format

`[ralph][speckit] T### <task title>` — T### is the real task ID from `{{TASK_FILE}}` (e.g. `T027`). Never use placeholders like `<description>` or `TODO`. Phase-completion commits use `[ralph][speckit][phase-N] <phase title> complete`.

## Working directory

You are already in a git repository. Do **not**:
- run `git init`
- run scaffolding commands that create nested directories
- create worktrees or branches unless the task explicitly asks

Work in the current directory.

## Learning from failure

If a step fails, check `.ralph/errors.log` and `.ralph/guardrails.md` for a pattern. If the same failure has happened before, add a `Sign` to `.ralph/guardrails.md` describing the trigger and the fix. The next iteration will read it.

---

Begin by finding the next unchecked phase in `{{TASK_FILE}}` and working every task in that phase end-to-end.
