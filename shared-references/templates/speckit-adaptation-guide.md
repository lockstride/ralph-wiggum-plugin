# Spec Kit → Ralph Loop: Prompt Adaptation Guide

This guide transforms a `speckit-implement` skill into a loop-compatible
prompt for unattended Ralph runs.

**Design principle**: trust the model. The skill itself
(`speckit-implement`) is ~10 high-level steps that work well in
interactive mode because the user is in the loop providing course
correction. In unattended mode the user isn't there, so we add a few
load-bearing rules — but resist the urge to add a rule every time the
agent does something dumb. Cumulative rules crush the agent's ability
to reason. Specialist behavior (gate discipline, stuck-debugging,
meta-review) lives in plugin **skills** the agent invokes when needed,
not in the framing prompt.

The shape we want: short framing that establishes flow expectations
(commit-then-keep-going, the four real stop conditions, a few
load-bearing protocols), and trusts the model for everything else.
The skills are where prescription belongs — and the diagnostic
skills are framed as *permission to step outside the procedure*, not
as procedures themselves.

## Transformation Rules

These rules describe the structural difference between interactive
and unattended execution. Stable across versions of speckit-implement.

1. **Strip interactive features.** Remove user prompts, "STOP and
   ask," confirmation gates, and any step that waits for user input.
2. **Strip one-time project setup.** Remove ignore file
   creation/verification, tech stack detection, project scaffolding.
   Done once before the loop, not on every loop.
3. **Strip extension hooks.** Remove `.specify/extensions.yml`
   processing.
4. **Strip the `$ARGUMENTS` section.** The loop replaces this.
5. **Replace "halt execution".** Log to `.ralph/errors.log` and emit
   `<ralph>GUTTER</ralph>` if structurally blocked.
6. **Keep the execution outline.** Context loading, task parsing,
   phase-by-phase execution, completion validation. These are the
   core logic.
7. **Add loop handoff.** Read `.ralph/handoff.md` at start (if fresher
   than the latest commit). Write it at loop end (< 30 lines,
   navigation-only).
8. **Reference the `running-gates` skill** for gate invocation. Don't
   inline the no-pipe rule, retry budget, or failure-diagnosis
   protocol — those live in the skill. The framing prompt only needs
   to say: "Run gates via `{{GATE_RUN}}`. See the `running-gates`
   skill for the contract."
9. **Reference the `diagnosing-stuck-tasks` skill** for stuck cases.
   Don't inline diagnostic protocols. Frame the skill as permission
   to step out of the procedural cycle, not as a procedure to follow.
10. **Add commit-per-task.** Conventional Commits
    `<type>(<scope>): <description> (T###)`. Stage by exact path. No
    agent-identifying footers.
11. **Add completion signal.** `<promise>ALL_TASKS_DONE</promise>`
    when all `[x]` AND final gate passes.
12. **Add the flow expectation.** After every commit, immediately
    read the next task. Models naturally end turns at "polite
    stopping points" (post-commit) — that's wrong here because there's
    no human to receive the polite handoff and the cold-start tax of
    a fresh agent process is 10–30k tokens. Frame this as the
    default expectation, not as a procedural rule with edge cases.
13. **Preserve `{{PLACEHOLDER}}` variables**: `{{TASK_FILE}}`,
    `{{PLAN_FILE}}`, `{{SPEC_FILE}}`, `{{CONSTITUTION_PATH}}`,
    `{{GATE_RUN}}`, `{{BASIC_CHECK_COMMAND}}`,
    `{{FINAL_CHECK_COMMAND}}` — the loop substitutes them.
14. **Reference `{{ACTIVITY_TAIL}}`.** A `Recent activity` section
    in the prompt body shows the last ~50 events from
    `.ralph/activity.log`. The loop populates this on each loop.
    Surface it so the agent can spot meta-patterns (same gate failing
    3×, same file thrashed) it would otherwise miss.
15. **Total output should stay under 50 lines.** Trust the model.
    The skills carry the weight.

---

## Example Pair

### Input: speckit-implement SKILL.md (any recent version)

The skill is ~10 high-level steps with extensive prose. Strip per
rules 1–4 above. Keep the core execution outline. Add the loop
wrappers.

### Output: Loop-adapted prompt (~40 lines)

```markdown
# Spec Kit Implementation (Loop-Adapted)

You are executing tasks from a Spec Kit spec inside the Ralph loop.
Work every remaining unchecked task in a single continuous turn.
A healthy loop completes the whole spec in ONE agent process —
commit, immediately read the next task, keep going. The loop handles
context rotation and rate limits; you handle the work.

## Paths
- **Tasks**: `{{TASK_FILE}}`
- **Plan**: `{{PLAN_FILE}}`
- **Spec**: `{{SPEC_FILE}}`
- **Constitution**: `{{CONSTITUTION_PATH}}`
- **Gate runner**: `{{GATE_RUN}}` — see the `running-gates` skill

## Recent activity
{{ACTIVITY_TAIL}}

If the snapshot above shows you've been running the same gate or
editing the same file repeatedly without progress, do NOT continue
the same approach — invoke the `diagnosing-stuck-tasks` skill.

## Loop handoff
- **At start**: If `.ralph/handoff.md` exists and is fresher than
  the latest commit, read it first.
- **At end** (only when actually ending the turn — not after every
  commit): write `.ralph/handoff.md` (< 30 lines: last completed,
  next task, files-to-read, max-5 architectural facts).

## Per-task flow
1. Read `{{TASK_FILE}}` and `{{PLAN_FILE}}`. Read data-model.md /
   contracts/ / research.md / quickstart.md if they exist.
2. For each unchecked task in `{{TASK_FILE}}`, in phase order:
   - Read only the files the task references.
   - Implement the minimum change. TDD where applicable.
   - Run a gate via `{{GATE_RUN}}` (see `running-gates` skill).
   - Mark `[x]` in `{{TASK_FILE}}` only after the gate exits 0.
   - Commit: `git add <exact paths> && git commit -m "<type>(<scope>): <description> (T###)"`.
   - Check `.ralph/stop-requested`. If absent, your next tool call
     is the read of the next unchecked task. No summary. No turn-end.
3. When all tasks are `[x]` AND the final gate passes, emit
   `<promise>ALL_TASKS_DONE</promise>`.

If the gate keeps failing for the same reason after a real fix,
you're probably investigating the wrong layer — invoke
`diagnosing-stuck-tasks` rather than retrying.

## Stop conditions (the only four)
`<promise>ALL_TASKS_DONE</promise>`, rotation `WARN` from the loop,
`.ralph/stop-requested` exists, or `<ralph>GUTTER</ralph>` for
genuinely stuck. A successful commit is NOT a stop condition.

## Constitution
Ground every decision in `{{CONSTITUTION_PATH}}`. If a task would
violate it, mark blocked and emit `<ralph>GUTTER</ralph>`.

Begin by reading `.ralph/handoff.md` if it exists, then continue
from the first unchecked task.
```

---

## Usage

The prompt resolver reads this guide and the current
`speckit-implement` SKILL.md, then produces a loop-adapted prompt following
the transformation rules and using the example as structural
reference. The output is written to `<spec_dir>/ralph-prompt.md` and
cached until `speckit-implement` or this guide changes (composite
hash; see `prompt-resolver.sh`).

Generated prompts that exceed 50 lines should be re-tightened — the
goal is to give the agent room to reason, not to enumerate every
protocol. When in doubt, push detail into a skill rather than into
the framing prompt.
