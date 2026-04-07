#!/bin/bash
# Ralph Wiggum: Install script for non-Claude-Code users
#
# Drops the ralph shell scripts into .claude/ralph-scripts/ in the
# current directory, so Cursor users (or anyone else) can run the loop
# without installing the Claude Code plugin system.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/lockstride/ralph-wiggum-plugin/main/install.sh | bash
#   # or, from a clone:
#   ./install.sh

set -euo pipefail

REPO_URL="${RALPH_REPO_URL:-https://github.com/lockstride/ralph-wiggum-plugin.git}"
REF="${RALPH_REF:-main}"
TARGET_DIR="${RALPH_TARGET_DIR:-.claude/ralph-scripts}"
TEMPLATES_DIR="${RALPH_TEMPLATES_DIR:-.claude/ralph-templates}"

echo "🐛 Ralph Wiggum installer"
echo ""

if ! command -v git >/dev/null 2>&1; then
  echo "❌ git is required" >&2
  exit 1
fi

# If we're running inside a clone, just copy from here.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)"
if [[ -n "$SCRIPT_DIR" ]] && [[ -d "$SCRIPT_DIR/shared-scripts" ]]; then
  echo "📂 Copying from local clone at $SCRIPT_DIR"
  mkdir -p "$TARGET_DIR" "$TEMPLATES_DIR"
  cp "$SCRIPT_DIR/shared-scripts/"*.sh "$TARGET_DIR/"
  cp "$SCRIPT_DIR/shared-references/templates/"*.md "$TEMPLATES_DIR/"
else
  # Otherwise clone a shallow copy into a tmp dir and copy out the bits we need.
  tmp=$(mktemp -d)
  trap "rm -rf $tmp" EXIT
  echo "📥 Cloning $REPO_URL#$REF..."
  git clone --depth 1 --branch "$REF" "$REPO_URL" "$tmp/ralph" >/dev/null 2>&1
  mkdir -p "$TARGET_DIR" "$TEMPLATES_DIR"
  cp "$tmp/ralph/shared-scripts/"*.sh "$TARGET_DIR/"
  cp "$tmp/ralph/shared-references/templates/"*.md "$TEMPLATES_DIR/"
fi

chmod +x "$TARGET_DIR/"*.sh

cat <<EOF

✓ Installed Ralph scripts to   $TARGET_DIR
✓ Installed prompt templates to $TEMPLATES_DIR

Run the interactive launcher:
  $TARGET_DIR/ralph-setup.sh

Or a single smoke-test iteration:
  $TARGET_DIR/ralph-once.sh --cli claude --spec

⚠️  Ralph runs the agent with all tool approvals pre-granted.
    Use only in a dedicated worktree with clean git state.
EOF
