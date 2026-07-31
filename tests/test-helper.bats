#!/usr/bin/env bats
# Behavioral tests for tests/test_helper.bash — the suite's own fixtures.
#
# These exist because a broken helper does not fail loudly; it corrupts
# whatever ran it.

load test_helper

setup() {
  create_mock_workspace
}

teardown() {
  rm -rf "$MOCK_WORKSPACE" "$VICTIM_REPO"
}

@test "create_mock_workspace builds an isolated git repo (0.20.0)" {
  [ -d "$MOCK_WORKSPACE/.ralph/gates" ]
  [ -d "$MOCK_WORKSPACE/.git" ]
  git -C "$MOCK_WORKSPACE" log --oneline | grep -q "init"
}

@test "an inherited git environment cannot reach the real repo (0.20.0)" {
  # git exports GIT_DIR / GIT_INDEX_FILE to its hooks, and .githooks/pre-commit
  # runs this suite. Inherited, they retarget the mock's `git init/add/commit`
  # at the repository being committed to: the mock's .gitignore lands in the
  # real index and `git commit -m init` seals the in-progress commit's staged
  # work into a bogus "init" commit. Stand up a victim repo, point the git env
  # at it exactly as a hook would, and prove the helper leaves it alone.
  VICTIM_REPO="$(mktemp -d "$BATS_TMPDIR/ralph-victim-XXXXXX")"
  (
    cd "$VICTIM_REPO" || exit 1
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test"
    echo original > tracked.txt
    git add tracked.txt
    git commit -q -m "base"
    # A staged change, as there always is mid-commit.
    echo staged >> tracked.txt
    git add tracked.txt
  )
  local before
  before=$(git -C "$VICTIM_REPO" rev-parse HEAD)

  export GIT_DIR="$VICTIM_REPO/.git" GIT_INDEX_FILE="$VICTIM_REPO/.git/index"
  create_mock_workspace
  unset GIT_DIR GIT_INDEX_FILE

  # The victim gained no commit, and its staged change is still staged.
  [ "$(git -C "$VICTIM_REPO" rev-parse HEAD)" = "$before" ]
  [ "$(git -C "$VICTIM_REPO" log --oneline | wc -l | tr -d ' ')" = "1" ]
  git -C "$VICTIM_REPO" diff --cached --name-only | grep -q "tracked.txt"
  ! git -C "$VICTIM_REPO" diff --cached --name-only | grep -q ".gitignore"

  # …and the mock is a real, separate repo with its own history.
  git -C "$MOCK_WORKSPACE" log --oneline | grep -q "init"
}
