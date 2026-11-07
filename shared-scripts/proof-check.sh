#!/usr/bin/env bash
# Ralph Wiggum: tranche-close proof check
#
# A run plan's Tickets section lists each ticket's acceptance criteria as plain
# bullets, each naming the test that proves it:
#
#   ### ABC-24 — <title>
#   - AC1: <criterion> | proof: <test file::name, or command>
#
# A task closes a tranche for the tickets named on its line (or, failing that,
# in the `###` heading it sits under). This check refuses the close while one
# of those tickets has a criterion with no proof, or a proof naming a file that
# does not exist.
#
# Usage: proof-check.sh <plan> <task-id> [root]
#   <plan>     the run plan (or its launch snapshot)
#   <task-id>  the closing task, e.g. T004
#   [root]     directory proof paths are relative to (default: cwd)
#
# Exit 0: the close may proceed — including a plan with no `| proof:` map, a
#         task the plan does not hold, or a plan that cannot be read.
# Exit 1: the close is refused; stdout names each ticket and criterion.
#
# Deterministic: awk and shell only, one pass over the plan.

set -euo pipefail

plan="${1:-}"
task_id="${2:-}"
root="${3:-$PWD}"

[[ -n "$plan" && -n "$task_id" && -f "$plan" ]] || exit 0

records=$(
  awk -v tid="$task_id" '
    function first_ids(s,   out, m) {
      out = ""
      while (match(s, /[A-Z][A-Z0-9]*-[0-9]+/)) {
        m = substr(s, RSTART, RLENGTH)
        out = out " " m
        s = substr(s, RSTART + RLENGTH)
      }
      return out
    }
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    function flush_crit() {
      if (crit_id != "") {
        n_crit++
        c_id[n_crit] = crit_id
        c_ac[n_crit] = crit_ac
        c_txt[n_crit] = crit_txt
        if (index(crit_txt, "| proof:") > 0) has_map = 1
      }
      crit_id = ""
    }
    /^## / { flush_crit(); in_tickets = ($0 ~ /^## Tickets/); in_task = 0; next }
    /^### / {
      flush_crit(); in_task = 0
      if (in_tickets) { cur = $2 } else { heading = $0 }
      next
    }
    {
      line = $0
      if (!in_tickets) {
        rest = line
        if (sub(/^[ \t]*[-*][ \t]+\[[ xX]\][ \t]+/, "", rest) && index(rest, tid) == 1 &&
            substr(rest, length(tid) + 1, 1) !~ /[0-9A-Za-z]/) {
          task_txt = rest; in_task = 1; task_h = heading; next
        }
        if (in_task) {
          if (line ~ /^[ \t]*$/ || line ~ /^[ \t]*[-*][ \t]+\[/) { in_task = 0 }
          else { task_txt = task_txt " " line }
        }
        next
      }
      if (line ~ /^[ \t]*-[ \t]+AC[0-9]+:/) {
        flush_crit()
        crit_id = cur
        crit_ac = line; sub(/^[ \t]*-[ \t]+/, "", crit_ac); sub(/:.*/, "", crit_ac)
        crit_txt = line
        next
      }
      if (crit_id != "") {
        if (line ~ /^[ \t]*$/ || line ~ /^[ \t]*-[ \t]/ || line ~ /^[ \t]*(Steps to reproduce|Notes from comments)/) { flush_crit() }
        else { crit_txt = crit_txt " " line }
      }
    }
    END {
      flush_crit()
      if (!has_map || task_txt == "") exit 0
      ids = first_ids(task_txt)
      if (ids == "") ids = first_ids(task_h)
      n = split(ids, want, " ")
      for (i = 1; i <= n; i++) {
        for (j = 1; j <= n_crit; j++) {
          if (c_id[j] != want[i]) continue
          p = index(c_txt[j], "| proof:")
          proof = ""
          if (p > 0) {
            proof = substr(c_txt[j], p + 8)
            q = index(proof, " | ")
            if (q > 0) proof = substr(proof, 1, q - 1)
            proof = trim(proof)
          }
          printf "%s\t%s\t%s\n", c_id[j], c_ac[j], proof
        }
      }
    }
  ' "$plan" 2>/dev/null
) || exit 0

[[ -n "$records" ]] || exit 0

refused=0
while IFS=$'\t' read -r ticket criterion proof; do
  [[ -n "$ticket" ]] || continue
  if [[ -z "$proof" ]]; then
    echo "$ticket $criterion: no test is named for it"
    refused=1
    continue
  fi
  path="${proof%%::*}"
  # A proof that is a command (it has spaces) names no file to look for.
  [[ "$path" != *" "* ]] || continue
  if [[ "$path" == */* || "$proof" == *::* ]]; then
    [[ "$path" == /* ]] || path="$root/$path"
    if [[ ! -e "$path" ]]; then
      echo "$ticket $criterion: the test file '${proof%%::*}' does not exist"
      refused=1
    fi
  fi
done <<<"$records"

exit "$refused"
