#!/bin/bash
# Lint and format-check all shell scripts in the project.
#
# Usage:
#   ./lint.sh          # check only (CI-friendly)
#   ./lint.sh --fix    # auto-format with shfmt
#
# Performance:
#   - shellcheck and shfmt run in parallel via `xargs -P` (uses available CPUs).
#   - bats runs in parallel via `--jobs` IF GNU `parallel` is installed (brew
#     install parallel). Without it, bats falls back to serial execution.
#     Override the worker count with RALPH_LINT_JOBS (default: 4).

set -euo pipefail

FIX=false
if [[ "${1:-}" == "--fix" ]]; then
  FIX=true
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JOBS="${RALPH_LINT_JOBS:-4}"

SH_FILES=()
while IFS= read -r f; do
  SH_FILES+=("$f")
done < <(find "$REPO_ROOT" -name '*.sh' -not -path '*/.git/*' -not -path '*/.ralph/*' | sort)

errors=0

# -----------------------------------------------------------------------------
# Shellcheck stage (parallel via xargs -P)
# -----------------------------------------------------------------------------
if command -v shellcheck >/dev/null 2>&1; then
  echo "shellcheck: checking ${#SH_FILES[@]} files (jobs=$JOBS)..."
  if ! printf '%s\0' "${SH_FILES[@]}" | xargs -0 -n1 -P"$JOBS" shellcheck; then
    errors=1
  fi
  echo ""
else
  echo "❌ shellcheck not found (brew install shellcheck)" >&2
  errors=1
fi

# -----------------------------------------------------------------------------
# shfmt (parallel via xargs -P)
# -----------------------------------------------------------------------------
if command -v shfmt >/dev/null 2>&1; then
  if [[ "$FIX" == "true" ]]; then
    echo "shfmt: formatting ${#SH_FILES[@]} files (jobs=$JOBS)..."
    printf '%s\0' "${SH_FILES[@]}" | xargs -0 -n1 -P"$JOBS" shfmt -i 2 -ci -w
    echo "Done."
  else
    echo "shfmt: checking ${#SH_FILES[@]} files (jobs=$JOBS)..."
    # Per-file diff, parallel. xargs returns non-zero if any invocation does.
    # The inner sh -c receives each file as $1; the single-quoted body is
    # intentional so $1 expands inside the worker, not in the outer shell.
    # shellcheck disable=SC2016
    if ! printf '%s\0' "${SH_FILES[@]}" |
      xargs -0 -n1 -P"$JOBS" sh -c '
        if ! shfmt -i 2 -ci -d "$1" >/dev/null 2>&1; then
          echo "  needs formatting: $1" >&2
          exit 1
        fi
      ' _; then
      errors=1
    fi
  fi
  echo ""
else
  echo "❌ shfmt not found (brew install shfmt)" >&2
  errors=1
fi

# -----------------------------------------------------------------------------
# bats — parallel via --jobs when GNU parallel is available, else serial.
# -----------------------------------------------------------------------------
if command -v bats >/dev/null 2>&1; then
  if compgen -G "$REPO_ROOT/tests/*.bats" >/dev/null 2>&1; then
    if command -v parallel >/dev/null 2>&1; then
      echo "bats: running tests (jobs=$JOBS, parallel mode)..."
      # --no-parallelize-within-files: keep tests within a file serial so
      # tests that share fixtures (mock workspace, env vars) don't collide.
      # Cross-file parallelism is the big win here — slowest file (gate-run)
      # caps total wallclock instead of summing all files.
      if ! bats --jobs "$JOBS" --no-parallelize-within-files "$REPO_ROOT"/tests/*.bats; then
        errors=1
      fi
    else
      echo "bats: running tests (serial — install GNU parallel for --jobs support)..."
      if ! bats "$REPO_ROOT"/tests/*.bats; then
        errors=1
      fi
    fi
    echo ""
  fi
else
  echo "⚠️  bats not installed — skipping tests (brew install bats-core)"
  echo ""
fi

if [[ "$errors" -ne 0 ]]; then
  echo "Lint or test issues found. Run ./lint.sh --fix to auto-format."
  exit 1
else
  echo "All checks passed."
fi
