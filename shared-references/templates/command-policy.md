# .ralph/command-policy — Ralph command policy
#
# Sections scanned per Bash invocation, in order:
#   [rewrite]      → [deny]      → [gate-wrapped]      → [protect]
#
# [rewrite] — regex substitution. On match, the agent's Bash call is
#   blocked with a message naming the canonical form. Format:
#     ^regex$ | replacement | reason
#   The replacement supports backrefs (\1, \2, ...).
#
# [deny] — literal exact-or-prefix match. Format:
#     command-prefix | reason
#
# [gate-wrapped] — listed commands MUST be invoked through gate-run.sh,
#   else denied. Matches the command after env-prefix stripping AND
#   pnpm-form normalization (`pnpm run X` / `pnpm exec X` → `pnpm X`),
#   so the agent can't slip past with surface variants. Bare invocation,
#   piped invocation, redirect, env-var prefix, and the run/exec variants
#   are all blocked. Wrapping in gate-run.sh allows the command through.
#
# [protect] — bare invocation OK; pipe / redirect of the command is denied.
#   One prefix per line. Use [gate-wrapped] instead when you want the
#   stricter "must route through gate-run.sh" invariant.
#
# Lines starting with '#' and blank lines are ignored. The new file
# (.ralph/command-policy) is preferred. If absent, the legacy
# .ralph/denied-commands + .ralph/protected-scripts are read with a
# one-time deprecation note appended to .ralph/errors.log. Legacy fallback
# never gets [rewrite] or [gate-wrapped] — only the new format does.

[rewrite]
# ^pnpm -w run (.+)$ | pnpm \1 | this repo's package.json has no -w workspace flag
# ^npx pnpm (.+)$    | pnpm \1 | use the project's local pnpm

[deny]
# pnpm test-e2e | containerized E2E is too expensive — use pnpm test-e2e:local

[gate-wrapped]
# Commands that must route through gate-run.sh so the loop captures the
# latest.log / .exit / .cmd / .summary breadcrumbs and the handoff "Last
# gate state" section.
# pnpm all-check
# pnpm basic-check

[protect]
# pnpm format:write
