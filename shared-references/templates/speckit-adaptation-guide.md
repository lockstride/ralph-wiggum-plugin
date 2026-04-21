# Spec Kit → Ralph Loop: Prompt Adaptation Guide

This guide transforms a `speckit.implement.md` slash command into a loop-compatible
prompt for unattended Ralph iterations. It contains durable transformation rules
and a concrete example pair.

## Transformation Rules

These rules describe the structural difference between interactive and unattended
execution. They are stable across versions of speckit.implement.md.

1. **Strip interactive features**: Remove user prompts, "STOP and ask", confirmation gates, and any step that waits for user input. In unattended mode there is no user to ask.
2. **Strip one-time project setup**: Remove ignore file creation/verification (step 4 in the outline), tech stack detection, and any project scaffolding. These are done once before the loop starts, not on every iteration.
3. **Strip extension hooks**: Remove all `.specify/extensions.yml` processing (before and after implementation hooks). Hooks require interactive slash command invocation.
4. **Strip the `$ARGUMENTS` / user input section**: The loop prompt replaces this with its own context.
5. **Replace "halt execution"**: Where the original says "halt" or "stop and ask", instead log the issue to `.ralph/errors.log` and emit `<ralph>GUTTER</ralph>` if structurally blocked.
6. **Keep the execution outline**: Preserve context loading (step 3), task parsing (step 5), phase-by-phase execution (steps 6-7), progress tracking (step 8), and completion validation (step 9). These are the core logic.
7. **Add iteration handoff**: Read `.ralph/handoff.md` at session start (if it exists and is fresh). Write it at session end (< 30 lines, navigation pointers only).
8. **Add gate wrapper**: All test/check commands must use `{{GATE_RUN}}` wrapper. Basic gate: `{{GATE_RUN}} basic {{BASIC_CHECK_COMMAND}}`. Final gate: `{{GATE_RUN}} final {{FINAL_CHECK_COMMAND}}`. Never pipe or redirect gate output.
9. **Add commit-per-task**: Commit after each completed task with `[ralph][speckit] T### <title>`. Stage files by explicit path only — never `git add .` or `git add -A`.
10. **Add completion signal**: `<promise>ALL_TASKS_DONE</promise>` when all tasks checked AND final gate passes.
11. **Add stuck signal**: `<ralph>GUTTER</ralph>` if stuck 3+ times on the same issue.
12. **Preserve `{{PLACEHOLDER}}` variables**: Keep `{{TASK_FILE}}`, `{{PLAN_FILE}}`, `{{SPEC_FILE}}`, `{{CONSTITUTION_PATH}}`, `{{GATE_RUN}}`, `{{BASIC_CHECK_COMMAND}}`, `{{FINAL_CHECK_COMMAND}}` as-is — the loop substitutes them later.
13. **Total output must stay under 120 lines.**

---

## Example Pair

### Input: speckit.implement.md (v0.6.1)

The source skill at this version has this structure:
- Pre-execution checks (hooks) — **strip**
- Outline steps 1-10:
  - Step 1: Run check-prerequisites.sh — **keep** (simplified)
  - Step 2: Check checklists — **keep** (replace interactive gate with log+continue)
  - Step 3: Load context — **keep**
  - Step 4: Project setup verification — **strip** (one-time setup)
  - Step 5: Parse tasks.md — **keep**
  - Step 6-7: Execute implementation — **keep** (core logic)
  - Step 8: Progress tracking — **keep** (add commit-per-task)
  - Step 9: Completion validation — **keep** (add ALL_TASKS_DONE signal)
  - Step 10: Post-hooks — **strip**

SHA-256 of the v0.6.1 source: (computed at generation time)

### Output: Loop-adapted prompt

```markdown
# Spec Kit Implementation (Loop-Adapted)

You are executing tasks from a Spec Kit spec in an unattended loop. Work one
phase per iteration. Commit after each task. The next iteration resumes from
your last commit.

## Paths (resolved by the loop)

- **Tasks**: `{{TASK_FILE}}`
- **Plan**: `{{PLAN_FILE}}`
- **Spec**: `{{SPEC_FILE}}`
- **Constitution**: `{{CONSTITUTION_PATH}}`
- **Basic gate**: `{{GATE_RUN}} basic {{BASIC_CHECK_COMMAND}}`
- **Final gate**: `{{GATE_RUN}} final {{FINAL_CHECK_COMMAND}}`

## Iteration Handoff

**At start**: If `.ralph/handoff.md` exists and is fresher than the latest commit,
read it first. Trust its file pointers and architectural facts.

**At end**: After your last commit, write `.ralph/handoff.md` (< 30 lines):

```
## Last completed
<task ID> (<commit SHA short>) — <one-line summary>

## Next task: <task ID>
**Read these files first** (max 6):
- <path> ← <why>

## Architectural facts (max 5 bullets)
- <fact>
```

## Execution

1. **Check prerequisites**: Run `.specify/scripts/bash/check-prerequisites.sh --json --require-tasks --include-tasks` to get FEATURE_DIR and AVAILABLE_DOCS.

2. **Check checklists** (if FEATURE_DIR/checklists/ exists): Scan for incomplete items. If any checklist fails, log the incomplete items to `.ralph/errors.log` and continue — do not halt.

3. **Load context**:
   - **REQUIRED**: Read `{{TASK_FILE}}` and `{{PLAN_FILE}}`
   - **IF EXISTS**: Read data-model.md, contracts/, research.md, quickstart.md

4. **Find the next unchecked task** in `{{TASK_FILE}}`. Respect phase ordering (Setup → Foundational → US1 → US2 → …), but **do not stop at phase boundaries**. Work every remaining unchecked task across every remaining phase in a single iteration. Only yield when `ALL_TASKS_DONE`, a rotation WARN, `.ralph/stop-requested`, or a GUTTER condition fires.

5. **For each unchecked task:**
   a. Read only the files the task references
   b. Follow TDD: write failing test first, then implementation
   c. Run the appropriate gate via `{{GATE_RUN}}`:
      - Final gate for risky changes (module wiring, auth, DB schema, barrel exports)
      - Basic gate for everything else
      - Never pipe or redirect gate output — the wrapper handles logging
   d. If gate fails: read `.ralph/gates/<label>-latest.log` to diagnose. Fix and re-run. You have a 3-try budget per task before emitting `<ralph>GUTTER</ralph>`; a single failure is a normal debug step, not a stuck pattern.
   e. Mark task `[x]` in `{{TASK_FILE}}`
   f. Commit: `git add <explicit file paths> && git commit -m "[ralph][speckit] T### <title>"`
   g. Check `.ralph/stop-requested` — if it exists, yield cleanly (no new task); otherwise continue to the next unchecked task (across phase boundaries as needed).

6. **Phase-boundary verification**: When every task in the current phase is `[x]`, run the final gate if the last task only ran the basic gate. Commit any residual changes. Then **advance into the next phase in the same iteration** — do not hand off to a fresh iteration just because the phase is done.

7. **Progress tracking**:
   - Mark completed tasks as `[x]` in `{{TASK_FILE}}`
   - Halt on non-parallel task failures
   - For parallel tasks `[P]`, continue with successful ones, log failures

8. **Completion**: When ALL tasks are `[x]` AND `{{GATE_RUN}} final {{FINAL_CHECK_COMMAND}}` passes, emit `<promise>ALL_TASKS_DONE</promise>`.

## Error Handling

- Any test failure is a regression you introduced — fix it, do not ignore it
- If stuck 3+ times on the same issue: emit `<ralph>GUTTER</ralph>`
- If structurally blocked (constitution violation, missing dependency): log to `.ralph/errors.log` with the task ID and what the human needs to decide

## Constitution

Ground every decision in `{{CONSTITUTION_PATH}}`. If a task would violate it, mark the task blocked and emit `<ralph>GUTTER</ralph>`.

Begin by finding the next unchecked phase in `{{TASK_FILE}}`.
```

---

## Usage

The prompt resolver reads this guide and the current `speckit.implement.md`,
then produces a loop-adapted prompt following the transformation rules and
using the example as structural reference. The output is written to
`<spec_dir>/ralph-prompt.md` and cached until `speckit.implement.md` changes.
