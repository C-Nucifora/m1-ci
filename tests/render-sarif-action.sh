#!/usr/bin/env bash
# Regression test for the render-sarif composite action.
#
# check.yml used to inline two near-identical "Render SARIF" steps, one in the
# lint job and one in the typecheck job. The two bodies were structurally
# identical — same `set -uo pipefail`, the same `jq -s` xargs-batch aggregation,
# the same `jq -e .runs` structural guard, the same "SARIF document is still
# complete on a non-zero tool exit" rationale — differing only in the tool name
# (m1-lint / m1-typecheck), the output filename, and the optional extra argument
# (--baseline <path> for lint, --project <path> for typecheck). That is one
# carefully reasoned SARIF-aggregation contract written twice, so tightening the
# empty/multi-document detection (or the aggregation) had to be edited in two
# identical places and could silently drift.
#
# The dedup hoists the render body into a single composite action,
# .github/actions/render-sarif, parameterised by `tool` and an optional
# `extra-flag` + `extra-value` pair. The lint and typecheck jobs each `uses:` it
# instead of inlining the heredoc, so the SARIF aggregation + structural guard
# has exactly ONE canonical source.
#
# This test:
#   1. Static: the composite action exists, is a composite, takes a `tool`
#      input, and carries the aggregating render (jq -s) + structural guard
#      (jq -e .runs).
#   2. Behavioural: run the action's render shell against a fake tool that splits
#      across multiple xargs batches (and exits non-zero on findings, as the
#      real tools do) and assert it produces ONE valid SARIF document carrying
#      every batch's runs — and that its guard rejects empty/crash output where a
#      bare non-empty ([ -s ]) test would not.
#   3. Static (dedup): check.yml no longer inlines the SARIF render heredoc — the
#      lint and typecheck jobs reference the composite action — so the
#      aggregation + guard live in exactly one place and cannot drift.

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
action="$repo_root/.github/actions/render-sarif/action.yml"
workflow="$repo_root/.github/workflows/check.yml"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 || fail "jq is required for this test (preinstalled on ubuntu-latest runners)"
command -v python3 >/dev/null 2>&1 || fail "python3 is required (preinstalled on ubuntu-latest runners)"

# --- Part 1: the composite action exists and has the right shape -------------

[ -f "$action" ] || fail "missing composite action: .github/actions/render-sarif/action.yml"

python3 - "$action" <<'PY'
import sys

# Avoid a YAML-library dependency (PyYAML is not guaranteed preinstalled); the
# structural assertions below are intentionally textual but specific.
path = sys.argv[1]
with open(path, encoding="utf-8") as fh:
    text = fh.read()

if "using: composite" not in text:
    sys.exit("render-sarif action is not a composite action (no 'using: composite')")
if "tool:" not in text:
    sys.exit("render-sarif action does not declare a 'tool' input")
if "jq -s" not in text:
    sys.exit("render-sarif action does not aggregate xargs batches (expected a 'jq -s')")
if "jq -e" not in text or ".runs" not in text:
    sys.exit("render-sarif action does not validate the document structure (expected 'jq -e ... .runs')")
print("ok: render-sarif is a composite action with a 'tool' input that aggregates (jq -s) and validates (jq -e .runs)")
PY

# Extract the action's render shell so we can RUN it. The action's run: body is
# expected to read its inputs as env vars (INPUT_<NAME> / the step's env:
# mapping) and aggregate the tool's per-batch SARIF into one document at
# "$RUNNER_TEMP/<basename>.sarif". Pull the run: script out of the composite step
# and drive it directly.
runner_script="$tmp/run.sh"
python3 - "$action" "$runner_script" <<'PY'
import sys

action, out = sys.argv[1], sys.argv[2]
with open(action, encoding="utf-8") as fh:
    lines = fh.readlines()

# Find the composite step's `run: |` block and capture its indented body.
start = None
run_indent = None
for i, line in enumerate(lines):
    stripped = line.strip()
    if stripped == "run: |" or stripped == "run: |-" or stripped.startswith("run: |"):
        start = i + 1
        run_indent = len(line) - len(line.lstrip(" "))
        break
if start is None:
    sys.exit("could not find a 'run: |' block in the render-sarif action")

body = []
for j in range(start, len(lines)):
    ln = lines[j]
    if ln.strip() == "":
        body.append("")
        continue
    cur_indent = len(ln) - len(ln.lstrip(" "))
    if cur_indent <= run_indent:
        break
    body.append(ln.rstrip("\n"))

# Strip the common indentation of the run block.
nonempty = [b for b in body if b.strip()]
common = min((len(b) - len(b.lstrip(" ")) for b in nonempty), default=0)
script = "\n".join(b[common:] if b.strip() else "" for b in body)

# Normalise any templated ${{ inputs.<name> }} references to the env vars the
# harness below provides, so the same body runs either way.
for name, env in (
    ("tool", "INPUT_TOOL"),
    ("extra-flag", "INPUT_EXTRA_FLAG"),
    ("extra-value", "INPUT_EXTRA_VALUE"),
):
    script = script.replace("${{ inputs.%s }}" % name, "$%s" % env)

with open(out, "w", encoding="utf-8") as fh:
    fh.write("#!/usr/bin/env bash\n")
    fh.write(script)
    fh.write("\n")
print("extracted the action run-body into a standalone script", file=sys.stderr)
PY

chmod +x "$runner_script"

# A fake tool standing in for m1-lint/m1-typecheck --format sarif: it emits one
# complete SARIF document per invocation, exiting non-zero (as the real tools do
# when there are findings — the render must NOT treat that as a failure). It
# writes each of its argv words on its own line to a side file (one record per
# invocation, NUL-separated) so we can assert the extra flag+value are forwarded
# as SEPARATE words and a spaced value stays ONE argument.
faketool="$tmp/m1-lint"
cat > "$faketool" <<TOOL
#!/bin/sh
for a in "\$@"; do printf '%s\n' "\$a"; done >> "$tmp/argv.log"
printf '\0' >> "$tmp/argv.log"
echo '{"version":"2.1.0","\$schema":"https://json.schemastore.org/sarif-2.1.0.json","runs":[{"tool":{"driver":{"name":"fake","rules":[{"id":"L010"}]}},"results":[{"ruleId":"L010"}]}]}'
exit 1
TOOL
chmod +x "$faketool"

# Build a NUL-delimited list large enough to force xargs to split into >1 batch
# (the same shape as a real M1 vehicle project: many scripts, long spaced names).
nul="$tmp/m1-scripts.nul"
python3 - "$nul" <<'PY'
import sys
with open(sys.argv[1], "wb") as f:
    for i in range(2400):
        f.write(("UQR-EV/01.00/Scripts/Mission Critical Transceive Subsystem %04d.m1scr" % i).encode())
        f.write(b"\0")
PY

# Sanity: confirm the list really does force more than one xargs batch, otherwise
# the behavioural test below would pass vacuously.
batches="$(PATH="$tmp:$PATH" xargs -0 -a "$nul" m1-lint 2>/dev/null | grep -c '"version":"2.1.0"' || true)"
[ "$batches" -ge 2 ] || fail "test setup did not cross the xargs buffer (got $batches batch(es)); raise the path count"
echo "setup: xargs splits the list into $batches batches (each emits its own SARIF document)"

# --- Part 2: behavioural — the action renders one valid aggregated document --

# Drive the extracted action body with the fake tool on PATH, passing an
# extra flag + value (with a space in the value) to prove it is forwarded to the
# tool as ONE argument. RUNNER_TEMP points at our tmp so the action writes
# m1-lint.sarif there.
out="$tmp/m1-lint.sarif"
PATH="$tmp:$PATH" RUNNER_TEMP="$tmp" \
  INPUT_TOOL="m1-lint" INPUT_EXTRA_FLAG="--baseline" INPUT_EXTRA_VALUE="base line.json" \
  TOOL="m1-lint" EXTRA_FLAG="--baseline" EXTRA_VALUE="base line.json" \
  bash "$runner_script" >/dev/null 2>"$tmp/err" || {
    echo "--- stderr ---" >&2
    cat "$tmp/err" >&2
    fail "render-sarif action shell failed (it must tolerate the tool's non-zero findings exit)"
  }

[ -f "$out" ] || fail "render-sarif did not write \$RUNNER_TEMP/m1-lint.sarif"

# 2a. Exactly one valid JSON document on disk.
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$out" \
  || { echo "--- rendered file ---" >&2; cat "$out" >&2; fail "render-sarif output is not a single valid JSON document"; }
echo "ok: render-sarif produced exactly one valid JSON document"

# 2b. Valid SARIF carrying EVERY batch's runs.
runs="$(jq '.runs | length' "$out")"
[ "$runs" = "$batches" ] || fail "expected $batches runs (one per batch) in the aggregated SARIF, got $runs"
jq -e '.version == "2.1.0"' "$out" >/dev/null || fail "aggregated SARIF lost its version field"
echo "ok: aggregated SARIF has version 2.1.0 and all $runs batch runs"

# 2c. The extra flag+value were forwarded to the tool as separate argv words,
#     and the spaced value survived as ONE argument (its own line in argv.log).
grep -qxF -- '--baseline' "$tmp/argv.log" \
  || { echo "--- argv.log ---" >&2; cat "$tmp/argv.log" >&2; fail "render-sarif did not forward the --baseline flag to the tool"; }
grep -qxF -- 'base line.json' "$tmp/argv.log" \
  || { echo "--- argv.log ---" >&2; cat "$tmp/argv.log" >&2; fail "render-sarif did not forward the spaced baseline value as ONE argument"; }
# --format and sarif are always passed (as two argv words from the action).
if ! grep -qxF -- '--format' "$tmp/argv.log" || ! grep -qxF -- 'sarif' "$tmp/argv.log"; then
  fail "render-sarif did not pass '--format sarif' to the tool"
fi
echo "ok: render-sarif forwards the extra flag+value (spaced value intact) and --format sarif"

# 2d. The structural guard rejects empty/crash output where a bare [ -s ] would
#     not. Re-run with a tool that emits NOTHING and exits non-zero (a crash):
#     the action must fail rather than upload an empty/invalid document.
crashtool="$tmp/m1-typecheck"
cat > "$crashtool" <<'TOOL'
#!/bin/sh
exit 2
TOOL
chmod +x "$crashtool"
if PATH="$tmp:$PATH" RUNNER_TEMP="$tmp" \
   INPUT_TOOL="m1-typecheck" INPUT_EXTRA_FLAG="" INPUT_EXTRA_VALUE="" \
   TOOL="m1-typecheck" EXTRA_FLAG="" EXTRA_VALUE="" \
   bash "$runner_script" >/dev/null 2>&1; then
  fail "render-sarif accepted empty/crash output — its structural guard must fail when no valid SARIF is produced"
fi
echo "ok: render-sarif fails on empty/crash output (structural guard, not a bare non-empty test)"

# --- Part 3: dedup — check.yml references the action, no inline render heredoc -

# Both the lint and typecheck render steps must delegate to the composite action.
uses_count="$(grep -cE 'uses: \./\.m1-ci/\.github/actions/render-sarif' "$workflow" || true)"
[ "$uses_count" -eq 2 ] \
  || fail "expected both SARIF render steps to use the render-sarif action, found $uses_count 'uses:' references"
echo "ok: check.yml uses ./.m1-ci/.github/actions/render-sarif in both the lint and typecheck jobs"

# The SARIF aggregation must no longer be inlined in check.yml — that is the
# whole point of the dedup (one canonical source). The byte signatures were the
# `jq -s` aggregation and the `jq -e ... .runs` structural guard.
if grep -qE 'jq -s ' "$workflow"; then
  fail "check.yml still inlines the 'jq -s' SARIF aggregation; it should live only in the render-sarif action"
fi
if grep -qE 'jq -e .*\.runs' "$workflow"; then
  fail "check.yml still inlines the 'jq -e .runs' SARIF guard; it should live only in the render-sarif action"
fi
echo "ok: check.yml no longer inlines the SARIF render (single canonical source in the action)"

echo "PASS: render-sarif-action"
