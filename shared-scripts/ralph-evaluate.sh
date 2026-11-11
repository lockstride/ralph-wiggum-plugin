#!/usr/bin/env bash
# Ralph Wiggum: Acceptance Evaluation Loop
#
# Runs a second Ralph loop *after* a main implementation loop has finished,
# with an orchestrator prompt that alternates between VERIFIER and REWORK
# roles (each delegated to a sub-agent via the Task tool). The orchestrator
# maintains .ralph/acceptance-report.md; the loop exits when the report's
# top-level "All acceptance criteria met and verified" checkbox is flipped
# to [x] by the verifier, or when the loop cap (default 10) is hit.
#
# Usage:
#   ./ralph-evaluate.sh --prompt                 # ground truth = PROMPT.md
#   ./ralph-evaluate.sh --prompt-file FOO.md     # ground truth = FOO.md
#   ./ralph-evaluate.sh --spec [name]            # ground truth = specs/<name>/tasks.md
#   ./ralph-evaluate.sh --prompt --fresh         # wipe existing report first
#   ./ralph-evaluate.sh --prompt -n 8 --cli claude -m opus
#   ./ralph-evaluate.sh mode                     # the orchestrator's mode for this pass
#
# Flags:
#   --cli <claude|cursor-agent>   Agent CLI (default: claude)
#   -m, --model <id>              Model (default: CLI-specific default)
#   -n, --loops N                 Eval loop cap (default: 10).
#                                 Env: RALPH_EVAL_MAX_LOOPS.
#   --prompt | --prompt-md        Ground truth = PROMPT.md in workspace root
#   --prompt-file <path>          Ground truth = specified file
#   --spec [name]                 Ground truth = specs/<name>/tasks.md (newest if omitted)
#   --fresh                       Delete any existing acceptance-report.md first
#   -h, --help                    Show this help
#
# Environment:
#   RALPH_EVAL_FRAMING_TEMPLATE   Custom orchestrator framing template
#                                 (absolute or workspace-relative path).
#                                 Rendered with {{GROUND_TRUTH_PATH}} and
#                                 {{REPORT_PATH}}. Default:
#                                 templates/evaluator-framing.md.
#   RALPH_EVAL_REPORT_TEMPLATE    Custom acceptance-report seed template
#                                 (absolute or workspace-relative path).
#                                 Rendered with {{GROUND_TRUTH_PATH}}.
#                                 Default: templates/acceptance-report-template.md.
#   RALPH_EVAL_MAX_LOOPS          Eval loop cap when -n/--loops is not given.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/agent-adapter.sh"
source "$SCRIPT_DIR/ralph-common.sh"
source "$SCRIPT_DIR/prompt-resolver.sh"

show_help() {
  sed -n '3,41p' "$0" | sed 's/^# \{0,1\}//'
}

WORKSPACE=""
CLI_FROM_FLAG=""
MODEL_FROM_FLAG=""
EVAL_ITER_FROM_FLAG=""
GROUND_TRUTH_MODE=""
GROUND_TRUTH_VALUE=""
FRESH=false

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --cli)
        CLI_FROM_FLAG="$2"
        shift 2
        ;;
      -m | --model)
        MODEL_FROM_FLAG="$2"
        shift 2
        ;;
      -n | --loops)
        EVAL_ITER_FROM_FLAG="$2"
        shift 2
        ;;
      --prompt | --prompt-md)
        GROUND_TRUTH_MODE="prompt"
        shift
        ;;
      --prompt-file)
        GROUND_TRUTH_MODE="file"
        GROUND_TRUTH_VALUE="$2"
        shift 2
        ;;
      --spec)
        GROUND_TRUTH_MODE="spec"
        if [[ $# -gt 1 ]] && [[ "${2:0:1}" != "-" ]]; then
          GROUND_TRUTH_VALUE="$2"
          shift 2
        else
          shift
        fi
        ;;
      --fresh)
        FRESH=true
        shift
        ;;
      -h | --help)
        show_help
        exit 0
        ;;
      -*)
        echo "Unknown option: $1" >&2
        exit 1
        ;;
      *)
        WORKSPACE="$1"
        shift
        ;;
    esac
  done
}

# =============================================================================
# GROUND TRUTH RESOLUTION
# =============================================================================

# Resolve the ground-truth file path that the orchestrator re-checks against.
# Echoes the absolute path on success, non-zero on failure.
resolve_ground_truth() {
  local workspace="$1" mode="$2" value="${3:-}"
  case "$mode" in
    prompt)
      local path="$workspace/PROMPT.md"
      if [[ ! -f "$path" ]]; then
        echo "❌ PROMPT.md not found at $path" >&2
        return 1
      fi
      echo "$path"
      ;;
    file)
      if [[ -z "$value" ]]; then
        echo "❌ --prompt-file requires a path" >&2
        return 1
      fi
      if [[ ! -f "$value" ]] && [[ -f "$workspace/$value" ]]; then
        value="$workspace/$value"
      fi
      if [[ ! -f "$value" ]]; then
        echo "❌ Prompt file not found: $value" >&2
        return 1
      fi
      echo "$value"
      ;;
    spec)
      local name="$value"
      if [[ -z "$name" ]]; then
        name=$(list_specs "$workspace" | head -1)
      fi
      if [[ -z "$name" ]]; then
        echo "❌ No specs found under $workspace/specs/" >&2
        return 1
      fi
      local tasks="$workspace/specs/$name/tasks.md"
      if [[ ! -f "$tasks" ]]; then
        echo "❌ tasks.md not found at $tasks" >&2
        return 1
      fi
      echo "$tasks"
      ;;
    *)
      echo "❌ Unknown ground-truth mode: $mode (expected prompt|file|spec)" >&2
      return 1
      ;;
  esac
}

# =============================================================================
# REPORT + PROMPT SETUP
# =============================================================================

# Resolve an operator-supplied template override path (0.17.0). Accepts
# absolute paths or paths relative to the workspace root. Echoes the
# resolved absolute path; fails loudly when the override is set but
# unreadable — an operator who set an override wants it used, not
# silently swapped for the stock template.
_resolve_eval_template_override() {
  local workspace="$1" path="$2" label="$3"
  if [[ "$path" != /* ]] && [[ -f "$workspace/$path" ]]; then
    path="$workspace/$path"
  fi
  if [[ ! -f "$path" ]]; then
    echo "❌ $label override not found: $path" >&2
    return 1
  fi
  echo "$path"
}

# Seed .ralph/acceptance-report.md from template if missing.
# Honors $FRESH: delete-and-recreate when true.
# 0.17.0: RALPH_EVAL_REPORT_TEMPLATE overrides the stock template so
# consuming projects can seed a differently-shaped report (e.g. a
# per-ticket ledger) while keeping the loop's checkbox-completion
# contract. Only {{GROUND_TRUTH_PATH}} is substituted.
seed_report() {
  local workspace="$1" ground_truth="$2"
  local report="$workspace/.ralph/acceptance-report.md"
  local template
  if [[ -n "${RALPH_EVAL_REPORT_TEMPLATE:-}" ]]; then
    template=$(_resolve_eval_template_override "$workspace" \
      "$RALPH_EVAL_REPORT_TEMPLATE" "RALPH_EVAL_REPORT_TEMPLATE") || return 1
    echo "  ✓ Report template override: $template" >&2
  else
    template="$(_default_templates_dir)/acceptance-report-template.md"
  fi

  if [[ "$FRESH" == "true" ]]; then
    rm -f "$report"
  fi

  if [[ -f "$report" ]]; then
    return 0
  fi

  if [[ ! -f "$template" ]]; then
    echo "❌ Acceptance report template not found: $template" >&2
    return 1
  fi

  mkdir -p "$(dirname "$report")"
  # Single placeholder substitution — bash param expansion handles this fine.
  local body
  body=$(cat "$template")
  body="${body//\{\{GROUND_TRUTH_PATH\}\}/$ground_truth}"
  printf '%s' "$body" >"$report"
}

# Record the absolute path to gate-run.sh in `.ralph/gate-runner` so the
# verifier/rework sub-agents can invoke the gate harness without guessing
# where the plugin is installed. gate-run.sh lives in the plugin install
# (not the repo), so an agent that tries to `find` it in the workspace comes
# up empty and may resort to hand-writing `final-latest.*` — which the
# completion guard then trusts. The breadcrumb removes the guesswork;
# ralph-guard.sh denies hand-forged gate breadcrumbs so the harness stays
# the only writer.
record_gate_runner() {
  local workspace="$1" scripts_dir="$2"
  mkdir -p "$workspace/.ralph"
  printf '%s\n' "$scripts_dir/gate-run.sh" >"$workspace/.ralph/gate-runner"
}

# The script path the orchestrator runs `mode` from; the plugin install is not
# in the repo, so the skill cannot assume where it is.
record_eval_runner() {
  local workspace="$1" scripts_dir="$2"
  mkdir -p "$workspace/.ralph"
  printf '%s\n' "$scripts_dir/ralph-evaluate.sh" >"$workspace/.ralph/eval-runner"
}

# The eval loop's mode for this pass, from the report on disk: REWORK when a
# gap is actionable (a `[ ]` line that is neither parked `(blocked: <reason>)`
# — _RALPH_PARKED_RE, the completion count's own test — nor the top-level
# checkbox) AND the verify pass covered every criterion and surface
# the ground truth names (verify-coverage.sh); otherwise VERIFIER, which
# fills the missing results. Prints MODE=<mode>, then what a refused rework
# still lacks.
#
# Bounded: the same uncovered set refuses a rework RALPH_COVERAGE_REFUSALS
# times (default 2), then rework runs anyway — a verifier that cannot produce a
# result must not wedge the loop. Fails open: an unreadable ground truth or a
# coverage check that errors counts as covered.
pick_mode() {
  local workspace="$1"
  local report="$workspace/.ralph/acceptance-report.md" state="$workspace/.ralph/coverage-refusals"
  local gaps
  gaps=$(grep -E '^- \[ \]' "$report" 2>/dev/null | grep -vE "$_RALPH_PARKED_RE" | grep -vF 'All acceptance criteria met' || true)
  if [[ -z "$gaps" ]]; then
    echo "MODE=VERIFIER"
    return 0
  fi

  local truth missing="" rc=0
  truth=$(cat "$workspace/.ralph/eval-ground-truth" 2>/dev/null) || truth=""
  [[ -z "$truth" || "$truth" == /* ]] || truth="$workspace/$truth"
  if [[ -n "$truth" ]]; then
    missing=$(bash "$SCRIPT_DIR/verify-coverage.sh" "$truth" "$report" 2>/dev/null) || rc=$?
  fi
  if [[ $rc -ne 1 ]]; then
    rm -f "$state"
    echo "MODE=REWORK"
    return 0
  fi

  local sig prev_sig="" prev_n=0 n=0
  sig=$(printf '%s' "$missing" | cksum | awk '{print $1}')
  if [[ -f "$state" ]]; then
    read -r prev_sig prev_n <"$state" || true
  fi
  [[ "$prev_n" =~ ^[0-9]+$ ]] || prev_n=0
  [[ "$prev_sig" == "$sig" ]] && n=$prev_n
  if [[ $n -ge ${RALPH_COVERAGE_REFUSALS:-2} ]]; then
    echo "MODE=REWORK"
    echo "Verify results still missing after $n refusals; reworking anyway:"
    printf '%s\n' "$missing"
    return 0
  fi
  printf '%s %s\n' "$sig" "$((n + 1))" >"$state" 2>/dev/null || true
  echo "MODE=VERIFIER"
  echo "Rework refused: the verify pass has no result for:"
  printf '%s\n' "$missing"
}

# Give the eval loop an empty gates dir, so a gate left behind by the
# implementation loop cannot satisfy its completion guard. The eval loop's
# verifier/rework sub-agents run their gates under label `final` and write
# fresh `final-latest.*` artifacts.
#
# 0.24.0: ARCHIVE rather than delete. Clearing is right — a green `full` from
# the implementation loop must not stand in for the eval loop's `final` tier —
# but the previous `rm -rf` also destroyed the implementation phase's entire
# gate record, which is the first thing a post-mortem reads. cur-71 ran 46
# gates and finished with exactly one still readable. Moving the directory
# aside gives the guard the same empty slate and keeps the evidence.
#
# No archive is ever deleted. The eval loop marks the dir it starts with
# (EVAL_GATES_MARKER), so a relaunch can tell its own gates from the
# implementation phase's: a prior eval run's dir is archived as
# gates.eval-<UTC stamp>, leaving gates.impl/ — the implementation record —
# untouched. An unmarked dir is the implementation phase's and becomes
# gates.impl/; an older gates.impl/, from an earlier cycle on this worktree,
# is kept as gates.impl-<UTC stamp>. Falls back to deleting if the move
# fails — an empty gates dir is the invariant, the archive is a courtesy.
EVAL_GATES_MARKER=".eval-run"
archive_impl_gates() {
  local workspace="$1"
  local gates="$workspace/.ralph/gates"
  if [[ -d "$gates" ]]; then
    local stamp dest="$gates.impl"
    stamp=$(date -u +%Y%m%dT%H%M%SZ)
    if [[ -f "$gates/$EVAL_GATES_MARKER" ]]; then
      dest="$gates.eval-$stamp"
    elif [[ -d "$dest" ]]; then
      mv "$dest" "$gates.impl-$stamp" 2>/dev/null || true
    fi
    mv "$gates" "$dest" 2>/dev/null || rm -rf "$gates"
  fi
  mkdir -p "$gates"
  : >"$gates/$EVAL_GATES_MARKER"
}

# Render a thin framing prompt that points the agent at the
# `running-acceptance-evaluation` skill and supplies the per-run paths
# (ground truth, report). The orchestrator workflow itself, plus the
# VERIFIER and REWORK role bodies, all live as plugin skills under
# `skills/running-acceptance-evaluation/`, `skills/verifying-acceptance-criteria/`,
# and `skills/addressing-acceptance-gaps/` (0.6.0+). The framing prompt
# is intentionally minimal — everything load-bearing is in the skills.
# 0.17.0: RALPH_EVAL_FRAMING_TEMPLATE overrides the stock framing so
# consuming projects can point the loop at their own orchestrator skill
# (e.g. a ticket-based verify/rework flow). The override is rendered
# with the same {{GROUND_TRUTH_PATH}} / {{REPORT_PATH}} placeholders.
render_orchestrator_prompt() {
  local workspace="$1" ground_truth="$2" report="$3"

  local tpl_dir framing_tpl
  tpl_dir="$(_default_templates_dir)"
  if [[ -n "${RALPH_EVAL_FRAMING_TEMPLATE:-}" ]]; then
    framing_tpl=$(_resolve_eval_template_override "$workspace" \
      "$RALPH_EVAL_FRAMING_TEMPLATE" "RALPH_EVAL_FRAMING_TEMPLATE") || return 1
    echo "  ✓ Framing template override: $framing_tpl" >&2
  else
    framing_tpl="$tpl_dir/evaluator-framing.md"
  fi

  if [[ ! -f "$framing_tpl" ]]; then
    echo "❌ Eval framing template not found: $framing_tpl" >&2
    return 1
  fi

  local body
  body=$(_render_template "$framing_tpl" \
    GROUND_TRUTH_PATH "$ground_truth" \
    REPORT_PATH "$report")

  _write_effective_prompt "$workspace" "$body"
}

# =============================================================================
# MAIN
# =============================================================================

main() {
  if [[ -z "$WORKSPACE" ]] || [[ "$WORKSPACE" == "." ]]; then
    WORKSPACE="$(pwd)"
  else
    WORKSPACE="$(cd "$WORKSPACE" && pwd)"
  fi

  # CLI + model defaults — same cascade as ralph-once.sh so the eval loop
  # feels identical to launch.
  RALPH_AGENT_CLI="${CLI_FROM_FLAG:-${RALPH_AGENT_CLI:-claude}}"
  RALPH_AGENT_CLI="$(agent_normalize_cli_name "$RALPH_AGENT_CLI")"
  local MODEL="${MODEL_FROM_FLAG:-${MODEL:-}}"
  if [[ -z "$MODEL" ]]; then
    MODEL="$(agent_default_model "$RALPH_AGENT_CLI")"
  fi
  local ROTATE_THRESHOLD WARN_THRESHOLD
  derive_thresholds
  agent_check_thresholds "$RALPH_AGENT_CLI" "$MODEL" "$ROTATE_THRESHOLD" "$WARN_THRESHOLD" || exit 64
  local MAX_LOOPS="${EVAL_ITER_FROM_FLAG:-${RALPH_EVAL_MAX_LOOPS:-10}}"

  # Tell run_ralph_loop's completion guard (_complete_allowed) that this is
  # the eval loop, so it gates on the `final` tier-gate (this loop's bar),
  # not `full` (the impl loop's). Without this the eval loop is unsatisfiable:
  # it wipes .ralph/gates at start and need not run `full`, so full-latest.*
  # may never exist and completion blocks forever.
  export RALPH_EVAL_LOOP=1

  export RALPH_AGENT_CLI MODEL ROTATE_THRESHOLD WARN_THRESHOLD MAX_LOOPS

  if [[ -z "$GROUND_TRUTH_MODE" ]]; then
    # Sensible default: if PROMPT.md exists, use it. Otherwise require explicit flag.
    if [[ -f "$WORKSPACE/PROMPT.md" ]]; then
      GROUND_TRUTH_MODE="prompt"
    else
      echo "❌ No ground-truth source specified. Use --prompt, --prompt-file, or --spec." >&2
      exit 1
    fi
  fi

  echo "═══════════════════════════════════════════════════════════════════"
  echo "🔍 Ralph Wiggum: Acceptance Evaluation Loop"
  echo "═══════════════════════════════════════════════════════════════════"
  echo ""

  init_ralph_dir "$WORKSPACE"

  if ! _validate_gates_section "$WORKSPACE"; then
    exit 1
  fi

  local ground_truth
  if ! ground_truth=$(resolve_ground_truth "$WORKSPACE" "$GROUND_TRUTH_MODE" "$GROUND_TRUTH_VALUE"); then
    exit 1
  fi
  echo "✓ Ground truth: $ground_truth"

  # Record the ground-truth path as a breadcrumb so future tooling can find it.
  echo "$ground_truth" >"$WORKSPACE/.ralph/eval-ground-truth"

  local report="$WORKSPACE/.ralph/acceptance-report.md"
  if ! seed_report "$WORKSPACE" "$ground_truth"; then
    exit 1
  fi
  echo "✓ Report: $report$([[ "$FRESH" == "true" ]] && echo ' (fresh)')"

  archive_impl_gates "$WORKSPACE"

  record_gate_runner "$WORKSPACE" "$SCRIPT_DIR"
  record_eval_runner "$WORKSPACE" "$SCRIPT_DIR"
  rm -f "$WORKSPACE/.ralph/coverage-refusals"

  if ! render_orchestrator_prompt "$WORKSPACE" "$ground_truth" "$report" >/dev/null; then
    exit 1
  fi
  echo "✓ Orchestrator prompt rendered to .ralph/effective-prompt.md"

  # Point the loop's completion detector at the acceptance report. The
  # breadcrumb takes precedence over PROMPT.md-style heuristics.
  echo "$report" >"$WORKSPACE/.ralph/task-file-path"
  export RALPH_TASK_FILE="$report"

  if ! check_prerequisites "$WORKSPACE"; then
    exit 1
  fi

  echo ""
  echo "─────────────────────────────────────────────────────────────────"
  echo "Summary:"
  echo "  • CLI:          $RALPH_AGENT_CLI"
  echo "  • Model:        $MODEL"
  echo "  • Max eval loops: $MAX_LOOPS"
  echo "  • Ground truth: $ground_truth"
  echo "  • Report:       $report"
  echo "─────────────────────────────────────────────────────────────────"
  echo ""

  local task_status
  task_status=$(check_task_complete "$WORKSPACE")
  if [[ "$task_status" == "COMPLETE" ]]; then
    echo "🎉 Report already clean — nothing to evaluate. Use --fresh to re-run from scratch."
    exit 0
  fi

  run_ralph_loop "$WORKSPACE" "$SCRIPT_DIR"
  exit $?
}

# Standalone entrypoint: only run main() when invoked directly, so tests
# can source this script to exercise resolve_ground_truth / seed_report /
# render_orchestrator_prompt in isolation.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  if [[ "${1:-}" == "mode" ]]; then
    pick_mode "${RALPH_WORKSPACE:-$(pwd)}"
    exit $?
  fi
  parse_args "$@"
  main
fi
