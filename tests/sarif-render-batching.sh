#!/usr/bin/env bash
# Regression test for the SARIF render steps in check.yml.
#
# The two "Render SARIF" steps feed the NUL-delimited script list to the tool
# via `xargs -0`. xargs invokes the tool ONCE PER BATCH, and its command buffer
# is only ~128 KB (xargs --show-limits), well under ARG_MAX. A large M1 project
# (enough scripts with long, spaced names to cross 128 KB) makes xargs run the
# tool more than once. Each invocation emits its own COMPLETE SARIF 2.1.0
# document, so a naive `> out.sarif` redirect ends up holding several root JSON
# objects concatenated back-to-back — invalid JSON / invalid SARIF that a
# non-empty check ([ -s ]) happily lets through to upload-sarif.
#
# This test has two parts:
#   1. Behavioural: drive the aggregating render pipeline against a fake tool
#      that splits across multiple xargs batches, and assert the result is a
#      single valid SARIF document carrying every batch's runs.
#   2. Static: assert check.yml actually uses that aggregating form and the
#      structural guard, so the workflow can't silently regress to the broken
#      unaggregated `> out.sarif` + `[ -s ]` shape.

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
workflow="$repo_root/.github/workflows/check.yml"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 || fail "jq is required for this test (preinstalled on ubuntu-latest runners)"

# A fake tool standing in for m1-lint/m1-typecheck --format sarif: it emits one
# complete SARIF document per invocation, exiting non-zero (as the real tools do
# when there are findings — the render step must NOT treat that as failure).
faketool="$tmp/faketool"
cat > "$faketool" <<'TOOL'
#!/bin/sh
echo '{"version":"2.1.0","$schema":"https://json.schemastore.org/sarif-2.1.0.json","runs":[{"tool":{"driver":{"name":"fake","rules":[{"id":"L010"}]}},"results":[{"ruleId":"L010"}]}]}'
exit 1
TOOL
chmod +x "$faketool"

# Build a NUL-delimited list large enough to force xargs to split into >1 batch.
# xargs's command buffer is 128 KB; ~2400 paths of ~70 chars clears it with room
# to spare on any runner. (The same shape as a real M1 vehicle project: many
# scripts, long spaced names.)
nul="$tmp/m1-scripts.nul"
python3 - "$nul" <<'PY'
import sys
with open(sys.argv[1], "wb") as f:
    for i in range(2400):
        f.write(("UQR-EV/01.00/Scripts/Mission Critical Transceive Subsystem %04d.m1scr" % i).encode())
        f.write(b"\0")
PY

# Sanity: confirm the list really does force more than one xargs batch with this
# tool, otherwise the behavioural test below would pass vacuously.
batches="$(xargs -0 -a "$nul" "$faketool" 2>/dev/null | grep -c '"version":"2.1.0"' || true)"
[ "$batches" -ge 2 ] || fail "test setup did not cross the xargs buffer (got $batches batch(es)); raise the path count"
echo "setup: xargs splits the list into $batches batches (each emits its own SARIF document)"

# --- Part 1: behavioural ---------------------------------------------------
#
# The aggregating render: collapse every batch's document into one. This is the
# pipeline check.yml runs; jq -s slurps all batch docs, keeps the first's
# top-level shape, and concatenates their `runs` arrays. The tool exits non-zero
# on findings, so (like the workflow step, which runs without `set -e`) we must
# not let that abort us — only a missing/malformed document is a real failure.
out="$tmp/m1-lint.sarif"
xargs -0 -a "$nul" "$faketool" --format sarif \
  | jq -s '.[0] * {runs: (map(.runs) | add)}' > "$out" || true

# Old-style unaggregated render, to prove the test would have caught the bug.
bad="$tmp/bad.sarif"
xargs -0 -a "$nul" "$faketool" --format sarif > "$bad" || true
if python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$bad" 2>/dev/null; then
  fail "unaggregated render unexpectedly produced valid JSON — test cannot distinguish the bug"
fi
[ -s "$bad" ] || fail "unaggregated render produced an empty file — expected a non-empty concatenation"
echo "ok: the unaggregated render IS broken (multi-doc, non-empty) — the bug this guards against"

# 1a. Exactly one valid JSON document on disk.
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$out" \
  || { echo "--- rendered file ---" >&2; cat "$out" >&2; fail "aggregated render is not a single valid JSON document"; }
echo "ok: aggregated render is exactly one valid JSON document"

# 1b. Valid SARIF carrying EVERY batch's runs.
runs="$(jq '.runs | length' "$out")"
[ "$runs" = "$batches" ] || fail "expected $batches runs (one per batch) in the aggregated SARIF, got $runs"
jq -e '.version == "2.1.0"' "$out" >/dev/null || fail "aggregated SARIF lost its version field"
echo "ok: aggregated SARIF has version 2.1.0 and all $runs batch runs"

# 1c. The structural guard accepts the good document and rejects empty/crash
#     output (where a bare `[ -s ]` non-empty test would not help).
jq -e '.runs' "$out" >/dev/null || fail "structural guard rejected a valid aggregated SARIF"
empty="$tmp/empty.sarif"; : > "$empty"
if jq -e '.runs' "$empty" >/dev/null 2>&1; then fail "structural guard accepted an empty render"; fi
echo "ok: jq -e .runs guard accepts the valid document and rejects empty output"

# --- Part 2: static ---------------------------------------------------------
#
# Assert check.yml uses the aggregating form and the structural guard, so it
# can't regress to the broken shape.
if grep -qE 'xargs -0 -a .*--format sarif.* > .*\.sarif"' "$workflow" \
   && ! grep -qE 'jq -s ' "$workflow"; then
  fail "check.yml redirects the SARIF render straight to a file without aggregating xargs batches (jq -s). A large project splits across batches and concatenates multiple SARIF documents."
fi
grep -qE 'jq -s ' "$workflow" \
  || fail "check.yml SARIF render does not aggregate batches (expected a 'jq -s' over the xargs output)"
# shellcheck disable=SC2016  # this is a grep regex literal; $RUNNER_TEMP must stay unexpanded
if grep -qE 'if ! \[ -s "\$RUNNER_TEMP/m1-(lint|typecheck).sarif" \]' "$workflow"; then
  fail "check.yml still guards the SARIF render with a non-empty-only test ([ -s ]); a concatenated multi-document file passes it. Validate the document instead (e.g. jq -e .runs)."
fi
grep -qE 'jq -e .*\.runs' "$workflow" \
  || fail "check.yml SARIF guard does not validate the document structure (expected 'jq -e ... .runs')"
echo "ok: check.yml uses the aggregating render (jq -s) and the structural guard (jq -e .runs)"

echo "PASS: SARIF render aggregates xargs batches into a single valid document and validates it"
