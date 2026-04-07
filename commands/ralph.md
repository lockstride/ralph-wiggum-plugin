---
description: Launch the Ralph Wiggum autonomous development loop in a terminal
argument-hint: "[--cli claude|cursor-agent] [--prompt | --prompt-file <path> | --spec [name]] [-n N] [-y]"
---

Ralph is a terminal-run loop — it does **not** run inside this Claude Code session. It shells out to either the `claude` or `cursor-agent` CLI in a separate terminal so it can survive context rotations, token thresholds, and AFK runs.

To start the interactive launcher from a terminal in the current repo, run:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/shared-scripts/ralph-setup.sh" $ARGUMENTS
```

If you pass flags after `/ralph`, they will be forwarded to the launcher, e.g.:

- `/ralph --cli claude --spec` → pick the newest spec, drive Claude Code
- `/ralph --cli cursor-agent --prompt-file PROMPT.md -n 30 -y` → scripted
- `/ralph --cli claude --spec --yes` → fully unattended on newest spec

Reminder: Ralph runs the agent with all tool approvals pre-granted. Use it only in a dedicated worktree with a clean git state — never against a repo holding uncommitted work you care about.

See `${CLAUDE_PLUGIN_ROOT}/README.md` for full flag docs, prerequisites, and troubleshooting.
