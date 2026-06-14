#!/usr/bin/env bash
# Regression test for the `lint-baseline` input in check.yml.
#
# m1-lint ships `--baseline FILE` / `--write-baseline FILE` — its README calls
# baselines "the adoption path" for a legacy codebase: snapshot the current
# findings once with --write-baseline, commit the file, then later runs with
# --baseline report only NEW regressions. A project with pre-existing findings
# can turn the lint gate ON without facing a wall of unrelated failures.
#
# The reusable workflow must let a consumer reach that path: expose a
# `lint-baseline` input and, when it is non-empty, append
# `--baseline "<file>"` to BOTH the Lint step and the Render SARIF step (so a
# finding suppressed in the gate is also suppressed in the GitHub code-scanning
# alerts — otherwise the Security tab would resurface exactly what the gate
# hides). Empty (the default) preserves gate-on-all-findings behaviour.
#
# This test has two parts:
#   1. Static: assert check.yml declares the input, plumbs it through to both
#      the lint and the SARIF-render m1-lint invocations, and that the example
#      + README document it.
#   2. Behavioural: drive the same "append --baseline only when non-empty" shell
#      the workflow uses against a fake m1-lint, proving an empty value runs the
#      tool with no extra flag and a non-empty value passes --baseline FILE.

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
workflow="$repo_root/.github/workflows/check.yml"
example="$repo_root/examples/check.yml"
readme="$repo_root/README.md"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# --- Part 1: static ---------------------------------------------------------

# 1a. The input is declared.
grep -qE '^[[:space:]]+lint-baseline:' "$workflow" \
  || fail "check.yml does not declare a 'lint-baseline' input"

# 1b. The input is wired into the Lint step's environment so the step's shell
#     can read it (the run: blocks reference env vars, not \${{ inputs.* }}).
grep -qE 'LINT_BASELINE:[[:space:]]*\$\{\{[[:space:]]*inputs\.lint-baseline' "$workflow" \
  || fail "check.yml does not expose inputs.lint-baseline as the LINT_BASELINE env var"

# 1c. Both m1-lint invocations (the gate AND the SARIF render) append
#     --baseline when the value is non-empty. Assert each invocation is fed the
#     assembled baseline argument array — count the occurrences so a future
#     refactor can't quietly drop one and let suppressed findings resurface as
#     code-scanning alerts.
appends="$(grep -cE '\-\-baseline "\$LINT_BASELINE"' "$workflow" || true)"
[ "$appends" -ge 2 ] \
  || fail "expected --baseline \"\$LINT_BASELINE\" in BOTH the lint gate and the SARIF render (found $appends)"

# 1d. Documented for consumers: README input mention + commented example knob.
grep -qi 'lint-baseline' "$readme" \
  || fail "README.md does not mention the lint-baseline input"
grep -qE '^[[:space:]]*#[[:space:]]*lint-baseline:' "$example" \
  || fail "examples/check.yml does not show the lint-baseline knob (commented out)"

echo "ok: check.yml declares lint-baseline, plumbs it to both m1-lint runs, and it is documented"

# --- Part 2: behavioural ----------------------------------------------------
#
# Reproduce the step's "append --baseline only when LINT_BASELINE is non-empty"
# logic against a fake m1-lint that records the argv it was called with. This is
# the exact shell shape the workflow uses (a bash array conditionally seeded).

faketool="$tmp/m1-lint"
cat > "$faketool" <<'TOOL'
#!/bin/sh
# Record every argument, one per line, so the test can assert on them.
printf '%s\n' "$@" > "$RECORD"
exit 0
TOOL
chmod +x "$faketool"
export PATH="$tmp:$PATH"

# One script to lint.
script="$tmp/Demo.m1scr"
: > "$script"

run_case() {
  # $1 = LINT_BASELINE value; uses the same array-build the workflow step uses.
  local LINT_BASELINE="$1"
  export RECORD="$tmp/argv.out"
  : > "$RECORD"
  bl=()
  if [ -n "$LINT_BASELINE" ]; then
    bl=(--baseline "$LINT_BASELINE")
  fi
  m1-lint "${bl[@]}" "$script"
}

# Empty -> no --baseline flag at all (gate-on-all-findings preserved).
run_case ""
if grep -qx -- '--baseline' "$tmp/argv.out"; then
  echo "--- argv ---" >&2; cat "$tmp/argv.out" >&2
  fail "empty lint-baseline must NOT pass --baseline"
fi
echo "ok: empty lint-baseline runs m1-lint with no --baseline flag"

# Non-empty -> --baseline FILE passed through verbatim.
run_case ".m1lint-baseline.json"
grep -qx -- '--baseline' "$tmp/argv.out" \
  || { echo "--- argv ---" >&2; cat "$tmp/argv.out" >&2; fail "non-empty lint-baseline must pass --baseline"; }
grep -qx -- '.m1lint-baseline.json' "$tmp/argv.out" \
  || { echo "--- argv ---" >&2; cat "$tmp/argv.out" >&2; fail "non-empty lint-baseline must pass the baseline FILE path"; }
echo "ok: non-empty lint-baseline passes --baseline <file> to m1-lint"

echo "PASS: lint-baseline input is declared, plumbed to both m1-lint runs, documented, and append-only when set"
