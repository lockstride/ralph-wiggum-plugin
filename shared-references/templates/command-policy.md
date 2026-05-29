# .ralph/command-policy — Ralph command policy
#
# Five sections, scanned in order: [gates] → [rewrite] → [deny] → [wrap] → [protect].
# Every Bash command is canonicalized first (env-prefix + pipes/redirects
# stripped, `pnpm run X` / `pnpm exec X` → `pnpm X`), then matched. [rewrite]
# and [wrap] transparently correct the agent's invocation via updatedInput;
# only [deny] hard-blocks.

# ─────────────────────────────────────────────────────────────────────
# [gates] — REQUIRED. The three tier-gate commands.
#
#   basic   per-task gate, after every task          (fast: format/lint/unit)
#   full    impl-loop completion gate, after [risky] (heavy: + integration/e2e)
#   final   eval-loop gate, post-completion          (heaviest: full acceptance)
#
# Loop refuses to start if any tier is missing. The tier-command label-lock
# requires each tier command to run under its own label — sidestepping is
# denied. Same command for two tiers is allowed.

[gates]
basic | pnpm basic-check
full  | pnpm all-check
final | pnpm all-check

# ─────────────────────────────────────────────────────────────────────
# [rewrite] — regex transforms applied before matching. Use for wrapper
# aliases the canonicalizer can't normalize on its own.
#
#   ^regex$ | replacement | reason   (backrefs \1, \2, … supported)

[rewrite]
# ^pnpm -w run (.+)$ | pnpm \1 | this repo's package.json has no -w workspace flag
# ^npx pnpm (.+)$    | pnpm \1 | use the project's local pnpm
# ^pnpm nx (.+)$     | pnpm \1 | pnpm nx bypasses [wrap]; use root pnpm scripts

# ─────────────────────────────────────────────────────────────────────
# [deny] — literal exact-or-prefix match. Hard block. Use for commands
# that should never run (containerized E2E, destructive ops).
#
#   command-prefix | reason

[deny]
# pnpm test-e2e | containerized E2E is too expensive — use pnpm test-e2e:local

# ─────────────────────────────────────────────────────────────────────
# [wrap] — free-form routing. Listed commands are auto-routed through
# gate-run.sh under the named label, so the loop captures
# .ralph/gates/<label>-latest.{log,exit,cmd,summary} breadcrumbs.
#
#   command-prefix | label
#   label ∈ basic | full | final | unit | integration | e2e | lint | format
#   Missing or unrecognized label → row skipped (no silent default).
#
# The three [gates] commands are auto-wrapped already; listing them here
# is harmless but unnecessary. Use [wrap] for other commands the agent
# might invoke — targeted subset tests, per-app variants, lint/format
# helpers, etc.

[wrap]
# pnpm test-unit         | unit
# pnpm test-integration  | integration
# pnpm test-e2e:local    | e2e
# pnpm lint              | lint
# pnpm format:check      | format

# ─────────────────────────────────────────────────────────────────────
# [protect] — bare invocation OK; pipe / redirect denied. Use for
# commands whose output should stay bounded (e.g. format scripts that
# spew per-file diffs).

[protect]
# pnpm format:write
