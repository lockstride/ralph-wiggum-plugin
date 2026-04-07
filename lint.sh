#!/bin/bash
# Lint and format-check all shell scripts in the project.
#
# Usage:
#   ./lint.sh          # check only (CI-friendly)
#   ./lint.sh --fix    # auto-format with shfmt

set -euo pipefail

FIX=false
if [[ "${1:-}" == "--fix" ]]; then
  FIX=true
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SH_FILES=()
while IFS= read -r f; do
  SH_FILES+=("$f")
done < <(find "$REPO_ROOT" -name '*.sh' -not -path '*/.git/*' -not -path '*/.ralph/*' | sort)

errors=0

if command -v shellcheck >/dev/null 2>&1; then
  echo "shellcheck: checking ${#SH_FILES[@]} files..."
  for f in "${SH_FILES[@]}"; do
    if ! shellcheck "$f"; then
      errors=1
    fi
  done
  echo ""
else
  echo "❌ shellcheck not found (brew install shellcheck)" >&2
  errors=1
fi

if command -v shfmt >/dev/null 2>&1; then
  if [[ "$FIX" == "true" ]]; then
    echo "shfmt: formatting ${#SH_FILES[@]} files..."
    shfmt -i 2 -ci -w "${SH_FILES[@]}"
    echo "Done."
  else
    echo "shfmt: checking ${#SH_FILES[@]} files..."
    for f in "${SH_FILES[@]}"; do
      if ! shfmt -i 2 -ci -d "$f" >/dev/null 2>&1; then
        echo "  needs formatting: $f"
        errors=1
      fi
    done
  fi
  echo ""
else
  echo "❌ shfmt not found (brew install shfmt)" >&2
  errors=1
fi

if [[ "$errors" -ne 0 ]]; then
  echo "Lint issues found. Run ./lint.sh --fix to auto-format."
  exit 1
else
  echo "All checks passed."
fi
