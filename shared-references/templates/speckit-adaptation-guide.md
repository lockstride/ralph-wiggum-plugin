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
7. **DO NOT emit a `## Loop handoff` section.** The framing prompt
   (build_prompt in ralph-common.sh) already specifies the handoff
   contract — line count, section structure, what gets written when.
   A duplicate section here drifts in wording and creates confusion
   when the agent has to pick between two versions.
8. **Hardcode the basic gate inline.** The per-task flow should say
   `Run \`{{GATE_RUN}} basic {{BASIC_CHECK_COMMAND}}\``. Reserve
   `full` for the impl-loop completion gate (step 3) — the eval loop
   owns `final`, so the impl-loop body never invokes it. Keep failure-
   diagnosis guidance to 2–3 lines: read the gate log, check
   screenshots, use `curl` — don't re-run to "see if it's really
   broken."
9. **Keep stuck guidance brief.** A short paragraph on investigating
   root causes. Don't inline full diagnostic protocols.
10. **Add commit-per-task.** Conventional Commits
    `<type>(<scope>): <description> (T###)`. Stage by exact path. No
    agent-identifying footers.
11. **Add completion signal.** `<promise>ALL_TASKS_DONE</promise>`
    when all `[x]` AND the `full` gate passes (under label `full`).
    Completion claims must cover only work the loop verified: the
    per-task flow must say that a verification the agent cannot
    execute in its environment is never marked `[x]` — the task stays
    unchecked, recorded as blocked in the handoff and
    `.ralph/errors.log`, and the agent continues with the remaining
    tasks.
12. **DO NOT enumerate the after-commit flow.** The framing prompt
    contains a `## After every commit` block with the three-bullet
    breadcrumb check (stop-requested → context-warning-active → next
    task). Referring to that block is fine ("see the framing's
    `## After every commit`"); restating it isn't — paraphrasing
    drops critical breadcrumb names.
13. **DO NOT emit a `## Stop conditions` section.** The framing owns
    the canonical four. A body-level version drifts and weakens.
14. **Preserve `{{PLACEHOLDER}}` variables**: `{{TASK_FILE}}`,
    `{{PLAN_FILE}}`, `{{SPEC_FILE}}`, `{{CONSTITUTION_PATH}}`,
    `{{GATE_RUN}}`, `{{BASIC_CHECK_COMMAND}}`, `{{FULL_CHECK_COMMAND}}`,
    `{{FINAL_CHECK_COMMAND}}` — the loop substitutes them from
    `[gates]` in `.ralph/command-policy`.
15. **Don't emit dynamic state.** Recent activity, gate failure
    summaries, and other per-loop state belong in the framing prompt
    (which fires per iteration), not in the cached body (which is
    rendered once at session start). The body is the durable,
    project-shaped "how to do tasks" layer — keep it static.
16. **Define paths once.** Inline `{{TASK_FILE}}`, `{{PLAN_FILE}}`,
    `{{CONSTITUTION_PATH}}`, and gate commands in a `## Paths` section
    at the top, then refer to them symbolically in the per-task flow
    ("the basic gate", "the tasks file"). Repeating absolute paths in
    every step is noise.
17. **Total output should stay under 40 lines.** With Stop / Handoff /
    After-commit moved to the framing and paths defined once, the body
    is purely task-execution flow and should shrink.

---

## Example Pair

### Input: speckit-implement SKILL.md (any recent version)

The skill is ~10 high-level steps with extensive prose. Strip per
rules 1–4 above. Keep the core execution outline. Add the loop
wrappers.

### Output: Loop-adapted prompt (~30 lines)

The body is just task-execution flow. Stop conditions, the after-commit
breadcrumb check, and the handoff contract live in the framing prompt
that wraps this body — see `build_prompt()` in `ralph-common.sh`.

```markdown
# Spec Kit Implementation (Loop-Adapted)

You are executing tasks from a Spec Kit spec inside the Ralph loop.
Work every remaining unchecked task in a single continuous turn.
A healthy loop completes the whole spec in ONE agent process —
commit, immediately read the next task, keep going. The loop handles
context rotation and rate limits; you handle the work.

> The framing already covers stop conditions, the after-commit
> breadcrumb check, and the handoff contract. This body only describes
> task-execution flow.

## Paths
- **Tasks**: `{{TASK_FILE}}` | **Plan**: `{{PLAN_FILE}}` | **Spec**: `{{SPEC_FILE}}`
- **Constitution**: `{{CONSTITUTION_PATH}}`
- **Basic gate (per-task)**: `{{GATE_RUN}} basic {{BASIC_CHECK_COMMAND}}`
- **Full gate (impl-loop completion)**: `{{GATE_RUN}} full {{FULL_CHECK_COMMAND}}`

## Per-task flow
1. Read the tasks file and the plan file. Read data-model.md /
   contracts/ / research.md / quickstart.md if they exist.
2. For each unchecked task in phase order:
   - Read only the files the task references.
   - Implement the minimum change. TDD where applicable.
   - Run the basic gate.
   - Mark `[x]` only after the gate exits 0. A checked box claims you
     verified the work — if you cannot execute a task's verification in
     this environment (e.g. a visual review in an external design tool),
     leave it unchecked, record it as blocked in the handoff and
     `.ralph/errors.log`, and continue with the remaining tasks.
   - Commit: `git add <exact paths> && git commit -m "<type>(<scope>): <description> (T###)"`.
   - (Framing's `## After every commit` block governs what's next.)
3. When all `[x]` AND the full gate exits 0, emit
   `<promise>ALL_TASKS_DONE</promise>`.

If a gate fails, read `.ralph/gates/<label>-latest.log` for the output.
Screenshots and direct `curl` are cheaper evidence than re-running.
After a genuine fix, if the gate still fails for the same reason,
emit `<ralph>GUTTER</ralph>`.

## Constitution
Ground every decision in the constitution. If a task would violate
it, mark blocked and emit `<ralph>GUTTER</ralph>`.

Begin from the first unchecked task.
```

---

## Usage

The prompt resolver reads this guide and the current
`speckit-implement` SKILL.md, then produces a loop-adapted prompt following
the transformation rules and using the example as structural
reference. The output is written to `<spec_dir>/ralph-prompt.md` and
cached until `speckit-implement` or this guide changes (composite
hash; see `prompt-resolver.sh`).

Generated prompts that exceed 40 lines should be re-tightened — the
goal is to give the agent room to reason, not to enumerate every
protocol. The framing in `build_prompt()` wraps this body with stop
conditions, the after-commit flow, and the handoff contract, so the
body itself should be purely task-execution mechanics. When in doubt,
push detail into a skill rather than into the framing prompt.
