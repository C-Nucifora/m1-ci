#!/usr/bin/env bash
# Regression test for the `fail-on-warning` gate in the Lint job of check.yml.
#
# m1-lint exits 0 on warning-severity findings by default (only errors are
# non-zero), so the reusable workflow's `fail-on-warning: true` option exists to
# turn warnings into a build failure too. The Lint step implements it by
# capturing m1-lint's output to a file and grepping that file for `warning[`.
#
# THE BUG this test guards against: m1-lint writes its human-format diagnostics
# to STDERR, not stdout (m1-lint src/main.rs: `Format::Human => eprint!(...)`).
# If the step captures only stdout (`m1-lint ... | tee FILE`, no `2>&1`), the
# captured FILE is empty, the `grep -q 'warning\['` never matches, and a project
# with warnings-only findings PASSES the gate even with fail-on-warning: true —
# silently defeating the option. The capture MUST fold stderr in (`2>&1`).
#
# Why neither existing self-test catches it:
#   * self-test-pass uses fail-on-warning: true on a CLEAN fixture — no warnings,
#     so grep-on-empty correctly finds nothing and the job (correctly) passes.
#   * self-test-fail asserts an ERROR fixture exits non-zero — that path is the
#     `code -ne 0` gate, not the fail-on-warning grep.
# Only a warnings-only fixture, run with fail-on-warning: true, exercises the
# grep — and only if the warning text was actually captured.
#
# Two parts:
#   1. Static: assert check.yml's Lint step capture redirects stderr (`2>&1`)
#      into the tee'd file, so the grep can see m1-lint's (stderr) diagnostics.
#   2. Behavioural: reproduce the gate's exact "capture + grep" shell against a
#      fake m1-lint that prints a `warning[...]` diagnostic to STDERR and exits
#      0 (mirroring real m1-lint on a warnings-only project), and assert the
#      gate exits non-zero when FAIL_ON_WARNING=true. The pre-fix stdout-only
#      capture makes this assertion fail; the `2>&1` fix makes it pass.

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
workflow="$repo_root/.github/workflows/check.yml"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# --- Part 1: static ---------------------------------------------------------
#
# The lint-gate capture must merge stderr into the tee'd file. m1-lint's
# human diagnostics go to stderr, so a stdout-only capture leaves the file
# empty and the warning grep can never match.
grep -qE 'm1-lint "\$\{bl\[@\]\}" 2>&1 \| tee' "$workflow" \
  || fail "the Lint gate capture does not redirect stderr (2>&1) into the tee'd file — m1-lint's warning diagnostics (stderr) would be lost and fail-on-warning would never fire"
echo "ok: check.yml Lint gate folds stderr into the captured output (2>&1)"

# --- Part 2: behavioural ----------------------------------------------------
#
# Fake m1-lint: prints a warning-severity diagnostic to STDERR (as the real
# tool does) and exits 0 (warnings don't fail by default). This is the exact
# "warnings-only project" shape the fail-on-warning option targets.
faketool="$tmp/m1-lint"
cat > "$faketool" <<'TOOL'
#!/bin/sh
# Human-format diagnostics go to stderr in real m1-lint (src/main.rs).
echo "Demo.m1scr:1:1: warning[L001]: line exceeds the configured maximum length" >&2
# Warnings do not fail the process by default.
exit 0
TOOL
chmod +x "$faketool"
export PATH="$tmp:$PATH"

script="$tmp/Demo.m1scr"
: > "$script"
printf '%s' "$script" > "$tmp/m1-scripts.nul" # NUL-list with a single entry (no trailing NUL needed for one arg)

# Reproduce the Lint gate shell verbatim, parameterised on the capture form so
# this test pins the behaviour, not a copy of the line. RUNNER_TEMP and the
# fail-on-warning env mirror the workflow.
export RUNNER_TEMP="$tmp"

run_gate() {
  # $1 = "stderr-merged" (the fix) or "stdout-only" (the bug). Returns the
  # gate's exit code.
  local capture="$1"
  (
    set -uo pipefail
    FAIL_ON_WARNING=true
    LINT_BASELINE=""
    bl=()
    if [ -n "$LINT_BASELINE" ]; then
      bl=(--baseline "$LINT_BASELINE")
    fi
    if [ "$capture" = stderr-merged ]; then
      xargs -0 -a "$RUNNER_TEMP/m1-scripts.nul" m1-lint "${bl[@]}" 2>&1 | tee "$RUNNER_TEMP/m1-lint.out"
    else
      xargs -0 -a "$RUNNER_TEMP/m1-scripts.nul" m1-lint "${bl[@]}" | tee "$RUNNER_TEMP/m1-lint.out"
    fi
    code=${PIPESTATUS[0]}
    if [ "$code" -ne 0 ]; then exit "$code"; fi
    if [ "$FAIL_ON_WARNING" = true ] && grep -q 'warning\[' "$RUNNER_TEMP/m1-lint.out"; then
      echo "::error::fail-on-warning: m1-lint reported warning-severity diagnostics"
      exit 1
    fi
  )
}

# The fix (2>&1) MUST make the gate fail on the warnings-only fixture.
if run_gate stderr-merged > "$tmp/gate.log" 2>&1; then
  echo "--- gate log ---" >&2; cat "$tmp/gate.log" >&2
  fail "fail-on-warning gate passed on a warnings-only fixture — stderr-merged capture must make it FAIL"
fi
grep -q 'warning\[' "$tmp/m1-lint.out" \
  || fail "stderr-merged capture did not record the warning diagnostic in m1-lint.out"
echo "ok: with stderr merged, the fail-on-warning gate correctly fails on a warnings-only project"

# Cross-check that the bug is real: the stdout-only capture (no 2>&1) leaves the
# file empty, so the gate wrongly PASSES. This documents exactly what the fix
# prevents (it is not an assertion on the workflow, just a demonstration).
if run_gate stdout-only > /dev/null 2>&1; then
  if [ -s "$tmp/m1-lint.out" ]; then
    fail "stdout-only capture unexpectedly recorded output — the test's fake tool is wrong"
  fi
  echo "ok: confirmed the pre-fix stdout-only capture leaves m1-lint.out empty and the gate wrongly passes"
else
  fail "stdout-only capture made the gate fail — the bug premise (stderr-only diagnostics) no longer holds; revisit this test"
fi

echo "PASS: fail-on-warning gate captures m1-lint's stderr diagnostics and fails on warnings-only projects"
