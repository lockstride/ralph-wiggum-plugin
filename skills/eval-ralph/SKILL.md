---
name: eval-ralph
description: Deeply evaluate the performance of a Ralph Wiggum autonomous loop run from its on-disk logs. Use when the user wants to analyze, review, grade, or post-mortem a Ralph loop / Ralph session / ralph-wiggum-plugin run — typically phrased as "evaluate loop <fragment>", "how did loop 152651 do", "analyze the ralph run in <worktree>", "did our plugin changes work", or any request to judge how a Ralph loop performed in light of recent plugin changes. The user usually supplies a loop fragment (a 6-digit-ish id like "152651") that names a worktree. Trigger even if they don't say the word "skill".
argument-hint: "[loop-fragment] [specific question]"
---

# eval-ralph — Ralph loop performance evaluation

This skill turns a Ralph loop's on-disk state into a rigorous performance
evaluation. Ralph is the `ralph-wiggum-plugin` autonomous dev loop: it drives a
CLI agent (Claude Code / cursor-agent) through repeated "loops" against a Spec
Kit task list, gating progress behind test commands and a completion guard.

Your job: locate the run, read its breadcrumbs, reconstruct what happened, and
answer the user's evaluation questions with evidence (timestamps, exit codes,
file:line). A clean run with no problems is a perfectly valid finding — don't
manufacture issues.

## What the user wants answered

Unless they ask something narrower, structure the report around these five:

1. **Generally, how did the loop(s) perform?** Throughput, wall-clock, whether
   it reached COMPLETE, how many loops it burned.
2. **What did it do well?**
3. **What did it do poorly?**
4. **Are the recent plugin improvements working?** Break this down
   *per-improvement* — for each recent change, cite the log evidence that it
   fired correctly (or didn't). Get the list of recent changes from the plugin
   repo (see "Establish the baseline" below).
5. **Any specific failure question the user asked** (e.g. "why did it fail to
   clear the cache / run all-check / rotate context?"). Answer mechanistically,
   tracing the exact guard/gate code path, not just symptoms.

End with a **summary evaluation + actionable recommendations**. A perfect score
with zero recommendations is a valid answer if the run earned it.

## Step 1 — Locate the run from the fragment

The user gives a fragment like `152651`. Find the worktree:

```bash
# Worktrees are usually <repo>.<type>-<fragment> siblings under ~/development
find ~/development -maxdepth 1 -name "*<fragment>*" -type d
# Confirm via git if you know the parent repo:
git -C ~/development/<repo> worktree list | grep <fragment>
```

If nothing matches under `~/development`, ask the user where the worktree or
devbox lives. A devbox may expose the same `.ralph/` tree over SSH or a mounted
path — read it the same way once you have a filesystem path.

The state you care about lives in `<worktree>/.ralph/`.

## Step 2 — Read the state, in this order

Read breadcrumbs before narrative; they're cheap and orient you.

| File | What it tells you |
|------|-------------------|
| `.ralph/task-summary` | done/total/remaining counts + the task list head. Quick "did it finish?" |
| `.ralph/acceptance-report.md` | Eval-loop output: Status (CLEAN/…), Last loop, Last mode (VERIFIER/REWORK), Gaps, History. Present ⇒ an eval loop ran. |
| `.ralph/eval-ground-truth` | Path to the spec `tasks.md` the eval graded against. |
| `.ralph/gates/` | Per-label gate results: `<label>-latest.{exit,cmd,log,summary}`. `exit` is the authoritative pass/fail. Labels: `basic`, `final`, `e2e`, `lint`, `custom`, `eval-*`. |
| `.ralph/errors.log` | Append-only list of every failed shell/gate — the fastest map of where it struggled. |
| `.ralph/handoff.md` | What the agent left for its next self. Reveals where it got stuck. |
| `.ralph/activity.log` | The full narrative (can be thousands of lines). Read last after you know what to look for. |

`activity.log` is large — don't dump it. Orient with grep first:

```bash
cd <worktree>
grep -nE "LOOP [0-9]+ (START|END)|SESSION START|COMPLETE|BLOCKED|GUTTER" .ralph/activity.log
grep -niE "gate (start|end|blocked)|guard (deny|rewrite)|cache|all-check" .ralph/activity.log
```

Then `sed -n 'A,Bp'` the interesting regions. Read the activity-log legend from
the emoji: 🧪 gate, 🔀 guard rewrite, ⛔ guard deny, 🚨 GUTTER (agent stuck),
✅ COMPLETE, 🛑 COMPLETE BLOCKED, 🟢 normal shell/tool.

## Step 3 — Distinguish loop types

A single session often contains two phases back-to-back:

- **Implementation loop** — `speckit-implement`. Starts with many tasks
  (`LOOP 1 START — Tasks: 0/42 …`). Gates under label `final` (the completion
  gate, default `pnpm all-check`). Exits when every task is `[x]` **and** the
  `final` gate exits 0.
- **Eval / acceptance loop** — the `running-acceptance-evaluation` orchestrator.
  Starts with `Tasks: 0/1` (the synthetic "All acceptance criteria met"
  task), reads `acceptance-report.md`, picks **VERIFIER** (no open gaps) or
  **REWORK** (open `[ ]` gaps), and gates under `eval-*` labels (e.g.
  `eval-final`). Output is `acceptance-report.md`, not committed.

Evaluate each phase on its own terms, then give an overall verdict.

## Step 4 — Map gate / guard / cache behavior (the usual culprit)

Most "why did it thrash?" questions come down to the guard. Key mechanics
(source: `ralph-wiggum-plugin/shared-scripts/`). Verify against the **installed
version** the run used — the activity log shows the path, e.g.
`…/ralph-wiggum-plugin/<version>/shared-scripts/gate-run.sh`.

- **Per-label gate cache** (`ralph-guard.sh` `_guard_bash`): a gate is blocked
  with *"Gate '<label>' already ran since last code write"* when
  `last_gate_ts.<label> >= last-write-ts`. Crucially, **`last-write-ts` is bumped
  only by Write/Edit/MultiEdit (code writes)** — never by Bash. So environmental
  remediation (`nx reset`, `docker compose up/down`, daemon restarts) does *not*
  invalidate the cache. There is intentionally no `--force`; deleting breadcrumbs
  doesn't help; `rm` of `.ralph/` is denied as state-tampering.
- **Completion check** (`ralph-common.sh` `_complete_allowed`): the impl loop and
  the eval loop gate on **different tiers** (0.14.3+). The tier command comes from
  `.ralph/command-policy` `[gates]` (the single source of truth — no defaults, no
  breadcrumb fallbacks):
  - **impl loop → `full`** (e.g. `pnpm all-check`): honored only when
    `gates/full-latest.cmd` matches the pinned `full` command **and**
    `full-latest.exit == 0`.
  - **eval loop → `final`** (e.g. `pnpm all-check:no-cache`): keyed on
    `gates/final-latest.*` instead. `ralph-evaluate.sh` exports `RALPH_EVAL_LOOP=1`
    and `_complete_allowed` reads it to pick the tier.
  So an impl loop can reach COMPLETE off a green `full` gate with **no `final` gate
  yet** — don't chase a phantom missing `final` during the impl phase. A pass under
  any *other* label doesn't count toward completion, and the guard now **blocks**
  running a pinned tier command under the wrong label (it escapes the tier cache),
  so the old `custom`-relabel escape is closed.
- **Gate lock**: `gate-run.sh` serializes a label behind a lock; a long gate
  still running ⇒ `GATE BLOCKED — could not acquire lock after 60s`, after which
  the agent may fall through to a raw (unbreadcrumbed) run.
- **Direct-runner denial**: raw `vitest`/`cypress`/`jest`/`tsc --noEmit` are
  denied unless routed through `gate-run.sh`; `[rewrite]` rules transparently
  rewrite (e.g. `pnpm nx` → project script).

**The cache is a forcing function, not a bug.** Its purpose is to enforce a core
Ralph principle: *whenever a gate/test fails, the agent owns it and must fix the
root cause — regardless of origin (flaky infra, env, "not my code"). Re-running,
resetting caches (`nx reset`), or restarting infra (docker/daemon) is dodging
ownership and will not change the result.* The deny message
("edit code to address the failure first, then retry") says exactly this. When
evaluating, **do not** recommend weakening the cache (env-mutation cache-busting,
flaky re-run budgets, `--force`) — that rewards the anti-pattern Ralph exists to
prevent.

The classic *misbehavior* cascade to flag: a flaky env-dependent tier gate
(`full` in the impl loop, `final` in the eval loop) fails → instead of fixing the
flakiness at its source, the agent tries to make it pass without a code change →
`nx reset` / docker up-down / daemon restart → cache correctly blocks the re-run →
agent tries the raw command (lock contention), tries to `rm` the lock or a gate
breadcrumb (denied), tries re-running the tier command under a different label
(now **denied** by the guard) → ~tens of minutes wasted, escaping only when a
*genuine* code/config fix bumps `last-write-ts`. When you see this, the agent
dodged ownership. As of 0.14.x the main relabel escape hatch is **closed** (the
guard blocks a pinned tier command under the wrong label, and `rm` of `.ralph/`
breadcrumbs is denied as state-tampering); the remaining hatch to watch for is:

- the raw-run fallthrough after `GATE BLOCKED` (untracked re-run).

Recommend closing any that remain, and recommend the agent fix flaky infra at the
source (e.g. harden a health check) — never recommend re-run tooling.

## Step 5 — Establish the plugin-change baseline (for question 4)

To judge "are our improvements working," you need the list of recent changes.
This needs the **development clone** (git history is not in the installed copy) —
resolve it per `${CLAUDE_PLUGIN_ROOT}/shared-references/locating-the-plugin-clone.md`:

```bash
cd "${RALPH_PLUGIN_DIR:-$HOME/development/ralph-wiggum-plugin}"
git log --oneline -20
cat .claude-plugin/plugin.json   # current version
```

Cross-reference the installed version the run used (from the activity-log gate
paths) against recent commits/tags. For each recent change, find the log
evidence it exercised: e.g. an `eval-*` label change ⇒ look for
`GATE start label=eval-final … exit=0`; an acceptance-report write-allowlist
change ⇒ look for a `WRITE …/acceptance-report.md` with no `⛔ GUARD DENY`;
a status-report change ⇒ inspect `ralph-status.sh` output if captured. Mark each
✅ working / ⚠️ mixed / ❌ broken / ➖ not exercised, with the evidence line.

## Report structure

Use this shape (adapt headers to the user's actual questions):

```
## Loop <fragment> — evaluation

**TL;DR** — one or two sentences: did it finish, was it clean or painful, did the
plugin changes hold.

### 1. General performance
Phases (impl loop N loops over Xh; eval loop M min), final state, wall-clock,
loops wasted.

### 2. What went well
Bullets with evidence.

### 3. What went poorly
Bullets with evidence (timestamps / exit codes / file:line).

### 4. Are the improvements working? (per-improvement)
| Change (ver) | Verdict | Evidence |
...

### <specific failure question, if any>
Mechanistic trace through the guard/gate/cache code path.

### Summary & recommendations
Numbered, actionable, severity-tagged. Distinguish plugin bugs from
project-side flakiness. "No changes needed" is valid.
```

## Principles

- **Evidence over vibes.** Every claim ties to a timestamp, exit code, or
  file:line. Quote the log.
- **Mechanism over symptom.** "It thrashed" is useless; "the per-label cache
  blocked re-running `final` because `nx reset` doesn't bump `last-write-ts`" is
  the answer.
- **Separate regressions from pre-existing limits.** If the recent changes all
  fired correctly and the pain came from an older design gap or project-side
  flakiness, say so plainly — that protects the changes from blame.
- **A perfect score is allowed.** Don't invent problems to look thorough.
