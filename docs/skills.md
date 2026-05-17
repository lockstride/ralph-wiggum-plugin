# Plugin skills (operator reference)

Ralph ships **four** plugin skills — one maintenance skill (`ralph-plugin-speckit-update`) and three for the post-completion acceptance evaluator (orchestrator + verifier + rework). This doc is the *operator* view: what each skill does, when it's invoked, and how to override or disable. The agent-facing content lives in each skill's `SKILL.md`.

> **Skills require plugin install.** Standalone-script users (Install Options A and B in the README) get the loop infrastructure, but the agent does NOT discover plugin skills. Install via the marketplace to unlock skill behavior. See [README → Install](../README.md#install).

Gate discipline for the main implementation loop is handled by the guard hook (blocks direct test-tool invocations, pipe/redirect on protected scripts) and the speckit prompt template (hardcodes `basic` gate for per-task verification). No main-loop skills are needed — the prompt template and mechanical enforcement are more reliable than skills the agent may or may not read.

## Acceptance-evaluation skills

These three drive the post-completion `ralph-evaluate` loop. The orchestrator + role bodies are discoverable plugin skills that the loop's framing prompt references by name.

### `running-acceptance-evaluation`

**File:** `skills/running-acceptance-evaluation/SKILL.md`

**What it does:** The orchestrator workflow for the eval loop. Per loop: read the ground truth + acceptance report, decide between VERIFIER and REWORK based on the report's gap state, delegate to a sub-agent via the Task tool (sub-agent then invokes one of the two role skills below). Stays lean across loops — does not read source files, run tests, or invoke Playwright itself.

**When invoked:** By the eval loop's framing prompt (written by `ralph-evaluate.sh` to `.ralph/effective-prompt.md`). The framing is intentionally minimal — it tells the agent the per-run paths and to invoke this skill. All workflow logic lives in the skill body.

**Override:** Edit `skills/running-acceptance-evaluation/SKILL.md`. The skill is invoked once per eval loop; structural changes affect all subsequent loops of the current run.

**Disable:** Removing the skill breaks the eval loop entirely. To suppress eval, just don't pass `--evaluate` (or `RALPH_CHAIN_EVALUATE=1`) to the main `ralph` launcher.

### `verifying-acceptance-criteria`

**File:** `skills/verifying-acceptance-criteria/SKILL.md`

**What it does:** Independent re-check of the entire ground-truth requirements list against the current repo state. Skeptical by default — does not trust `progress.md`, `handoff.md`, or the main loop's self-assessment. Records every unmet requirement as a gap line in the acceptance report. The only role allowed to flip the top-level "All acceptance criteria met" checkbox to `[x]`. Records findings only; does not modify code.

**When invoked:** By the orchestrator skill's VERIFIER mode, via Task-tool sub-agent. The sub-agent's prompt instructs it to invoke this skill. Sub-agent isolation matters here — fresh context window means the verifier reads requirements without bias from prior loop findings or rework commits.

**Override:** Edit `skills/verifying-acceptance-criteria/SKILL.md` to change verification thoroughness, gate-label conventions, or what counts as "affirmatively verified."

### `addressing-acceptance-gaps`

**File:** `skills/addressing-acceptance-gaps/SKILL.md`

**What it does:** Closes gaps that the verifier recorded. Reads the report's Gaps section as a work list, makes the code/test changes for each `[ ]` entry, runs targeted gates under `eval-rework` label, checks resolved gaps off in place. Does not invent new gaps (verifier's job), does not flip the top-level checkbox (verifier's job), does not over-claim resolution without evidence. Marks unresolvable gaps as `(blocked: reason)`.

**When invoked:** By the orchestrator skill's REWORK mode, via Task-tool sub-agent. Triggered when the report's Gaps section contains any `[ ]` line not suffixed with `(blocked: …)`.

**Override:** Edit `skills/addressing-acceptance-gaps/SKILL.md` to change what counts as legitimate "blocked" reasons, scope-creep guardrails, or commit-granularity expectations.

## `ralph-plugin-speckit-update`

**File:** `skills/ralph-plugin-speckit-update/SKILL.md`

**What it does:** Maintenance skill for updating the plugin's own Spec Kit integration files when a new Spec Kit version is released. Covers the adaptation guide, prompt-resolver, fallback prompt template, docs, and tests.

**When invoked:** By the operator (you) when Spec Kit releases a new tagged version.

## How skills are wired into the loop

1. **Discovery** — when ralph-setup launches `claude`, the plugin install registers `skills/*/SKILL.md` with claude. Their frontmatter (name + description) is preloaded into the agent's system prompt at model load. Body is read on demand when the agent invokes the skill.

2. **Invocation** — agent calls the `Skill` tool with the matching name. The skill's body becomes part of the conversation context. The agent follows the skill's workflow, then returns to the main loop's procedural cycle (or escalates via GUTTER per the skill's guidance).

## Adding new skills

1. Create `skills/<gerund-form-name>/SKILL.md` (gerund form per [Anthropic best practices](https://platform.claude.com/docs/en/agents-and-tools/agent-skills/best-practices)).
2. Frontmatter: `name`, `description` (third-person, ≤1024 chars, includes both *what* and *when*). Body ≤500 lines.
3. Reference the new skill from `shared-references/templates/speckit-prompt.md` and `shared-references/templates/speckit-adaptation-guide.md` so generated prompts mention it.
4. Add a frontmatter-validation test case to `tests/skills.bats`.
5. Document the skill here.
