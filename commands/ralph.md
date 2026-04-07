---
description: Print the terminal command to launch the Ralph autonomous loop
argument-hint: "[--cli claude|cursor-agent] [--prompt | --prompt-file <path> | --spec [name]] [-n N]"
---

Ralph is a **shell script that runs in a terminal**, not inside this session. This slash command is a convenience — it just prints the command you need to run in a separate terminal window. The loop itself runs there, independent of any editor, and you choose which agent CLI (`claude` or `cursor-agent`) it drives at script-execution time.

Copy and paste this into a terminal open to the current repo:

```bash
"${CLAUDE_PLUGIN_ROOT}/shared-scripts/ralph-setup.sh" $ARGUMENTS
```

Any arguments you pass after `/ralph` are forwarded to the launcher:

- `/ralph` → fully interactive (CLI picker, prompt picker, model picker)
- `/ralph --cli claude --spec` → pick newest spec, drive Claude Code
- `/ralph --cli cursor-agent --prompt-file PROMPT.md -n 30` → scripted
- `/ralph --cli claude -m opus --spec -n 20` → fully unattended on newest spec

**Blast radius**: Ralph runs the agent with all tool approvals pre-granted (`--dangerously-skip-permissions` for `claude`, `--force` for `cursor-agent`). Use only in a dedicated worktree with a clean git state — never against a repo holding uncommitted work you care about.

See `${CLAUDE_PLUGIN_ROOT}/README.md` for full flag docs, prerequisites, and troubleshooting.
