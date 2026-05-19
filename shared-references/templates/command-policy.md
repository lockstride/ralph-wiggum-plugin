# .ralph/command-policy — Ralph command policy (rewrite / deny / protect)
#
# Sections scanned per Bash invocation. Order: rewrite → deny → protect.
#
# [rewrite] — regex substitution. On match, the agent's Bash call is blocked
#   with a message naming the canonical form. Format:
#     ^regex$ | replacement | reason
#   The replacement supports backrefs (\1, \2, ...).
#
# [deny]   — literal exact-or-prefix match. Format:
#     command-prefix | reason
#
# [protect] — bare invocation OK; pipe / redirect of the command is denied.
#   One prefix per line.
#
# Lines starting with '#' and blank lines are ignored. The new file
# (.ralph/command-policy) is preferred. If absent, the legacy
# .ralph/denied-commands + .ralph/protected-scripts are read with a one-time
# deprecation note appended to .ralph/errors.log.

[rewrite]
# ^pnpm -w run (.+)$ | pnpm \1 | this repo's package.json has no -w workspace flag
# ^npx pnpm (.+)$    | pnpm \1 | use the project's local pnpm

[deny]
# pnpm test-e2e | containerized E2E is too expensive — use pnpm test-e2e:local

[protect]
# pnpm all-check
# pnpm basic-check
