# .ralph/command-policy — Ralph command policy
#
# Sections scanned per Bash invocation, in order:
#   [rewrite] → [deny] → [wrap] → [protect]
#
# 0.12.3 model: canonicalize → rewrite → deny → wrap → protect.
# Every command is first canonicalized: env-prefix stripped, pipes /
# redirects stripped, `pnpm run X` / `pnpm exec X` normalized to `pnpm X`.
# Sections then match against the canonical form. When a [rewrite] or
# [wrap] rule fires, the hook returns a transparent `updatedInput` so the
# agent's tool call is silently corrected — no block, no retry puzzle.
# Only [deny] still hard-blocks (for genuinely dangerous commands).
#
# ----------------------------------------------------------------------
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
# [wrap] — listed commands are TRANSPARENTLY auto-rewritten to their
#   gate-run.sh-wrapped form. The loop gets its tracking artifacts
#   (latest.log / .exit / .cmd / .summary, handoff state, fail-streak
#   counter) because the wrapped form is what actually runs. The agent
#   sees its command "just work" without knowing it was wrapped.
#   Format:  command-prefix | label
#   label must be one of: basic | final | e2e | lint | custom
#   Missing label defaults to "basic".
#
#   The matcher closes every known evasion form generically: bare,
#   with args, piped, redirected, env-prefixed, `pnpm run X`,
#   `pnpm exec X`, etc. all canonicalize to the same prefix.
#
# [protect] — bare invocation OK; pipe / redirect of the command is
#   denied. Use for commands whose output should stay bounded (e.g.
#   format scripts that spew per-file diffs).
#
# Backward compat: a [gate-wrapped] section is accepted and treated as
# [wrap] entries with the default label "basic". Projects should migrate
# to [wrap] with explicit labels for accurate gate logging.
#
# Lines starting with '#' and blank lines are ignored. If this file is
# absent, the legacy .ralph/denied-commands + .ralph/protected-scripts
# are read with a one-time deprecation note appended to .ralph/errors.log.
# Legacy fallback never gets [rewrite] or [wrap] — only this file does.

[rewrite]
# ^pnpm -w run (.+)$ | pnpm \1 | this repo's package.json has no -w workspace flag
# ^npx pnpm (.+)$    | pnpm \1 | use the project's local pnpm
# ^pnpm nx (.+)$     | pnpm \1 | pnpm nx bypasses [wrap]; use root pnpm scripts

[deny]
# pnpm test-e2e | containerized E2E is too expensive — use pnpm test-e2e:local

[wrap]
# Commands that should auto-route through gate-run.sh with a chosen label.
# pnpm all-check    | final
# pnpm basic-check  | basic
# pnpm test-unit    | basic
# pnpm test-e2e:local | e2e
# pnpm lint         | lint

[protect]
# pnpm format:write
