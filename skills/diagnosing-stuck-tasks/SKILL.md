---
name: diagnosing-stuck-tasks
description: Permission to step out of the procedural execute-gate-commit cycle when the loop's normal flow isn't working. Suspends procedural rules so you can investigate however the situation demands.
---

# Diagnosing stuck tasks

You are switching from "execute the next step" to "understand why this isn't working." No procedural rules apply until you understand the problem.

## What changes

- Run whatever commands help you understand the failure — `curl`, `lsof`, `docker ps`, direct script execution, individual test files, whatever answers the question.
- Read anything — screenshots, network logs, container state, env files, test setup code, module wiring, constructor signatures.
- Don't commit during diagnosis. Diagnostic edits are throwaway. The fix comes after you understand.
- Take as much time as you need.

## Useful instincts

- **The symptom is rarely the cause.** Trace the actual call graph instead of staring at the assertion.
- **Run the smallest thing that reproduces.** If a single test file isolates the bug, run just that file.
- **Question the test, not just the code.** Maybe the test setup is stale, the mocks are wrong, or the wiring doesn't match the real constructor.
- **Ask whether the right layer is failing.** Layer-bypassing diagnostics collapse this fast.
- **Check what changed recently.** `git log --oneline -20` and `git show <sha>` for anything that touched the failing layer.

## When to escalate

If you've genuinely investigated and can't isolate the cause, emit `<ralph>GUTTER</ralph>` with what you learned. GUTTER is escalation to a human with fresh eyes, not failure.

## Leave a trail

Write what you learned to `.ralph/diagnosis.md` — a few bullets the next loop or operator can read in 30 seconds.
