# Ralph × Spec Kit: Run-to-Completion Implementation

You are executing a Spec Kit spec inside the Ralph loop.

## Paths (resolved by the loop)

- **Spec directory**: `{{SPEC_DIR}}` (`{{SPEC_NAME}}`)
- **Constitution**:   `{{CONSTITUTION_PATH}}`
- **Spec**:           `{{SPEC_FILE}}`
- **Plan**:           `{{PLAN_FILE}}`
- **Tasks**:          `{{TASK_FILE}}`
- **Basic check**:    `{{BASIC_CHECK_COMMAND}}`
- **Final check**:    `{{FINAL_CHECK_COMMAND}}`
- **Gate runner**:    `{{GATE_RUN}}` — invoke ALL gates through this wrapper. See the `running-gates` skill for the contract.

## Per-task flow

For each unchecked task:

1. Read the task and the relevant source files.
2. Make the minimum change.
3. Run a gate via `{{GATE_RUN}}` (see `running-gates` for label selection).
4. Confirm green, mark `[x]`, commit.
5. Your next tool call is the read of the next unchecked task.

## Zero-baseline assumption

`main` is green. Any failure in `{{BASIC_CHECK_COMMAND}}` or
`{{FINAL_CHECK_COMMAND}}` is a regression introduced by the in-progress
refactor. Fix it. Don't assume failures are pre-existing.

## Loop handoff

`.ralph/handoff.md` is your navigation breadcrumb.

**At loop start**, if `.ralph/handoff.md` exists and is fresher than
the latest commit, read it first.

**At turn end**, write `.ralph/handoff.md` (under 30 lines,
navigation-only — no narrative):

```markdown
## Last completed
<task ID> (<commit SHA short>) — <one-line summary>

## Next task: <task ID>
**Read these files first** (max 6):
- <relative path>:<line range>  ← <why>

## Architectural facts (max 5 bullets)
- <one fact, declarative>
```

## Recent activity

`{{ACTIVITY_TAIL}}`

## Git protocol

1. `git add <exact paths>` only. Never `.` / `-A` / `<directory>`.
2. Never `git add` a `.gitignore`'d path (`.ralph/`, `dist/`, etc.).
3. Commit after every completed task.
4. No `Co-authored-by` or agent-identifying footers.
5. No `--amend`, `--force`, `reset --hard`.
6. {{PUSH_GUIDANCE}}

## Commit message format

Conventional Commits: `<type>(<scope>): <short description> (T###)`

## Constitution compliance

Ground every decision in `{{CONSTITUTION_PATH}}`. If a task would
violate it, mark the task blocked and stop.

## Completion

When every `[ ]` in `{{TASK_FILE}}` is checked AND `{{GATE_RUN}}
final {{FINAL_CHECK_COMMAND}}` exits 0, emit
`<promise>ALL_TASKS_DONE</promise>`.

---

Begin by reading `.ralph/handoff.md` if it exists, then continue
from the first unchecked task in `{{TASK_FILE}}`.
