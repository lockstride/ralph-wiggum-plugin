#!/usr/bin/env bats
# Behavioral tests for ralph-setup.sh: the --evaluate chain.

load test_helper

setup() {
  create_mock_workspace
  stub_claude_cli
  # A copy of the plugin whose ralph-evaluate.sh only records that it ran.
  PLUGIN_COPY="$(mktemp -d "$BATS_TMPDIR/ralph-plugin-XXXXXX")"
  cp -R "$PLUGIN_ROOT/shared-scripts" "$PLUGIN_ROOT/shared-references" "$PLUGIN_ROOT/.claude-plugin" "$PLUGIN_COPY/"
  cat >"$PLUGIN_COPY/shared-scripts/ralph-evaluate.sh" <<'STUB'
#!/usr/bin/env bash
echo "EVAL CHAINED: $*"
exit 7
STUB
  chmod +x "$PLUGIN_COPY/shared-scripts/ralph-evaluate.sh"
  cat >"$MOCK_WORKSPACE/.ralph/command-policy" <<'POLICY'
[gates]
basic | true
full  | true
final | true
POLICY
}

teardown() {
  rm -rf "$MOCK_WORKSPACE" "$PLUGIN_COPY"
}

_setup() {
  bash "$PLUGIN_COPY/shared-scripts/ralph-setup.sh" --cli claude -m opus --prompt -n 1 "$@" "$MOCK_WORKSPACE" </dev/null
}

@test "a relaunch with every task done chains into the eval loop when --evaluate is set" {
  printf -- '- [x] T001 Build it\n- [ ] T002 CI on main (blocked: needs CI)\n' >"$MOCK_WORKSPACE/PROMPT.md"
  run _setup --evaluate
  [ "$status" -eq 7 ]
  [[ "$output" == *"EVAL CHAINED: --cli claude -m opus --prompt $MOCK_WORKSPACE"* ]]
}

@test "a relaunch with every task done and no --evaluate exits 0 without the eval loop" {
  printf -- '- [x] T001 Build it\n' >"$MOCK_WORKSPACE/PROMPT.md"
  run _setup
  [ "$status" -eq 0 ]
  [[ "$output" == *"Nothing to do."* ]]
  [[ "$output" != *"EVAL CHAINED"* ]]
}
