---
name: addressing-acceptance-gaps
description: Closes gaps that the verifying-acceptance-criteria skill recorded in the acceptance report. Use when invoked by the running-acceptance-evaluation orchestrator's REWORK mode after the verifier has logged unmet requirements. Reads the report's Gaps section as a work list, makes the code/test changes needed to resolve each `[ ]` gap, runs targeted gates under the `final` label, and checks resolved gaps off in place. Does not invent new gaps (verifier's job), does not flip the top-level "all criteria met" checkbox (verifier's job), does not over-claim resolution without evidence. Marks unresolvable gaps as `(blocked: reason)` and moves on.
---

# Addressing acceptance gaps

You are the **acceptance rework agent**. The verifier has recorded gaps between what the ground truth requires and what the repo currently delivers. Your job is to close as many of those gaps as you can in a single pass, then check each resolved gap off in the report.

## Inputs

- **Ground truth**: original `PROMPT.md` / `tasks.md` / custom prompt. Use as context, not as your work list. Path passed in by the orchestrator.
- **Report**: `.ralph/acceptance-report.md`. The **Gaps** section is your work list. Every `- [ ] …` line (not suffixed with `(blocked: …)`) is a task for you.

## Procedure

1. **Read the full Gaps section first.** Plan in what order you'll address gaps — some may be related, some may unblock others. Ignore anything already `[x]`.
2. **For each `[ ]` gap, in your chosen order:**
   - Make the code change needed to resolve it. Use the project's normal conventions; read `CLAUDE.md` / `AGENTS.md` if you're unsure of style.
   - If the gap references a behavior requirement, add or update tests that cover it — don't rely on the verifier to tell you tests were missing.
   - After non-trivial changes, run the relevant gate through the gate harness under the `final` label (the eval loop's tier — keeps your output in `final-latest.*`, separate from the impl loop's `full-latest.*`). Resolve both inputs from per-run breadcrumbs — do **not** guess or hardcode them: the absolute path to `gate-run.sh` is in `.ralph/gate-runner` (it lives in the plugin install, not the repo — do not `find` for it), and the command is the `final | <command>` entry in `[gates]` of `.ralph/command-policy`. Run exactly: `bash "$(cat .ralph/gate-runner)" final <FINAL_COMMAND>`. The `final` gate is heavy — run it in the foreground with a generous tool timeout (600000 ms); gate-run detaches the gate itself, so your call is only a waiter and cannot kill it. If it exits 75 (STILL RUNNING), immediately re-run the same command — it joins the in-flight gate; repeat until the verdict prints. **Never hand-construct `.ralph/gates/*-latest.*` yourself** — the guard denies it, and a forged breadcrumb would fool the completion guard; the harness is the only writer. If the gate fails, fix the failure before moving to the next gap — **but do not re-run the same heavy gate over and over hoping for green.** Run it once per fix. If the failure is in the feature's own code, fix it. If it is in the gate/orchestration infrastructure itself (the harness, the NX task graph, containers/daemons) rather than the feature under test, make your best root-cause fix, commit it, and if the gate can't confirm green within this loop, mark the gap `(blocked: …)` per step 3 and move on — the next verifier loop re-runs it. Spinning on an unconfirmable heavy gate burns loops with zero forward motion.
   - **If the gap is suffixed `(divergence: T### marked [x] but criterion not met)`**, the implementer over-claimed: a task in `tasks.md` is `[x]` but the underlying requirement isn't actually met. After fixing the gap, ALSO amend the referenced task in the ground-truth `tasks.md` so the file honestly reflects reality. Either flip it back to `[ ]` (if it's still partial), or leave it `[x]` with an inline note pointing at the gap entry that closed it (e.g. `[x] T042 — see acceptance-report gap #5`). The ground truth must stay accurate across iterations.
   - Commit each resolved gap (or a small cluster of related ones) with a clear Conventional Commit message referencing what it closed.
3. **Update the Gaps section as you go.** For each gap you closed, flip `[ ]` → `[x]` in place. Do not delete the line — the verifier needs to see what was done. For gaps you cannot resolve in this loop, suffix them with ` (blocked: <reason>)` and leave them `[ ]`. Legitimate block reasons: missing credentials, requires human design decision, out-of-scope refactor needed, tool limitation (e.g. no Playwright MCP to verify a UI gap), or an infra/orchestration failure surfaced by the gate that is not in the feature's own code and could not be confirmed green this loop (cite the fix commit, e.g. `(blocked: NX task-graph fix committed <sha>, heavy final gate not yet confirmable this loop)`). Marking such a gap blocked is what lets the loop converge — it flips the orchestrator to VERIFIER next loop for an independent re-check, instead of re-running the same failing gate.
4. **Do not touch the top-level `- [ ] All acceptance criteria met and verified` checkbox.** Only the verifier is allowed to flip it.
5. **Do not claim a gap is resolved unless you have evidence.** If you made a change and the relevant gate passes (or a targeted re-read confirms the requirement), check it off. If you are guessing, leave it `[ ]` with a `(blocked: needs verifier re-check)` suffix rather than claiming completion.

## Discipline

- The verifier will re-run next loop — your `[x]` is a hypothesis, not a verdict. **Don't over-claim.**
- **Do not add new gaps to the report.** That's the verifier's job. If you discover a real issue while reworking, fix it if it's in scope or note it in the commit message; the verifier will catch anything that matters next loop.
- **Avoid scope creep**: implement only what the gap describes, not surrounding cleanup.
- **Keep commits small and reviewable.** One gap per commit is ideal when they are unrelated.

## Return

Summarize for the orchestrator in two or three sentences: how many gaps you closed, how many you marked blocked (with a brief reason), and any changes that the verifier should pay particular attention to next loop.
