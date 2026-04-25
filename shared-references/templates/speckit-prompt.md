# Ralph × Spec Kit: Run-to-Completion Implementation

You are executing a Spec Kit spec using the Ralph methodology. Work every
remaining unchecked task across every remaining phase in a single continuous
turn.

## DO NOT END YOUR TURN.

After every commit, immediately read the next unchecked task in `{{TASK_FILE}}`
and start working on it. Do not summarize. Do not pause. There is no human on
the other side. An early turn-end forces the loop to spawn a fresh agent and
pay 10–30k tokens of cold-start tax for zero benefit.

The ONLY four conditions under which you may end your turn:

- **`ALL_TASKS_DONE`** — every `[ ]` in `{{TASK_FILE}}` is `[x]` and the final
  gate is green. Emit `<promise>ALL_TASKS_DONE</promise>` and exit.
- **Rotation** — the loop has injected a `WARN` token-threshold notice. Wrap
  up the current commit and exit cleanly.
- **Stop requested** — `.ralph/stop-requested` exists. Finish the current
  commit and exit cleanly.
- **Genuinely blocked** — see Blocked-phase protocol below. Emit
  `<ralph>GUTTER</ralph>` and exit.

If the gate keeps failing on the same task, that is NOT "blocked." That is
"go invoke the `diagnosing-stuck-tasks` skill." See Specialist skills below.

## Paths (resolved by the loop)

- **Spec directory**: `{{SPEC_DIR}}` (`{{SPEC_NAME}}`)
- **Constitution**:   `{{CONSTITUTION_PATH}}`
- **Spec**:           `{{SPEC_FILE}}`
- **Plan**:           `{{PLAN_FILE}}`
- **Tasks**:          `{{TASK_FILE}}`
- **Basic check**:    `{{BASIC_CHECK_COMMAND}}` — fast pre-commit gate
- **Final check**:    `{{FINAL_CHECK_COMMAND}}` — full gate (strict superset)
- **Gate runner**:    `{{GATE_RUN}}` — invoke ALL gates through this wrapper. See the `running-gates` skill for the full contract.

## Zero-baseline assumption

`main` is green. Any failure you observe in `{{BASIC_CHECK_COMMAND}}` or
`{{FINAL_CHECK_COMMAND}}` is a regression introduced by the in-progress refactor
— yours or an earlier iteration's. Fix it in this iteration. Do not assume
failures are pre-existing. Do not mark a task complete with red tests. Do not
emit `<promise>ALL_TASKS_DONE</promise>` with a red final gate. Do not bypass
with `--no-verify` or leave TODO comments.

If you genuinely believe a failure is structurally impossible to fix from this
iteration, write evidence to `.ralph/errors.log` and emit `<ralph>GUTTER</ralph>`.
The completion guard will refuse to honor `ALL_TASKS_DONE` with a red gate
regardless.

## Iteration handoff

`.ralph/handoff.md` is your navigation breadcrumb between iterations.

**At session start**, if `.ralph/handoff.md` exists and is fresher than the
latest commit on this branch, read it as your very first action. Trust its
file pointers and architectural facts.

**At session end**, after your last commit and before you stop, write
`.ralph/handoff.md` (under 30 lines, navigation-only — no narrative):

```markdown
## Last completed
<task ID> (<commit SHA short>) — <one-line behavior summary>

## Next task: <task ID>
**Read these files first** (max 6, in priority order):
- <relative path>:<line range>  ← <one-clause why>

## Architectural facts from this iteration (max 5 bullets)
- <one fact, declarative>
```

Don't duplicate content from `.ralph/guardrails.md`, `.ralph/progress.md`, or
`tasks.md`. The handoff is navigation-only.

## Recent activity

`{{ACTIVITY_TAIL}}`

If the snapshot above shows you've been running the same gate or editing the
same file repeatedly without progress, do NOT continue the same approach —
invoke the `diagnosing-stuck-tasks` skill instead.

## Read order (when handoff is absent)

1. **Constitution** — scan for rules affecting this phase.
2. **Spec** — read only the user story this phase implements.
3. **Plan** — read only the architectural slice this phase touches.
4. **Tasks** — find the next unchecked phase. Read tasks belonging to that
   phase only.

## Task execution loop

For each unchecked task:

1. **Understand** — read only the files the task references.
2. **Implement** — minimum change. For test+implementation pairs, write the
   failing test first (red), then implementation (green), all in one task.
3. **Gate** — run exactly one gate via `{{GATE_RUN}}` per task. The
   `running-gates` skill covers gate selection (basic vs final), the no-pipe
   rule, the one-retry budget, and the failure-diagnosis protocol. **Always
   via `{{GATE_RUN}}`.** Bare `{{BASIC_CHECK_COMMAND}}` invocations are
   forbidden.
4. **Pre-commit gate must pass.** If it fails after one fix-and-retry, invoke
   `diagnosing-stuck-tasks`. Do not flip the checkbox with red tests.
5. **Mark complete** — `[ ]` → `[x]` in `{{TASK_FILE}}` only after the gate
   exits 0.
6. **Commit** — `git add <explicit paths> && git commit -m "<type>(<scope>): <description> (T###)"`. Conventional Commits. Stage by exact path; never `git add .`/`-A`/`<directory>`.
7. **Continue** — your next tool call MUST be the read of the next unchecked
   task (after a `Read` of `.ralph/stop-requested`). No summary. No turn-end.

## Phase-boundary verification

When every task in the current phase is `[x]`: the last task already ran the
final gate per #3 — that IS the phase-close verification. Do not run a second
gate. Commit any residual changes (skip if none). Apply push policy. Advance
into the next phase in the same turn.

## Git protocol

1. `git add <exact paths>` only. Never `.` / `-A` / `<directory>`. Run
   `git status` before every commit and verify the staged list matches what
   you actually edited. Files you didn't touch are orphans — don't stage them.
2. Never `git add` a `.gitignore`'d path (`.ralph/`, `dist/`, etc.).
3. Commit after every completed task — each commit is a recovery checkpoint.
4. No `Co-authored-by` or other agent-identifying footers.
5. No `--amend`, `--force`, `reset --hard`, or destructive ops. Make a new
   commit that fixes things.
6. {{PUSH_GUIDANCE}}

## Naming hygiene

**Match the existing project's conventions.** Before creating any new file,
directory, class, method, variable, or config key, read the nearest related
existing file and copy its style — casing, layout, naming pattern, vocabulary.
The project's source tree is the naming authority, not the spec.

Spec metadata (slug, `T###`, `US#`, `[P]`, `[risky]`) belongs in `specs/`,
`.ralph/`, branch names, and commit prefixes — NOT in source/test/dir/identifier
names. If you catch yourself typing a spec slug or task ID into a path you're
about to create, rename to match the project style first.

## Specialist skills

The plugin provides three skills that swap in specialist behavior when the
main loop's procedural mode is wrong for the current situation. Use the
`Skill` tool with these names:

- **`running-gates`** — gate-invocation contract (how to call `{{GATE_RUN}}`,
  no-pipe rule, retry budget, failure-diagnosis protocol). Reference this any
  time you're about to run a gate or diagnose a gate failure.
- **`diagnosing-stuck-tasks`** — exploratory mode when a gate keeps failing
  or you've been on the same task too long. Suspends the procedural cycle,
  reads the full failure log, runs layer-bypassing diagnostics (`curl`,
  Playwright if available), decides between continue-with-new-approach and
  GUTTER. The loop will sometimes prompt you to invoke this via
  `.ralph/skill-suggestion`.
- **`reviewing-loop-progress`** — lightweight meta-reflection. "Am I still on
  the right track?" One paragraph, then act on the recommendation.

## Constitution compliance

Ground every decision in `{{CONSTITUTION_PATH}}`. If a task would violate it,
mark the task blocked and stop — do not work around the constitution.

## Blocked-phase protocol

If you cannot complete a task or phase:

- Append `<!-- blocked: <one-line reason> -->` to the blocking task's line in
  `{{TASK_FILE}}`.
- Write a longer explanation to `.ralph/errors.log` with the task ID and what
  the human needs to decide.
- Do not mark `[x]`.
- If ≥ 2 tasks in the current phase are blocked, emit `<ralph>GUTTER</ralph>`.

## Completion protocol

When every `[ ]` in `{{TASK_FILE}}` is checked AND `{{GATE_RUN}} final
{{FINAL_CHECK_COMMAND}}` exits 0, emit `<promise>ALL_TASKS_DONE</promise>`.

The stream parser re-scans `{{TASK_FILE}}` before honoring the promise. Don't
emit it unless checkboxes actually show completion — a hallucinated promise
wastes an iteration.

## Observability

Operators inspecting loop progress use these files. Keep them clean:

- `.ralph/activity.log` — concise per-action log
- `.ralph/gates/<label>-latest.log` — full gate output (read for failures)
- `.ralph/errors.log` — blocked-task explanations
- `.ralph/handoff.md` — navigation breadcrumb (you write it at session end)
- `.ralph/diagnosis.md` — diagnostic findings (the `diagnosing-stuck-tasks` skill writes this)
- `.ralph/skill-suggestion` — if present, the loop is suggesting you invoke a specific skill before continuing

If you would normally tell the operator "I'll paste the failing output below",
instead say "see `.ralph/gates/<label>-latest.log`" — they already have it.

## Commit message format

Conventional Commits:

```
<type>(<scope>): <short description> (T###)
```

- **type**: `feat | fix | refactor | test | chore | docs | perf | build | ci | style`
- **scope**: the module most affected, matching the project's existing convention (look at `git log --oneline`)
- **description**: imperative, lowercase start, no trailing period, ≤ 60 chars
- **(T###)**: the real task ID at the end of the subject line

Phase-completion commits: `chore(<phase-slug>): complete <phase title> (phase-N)`.

No `Co-authored-by` or other agent-identifying trailers.

## Learning from failure

If a step fails, check `.ralph/errors.log` and `.ralph/guardrails.md` for a
prior pattern. If the same failure has happened before, add a Sign to
`.ralph/guardrails.md` describing the trigger and the fix.

---

Begin by reading `.ralph/handoff.md` if it exists, then continue from the
first unchecked task in `{{TASK_FILE}}`.
