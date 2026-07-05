#!/usr/bin/env bash
# Regression test for the `fail-on-warning` gate in the Format-check job.
#
# m1-fmt --check exits non-zero on would-reformat and syntax errors, but a parse
# WARNING (`<file>:<line>: warning: <message>`) exits 0 on its own. The
# fail-on-warning option is meant to turn every check's warnings into a build
# failure — the lint, typecheck and project jobs all honour it, but the fmt job
# originally ran a bare `m1-fmt --check` and ignored the input entirely, so a
# project whose only fmt findings were parse warnings passed even with
# fail-on-warning: true.
#
# The fix captures m1-fmt's output (folding stderr in, 2>&1, like the sibling
# gates), propagates its real exit via PIPESTATUS, then — when fail-on-warning is
# set — greps the captured output for the parse-warning line and fails.
#
# Two parts:
#   1. Static: assert check.yml's Format-check step honours FAIL_ON_WARNING
#      (captures + greps the warning line), matching its three siblings.
#   2. Behavioural: reproduce the gate shell against a fake m1-fmt that prints a
#      parse warning and exits 0, and assert the gate fails when
#      FAIL_ON_WARNING=true and passes when it is false.

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
# Extract the Format-check step body and assert it honours fail-on-warning.
awk '/^      - name: Format check \(m1-fmt --check\)$/{f=1} f{print} /^      - name: Show reformat diff$/{f=0}' \
  "$workflow" > "$tmp/fmt-step.txt"
[ -s "$tmp/fmt-step.txt" ] || fail "could not extract the 'Format check' step from check.yml"

grep -q 'FAIL_ON_WARNING' "$tmp/fmt-step.txt" \
  || fail "the Format-check step does not reference FAIL_ON_WARNING — it ignores fail-on-warning unlike its siblings"
grep -qE 'm1-fmt --check 2>&1 \| tee' "$tmp/fmt-step.txt" \
  || fail "the Format-check step does not capture m1-fmt output (2>&1 | tee) — it cannot inspect parse warnings"
grep -qE 'grep -qE .*warning: ' "$tmp/fmt-step.txt" \
  || fail "the Format-check step does not grep for m1-fmt's parse-warning line"
echo "ok: check.yml Format-check step honours fail-on-warning (captures + greps the warning line)"

# --- Part 2: behavioural ----------------------------------------------------
#
# Fake m1-fmt: emits a parse-warning line and exits 0 (a warning does not fail
# --check on its own), mirroring the real tool's warnings-only case.
faketool="$tmp/m1-fmt"
cat > "$faketool" <<'TOOL'
#!/bin/sh
echo "Demo.m1scr:42: warning: unexpected token" >&2
exit 0
TOOL
chmod +x "$faketool"
export PATH="$tmp:$PATH"

script="$tmp/Demo.m1scr"
: > "$script"
printf '%s' "$script" > "$tmp/m1-scripts.nul"
export RUNNER_TEMP="$tmp"

run_gate() {
  # $1 = value of FAIL_ON_WARNING (true/false). Returns the gate's exit code.
  local fow="$1"
  (
    set -uo pipefail
    FAIL_ON_WARNING="$fow"
    xargs -0 -a "$RUNNER_TEMP/m1-scripts.nul" m1-fmt --check 2>&1 | tee "$RUNNER_TEMP/m1-fmt.out"
    code=${PIPESTATUS[0]}
    if [ "$code" -ne 0 ]; then exit "$code"; fi
    if [ "$FAIL_ON_WARNING" = true ] && grep -qE '^.+:[0-9]+: warning: ' "$RUNNER_TEMP/m1-fmt.out"; then
      echo "::error::fail-on-warning: m1-fmt reported parse warnings"
      exit 1
    fi
  )
}

# With fail-on-warning true, the parse warning MUST fail the gate.
if run_gate true > "$tmp/gate.log" 2>&1; then
  echo "--- gate log ---" >&2; cat "$tmp/gate.log" >&2
  fail "fail-on-warning gate passed on a parse-warning fixture — it must FAIL"
fi
echo "ok: with fail-on-warning true, the fmt gate fails on a parse warning"

# With fail-on-warning false (the default), the same warning must NOT fail.
if ! run_gate false > "$tmp/gate.log" 2>&1; then
  echo "--- gate log ---" >&2; cat "$tmp/gate.log" >&2
  fail "the fmt gate failed on a parse warning with fail-on-warning false — warnings must only fail when opted in"
fi
echo "ok: with fail-on-warning false, a parse warning does not fail the fmt gate"

echo "PASS: the Format-check job honours fail-on-warning on m1-fmt parse warnings"
