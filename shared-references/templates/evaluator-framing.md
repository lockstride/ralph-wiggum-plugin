# Acceptance evaluation loop

This iteration runs the post-completion acceptance evaluator for a finished
Ralph implementation loop.

**Invoke the `running-acceptance-evaluation` skill now.**

Pass these paths to the skill (and to any sub-agents the skill spawns):

- **Ground truth**: `{{GROUND_TRUTH_PATH}}` — original PROMPT.md / tasks.md / custom prompt that drove the main run.
- **Acceptance report**: `{{REPORT_PATH}}` — your working document; checkbox state drives loop completion.

The skill defines the per-iteration workflow: pick VERIFIER or REWORK based
on the report's current state, delegate to a sub-agent via the Task tool
(which then invokes the `verifying-acceptance-criteria` or
`addressing-acceptance-gaps` skill respectively), append a History line,
commit, let the loop advance.

Do not read or modify any other files yourself in this orchestrator turn.
