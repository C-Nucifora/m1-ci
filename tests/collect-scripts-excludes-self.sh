#!/usr/bin/env bash
# Regression test for the collect-scripts composite action
# (.github/actions/collect-scripts/action.yml, "Collect scripts" step).
#
# The reusable check.yml checks the CALLER's repo out at the workspace root,
# then checks m1-ci itself out into `path: .m1-ci` (a subdirectory of that
# root) so its composite actions resolve. With the default scripts-path "."
# the collect-scripts find walks the WHOLE workspace — including .m1-ci — and
# so harvests m1-ci's own deliberately-broken test fixtures
# (e.g. .m1-ci/tests/fixture-bad/Broken.m1scr,
# .m1-ci/tests/fixture-typecheck-bad/T002.m1scr). Those files are not the
# caller's, yet they fail the caller's fmt/lint/typecheck.
#
# The fix prunes the self-checkout: the find skips any `.m1-ci` directory. A
# caller who sets a real scripts-path subdir is unaffected — .m1-ci is a
# sibling of that subdir, never under it.
#
# This test:
#   1. Static: assert the action's find prunes a `.m1-ci` directory.
#   2. Behavioural: build a temp workspace with one legitimate script under
#      a/ and one broken fixture under .m1-ci/tests/fixture-bad/, run the
#      exact find logic from the action with SCRIPTS_PATH="." and assert the
#      NUL list has exactly one entry and nothing under .m1-ci/.

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
action="$repo_root/.github/actions/collect-scripts/action.yml"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# --- Part 1: static ---------------------------------------------------------
#
# The action's find must prune the .m1-ci self-checkout. Before the fix the
# find had no -prune clause and descended into .m1-ci.
# shellcheck disable=SC2016  # match the literal find text in the YAML
grep -qE '\-type d -name \.m1-ci -prune' "$action" \
  || fail "collect-scripts find does not prune the .m1-ci self-checkout"

echo "ok: collect-scripts find prunes the .m1-ci self-checkout"

# --- Part 2: behavioural ----------------------------------------------------
#
# Reproduce the exact find the action runs and assert the self-checkout is
# excluded. This is the contract check.yml relies on.

ws="$tmp/workspace"
mkdir -p "$ws/a" "$ws/.m1-ci/tests/fixture-bad" "$ws/.m1-ci/tests/fixture-typecheck-bad"
: > "$ws/a/foo.m1scr"                                   # the caller's real script
: > "$ws/.m1-ci/tests/fixture-bad/Broken.m1scr"         # m1-ci's own broken fixture
: > "$ws/.m1-ci/tests/fixture-typecheck-bad/T002.m1scr" # m1-ci's own broken fixture

export RUNNER_TEMP="$tmp/runner-temp"
mkdir -p "$RUNNER_TEMP"

# The exact find from the action, run from the workspace with scripts-path ".".
(
  cd "$ws"
  SCRIPTS_PATH="."
  find "$SCRIPTS_PATH" -type d -name .m1-ci -prune -o -type f -name '*.m1scr' -print0 \
    > "$RUNNER_TEMP/m1-scripts.nul"
)

# Count NUL terminators (robust for names with spaces/newlines).
count="$(tr -dc '\0' < "$RUNNER_TEMP/m1-scripts.nul" | wc -c | tr -d ' ')"
[ "$count" -eq 1 ] \
  || fail "expected exactly 1 collected script, got $count (the .m1-ci fixtures leaked in)"

# No collected path may live under .m1-ci/.
while IFS= read -r -d '' path; do
  case "$path" in
    *.m1-ci/*|./.m1-ci/*|.m1-ci/*)
      fail "a path under the self-checkout was collected: '$path'" ;;
  esac
done < "$RUNNER_TEMP/m1-scripts.nul"

echo "ok: only the caller's script is collected; nothing under .m1-ci/"

echo "PASS: collect-scripts excludes the .m1-ci self-checkout"
