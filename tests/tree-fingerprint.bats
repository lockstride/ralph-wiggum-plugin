#!/usr/bin/env bats
# Behavioral tests for tree-fingerprint.sh — the working-tree fingerprint the
# gate runner records beside each verdict and the guard compares against.

load test_helper

FP="$SCRIPTS_DIR/tree-fingerprint.sh"

setup() {
  create_mock_workspace
  echo "one" >"$MOCK_WORKSPACE/src.ts"
  git -C "$MOCK_WORKSPACE" add src.ts
  git -C "$MOCK_WORKSPACE" commit -q -m "add src"
}

teardown() {
  rm -rf "$MOCK_WORKSPACE"
}

@test "is stable while nothing changes" {
  local a b
  a=$(bash "$FP" "$MOCK_WORKSPACE")
  b=$(bash "$FP" "$MOCK_WORKSPACE")
  [ -n "$a" ]
  [ "$a" = "$b" ]
}

@test "changes with a tracked edit and returns when it is reverted" {
  local before edited reverted
  before=$(bash "$FP" "$MOCK_WORKSPACE")
  echo "two" >>"$MOCK_WORKSPACE/src.ts"
  edited=$(bash "$FP" "$MOCK_WORKSPACE")
  git -C "$MOCK_WORKSPACE" checkout -q -- src.ts
  reverted=$(bash "$FP" "$MOCK_WORKSPACE")
  [ "$edited" != "$before" ]
  [ "$reverted" = "$before" ]
}

@test "changes when a staged edit is the only change" {
  local before
  before=$(bash "$FP" "$MOCK_WORKSPACE")
  echo "two" >>"$MOCK_WORKSPACE/src.ts"
  git -C "$MOCK_WORKSPACE" add src.ts
  [ "$(bash "$FP" "$MOCK_WORKSPACE")" != "$before" ]
}

@test "changes with a new untracked file, and with its content" {
  local before added edited
  before=$(bash "$FP" "$MOCK_WORKSPACE")
  echo "a" >"$MOCK_WORKSPACE/new.ts"
  added=$(bash "$FP" "$MOCK_WORKSPACE")
  echo "b" >"$MOCK_WORKSPACE/new.ts"
  edited=$(bash "$FP" "$MOCK_WORKSPACE")
  [ "$added" != "$before" ]
  [ "$edited" != "$added" ]
}

@test "changes with a commit" {
  local before
  before=$(bash "$FP" "$MOCK_WORKSPACE")
  git -C "$MOCK_WORKSPACE" commit -q --allow-empty -m "empty"
  [ "$(bash "$FP" "$MOCK_WORKSPACE")" != "$before" ]
}

@test "ignores paths git ignores" {
  local before
  before=$(bash "$FP" "$MOCK_WORKSPACE")
  echo "state" >"$MOCK_WORKSPACE/.ralph/activity.log"
  [ "$(bash "$FP" "$MOCK_WORKSPACE")" = "$before" ]
}

@test "defaults to RALPH_WORKSPACE when no argument is given" {
  [ "$(cd / && RALPH_WORKSPACE="$MOCK_WORKSPACE" bash "$FP")" = "$(bash "$FP" "$MOCK_WORKSPACE")" ]
}

@test "prints nothing and succeeds outside a git work tree" {
  local ws
  ws=$(mktemp -d "$BATS_TMPDIR/ralph-nogit-XXXXXX")
  # The ceiling keeps git from finding a repository above the temp dir.
  GIT_CEILING_DIRECTORIES="$BATS_TMPDIR" run bash "$FP" "$ws"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  rm -rf "$ws"
}

@test "leaves no index.lock behind" {
  echo "two" >>"$MOCK_WORKSPACE/src.ts"
  bash "$FP" "$MOCK_WORKSPACE" >/dev/null
  [ ! -e "$MOCK_WORKSPACE/.git/index.lock" ]
}
