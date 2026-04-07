---
description: Run exactly one Ralph iteration in a terminal (smoke test your prompt)
argument-hint: "[--cli claude|cursor-agent] [--prompt | --prompt-file <path> | --spec [name]]"
---

Run a single iteration of the Ralph loop — useful for smoke-testing your prompt or spec before committing to a full AFK run.

From a terminal in the current repo, run:

```bash
"${CLAUDE_PLUGIN_ROOT}/shared-scripts/ralph-once.sh" $ARGUMENTS
```

After the iteration finishes, review:

- `git log --oneline -5` — any commits the agent made
- `cat .ralph/progress.md` — the progress log
- `tail .ralph/activity.log` — token usage and tool activity
- `cat .ralph/errors.log` — any failures detected

If the iteration looks good, switch to `/ralph` for the full loop.
