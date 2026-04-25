# Spec Kit → Ralph Loop: Prompt Adaptation Guide

This guide transforms a `speckit.implement.md` slash command into a loop-compatible
prompt for unattended Ralph iterations.

**Design principle**: trust the model. The skill itself (`speckit.implement.md`)
is ~10 high-level steps that work well in interactive mode because the user is
in the loop providing course correction. In unattended mode the user isn't
there, so we add a few load-bearing rules — but resist the urge to add a rule
every time the agent does something dumb. Cumulative rules crush the agent's
ability to reason. Specialist behavior (gate discipline, stuck-debugging,
meta-review) lives in plugin **skills** the agent invokes when needed, not in
the framing prompt.

## Transformation Rules

These rules describe the structural difference between interactive and unattended
execution. They are stable across versions of speckit.implement.md.

1. **Strip interactive features**: Remove user prompts, "STOP and ask", confirmation gates, and any step that waits for user input.
2. **Strip one-time project setup**: Remove ignore file creation/verification, tech stack detection, project scaffolding. Done once before the loop, not on every iteration.
3. **Strip extension hooks**: Remove all `.specify/extensions.yml` processing.
4. **Strip the `$ARGUMENTS` section**: The loop replaces this.
5. **Replace "halt execution"**: Log to `.ralph/errors.log` and emit `<ralph>GUTTER</ralph>` if structurally blocked.
6. **Keep the execution outline**: Context loading, task parsing, phase-by-phase execution, completion validation. These are the core logic.
7. **Add iteration handoff**: Read `.ralph/handoff.md` at start (if fresher than the latest commit). Write it at end (< 30 lines, navigation-only).
8. **Reference the `running-gates` skill** for gate invocation. Don't inline the no-pipe rule, retry budget, or failure-diagnosis protocol — those live in the skill. The framing prompt only needs to say: "Run gates via `{{GATE_RUN}}`. See the `running-gates` skill for the contract."
9. **Reference the `diagnosing-stuck-tasks` skill** for stuck cases. Don't inline diagnostic protocols. The framing prompt only needs to say: "If a gate fails after one fix-and-retry, invoke `diagnosing-stuck-tasks` instead of looping."
10. **Add commit-per-task**: Conventional Commits `<type>(<scope>): <description> (T###)`. Stage by exact path. No agent-identifying footers.
11. **Add completion signal**: `<promise>ALL_TASKS_DONE</promise>` when all `[x]` AND final gate passes.
12. **Add DO-NOT-END-YOUR-TURN rule**: After every commit, immediately read the next task. Models naturally end turns at "polite stopping points" (post-commit) — that's wrong here because there's no human to receive the polite handoff and the cold-start tax of a new iteration is 10–30k tokens.
13. **Preserve `{{PLACEHOLDER}}` variables**: `{{TASK_FILE}}`, `{{PLAN_FILE}}`, `{{SPEC_FILE}}`, `{{CONSTITUTION_PATH}}`, `{{GATE_RUN}}`, `{{BASIC_CHECK_COMMAND}}`, `{{FINAL_CHECK_COMMAND}}` — the loop substitutes them.
14. **Reference `{{ACTIVITY_TAIL}}`**: A `Recent activity` section in the prompt body shows the last ~50 events from `.ralph/activity.log`. The loop populates this on each iteration. Surface it so the agent can spot meta-patterns (same gate failing 3×, same file thrashed) it would otherwise miss.
15. **Total output must stay under 50 lines.** Trust the model. The skills carry the weight.

---

## Example Pair

### Input: speckit.implement.md (any recent version)

The skill is ~10 high-level steps with extensive prose. Strip per rules 1–4
above. Keep the core execution outline. Add the loop wrappers.

### Output: Loop-adapted prompt (~40 lines)

```markdown
# Spec Kit Implementation (Loop-Adapted)

You are executing tasks from a Spec Kit spec in an unattended Ralph loop.
Work every remaining unchecked task in a single continuous turn. Commit
after each task. The loop handles context rotation and rate limits.

## Paths
- **Tasks**: `{{TASK_FILE}}`
- **Plan**: `{{PLAN_FILE}}`
- **Spec**: `{{SPEC_FILE}}`
- **Constitution**: `{{CONSTITUTION_PATH}}`
- **Gate runner**: `{{GATE_RUN}}` — see the `running-gates` skill for the contract

## Recent activity
{{ACTIVITY_TAIL}}

If the snapshot above shows you've been running the same gate or editing
the same file repeatedly without progress, do NOT continue the same
approach — invoke the `diagnosing-stuck-tasks` skill instead.

## Iteration handoff
- **At start**: If `.ralph/handoff.md` exists and is fresher than the latest commit, read it first.
- **At end**: After your last commit, write `.ralph/handoff.md` (< 30 lines: last completed, next task, files-to-read, max-5 architectural facts).

## Execution
1. Run `.specify/scripts/bash/check-prerequisites.sh --json --require-tasks --include-tasks` for FEATURE_DIR and AVAILABLE_DOCS.
2. Read `{{TASK_FILE}}` and `{{PLAN_FILE}}`. Read data-model.md / contracts/ / research.md / quickstart.md if they exist.
3. For each unchecked task in `{{TASK_FILE}}`, in phase order:
   a. Read only the files the task references.
   b. Implement the minimum change. TDD where applicable (red → green in one commit).
   c. Run the appropriate gate via `{{GATE_RUN}}` (see `running-gates` skill for basic-vs-final selection and the no-pipe rule).
   d. If the gate fails: fix and re-run **once**. If it still fails, invoke the `diagnosing-stuck-tasks` skill — do NOT keep looping fix-then-fail.
   e. Mark `[x]` in `{{TASK_FILE}}` only after the gate exits 0.
   f. Commit: `git add <exact paths> && git commit -m "<type>(<scope>): <description> (T###)"`.
   g. Check `.ralph/stop-requested`. If absent, your next tool call MUST be a read of the next unchecked task. No summary. No turn-end.
4. When all tasks are `[x]` AND the final gate passes, emit `<promise>ALL_TASKS_DONE</promise>`.

## Stop conditions
The ONLY four valid turn-ends: `ALL_TASKS_DONE`, rotation `WARN` from the loop, `.ralph/stop-requested` exists, or `<ralph>GUTTER</ralph>` for genuinely stuck. A successful commit is NOT a stop condition.

## Constitution
Ground every decision in `{{CONSTITUTION_PATH}}`. If a task would violate it, mark blocked and emit `<ralph>GUTTER</ralph>`.

Begin by reading `.ralph/handoff.md` if it exists, then continue from the first unchecked task.
```

---

## Usage

The prompt resolver reads this guide and the current `speckit.implement.md`,
then produces a loop-adapted prompt following the transformation rules and
using the example as structural reference. The output is written to
`<spec_dir>/ralph-prompt.md` and cached until `speckit.implement.md` changes.

Generated prompts that exceed 50 lines should be re-tightened — the goal is
to give the agent room to reason, not to enumerate every protocol. When in
doubt, push detail into a skill rather than into the framing prompt.
