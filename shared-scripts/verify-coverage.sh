#!/usr/bin/env bash
# Ralph Wiggum: verify-pass coverage check
#
# A rework is worth starting only when the verify pass looked at everything the
# ground truth asks for. The verifier records what it checked under `## Results`
# in the acceptance report, one plain bullet (never a checkbox — the loop counts
# those as tasks) per criterion and surface:
#
#   - <criterion> | <surface> | pass|fail
#
# Only pass or fail is a result: a line saying `not run` probed nothing.
#
# The ground truth names what must be covered:
#   - a run plan's `## Tickets`: each `### <ID>` block's `- AC<n>:` bullets,
#     keyed `<ID>/AC<n>`
#   - a Spec Kit spec (the ground truth's sibling spec.md): `FR-###` bullets
# A criterion lists the surfaces it touches as `| surface: ui, api`. One that
# names none is covered by any result line for it, with surface `-`.
#
# Usage: verify-coverage.sh <ground-truth> <report>
# Exit 0: covered — including a ground truth with no criteria it can read.
# Exit 1: stdout names each uncovered `<criterion> | <surface>`.
#
# Deterministic: awk and shell only, no model call.

set -euo pipefail

truth="${1:-}"
report="${2:-}"
[[ -f "$truth" && -f "$report" ]] || exit 0

work=$(mktemp -d "${TMPDIR:-/tmp}/verify-coverage.XXXXXX") || exit 0
# shellcheck disable=SC2064 # expand $work now: the trap must remove this run's dir
trap "rm -rf '$work'" EXIT

files=("$truth")
sibling="$(dirname "$truth")/spec.md"
if [[ -f "$sibling" && "$sibling" != "$truth" ]]; then
  files+=("$sibling")
fi

awk '
  function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
  function flush(   p, s, q) {
    if (key == "") return
    s = ""
    p = index(txt, "| surface:")
    if (p > 0) {
      s = substr(txt, p + 10)
      q = index(s, " | ")
      if (q > 0) s = substr(s, 1, q - 1)
      gsub(/[ \t]*,[ \t]*/, ",", s)
      s = trim(s)
    }
    printf "%s\t%s\n", key, s
    key = ""
  }
  FNR == 1 { flush(); in_t = 0; cur = "" }
  /^## / { flush(); in_t = ($0 ~ /^## Tickets/); next }
  /^### / { flush(); if (in_t) cur = $2; next }
  {
    line = $0
    nk = ""
    if (in_t && cur != "" && line ~ /^[ \t]*-[ \t]+AC[0-9]+:/) {
      ac = line; sub(/^[ \t]*-[ \t]+/, "", ac); sub(/:.*/, "", ac)
      nk = cur "/" ac
    } else if (line ~ /^[ \t]*[-*][ \t]+[*`]*FR-[0-9]+/) {
      fr = line; sub(/^[ \t]*[-*][ \t]+[*`]*/, "", fr)
      match(fr, /^FR-[0-9]+/)
      nk = substr(fr, RSTART, RLENGTH)
    }
    if (nk != "") { flush(); key = nk; txt = line; next }
    if (key != "") {
      if (line ~ /^[ \t]*$/ || line ~ /^[ \t]*[-*][ \t]/ || line ~ /^[ \t]*(Steps to reproduce|Notes from comments)/) flush()
      else txt = txt " " line
    }
  }
  END { flush() }
' "${files[@]}" >"$work/expected" 2>/dev/null || exit 0

[[ -s "$work/expected" ]] || exit 0

awk '
  function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
  /^## / { in_r = ($0 ~ /^## Results/); next }
  in_r && /^[ \t]*[-*][ \t]+/ {
    l = $0; sub(/^[ \t]*[-*][ \t]+/, "", l)
    if (split(l, f, "|") >= 3 && tolower(trim(f[3])) ~ /^(pass|fail)$/)
      print tolower(trim(f[1])) "|" tolower(trim(f[2]))
  }
' "$report" >"$work/results" 2>/dev/null || exit 0

missing=$(
  awk -F'\t' -v results="$work/results" '
    FILENAME == results { have[$0] = 1; k = substr($0, 1, index($0, "|") - 1); anyk[k] = 1; next }
    {
      key = tolower($1)
      if ($2 == "") {
        if (!(key in anyk)) print $1 " | -"
        next
      }
      n = split(tolower($2), ss, ",")
      for (i = 1; i <= n; i++) if (!((key "|" ss[i]) in have)) print $1 " | " ss[i]
    }
  ' "$work/results" "$work/expected" 2>/dev/null
) || exit 0

[[ -z "$missing" ]] && exit 0
printf '%s\n' "$missing"
exit 1
