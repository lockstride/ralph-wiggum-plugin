#!/usr/bin/env bash
# Ralph Wiggum: open-items completion check
#
# A run records everything it defers, finds out of scope, or cannot decide in
# the spec folder's open-items.md, a table whose last column is `Disposition`:
#
#   | ID    | Source task | Class    | Summary | Disposition               |
#   | OI-01 | T004        | decision | …       | ticketed https://…/ABC-12 |
#
# A row is closed by exactly one disposition:
#   fixed
#   ticketed <link>        (an http(s) link)
#   blocked: <reason>      (only the operator or an outside party can settle it)
#   accepted <operator>    (the operator's name)
# Anything else, including an empty cell, leaves the row open. A blocked row
# does not hold completion; the run lists it for the operator.
#
# Usage: open-items-check.sh <open-items.md>
#        open-items-check.sh --blocked <open-items.md>
# Exit 0: nothing is open — including a missing file, an unreadable file, or
#         a file with no Disposition table. With --blocked, always exit 0 and
#         print each blocked row as `<ID>: <disposition>`.
# Exit 1: stdout names each open row as `<ID>: <why>`.
#
# Deterministic: awk only, no model call.

set -euo pipefail

mode=open
if [[ "${1:-}" == "--blocked" ]]; then
  mode=blocked
  shift
fi
file="${1:-}"
[[ -n "$file" && -f "$file" ]] || exit 0

open=$(
  awk -v mode="$mode" '
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    { sub(/\r$/, "") }
    /^[ \t]*\|/ {
      line = $0
      sub(/^[ \t]*\|/, "", line)
      sub(/\|[ \t]*$/, "", line)
      n = split(line, c, "|")
      if (!in_t) {
        if (tolower(trim(c[n])) == "disposition") in_t = 1
        next
      }
      if (line ~ /^[ \t:|-]+$/) next
      id = trim(c[1])
      d = (n >= 2) ? trim(c[n]) : ""
      ld = tolower(d)
      blocked = (ld ~ /^blocked[ \t]*:[ \t]*[^ \t]/)
      if (mode == "blocked") { if (blocked) print id ": " d; next }
      if (blocked) next
      if (ld ~ /^fixed([ \t:.,;(]|$)/) next
      if (ld ~ /^ticketed([ \t:]|$)/ && d ~ /https?:\/\/[^ \t]+/) next
      if (ld ~ /^accepted[ \t:]+[^ \t]/) next
      if (d == "") print id ": no disposition"
      else print id ": \"" d "\" is not fixed, ticketed <link>, blocked: <reason>, or accepted <operator>"
      next
    }
    { in_t = 0 }
  ' "$file" 2>/dev/null
) || exit 0

[[ -z "$open" ]] && exit 0
printf '%s\n' "$open"
[[ "$mode" == "blocked" ]] && exit 0
exit 1
