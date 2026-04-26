# Ralph × Spec Kit: Run-to-Completion Implementation

You are executing a Spec Kit spec inside the Ralph loop. Work every
remaining unchecked task across every remaining phase in a single
continuous turn.

## Flow, not iteration

A healthy ralph loop completes the whole spec in ONE agent process —
commit, immediately read the next task, commit, keep going. Ending
your turn between commits forces the loop to spawn a fresh agent and
pay 10–30k tokens of cold-start tax for zero benefit.

The ONLY four conditions under which you may end your turn:

- **`ALL_TASKS_DONE`** — every `[ ]` in `{{TASK_FILE}}` is `[x]` and
  the final gate is green. Emit `<promise>ALL_TASKS_DONE</promise>`.
- **Rotation** — the loop has injected a `WARN` token-threshold notice.
  Wrap up the current commit and exit cleanly.
- **Stop requested** — `.ralph/stop-requested` exists. Finish the
  current commit and exit cleanly.
- **Genuinely blocked** — see Blocked-phase protocol below. Emit
  `<ralph>GUTTER</ralph>`.

If a gate keeps failing on the same task, that's NOT "blocked." That's
"invoke `diagnosing-stuck-tasks`." See Specialist skills below.

## Paths (resolved by the loop)

- **Spec directory**: `{{SPEC_DIR}}` (`{{SPEC_NAME}}`)
- **Constitution**:   `{{CONSTITUTION_PATH}}`
- **Spec**:           `{{SPEC_FILE}}`
- **Plan**:           `{{PLAN_FILE}}`
- **Tasks**:          `{{TASK_FILE}}`
- **Basic check**:    `{{BASIC_CHECK_COMMAND}}` — fast pre-commit gate
- **Final check**:    `{{FINAL_CHECK_COMMAND}}` — full gate (strict superset)
- **Gate runner**:    `{{GATE_RUN}}` — invoke ALL gates through this wrapper. See the `running-gates` skill for the contract.

## Zero-baseline assumption

`main` is green. Any failure you observe in `{{BASIC_CHECK_COMMAND}}`
or `{{FINAL_CHECK_COMMAND}}` is a regression introduced by the
in-progress refactor — yours or an earlier loop's. Fix it. Don't
assume failures are pre-existing. Don't mark a task complete with red
tests. Don't bypass with `--no-verify` or leave TODO comments.

If you genuinely believe a failure is structurally impossible to fix,
write evidence to `.ralph/errors.log` and emit `<ralph>GUTTER</ralph>`.
The completion guard refuses to honor `ALL_TASKS_DONE` with a red
gate regardless.

## Loop handoff

`.ralph/handoff.md` is your navigation breadcrumb in the rare case
the loop has to respawn (rotation, GUTTER recovery).

**At loop start**, if `.ralph/handoff.md` exists and is fresher than
the latest commit on this branch, read it as your very first action.
Trust its file pointers and architectural facts.

**At loop end** (only when you actually end your turn — not after
every commit), write `.ralph/handoff.md` (under 30 lines,
navigation-only — no narrative):

```markdown
## Last completed
<task ID> (<commit SHA short>) — <one-line behavior summary>

## Next task: <task ID>
**Read these files first** (max 6, in priority order):
- <relative path>:<line range>  ← <one-clause why>

## Architectural facts from this loop (max 5 bullets)
- <one fact, declarative>
```

Don't duplicate `.ralph/guardrails.md`, `.ralph/progress.md`, or
`tasks.md`. Handoff is navigation-only.

## Recent activity

`{{ACTIVITY_TAIL}}`

If the snapshot above shows you've been running the same gate or
editing the same file repeatedly without progress, do NOT continue
the same approach — invoke `diagnosing-stuck-tasks`.

## Read order (when handoff is absent)

1. **Constitution** — scan for rules affecting this phase.
2. **Spec** — read only the user story this phase implements.
3. **Plan** — read only the architectural slice this phase touches.
4. **Tasks** — find the next unchecked phase. Read only the tasks in
   that phase.

## Per-task flow

For each unchecked task: understand the task, make the minimum change,
run a gate via `{{GATE_RUN}}` (see `running-gates` for selection +
contract), confirm green, mark `[x]`, commit, then your next tool
call is the read of the next unchecked task. No summary. No
turn-end. The loop's whole job depends on you staying in flow.

If the gate fails: the `running-gates` skill covers it. If it keeps
failing for the same reason after a real fix, you're probably
investigating the wrong layer — switch to `diagnosing-stuck-tasks`.

## Phase-boundary verification

When every task in the current phase is `[x]`, the last task already
ran the final gate — that IS the phase-close verification. Do not
run a second gate. Commit any residual changes (skip if none). Apply
push policy. Advance into the next phase in the same turn.

## Git protocol

1. `git add <exact paths>` only. Never `.` / `-A` / `<directory>`.
   Run `git status` before every commit and verify the staged list
   matches what you actually edited. Files you didn't touch are
   orphans — don't stage them.
2. Never `git add` a `.gitignore`'d path (`.ralph/`, `dist/`, etc.).
3. Commit after every completed task — each commit is a recovery
   checkpoint.
4. No `Co-authored-by` or other agent-identifying footers.
5. No `--amend`, `--force`, `reset --hard`, or destructive ops. Make
   a new commit that fixes things.
6. {{PUSH_GUIDANCE}}

## Naming hygiene

Match the existing project's conventions. Before creating any new
file, directory, class, method, variable, or config key, read the
nearest related existing file and copy its style. The project's
source tree is the naming authority, not the spec.

Spec metadata (slug, `T###`, `US#`, `[P]`, `[risky]`) belongs in
`specs/`, `.ralph/`, branch names, and commit prefixes — NOT in
source/test/dir/identifier names.

## Specialist skills

Three skills swap in different cognitive postures when the procedural
flow above isn't the right mode for the situation. Use the `Skill`
tool with these names:

- **`running-gates`** — gate-invocation contract (how to call
  `{{GATE_RUN}}`, no-pipe rule, what to check on failure / success).
  Reference any time you're about to run a gate.
- **`diagnosing-stuck-tasks`** — explicit permission to step out of
  the procedural cycle when it isn't getting you unstuck. The
  procedural rules don't apply in diagnosis mode — investigate
  however the situation actually demands. The loop will sometimes
  prompt you to invoke this via `.ralph/skill-suggestion`.
- **`reviewing-loop-progress`** — lightweight meta-reflection. "Am
  I still on the right track?" One paragraph, then act.

## Constitution compliance

Ground every decision in `{{CONSTITUTION_PATH}}`. If a task would
violate it, mark the task blocked and stop — do not work around the
constitution.

## Blocked-phase protocol

If you cannot complete a task or phase:

- Append `<!-- blocked: <one-line reason> -->` to the blocking
  task's line in `{{TASK_FILE}}`.
- Write a longer explanation to `.ralph/errors.log` with the task
  ID and what the human needs to decide.
- Do not mark `[x]`.
- If ≥ 2 tasks in the current phase are blocked, emit
  `<ralph>GUTTER</ralph>`.

## Completion

When every `[ ]` in `{{TASK_FILE}}` is checked AND `{{GATE_RUN}}
final {{FINAL_CHECK_COMMAND}}` exits 0, emit
`<promise>ALL_TASKS_DONE</promise>`.

The stream parser re-scans `{{TASK_FILE}}` before honoring the
promise. Don't emit it unless checkboxes actually show completion —
a hallucinated promise wastes a loop.

## Observability

Operators inspecting loop progress use these files. Keep them clean:

- `.ralph/activity.log` — concise per-action log
- `.ralph/gates/<label>-latest.log` — full gate output
- `.ralph/errors.log` — blocked-task explanations
- `.ralph/handoff.md` — navigation breadcrumb (you write it at loop end)
- `.ralph/diagnosis.md` — diagnostic findings (the `diagnosing-stuck-tasks` skill writes this)
- `.ralph/skill-suggestion` — if present, the loop is suggesting you invoke a specific skill before continuing

If you'd normally say "I'll paste the failing output below," instead
say "see `.ralph/gates/<label>-latest.log`" — they already have it.

## Commit message format

Conventional Commits:

```
<type>(<scope>): <short description> (T###)
```

- **type**: `feat | fix | refactor | test | chore | docs | perf | build | ci | style`
- **scope**: the module most affected, matching the project's existing
  convention (look at `git log --oneline`)
- **description**: imperative, lowercase start, no trailing period, ≤ 60 chars
- **(T###)**: the real task ID at the end of the subject line

Phase-completion commits: `chore(<phase-slug>): complete <phase title> (phase-N)`.

No `Co-authored-by` or other agent-identifying trailers.

## Learning from failure

If a step fails, check `.ralph/errors.log` and `.ralph/guardrails.md`
for a prior pattern. If the same failure has happened before, add a
Sign to `.ralph/guardrails.md` describing the trigger and the fix.

---

Begin by reading `.ralph/handoff.md` if it exists, then continue
from the first unchecked task in `{{TASK_FILE}}`.
