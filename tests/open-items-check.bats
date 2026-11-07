#!/usr/bin/env bats
# Behavioral tests for open-items-check.sh (completion check on open-items.md)

load test_helper

CHECK="$SCRIPTS_DIR/open-items-check.sh"

setup() {
  create_mock_workspace
  ITEMS="$MOCK_WORKSPACE/open-items.md"
}

teardown() {
  rm -rf "$MOCK_WORKSPACE"
}

_items() {
  {
    printf '# Open Items\n\n'
    printf '| ID | Source task | Class | Summary | Disposition |\n'
    printf '| --- | --- | --- | --- | --- |\n'
    printf '%s\n' "$@"
  } >"$ITEMS"
}

@test "allows a file whose rows all carry a valid disposition" {
  _items \
    '| OI-01 | T003 | defect | a | fixed |' \
    '| OI-02 | T004 | follow-up | b | ticketed https://linear.app/x/issue/ABC-1 |' \
    '| OI-03 | T005 | decision | c | accepted Brian |'
  run bash "$CHECK" "$ITEMS"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "allows a table with no rows (the template as seeded)" {
  _items
  run bash "$CHECK" "$ITEMS"
  [ "$status" -eq 0 ]
}

@test "refuses a row with an empty disposition and names it" {
  _items '| OI-01 | T003 | defect | a | fixed |' '| OI-02 | T004 | decision | b |  |'
  run bash "$CHECK" "$ITEMS"
  [ "$status" -eq 1 ]
  [[ "$output" == *"OI-02: no disposition"* ]]
  [[ "$output" != *"OI-01"* ]]
}

@test "refuses ticketed without a link" {
  _items '| OI-01 | T003 | defect | a | ticketed |'
  run bash "$CHECK" "$ITEMS"
  [ "$status" -eq 1 ]
  [[ "$output" == *"OI-01"* ]]
}

@test "refuses accepted without an operator" {
  _items '| OI-01 | T003 | defect | a | accepted |'
  run bash "$CHECK" "$ITEMS"
  [ "$status" -eq 1 ]
  [[ "$output" == *"OI-01"* ]]
}

@test "refuses a disposition that is none of the three" {
  _items '| OI-01 | T003 | defect | a | later |'
  run bash "$CHECK" "$ITEMS"
  [ "$status" -eq 1 ]
  [[ "$output" == *'OI-01: "later"'* ]]
}

@test "reads the disposition as the last column when the summary holds a pipe" {
  _items '| OI-01 | T003 | defect | a \| b | fixed |'
  run bash "$CHECK" "$ITEMS"
  [ "$status" -eq 0 ]
}

@test "a missing file, a path of none, or a file with no Disposition table runs as today" {
  run bash "$CHECK" "$MOCK_WORKSPACE/absent.md"
  [ "$status" -eq 0 ]
  run bash "$CHECK"
  [ "$status" -eq 0 ]
  printf '# Notes\n\n| a | b |\n| - | - |\n| x | y |\n' >"$ITEMS"
  run bash "$CHECK" "$ITEMS"
  [ "$status" -eq 0 ]
}

@test "rows in a table that is not the Disposition table are ignored" {
  _items '| OI-01 | T003 | defect | a | fixed |'
  printf '\n| Other | Col |\n| --- | --- |\n| row | |\n' >>"$ITEMS"
  run bash "$CHECK" "$ITEMS"
  [ "$status" -eq 0 ]
}

@test "a CRLF file is read like an LF one" {
  _items '| OI-01 | T003 | defect | a | fixed |' '| OI-02 | T004 | defect | b |  |'
  sed 's/$/\r/' "$ITEMS" >"$ITEMS.crlf"
  run bash "$CHECK" "$ITEMS.crlf"
  [ "$status" -eq 1 ]
  [[ "$output" == *"OI-02"* ]]
  [[ "$output" != *"OI-01"* ]]
}

@test "a word that merely starts with fixed or ticketed does not close a row" {
  _items '| OI-01 | T003 | defect | a | fixed-by-T9 |' '| OI-02 | T004 | defect | b | ticketedx https://x.test/1 |'
  run bash "$CHECK" "$ITEMS"
  [ "$status" -eq 1 ]
  [[ "$output" == *"OI-01"* ]]
  [[ "$output" == *"OI-02"* ]]
}

@test "fixed may carry a note after it" {
  _items '| OI-01 | T003 | defect | a | Fixed (commit abc123) |' '| OI-02 | T004 | defect | b | fixed: in T009 |'
  run bash "$CHECK" "$ITEMS"
  [ "$status" -eq 0 ]
}

@test "same input gives the same output" {
  _items '| OI-01 | T003 | defect | a |  |' '| OI-02 | T004 | defect | b |  |'
  run bash "$CHECK" "$ITEMS"
  first="$output"
  run bash "$CHECK" "$ITEMS"
  [ "$output" = "$first" ]
}
