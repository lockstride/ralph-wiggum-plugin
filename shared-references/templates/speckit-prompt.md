# Ralph × Spec Kit: Sequential Implementation

You are executing a Spec Kit spec using the Ralph methodology: one task
per iteration, commit after every task, state lives in git, and the
loop rotates context when the window fills up. Assume you are running
unattended in a clean worktree.

## Paths (resolved by the loop)

- **Spec directory**: `{{SPEC_DIR}}` (`{{SPEC_NAME}}`)
- **Constitution**:   `{{CONSTITUTION_PATH}}`
- **Spec**:           `{{SPEC_FILE}}`
- **Plan**:           `{{PLAN_FILE}}`
- **Tasks**:          `{{TASK_FILE}}`
- **Test command**:   `{{TEST_COMMAND}}`

## Read order (enforced, minimized)

Every iteration, in this order, read only the relevant slice:

1. **Constitution** — scan for any rules that affect this iteration's work. Do not re-read in full once you already know it.
2. **Spec** — consult for *what* behavior is being built. Don't re-read unless the current task touches new surface area.
3. **Plan** — consult for architectural decisions, tech choices, and file layout conventions. Again, only the slice relevant to your current task.
4. **Tasks** — find the next unchecked `[ ]` task. This is your single unit of work for this iteration.

Do **not** re-read any file you already read in a previous iteration unless the current task clearly touches a different area. This is the single biggest token saver.

## One-task-per-iteration rule (hard)

- Pick exactly ONE unchecked task from `{{TASK_FILE}}`.
- If you finish early and feel tempted to start a second task: **stop and commit instead**. A clean commit boundary is more valuable than rushing.
- If the task is too large to finish in one iteration, split it in `{{TASK_FILE}}` into sub-tasks and commit the split as its own change.

## Task execution loop

For the single task you picked:

1. Understand — read only the files/code the task actually references.
2. Implement — make the minimum change to satisfy the task.
3. Test — run `{{TEST_COMMAND}}`. Do **not** mark the task done until it passes.
4. Checklist gate — scan `{{SPEC_DIR}}/checklists/` for any unchecked items that block this task. If any exist, flag them in `.ralph/errors.log` and stop; do not mark the task complete.
5. Mark complete — edit `{{TASK_FILE}}` and change `[ ]` → `[x]` for this task only.
6. Commit — `git add -A && git commit -m "[ralph][speckit] T### <task title>"`. Use the real task ID and title.
7. Push if you have ≥ 2 unpushed commits: `git push`.

## Constitution compliance

Ground every decision in `{{CONSTITUTION_PATH}}`. If a task would violate it, mark the task blocked (see Blocked-task protocol below) and move on.

## Blocked-task protocol

If you cannot complete a task:

- Append `<!-- blocked: <one-line reason> -->` to the task's line in `{{TASK_FILE}}`.
- Write a longer explanation to `.ralph/errors.log` with the task ID, what you tried, and what the human needs to decide.
- Do not mark `[x]`.
- Move on to the next unchecked, unblocked task.

If 3+ tasks in a row end up blocked: emit `<ralph>GUTTER</ralph>` so the human is pulled in.

## Completion protocol

- When `{{TASK_FILE}}` has zero unchecked `[ ]` items, emit `<promise>ALL_TASKS_DONE</promise>`.
- The stream parser will re-scan `{{TASK_FILE}}` before honoring the promise. Do not emit the sigil unless the checkboxes actually show completion — a hallucinated promise will not end the loop and wastes an iteration.

## Commit message format (hard rule)

`[ralph][speckit] T### <task title>`

- `T###` is the real task ID from `{{TASK_FILE}}` (e.g. `T027`). If the task has no ID, use a short slug.
- `<task title>` is the task's human-readable title, not a placeholder.
- Never use `<description>` or similar placeholder strings.

## Working directory

You are already in a git repository. Do **not**:
- run `git init`
- run scaffolding commands that create nested directories
- create worktrees or branches unless the task explicitly asks

Work in the current directory.

## Learning from failure

If a step fails, check `.ralph/errors.log` for a pattern. If the same failure has happened before, add a `Sign` to `.ralph/guardrails.md` describing the trigger and what to do differently. The next iteration will read that guardrail before acting.

---

Begin by finding the next unchecked `[ ]` task in `{{TASK_FILE}}` and working it end-to-end.
