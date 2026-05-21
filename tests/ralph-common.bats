#!/usr/bin/env bats
# Behavioral tests for ralph-common.sh build_prompt() framing.
#
# Verifies the trimmed framing prompt contains required sections
# and does NOT contain removed sections.

load test_helper

setup() {
  create_mock_workspace

  # Source ralph-common.sh (requires agent-adapter.sh first)
  source "$SCRIPTS_DIR/agent-adapter.sh"
  source "$SCRIPTS_DIR/ralph-common.sh"

  # Create minimal state files that build_prompt expects
  echo "# Guardrails" > "$MOCK_WORKSPACE/.ralph/guardrails.md"
  echo "# Errors" > "$MOCK_WORKSPACE/.ralph/errors.log"

  # Write a mock effective prompt
  mkdir -p "$MOCK_WORKSPACE/.ralph"
  echo "Mock task body" > "$MOCK_WORKSPACE/.ralph/effective-prompt.md"
}

teardown() {
  rm -rf "$MOCK_WORKSPACE"
}

@test "build_prompt framing is under 90 lines (excluding user body)" {
  local output
  output=$(build_prompt "$MOCK_WORKSPACE" 1)

  # Count lines before the user body marker "## Task Execution"
  local framing_lines
  framing_lines=$(echo "$output" | sed '/^## Task Execution$/,$d' | wc -l | tr -d ' ')

  # Framing should be concise. History:
  #   0.3.3 added Completion Bar          (cap was 35)
  #   0.3.6 added Gate Runner section     (cap bumped to 55)
  #   0.6.3 expanded the Stop conditions  (cap bumped to 70)
  #   0.12.0 added Handoff + Gate Selection blocks (cap bumped to 90)
  # The Gate Runner block only renders when gate-run.sh exists next to
  # ralph-common.sh (it does in-tree). If it ever needs to grow further,
  # update this cap AND AGENTS.md §Prompt Architecture in the same commit.
  [ "$framing_lines" -le 90 ]
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
  # under the normal test setup. This was the 0.3.6 fix for agents who ran
  # bare commands and re-ran on every failure instead of reading the log.
  local output
  output=$(build_prompt "$MOCK_WORKSPACE" 1)

  echo "$output" | grep -q "## Gate Runner"
  # 0.6.3: load-bearing pieces of the new (less prescriptive) protocol.
  # The "do NOT re-run" recipe was replaced by an "understand why, then
  # act" framing — same intent (don't reflexively retry), more latitude
  # for the agent to inspect screenshots / curl / lsof / config as the
  # situation demands.
  echo "$output" | grep -q "Never pipe"
  echo "$output" | grep -qE "\.ralph/gates/<label>-latest\.log"
  echo "$output" | grep -qE "understand why"
  # Points at --help so agents can self-discover the full surface:
  echo "$output" | grep -q -- "--help"
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

@test "build_prompt does NOT include removed verbose sections" {
  local output
  output=$(build_prompt "$MOCK_WORKSPACE" 1)

  # These were in the old 85-line framing but are now removed
  ! echo "$output" | grep -qi "naming hygiene"
  ! echo "$output" | grep -qi "gate invocation contract"
  ! echo "$output" | grep -qi "Learning from Failures"
  ! echo "$output" | grep -qi "Context Rotation Warning"
  ! echo "$output" | grep -qi "Sign:"
}

@test "build_prompt includes loop number" {
  local output
  output=$(build_prompt "$MOCK_WORKSPACE" 7)

  echo "$output" | grep -q "Loop 7"
}

@test "build_prompt includes user body from effective prompt" {
  local output
  output=$(build_prompt "$MOCK_WORKSPACE" 1)

  echo "$output" | grep -q "Mock task body"
}

@test "build_prompt uses normal template (0.10.0)" {
  local output
  output=$(build_prompt "$MOCK_WORKSPACE" 1)

  echo "$output" | grep -q "^## Completion$"
  echo "$output" | grep -q "^## State Files"
  echo "$output" | grep -q "^## Stop conditions"
  echo "$output" | grep -q "^## Git hygiene"
  echo "$output" | grep -q "Mock task body"
}

# --- 0.12.0: handoff injection + Gate Selection block ---

@test "build_prompt injects handoff block when handoff.md exists (0.12.0)" {
  cat > "$MOCK_WORKSPACE/.ralph/handoff.md" <<'HOFF'
# Loop Handoff

## Last gate state

label: basic
exit: 1
failures:
1:src/foo.spec.ts > assertion failed

## Working set

Active task: T031 — wire up X.
HOFF
  local output
  output=$(build_prompt "$MOCK_WORKSPACE" 1)
  echo "$output" | grep -q "^## Handoff from previous loop$"
  echo "$output" | grep -q "## Last gate state"
  echo "$output" | grep -q "Active task: T031"
  echo "$output" | grep -q "src/foo.spec.ts"
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
  # Default gate guidance is the only load-bearing thing here.
  echo "$output" | grep -q "pnpm basic-check"
  echo "$output" | grep -q "\[risky\]"
}

@test "build_prompt does NOT include removed troubleshoot overlay (0.12.0)" {
  # 0.12.0 sunset _RALPH_OVERLAY_TROUBLESHOOT. Setting the env var must be
  # a no-op now — failures are surfaced via the inlined handoff block.
  export _RALPH_OVERLAY_TROUBLESHOOT=1
  export _RALPH_FAILING_GATE_LABEL=basic
  local output
  output=$(build_prompt "$MOCK_WORKSPACE" 1)
  unset _RALPH_OVERLAY_TROUBLESHOOT
  unset _RALPH_FAILING_GATE_LABEL
  # The overlay sentence ("Test failure recovery") from the old template
  # must not appear, and no {{FAILING_LABEL}} placeholder either.
  ! echo "$output" | grep -qi "consecutive gate failures"
  ! echo "$output" | grep -q "FAILING_LABEL"
}

@test "init_ralph_dir seeds handoff.md skeleton on first init (0.12.0)" {
  local fresh
  fresh=$(mktemp -d "$BATS_TMPDIR/rb-init.XXXXXX")
  init_ralph_dir "$fresh"
  [ -f "$fresh/.ralph/handoff.md" ]
  grep -q "## Last gate state" "$fresh/.ralph/handoff.md"
  grep -q "## Working set" "$fresh/.ralph/handoff.md"
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

# ---------------------------------------------------------------------------
# _classify_heartbeat_exit — heartbeat loop exit classifier (0.3.1+)
# ---------------------------------------------------------------------------

@test "_classify_heartbeat_exit: non-empty signal always wins" {
  # Even if read returned a timeout or EOF, a caller-set signal is
  # authoritative — honour it.
  [ "$(_classify_heartbeat_exit 0 COMPLETE)" = "signalled" ]
  [ "$(_classify_heartbeat_exit 1 ROTATE)" = "signalled" ]
  [ "$(_classify_heartbeat_exit 142 DEFER)" = "signalled" ]
}

@test "_classify_heartbeat_exit: rc>128 with empty signal → timeout" {
  # read -t returns 128+signal-number on timeout; bash typically uses
  # SIGALRM-ish values in the 129..142 range.
  [ "$(_classify_heartbeat_exit 142 '')" = "timeout" ]
  [ "$(_classify_heartbeat_exit 129 '')" = "timeout" ]
}

@test "_classify_heartbeat_exit: rc=1 with empty signal → eof (0.3.2)" {
  # EOF on the FIFO. Caller must probe liveness to decide between a
  # clean natural end and a wedged-agent hang.
  [ "$(_classify_heartbeat_exit 1 '')" = "eof" ]
}

@test "_classify_heartbeat_exit: rc=0 with empty signal → eof (0.3.2)" {
  [ "$(_classify_heartbeat_exit 0 '')" = "eof" ]
}

# ---------------------------------------------------------------------------
# _probe_agent_liveness — post-EOF agent-pid probe (0.3.2)
# ---------------------------------------------------------------------------

@test "_probe_agent_liveness: dead pid → clean (0.3.2)" {
  # Spawn then reap a trivial subshell so the pid is guaranteed dead
  # by the time we probe.
  ( sleep 0 ) &
  local pid=$!
  wait "$pid" 2>/dev/null || true
  [ "$(_probe_agent_liveness "$pid" 1)" = "clean" ]
}

@test "_probe_agent_liveness: quickly-exiting pid → clean within grace (0.3.2)" {
  # Agent exits 1s into a 5s grace window — should return "clean"
  # without running the full grace duration.
  ( sleep 1 ) &
  local pid=$!
  local start=$SECONDS
  local result
  result=$(_probe_agent_liveness "$pid" 5)
  local elapsed=$((SECONDS - start))
  wait "$pid" 2>/dev/null || true
  [ "$result" = "clean" ]
  # Must not have waited the full 5s
  [ "$elapsed" -lt 4 ]
}

@test "_probe_agent_liveness: long-running pid → hang (0.3.2)" {
  # Agent still alive after the grace window — should return "hang".
  ( sleep 10 ) &
  local pid=$!
  local result
  result=$(_probe_agent_liveness "$pid" 1)
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  [ "$result" = "hang" ]
}

# ---------------------------------------------------------------------------
# Completion Bar guard — refuse COMPLETE when a gate is red (0.3.3)
# ---------------------------------------------------------------------------

@test "_most_recent_gate_exit: no gates dir → empty (0.3.3)" {
  rm -rf "$MOCK_WORKSPACE/.ralph/gates"
  [ -z "$(_most_recent_gate_exit "$MOCK_WORKSPACE")" ]
}

@test "_most_recent_gate_exit: no *-latest.exit files → empty (0.3.3)" {
  # gates dir exists but no breadcrumbs yet (older plugin, or no runs)
  mkdir -p "$MOCK_WORKSPACE/.ralph/gates"
  [ -z "$(_most_recent_gate_exit "$MOCK_WORKSPACE")" ]
}

@test "_most_recent_gate_exit: returns the most-recently-written breadcrumb (0.3.3)" {
  mkdir -p "$MOCK_WORKSPACE/.ralph/gates"
  printf '1'  >"$MOCK_WORKSPACE/.ralph/gates/basic-latest.exit"
  # Space them in time so mtime ordering is unambiguous
  sleep 1
  printf '0'  >"$MOCK_WORKSPACE/.ralph/gates/final-latest.exit"
  [ "$(_most_recent_gate_exit "$MOCK_WORKSPACE")" = "0" ]

  # Now the basic gate is the more recent one, and it was red
  sleep 1
  printf '42' >"$MOCK_WORKSPACE/.ralph/gates/basic-latest.exit"
  [ "$(_most_recent_gate_exit "$MOCK_WORKSPACE")" = "42" ]
}

@test "_complete_allowed: no breadcrumbs → allow (backward compat) (0.3.3)" {
  # Projects that haven't run a gate (or are on older plugin state) must
  # not regress — allow COMPLETE to proceed.
  rm -rf "$MOCK_WORKSPACE/.ralph/gates"
  _complete_allowed "$MOCK_WORKSPACE"
}

@test "_complete_allowed: green gate → allow (0.3.3)" {
  mkdir -p "$MOCK_WORKSPACE/.ralph/gates"
  printf '0' >"$MOCK_WORKSPACE/.ralph/gates/final-latest.exit"
  _complete_allowed "$MOCK_WORKSPACE"
}

@test "_complete_allowed: red gate → block (0.3.3)" {
  mkdir -p "$MOCK_WORKSPACE/.ralph/gates"
  printf '124' >"$MOCK_WORKSPACE/.ralph/gates/final-latest.exit"
  ! _complete_allowed "$MOCK_WORKSPACE"
}

@test "_complete_allowed: most recent is what matters, even if older gate was green (0.3.3)" {
  # Exactly the user's failure mode: basic-check passes, but final-check
  # (run later) fails. The agent marks all boxes [x] anyway. Guard must
  # block on the more-recent red gate.
  mkdir -p "$MOCK_WORKSPACE/.ralph/gates"
  printf '0'   >"$MOCK_WORKSPACE/.ralph/gates/basic-latest.exit"
  sleep 1
  printf '124' >"$MOCK_WORKSPACE/.ralph/gates/final-latest.exit"
  ! _complete_allowed "$MOCK_WORKSPACE"
}

# ---------------------------------------------------------------------------
# Pinned-final-command bar (0.6.4) — close the cheap-command-relabeled-as-
# `final` spoof. When .ralph/gates/final-latest.cmd exists, the cmd MUST
# match .ralph/final-check-command (default "pnpm all-check") AND the
# corresponding final-latest.exit must be 0.
# ---------------------------------------------------------------------------

@test "_complete_allowed: pinned cmd matches default and exit 0 → allow (0.6.4)" {
  mkdir -p "$MOCK_WORKSPACE/.ralph/gates"
  printf 'pnpm all-check' >"$MOCK_WORKSPACE/.ralph/gates/final-latest.cmd"
  printf '0'              >"$MOCK_WORKSPACE/.ralph/gates/final-latest.exit"
  _complete_allowed "$MOCK_WORKSPACE"
}

@test "_complete_allowed: pinned cmd mismatch → block, even if exit 0 (0.6.4)" {
  # The exact spoof we're closing: agent ran `gate-run.sh final pnpm
  # basic-check` to satisfy the label-only guard. Cheap, green, wrong.
  mkdir -p "$MOCK_WORKSPACE/.ralph/gates"
  printf 'pnpm basic-check' >"$MOCK_WORKSPACE/.ralph/gates/final-latest.cmd"
  printf '0'                >"$MOCK_WORKSPACE/.ralph/gates/final-latest.exit"
  ! _complete_allowed "$MOCK_WORKSPACE"
  [[ "$_COMPLETE_BLOCK_REASON" == *"pnpm all-check"* ]]
  [[ "$_COMPLETE_BLOCK_REASON" == *"pnpm basic-check"* ]]
}

@test "_complete_allowed: pinned cmd matches but exit non-zero → block (0.6.4)" {
  mkdir -p "$MOCK_WORKSPACE/.ralph/gates"
  printf 'pnpm all-check' >"$MOCK_WORKSPACE/.ralph/gates/final-latest.cmd"
  printf '1'              >"$MOCK_WORKSPACE/.ralph/gates/final-latest.exit"
  ! _complete_allowed "$MOCK_WORKSPACE"
  [[ "$_COMPLETE_BLOCK_REASON" == *"exited 1"* ]]
}

@test "_complete_allowed: .ralph/final-check-command override is honored (0.6.4)" {
  # Non-pnpm project — operator overrides the canonical via the existing
  # breadcrumb file. Pinning logic must read the override, not the default.
  mkdir -p "$MOCK_WORKSPACE/.ralph/gates"
  printf 'cargo test --release' >"$MOCK_WORKSPACE/.ralph/final-check-command"
  printf 'cargo test --release' >"$MOCK_WORKSPACE/.ralph/gates/final-latest.cmd"
  printf '0'                    >"$MOCK_WORKSPACE/.ralph/gates/final-latest.exit"
  _complete_allowed "$MOCK_WORKSPACE"
}

@test "_complete_allowed: override mismatches actual → block (0.6.4)" {
  mkdir -p "$MOCK_WORKSPACE/.ralph/gates"
  printf 'cargo test --release' >"$MOCK_WORKSPACE/.ralph/final-check-command"
  printf 'cargo check'          >"$MOCK_WORKSPACE/.ralph/gates/final-latest.cmd"
  printf '0'                    >"$MOCK_WORKSPACE/.ralph/gates/final-latest.exit"
  ! _complete_allowed "$MOCK_WORKSPACE"
}

@test "_complete_allowed: whitespace differences in pinned cmd are tolerated (0.6.4)" {
  # Operators may type "pnpm  all-check" or have a trailing newline in the
  # file; the breadcrumb is space-joined "$*". Both sides get normalized
  # before comparison.
  mkdir -p "$MOCK_WORKSPACE/.ralph/gates"
  printf 'pnpm  all-check\n' >"$MOCK_WORKSPACE/.ralph/final-check-command"
  printf 'pnpm all-check'    >"$MOCK_WORKSPACE/.ralph/gates/final-latest.cmd"
  printf '0'                 >"$MOCK_WORKSPACE/.ralph/gates/final-latest.exit"
  _complete_allowed "$MOCK_WORKSPACE"
}

@test "_complete_allowed: no final breadcrumb → falls back to most-recent check (0.6.4 compat)" {
  # Project that only runs basic/e2e, never `final` — must keep working
  # with pre-0.6.4 semantics. final-latest.cmd absent, basic exit 0
  # → allow.
  mkdir -p "$MOCK_WORKSPACE/.ralph/gates"
  printf '0' >"$MOCK_WORKSPACE/.ralph/gates/basic-latest.exit"
  _complete_allowed "$MOCK_WORKSPACE"
}

@test "_complete_allowed: no final breadcrumb but basic gate red → block (0.6.4 compat)" {
  mkdir -p "$MOCK_WORKSPACE/.ralph/gates"
  printf '1' >"$MOCK_WORKSPACE/.ralph/gates/basic-latest.exit"
  ! _complete_allowed "$MOCK_WORKSPACE"
  [[ "$_COMPLETE_BLOCK_REASON" == *"most recent gate exited 1"* ]]
}

# ---------------------------------------------------------------------------
# _fmt_iter — loop label with per-loop retry suffix (0.3.7)
# ---------------------------------------------------------------------------

@test "_fmt_iter: retry 0 returns bare loop number (0.3.7)" {
  [ "$(_fmt_iter 1 0)" = "1" ]
  [ "$(_fmt_iter 7 0)" = "7" ]
  # Omitted retry arg defaults to 0
  [ "$(_fmt_iter 12)" = "12" ]
}

@test "_fmt_iter: retry > 0 appends dotted suffix (0.3.7)" {
  [ "$(_fmt_iter 1 1)" = "1.1" ]
  [ "$(_fmt_iter 1 3)" = "1.3" ]
  [ "$(_fmt_iter 14 9)" = "14.9" ]
}

# ---------------------------------------------------------------------------
# _probe_pipeline_stages — per-stage classifier for FIFO EOF diagnosis (0.3.7)
# ---------------------------------------------------------------------------

@test "_probe_pipeline_stages: empty subshell reports all dead (0.3.7)" {
  # A subshell that exits immediately — its pid is dead by the time we
  # probe, so it has no children. Should report all stages dead rather
  # than emitting noise.
  ( : ) &
  local pid=$!
  wait "$pid" 2>/dev/null || true
  local out
  out=$(_probe_pipeline_stages "$pid")
  echo "$out" | grep -q "^claude=dead$"
  echo "$out" | grep -q "^jq=dead$"
  echo "$out" | grep -q "^parser=dead$"
}

@test "_probe_pipeline_stages: detects a live jq child (0.3.7)" {
  # Stand up a subshell that runs a real 3-stage pipe (mirroring the
  # production `claude | jq | stream-parser.sh` shape) so every stage is
  # a real child of the subshell. A trailing no-op (`: ;`) plus the pipe
  # structure prevents bash from exec'ing a single command in place of
  # the subshell.
  (
    sleep 2 | jq -c . >/dev/null 2>&1
    :
  ) &
  local pid=$!
  # Wait for bash to fork the pipe stages inside the subshell.
  local tries=0
  while ! pgrep -P "$pid" >/dev/null 2>&1 && [[ $tries -lt 30 ]]; do
    sleep 0.1
    tries=$((tries + 1))
  done

  local out
  out=$(_probe_pipeline_stages "$pid")

  kill -9 "$pid" 2>/dev/null || true
  # Kill any lingering jq child.
  pkill -9 -P "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true

  echo "$out" | grep -q "^jq=alive$"
}

@test "_probe_pipeline_stages: zombie children report as dead (0.3.10)" {
  # Regression for the 0.3.10 zombie-filter fix. When stream-parser exits
  # immediately after EOF-ing on jq's stdout, its pid enters Z state until
  # the enclosing subshell `wait`s on it. The pre-0.3.10 probe used
  # `pgrep -P` + `ps -o comm=` without checking state and reported the
  # zombie as "alive", which tripped the PARSER EXIT false-positive on
  # otherwise-clean natural ends (FIFO EOF with rc=1). Filtering STAT=Z
  # in the probe gives an accurate picture.
  #
  # We simulate this by backgrounding a subshell whose only child exits
  # immediately. The child becomes a zombie (not reaped until we wait on
  # the outer subshell). During that window the probe must treat it as
  # dead, not alive.
  (
    # Single-line command would be exec-optimized; pipe forces a real
    # child process. That child (`true`) exits instantly and becomes a
    # zombie until the outer subshell (us) reaps it.
    true | sleep 0.5
  ) &
  local pid=$!
  # Wait for the child to spawn and `true` to exit. A short sleep is
  # enough — we want to probe while sleep is still alive and `true` is
  # a zombie.
  sleep 0.1

  local out
  out=$(_probe_pipeline_stages "$pid")

  kill -9 "$pid" 2>/dev/null || true
  pkill -9 -P "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true

  # The probe should NOT count the zombie `true` as alive. `sleep` is
  # still alive but it isn't claude/jq/parser, so none of those flags
  # should fire — all three should be dead.
  echo "$out" | grep -q "^claude=dead$"
  echo "$out" | grep -q "^jq=dead$"
  echo "$out" | grep -q "^parser=dead$"
}

# ---------------------------------------------------------------------------
# Activity-based heartbeat (0.4.0)
# ---------------------------------------------------------------------------

@test "stream-parser emits HEARTBEAT on log_activity and log_token_status (0.4.0)" {
  # End-to-end check: feeding real tool_result events through the
  # stream-parser produces HEARTBEAT tokens on stdout. The main loop's
  # read-timer reset depends on these, so we guard the contract here.
  # Separate tests in stream-parser.bats cover per-path emission.
  local tmp
  tmp=$(mktemp -d "$BATS_TMPDIR/heartbeat.XXXXXX")
  mkdir -p "$tmp/.ralph"
  local out
  out=$(printf '{"kind":"tool_result","name":"Read","bytes":100,"lines":5,"path":"/tmp/x"}\n' \
    | bash "$SCRIPTS_DIR/stream-parser.sh" "$tmp" 1)
  echo "$out" | grep -q "^HEARTBEAT$"
  rm -rf "$tmp"
}

# ---------------------------------------------------------------------------
# Read-loop rc capture (0.3.9)
# ---------------------------------------------------------------------------

@test "while-read-rc: documents the bash gotcha (0.3.9)" {
  # Regression anchor for the 0.3.9 false-positive PARSER EXIT fix.
  # Per bash(1): "The exit status of the while and until commands is the
  # exit status of the last command executed in list-2, or zero if none
  # was executed." That means `while read; do :; done < fifo; rc=$?` ALWAYS
  # reports rc=0, regardless of whether read EOF'd (1) or timed out (142).
  # The pre-0.3.9 run_loop used that broken idiom, which made the
  # timeout branch of _classify_heartbeat_exit unreachable and caused
  # every heartbeat-scale quiet period to surface as a PARSER EXIT.
  #
  # This test pins both halves of the story: the broken idiom masks the
  # status, and the new explicit-break idiom preserves it.
  local fifo
  fifo=$(mktemp -u "$BATS_TMPDIR/rc-fifo.XXXXXX")
  mkfifo "$fifo"

  # Writer opens then closes without writing (FIFO EOF, no data).
  ( exec 3>"$fifo"; exec 3>&- ) &
  local writer1=$!

  # Broken idiom — masks EOF as rc=0.
  local bad_rc
  while IFS= read -t 5 -r _line; do :; done <"$fifo"
  bad_rc=$?
  wait "$writer1" 2>/dev/null || true
  [ "$bad_rc" -eq 0 ]

  # Explicit-break idiom — preserves EOF rc=1.
  ( exec 3>"$fifo"; exec 3>&- ) &
  local writer2=$!
  local good_rc=0
  while :; do
    IFS= read -t 5 -r _line || { good_rc=$?; break; }
    :
  done <"$fifo"
  wait "$writer2" 2>/dev/null || true
  [ "$good_rc" -eq 1 ]

  rm -f "$fifo"
}

@test "while-read-rc: explicit-break captures timeout rc (0.3.9)" {
  # Same idiom, timeout path. Writer holds the FIFO open but writes no
  # data — read hits its -t timeout. The exact rc value differs by bash
  # version (bash 5.x returns 128+SIGALRM = 142; bash 3.2 returns 1),
  # so we only assert it is non-zero — the key invariant for the 0.3.9
  # fix is that read's rc is *captured* rather than swallowed to 0 by
  # the while loop's exit-status semantics.
  local fifo
  fifo=$(mktemp -u "$BATS_TMPDIR/rc-timeout-fifo.XXXXXX")
  mkfifo "$fifo"

  ( exec 3>"$fifo"; sleep 5 ) &
  local writer=$!

  local rc=0
  while :; do
    IFS= read -t 1 -r _line || { rc=$?; break; }
    :
  done <"$fifo"

  kill "$writer" 2>/dev/null || true
  wait "$writer" 2>/dev/null || true
  rm -f "$fifo"

  [ "$rc" -ne 0 ]
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

@test "_probe_pipeline_stages: detects a live stream-parser child by args (0.3.7)" {
  # A bash wrapper whose args contain "stream-parser.sh" should classify
  # as parser=alive even when comm is just "bash". Use a real pipe so the
  # bash stage is a child of the subshell, not exec'd in place.
  local fake_script
  fake_script=$(mktemp "$BATS_TMPDIR/stream-parser.sh.XXXXXX")
  cat >"$fake_script" <<'EOF'
#!/usr/bin/env bash
# Fake stream-parser that just sleeps so the probe finds it alive.
sleep 5
EOF
  chmod +x "$fake_script"

  (
    sleep 2 | bash "$fake_script" /workspace 1
    :
  ) &
  local pid=$!
  local tries=0
  while ! pgrep -P "$pid" >/dev/null 2>&1 && [[ $tries -lt 30 ]]; do
    sleep 0.1
    tries=$((tries + 1))
  done

  local out
  out=$(_probe_pipeline_stages "$pid")

  kill -9 "$pid" 2>/dev/null || true
  pkill -9 -P "$pid" 2>/dev/null || true
  pkill -9 -f "$fake_script" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  rm -f "$fake_script"

  echo "$out" | grep -q "^parser=alive$"
}

# -----------------------------------------------------------------------------
# 0.6.3: terminology + flow-vs-loop driver semantics
#
# The driver renamed `iteration` → `loop` in code and log messages. The
# `--iterations` flag and `MAX_ITERATIONS` / `RALPH_MAX_ITERATIONS` env vars
# are kept as deprecated aliases for one minor release. The framing prompt
# is now flow-oriented: "loop", not "iteration N of an autonomous loop";
# the agent is told ending the turn between commits costs 10–30k tokens.
# -----------------------------------------------------------------------------

@test "MAX_LOOPS env var sets the loop ceiling (0.6.3)" {
  # Re-source after setting the env to exercise the cascade in
  # ralph-common.sh. Use a subshell so the rest of the test file is
  # unaffected.
  (
    unset MAX_LOOPS RALPH_MAX_LOOPS MAX_ITERATIONS RALPH_MAX_ITERATIONS
    export MAX_LOOPS=42
    # shellcheck disable=SC1090
    source "$SCRIPTS_DIR/ralph-common.sh"
    [ "$MAX_LOOPS" = "42" ]
  )
}

@test "RALPH_MAX_LOOPS is honored as a fallback (0.6.3)" {
  (
    unset MAX_LOOPS RALPH_MAX_LOOPS MAX_ITERATIONS RALPH_MAX_ITERATIONS
    export RALPH_MAX_LOOPS=17
    # shellcheck disable=SC1090
    source "$SCRIPTS_DIR/ralph-common.sh"
    [ "$MAX_LOOPS" = "17" ]
  )
}

@test "MAX_ITERATIONS is honored as a deprecated alias for MAX_LOOPS (0.6.3 compat)" {
  (
    unset MAX_LOOPS RALPH_MAX_LOOPS MAX_ITERATIONS RALPH_MAX_ITERATIONS
    export MAX_ITERATIONS=11
    # shellcheck disable=SC1090
    source "$SCRIPTS_DIR/ralph-common.sh"
    [ "$MAX_LOOPS" = "11" ]
  )
}

@test "RALPH_MAX_ITERATIONS is honored as a deprecated alias for MAX_LOOPS (0.6.3 compat)" {
  (
    unset MAX_LOOPS RALPH_MAX_LOOPS MAX_ITERATIONS RALPH_MAX_ITERATIONS
    export RALPH_MAX_ITERATIONS=9
    # shellcheck disable=SC1090
    source "$SCRIPTS_DIR/ralph-common.sh"
    [ "$MAX_LOOPS" = "9" ]
  )
}

@test "MAX_LOOPS default is 10 when no env var is set (0.6.4)" {
  # 0.6.3 default was 20 (carryover from per-task iteration era). 0.6.4
  # lowers to 10 because under the flow framing one loop should chew
  # through most/all of a spec — double-digit respawns is a smell, not
  # steady state. Stall thresholds catch genuine stuckness well before 10.
  (
    unset MAX_LOOPS RALPH_MAX_LOOPS MAX_ITERATIONS RALPH_MAX_ITERATIONS
    # shellcheck disable=SC1090
    source "$SCRIPTS_DIR/ralph-common.sh"
    [ "$MAX_LOOPS" = "10" ]
  )
}

@test "build_prompt framing uses loop terminology and names stop conditions (0.9.0)" {
  local output
  output=$(build_prompt "$MOCK_WORKSPACE" 1)

  # Header reads "Ralph Loop 1", not "Ralph Iteration 1".
  echo "$output" | grep -q "^# Ralph Loop 1"
  ! echo "$output" | grep -q "^# Ralph Iteration"

  # The framing names the four real stop conditions.
  echo "$output" | grep -q "ALL_TASKS_DONE"
  echo "$output" | grep -q "GUTTER"
  echo "$output" | grep -q "context-warning-active"
  echo "$output" | grep -q "stop-requested"

  # 0.9.0: "cold-start tax" guilt-tripping language was removed — it
  # pressured the agent to flow through tasks even when stopping to
  # diagnose was the right move.
  if echo "$output" | grep -qi "cold-start tax"; then
    fail "cold-start tax language removed in 0.9.0"
  fi
}

@test "run_iteration is renamed to run_loop (0.6.3)" {
  # Both names should NOT exist; only the new name. Catches accidental
  # leftover function references after the rename.
  declare -F run_loop >/dev/null
  ! declare -F run_iteration >/dev/null
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

@test "agent_build_cmd unset prefix comes before the claude invocation" {
  local cmd
  cmd=$(agent_build_cmd claude "sonnet" "hello")
  # The unset must precede 'claude -p' so it takes effect in the same
  # shell before the process is exec'd.
  local unset_pos claude_pos
  unset_pos=$(echo "$cmd" | grep -bo "unset ANTHROPIC" | head -1 | cut -d: -f1)
  claude_pos=$(echo "$cmd" | grep -bo "claude -p" | head -1 | cut -d: -f1)
  [ "$unset_pos" -lt "$claude_pos" ]
}

@test "agent_build_cmd does NOT unset ANTHROPIC vars for cursor-agent" {
  local cmd
  cmd=$(agent_build_cmd cursor-agent "composer-2" "hello")
  # cursor-agent uses its own auth; don't touch ANTHROPIC vars.
  ! echo "$cmd" | grep -q "unset ANTHROPIC"
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
