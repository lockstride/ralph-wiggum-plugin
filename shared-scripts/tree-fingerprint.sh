#!/bin/bash
# Ralph Wiggum: working-tree fingerprint
#
# Prints one hash that changes whenever the CONTENT of the workspace does:
# HEAD, every tracked change (staged or not), and every untracked file git does
# not ignore (path + content). Ignored paths — build output, node_modules,
# .ralph/ itself — are outside it by construction, so restarting a daemon,
# resetting a cache, or a gate writing only ignored artifacts leaves it
# unchanged.
#
# gate-run.sh records it beside each verdict as <label>-latest.tree, and
# ralph-guard.sh compares against that record: the per-label gate cache
# re-opens when a file changed by ANY means — a Write/Edit event, or a Bash
# edit (`sed -i`, a heredoc, a python script) that no tool event reports.
#
# Usage: tree-fingerprint.sh [workspace]   (default: $RALPH_WORKSPACE, else $PWD)
#
# Prints nothing and exits 0 when no fingerprint can be computed (not a git
# work tree). Callers treat an empty result as "unknown", never as a match.

set -euo pipefail

workspace="${1:-${RALPH_WORKSPACE:-$PWD}}"
cd "$workspace" 2>/dev/null || exit 0
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

# --no-optional-locks: never take index.lock for a stat refresh. This runs from
# the guard hook and the gate runner while the agent may be committing in the
# same repository, and a lock held here would fail that commit.
{
  git --no-optional-locks rev-parse -q --verify HEAD 2>/dev/null || echo "(unborn HEAD)"
  git --no-optional-locks diff HEAD --binary --no-ext-diff --no-textconv --no-color 2>/dev/null || true
  # Untracked files contribute path and content. cksum skips what it cannot
  # read (a nested repository lists as a directory) and keeps going, so one odd
  # entry never truncates the rest of the list.
  git --no-optional-locks ls-files -z --others --exclude-standard 2>/dev/null |
    xargs -0 -r cksum 2>/dev/null || true
} | git hash-object --stdin
