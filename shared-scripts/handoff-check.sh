#!/bin/bash
# Ralph Wiggum: Stop-event hook
#
# Soft reminder that emits a notice if .ralph/handoff.md was not updated
# during the current loop. Does not block — the loop ends regardless. The
# next loop will see whatever state was (or was not) written.
#
# Detection: compare handoff.md mtime against the loop-start sentinel
# .ralph/loop-baseline-head (rewritten by _capture_loop_baseline at every
# loop start). If handoff.md is older or identical to the baseline, it
# was not updated this loop.
#
# Hook input: JSON on stdin (Stop event payload).
# Hook output: JSON on stdout with optional permissionDecision + reason.
#              Always allows (never blocks).

set -euo pipefail

INPUT=$(cat 2>/dev/null || true)
[[ -z "$INPUT" ]] && exit 0

# Only enforce inside a Ralph loop.
[[ -z "${RALPH_AGENT_GUARD:-}" ]] && exit 0

WORKSPACE="${RALPH_WORKSPACE:-$(pwd)}"
HANDOFF="$WORKSPACE/.ralph/handoff.md"
BASELINE="$WORKSPACE/.ralph/loop-baseline-head"

# Nothing to compare against — first loop or non-Ralph context. Stay silent.
[[ -f "$BASELINE" ]] || exit 0
[[ -f "$HANDOFF" ]] || {
  printf '{"systemMessage":"⚠️ handoff.md missing — next loop will start blind. Write a short Working Set before yielding."}\n'
  exit 0
}

_mtime() {
  # GNU and BSD stat differ; try both.
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0
}

handoff_mtime=$(_mtime "$HANDOFF")
baseline_mtime=$(_mtime "$BASELINE")

if [[ "$handoff_mtime" -le "$baseline_mtime" ]]; then
  printf '{"systemMessage":"⚠️ handoff.md not updated this loop — next loop will start blind. A short Working Set (current task, key files, next steps) before yielding makes the next loop much faster."}\n'
fi

exit 0
