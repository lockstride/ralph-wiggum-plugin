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
#   accepted <operator>    (the operator's name)
# Anything else, including an empty cell, leaves the row open.
#
# Usage: open-items-check.sh <open-items.md>
# Exit 0: nothing is open — including a missing file, an unreadable file, or
#         a file with no Disposition table.
# Exit 1: stdout names each open row as `<ID>: <why>`.
#
# Deterministic: awk only, no model call.

set -euo pipefail

file="${1:-}"
[[ -n "$file" && -f "$file" ]] || exit 0

open=$(
  awk '
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
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
      if (ld ~ /^fixed([^a-z]|$)/) next
      if (ld ~ /^ticketed/ && d ~ /https?:\/\/[^ \t]+/) next
      if (ld ~ /^accepted[ \t:]+[^ \t]/) next
      if (d == "") print id ": no disposition"
      else print id ": \"" d "\" is not fixed, ticketed <link>, or accepted <operator>"
      next
    }
    { in_t = 0 }
  ' "$file" 2>/dev/null
) || exit 0

[[ -z "$open" ]] && exit 0
printf '%s\n' "$open"
exit 1
