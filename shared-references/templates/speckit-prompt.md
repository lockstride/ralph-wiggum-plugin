# Spec Kit Implementation (Loop-Adapted)

You are executing tasks from a Spec Kit spec inside the Ralph loop.
Work every remaining unchecked task in a single continuous turn.
Commit, immediately read the next task, keep going — the loop handles
context rotation; you handle the work.

> The framing above already lists the four stop conditions, the per-commit
> breadcrumb check, the handoff contract, and gate-runner usage. This body
> only describes the task-execution flow. Don't restate framing content.

## Paths
- **Tasks**: `{{TASK_FILE}}` | **Plan**: `{{PLAN_FILE}}` | **Spec**: `{{SPEC_FILE}}`
- **Constitution**: `{{CONSTITUTION_PATH}}`
- **Basic gate (per-task)**: `{{GATE_RUN}} basic {{BASIC_CHECK_COMMAND}}`
- **Full gate (on [risky] + end-of-loop completion)**: `{{GATE_RUN}} full {{FULL_CHECK_COMMAND}}`
- **Final gate**: reserved for the post-completion eval loop — do NOT run it from this loop.

## Per-task flow
1. Read the tasks file and the plan file. Read data-model.md /
   contracts/ / research.md / quickstart.md if they exist.
2. For each unchecked task in phase order:
   - Read only files the task references; implement the minimum change.
   - Run the basic gate.
   - Mark `[x]` only after the gate exits 0. A checked box claims you
     verified the work — if you cannot execute a task's verification in
     this environment (e.g. a visual review in an external design tool),
     leave it unchecked, record it as blocked in the handoff and
     `.ralph/errors.log`, and continue with the remaining tasks.
   - `git add <exact paths> && git commit -m "<type>(<scope>): <desc> (T###)"`. No agent footers. No `--amend`. {{PUSH_GUIDANCE}}
   - (The framing's `## After every commit` block governs what happens
     next — yield-if-breadcrumb OR read the next task.)
3. When all tasks are `[x]` AND the full gate exits 0,
   emit `<promise>ALL_TASKS_DONE</promise>`.

If a gate fails, read `.ralph/gates/<label>-latest.log` for the
output. Screenshots at `cypress/screenshots/` and direct `curl` against
endpoints are cheaper evidence than re-running. After a genuine fix,
if the gate still fails for the same reason, emit `<ralph>GUTTER</ralph>`
— the loop will rotate to a fresh agent.

## Constitution
Ground every decision in the constitution. A task that would violate
it: mark blocked and emit `<ralph>GUTTER</ralph>`.

---
The framing has already inlined `.ralph/handoff.md`. Do NOT re-read the
file — it may have been auto-enriched since the inline snapshot. Begin
from the first unchecked task.
