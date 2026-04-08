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
- **Basic check**:    `{{BASIC_CHECK_COMMAND}}` — fast gate (no e2e), used on most tasks
- **Final check**:    `{{FINAL_CHECK_COMMAND}}` — full gate (strict superset of basic check, includes e2e), used on risky tasks and at phase completion

Every task runs **exactly one** of these gates before commit — never both, never neither. `{{FINAL_CHECK_COMMAND}}` is a strict superset of `{{BASIC_CHECK_COMMAND}}`, so when you run the final check you have already satisfied the basic check.

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
2. **Implement** — make the minimum change. For test+implementation pairs, write the failing test first (TDD red), then the implementation (green), all in this task (red→green in one commit).
3. **Gate selection** — decide which single gate covers this task, based on what you touched:
   - **Run `{{FINAL_CHECK_COMMAND}}`** if this task (or the task spec line itself, tagged `[risky]`) touches any of:
     - Package barrel exports (`packages/*/src/index.ts`, `packages/*/index.ts`)
     - Prisma schema (`*.prisma`), Prisma seed, or DB constraint/seed loaders
     - NestJS module registration (`app.module.ts`, `imports:` arrays, new `*.module.ts` files wired into the app)
     - App bootstrap / entrypoints (`main.ts`, server entrypoints, Nuxt/Vue app roots)
     - `tsconfig.json` `include` / `exclude` / `paths`, or workspace-level `package.json` dependencies
     - Authentication, authorization middleware, or request-context builders
   - **Run `{{BASIC_CHECK_COMMAND}}`** otherwise — pure unit tests, in-memory logic, docs, type-only changes, self-contained refactors.
   - **Never run both.** `{{FINAL_CHECK_COMMAND}}` is a strict superset.
4. **Pre-commit gate** — the chosen gate **must pass before you commit**. If it fails, you caused the failure — fix it in place and re-run the same gate. Do not `git add` or `git commit` with a red gate. Do not commit and amend; fix first, commit once. Track in your own notes which gate you ran — the phase-completion protocol below uses this to skip a redundant run.
5. **Checklist gate** — scan `{{SPEC_DIR}}/checklists/` for unchecked items that block this task. If any exist, flag them in `.ralph/errors.log` and stop (do not mark complete).
6. **Mark complete** — edit `{{TASK_FILE}}` and change `[ ]` → `[x]` for this task.
7. **Commit** — `git commit -m "[ralph][speckit] T### <task title>"`. Use the real task ID and title. Stage only the files you touched for this task (see Git Protocol below — **never use `git add .` / `git add -A` / `git add <directory>`**).
8. **Continue** to the next task in the same phase. Do not stop until the phase is complete or you are genuinely blocked.

## Phase completion protocol

After every task in the current phase is checked:

1. **Decide whether the phase gate needs to run**:
   - If the **last task's gate was `{{BASIC_CHECK_COMMAND}}`**, run `{{FINAL_CHECK_COMMAND}}` now. The phase as a whole has not yet been verified at the full-gate level.
   - If the **last task's gate was `{{FINAL_CHECK_COMMAND}}`** (the final task of the phase was risky and self-gated), the phase is already verified — **skip the redundant run**.
2. If you ran the phase gate and it failed: the phase is not complete. Diagnose against the commits from this iteration (`git log --oneline -10`, `git show HEAD`, `git show HEAD~1`, etc.) and fix the regression in this same iteration before moving on. Never mark a phase complete with a red final check.
3. When the gate is green, commit any residual changes with `git commit -m "[ralph][speckit][phase-N] <phase title> complete"`. If there are no residual changes, skip this commit — every task already committed its own work.
4. Push if you have ≥ 2 unpushed commits: `git push`.

## Zero-baseline assumption (critical)

`main` is green. There are **no** pre-existing test failures, lint errors, or build breaks. Any failure you observe in `{{BASIC_CHECK_COMMAND}}` or `{{FINAL_CHECK_COMMAND}}` is a regression introduced by the in-progress refactor — yours or an earlier iteration's. **You must fix it in this iteration.** Do not:

- Assume failures are "pre-existing" and ignore them.
- Mark a task or phase complete while tests are red.
- Use `--no-verify`, `--skip-tests`, or any other bypass.
- Leave TODO comments to "fix later." Fix now.

## Git Protocol (hard rules)

1. **Stage files by exact path only.** Every `git add` call MUST list explicit file paths, e.g. `git add packages/utils/src/capabilities.ts apps/api/tests/unit/utils/capabilities.spec.ts`. **Never** use `git add .`, `git add -A`, `git add <directory>`, or any glob. Before every commit, run `git status` and verify the staged list matches exactly the files you edited or created for this task. If you see files you did not touch — especially untracked files in directories you weren't working in — **they are orphans from a prior iteration or a user stash, not yours**. Do not stage them. Do not commit them. If you're not sure whether a file is yours, `git diff --cached <file>` and check: if you don't recognize the content, `git reset HEAD <file>` to unstage and leave it untracked.
2. **Never `git add .ralph/…`**. `.ralph/` is gitignored and `git add` on ignored paths fails with exit 1, aborting the whole commit. Commit only source files, `tasks.md`, and other non-ignored content.
3. Write progress notes **directly** to `.ralph/progress.md` with the `Write`/`Edit` tool. Never via commits.
4. Commit after every completed task (not at the end of the phase). Each commit is a checkpoint the next iteration can resume from.
5. Never include `Co-authored-by` trailers. The commit message format is exactly `[ralph][speckit] T### <task title>`.
6. Never use `--amend`, `--force`, `reset --hard`, or any destructive git operation. If something went wrong, make a new commit that fixes it.
7. Push after every ~3 commits.

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
