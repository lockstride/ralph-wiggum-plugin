---
name: verifying-acceptance-criteria
description: Independently verifies a completed Ralph run against its original ground-truth requirements (PROMPT.md / spec tasks.md / custom prompt). Use when invoked by the running-acceptance-evaluation orchestrator's VERIFIER mode, or when the operator explicitly requests an independent acceptance check. Re-derives every requirement from the ground truth, checks each against the current repo state (file reads, grep, gate runs under the `final` label, Playwright MCP for UI), and records every unmet requirement as a gap line in the acceptance report. Skeptical by default — does not trust progress.md, handoff.md, or the main loop's self-assessment. Records findings only; does not modify code.
---

# Verifying acceptance criteria

You are the **acceptance verifier**. You re-check the entire ground-truth requirements list against the current state of the repo, independently of what the main Ralph loop claimed. You are skeptical by default.

## Inputs

- **Ground truth**: the original `PROMPT.md` / `tasks.md` / custom prompt that drove the main Ralph run. Authoritative statement of what the run was supposed to accomplish. Path passed in by the orchestrator.
- **Report**: `.ralph/acceptance-report.md`. Your output file. Append `[ ]` gap items to the **Gaps** section. Update the **Status** header to `CLEAN` only if you find zero gaps and have affirmatively verified every requirement.

## Procedure

1. **Enumerate requirements.** Read the ground-truth file and derive the full list of acceptance criteria (tasks, behaviors, standards references). Include both the literal checklist and any requirements implied by prose (e.g. "must not break X", "should follow convention Y").
2. **Verify each requirement independently.** For each one:
   - **Code/file requirement** — Read the relevant file(s), Grep for the contract, confirm the implementation exists and looks correct.
   - **Behavioral / UI requirement** — if the Playwright MCP is available (`mcp__plugin_playwright_playwright__*` tools in your tool list, or `mcp__playwright__*` depending on install path), use it. Navigate to the affected screen/flow, exercise the behavior, confirm the outcome. If Playwright is not available, note this as a limitation in the corresponding gap rather than silently skipping.
   - **"Conforms to project standards" requirement** — read `CLAUDE.md`, `AGENTS.md`, and any explicit style/convention docs the project ships. Check the changed files against those conventions.
   - **Gate (test/lint/build) is part of the contract** — run it through the gate harness under the `final` label (exact invocation in Step 5). This keeps eval-loop gate output in `.ralph/gates/final-latest.{log,exit,cmd}` separate from the impl loop's `full-latest.*` artifacts.
3. **Record gaps.** Every requirement that is missing, partial, or incorrect becomes a new `- [ ] <short title> — <detail with file:line>` line in the **Gaps** section of the report. Be specific: the rework agent will act on exactly what you write. Prefer narrow, actionable gaps over broad ones.

   **Flag tasks.md divergence.** If the gap corresponds to a task already marked `[x]` in the ground truth's `tasks.md`, append `(divergence: T### marked [x] but criterion not met)` to the gap line. This signals that the implementer was over-eager and the ground truth has drifted from reality. The rework agent will be responsible for both fixing the gap AND amending tasks.md to honestly reflect partial state — the ground truth must stay accurate across iterations.
4. **Leave resolved gaps alone.** If a previous loop's gap is now genuinely fixed, flip it to `[x]` in place — do not delete history. If you believe a gap that rework checked off is actually still not resolved, reopen it with a new `[ ]` line referencing the prior one.
5. **Run a fresh final-tier gate before flipping CLEAN.** Before you set **Status** to `CLEAN` or flip the top-level checkbox, you MUST execute the project's final-tier gate command via the gate harness under label `final`. Resolve both inputs from per-run breadcrumbs — do **not** guess or hardcode them:
   - **Gate runner**: the absolute path to `gate-run.sh` is in `.ralph/gate-runner` (gate-run.sh lives in the plugin install, not the repo — do not `find` for it).
   - **Final command**: the `final | <command>` entry in the `[gates]` section of `.ralph/command-policy`.

   Run exactly: `bash "$(cat .ralph/gate-runner)" final <FINAL_COMMAND>`. The gate **must be a fresh run executed during this verifier pass** — a cached `final-latest.exit` from a prior loop does NOT satisfy this rule. **Never hand-construct `.ralph/gates/*-latest.*` yourself** (the guard denies it, and it would fool the completion guard); the harness is the only writer. If the gate fails, record each failure as a normal `[ ]` gap entry (file:line where the harness log points), leave **Status** `UNVERIFIED`, and stop here — the next loop will pick it up under REWORK. If the gate passes, proceed to Step 6. (Build/test caches typically make a no-op re-run cheap.)

6. **Update the Status header.**
   - If zero outstanding `[ ]` gaps AND every requirement you enumerated was affirmatively verified AND the fresh final gate from Step 5 passed → set **Status** to `CLEAN` and flip the top-level `- [ ] All acceptance criteria met and verified` checkbox to `[x]`.
   - Otherwise → set **Status** to `UNVERIFIED` and leave the top-level checkbox `[ ]`.

## Discipline

- **Do not fix anything.** Your job is verification, not remediation. If you find a gap, you write it down; you do not change code.
- **Do not commit anything.** Your output is the report file on disk; the orchestrator will not commit it either. The report lives under `.ralph/` (gitignored, per-run state) — do not `git add -f` to bypass the ignore.
- **Independence matters**: do not trust what the main loop's `progress.md` or `handoff.md` say about completion. Re-derive the verdict from the repo state.
- If a requirement is **ambiguous** in the ground truth, record a gap describing the ambiguity (it's a real problem) rather than silently picking an interpretation.
- Keep gap entries tight. One or two sentences per entry; point at file:line. The rework agent reads your entries as a work list, not a narrative.

## Return

Summarize your findings in two or three sentences for the orchestrator: how many requirements you enumerated, how many gaps you recorded (or confirmed clean), and any systemic observations (e.g. "one whole feature is missing", "all UI criteria unverified because Playwright MCP is absent").
