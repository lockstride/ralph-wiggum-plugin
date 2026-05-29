# .ralph/command-policy — Ralph command policy
#
# Sections, in declaration + scan order:
#   [gates] → [rewrite] → [deny] → [wrap] → [protect]
#
# Every Bash command the agent runs is first canonicalized: env-prefix
# stripped, pipes / redirects stripped, `pnpm run X` / `pnpm exec X`
# normalized to `pnpm X`. Sections then match against the canonical form.
# When a [rewrite] or [wrap] rule fires, the hook returns a transparent
# `updatedInput` so the agent's tool call is silently corrected — no
# block, no retry puzzle. Only [deny] still hard-blocks.
#
# ----------------------------------------------------------------------
# [gates] — REQUIRED. The three tier-gate commands the loop runs at each
#   phase. Loop refuses to start if any of the three rows is missing.
#
#   Format:  tier | command
#   tiers (each exactly once):
#     basic   per-task gate, after every task              (fast: format/lint/unit)
#     full    impl-loop completion gate, after [risky]     (heavy: + integration/e2e)
#     final   eval-loop gate, post-completion verification (heaviest: full acceptance)
#
#   Same command for two tiers is allowed; "no-op" via `true` is allowed.
#   The tier-command label-lock requires each command to run under its own
#   tier label — a `full` command labeled `basic` is denied, because the
#   completion guard reads `full-latest.{cmd,exit}` and would miss the run.
#
# [rewrite] — project-specific regex transforms applied before matching.
#   Format:  ^regex$ | replacement | reason
#   Backrefs supported (\1, \2, …). The rewritten form flows into all
#   downstream checks AND is what the agent's command becomes. Use this
#   to neutralize wrapper aliases the canonical pipeline doesn't know
#   about (e.g. `pnpm nx X` in Nx monorepos).
#
# [deny] — literal exact-or-prefix match. Hard block. Use for commands
#   that should never run (containerized E2E, destructive ops).
#   Format:  command-prefix | reason
#
# [wrap] — free-form routing table. Listed commands are TRANSPARENTLY
#   auto-rewritten to their gate-run.sh-wrapped form. The loop gets its
#   tracking artifacts (latest.log/.exit/.cmd/.summary, handoff state,
#   fail-streak counter) because the wrapped form is what actually runs.
#   The agent sees its command "just work" without knowing it was wrapped.
#
#   Format:  command-prefix | label
#   label ∈ basic | full | final | unit | integration | e2e | lint | format
#   Missing or unrecognized label → row is skipped (no silent default).
#
#   The three [gates] commands are auto-wrapped by their tier; they do
#   NOT need [wrap] rows. Adding them anyway is harmless. Use [wrap] for
#   *other* commands the agent might run — targeted subset tests,
#   per-app variants, etc.
#
# [protect] — bare invocation OK; pipe / redirect of the command is
#   denied. Use for commands whose output should stay bounded (e.g.
#   format scripts that spew per-file diffs).
#
# Lines starting with '#' and blank lines are ignored.

[gates]
# Project's three tier-gate commands. ALL THREE REQUIRED.
# Example (replace with your project's actual gates):
basic | pnpm basic-check
full  | pnpm all-check
final | pnpm all-check

[rewrite]
# ^pnpm -w run (.+)$ | pnpm \1 | this repo's package.json has no -w workspace flag
# ^npx pnpm (.+)$    | pnpm \1 | use the project's local pnpm
# ^pnpm nx (.+)$     | pnpm \1 | pnpm nx bypasses [wrap]; use root pnpm scripts

[deny]
# pnpm test-e2e | containerized E2E is too expensive — use pnpm test-e2e:local

[wrap]
# Free-form routing for commands NOT in [gates]. The label drives the
# artifact namespace (.ralph/gates/<label>-latest.*) and timeout bucket,
# nothing more. Pick the closest kind label; tier labels (basic/full/final)
# are reserved for the [gates] commands.
# pnpm test-unit            | unit
# pnpm test-integration     | integration
# pnpm test-e2e:local       | e2e
# pnpm api:test-unit        | unit
# pnpm webapp:test-e2e:local | e2e
# pnpm lint                 | lint
# pnpm format:check         | format

[protect]
# pnpm format:write
