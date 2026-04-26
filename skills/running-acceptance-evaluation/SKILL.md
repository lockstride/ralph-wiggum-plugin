---
name: running-acceptance-evaluation
description: Orchestrates the post-completion acceptance evaluation loop for a finished Ralph run. Use when invoked by the eval-loop framing prompt (ralph-evaluate.sh writes a tiny framing prompt that points here). Picks one of two modes per loop based on the current state of `.ralph/acceptance-report.md` — VERIFIER (independent re-check, invokes verifying-acceptance-criteria skill) or REWORK (close the verifier's logged gaps, invokes addressing-acceptance-gaps skill) — and delegates the actual work to a sub-agent via the Task tool. Stays lean across loops so context pollution is bounded; the sub-agent carries the heavy context for the active mode.
---

# Running acceptance evaluation

You are the **acceptance-test orchestrator** for a completed Ralph run. Your job is *not* to verify or fix anything yourself — your job is to pick one of two modes per loop and delegate the work to a sub-agent via the Task tool. Stay lean; the sub-agent carries the heavy context.

## Inputs (from the eval-loop framing prompt)

- **Ground truth**: the original `PROMPT.md` / `tasks.md` / custom prompt that drove the main Ralph run. Treat as the canonical statement of "done." Path is in the framing prompt.
- **Acceptance report**: `.ralph/acceptance-report.md`. Your working document. You read and write it every loop. The loop's task-counter points at this file, so its checkbox state drives the loop's natural completion.

## How completion works in this loop

The report opens with a single top-level checkbox: `- [ ] All acceptance criteria met and verified`. The loop exits COMPLETE only when **every** checkbox in the report is `[x]`. The verifier is the only role allowed to flip that top-level checkbox from `[ ]` to `[x]`, and only after an independent pass that found zero gaps and confirmed each requirement.

## Per-loop workflow

**Step 1. Read both files.** Read the ground-truth file and the acceptance report (Read tool, not Bash). Do not read anything else yourself.

**Step 2. Decide the mode.** Apply these rules in order and stop at the first match:

1. If the report's top-level checkbox is `[x]` and the **Status** line reads `CLEAN` → emit `<ralph>COMPLETE</ralph>` and stop. Do not invoke a sub-agent.
2. If the **Gaps** section contains any `[ ]` line (not suffixed with `(blocked: …)`) → mode = **REWORK**.
3. Otherwise → mode = **VERIFIER**. (Covers: first loop, report just rewritten by verifier with no gaps, report stale after rework.)

**Step 3. Delegate via Task tool.** Invoke the Task tool once with `subagent_type: general-purpose`. The sub-agent's prompt should be:

- **For VERIFIER mode**:
  > Invoke the `verifying-acceptance-criteria` skill. Ground truth is at `<GROUND_TRUTH_PATH>`. Acceptance report is at `<REPORT_PATH>`. Follow the skill's procedure exactly, then return a 2–3 sentence summary.
- **For REWORK mode**:
  > Invoke the `addressing-acceptance-gaps` skill. Ground truth is at `<GROUND_TRUTH_PATH>`. Acceptance report is at `<REPORT_PATH>`. Work the report's Gaps section per the skill's procedure, then return a 2–3 sentence summary.

Substitute the actual paths from your framing prompt. **Do not perform verification or code changes yourself.** Wait for the sub-agent to return.

**Step 4. Append to History.** After the sub-agent returns, append one line to the report's **History** section:

```
iter N - MODE - <one-sentence summary from sub-agent>
```

Bump the **Last loop** and **Last mode** header fields. Commit the report change.

**Step 5. Let the loop advance.** No signal emission needed. The loop's own task-counter will see the updated checkbox state and decide whether to continue or exit.

## What *not* to do

- Do not read project source files, run tests, or invoke Playwright yourself. That is the sub-agent's job, so the orchestrator's context stays small across loops.
- Do not mark the top-level "All acceptance criteria met" checkbox yourself. Only the verifier does this, and only after a full independent pass.
- Do not invent gaps or dismiss real ones. If the report says something, it is authoritative for the current loop.
- Do not commit sub-agent work before the sub-agent has returned. Wait, then commit the report update as a single commit.

## Why sub-agents (vs. invoking the role skills inline)

The verifier specifically needs an INDEPENDENT reading of the requirements. If you invoked `verifying-acceptance-criteria` inline (in your own context), the skill body would join your conversation and you'd see the prior loop's findings, the rework's commit history, and your own orchestration prose — all of which would bias toward "this looks right to me." Sub-agents get a fresh context window seeded only with the prompt you pass them; they read the ground truth and the report independently. That's the load-bearing design choice.
