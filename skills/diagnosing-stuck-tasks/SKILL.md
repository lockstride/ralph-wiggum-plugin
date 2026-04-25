---
name: diagnosing-stuck-tasks
description: Switches the Ralph agent into exploratory diagnosis mode when the same gate keeps failing or the same task has been in flight too long. Use when the loop emits a SUGGEST_SKILL signal pointing here, when the same gate-run.sh command has failed 3+ times, when a single task has consumed more than 20 minutes without a commit, or when the agent is otherwise about to spin in a fix-then-fail loop. Suspends the procedural execute-gate-commit cycle, reads the full failure log, questions whether the test itself is wrong, lists 2-3 alternative root causes, runs layer-bypassing diagnostic commands (curl / playwright), then either commits to a new approach or emits GUTTER. Writes findings to `.ralph/diagnosis.md` for the next iteration.
---

# Diagnosing stuck tasks

You are switching cognitive postures: from "execute the next prescribed step" to "step back and investigate." The procedural rules of the main loop (one gate per task, commit after every task, do not end your turn) are temporarily relaxed so you can reason about the problem itself.

## When to invoke

The loop suggests this skill when one of the following triggers fires:

- Same `gate-run.sh` command has failed 3+ times in this iteration
- Same file has been rewritten 5+ times within 10 minutes (file thrash)
- The current task has been in flight more than 20 minutes with no commit
- You yourself notice you've made the same edit-then-fail cycle 2-3 times

The loop will write `.ralph/skill-suggestion` with the trigger context. Read it as your first action.

## Diagnosis workflow

Copy this checklist and check off items as you go:

```
Diagnosis Progress:
- [ ] Step 1: Read the suggestion context and the full latest gate log
- [ ] Step 2: State the problem in one sentence
- [ ] Step 3: List 2-3 candidate root causes (not just the obvious one)
- [ ] Step 4: Run layer-bypassing diagnostics for each candidate
- [ ] Step 5: Decide: pick the right candidate, or escalate to GUTTER
- [ ] Step 6: Write findings to .ralph/diagnosis.md
```

### Step 1: Read context

- `Read .ralph/skill-suggestion` if it exists — the loop's reason for invoking you.
- `Read .ralph/gates/<label>-latest.log` **in full** (not tail). The bounded summary you saw before is no longer enough; you need the surrounding context.
- `tail -n 50 .ralph/activity.log` — your own recent actions. Look for repeated patterns.

### Step 2: State the problem in one sentence

Write a one-sentence problem statement. Examples:
- "Cypress integration test asserts redirect away from /sign-in but the URL stays on /sign-in for 30s."
- "Vitest unit test for `RegisterHandler` expects `findByEmail` to be called but it isn't."
- "Build fails because `@nx/eslint-plugin` 22.7.0 doesn't export `flatConfig`."

If you can't state it cleanly in one sentence, you're confused about the failure — read the log again before continuing.

### Step 3: List 2-3 candidate root causes

The instinct after a gate failure is "fix the production code." That's one candidate. List at least two more. Common alternatives:

- **The test is wrong.** Maybe it asserts behavior that has changed. Maybe it depends on stale fixtures.
- **The wrong layer.** A failing browser test might be a server-route bug, a proxy bug, a cookie bug, OR a Cypress runner bug — not a frontend bug.
- **An environmental issue.** Cache state, daemon state, dirty fixtures, missing env var, port conflict.
- **An upstream change.** Did dependencies bump recently? Did a refactor touch a shared module?

Force yourself to write all 2-3 candidates BEFORE picking one. Otherwise you'll latch onto the first plausible explanation.

### Step 4: Run layer-bypassing diagnostics

For each candidate, run **one** diagnostic that would distinguish it from the others. Tools you have:

- **`curl`** — bypass Cypress/browser entirely; talk directly to the failing endpoint. If `curl` succeeds against the same URL, the bug is in the browser/test layer, not the server.
- **`mcp__playwright__*`** (if available) — drive the browser interactively. Open the failing page, submit the form, inspect network tab and DOM. Often diagnoses proxy/cookie issues in seconds.
- **`Grep` against recent commits** — `git log --oneline -20`, then `git show <sha>` for anything that touched the failing layer.
- **Coverage / uncovered-branch reports** — only if you have a specific hypothesis about untested code; don't fish.
- **`Read` the actual test file in full** — does the assertion match what you think it does?

**Do not commit anything during diagnosis.** Diagnostics are throwaway; you're gathering evidence, not landing a fix.

### Step 5: Decide

After diagnostics, one of three outcomes:

1. **You found the right layer and have a small fix.** Exit diagnosis mode, return to the main loop's procedural cycle: edit → gate → commit. Mention in your commit message what diagnosis revealed.
2. **The fix is large or touches scope outside the current task.** Write a finding to `.ralph/diagnosis.md` describing what's needed, then emit `<ralph>GUTTER</ralph>`. The human will see the diagnosis and decide.
3. **You can't isolate the cause after honest diagnostics.** Same outcome: write what you learned to `.ralph/diagnosis.md`, emit `<ralph>GUTTER</ralph>`. **Don't loop back into "let me try one more fix"** — that's the pattern this skill exists to break.

GUTTER is the right answer ~50% of the time you reach this skill. It is **not failure** — it's escalation. The human has fresh eyes and can decide to (a) fix the test, (b) defer the task, (c) provide more context for the next iteration.

### Step 6: Write `.ralph/diagnosis.md`

Whether you continue or escalate, write findings:

```markdown
# Diagnosis: <task ID> at <YYYY-MM-DD HH:MM>

## Problem
<one sentence>

## Candidates considered
1. <candidate> — diagnostic: <what you ran> — result: <ruled in/out>
2. <candidate> — diagnostic: <what you ran> — result: <ruled in/out>
3. <candidate> — diagnostic: <what you ran> — result: <ruled in/out>

## Conclusion
<one of: "Continuing with candidate N — small fix" | "Escalating GUTTER — needs human decision" | "Escalating GUTTER — could not isolate">

## Notes for next iteration
<2-3 bullets max. What the next attempt should know.>
```

The next iteration will read this on startup and avoid re-walking the same diagnostic ground.
