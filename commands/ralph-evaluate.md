---
description: Print the terminal command to launch Ralph's acceptance evaluation loop
argument-hint: "[--cli claude|cursor-agent] [--prompt | --prompt-file <path> | --spec [name]] [-n N] [--fresh]"
---

Ralph Evaluate is a **shell script that runs in a terminal**, not inside this session. It runs a second Ralph loop *after* a main run has finished, with an orchestrator prompt that alternates VERIFIER and REWORK roles (each delegated to a sub-agent via the Task tool) and maintains `.ralph/acceptance-report.md`.

Copy and paste this into a terminal open to the current repo:

```bash
"${CLAUDE_PLUGIN_ROOT}/shared-scripts/ralph-evaluate.sh" $ARGUMENTS
```

Any arguments you pass after `/ralph-evaluate` are forwarded to the launcher:

- `/ralph-evaluate --prompt` → ground truth = `PROMPT.md` in repo root
- `/ralph-evaluate --prompt-file custom.md` → ground truth = a specific file
- `/ralph-evaluate --spec` → ground truth = newest `specs/*/tasks.md`
- `/ralph-evaluate --prompt --fresh` → delete existing report and start over
- `/ralph-evaluate --prompt -n 8 --cli claude -m opus` → 8-iter cap on Opus

The loop exits cleanly when the verifier flips the report's top-level "All acceptance criteria met and verified" checkbox to `[x]`, or when the iteration cap (default 5) is hit. To also auto-run this after a main Ralph loop completes, pass `--evaluate` to `/ralph`.

**Blast radius**: same as the main Ralph loop — the agent runs with all tool approvals pre-granted. Sub-agents spawned via the Task tool inherit that scope. Use only in a dedicated worktree.

See `${CLAUDE_PLUGIN_ROOT}/README.md` for the full evaluation-loop contract and troubleshooting.
