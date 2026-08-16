# Acceptance evaluation loop

Invoke the `running-acceptance-evaluation` skill and follow it — it is the
single source of truth for this loop's workflow.

Paths to pass to the skill (and to any sub-agent it spawns):

- **Ground truth**: `{{GROUND_TRUTH_PATH}}` — original PROMPT.md / tasks.md / custom prompt that drove the main run.
- **Acceptance report**: `{{REPORT_PATH}}` — your working document; checkbox state drives loop completion.

The skill picks VERIFIER or REWORK and runs the verify/rework work in a
sub-agent via the Task tool (`verifying-acceptance-criteria` or
`addressing-acceptance-gaps`) — in the sub-agent, not inline in this
orchestrator turn, so its context stays out of yours.

Do not signal COMPLETE directly — loop completion keys on the acceptance
report's top-level checkbox, which only the VERIFIER/REWORK workflow may
flip. A green gate alone will be rejected.

**How this loop ends: you end your turn.** After the sub-agent returns and you
have appended to History, just stop. The loop re-enters with a fresh context
and picks the next mode from the report. COMPLETE is emitted only when every
row of the report is terminal AND the top-level checkbox is `[x]` — the single
early-exit case in the skill. Signalling COMPLETE with criteria still open does
not shortcut anything: the loop checks the report, rejects the signal, and you
have spent a loop learning what the report already said.
