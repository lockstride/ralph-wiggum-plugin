#!/usr/bin/env bats
# Behavioral tests for ralph-common.sh build_prompt() framing.
#
# Verifies the trimmed framing prompt contains required sections
# and does NOT contain removed sections.

load test_helper

setup() {
  create_mock_workspace

  # Default to impl-loop context; eval-loop tests opt in explicitly. Keeps
  # the completion guard keyed on `full` unless a test sets RALPH_EVAL_LOOP.
  unset RALPH_EVAL_LOOP

  # Source ralph-common.sh (requires agent-adapter.sh first)
  source "$SCRIPTS_DIR/agent-adapter.sh"
  source "$SCRIPTS_DIR/ralph-common.sh"

  # Create minimal state files that build_prompt expects
  echo "# Guardrails" > "$MOCK_WORKSPACE/.ralph/guardrails.md"
  echo "# Errors" > "$MOCK_WORKSPACE/.ralph/errors.log"

  # Write a mock effective prompt
  mkdir -p "$MOCK_WORKSPACE/.ralph"
  echo "Mock task body" > "$MOCK_WORKSPACE/.ralph/effective-prompt.md"

  # 0.14.0: [gates] is required for any startup that builds a prompt or
  # runs the completion guard. Seed with sentinel commands so the build
  # prompt's "## Gate Selection" block has actual values to interpolate.
  cat > "$MOCK_WORKSPACE/.ralph/command-policy" <<'EOF'
[gates]
basic | mock basic-check
full  | mock all-check
final | mock verify:final
EOF
}

teardown() {
  rm -rf "$MOCK_WORKSPACE"
}

@test "build_prompt includes Completion section (0.9.0)" {
  # 0.9.0 renamed "Completion Bar" → "Completion" (less Yelling) and
  # trimmed verbose "pre-existing failure is NEVER a reason" prose down
  # to a single short bullet. Core invariant unchanged: gate-must-pass
  # before flipping a checkbox; if it can't, emit GUTTER.
  local output
  output=$(build_prompt "$MOCK_WORKSPACE" 1)

  echo "$output" | grep -q "^## Completion$"
  echo "$output" | grep -q "GUTTER"
  # Completion must appear BEFORE State Files — it's the first rule.
  echo "$output" | awk '
    /^## Completion$/   { saw_cb=1 }
    /^## State Files/   { if (saw_cb) ok=1 }
    END { exit ok ? 0 : 1 }
  '
}

@test "build_prompt includes required sections (0.9.0)" {
  local output
  output=$(build_prompt "$MOCK_WORKSPACE" 1)

  echo "$output" | grep -q "State Files"
  echo "$output" | grep -q "Stop conditions"
  # 0.9.0 renamed "Loop Hygiene" → "Git hygiene" (the section is now
  # purely about git invariants, not loop flow rules).
  echo "$output" | grep -q "Git hygiene"
  echo "$output" | grep -q "Task Execution"
}

@test "build_prompt includes Gate Runner section when gate-run.sh is present (0.3.6)" {
  # gate-run.sh ships in-tree next to ralph-common.sh, so the block renders
  # under the normal test setup. 0.12.5 trimmed this block; 0.14.0 swapped
  # the label list to the new canonical set and surfaces each tier-gate
  # command from [gates]. Load-bearing assertions: section heading, hint
  # that the hook does the wrapping, full new label list, and the actual
  # tier-gate commands (loaded from [gates]) are surfaced.
  local output
  output=$(build_prompt "$MOCK_WORKSPACE" 1)

  echo "$output" | grep -q "## Gate Runner"
  echo "$output" | grep -qE "auto-wraps|hook"
  echo "$output" | grep -qE "basic.*full.*final.*unit.*integration.*e2e.*lint.*format"
  # The interpolated tier-gate commands appear by name
  echo "$output" | grep -q "mock basic-check"
  echo "$output" | grep -q "mock all-check"
  # 0.12.5: phrasing avoids the apostrophe form because bash 3.2's
  # `$( ... <<EOF heredoc ... )` parser mis-tracks single quotes when
  # the heredoc body contains them (real bug, breaks `head -N` parsing).
  echo "$output" | grep -qiE "do not pipe|never pipe"
}

@test "build_prompt Gate Runner: foreground waiter + exit-75 join protocol (0.16.0)" {
  # Gates run detached (the runner survives the caller); the agent's call
  # is a foreground waiter. 75 means still-running — re-run the SAME
  # command to join. Backgrounding a gate call is explicitly forbidden
  # (a subagent's background tasks are reaped on return — the 0.15.3
  # guidance died exactly that way in the field).
  local output
  output=$(build_prompt "$MOCK_WORKSPACE" 1)

  # Foreground instruction with a generous tool timeout.
  echo "$output" | grep -qiE "foreground"
  echo "$output" | grep -q "600000"
  # The 75/join continuation protocol.
  echo "$output" | grep -q "75"
  echo "$output" | grep -qiE "join"
  # Backgrounding is named and forbidden (assertions are single-line —
  # the prohibition clause wraps across lines in the heredoc).
  echo "$output" | grep -q "run_in_background"
  echo "$output" | grep -qiE "never a Monitor"
  # The verdict breadcrumb is still named.
  echo "$output" | grep -qF ".ralph/gates/<label>-latest.exit"
}

@test "build_prompt omits Gate Runner section when gate-run.sh is absent (0.3.6)" {
  # Simulate a degraded install where gate-run.sh is missing. The block
  # must not render (it would mislead the agent about a tool it can't call).
  # We copy ralph-common.sh to a temp dir without gate-run.sh, source it
  # from there, and call build_prompt.
  local tmp
  tmp=$(mktemp -d "$BATS_TMPDIR/rb-no-gate.XXXXXX")
  cp "$SCRIPTS_DIR/agent-adapter.sh" "$tmp/"
  cp "$SCRIPTS_DIR/ralph-common.sh" "$tmp/"
  # NOTE: deliberately do NOT copy gate-run.sh

  local output
  output=$(
    bash -c "
      source '$tmp/agent-adapter.sh'
      source '$tmp/ralph-common.sh'
      build_prompt '$MOCK_WORKSPACE' 1
    "
  )

  if echo "$output" | grep -q "## Gate Runner"; then
    rm -rf "$tmp"
    fail "Gate Runner section must not appear when gate-run.sh is absent"
  fi

  rm -rf "$tmp"
}

@test "build_prompt includes loop number and user body" {
  local output
  output=$(build_prompt "$MOCK_WORKSPACE" 7)
  echo "$output" | grep -q "Loop 7"
  echo "$output" | grep -q "Mock task body"
}

@test "build_prompt renders the canonical framing sections" {
  # The framing must include the load-bearing sections that the agent
  # depends on. Each section has its own behavioral test below for the
  # specific contract; this guards the structural shape.
  local output
  output=$(build_prompt "$MOCK_WORKSPACE" 1)
  echo "$output" | grep -q "^## Completion$"
  echo "$output" | grep -q "^## State Files"
  echo "$output" | grep -q "^## Stop conditions"
  echo "$output" | grep -q "^## After every commit"
  echo "$output" | grep -q "^## Handoff before yielding"
  echo "$output" | grep -q "^## Git hygiene"
}

@test "build_prompt Git hygiene forbids blanket git add (orphan-leak prevention)" {
  # The explicit-path rule is the preventive half of the orphan-leak
  # mechanism (_check_orphan_leak flags commits that swept up files via
  # `git add .` / -A / <dir>). Assert the rule and its anti-pattern list.
  local output
  output=$(build_prompt "$MOCK_WORKSPACE" 1)
  echo "$output" | grep -q "Stage by explicit path"
  echo "$output" | grep -q "git add -A"
}

# --- 0.12.0: handoff injection + Gate Selection block ---

@test "build_prompt injects handoff block when handoff.md exists (0.12.0)" {
  cat > "$MOCK_WORKSPACE/.ralph/handoff.md" <<'HOFF'
# Loop Handoff

## Last gate state

label: basic
exit: 1
duration: 12s
log: .ralph/gates/basic-latest.log
cmd: pnpm basic-check

## Working set

Active task: T031 — wire up X.
HOFF
  local output
  output=$(build_prompt "$MOCK_WORKSPACE" 1)
  echo "$output" | grep -q "^## Handoff from previous loop$"
  echo "$output" | grep -q "## Last gate state"
  echo "$output" | grep -q "Active task: T031"
  echo "$output" | grep -q "log: .ralph/gates/basic-latest.log"
}

@test "build_prompt omits handoff section when handoff.md is absent (0.12.0)" {
  rm -f "$MOCK_WORKSPACE/.ralph/handoff.md"
  local output
  output=$(build_prompt "$MOCK_WORKSPACE" 1)
  ! echo "$output" | grep -q "^## Handoff from previous loop$"
}

@test "build_prompt includes Gate Selection block (0.12.0)" {
  local output
  output=$(build_prompt "$MOCK_WORKSPACE" 1)
  echo "$output" | grep -q "^## Gate Selection$"
  # 0.14.0: interpolates [gates].basic + [gates].full into the block;
  # no hardcoded dMatrix-specific commands.
  echo "$output" | grep -q "mock basic-check"
  echo "$output" | grep -q "mock all-check"
  echo "$output" | grep -q "\[risky\]"
  # Regression guard: the old hardcoded literals must NOT appear.
  ! echo "$output" | grep -q "pnpm basic-check"
  ! echo "$output" | grep -q "pnpm all-check"
}

@test "build_prompt's Gate Selection follows [gates] override (0.14.0)" {
  # Swap the policy mid-test to confirm interpolation, not stale literals.
  cat > "$MOCK_WORKSPACE/.ralph/command-policy" <<'EOF'
[gates]
basic | npm run check:fast
full  | npm run check:full
final | npm run check:final
EOF
  local output
  output=$(build_prompt "$MOCK_WORKSPACE" 1)
  echo "$output" | grep -q "npm run check:fast"
  echo "$output" | grep -q "npm run check:full"
  ! echo "$output" | grep -q "mock basic-check"
}

@test "init_ralph_dir seeds handoff.md skeleton on first init (0.12.0)" {
  local fresh
  fresh=$(mktemp -d "$BATS_TMPDIR/rb-init.XXXXXX")
  init_ralph_dir "$fresh"
  [ -f "$fresh/.ralph/handoff.md" ]
  grep -q "## Last gate state" "$fresh/.ralph/handoff.md"
  # 0.12.5: the "## Working set" stub was removed from the skeleton — the
  # auto-enriched state covers the no-agent-write case, and the preamble
  # comment still instructs the agent to add Working set themselves before
  # yielding. The expectation is now that the preamble mentions it, not
  # that a stub section exists.
  grep -q "Working set" "$fresh/.ralph/handoff.md"
  ! grep -q "^## Working set" "$fresh/.ralph/handoff.md"
  rm -rf "$fresh"
}

@test "init_ralph_dir does not overwrite existing handoff.md (0.12.0)" {
  local fresh
  fresh=$(mktemp -d "$BATS_TMPDIR/rb-init2.XXXXXX")
  mkdir -p "$fresh/.ralph"
  echo "existing content" > "$fresh/.ralph/handoff.md"
  init_ralph_dir "$fresh"
  grep -q "existing content" "$fresh/.ralph/handoff.md"
  rm -rf "$fresh"
}

# ---------------------------------------------------------------------------
# _check_orphan_leak — orphan file detection (0.7.0)
# ---------------------------------------------------------------------------

@test "_check_orphan_leak returns 1 on leak (0.7.0)" {
  # Set up a fake git repo with a baseline that shows a file as untracked
  # at loop start, then commits it — simulating the broad-add pattern.
  local ws
  ws=$(mktemp -d "$BATS_TMPDIR/orphan-test.XXXXXX")
  git -C "$ws" init -q
  git -C "$ws" config user.email "test@test.com"
  git -C "$ws" config user.name "Test"

  # Initial commit (baseline HEAD)
  echo "init" >"$ws/init.txt"
  git -C "$ws" add init.txt
  git -C "$ws" commit -q -m "init"

  # Record baseline BEFORE the orphan appears
  mkdir -p "$ws/.ralph"
  git -C "$ws" rev-parse HEAD >"$ws/.ralph/loop-baseline-head"
  git -C "$ws" ls-files --others --exclude-standard >"$ws/.ralph/loop-baseline-untracked" 2>/dev/null || true

  # Now create an orphan and commit it (simulating broad git add)
  echo "orphan" >"$ws/orphan.txt"
  git -C "$ws" ls-files --others --exclude-standard >"$ws/.ralph/loop-baseline-untracked"
  git -C "$ws" add orphan.txt
  git -C "$ws" commit -q -m "add orphan"

  local rc=0
  _check_orphan_leak "$ws" || rc=$?
  [ "$rc" -eq 1 ]

  # Errors.log should record the leak
  grep -q 'ORPHAN FILE LEAK' "$ws/.ralph/errors.log"

  rm -rf "$ws"
}

@test "_check_orphan_leak writes objective orphan-leak.md handoff (0.11.3)" {
  # 0.11.3 demoted ORPHAN_LEAK from gutter trigger to non-blocking warning.
  # The leak file list must surface to the next loop via .ralph/orphan-leak.md,
  # with strictly objective content (file list + detector facts, no editorial).
  local ws
  ws=$(mktemp -d "$BATS_TMPDIR/orphan-handoff.XXXXXX")
  git -C "$ws" init -q
  git -C "$ws" config user.email "test@test.com"
  git -C "$ws" config user.name "Test"

  echo "init" >"$ws/init.txt"
  git -C "$ws" add init.txt
  git -C "$ws" commit -q -m "init"

  mkdir -p "$ws/.ralph"
  git -C "$ws" rev-parse HEAD >"$ws/.ralph/loop-baseline-head"

  # Create two orphans and commit them
  echo "scratch" >"$ws/scratch.tmp"
  echo "debug" >"$ws/debug.log"
  git -C "$ws" ls-files --others --exclude-standard >"$ws/.ralph/loop-baseline-untracked"
  git -C "$ws" add scratch.tmp debug.log
  git -C "$ws" commit -q -m "add orphans"

  _check_orphan_leak "$ws" || true

  # The handoff file exists and is non-empty
  [ -f "$ws/.ralph/orphan-leak.md" ]
  [ -s "$ws/.ralph/orphan-leak.md" ]

  # Lists both leaked files
  grep -Fq 'scratch.tmp' "$ws/.ralph/orphan-leak.md"
  grep -Fq 'debug.log' "$ws/.ralph/orphan-leak.md"

  # Mentions it's informational / non-blocking — not a stop signal
  grep -Fqi 'does not block' "$ws/.ralph/orphan-leak.md"

  # Records HEAD context for forensic clarity
  grep -Fq 'Loop baseline HEAD' "$ws/.ralph/orphan-leak.md"
  grep -Fq 'Loop end HEAD' "$ws/.ralph/orphan-leak.md"

  # Strictly objective: must not editorialize the agent's intent
  ! grep -Eqi 'confused|stuck|broken|panic|wrong' "$ws/.ralph/orphan-leak.md"

  rm -rf "$ws"
}

@test "_capture_loop_baseline clears stale orphan-leak.md (0.11.3)" {
  # Each fresh loop starts with a clean slate — a prior loop's orphan
  # warning must not bleed into an unrelated subsequent loop.
  local ws
  ws=$(mktemp -d "$BATS_TMPDIR/orphan-cleanup.XXXXXX")
  git -C "$ws" init -q
  git -C "$ws" config user.email "test@test.com"
  git -C "$ws" config user.name "Test"
  echo "init" >"$ws/init.txt"
  git -C "$ws" add init.txt
  git -C "$ws" commit -q -m "init"

  mkdir -p "$ws/.ralph"
  echo "stale warning from a prior loop" >"$ws/.ralph/orphan-leak.md"

  _capture_loop_baseline "$ws"

  [ ! -f "$ws/.ralph/orphan-leak.md" ]

  rm -rf "$ws"
}

@test "_check_orphan_leak skips files named in task-summary (0.9.1)" {
  local ws
  ws=$(mktemp -d "$BATS_TMPDIR/orphan-allowlist.XXXXXX")
  git -C "$ws" init -q
  git -C "$ws" config user.email "test@test.com"
  git -C "$ws" config user.name "Test"

  echo "init" >"$ws/init.txt"
  git -C "$ws" add init.txt
  git -C "$ws" commit -q -m "init"

  mkdir -p "$ws/.ralph"
  git -C "$ws" rev-parse HEAD >"$ws/.ralph/loop-baseline-head"

  # Create the file the task spec names, then commit it
  mkdir -p "$ws/apps/api/tests/e2e"
  echo "test content" >"$ws/apps/api/tests/e2e/attach-matrix.e2e.spec.ts"
  git -C "$ws" ls-files --others --exclude-standard >"$ws/.ralph/loop-baseline-untracked"
  git -C "$ws" add "apps/api/tests/e2e/attach-matrix.e2e.spec.ts"
  git -C "$ws" commit -q -m "add e2e test"

  # Task summary explicitly names this file path in backticks
  cat >"$ws/.ralph/task-summary" <<'SUMMARY'
done=5
total=6
remaining=1
---
- [ ] T024 E2E test at `apps/api/tests/e2e/attach-matrix.e2e.spec.ts`
SUMMARY

  # Should return 0 — the "leaked" file is expected by the task spec.
  _check_orphan_leak "$ws"

  rm -rf "$ws"
}

@test "_write_task_summary: refresh overwrites a stale loop-start snapshot (0.14.8)" {
  # test/000534 left task-summary frozen at done=0 after COMPLETE because
  # it was only written at session start. The COMPLETE exit paths now call
  # _write_task_summary again; this pins the refresh semantics.
  cat > "$MOCK_WORKSPACE/tasks.md" <<'TASKS'
- [x] T001 first task
- [x] T002 second task
TASKS
  echo "$MOCK_WORKSPACE/tasks.md" > "$MOCK_WORKSPACE/.ralph/task-file-path"

  cat > "$MOCK_WORKSPACE/.ralph/task-summary" <<'STALE'
done=0
total=2
remaining=2
---
- [ ] T001 first task
STALE

  _write_task_summary "$MOCK_WORKSPACE"

  grep -q "done=2" "$MOCK_WORKSPACE/.ralph/task-summary"
  grep -q "remaining=0" "$MOCK_WORKSPACE/.ralph/task-summary"
  ! grep -q '^\- \[ \]' "$MOCK_WORKSPACE/.ralph/task-summary"
}

# ---------------------------------------------------------------------------
# Completion bar — _complete_allowed refuses ALL_TASKS_DONE unless the
# loop's tier gate matches its [gates] entry and exits 0. The impl loop
# (default) gates on `full`; the eval loop (RALPH_EVAL_LOOP=1) gates on
# `final`. See the eval-aware block further down.
# ---------------------------------------------------------------------------

@test "_complete_allowed: green full gate matching [gates].full → allow" {
  # setup() already wrote [gates].full = "mock all-check".
  mkdir -p "$MOCK_WORKSPACE/.ralph/gates"
  printf 'mock all-check' >"$MOCK_WORKSPACE/.ralph/gates/full-latest.cmd"
  printf '0'              >"$MOCK_WORKSPACE/.ralph/gates/full-latest.exit"
  _complete_allowed "$MOCK_WORKSPACE"
}

@test "_complete_allowed: in-flight detached full gate → block despite stale green (0.16.0)" {
  # A detached gate is still running; the green breadcrumb on disk is from
  # the PREVIOUS run and must not satisfy completion.
  mkdir -p "$MOCK_WORKSPACE/.ralph/gates/.full.lock"
  echo $$ > "$MOCK_WORKSPACE/.ralph/gates/.full.lock/pid"
  printf 'mock all-check' >"$MOCK_WORKSPACE/.ralph/gates/full-latest.cmd"
  printf '0'              >"$MOCK_WORKSPACE/.ralph/gates/full-latest.exit"
  ! _complete_allowed "$MOCK_WORKSPACE"
  [[ "$_COMPLETE_BLOCK_REASON" == *"still running"* ]]
}

@test "_complete_allowed: red full gate → block" {
  mkdir -p "$MOCK_WORKSPACE/.ralph/gates"
  printf 'mock all-check' >"$MOCK_WORKSPACE/.ralph/gates/full-latest.cmd"
  printf '124'            >"$MOCK_WORKSPACE/.ralph/gates/full-latest.exit"
  ! _complete_allowed "$MOCK_WORKSPACE"
}

@test "_complete_allowed: pinned cmd mismatch → block even when green" {
  # The 0.6.4 spoof, generalized to v0.14.0: agent ran a cheap command
  # under label=full to satisfy a label-only guard. Caught by the cmd-match.
  mkdir -p "$MOCK_WORKSPACE/.ralph/gates"
  printf 'mock basic-check' >"$MOCK_WORKSPACE/.ralph/gates/full-latest.cmd"
  printf '0'                >"$MOCK_WORKSPACE/.ralph/gates/full-latest.exit"
  ! _complete_allowed "$MOCK_WORKSPACE"
}

@test "_complete_allowed: no full gate has run yet → block" {
  # 0.14.0 dropped the pre-0.6.4 fallback: no full-latest.cmd → not allowed.
  mkdir -p "$MOCK_WORKSPACE/.ralph/gates"
  ! _complete_allowed "$MOCK_WORKSPACE"
}

@test "_complete_allowed: missing [gates].full → block with clear reason" {
  # Belt-and-suspenders: even if validation fell through (e.g. policy edited
  # mid-run), the completion guard refuses without an explicit full tier.
  cat > "$MOCK_WORKSPACE/.ralph/command-policy" <<'EOF'
[gates]
basic | mock basic-check
final | mock verify:final
EOF
  mkdir -p "$MOCK_WORKSPACE/.ralph/gates"
  printf 'mock all-check' >"$MOCK_WORKSPACE/.ralph/gates/full-latest.cmd"
  printf '0'              >"$MOCK_WORKSPACE/.ralph/gates/full-latest.exit"
  ! _complete_allowed "$MOCK_WORKSPACE"
  [[ "$_COMPLETE_BLOCK_REASON" == *"[gates].full"* ]]
}

@test "_complete_allowed: [gates].full override is honored" {
  # Project ships a non-pnpm gate — completion bar follows whatever is
  # declared, no defaults.
  cat > "$MOCK_WORKSPACE/.ralph/command-policy" <<'EOF'
[gates]
basic | cargo test
full  | cargo test --release
final | cargo bench
EOF
  mkdir -p "$MOCK_WORKSPACE/.ralph/gates"
  printf 'cargo test --release' >"$MOCK_WORKSPACE/.ralph/gates/full-latest.cmd"
  printf '0'                    >"$MOCK_WORKSPACE/.ralph/gates/full-latest.exit"
  _complete_allowed "$MOCK_WORKSPACE"
}

# ---------------------------------------------------------------------------
# 0.14.3: eval-aware completion bar. The eval loop (RALPH_EVAL_LOOP=1) gates
# on `final`, not `full`. Regression guard: pre-0.14.3 the eval loop checked
# `full`, which it never runs and wipes at start → blocked forever (livelock).
# ---------------------------------------------------------------------------

@test "_complete_allowed: eval loop honors COMPLETE on green final gate with NO full gate (0.14.3 regression)" {
  # Exactly loop 150610's state: eval loop ran `final` (green), full-latest.*
  # absent (eval wipes .ralph/gates). Must be ALLOWED, not blocked.
  export RALPH_EVAL_LOOP=1
  mkdir -p "$MOCK_WORKSPACE/.ralph/gates"
  printf 'mock verify:final' >"$MOCK_WORKSPACE/.ralph/gates/final-latest.cmd"
  printf '0'                 >"$MOCK_WORKSPACE/.ralph/gates/final-latest.exit"
  # No full-latest.* on disk — the pre-fix bug blocked here.
  _complete_allowed "$MOCK_WORKSPACE"
}

@test "_complete_allowed: eval loop blocks on red final gate" {
  export RALPH_EVAL_LOOP=1
  mkdir -p "$MOCK_WORKSPACE/.ralph/gates"
  printf 'mock verify:final' >"$MOCK_WORKSPACE/.ralph/gates/final-latest.cmd"
  printf '1'                 >"$MOCK_WORKSPACE/.ralph/gates/final-latest.exit"
  ! _complete_allowed "$MOCK_WORKSPACE"
  [[ "$_COMPLETE_BLOCK_REASON" == *"final gate"* ]]
}

@test "_complete_allowed: eval loop blocks when final gate has not run yet" {
  export RALPH_EVAL_LOOP=1
  mkdir -p "$MOCK_WORKSPACE/.ralph/gates"
  ! _complete_allowed "$MOCK_WORKSPACE"
  [[ "$_COMPLETE_BLOCK_REASON" == *"final gate"* ]]
}

@test "_complete_allowed: eval loop blocks on relabeled cheap command under final" {
  # Spoof: ran the cheaper basic command but recorded it under final.
  export RALPH_EVAL_LOOP=1
  mkdir -p "$MOCK_WORKSPACE/.ralph/gates"
  printf 'mock basic-check' >"$MOCK_WORKSPACE/.ralph/gates/final-latest.cmd"
  printf '0'                >"$MOCK_WORKSPACE/.ralph/gates/final-latest.exit"
  ! _complete_allowed "$MOCK_WORKSPACE"
}

@test "_complete_allowed: impl loop still blocks when only a final gate exists" {
  # Inverse of the eval case: in impl context a green final gate must NOT
  # satisfy the bar — impl completion is keyed on `full`.
  mkdir -p "$MOCK_WORKSPACE/.ralph/gates"
  printf 'mock verify:final' >"$MOCK_WORKSPACE/.ralph/gates/final-latest.cmd"
  printf '0'                 >"$MOCK_WORKSPACE/.ralph/gates/final-latest.exit"
  ! _complete_allowed "$MOCK_WORKSPACE"
  [[ "$_COMPLETE_BLOCK_REASON" == *"full gate"* ]]
}

# ---------------------------------------------------------------------------
# 0.14.3: fail-loud on an unsatisfiable completion bar. _complete_block_escalates
# returns 0 (escalate) once the SAME block reason repeats to the threshold,
# 1 (keep looping) otherwise — so the loop fails loud instead of spinning to
# MAX_LOOPS, while a one-off block (or a changing reason) keeps looping.
# ---------------------------------------------------------------------------

@test "_complete_block_escalates: first identical block does not escalate, second does" {
  _COMPLETE_BLOCK_COUNT=0
  _LAST_COMPLETE_BLOCK_REASON=""
  run _complete_block_escalates "full gate has not run yet"
  [ "$status" -ne 0 ]   # 1st: keep looping
  # _complete_block_escalates mutates globals; `run` is a subshell, so call
  # directly to accumulate state for the threshold check.
  _complete_block_escalates "full gate has not run yet" || true   # count=1
  _complete_block_escalates "full gate has not run yet"           # count=2 → escalate (exit 0)
}

@test "_complete_block_escalates: a changing reason resets the streak" {
  _COMPLETE_BLOCK_COUNT=0
  _LAST_COMPLETE_BLOCK_REASON=""
  _complete_block_escalates "reason A" || true   # count=1
  ! _complete_block_escalates "reason B"         # different → count resets to 1, no escalate
  [ "$_COMPLETE_BLOCK_COUNT" -eq 1 ]
}

@test "_complete_block_escalates: threshold is configurable via RALPH_COMPLETE_BLOCK_THRESHOLD" {
  _COMPLETE_BLOCK_COUNT=0
  _LAST_COMPLETE_BLOCK_REASON=""
  RALPH_COMPLETE_BLOCK_THRESHOLD=1 _complete_block_escalates "boom"  # escalate on first
}

# ---------------------------------------------------------------------------
# 0.14.0: _load_gates_from_policy and _validate_gates_section
# ---------------------------------------------------------------------------

@test "_load_gates_from_policy: happy path — all three tiers populated" {
  local b f fi
  _load_gates_from_policy "$MOCK_WORKSPACE" b f fi
  [ "$b"  = "mock basic-check" ]
  [ "$f"  = "mock all-check" ]
  [ "$fi" = "mock verify:final" ]
}

@test "_load_gates_from_policy: missing file → all three empty" {
  rm -f "$MOCK_WORKSPACE/.ralph/command-policy"
  local b f fi
  _load_gates_from_policy "$MOCK_WORKSPACE" b f fi
  [ -z "$b" ]; [ -z "$f" ]; [ -z "$fi" ]
}

@test "_load_gates_from_policy: missing tier rows → that tier's slot empty" {
  cat > "$MOCK_WORKSPACE/.ralph/command-policy" <<'EOF'
[gates]
basic | only basic set
EOF
  local b f fi
  _load_gates_from_policy "$MOCK_WORKSPACE" b f fi
  [ "$b" = "only basic set" ]
  [ -z "$f" ]; [ -z "$fi" ]
}

@test "_load_gates_from_policy: whitespace tolerance around tier name and command" {
  cat > "$MOCK_WORKSPACE/.ralph/command-policy" <<'EOF'
[gates]
  basic   |    spaced basic
full|tight
   final |   spaced final
EOF
  local b f fi
  _load_gates_from_policy "$MOCK_WORKSPACE" b f fi
  [ "$b"  = "spaced basic" ]
  [ "$f"  = "tight" ]
  [ "$fi" = "spaced final" ]
}

@test "_load_gates_from_policy: subsequent section header ends the [gates] scope" {
  cat > "$MOCK_WORKSPACE/.ralph/command-policy" <<'EOF'
[gates]
basic | from gates
[wrap]
basic | this should not become [gates].basic
EOF
  local b f fi
  _load_gates_from_policy "$MOCK_WORKSPACE" b f fi
  [ "$b" = "from gates" ]
}

@test "_validate_gates_section: complete [gates] → returns 0 silently" {
  run _validate_gates_section "$MOCK_WORKSPACE"
  [ "$status" -eq 0 ]
}

@test "_validate_gates_section: missing tier → returns non-zero with named tier" {
  cat > "$MOCK_WORKSPACE/.ralph/command-policy" <<'EOF'
[gates]
basic | only basic
EOF
  run _validate_gates_section "$MOCK_WORKSPACE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"full"* ]]
  [[ "$output" == *"final"* ]]
  # Errors log got an entry.
  grep -q "incomplete \[gates\]" "$MOCK_WORKSPACE/.ralph/errors.log"
}

@test "_validate_gates_section: missing file → returns non-zero" {
  rm -f "$MOCK_WORKSPACE/.ralph/command-policy"
  run _validate_gates_section "$MOCK_WORKSPACE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"basic"* ]]
  [[ "$output" == *"full"* ]]
  [[ "$output" == *"final"* ]]
}

@test "_validate_gates_section: empty tier value → counts as missing" {
  cat > "$MOCK_WORKSPACE/.ralph/command-policy" <<'EOF'
[gates]
basic |
full  | mock all-check
final | mock final
EOF
  run _validate_gates_section "$MOCK_WORKSPACE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"basic"* ]]
}

# ---------------------------------------------------------------------------
# Heartbeat contract (0.4.0)
# ---------------------------------------------------------------------------

@test "stream-parser emits HEARTBEAT on activity (0.4.0)" {
  # The main loop's read-timer reset depends on this. Per-path emission
  # tests live in stream-parser.bats — this is the cross-module contract.
  local tmp
  tmp=$(mktemp -d "$BATS_TMPDIR/heartbeat.XXXXXX")
  mkdir -p "$tmp/.ralph"
  local out
  out=$(printf '{"kind":"tool_result","name":"Read","bytes":100,"lines":5,"path":"/tmp/x"}\n' \
    | bash "$SCRIPTS_DIR/stream-parser.sh" "$tmp" 1)
  echo "$out" | grep -q "^HEARTBEAT$"
  rm -rf "$tmp"
}

@test "check_task_complete: honors RALPH_TASK_FILE pointing at an acceptance report (0.5.0)" {
  # Simulate the eval loop's handoff: RALPH_TASK_FILE points at the
  # acceptance report; the counter must use that file, not PROMPT.md.
  mkdir -p "$MOCK_WORKSPACE/.ralph"
  cat > "$MOCK_WORKSPACE/.ralph/acceptance-report.md" <<'REPORT'
# Acceptance Report

- [ ] All acceptance criteria met and verified

**Status:** UNVERIFIED

## Gaps

- [ ] gap one
- [ ] gap two
REPORT

  # Also write a PROMPT.md with fully-checked tasks to make sure the
  # counter doesn't fall back to it.
  cat > "$MOCK_WORKSPACE/PROMPT.md" <<'PROMPT'
- [x] a
- [x] b
PROMPT

  export RALPH_TASK_FILE="$MOCK_WORKSPACE/.ralph/acceptance-report.md"
  local status
  status=$(check_task_complete "$MOCK_WORKSPACE")
  # Three unchecked boxes in the report → INCOMPLETE, not COMPLETE.
  [[ "$status" == INCOMPLETE:* ]]
  unset RALPH_TASK_FILE
}

@test "check_task_complete: flips to COMPLETE when every report checkbox is [x] (0.5.0)" {
  mkdir -p "$MOCK_WORKSPACE/.ralph"
  cat > "$MOCK_WORKSPACE/.ralph/acceptance-report.md" <<'REPORT'
# Acceptance Report

- [x] All acceptance criteria met and verified

**Status:** CLEAN

## Gaps

- [x] gap one
- [x] gap two
REPORT

  export RALPH_TASK_FILE="$MOCK_WORKSPACE/.ralph/acceptance-report.md"
  local status
  status=$(check_task_complete "$MOCK_WORKSPACE")
  [ "$status" = "COMPLETE" ]
  unset RALPH_TASK_FILE
}

@test "_resolve_task_file: breadcrumb wins over PROMPT.md (0.5.0)" {
  # This covers the eval loop's handoff AND the new PROMPT.md-mode
  # breadcrumb. If both are present, the breadcrumb is authoritative.
  mkdir -p "$MOCK_WORKSPACE/.ralph"
  echo "$MOCK_WORKSPACE/.ralph/acceptance-report.md" > "$MOCK_WORKSPACE/.ralph/task-file-path"
  echo "- [ ] placeholder" > "$MOCK_WORKSPACE/.ralph/acceptance-report.md"
  echo "- [ ] decoy" > "$MOCK_WORKSPACE/PROMPT.md"

  local got
  got=$(_resolve_task_file "$MOCK_WORKSPACE")
  [ "$got" = "$MOCK_WORKSPACE/.ralph/acceptance-report.md" ]
}

# -----------------------------------------------------------------------------
# Loop ceiling configuration (MAX_LOOPS)
#
# The driver tracks loop count via `loop_n`. MAX_LOOPS is the upper-bound
# safety cap on respawns (default 10). 0.12.5 dropped the pre-0.6.3
# deprecated `MAX_ITERATIONS` / `RALPH_MAX_ITERATIONS` / `--iterations`
# aliases after verifying zero usage in consuming projects.
# -----------------------------------------------------------------------------

@test "MAX_LOOPS env var sets the loop ceiling (0.6.3)" {
  (
    unset MAX_LOOPS RALPH_MAX_LOOPS
    export MAX_LOOPS=42
    # shellcheck disable=SC1090
    source "$SCRIPTS_DIR/ralph-common.sh"
    [ "$MAX_LOOPS" = "42" ]
  )
}

@test "RALPH_MAX_LOOPS is honored as a fallback (0.6.3)" {
  (
    unset MAX_LOOPS RALPH_MAX_LOOPS
    export RALPH_MAX_LOOPS=17
    # shellcheck disable=SC1090
    source "$SCRIPTS_DIR/ralph-common.sh"
    [ "$MAX_LOOPS" = "17" ]
  )
}

@test "deprecated MAX_ITERATIONS env var is NO LONGER honored (0.12.5)" {
  # 0.12.5 dropped the alias after verifying zero external usage.
  (
    unset MAX_LOOPS RALPH_MAX_LOOPS
    export MAX_ITERATIONS=11
    # shellcheck disable=SC1090
    source "$SCRIPTS_DIR/ralph-common.sh"
    # MAX_LOOPS should fall through to the default 10, NOT pick up 11.
    [ "$MAX_LOOPS" = "10" ]
  )
}

@test "MAX_LOOPS default is 10 when no env var is set (0.6.4)" {
  # 0.6.3 default was 20 (carryover from per-task iteration era). 0.6.4
  # lowers to 10 because under the flow framing one loop should chew
  # through most/all of a spec — double-digit respawns is a smell, not
  # steady state. Stall thresholds catch genuine stuckness well before 10.
  (
    unset MAX_LOOPS RALPH_MAX_LOOPS
    # shellcheck disable=SC1090
    source "$SCRIPTS_DIR/ralph-common.sh"
    [ "$MAX_LOOPS" = "10" ]
  )
}

@test "build_prompt framing names all four stop conditions" {
  # The four canonical stop conditions must all appear by name.
  # Removing any of them silently regresses graceful-yield behavior.
  local output
  output=$(build_prompt "$MOCK_WORKSPACE" 1)
  echo "$output" | grep -q "ALL_TASKS_DONE"
  echo "$output" | grep -q "GUTTER"
  echo "$output" | grep -q "context-warning-active"
  echo "$output" | grep -q "stop-requested"
}

# =============================================================================
# agent_build_cmd — ANTHROPIC env-var stripping (0.8.2)
# =============================================================================

@test "agent_build_cmd unsets ANTHROPIC_API_KEY and ANTHROPIC_BASE_URL for claude" {
  local cmd
  cmd=$(agent_build_cmd claude "sonnet" "hello")
  # Both vars must be unset before the claude invocation so that Claude
  # Desktop's empty placeholders do not force API-key auth mode.
  echo "$cmd" | grep -q "unset ANTHROPIC_API_KEY ANTHROPIC_BASE_URL"
}

@test "agent_build_cmd does NOT unset ANTHROPIC vars for cursor-agent" {
  local cmd
  cmd=$(agent_build_cmd cursor-agent "composer-2" "hello")
  # cursor-agent uses its own auth; don't touch ANTHROPIC vars.
  ! echo "$cmd" | grep -q "unset ANTHROPIC"
}

# =============================================================================
# Reasoning effort — default + RALPH_EFFORT passthrough (0.15.0)
# =============================================================================

@test "agent_default_effort defaults to xhigh for claude" {
  [ "$(agent_default_effort claude)" = "xhigh" ]
}

@test "agent_default_effort is empty for cursor-agent (no effort knob)" {
  [ -z "$(agent_default_effort cursor-agent)" ]
}

@test "agent_build_cmd defaults claude to --effort xhigh" {
  local cmd
  cmd=$(agent_build_cmd claude "sonnet" "hello")
  echo "$cmd" | grep -q -- "--effort 'xhigh'"
}

@test "agent_build_cmd honors RALPH_EFFORT override for claude" {
  local cmd
  RALPH_EFFORT=max \
    cmd=$(agent_build_cmd claude "sonnet" "hello")
  echo "$cmd" | grep -q -- "--effort 'max'"
  # The default must not leak through when an override is set.
  ! echo "$cmd" | grep -q -- "--effort 'xhigh'"
}

@test "agent_build_cmd's --effort appears before --model for claude" {
  local cmd effort_pos model_pos
  cmd=$(agent_build_cmd claude "sonnet" "hello")
  effort_pos=$(echo "$cmd" | grep -bo -- "--effort" | head -1 | cut -d: -f1)
  model_pos=$(echo "$cmd" | grep -bo -- "--model" | head -1 | cut -d: -f1)
  [ "$effort_pos" -lt "$model_pos" ]
}

@test "agent_build_cmd emits no --effort flag for cursor-agent" {
  local cmd
  # cursor-agent has no --effort knob; even with RALPH_EFFORT set the flag
  # must be omitted so the invocation stays valid.
  RALPH_EFFORT=max \
    cmd=$(agent_build_cmd cursor-agent "composer-2" "hello")
  ! echo "$cmd" | grep -q -- "--effort"
}

# =============================================================================
# agent_build_cmd — plugin-dir self-registration (0.12.4)
# =============================================================================
# Critical bug fix: prior to 0.12.4, agent_build_cmd launched `claude -p`
# without `--plugin-dir` for this plugin, so our PreToolUse hook never
# registered and the entire guard/wrap/deny machinery was dead code in
# production. These tests pin the regression closed.

@test "agent_build_cmd adds --plugin-dir for ralph-wiggum-plugin (0.12.4)" {
  local cmd
  cmd=$(agent_build_cmd claude "sonnet" "hello")
  # The plugin root must appear as a --plugin-dir arg so `claude -p`
  # loads our hooks.json. Without this, [wrap]/[deny]/[rewrite]/[protect]
  # are all silently no-ops.
  echo "$cmd" | grep -q -- "--plugin-dir '[^']*ralph-wiggum-plugin[^']*'"
}

@test "agent_build_cmd's --plugin-dir appears before --resume (0.12.4)" {
  local cmd
  cmd=$(agent_build_cmd claude "sonnet" "hello" "session-abc")
  # Argument ordering: --plugin-dir must come before --resume so claude
  # parses them in the expected order (matches the in-code order).
  local plugin_pos resume_pos
  plugin_pos=$(echo "$cmd" | grep -bo -- "--plugin-dir" | head -1 | cut -d: -f1)
  resume_pos=$(echo "$cmd" | grep -bo -- "--resume" | head -1 | cut -d: -f1)
  [ "$plugin_pos" -lt "$resume_pos" ]
}

@test "agent_build_cmd's plugin-dir still works with RALPH_EXTRA_PLUGIN_DIRS (0.12.4)" {
  local cmd
  RALPH_EXTRA_PLUGIN_DIRS="/tmp/extra1:/tmp/extra2" \
    cmd=$(agent_build_cmd claude "sonnet" "hello")
  # All three plugin-dirs must be present: ours + the two extras.
  local count
  count=$(echo "$cmd" | grep -o -- "--plugin-dir" | wc -l | tr -d ' ')
  [ "$count" = "3" ]
}

# =============================================================================
# _auto_enrich_handoff — mechanical state appending (0.12.4)
# =============================================================================
# Closes the gap where the agent gets force-killed before writing its
# Working set, leaving the next session blind. We extract last commit,
# last [x] task, and next unchecked task from git+tasks.md so even on
# force-kill the handoff has carry-over context.

@test "_auto_enrich_handoff: appends last commit, last done, next unchecked (0.12.4)" {
  create_mock_spec "test-spec"
  # Mark one task done, leave another unchecked.
  cat > "$MOCK_SPEC_DIR/tasks.md" <<'TASKS'
# Tasks
- [x] T001 First task done
- [ ] T002 Second task pending
TASKS
  (cd "$MOCK_WORKSPACE" && git add specs/ && git commit -q -m "feat(scope): T001 first task complete")
  echo "$MOCK_SPEC_DIR/tasks.md" > "$MOCK_WORKSPACE/.ralph/task-file-path"
  # Pre-existing minimal handoff.
  echo "## Existing content" > "$MOCK_WORKSPACE/.ralph/handoff.md"

  _auto_enrich_handoff "$MOCK_WORKSPACE"

  grep -q "## Auto-enriched state" "$MOCK_WORKSPACE/.ralph/handoff.md"
  grep -qE 'Last commit.*T001 first task complete' "$MOCK_WORKSPACE/.ralph/handoff.md"
  grep -qE 'Last task done.*T001' "$MOCK_WORKSPACE/.ralph/handoff.md"
  grep -qE 'Next unchecked.*T002' "$MOCK_WORKSPACE/.ralph/handoff.md"
  # Existing content must be preserved.
  grep -q "## Existing content" "$MOCK_WORKSPACE/.ralph/handoff.md"
}

@test "_auto_enrich_handoff: idempotent — replaces existing section (0.12.4)" {
  create_mock_spec "test-spec"
  cat > "$MOCK_SPEC_DIR/tasks.md" <<'TASKS'
- [x] T010 Old finished task
- [ ] T011 Next
TASKS
  (cd "$MOCK_WORKSPACE" && git add specs/ && git commit -q -m "feat: T010 done")
  echo "$MOCK_SPEC_DIR/tasks.md" > "$MOCK_WORKSPACE/.ralph/task-file-path"
  echo "## Existing" > "$MOCK_WORKSPACE/.ralph/handoff.md"

  # First enrich.
  _auto_enrich_handoff "$MOCK_WORKSPACE"
  # Now mark T011 done, add T012 unchecked.
  cat > "$MOCK_SPEC_DIR/tasks.md" <<'TASKS'
- [x] T010 Old finished task
- [x] T011 Now done too
- [ ] T012 Newest pending
TASKS
  (cd "$MOCK_WORKSPACE" && git add specs/ && git commit -q -m "feat: T011 done")
  # Second enrich — must REPLACE, not duplicate.
  _auto_enrich_handoff "$MOCK_WORKSPACE"

  local section_count
  section_count=$(grep -c "^## Auto-enriched state" "$MOCK_WORKSPACE/.ralph/handoff.md")
  [ "$section_count" = "1" ]
  grep -qE 'Last task done.*T011' "$MOCK_WORKSPACE/.ralph/handoff.md"
  grep -qE 'Next unchecked.*T012' "$MOCK_WORKSPACE/.ralph/handoff.md"
  # T010 must NOT appear in the freshly-replaced section.
  ! grep -qE 'Last task done.*T010' "$MOCK_WORKSPACE/.ralph/handoff.md"
}

@test "_auto_enrich_handoff: no-op when no commits and no tasks (0.12.4)" {
  # Fresh workspace: only the init commit, no task file resolvable.
  echo "## Pristine" > "$MOCK_WORKSPACE/.ralph/handoff.md"
  _auto_enrich_handoff "$MOCK_WORKSPACE"
  # The init commit IS a commit, so the section may appear with just Last commit.
  # We just verify the function doesn't error or destroy existing content.
  grep -q "## Pristine" "$MOCK_WORKSPACE/.ralph/handoff.md"
}

# =============================================================================
# _detect_graceful_yield (0.12.5)
# =============================================================================
# A graceful yield = agent saw a breadcrumb, wrote handoff.md during this
# iteration, and ended cleanly. Detection compares handoff.md's mtime
# against .ralph/.loop-start-ts touched at iteration start.

@test "_detect_graceful_yield: returns 0 when handoff is newer than loop-baseline-head (0.12.5)" {
  touch -t 202601010000 "$MOCK_WORKSPACE/.ralph/loop-baseline-head"
  echo "## Working set" > "$MOCK_WORKSPACE/.ralph/handoff.md"  # newer than the touch above
  _detect_graceful_yield "$MOCK_WORKSPACE"
}

@test "_detect_graceful_yield: returns 1 when handoff is older than loop-baseline-head (0.12.5)" {
  echo "## Working set" > "$MOCK_WORKSPACE/.ralph/handoff.md"
  sleep 1
  touch "$MOCK_WORKSPACE/.ralph/loop-baseline-head"
  ! _detect_graceful_yield "$MOCK_WORKSPACE"
}

@test "_detect_graceful_yield: returns 1 when handoff.md is absent (0.12.5)" {
  touch "$MOCK_WORKSPACE/.ralph/loop-baseline-head"
  rm -f "$MOCK_WORKSPACE/.ralph/handoff.md"
  ! _detect_graceful_yield "$MOCK_WORKSPACE"
}

@test "_detect_graceful_yield: returns 1 when loop-baseline-head is absent (0.12.5)" {
  rm -f "$MOCK_WORKSPACE/.ralph/loop-baseline-head"
  echo "x" > "$MOCK_WORKSPACE/.ralph/handoff.md"
  ! _detect_graceful_yield "$MOCK_WORKSPACE"
}

# =============================================================================
# hooks.json schema validation (0.12.5)
# =============================================================================
# Critical bug closed in 0.12.5: Claude Code expects `hooks` to be a
# record keyed by event name, not an array. Our pre-0.12.5 schema:
#     { "hooks": [ { "type": "PreToolUse", "matcher": "Bash", ... }, ... ] }
# silently failed to load with error "expected: record, received: array".
# Empirically verified by triggering a state-tampering rm: pre-fix the
# command ran, post-fix Claude Code returned permissionDecision=deny
# from our _block(). These tests pin the regression closed.

@test "hooks.json: hooks field is a record/object (0.12.5)" {
  local manifest="$PLUGIN_ROOT/hooks/hooks.json"
  [ -f "$manifest" ]
  # `jq` reports the type of .hooks. Must be "object", not "array".
  local hook_type
  hook_type=$(jq -r '.hooks | type' "$manifest")
  [ "$hook_type" = "object" ]
}

@test "hooks.json: each event maps to an array of matcher-groups (0.12.5)" {
  local manifest="$PLUGIN_ROOT/hooks/hooks.json"
  # PreToolUse and Stop must both be arrays.
  jq -e '.hooks.PreToolUse | type == "array"' "$manifest" >/dev/null
  jq -e '.hooks.Stop | type == "array"' "$manifest" >/dev/null
}

@test "hooks.json: every hook entry has type=\"command\" (0.12.5)" {
  local manifest="$PLUGIN_ROOT/hooks/hooks.json"
  # All inner hooks must declare type=command (the previous schema omitted
  # this field, which contributed to the load failure).
  local missing
  missing=$(jq '[.hooks[] | .[] | .hooks[] | select(.type != "command")] | length' "$manifest")
  [ "$missing" = "0" ]
}

# =============================================================================
# stop-requested vs --evaluate chain interaction (0.12.5)
# =============================================================================
# Bug: stop-requested honor in run_ralph_loop returned 0, which the
# chain-evaluate guard at ralph-setup.sh:525 read as "clean ALL_TASKS_DONE
# completion → proceed to acceptance evaluation". Operator intent for
# stop-requested is "halt for intervention", not "ready for verification".
# Fix: write `.ralph/.loop-stopped-by-user` breadcrumb on honor; the
# chain-evaluate guard reads + clears it before deciding to chain.

@test "stop-requested honor writes .loop-stopped-by-user breadcrumb (0.12.5)" {
  # Source ralph-common.sh and inspect the honor code path. The full
  # run_ralph_loop is too heavy to exercise end-to-end here, so we
  # exercise the breadcrumb invariant directly: the honor block touches
  # the file before returning.
  grep -q "touch.*\.loop-stopped-by-user" "$SCRIPTS_DIR/ralph-common.sh"
}

@test "ralph-setup chain-evaluate guard reads and clears .loop-stopped-by-user (0.12.5)" {
  # The setup script must (a) check the breadcrumb BEFORE the chain
  # check, (b) clear it on exit so a subsequent ralph run doesn't see
  # a stale signal.
  grep -q '\.loop-stopped-by-user' "$SCRIPTS_DIR/ralph-setup.sh"
  grep -q 'rm.*\.loop-stopped-by-user' "$SCRIPTS_DIR/ralph-setup.sh"
  # The breadcrumb check must precede the chain-evaluate decision so
  # the early exit fires before the eval chain. The decision is the
  # `if [[ "$main_rc" -eq 0 ]] && [[ "$CHAIN_EVALUATE" == "true" ]]`
  # block — find its line number and confirm the breadcrumb check is
  # above it.
  local stopped_line decision_line
  stopped_line=$(grep -n 'if \[\[ -f.*\.loop-stopped-by-user' "$SCRIPTS_DIR/ralph-setup.sh" | head -1 | cut -d: -f1)
  decision_line=$(grep -n 'main_rc.*-eq 0.*CHAIN_EVALUATE.*true' "$SCRIPTS_DIR/ralph-setup.sh" | head -1 | cut -d: -f1)
  [ -n "$stopped_line" ]
  [ -n "$decision_line" ]
  [ "$stopped_line" -lt "$decision_line" ]
}

@test "_auto_enrich_handoff: creates handoff.md if absent (0.12.4)" {
  create_mock_spec "test-spec"
  cat > "$MOCK_SPEC_DIR/tasks.md" <<'TASKS'
- [x] T020 Done
- [ ] T021 Pending
TASKS
  (cd "$MOCK_WORKSPACE" && git add specs/ && git commit -q -m "feat: T020 done")
  echo "$MOCK_SPEC_DIR/tasks.md" > "$MOCK_WORKSPACE/.ralph/task-file-path"
  rm -f "$MOCK_WORKSPACE/.ralph/handoff.md"

  _auto_enrich_handoff "$MOCK_WORKSPACE"

  [ -f "$MOCK_WORKSPACE/.ralph/handoff.md" ]
  grep -q "## Auto-enriched state" "$MOCK_WORKSPACE/.ralph/handoff.md"
}

# =============================================================================
# rotate/warn thresholds — 0.12.2 bump
# =============================================================================

@test "200K-model rotate threshold is 170000 (0.12.2)" {
  local threshold
  threshold=$(agent_default_rotate_threshold claude "opus")
  [ "$threshold" = "170000" ]
}

@test "200K-model warn threshold is 148750 (0.12.2)" {
  local threshold
  threshold=$(agent_default_warn_threshold claude "opus")
  [ "$threshold" = "148750" ]
}

@test "1M-model rotate threshold is unchanged at 700000" {
  local threshold
  threshold=$(agent_default_rotate_threshold claude "opus[1m]")
  [ "$threshold" = "700000" ]
}

# =============================================================================
# _check_orphaned_gates — 0.14.7 loop-boundary orphaned-gate detection
# =============================================================================

@test "_check_orphaned_gates: dead-holder lock logs GATE ORPHANED and releases lock (0.14.7)" {
  local lock_dir="$MOCK_WORKSPACE/.ralph/gates/.full.lock"
  mkdir -p "$lock_dir"
  # Spawn-and-reap a process so the PID is verifiably dead.
  sleep 0.01 &
  local dead_pid=$!
  wait "$dead_pid"
  echo "$dead_pid" > "$lock_dir/pid"

  _check_orphaned_gates "$MOCK_WORKSPACE"

  grep -q "GATE ORPHANED label=full" "$MOCK_WORKSPACE/.ralph/activity.log"
  [ ! -d "$lock_dir" ]
}

@test "_check_orphaned_gates: alive-holder lock is left untouched (0.14.7)" {
  local lock_dir="$MOCK_WORKSPACE/.ralph/gates/.basic.lock"
  mkdir -p "$lock_dir"
  # Our own PID is alive for the duration of the test.
  echo "$$" > "$lock_dir/pid"

  _check_orphaned_gates "$MOCK_WORKSPACE"

  if grep -q "GATE ORPHANED" "$MOCK_WORKSPACE/.ralph/activity.log" 2>/dev/null; then
    fail "GATE ORPHANED logged for an alive holder"
  fi
  [ -d "$lock_dir" ]
  rm -rf "$lock_dir"
}

@test "_check_orphaned_gates: lock without pid file is left untouched (0.14.7)" {
  # Pre-0.12.5 locks have no pid file — ownership is unverifiable, so the
  # loop-boundary sweep must not guess; the time-based steal in gate-run.sh
  # handles those.
  local lock_dir="$MOCK_WORKSPACE/.ralph/gates/.final.lock"
  mkdir -p "$lock_dir"

  _check_orphaned_gates "$MOCK_WORKSPACE"

  if grep -q "GATE ORPHANED" "$MOCK_WORKSPACE/.ralph/activity.log" 2>/dev/null; then
    fail "GATE ORPHANED logged for a pid-less lock"
  fi
  [ -d "$lock_dir" ]
  rm -rf "$lock_dir"
}

@test "_check_orphaned_gates: no gates dir is a no-op (0.14.7)" {
  rm -rf "$MOCK_WORKSPACE/.ralph/gates"
  _check_orphaned_gates "$MOCK_WORKSPACE"
}

# --- _is_zero_progress_bail — natural-end stall accounting (0.15.4) ---

@test "_is_zero_progress_bail: zero task delta + unchanged HEAD → bail (0.15.4)" {
  # No checkbox flipped and no commit: a genuine silent bail.
  _is_zero_progress_bail 0 abc123 abc123
}

@test "_is_zero_progress_bail: zero task delta + new commit → NOT a bail (0.15.4)" {
  # Committed a fix this loop (HEAD advanced) even though no box flipped —
  # e.g. an eval loop whose validating heavy gate is still backgrounded.
  run _is_zero_progress_bail 0 abc123 def456
  [ "$status" -eq 1 ]
}

@test "_is_zero_progress_bail: positive task delta → NOT a bail (0.15.4)" {
  run _is_zero_progress_bail 2 abc123 abc123
  [ "$status" -eq 1 ]
}

@test "_is_zero_progress_bail: git unavailable (empty heads) falls back to task delta (0.15.4)" {
  # Non-git workspace: preserve pre-0.15.4 behavior — zero delta is a bail...
  _is_zero_progress_bail 0 "" ""
  # ...and any positive delta is not.
  run _is_zero_progress_bail 1 "" ""
  [ "$status" -eq 1 ]
}
