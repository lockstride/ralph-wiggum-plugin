#!/usr/bin/env bats
# Behavioral tests for proof-check.sh (tranche-close proof check)

load test_helper

CHECK="$SCRIPTS_DIR/proof-check.sh"

setup() {
  create_mock_workspace
  create_mock_plan
}

teardown() {
  rm -rf "$MOCK_WORKSPACE"
}

_proofs_exist() {
  touch "$MOCK_WORKSPACE/tests/one.bats" "$MOCK_WORKSPACE/tests/two.bats" "$MOCK_WORKSPACE/tests/three.bats"
}

@test "allows a close when every criterion names a test that exists" {
  _proofs_exist
  run bash "$CHECK" "$MOCK_PLAN" T002 "$MOCK_WORKSPACE"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "refuses a close while a criterion names a test file that does not exist" {
  touch "$MOCK_WORKSPACE/tests/one.bats"
  run bash "$CHECK" "$MOCK_PLAN" T002 "$MOCK_WORKSPACE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ABC-1 AC2"* ]]
  [[ "$output" == *"tests/two.bats"* ]]
  [[ "$output" != *"AC1"* ]]
}

@test "refuses a close while a criterion names no test" {
  _proofs_exist
  sed -i.bak 's/^- AC2: also works .*/- AC2: also works/' "$MOCK_PLAN"
  run bash "$CHECK" "$MOCK_PLAN" T002 "$MOCK_WORKSPACE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ABC-1 AC2: no test is named"* ]]
}

@test "a proof that is a command names no file to look for" {
  _proofs_exist
  run bash "$CHECK" "$MOCK_PLAN" T002 "$MOCK_WORKSPACE"
  [ "$status" -eq 0 ]
}

@test "a ticket id on the close line's continuation is closed too" {
  _proofs_exist
  sed -i.bak 's/^- AC1: a command proves it .*/- AC1: a command proves it/' "$MOCK_PLAN"
  run bash "$CHECK" "$MOCK_PLAN" T002 "$MOCK_WORKSPACE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ABC-2 AC1"* ]]
}

@test "a close naming no ticket takes its tickets from the tranche heading" {
  touch "$MOCK_WORKSPACE/tests/one.bats" "$MOCK_WORKSPACE/tests/two.bats"
  run bash "$CHECK" "$MOCK_PLAN" T004 "$MOCK_WORKSPACE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ABC-3 AC1"* ]]
}

@test "only the closing tranche's tickets are checked" {
  touch "$MOCK_WORKSPACE/tests/one.bats" "$MOCK_WORKSPACE/tests/two.bats"
  run bash "$CHECK" "$MOCK_PLAN" T002 "$MOCK_WORKSPACE"
  [ "$status" -eq 0 ]
}

@test "a plan with no proof map runs as before" {
  sed -i.bak 's/ | proof:.*//' "$MOCK_PLAN"
  run bash "$CHECK" "$MOCK_PLAN" T002 "$MOCK_WORKSPACE"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a task the plan does not hold, or a plan that is missing, is allowed" {
  run bash "$CHECK" "$MOCK_PLAN" T099 "$MOCK_WORKSPACE"
  [ "$status" -eq 0 ]
  run bash "$CHECK" "$MOCK_WORKSPACE/absent.md" T002 "$MOCK_WORKSPACE"
  [ "$status" -eq 0 ]
  run bash "$CHECK"
  [ "$status" -eq 0 ]
}

@test "a task id is matched whole, not as a prefix" {
  run bash "$CHECK" "$MOCK_PLAN" T00 "$MOCK_WORKSPACE"
  [ "$status" -eq 0 ]
}

@test "names every failing criterion, not just the first" {
  run bash "$CHECK" "$MOCK_PLAN" T002 "$MOCK_WORKSPACE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ABC-1 AC1"* ]]
  [[ "$output" == *"ABC-1 AC2"* ]]
}

@test "checks a large plan in under a second" {
  local i
  for i in $(seq 1 400); do
    printf '### ABC-%s - filler\n- AC1: x | proof: tests/one.bats\n' "$((i + 100))" >>"$MOCK_PLAN"
  done
  _proofs_exist
  local start end
  start=$(date +%s)
  run bash "$CHECK" "$MOCK_PLAN" T002 "$MOCK_WORKSPACE"
  end=$(date +%s)
  [ "$status" -eq 0 ]
  [ $((end - start)) -lt 1 ]
}
