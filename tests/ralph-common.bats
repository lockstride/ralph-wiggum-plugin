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

@test "build_prompt framing is under 55 lines (excluding user body)" {
  local output
  output=$(build_prompt "$MOCK_WORKSPACE" 1)

  # Count lines before the user body marker "## Task Execution"
  local framing_lines
  framing_lines=$(echo "$output" | sed '/^## Task Execution$/,$d' | wc -l | tr -d ' ')

  # Framing should be concise. History:
  #   0.3.3 added Completion Bar          (cap was 35)
  #   0.3.6 added Gate Runner section     (cap bumped to 55)
  #   0.6.3 expanded the Stop conditions  (cap bumped to 70)
  #         section so the four real stop conditions are explicit and
  #         reframed gate-failure guidance away from a procedure.
  # The Gate Runner block only renders when gate-run.sh exists next to
  # ralph-common.sh (it does in-tree). If it ever needs to grow further,
  # update this cap AND AGENTS.md §Prompt Architecture in the same commit.
  [ "$framing_lines" -le 70 ]
}

@test "build_prompt includes Completion Bar (0.3.3)" {
  local output
  output=$(build_prompt "$MOCK_WORKSPACE" 1)

  echo "$output" | grep -q "Completion Bar"
  echo "$output" | grep -qi "pre-existing failure.*never"
  # Completion Bar must appear BEFORE State Files — it's the first rule.
  echo "$output" | awk '
    /## Completion Bar/ { saw_cb=1 }
    /## State Files/    { if (saw_cb) ok=1 }
    END { exit ok ? 0 : 1 }
  '
}

@test "build_prompt includes required sections" {
  local output
  output=$(build_prompt "$MOCK_WORKSPACE" 1)

  echo "$output" | grep -q "State Files"
  # 0.6.3 renamed "Signals" to "Stop conditions" — same intent, clearer name.
  echo "$output" | grep -q "Stop conditions"
  echo "$output" | grep -q "Loop Hygiene"
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

@test "build_prompt uses diagnostic template when recovery hint present (0.3.0/0.7.0)" {
  # Simulate a prior loop's stream-parser having written a hint.
  # 0.7.0: recovery mode produces a completely different prompt template
  # (diagnostic-first) instead of prepending the hint to the normal framing.
  cat > "$MOCK_WORKSPACE/.ralph/recovery-hint.md" <<EOF
## Recovery Hint from Prior Loop

Your prior loop ran \`pnpm test\` twice with exit code 1. Do not retry it.
EOF

  local output
  output=$(build_prompt "$MOCK_WORKSPACE" 5)

  # Diagnostic Recovery header, not the normal Ralph Loop header
  echo "$output" | grep -q "Diagnostic Recovery"
  echo "$output" | grep -q "Loop 5"
  # Hint content is embedded in the output
  echo "$output" | grep -q "Recovery Hint from Prior Loop"
  echo "$output" | grep -q "pnpm test"
  # 5-step mandatory diagnostic sequence must be present
  echo "$output" | grep -q "Print the exact error message"
  echo "$output" | grep -q "Identify the file the error names"
  echo "$output" | grep -q "Confirm intersection"
}

@test "build_prompt recovery template omits normal loop sections (0.7.0)" {
  # In recovery mode, the normal loop-hygiene sections must be absent.
  # Their presence would bury the diagnostic directive under familiar boilerplate.
  cat > "$MOCK_WORKSPACE/.ralph/recovery-hint.md" <<EOF
## Recovery Hint
Some hint body.
EOF

  local output
  output=$(build_prompt "$MOCK_WORKSPACE" 1)

  # These normal-framing sections must NOT appear in recovery mode
  if echo "$output" | grep -q "^## Completion Bar"; then
    fail "Completion Bar must not appear in recovery prompt"
  fi
  if echo "$output" | grep -q "^## Stop conditions"; then
    fail "Stop conditions must not appear in recovery prompt"
  fi
  if echo "$output" | grep -q "^## Loop Hygiene"; then
    fail "Loop Hygiene must not appear in recovery prompt"
  fi
  # Original task body is still included (for context only)
  echo "$output" | grep -q "Mock task body"
}

@test "build_prompt deletes recovery hint after consumption (consume-once) (0.3.0)" {
  echo "## Recovery Hint from Prior Loop" > "$MOCK_WORKSPACE/.ralph/recovery-hint.md"
  echo "Some hint body" >> "$MOCK_WORKSPACE/.ralph/recovery-hint.md"

  build_prompt "$MOCK_WORKSPACE" 1 >/dev/null

  # File must be gone
  [ ! -f "$MOCK_WORKSPACE/.ralph/recovery-hint.md" ]
}

@test "build_prompt uses normal template when no hint file (0.3.0)" {
  # No recovery-hint.md → normal framing must be used
  rm -f "$MOCK_WORKSPACE/.ralph/recovery-hint.md"

  local output
  output=$(build_prompt "$MOCK_WORKSPACE" 1)

  # Normal sections present
  echo "$output" | grep -q "^## Completion Bar"
  echo "$output" | grep -q "^## State Files"
  echo "$output" | grep -q "^## Stop conditions"
  echo "$output" | grep -q "^## Loop Hygiene"

  # Diagnostic Recovery header must NOT appear
  if echo "$output" | grep -q "Diagnostic Recovery"; then
    fail "Diagnostic Recovery header must not appear in normal prompt"
  fi
}

# ---------------------------------------------------------------------------
# Skill suggestion enforcement (0.7.0) — consume-once, injected as mandatory
# ---------------------------------------------------------------------------

@test "build_prompt injects MANDATORY SKILL DIRECTIVE when skill-suggestion present (0.7.0)" {
  cat > "$MOCK_WORKSPACE/.ralph/skill-suggestion" <<EOF
**Skill to invoke**: \`diagnosing-stuck-tasks\`

**Why**: 3 consecutive failures on the same gate command.

**Context**: Switch cognitive posture before retrying.
EOF

  local output
  output=$(build_prompt "$MOCK_WORKSPACE" 3)

  echo "$output" | grep -q "MANDATORY SKILL DIRECTIVE"
  echo "$output" | grep -q "diagnosing-stuck-tasks"
  echo "$output" | grep -q "Switch cognitive posture"
}

@test "build_prompt deletes skill-suggestion after consumption (consume-once) (0.7.0)" {
  cat > "$MOCK_WORKSPACE/.ralph/skill-suggestion" <<EOF
**Skill to invoke**: \`diagnosing-stuck-tasks\`
EOF

  build_prompt "$MOCK_WORKSPACE" 1 >/dev/null

  [ ! -f "$MOCK_WORKSPACE/.ralph/skill-suggestion" ]
}

@test "build_prompt normal prompt has no MANDATORY SKILL DIRECTIVE when no skill file (0.7.0)" {
  rm -f "$MOCK_WORKSPACE/.ralph/skill-suggestion"

  local output
  output=$(build_prompt "$MOCK_WORKSPACE" 1)

  if echo "$output" | grep -q "MANDATORY SKILL DIRECTIVE"; then
    fail "MANDATORY SKILL DIRECTIVE must not appear when no skill-suggestion file exists"
  fi
}

@test "build_prompt skill directive appears before main framing sections (0.7.0)" {
  # Skill directive must be injected at the TOP of the normal prompt so the
  # agent sees it before the execute-gate-commit framing it has internalized.
  cat > "$MOCK_WORKSPACE/.ralph/skill-suggestion" <<EOF
**Skill to invoke**: \`diagnosing-stuck-tasks\`
EOF

  local output
  output=$(build_prompt "$MOCK_WORKSPACE" 1)

  echo "$output" | awk '
    /MANDATORY SKILL DIRECTIVE/ { saw_skill=1 }
    /^## Completion Bar/        { if (saw_skill) ok=1 }
    END { exit ok ? 0 : 1 }
  '
}

# ---------------------------------------------------------------------------
# _check_wrong_file_edits — wrong-file heuristic (0.7.0)
# ---------------------------------------------------------------------------

@test "_check_wrong_file_edits: no gates dir → returns 0 (0.7.0)" {
  rm -rf "$MOCK_WORKSPACE/.ralph/gates"
  _check_wrong_file_edits "$MOCK_WORKSPACE"
}

@test "_check_wrong_file_edits: no failing gates → returns 0 (0.7.0)" {
  mkdir -p "$MOCK_WORKSPACE/.ralph/gates"
  printf '0' >"$MOCK_WORKSPACE/.ralph/gates/basic-latest.exit"
  printf '0' >"$MOCK_WORKSPACE/.ralph/gates/final-latest.exit"
  printf 'gate content\n' >"$MOCK_WORKSPACE/.ralph/gates/basic-latest.log"
  _check_wrong_file_edits "$MOCK_WORKSPACE"
}

@test "_check_wrong_file_edits: returns 0 when agent writes intersect gate error files (0.7.0)" {
  mkdir -p "$MOCK_WORKSPACE/.ralph/gates"
  printf '1' >"$MOCK_WORKSPACE/.ralph/gates/basic-latest.exit"
  # Gate log names a specific TS file in an error line
  printf 'src/app/app.module.ts:4:1 - error TS2304: Cannot find name foo\n' \
    >"$MOCK_WORKSPACE/.ralph/gates/basic-latest.log"

  # Activity log shows the agent wrote that same file
  printf '[12:00:00] WRITE src/app/app.module.ts\n' \
    >"$MOCK_WORKSPACE/.ralph/activity.log"

  _check_wrong_file_edits "$MOCK_WORKSPACE"
  # No recovery hint should be written
  [ ! -f "$MOCK_WORKSPACE/.ralph/recovery-hint.md" ]
}

@test "_check_wrong_file_edits: returns 1 and writes hint when agent wrote wrong files (0.7.0)" {
  mkdir -p "$MOCK_WORKSPACE/.ralph/gates"
  printf '1' >"$MOCK_WORKSPACE/.ralph/gates/basic-latest.exit"
  # Gate log names app.module.ts
  printf 'src/app/app.module.ts:4:1 - error TS2304: Cannot find name foo\n' \
    >"$MOCK_WORKSPACE/.ralph/gates/basic-latest.log"

  # Agent wrote a completely different file
  printf '[12:00:00] WRITE src/app/main.spec.ts\n' \
    >"$MOCK_WORKSPACE/.ralph/activity.log"

  local rc=0
  _check_wrong_file_edits "$MOCK_WORKSPACE" || rc=$?
  [ "$rc" -eq 1 ]

  # Recovery hint must be written
  [ -f "$MOCK_WORKSPACE/.ralph/recovery-hint.md" ]
  grep -qi 'wrong-file mismatch' "$MOCK_WORKSPACE/.ralph/recovery-hint.md"
  grep -q 'app.module.ts' "$MOCK_WORKSPACE/.ralph/recovery-hint.md"
}

@test "_check_wrong_file_edits: does not clobber existing recovery hint (0.7.0)" {
  mkdir -p "$MOCK_WORKSPACE/.ralph/gates"
  printf '1' >"$MOCK_WORKSPACE/.ralph/gates/basic-latest.exit"
  printf 'src/app/app.module.ts:4:1 - error TS9999\n' \
    >"$MOCK_WORKSPACE/.ralph/gates/basic-latest.log"
  printf '[12:00:00] WRITE src/other.ts\n' >"$MOCK_WORKSPACE/.ralph/activity.log"

  # Pre-existing recovery hint from a prior escalation
  printf 'Prior hint content\n' >"$MOCK_WORKSPACE/.ralph/recovery-hint.md"

  _check_wrong_file_edits "$MOCK_WORKSPACE" || true

  # Original hint must be preserved
  grep -q 'Prior hint content' "$MOCK_WORKSPACE/.ralph/recovery-hint.md"
}

# ---------------------------------------------------------------------------
# _check_orphan_leak escalation to recovery hint (0.7.0)
# ---------------------------------------------------------------------------

@test "_check_orphan_leak writes recovery-hint.md on leak (0.7.0)" {
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

  [ -f "$ws/.ralph/recovery-hint.md" ]
  grep -q 'Orphan file leak' "$ws/.ralph/recovery-hint.md"
  grep -q 'orphan.txt' "$ws/.ralph/recovery-hint.md"

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

@test "build_prompt framing uses flow-not-iteration language (0.6.3)" {
  local output
  output=$(build_prompt "$MOCK_WORKSPACE" 1)

  # Header reads "Ralph Loop 1", not "Ralph Iteration 1".
  echo "$output" | grep -q "^# Ralph Loop 1"
  ! echo "$output" | grep -q "^# Ralph Iteration"

  # The framing names the four real stop conditions and explicitly tells
  # the agent that ending its turn between commits is the wrong move.
  echo "$output" | grep -q "ALL_TASKS_DONE"
  echo "$output" | grep -q "GUTTER"
  echo "$output" | grep -q "WARN"
  echo "$output" | grep -q "stop-requested"
  echo "$output" | grep -qi "cold-start tax"
}

@test "run_iteration is renamed to run_loop (0.6.3)" {
  # Both names should NOT exist; only the new name. Catches accidental
  # leftover function references after the rename.
  declare -F run_loop >/dev/null
  ! declare -F run_iteration >/dev/null
}
