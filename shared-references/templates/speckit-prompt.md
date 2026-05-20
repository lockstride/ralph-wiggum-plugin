# Spec Kit Implementation (Loop-Adapted)

You are executing tasks from a Spec Kit spec inside the Ralph loop.
Work every remaining unchecked task in a single continuous turn.
Commit, immediately read the next task, keep going — the loop handles
context rotation; you handle the work.

## Paths
- **Tasks**: `{{TASK_FILE}}` | **Plan**: `{{PLAN_FILE}}` | **Spec**: `{{SPEC_FILE}}`
- **Constitution**: `{{CONSTITUTION_PATH}}`
- **Gate runner**: `{{GATE_RUN}}`
- **Basic gate**: `{{GATE_RUN}} basic {{BASIC_CHECK_COMMAND}}`
- **Final gate**: `{{GATE_RUN}} final {{FINAL_CHECK_COMMAND}}`

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
   - Run `{{GATE_RUN}} basic {{BASIC_CHECK_COMMAND}}`.
   - Mark `[x]` only after the gate exits 0.
   - `git add <exact paths> && git commit -m "<type>(<scope>): <desc> (T###)"`. No agent footers. No `--amend`. {{PUSH_GUIDANCE}}
   - Check `.ralph/stop-requested` or `.ralph/context-warning-active`.
     If either exists, write handoff and yield. If absent, next tool
     call is the read of the next unchecked task — no summary, no
     turn-end.
3. When all tasks are `[x]` AND `{{GATE_RUN}} final {{FINAL_CHECK_COMMAND}}`
   exits 0, emit `<promise>ALL_TASKS_DONE</promise>`.

If a gate fails, read `.ralph/gates/basic-latest.log` (or the
relevant label's log). Screenshots at `cypress/screenshots/` and
direct `curl` against endpoints are cheaper evidence than re-running.
After a genuine fix, if the gate still fails for the same reason,
emit `<ralph>GUTTER</ralph>` — the loop will rotate to a fresh agent.

## Stop conditions (the only four)
`<promise>ALL_TASKS_DONE</promise>`, `.ralph/context-warning-active` (yield for
rotation), `.ralph/stop-requested`, or `<ralph>GUTTER</ralph>`.
A successful commit is NOT a stop condition.

## Constitution
Ground every decision in `{{CONSTITUTION_PATH}}`. A task that would
violate it: mark blocked and emit `<ralph>GUTTER</ralph>`.

---
Begin by reading `.ralph/handoff.md` if it exists, then continue
from the first unchecked task in `{{TASK_FILE}}`.
