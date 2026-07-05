#!/usr/bin/env bash
# Regression test for collect-scripts pruning the m1-ci checkout.
#
# Every check job in check.yml checks m1-ci out INTO the caller's workspace (at
# `.m1-ci`) to load its composite actions, BEFORE collect-scripts runs. With the
# default scripts-path "." an unpruned `find . -name '*.m1scr'` therefore swept
# m1-ci's OWN intentionally-broken test fixtures (tests/fixture-bad/Broken.m1scr,
# tests/fixture-typecheck-bad/T002.m1scr) into the caller's run — a guaranteed
# red fmt/lint/typecheck for EVERY zero-config consumer. The existing self-tests
# never caught it because they pin scripts-path to tests/fixture, not ".".
#
# The fix adds an `exclude-dir` input to collect-scripts (check.yml passes
# `.m1-ci`) that prunes the checkout by its real relative location.
#
# This test:
#   1. Static: collect-scripts declares/uses exclude-dir, and check.yml passes
#      `exclude-dir: .m1-ci` to every collect-scripts step.
#   2. Behavioural: reproduce the collect find against a scratch zero-config
#      layout (a real consumer script at the root + a `.m1-ci` checkout holding
#      broken fixtures) and prove the checkout's scripts are excluded while the
#      consumer's own script (including one with a space in its name) is kept —
#      and that WITHOUT the exclude the broken fixtures would be collected.

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
action="$repo_root/.github/actions/collect-scripts/action.yml"
workflow="$repo_root/.github/workflows/check.yml"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# --- Part 1: static ---------------------------------------------------------

grep -q 'exclude-dir:' "$action" \
  || fail "collect-scripts action does not declare an 'exclude-dir' input"
grep -q 'EXCLUDE_DIR' "$action" \
  || fail "collect-scripts action does not consume EXCLUDE_DIR in its find"

# Every collect-scripts invocation in check.yml must pass exclude-dir so no job
# can silently sweep the checkout back in. Count uses vs the exclude-dir args.
uses_count="$(grep -c 'uses: ./.m1-ci/.github/actions/collect-scripts' "$workflow" || true)"
excl_count="$(grep -c 'exclude-dir: .m1-ci' "$workflow" || true)"
[ "$uses_count" -ge 1 ] || fail "no collect-scripts uses found in check.yml"
[ "$excl_count" -ge "$uses_count" ] \
  || fail "check.yml has $uses_count collect-scripts use(s) but only $excl_count exclude-dir arg(s) — a job can sweep the .m1-ci checkout in"
echo "ok: check.yml passes exclude-dir to all $uses_count collect-scripts step(s)"

# --- Part 2: behavioural ----------------------------------------------------
#
# Reproduce the collect find (the prune shell from the action) exactly.
collect() {
  # $1 = workspace, $2 = SCRIPTS_PATH, $3 = EXCLUDE_DIR (may be empty).
  local ws="$1" SCRIPTS_PATH="$2" EXCLUDE_DIR="${3:-}" sp rel
  ( cd "$ws" || exit 1
    sp="${SCRIPTS_PATH%/}"; [ -n "$sp" ] || sp="$SCRIPTS_PATH"
    prune=()
    if [ -n "${EXCLUDE_DIR:-}" ]; then
      rel="$(realpath -m --relative-to="$sp" "$EXCLUDE_DIR")"
      case "$rel" in
        .. | ../*) : ;;
        *) prune=(-path "$sp/$rel" -prune -o) ;;
      esac
    fi
    find "$sp" "${prune[@]}" -type f -name '*.m1scr' -print0
  )
}

# Zero-config consumer layout: a real script at the workspace root, plus the
# m1-ci checkout (.m1-ci) holding the intentionally-broken fixtures.
ws="$tmp/work"
mkdir -p "$ws/Scripts" "$ws/.m1-ci/tests/fixture-bad" "$ws/.m1-ci/tests/fixture"
: > "$ws/Scripts/Root.m1scr"                                  # consumer script
: > "$ws/Scripts/Mission Critical 500Hz.m1scr"               # consumer script (spaces)
: > "$ws/.m1-ci/tests/fixture-bad/Broken.m1scr"              # m1-ci fixture (broken)
: > "$ws/.m1-ci/tests/fixture/Demo Update.m1scr"            # m1-ci fixture

# With the exclude, the .m1-ci checkout must be pruned and the consumer scripts kept.
mapfile -d '' got < <(collect "$ws" "." ".m1-ci")
printf '%s\0' "${got[@]}" | grep -qz 'Root.m1scr' \
  || fail "the consumer's Root.m1scr was not collected"
printf '%s\0' "${got[@]}" | grep -qz 'Mission Critical 500Hz.m1scr' \
  || fail "the consumer's spaced-name script was not collected"
if printf '%s\0' "${got[@]}" | grep -qz '\.m1-ci/'; then
  fail "a .m1-ci checkout script leaked into the collected set: ${got[*]}"
fi
echo "ok: zero-config collect keeps consumer scripts and prunes the .m1-ci checkout"

# Sanity: WITHOUT the exclude, the broken fixtures WOULD be collected (proving
# the layout reproduces the bug the exclude fixes).
mapfile -d '' unpruned < <(collect "$ws" "." "")
printf '%s\0' "${unpruned[@]}" | grep -qz '\.m1-ci/tests/fixture-bad/Broken.m1scr' \
  || fail "test scaffolding wrong: the broken fixture is not collected even without the exclude"
echo "ok: without the exclude the broken .m1-ci fixture is collected (bug reproduced)"

# A scripts-path that does NOT contain the checkout is unaffected: the exclude is
# a no-op (find never descends into a sibling .m1-ci).
mapfile -d '' sub < <(collect "$ws" "Scripts" ".m1-ci")
printf '%s\0' "${sub[@]}" | grep -qz 'Root.m1scr' \
  || fail "a subdir scripts-path lost the consumer script"
if printf '%s\0' "${sub[@]}" | grep -qz '\.m1-ci/'; then
  fail "a subdir scripts-path somehow collected a .m1-ci script"
fi
echo "ok: a subdir scripts-path is unaffected by the exclude"

echo "PASS: collect-scripts prunes the m1-ci checkout from a zero-config consumer's search"
