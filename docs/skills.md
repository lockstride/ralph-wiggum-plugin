# Plugin skills (operator reference)

Ralph 0.6.0 ships **six** plugin skills — three for the main implementation loop (cognitive-mode switching when the agent gets stuck or needs to step back) and three for the post-completion acceptance evaluator (orchestrator + verifier + rework, previously inline templates). This doc is the *operator* view: what each skill does, when the loop suggests it, and how to override or disable. The agent-facing content lives in each skill's `SKILL.md`.

> **Skills require plugin install.** Standalone-script users (Install Options A and B in the README) get the loop infrastructure, but the agent does NOT discover plugin skills. Install via the marketplace (Option C) to unlock the cognitive-mode behavior. See [README → Install](../README.md#install).

## Main-loop skills

## `running-gates`

**File:** `skills/running-gates/SKILL.md`

**What it does:** Wraps everything previously inlined as the "Gate invocation contract" in the framing prompt — how to call `gate-run.sh`, the no-pipe rule, the per-task one-retry budget, the failure-diagnosis protocol, the post-success protocol. The agent invokes this skill any time it's about to run a gate or diagnose a gate failure.

**When invoked:** Continuously, by the agent's own judgment. The framing prompt directs the agent to reference this skill for gate operations rather than relying on inlined rules. Pulling the contract out of the framing prompt saves ~500 tokens of working memory on every non-gate turn.

**Override:** Edit `skills/running-gates/SKILL.md`. The framing prompt's reference (`See the running-gates skill for the contract`) survives any edit; only the contract details change.

**Disable:** Not recommended — the gate discipline is load-bearing. To experiment, delete the skill directory and the agent will fall back to its training-time judgment about gate invocation. Expect more `pipe`-mediated calls and reruns.

## `diagnosing-stuck-tasks`

**File:** `skills/diagnosing-stuck-tasks/SKILL.md`

**What it does:** Switches the agent into exploratory diagnosis mode. Suspends the procedural execute-gate-commit cycle. The agent reads the full failure log (not the bounded summary), questions whether the test itself is wrong, lists 2–3 alternative root causes, runs layer-bypassing diagnostics (`curl` directly against endpoints, Playwright if available), then either commits to a new approach or emits `<ralph>GUTTER</ralph>`. Findings written to `.ralph/diagnosis.md` for the next iteration.

**When invoked (auto-suggested by the loop):**
- Same `gate-run.sh` command has failed 3+ times in this iteration (`RALPH_SHELL_FAIL_SUGGEST_THRESHOLD`, default 3).
- Same file rewritten 3+ times within 10 minutes (`RALPH_FILE_THRASH_SUGGEST_THRESHOLD`, default 3).
- Stream-parser writes `.ralph/skill-suggestion` with the trigger context. Agent's prompt directs it to read that file and invoke the skill before continuing.

**When invoked (agent self-judgment):** When the agent notices it's about to make the same edit-then-fail cycle for the third time.

**Override:**
- Raise/lower the suggestion thresholds via `RALPH_SHELL_FAIL_SUGGEST_THRESHOLD` and `RALPH_FILE_THRASH_SUGGEST_THRESHOLD` in the loop's environment.
- Edit the skill body to change what counts as "honest diagnosis" or to add new diagnostic patterns.
- The hard recovery threshold (`RALPH_SHELL_FAIL_THRESHOLD`, default 5) is unchanged by this skill — if the agent ignores the suggestion and keeps failing, the existing kill-and-restart-with-hint path still fires.

**Disable:** Set `RALPH_SHELL_FAIL_SUGGEST_THRESHOLD=999` and `RALPH_FILE_THRASH_SUGGEST_THRESHOLD=999` to effectively suppress soft suggestions. The hard recovery path remains active.

## `reviewing-loop-progress`

**File:** `skills/reviewing-loop-progress/SKILL.md`

**What it does:** Lightweight meta-reflection. The agent reads the activity-log tail, recent commits, and the current task description, then writes a one-paragraph "what I've been doing, what's working, what's not, recommendation" assessment. Different from `diagnosing-stuck-tasks` — this is for "step back and look at the bigger picture" rather than "this specific failure is blocking me."

**When invoked:** Agent self-judgment, not loop-suggested. The framing prompt mentions this skill is available for uncertainty moments. Useful before invoking the heavier `diagnosing-stuck-tasks` — sometimes a meta-look reveals you're working the wrong task entirely.

**Override:** Edit the skill body to change what gets read or how the assessment is structured.

**Disable:** Not necessary — the skill is opt-in by the agent. If the agent never invokes it, it costs nothing.

## Acceptance-evaluation skills

These three drive the post-completion `ralph-evaluate` loop. Pre-0.6.0 the orchestrator + role bodies were inline markdown templates rendered into a 150-line effective prompt. 0.6.0 splits them into discoverable plugin skills that the loop's framing prompt references by name.

### `running-acceptance-evaluation`

**File:** `skills/running-acceptance-evaluation/SKILL.md`

**What it does:** The orchestrator workflow for the eval loop. Per iteration: read the ground truth + acceptance report, decide between VERIFIER and REWORK based on the report's gap state, delegate to a sub-agent via the Task tool (sub-agent then invokes one of the two role skills below). Stays lean across iterations — does not read source files, run tests, or invoke Playwright itself.

**When invoked:** By the eval loop's framing prompt (written by `ralph-evaluate.sh` to `.ralph/effective-prompt.md`). The framing is intentionally minimal — it tells the agent the per-run paths and to invoke this skill. All workflow logic lives in the skill body.

**Override:** Edit `skills/running-acceptance-evaluation/SKILL.md`. The skill is invoked once per eval iteration; structural changes affect all subsequent iterations of the current run.

**Disable:** Removing the skill breaks the eval loop entirely. To suppress eval, just don't pass `--evaluate` (or `RALPH_CHAIN_EVALUATE=1`) to the main `ralph` launcher.

### `verifying-acceptance-criteria`

**File:** `skills/verifying-acceptance-criteria/SKILL.md`

**What it does:** Independent re-check of the entire ground-truth requirements list against the current repo state. Skeptical by default — does not trust `progress.md`, `handoff.md`, or the main loop's self-assessment. Records every unmet requirement as a gap line in the acceptance report. The only role allowed to flip the top-level "All acceptance criteria met" checkbox to `[x]`. Records findings only; does not modify code.

**When invoked:** By the orchestrator skill's VERIFIER mode, via Task-tool sub-agent. The sub-agent's prompt instructs it to invoke this skill. Sub-agent isolation matters here — fresh context window means the verifier reads requirements without bias from prior iteration findings or rework commits.

**Override:** Edit `skills/verifying-acceptance-criteria/SKILL.md` to change verification thoroughness, gate-label conventions, or what counts as "affirmatively verified."

### `addressing-acceptance-gaps`

**File:** `skills/addressing-acceptance-gaps/SKILL.md`

**What it does:** Closes gaps that the verifier recorded. Reads the report's Gaps section as a work list, makes the code/test changes for each `[ ]` entry, runs targeted gates under `eval-rework` label, checks resolved gaps off in place. Does not invent new gaps (verifier's job), does not flip the top-level checkbox (verifier's job), does not over-claim resolution without evidence. Marks unresolvable gaps as `(blocked: reason)`.

**When invoked:** By the orchestrator skill's REWORK mode, via Task-tool sub-agent. Triggered when the report's Gaps section contains any `[ ]` line not suffixed with `(blocked: …)`.

**Override:** Edit `skills/addressing-acceptance-gaps/SKILL.md` to change what counts as legitimate "blocked" reasons, scope-creep guardrails, or commit-granularity expectations.

## How skills are wired into the loop

1. **Discovery** — when ralph-setup launches `claude`, the plugin install registers `skills/*/SKILL.md` with claude. Their frontmatter (name + description) is preloaded into the agent's system prompt at model load. Body is read on demand when the agent invokes the skill.

2. **Suggestion** — stream-parser writes `.ralph/skill-suggestion` when an early stuck pattern fires (`SUGGEST_SKILL` signal, distinct from the harder `RECOVER_ATTEMPT`). The framing prompt directs the agent to check this file at startup and after every commit.

3. **Invocation** — agent calls the `Skill` tool with the matching name. The skill's body becomes part of the conversation context. The agent follows the skill's workflow, then returns to the main loop's procedural cycle (or escalates via GUTTER per the skill's guidance).

4. **Cleanup** — after invocation, the agent deletes `.ralph/skill-suggestion` so the same trigger doesn't re-prompt next turn. The per-iteration suggested-skills tracker is cleared on every successful commit (`reset_failure_counters_on_task_boundary`).

## Cross-CLI portability

Anthropic published Agent Skills as an [open standard](https://agentskills.io) in December 2025. As adoption spreads, these skills should work in:

- **Claude Code** — ✅ supported now (plugin install)
- **Cursor** — supported as ecosystem matures
- **Codex CLI** — supported as ecosystem matures
- **Gemini CLI / Copilot** — supported as ecosystem matures

For non-supporting CLIs, the loop's fallback path is to inline the relevant skill content into the framing prompt. This is mechanically straightforward but defeats the cognitive-load benefit of progressive disclosure. Track CLI support in [README → Install](../README.md#install).

## Adding new skills

If you find a class of stuck pattern the existing skills don't cover, add a new one:

1. Create `skills/<gerund-form-name>/SKILL.md` (gerund form per [Anthropic best practices](https://platform.claude.com/docs/en/agents-and-tools/agent-skills/best-practices)).
2. Frontmatter: `name`, `description` (third-person, ≤1024 chars, includes both *what* and *when*). Body ≤500 lines.
3. If the loop should auto-suggest the skill on a specific signal, add the trigger in `shared-scripts/stream-parser.sh` (see existing `_write_skill_suggestion` calls in `track_shell_failure` and `track_file_write` for the pattern).
4. Reference the new skill from `shared-references/templates/speckit-prompt.md` and `shared-references/templates/speckit-adaptation-guide.md` so generated prompts mention it.
5. Add a frontmatter-validation test case to `tests/skills.bats`.
6. Document the skill here.
