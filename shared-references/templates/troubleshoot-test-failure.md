# Troubleshoot: Gate Failure (auto-injected)

The prior turn hit {{CONSECUTIVE_FAILURES}} consecutive gate failures on
`{{FAILING_LABEL}}` and was ended by the loop.

## Failing gate log

`.ralph/gates/{{FAILING_LABEL}}-latest.log`

Read it before doing anything else.

## Diagnostic checklist

1. **Read the log** — find the first error line, not the last.
2. **Check the file named in the error** — is it a file you edited, or
   one you haven't touched? If untouched, you're fixing the wrong layer.
3. **Layer-bypass test** — if the error is a network/port/container
   issue, `curl`/`lsof`/`docker ps` answer faster than re-running the
   gate.
4. **Diff check** — `git diff HEAD~3` may show where the regression
   was introduced.

## After diagnosis

Make the smallest fix that addresses the root cause. Run the gate once.
If it passes, commit and resume the task list. If it fails for a
*different* reason, repeat this checklist. If it fails for the *same*
reason after a genuine fix, emit `<ralph>GUTTER</ralph>` with what you
learned — escalation to a human is the correct move.
