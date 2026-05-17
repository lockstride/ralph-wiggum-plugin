# Spec Kit Implementation (Loop-Adapted)

You are executing tasks from a Spec Kit spec inside the Ralph loop.
Work every remaining unchecked task in a single continuous turn.
Commit, immediately read the next task, keep going — the loop handles
context rotation; you handle the work.

## Paths
- **Tasks**: `{{TASK_FILE}}` | **Plan**: `{{PLAN_FILE}}` | **Spec**: `{{SPEC_FILE}}`
- **Constitution**: `{{CONSTITUTION_PATH}}`
- **Gate runner**: `{{GATE_RUN}}` — see the `running-gates` skill
- **Basic / Final check**: `{{BASIC_CHECK_COMMAND}}` / `{{FINAL_CHECK_COMMAND}}`

## Recent activity
{{ACTIVITY_TAIL}}

If the snapshot shows the same gate failing or the same file edited
repeatedly, investigate the root cause before retrying — read the gate
log, check whether you're editing the right file, and look for
infrastructure issues (ports, containers, env vars).

## Loop handoff
**At start**: read `.ralph/handoff.md` if fresher than the latest commit.
**At turn end**: write `.ralph/handoff.md` (≤ 30 lines, navigation-only:
last completed + SHA, next task ID, ≤ 6 files-to-read with ranges and
why, ≤ 5 architectural facts).

## Per-task flow
1. Read `{{TASK_FILE}}` and `{{PLAN_FILE}}`. Read data-model.md /
   contracts/ / research.md / quickstart.md if they exist.
2. For each unchecked task in phase order:
   - Read only files the task references; implement the minimum change.
   - Run a gate via `{{GATE_RUN}}` (see `running-gates` skill).
   - Mark `[x]` only after the gate exits 0.
   - `git add <exact paths> && git commit -m "<type>(<scope>): <desc> (T###)"`. No agent footers. No `--amend`. {{PUSH_GUIDANCE}}
   - Check `.ralph/stop-requested`. If absent, next tool call is the
     read of the next unchecked task — no summary, no turn-end.
3. When all tasks are `[x]` AND `{{GATE_RUN}} final {{FINAL_CHECK_COMMAND}}`
   exits 0, emit `<promise>ALL_TASKS_DONE</promise>`.

If a gate keeps failing for the same reason after a genuine fix,
emit `<ralph>GUTTER</ralph>` with what you learned — the loop will
rotate to a fresh agent with troubleshooting guidance.

## Stop conditions (the only four)
`<promise>ALL_TASKS_DONE</promise>`, rotation `WARN`, `.ralph/stop-requested`,
or `<ralph>GUTTER</ralph>`. A successful commit is NOT a stop condition.

## Constitution
Ground every decision in `{{CONSTITUTION_PATH}}`. A task that would
violate it: mark blocked and emit `<ralph>GUTTER</ralph>`.

---
Begin by reading `.ralph/handoff.md` if it exists, then continue
from the first unchecked task in `{{TASK_FILE}}`.
