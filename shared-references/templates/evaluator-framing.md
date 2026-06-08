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
