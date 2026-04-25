---
name: reviewing-loop-progress
description: Produces a one-paragraph meta-review of recent Ralph loop activity — what the agent has been doing, what's working, what's not, and a recommendation for the next move. Use when the agent feels uncertain about whether to continue with the current approach, when 4+ consecutive tasks have committed but the gate quality is unclear, when token usage is climbing fast without commensurate task progress, or as a self-check before invoking `diagnosing-stuck-tasks`. A lighter alternative to full diagnosis — useful for "am I still on the right track" questions, not "this specific gate is failing."
---

# Reviewing loop progress

Lightweight meta-reflection. Different from `diagnosing-stuck-tasks` — that skill is for "this specific failure is blocking me," this skill is for "step back and look at the bigger picture."

## When to invoke

- Self-check: you've committed 4+ tasks but you're unsure if the work is actually advancing the spec's goal
- Token usage is climbing faster than task progress (compare TOKENS lines in activity.log to recent commits)
- Before invoking `diagnosing-stuck-tasks` — sometimes a meta-look reveals you're working the wrong task entirely
- After a `RECOVER_ATTEMPT` — quick sanity check that the recovery hint actually addressed the issue

## What to do

Three reads, one paragraph, optional next action.

### Read 1: Activity log tail

```
Read .ralph/activity.log offset=<file_length - 80>
```

Look for: repeated commands, gate failure clusters, file thrash patterns, gaps in commits despite many tool calls.

### Read 2: Recent commits

```
Bash: git log --oneline -10
```

Look for: are recent commit messages aligned with what the current task asks for? Are commits trivial (whitespace, comments) or substantive?

### Read 3: Current task description

```
Bash: grep -A 3 '^- \[ \]' {{TASK_FILE}} | head -10
```

Look for: is the current task what you've actually been working on? Sometimes you drift to a related task without flipping the checkbox.

## Output

Write a one-paragraph assessment to your assistant text (do not write a file). Format:

```
**Loop progress review (T### / iter N):**

What I've been doing: <one sentence>
What's working: <one sentence>
What's not: <one sentence>
Recommendation: <one of: "continue current approach" | "switch to <other task>" | "invoke diagnosing-stuck-tasks" | "emit GUTTER">
```

Then, based on the recommendation, take the corresponding action. Do not write the assessment to a file (that's `diagnosis.md`'s job for the heavier skill); this is for in-context reflection that informs your next move.

## Anti-patterns

- **Don't run this every commit.** It's for uncertainty moments, not a routine check.
- **Don't write a long analysis.** One paragraph total. If it takes more, you should be in `diagnosing-stuck-tasks` instead.
- **Don't use as a procrastination device.** If you know what to do next, do it. This skill exists for genuine uncertainty.
