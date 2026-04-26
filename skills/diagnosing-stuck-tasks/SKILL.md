---
name: diagnosing-stuck-tasks
description: Permission to step out of the procedural execute-gate-commit cycle when the loop's normal flow isn't getting unstuck. Use when the loop emits a SUGGEST_SKILL signal pointing here, when the same gate has failed multiple times, when a task has been in flight much longer than usual without progress, or when you notice yourself about to attempt the same fix-then-fail cycle a third time. Suspends the procedural rules so you can investigate however the situation demands. Writes findings to `.ralph/diagnosis.md` so the next loop benefits from what you learned.
---

# Diagnosing stuck tasks

You are switching cognitive postures: from "execute the next prescribed step" to "understand why this isn't working." The procedural rules of the main loop are temporarily relaxed.

## When this fires

The loop suggests this skill when:

- The same `gate-run.sh` command has failed 3+ times in this loop
- The same file has been rewritten 5+ times within 10 minutes
- The current task has been in flight much longer than its peers without a commit
- You notice yourself about to make the same edit-then-fail cycle a third time

The loop writes `.ralph/skill-suggestion` with the trigger context. Read it as your first action.

## What changes

The procedural rules don't apply in this mode. Specifically:

- You can run things other than `{{GATE_RUN}}` to understand the failure faster — `curl`, `lsof`, `docker ps`, direct script execution, whatever answers the question.
- You can read screenshots, network logs, container state, env files — anything the gate wrapper isn't surfacing.
- You can edit env vars, spin up subsystems manually, bypass parts of the test infrastructure to isolate where the failure actually lives.
- You don't commit during diagnosis. Diagnostic edits are throwaway. The fix comes after you understand.
- You take as much time as you need. The 3-try gate budget doesn't apply — you're not retrying, you're investigating.

The intent is **understanding**, not execution. Once you understand, the actual fix is usually small and the procedural cycle resumes naturally.

## Useful instincts

A few things that often pay off in stuck cases — not a procedure to follow, just patterns worth knowing:

- **The symptom is rarely the cause.** A test that asserts "URL not /sign-in" might be failing because of a session cookie, a workspace lookup, a downstream middleware bounce — none of which are in the test file. Trace the actual call graph instead of staring at the assertion.
- **Run the smallest thing that reproduces.** If the full gate takes 10 min and a `curl` against the failing endpoint takes 2 sec, prefer the `curl`. If a single test file isolates the bug, run just that file. Don't iterate against the slowest possible reproduction.
- **The screenshot is often the answer.** Cypress / Playwright write screenshots to `<project>/cypress/screenshots/<spec>/<test> (failed).png`. The image typically shows the URL bar, the network panel, and the page state in one frame. You can `Read` images directly.
- **Question the test, not just the code.** Maybe the assertion is wrong. Maybe the test depends on stale fixtures. Maybe the test was written before a refactor. The fix isn't always in production code.
- **Ask whether the right layer is failing.** A failing browser test could be a frontend bug, a server-route bug, a proxy bug, a cookie bug, an infra bug, or a Cypress bug. Layer-bypassing diagnostics (curl past the browser, hit the API directly, check the cookie shape, look at the proxy headers) collapse this fast.
- **Check what changed recently.** `git log --oneline -20` and `git show <sha>` for anything that touched the failing layer. The bug usually lives in a recent commit.

## When to escalate

If you've genuinely investigated and you can't isolate the cause, or the fix is too large for the current task's scope, emit `<ralph>GUTTER</ralph>`. GUTTER is escalation, not failure — the human has fresh eyes and can decide to fix the test, defer the task, or supply context. **Don't loop back into "let me try one more fix"** — that's the pattern this skill exists to break.

## Leave a trail

Whether you continue with a fix or escalate, write what you learned to `.ralph/diagnosis.md`. Keep it short — a few bullets the next loop (or the next operator) can read in 30 seconds:

```markdown
# Diagnosis: <task ID> at <YYYY-MM-DD HH:MM>

## What was failing
<one sentence>

## What I learned
<2-4 bullets about the actual root cause / the layers you ruled out>

## Where I left it
<one of: "Small fix in progress, see commit X" | "GUTTER — needs human decision because Y" | "GUTTER — could not isolate after investigating A, B, C">
```

The next loop reads this on startup and skips the diagnostic ground you already covered.
