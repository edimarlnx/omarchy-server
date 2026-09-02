#!/bin/bash

# Assertions shared by the shell tests, sourced rather than run. Deliberately
# the same names and the same "ok -" / "not ok -" output as upstream's
# test/shell.d/base-test.sh, so a person reading either run reads the same
# thing.

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  echo "source test/shell.d/base-test.sh from a shell test; do not run it directly" >&2
  exit 1
fi

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
export ROOT

# The profile's runtime commands, which is what these tests exercise.
RUNTIME_BIN="$ROOT/profile/server/overlay/runtime/bin"
export RUNTIME_BIN

pass() {
  printf 'ok - %s\n' "$1"
}

fail() {
  local description="$1" detail="${2:-}"

  [[ -n $detail ]] && printf '%s\n' "$detail" >&2
  printf 'not ok - %s\n' "$description" >&2
  exit 1
}

assert() {
  local condition="$1" description="$2" detail="${3:-}"

  [[ $condition == 1 ]] || fail "$description" "$detail"
  pass "$description"
}

assert_equal() {
  local actual="$1" expected="$2" description="$3"

  [[ $actual == "$expected" ]] ||
    fail "$description" "expected: $expected"$'\n'"actual:   $actual"
  pass "$description"
}

assert_contains() {
  local haystack="$1" needle="$2" description="$3"

  [[ $haystack == *"$needle"* ]] ||
    fail "$description" "expected to contain: $needle"$'\n'"actual:"$'\n'"$haystack"
  pass "$description"
}

assert_not_contains() {
  local haystack="$1" needle="$2" description="$3"

  [[ $haystack != *"$needle"* ]] ||
    fail "$description" "expected NOT to contain: $needle"$'\n'"actual:"$'\n'"$haystack"
  pass "$description"
}

# A throwaway directory, removed when the test file exits however it exits --
# including through fail(), which is why the trap and not a line at the end.
make_temp_dir() {
  local dir
  dir=$(mktemp -d)
  # shellcheck disable=SC2064 -- $dir is expanded now on purpose.
  trap "rm -rf '$dir'" EXIT
  printf '%s' "$dir"
}
