---
description: Clean up Ralph state files (.ralph/.iteration and .ralph/effective-prompt.md)
---

Remove Ralph's transient state files so the next run starts fresh. This does **not** touch `.ralph/progress.md`, `.ralph/guardrails.md`, `.ralph/errors.log`, or `.ralph/activity.log` — those are your durable history.

Run from a terminal in the repo root:

```bash
rm -f .ralph/.iteration .ralph/effective-prompt.md .ralph/.parser_fifo
echo "✓ Ralph state cleaned. Durable logs preserved."
```

If you also want to wipe durable logs (rarely needed):

```bash
rm -rf .ralph/
```
