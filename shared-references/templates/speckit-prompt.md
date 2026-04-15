# Ralph × Spec Kit: Phase-Level Implementation

You are executing a Spec Kit spec using the Ralph methodology. The unit of
work for one iteration is an **entire Spec Kit phase**, not a single task.
Assume you are running unattended in a clean worktree on a 1M-context model.

## Paths (resolved by the loop)

- **Spec directory**: `{{SPEC_DIR}}` (`{{SPEC_NAME}}`)
- **Constitution**:   `{{CONSTITUTION_PATH}}`
- **Spec**:           `{{SPEC_FILE}}`
- **Plan**:           `{{PLAN_FILE}}`
- **Tasks**:          `{{TASK_FILE}}`
- **Basic check**:    `{{BASIC_CHECK_COMMAND}}` — fast gate (no e2e), used on most tasks
- **Final check**:    `{{FINAL_CHECK_COMMAND}}` — full gate (strict superset of basic check, includes e2e), used on risky tasks and at phase completion
- **Gate runner**:    `{{GATE_RUN}}` — shell wrapper that runs a gate with pipefail, persists the full log to `.ralph/gates/<label>-latest.log`, prints a compact summary, and exits with the real command status. **You MUST invoke every gate through this wrapper.**

Every task runs **exactly one** of these gates before commit — never both, never neither. `{{FINAL_CHECK_COMMAND}}` is a strict superset of `{{BASIC_CHECK_COMMAND}}`, so when you run the final check you have already satisfied the basic check.

## Zero-baseline assumption (read before anything else)

`main` is green. There are **no** pre-existing test failures, lint errors, or build breaks. Any failure you observe in `{{BASIC_CHECK_COMMAND}}` or `{{FINAL_CHECK_COMMAND}}` is a regression introduced by the in-progress refactor — yours or an earlier iteration's. **You must fix it in this iteration.** The following are forbidden — they are why this section is at the top:

- **Do not** assume failures are "pre-existing" and ignore them.
- **Do not** mark a task or phase complete while tests are red.
- **Do not** emit `<promise>ALL_TASKS_DONE</promise>` with a red final gate.
- **Do not** bypass with `--no-verify`, `--skip-tests`, or similar.
- **Do not** leave TODO comments to "fix later." Fix now.

If you genuinely believe a failure is unrelated to your task and structurally impossible to fix from this iteration, write the evidence and your reasoning to `.ralph/errors.log` and emit `<ralph>GUTTER</ralph>`. **A human must decide — not you.** Marking a task `[x]` around a red gate is a protocol violation; the loop's completion guard will refuse to exit even if you do, so you will just waste an iteration.

## Gate invocation contract (hard rules — read carefully)

This is the single most load-bearing rule in this prompt. Past iterations wasted hours by piping gate output through `grep`/`tail`, which hides non-zero exit codes and forces you to re-run expensive checks just to see more output. **The wrapper fixes both problems for you.** Use it, and do nothing else.

1. **Run gates via `{{GATE_RUN}}`, never bare.**
   - Basic gate: `{{GATE_RUN}} basic {{BASIC_CHECK_COMMAND}}`
   - Final gate: `{{GATE_RUN}} final {{FINAL_CHECK_COMMAND}}`
   - If you need a targeted e2e run for debugging: `{{GATE_RUN}} e2e pnpm test-e2e:local` (or whatever e2e command applies).

2. **Never pipe, never redirect, never filter gate commands.** The wrapper already tails to a bounded summary and persists the full log. Forbidden suffixes on any gate invocation:
   - `| tail …`, `| head …`, `| grep …`, `| awk …`, `| sed …`
   - `> /tmp/…`, `>> …`, `| tee …`
   - `2>&1 | anything`
   If you catch yourself writing any of these on a gate command, **stop and rewrite it as the bare `{{GATE_RUN}} <label> <cmd>` form.** The in-context summary will be sufficient; the full log is on disk for targeted `grep` via the `Read` tool (see "Failure diagnosis protocol" below).

3. **Gate re-run budget.**
   - **Per task: at most one gate run** (the one before commit). If it passes, commit and advance — **do not re-run the gate to "verify it's still green."** A green gate is authoritative; re-running it burns 1–5 minutes per run for zero information.
   - **Per phase close: at most one final-gate run.** The phase-completion protocol below tells you when to run it.
   - If a gate fails, you are allowed **one** additional run **after** making a code change. Re-running the same gate twice in a row without any edits in between is forbidden — it will produce the same failure and waste ~1–5 minutes per run. Read the persisted log instead (see below).
   - **Never run a gate "to be safe" before starting a task.** `main` is green (see Zero-baseline assumption); the prior iteration's final commit was also green. A pre-emptive gate run before you've made any edits is pure waste.

4. **Failure diagnosis protocol** — when a gate exits non-zero:
   1. **Do not re-run the gate.** The summary you already saw, plus the full log at `.ralph/gates/<label>-latest.log`, contains everything you need.
   2. Use the `Read` tool with `offset`/`limit` to slice the log around interesting spots. Example: `Read .ralph/gates/final-latest.log` for the tail, then targeted offset reads for stack traces.
   3. Use the `Grep` tool (NOT a shell `grep` in a second process) against `.ralph/gates/final-latest.log` to find specific symptoms:
      - `Grep pattern="^\\s*(FAIL|✗|×)" path=".ralph/gates/final-latest.log"` — failing test titles
      - `Grep pattern="Error:|AssertionError" path=".ralph/gates/final-latest.log" -A 5` — error sites with context
      - `Grep pattern="error TS[0-9]+" path=".ralph/gates/final-latest.log"` — TypeScript errors
   4. Fix the smallest thing that could be wrong. Do not re-read unrelated files.
   5. Re-run the gate **once** via `{{GATE_RUN}}`. If it still fails, read the log again and iterate — but if you have already re-run twice without progress, stop and emit `<ralph>GUTTER</ralph>` instead of burning more cycles.

5. **The wrapper's exit code is authoritative.** If the summary ends with `exit=0`, the gate passed. If it ends with `exit=<N>` where N≠0, the gate failed — regardless of how the output "looks." Do not second-guess it.

6. **Post-gate-success protocol** — when a gate exits zero:
   - Your **next** tool call MUST be `git status` to see what is staged and what is dirty.
   - Your tool call after that MUST be `git add <explicit paths>` to stage the files you intended to commit (per the Git Protocol below — never `git add .`).
   - Your tool call after that MUST be `git commit -m "[ralph][speckit] T### …"`.
   - Do **not** Read the gate log after a passing gate. Do **not** Grep the gate log. Do **not** `tail` / `wc` / `ls` the gate log. Do **not** run any other shell command between the passing gate and the commit. The wrapper has already printed every fact about the run that you need; the persisted log is only there for the failure-diagnosis path. Re-reading it after a green gate consumes tool calls and tokens for zero new information.
   - The single legitimate exception: if `git status` shows files modified that you did **not** intend to touch (orphans, IDE droppings, prior-iteration leftovers), surface them per the Git Protocol's orphan-handling rule before committing.

## Iteration handoff (read this first, write it last)

Each iteration is a fresh process with no memory of prior iterations — but the *most recent* iteration was the one with the freshest context, and rediscovering what it already learned is the single biggest source of warm-up cost. You have two responsibilities around the handoff file `.ralph/handoff.md`:

**At session start, BEFORE any other reads.** If `.ralph/handoff.md` exists, `Read` it as your very first action. Trust its pointers: read the files it lists in the order it lists them. Use the architectural facts it records as already-known (do not re-derive them from source). Only fall through to the full Read order below if (a) `handoff.md` does not exist, (b) `handoff.md` is older than the most recent commit on the current branch (its facts may be stale), or (c) `handoff.md`'s "next task" disagrees with the next unchecked task in `{{TASK_FILE}}` (a newer human edit overrides it).

**At session end, AFTER your last commit and BEFORE you stop.** Write `.ralph/handoff.md` for the next iteration. The file MUST follow this exact structure and stay under ~30 lines total. Do not narrate; record pointers.

```markdown
## Last completed
<task ID> (<commit SHA short>) — <one-line behavior summary>

## Next task: <task ID>
**Read these files first** (max 6, in priority order):
- <relative path>:<line range, optional>  ← <one-clause why>
- <relative path>:<line range, optional>  ← <one-clause why>
- ...

## Architectural facts from this iteration (skip rediscovery, max 5 bullets)
- <one fact, declarative, no narrative>
- <one fact>
- ...
```

Bounding rules: **fewer than 30 lines total, files-most-relevant section ≤ 6 entries, architectural-facts section ≤ 5 bullets, no narrative prose, no rationale, no apology, no praise, no scope discussion.** The next iteration is reading this for navigation, not for context. If the file balloons past 30 lines it becomes the same kind of overhead it was supposed to eliminate; trim ruthlessly.

Do not duplicate content already in `.ralph/guardrails.md` (general lessons), `.ralph/progress.md` (narrative session log), or `tasks.md` (task definitions). The handoff file is **navigation-only**: where to look, in what order, and what facts to take as given.

## Read order (targeted, not full-file)

This is the fallback path used when `.ralph/handoff.md` is absent or invalid:

1. **Constitution** — scan for any rules that affect this phase. Skip sections irrelevant to the current phase.
2. **Spec** — read only the user story or section this phase implements.
3. **Plan** — read only the architectural slice (module layout, tech decisions) this phase touches.
4. **Tasks** — find the next unchecked phase. Read the tasks belonging to *that phase only*. Use `grep -n '^## Phase'` and narrow `Read` ranges; do not slurp the whole file.

Each iteration is a fresh process with no memory of prior iterations. Rely on `git log`, `tasks.md` checkboxes, the handoff file, and the current code state — **not** on a narrative of what you "already read."

## One-phase-per-iteration rule (hard)

- **Pick the next unchecked phase** in `{{TASK_FILE}}`. A "phase" is a `## Phase N: …` section (Setup, Foundational, or a single user story US1/US2/…).
- **Work every unchecked task in that phase** within this iteration. Do not stop after a single task and do not skip to the next phase until every task in the current phase is checked and the phase gate is green.
- If `{{TASK_FILE}}` contains ultra-fine-grained atomic TDD pairs (e.g. `Write failing test for X` followed by `Implement X`), **batch them**: write the failing test and the implementation in the same iteration, producing one commit per conceptual unit. Do not split those pairs across iterations.
- If the entire phase is genuinely too large to fit in one iteration (rare — the 1M-context window can hold an entire user story), complete as many contiguous tasks as you can, commit your progress, and stop. The next iteration will pick up from your last commit.

## Task execution loop (inside a phase)

For each unchecked task in the phase, in order:

1. **Understand** — read only the files the task references.
2. **Implement** — make the minimum change. For test+implementation pairs, write the failing test first (TDD red), then the implementation (green), all in this task (red→green in one commit).
3. **Gate selection** — decide which single gate covers this task, based on what you touched:
   - **Run the final gate** (`{{GATE_RUN}} final {{FINAL_CHECK_COMMAND}}`) if this task (or the task spec line itself, tagged `[risky]`) touches any of:
     - Package barrel exports (`packages/*/src/index.ts`, `packages/*/index.ts`)
     - Prisma schema (`*.prisma`), Prisma seed, or DB constraint/seed loaders
     - NestJS module registration (`app.module.ts`, `imports:` arrays, new `*.module.ts` files wired into the app)
     - App bootstrap / entrypoints (`main.ts`, server entrypoints, Nuxt/Vue app roots)
     - `tsconfig.json` `include` / `exclude` / `paths`, or workspace-level `package.json` dependencies
     - Authentication, authorization middleware, or request-context builders
   - **Run the basic gate** (`{{GATE_RUN}} basic {{BASIC_CHECK_COMMAND}}`) otherwise — pure unit tests, in-memory logic, docs, type-only changes, self-contained refactors.
   - **Never run both.** The final gate is a strict superset.
   - **Always via `{{GATE_RUN}}`.** Bare `{{BASIC_CHECK_COMMAND}}` or `{{FINAL_CHECK_COMMAND}}` invocations are forbidden — see the Gate invocation contract above.
4. **Pre-commit gate** — the chosen gate **must pass before you commit** (wrapper exit code 0). If it fails, you caused the failure — diagnose via the persisted log per the Failure diagnosis protocol, fix, and re-run the same gate **exactly once**. Do not `git add` or `git commit` with a red gate. Do not commit and amend; fix first, commit once. Track in your own notes which gate you ran — the phase-completion protocol below uses this to skip a redundant run.
5. **Checklist gate** — scan `{{SPEC_DIR}}/checklists/` for unchecked items that block this task. If any exist, flag them in `.ralph/errors.log` and stop (do not mark complete).
6. **Mark complete** — edit `{{TASK_FILE}}` and change `[ ]` → `[x]` for this task. Before you do, **self-check the zero-baseline rule**: did the gate you ran for this task exit 0 in **this** iteration? If not — if any test is red, any lint failed, any type error remains — **do not flip the checkbox**. Fix the failure or escalate via `<ralph>GUTTER</ralph>`. "Unrelated" / "pre-existing" failures are never a valid excuse; see the Zero-baseline assumption above.
7. **Commit** — `git commit -m "[ralph][speckit] T### <task title>"`. Use the real task ID and title. Stage only the files you touched for this task (see Git Protocol below — **never use `git add .` / `git add -A` / `git add <directory>`**).
8. **Continue** to the next task in the same phase. Do not stop until the phase is complete or you are genuinely blocked.

## Phase completion protocol

After every task in the current phase is checked:

1. **Decide whether the phase gate needs to run**:
   - If the **last task's gate was the basic gate**, run `{{GATE_RUN}} final {{FINAL_CHECK_COMMAND}}` now. The phase as a whole has not yet been verified at the full-gate level.
   - If the **last task's gate was the final gate** (the final task of the phase was risky and self-gated), the phase is already verified — **skip the redundant run**. Running it again would just burn minutes.
2. If you ran the phase gate and it failed: the phase is not complete. **Diagnose via `.ralph/gates/final-latest.log` — do not re-run the gate to "see more."** Use the `Read` and `Grep` tools against that file (see Failure diagnosis protocol above). Check commits from this iteration (`git log --oneline -10`, `git show HEAD`, `git show HEAD~1`) and fix the regression in this same iteration before moving on. Re-run the final gate **exactly once** after the fix. Never mark a phase complete with a red final check.
3. When the gate is green, commit any residual changes with `git commit -m "[ralph][speckit][phase-N] <phase title> complete"`. If there are no residual changes, skip this commit — every task already committed its own work.
4. Apply the push policy defined in the Git Protocol section (rule 7 below). Do **not** assume pushing is desired — many projects treat feature branches as local-only. If the policy is `never`, skip this step entirely.

## Git Protocol (hard rules)

1. **Stage files by exact path only.** Every `git add` call MUST list explicit file paths, e.g. `git add packages/utils/src/capabilities.ts apps/api/tests/unit/utils/capabilities.spec.ts`. **Never** use `git add .`, `git add -A`, `git add <directory>`, or any glob. Before every commit, run `git status` and verify the staged list matches exactly the files you edited or created for this task. If you see files you did not touch — especially untracked files in directories you weren't working in — **they are orphans from a prior iteration or a user stash, not yours**. Do not stage them. Do not commit them. If you're not sure whether a file is yours, `git diff --cached <file>` and check: if you don't recognize the content, `git reset HEAD <file>` to unstage and leave it untracked.
2. **Never `git add` any path matched by `.gitignore`.** This includes `.ralph/`, generated source directories (e.g. `packages/*/generated/`, `dist/`, `build/`, Prisma client output), dependency caches, and anything else the project deliberately excludes. `git add` on an ignored path fails with exit 1 and aborts the whole commit. If you are unsure whether a path is ignored, run `git check-ignore <path>` first. Commit only source files, `tasks.md`, and other non-ignored content.
3. Write progress notes **directly** to `.ralph/progress.md` with the `Write`/`Edit` tool. Never via commits.
4. Commit after every completed task (not at the end of the phase). Each commit is a checkpoint the next iteration can resume from.
5. Never include `Co-authored-by` trailers. The commit message format is exactly `[ralph][speckit] T### <task title>`.
6. Never use `--amend`, `--force`, `reset --hard`, or any destructive git operation. If something went wrong, make a new commit that fixes it.
7. {{PUSH_GUIDANCE}} The policy is resolved from the breadcrumb file `.ralph/push-policy` at iteration start; if you disagree with it, do not override it from inside the loop — surface the disagreement in `.ralph/errors.log` and let the operator adjust the breadcrumb between iterations.

## Naming hygiene (hard rules — read carefully)

**The overriding rule: match the existing project's conventions at all times.**

Spec Kit artifacts — the spec slug, user-story numbers (`US1`, `US2`, …), task IDs (`T001`, …), phase numbering, and any other shorthand invented for this specific spec — are **process metadata**. They live in `{{SPEC_FILE}}`, `{{PLAN_FILE}}`, `{{TASK_FILE}}`, the spec directory name, the `[ralph][speckit] T### …` commit prefix, and any `[risky]` / `[P]` / `[US#]` tags. They do **not** belong in implementation artifacts. Implementation artifacts (source files, test files, directories, function names, class names, type names, database columns, configuration keys, shell scripts, docs) live forever; the spec gets archived. A reader six months from now should be able to understand every file and identifier you create **without** reading the spec.

This is a recurring failure mode on Spec Kit loops. Watch for it on every task.

**Concrete rules:**

1. **Match the root project's existing conventions.** Before creating any new file, directory, class, method, variable, type, config key, or database column, read the nearest related existing file and copy its style — casing, layout, dir grouping, naming pattern, vocabulary. Whatever the rest of the project does is authoritative. If the project groups tests by module, yours goes in the existing module directory. If the project uses kebab-case filenames with behavior descriptions, yours does the same. If the project uses camelCase method names built from domain nouns, yours does the same. The project's source tree, not the spec, is the naming authority.

2. **Name for behavior, not for origin.** A file, class, or method name should describe what it *does* or *asserts*, not which spec or user story produced it. `describe("US3: <feature slug> — <scenario>", …)` and `us3-feature-slug.spec.ts` are wrong; the correct forms describe the behavior under test (e.g. `describe("<behavior>: <scenario>", …)` and `<behavior-description>.spec.ts`). The same rule applies to every nested `it()` title, to directory names, to exported symbols, and to config sections.

3. **Do not carry the spec slug, user-story number, or task ID into any identifier.** If the spec uses a codename or shorthand for the feature (`<spec-slug>`, `<feature-codename>`, `<project-internal-abbreviation>`), check whether that term already appears broadly in the **real source tree** — modules, public types, database tables, API routes, top-level directories. If it does, it is part of the project's own vocabulary and you may use it. If it appears only in `specs/`, `.ralph/`, branch names, and commit message prefixes, it is spec-process vocabulary and must not leak into implementation.

4. **Never create a new top-level directory named after a spec slug or codename.** If the rest of the tree organizes work by module, feature, or domain, your new files go into the existing directory that matches the module, feature, or domain you are touching — not into a parallel `tests/<spec-slug>/` or `policies/<spec-slug>/` or `seed/<spec-slug>/` catch-all. If no suitable existing directory exists, the new directory you create should be named after the behavior or domain concept, not the spec.

5. **Before creating any new directory under a source root, test root, or package root, `Glob` the sibling parent to confirm the existing layout.** If a directory already exists for the concept you are working on, your file goes there. Do not create a parallel directory to hold the same concept. This is cheap (one tool call) and prevents the most common source of naming-hygiene regressions.

6. **Extend existing helpers in place — do not add a parallel second helper with a spec-flavored name.** If an existing repository / service / utility method already does 80% of what your task needs, either (a) generalize the existing method in place, or (b) rename it to something more specific and add a new more-general variant. Do **not** create a second method on the same class where the second name embeds spec vocabulary and the two methods return overlapping shapes. Two sibling methods on the same class that both load the same root entity with overlapping joins are a code smell the naming-hygiene rules exist to prevent. The same principle applies to parallel component files, parallel config entries, parallel table columns, and parallel type aliases.

7. **Maintenance edits on existing code must respect names the prior commits already settled on.** If a previous iteration renamed `<oldName>` to `<newName>` in commit X, do **not** resurrect `<oldName>` — check the git log (`git log --oneline --all -- <file>`) for recent renames before extending an existing surface. A recently-renamed identifier is a strong signal that a human or prior iteration made a deliberate naming decision; honour it.

If you catch yourself typing a spec slug, user-story number, task ID, or project-internal shorthand into a path or identifier you're about to create — **stop, re-read the nearest related existing file, and rename your new thing to match the existing project's style**. Renaming is cheap before commit; expensive after.

## Constitution compliance

Ground every decision in `{{CONSTITUTION_PATH}}`. If a task would violate it, mark the task blocked (see Blocked-phase protocol) and stop — do not work around the constitution.

## Blocked-phase protocol

If you cannot complete a task or phase:

- Append `<!-- blocked: <one-line reason> -->` to the blocking task's line in `{{TASK_FILE}}`.
- Write a longer explanation to `.ralph/errors.log` with the task ID, what you tried, and what the human needs to decide.
- Do **not** mark `[x]` for the blocked task.
- If ≥ 2 tasks in the current phase are blocked, or the phase is structurally impossible, emit `<ralph>GUTTER</ralph>` so the human is pulled in.

## Completion protocol

- When every `[ ]` in `{{TASK_FILE}}` is checked **and** `{{GATE_RUN}} final {{FINAL_CHECK_COMMAND}}` passes (wrapper exit 0), emit `<promise>ALL_TASKS_DONE</promise>`.
- The stream parser will re-scan `{{TASK_FILE}}` before honoring the promise. Do not emit the sigil unless the checkboxes actually show completion — a hallucinated promise wastes an iteration.

## Observability (operator surfaces)

Operators inspecting loop progress use these files — keep them clean and informative:

- `.ralph/activity.log` — concise per-action log (commits, pushes, gate starts/ends, shell commands, reads, writes). Every gate-run.sh invocation writes a `🧪 GATE start` and `🧪 GATE end` line here automatically.
- `.ralph/gates/<label>-latest.log` — full, unfiltered output of the most recent gate run for that label. Symlinked to a timestamped file; older runs are retained (last 10 per label).
- `.ralph/errors.log` — longer explanations for blocked tasks or structural problems the operator needs to resolve.
- `.ralph/progress.md` — narrative session/iteration summary.
- `.ralph/guardrails.md` — lessons learned from prior failures. Add a new Sign here whenever you encounter a repeat-failure pattern.
- `.ralph/recovery-hint.md` — transient breadcrumb written by the loop when the prior iteration tripped a recoverable stuck pattern (same shell command failed twice, or the same file was rewritten 5× in 10 min). If a `## Recovery Hint from Prior Iteration` section appears at the very top of this prompt, it came from this file and **is authoritative steering** — the prior run was killed mid-flight; do not repeat what it just tried. The hint is consumed once and deleted; you will not see it again.

If you would normally tell the operator "I'll paste the failing output below," instead tell them "see `.ralph/gates/<label>-latest.log`" — they already have it.

## Commit message format

`[ralph][speckit] T### <task title>` — T### is the real task ID from `{{TASK_FILE}}` (e.g. `T027`). Never use placeholders like `<description>` or `TODO`. Phase-completion commits use `[ralph][speckit][phase-N] <phase title> complete`.

## Working directory

You are already in a git repository. Do **not**:
- run `git init`
- run scaffolding commands that create nested directories
- create worktrees or branches unless the task explicitly asks

Work in the current directory.

## Learning from failure

If a step fails, check `.ralph/errors.log` and `.ralph/guardrails.md` for a pattern. If the same failure has happened before, add a `Sign` to `.ralph/guardrails.md` describing the trigger and the fix. The next iteration will read it.

---

Begin by finding the next unchecked phase in `{{TASK_FILE}}` and working every task in that phase end-to-end.
