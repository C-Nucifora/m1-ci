#!/usr/bin/env bash
# Regression test for the fmt-job diff feedback.
#
# When the Format-check job fails, the only line m1-fmt --check emits is
# `<file>: would reformat` — a file-level "this is misformatted" with NO
# indication of WHAT is wrong or how it should look. The lint and typecheck
# jobs, by contrast, surface line-accurate `file:line:col: severity[CODE]: msg`
# annotations. A developer staring at a red fmt job has to check the branch out
# and run m1-fmt locally to see the difference — defeating inline CI feedback.
#
# m1-fmt ships a `--diff` flag that prints the exact unified diff of the
# reformatting. The fix lands that diff in the CI log on failure, so the fix is
# self-evident from the run alone. This test asserts check.yml's fmt job carries
# a guarded "Show reformat diff" step that:
#   1. runs m1-fmt --diff over the SAME collected script list (the .nul file),
#   2. is gated on `if: failure()` and a non-zero collected count (so it only
#      runs when the --check step actually failed and there were scripts),
#   3. swallows its own exit status (`|| true`) so the diff step itself stays
#      green — the failing --check step above already carries the red exit, and
#      m1-fmt --diff exits non-zero on syntax errors (which must not double-fail
#      or be reported as the diff step's own failure),
#   4. comes AFTER the `m1-fmt --check` step (so the check's failure() is what
#      gates it), and stays scoped to the fmt job.

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
workflow="$repo_root/.github/workflows/check.yml"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

command -v python3 >/dev/null 2>&1 || fail "python3 is required for this test (preinstalled on ubuntu-latest runners)"

python3 - "$workflow" <<'PY'
import re
import sys

workflow = sys.argv[1]
with open(workflow, encoding="utf-8") as fh:
    text = fh.read()
lines = text.splitlines()

# --- Locate the fmt job and its bounds ---------------------------------------
# The fmt job is the first top-level job; the lint job (`  lint:`) starts the
# next one. Slice the fmt job's lines so assertions stay scoped to it.
def job_start(name):
    pat = re.compile(r"^  %s:\s*$" % re.escape(name))
    for i, ln in enumerate(lines):
        if pat.match(ln):
            return i
    sys.exit("could not find the '%s:' job in check.yml" % name)

fmt_i = job_start("fmt")
lint_i = job_start("lint")
if not fmt_i < lint_i:
    sys.exit("expected the fmt job to precede the lint job")
fmt_block = lines[fmt_i:lint_i]
fmt_text = "\n".join(fmt_block)

# Match the command on an actual `run:` line, not a mention in a comment.
def is_run_with(token):
    def pred(ln):
        s = ln.lstrip()
        if s.startswith("#"):
            return False
        return ("run:" in ln or ln.lstrip().startswith("xargs")) and token in ln
    return pred

# --- The pre-existing check step must still be there --------------------------
check_idx = None
for i, ln in enumerate(fmt_block):
    if is_run_with("m1-fmt --check")(ln):
        check_idx = i
        break
if check_idx is None:
    sys.exit("the fmt job no longer runs `m1-fmt --check` — the gate is gone")

# --- The diff step must exist, AFTER the check step --------------------------
diff_idx = None
for i, ln in enumerate(fmt_block):
    if is_run_with("m1-fmt --diff")(ln):
        diff_idx = i
        break
if diff_idx is None:
    sys.exit(
        "the fmt job has no `m1-fmt --diff` step — a red Format-check job still "
        "only says 'would reformat' with no diff of what is wrong"
    )
if not diff_idx > check_idx:
    sys.exit("the `m1-fmt --diff` step must come AFTER the `m1-fmt --check` step")
print("ok: fmt job runs `m1-fmt --diff` after `m1-fmt --check`")

# --- Find the diff step's `- name:` block and inspect its guards/run ----------
# Walk back from the diff command line to the enclosing `- name:` step header,
# then forward to the next step (`-` at the step indent) to bound the step.
def step_indent(ln):
    m = re.match(r"^(\s*)- ", ln)
    return len(m.group(1)) if m else None

start = None
for i in range(diff_idx, -1, -1):
    if re.match(r"^\s*- name:", fmt_block[i]):
        start = i
        break
if start is None:
    sys.exit("could not find the `- name:` header for the diff step")
indent = step_indent(fmt_block[start])
end = len(fmt_block)
for i in range(start + 1, len(fmt_block)):
    si = step_indent(fmt_block[i])
    if si is not None and si <= indent:
        end = i
        break
step = "\n".join(fmt_block[start:end])

# 1. Gated on failure() — only runs when --check failed.
if "failure()" not in step:
    sys.exit("the diff step must be gated on `if: failure()` so it only runs when --check failed")
print("ok: diff step is gated on failure()")

# 2. Gated on a non-zero collected count (no empty-list diff run).
if "steps.collect.outputs.count" not in step or "!= '0'" not in step:
    sys.exit("the diff step must also be gated on `steps.collect.outputs.count != '0'`")
print("ok: diff step is gated on a non-zero collected-script count")

# 3. Runs --diff over the SAME collected script list (the .nul file via xargs).
if "m1-scripts.nul" not in step:
    sys.exit("the diff step must run over the collected script list ($RUNNER_TEMP/m1-scripts.nul)")
if "xargs" not in step:
    sys.exit("the diff step must feed the .nul script list via xargs (matching the --check step)")
print("ok: diff step runs --diff over the same collected script list via xargs")

# 4. Swallows its own exit status so the diff step stays green.
if "|| true" not in step:
    sys.exit(
        "the diff step must swallow its exit (`|| true`): the --check step already "
        "carries the failing exit, and m1-fmt --diff exits non-zero on syntax errors"
    )
print("ok: diff step swallows its own exit status (|| true)")

print("PASS: fmt job surfaces a unified diff on Format-check failure")
PY

echo "PASS: fmt-check-diff"
