#!/usr/bin/env bash
# Regression test for the register-matchers composite action.
#
# check.yml used to inline three near-identical "Register problem matchers"
# steps, one per tool job. The lint job's matcher block and the typecheck job's
# matcher block were byte-for-byte identical (same `m1-diagnostic` owner, same
# regex), and the fmt job's block was a sibling variant. Because each block
# embedded the same diagnostic-parsing regex, any change to the M1 diagnostic
# line format had to be applied in two identical places and could silently
# drift.
#
# The dedup hoists the matcher JSON into a single composite action,
# .github/actions/register-matchers, with input `kind: fmt|diagnostic`. The
# fmt / lint / typecheck jobs each `uses:` it instead of inlining the heredoc,
# so the diagnostic matcher has exactly ONE canonical source.
#
# This test:
#   1. Static: the composite action exists, is a composite, takes a `kind`
#      input, and emits BOTH matcher variants (fmt + diagnostic) via
#      ::add-matcher::.
#   2. Behavioural: run the action's matcher-writing shell for each kind and
#      assert the produced JSON matches the real m1-fmt / m1-lint /
#      m1-typecheck output lines, capturing file/line/column/severity/message
#      as expected, and does NOT match plain summary noise.
#   3. Static (dedup): check.yml no longer inlines the matcher heredoc — the
#      three jobs reference the composite action — so the diagnostic regex
#      lives in exactly one place and cannot drift.

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
action="$repo_root/.github/actions/register-matchers/action.yml"
workflow="$repo_root/.github/workflows/check.yml"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

command -v python3 >/dev/null 2>&1 || fail "python3 is required (preinstalled on ubuntu-latest runners)"

# --- Part 1: the composite action exists and has the right shape -------------

[ -f "$action" ] || fail "missing composite action: .github/actions/register-matchers/action.yml"

python3 - "$action" <<'PY'
import sys

# We avoid a YAML-library dependency (PyYAML is not guaranteed preinstalled);
# the structural assertions below are intentionally textual but specific.
path = sys.argv[1]
with open(path, encoding="utf-8") as fh:
    text = fh.read()

if "using: composite" not in text:
    sys.exit("register-matchers action is not a composite action (no 'using: composite')")
if "kind:" not in text:
    sys.exit("register-matchers action does not declare a 'kind' input")
if "::add-matcher::" not in text:
    sys.exit("register-matchers action never emits ::add-matcher:: (it must register the matcher)")
print("ok: register-matchers is a composite action with a 'kind' input that emits ::add-matcher::")
PY

# Extract the action's matcher-writing shell so we can RUN it per kind. The
# action's run: body is expected to branch on the `kind` input and write the
# matcher JSON to "$RUNNER_TEMP/m1-matchers.json". We pull the run: script out
# of the composite step and drive it with INPUT_KIND set, mimicking how the
# Actions runner passes a composite input through as INPUT_<NAME>.
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
    if stripped in ("run: |", "run: |-") or stripped.startswith("run: |"):
        start = i + 1
        run_indent = len(line) - len(line.lstrip(" "))
        break
if start is None:
    sys.exit("could not find a 'run: |' block in the register-matchers action")

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

# The action reads the input as $INPUT_KIND (an env: mapping in the step) or via
# a templated ${{ inputs.kind }}. Normalise a templated reference to the env var
# the harness below provides, so the same script body runs either way.
script = script.replace("${{ inputs.kind }}", "$INPUT_KIND")

with open(out, "w", encoding="utf-8") as fh:
    fh.write("#!/usr/bin/env bash\n")
    fh.write(script)
    fh.write("\n")
print("extracted the action run-body into a standalone script", file=sys.stderr)
PY

chmod +x "$runner_script"

# Drive the extracted script per kind, capturing the JSON it writes. The action
# reads its input as $KIND (via the step's env: mapping); provide that, plus
# INPUT_KIND and the templated form, so the body runs however it references the
# input.
run_kind() {
  local kind="$1" out="$2"
  RUNNER_TEMP="$tmp" KIND="$kind" INPUT_KIND="$kind" bash "$runner_script" >/dev/null 2>"$tmp/err.$kind" || {
    echo "--- stderr ---" >&2
    cat "$tmp/err.$kind" >&2
    fail "register-matchers action shell failed for kind=$kind"
  }
  [ -f "$tmp/m1-matchers.json" ] || fail "kind=$kind did not write \$RUNNER_TEMP/m1-matchers.json"
  cp "$tmp/m1-matchers.json" "$out"
}

run_kind fmt "$tmp/fmt.json"
run_kind diagnostic "$tmp/diagnostic.json"

# --- Part 2: behavioural — each kind matches the real tool output ------------

python3 - "$tmp/fmt.json" "$tmp/diagnostic.json" <<'PY'
import json
import re
import sys

fmt_doc = json.load(open(sys.argv[1], encoding="utf-8"))
diag_doc = json.load(open(sys.argv[2], encoding="utf-8"))


def matchers(doc, label):
    ms = doc.get("problemMatcher", [])
    if not ms:
        sys.exit("%s matcher document has no problemMatcher entries" % label)
    return ms


def all_patterns(ms, label):
    out = []
    for m in ms:
        owner = m.get("owner")
        if not m.get("pattern"):
            sys.exit("%s matcher owner %r has no pattern" % (label, owner))
        for p in m["pattern"]:
            try:
                rx = re.compile(p["regexp"])
            except re.error as exc:
                sys.exit("%s owner %r has an invalid regexp: %s" % (label, owner, exc))
            out.append((owner, rx, p, m))
    return out


def first_match(pats, line):
    for owner, rx, p, m in pats:
        mo = rx.match(line)
        if mo:
            return owner, mo, p, m
    return None


# --- kind=fmt: would-reformat, syntax-error, parse-warning -------------------
fmt_ms = matchers(fmt_doc, "fmt")
fmt_pats = all_patterns(fmt_ms, "fmt")

line = "UQR-EV/01.00/Scripts/Mission Critical.m1scr: would reformat"
hit = first_match(fmt_pats, line)
if not hit:
    sys.exit("fmt: no matcher matched 'would reformat': %r" % line)
owner, mo, p, m = hit
if mo.group(p["file"]) != "UQR-EV/01.00/Scripts/Mission Critical.m1scr":
    sys.exit("fmt would-reformat captured the wrong file: %r" % mo.group(p["file"]))
print("ok: fmt matches 'would reformat'")

line = "m1-fmt: UQR-EV/01.00/Scripts/Broken.m1scr: 3 syntax error(s); left unchanged"
hit = first_match(fmt_pats, line)
if not hit:
    sys.exit("fmt: no matcher matched the syntax-error line: %r" % line)
owner, mo, p, m = hit
if mo.group(p["file"]) != "UQR-EV/01.00/Scripts/Broken.m1scr":
    sys.exit("fmt syntax-error captured the wrong file: %r" % mo.group(p["file"]))
if (p.get("severity") or m.get("severity")) != "error":
    sys.exit("fmt syntax-error matcher must report severity 'error'")
print("ok: fmt matches the syntax-error line (severity error)")

line = "UQR-EV/01.00/Scripts/Demo.m1scr:42: warning: unexpected token"
hit = first_match(fmt_pats, line)
if not hit:
    sys.exit("fmt: no matcher matched the parse-warning line: %r" % line)
owner, mo, p, m = hit
if mo.group(p["file"]) != "UQR-EV/01.00/Scripts/Demo.m1scr":
    sys.exit("fmt parse-warning captured the wrong file: %r" % mo.group(p["file"]))
if "line" not in p or mo.group(p["line"]) != "42":
    sys.exit("fmt parse-warning did not capture the line number")
if "message" not in p or mo.group(p["message"]) != "unexpected token":
    sys.exit("fmt parse-warning did not capture the message")
if (p.get("severity") or m.get("severity")) != "warning":
    sys.exit("fmt parse-warning matcher must report severity 'warning'")
print("ok: fmt matches the parse-warning line (file/line/message, severity warning)")

# Distinct owners, separate entries (>=3), matching the prior inline behaviour.
fmt_owners = [m.get("owner") for m in fmt_ms]
if len(fmt_owners) != len(set(fmt_owners)):
    sys.exit("fmt matcher owners are not distinct: %r" % fmt_owners)
if len(fmt_ms) < 3:
    sys.exit("expected >=3 fmt matcher entries, got %d: %r" % (len(fmt_ms), fmt_owners))
print("ok: %d distinct fmt matcher owners: %r" % (len(fmt_ms), fmt_owners))

# --- kind=diagnostic: m1-lint / m1-typecheck diagnostic lines ---------------
diag_ms = matchers(diag_doc, "diagnostic")
diag_pats = all_patterns(diag_ms, "diagnostic")

# An m1-lint / m1-typecheck error line: file:line:col: severity[CODE]: message.
line = "UQR-EV/01.00/Scripts/Engine.m1scr:12:5: error[L010]: tabs expected"
hit = first_match(diag_pats, line)
if not hit:
    sys.exit("diagnostic: no matcher matched an error diagnostic: %r" % line)
owner, mo, p, m = hit
if mo.group(p["file"]) != "UQR-EV/01.00/Scripts/Engine.m1scr":
    sys.exit("diagnostic captured the wrong file: %r" % mo.group(p["file"]))
if mo.group(p["line"]) != "12" or mo.group(p["column"]) != "5":
    sys.exit("diagnostic did not capture line/column")
if mo.group(p["severity"]) != "error":
    sys.exit("diagnostic did not capture the 'error' severity")
if mo.group(p["message"]) != "tabs expected":
    sys.exit("diagnostic did not capture the message")
print("ok: diagnostic matches an error[CODE] line (file/line/col/severity/message)")

# A warning diagnostic.
line = "Scripts/Brake Control 100Hz.m1scr:3:1: warning[T002]: float equality"
hit = first_match(diag_pats, line)
if not hit:
    sys.exit("diagnostic: no matcher matched a warning diagnostic: %r" % line)
owner, mo, p, m = hit
if mo.group(p["severity"]) != "warning":
    sys.exit("diagnostic did not capture the 'warning' severity")
print("ok: diagnostic matches a warning[CODE] line (spaces in path)")

# info/hint diagnostics: matched (annotated), severity not error/warning.
line = "a.m1scr:1:1: hint[T041]: consider naming this"
hit = first_match(diag_pats, line)
if not hit:
    sys.exit("diagnostic: no matcher matched a hint diagnostic: %r" % line)
print("ok: diagnostic matches an info/hint[CODE] line")

# Negative: plain summary / version output must NOT be annotated by either kind.
for label, pats in (("fmt", fmt_pats), ("diagnostic", diag_pats)):
    for noise in (
        "All files OK.",
        "Checked 12 file(s).",
        "m1-lint 0.20.0",
        "m1-typecheck 0.37.0",
    ):
        if first_match(pats, noise):
            sys.exit("%s wrongly matched non-diagnostic output: %r" % (label, noise))
print("ok: neither kind matches plain summary/version output")

print("PASS: register-matchers emits a correct matcher set for both fmt and diagnostic kinds")
PY

# --- Part 3: dedup — check.yml references the action, no inline heredocs -----

# All three tool jobs must register matchers via the composite action.
uses_count="$(grep -cE 'uses: \./\.m1-ci/\.github/actions/register-matchers' "$workflow" || true)"
[ "$uses_count" -eq 3 ] \
  || fail "expected all 3 tool jobs to use the register-matchers action, found $uses_count 'uses:' references"
echo "ok: check.yml uses ./.m1-ci/.github/actions/register-matchers in all 3 tool jobs"

# The diagnostic regex must no longer be inlined in check.yml — that is the
# whole point of the dedup (one canonical source). Its byte signature was the
# `error|warning` alternation embedded in the matcher heredoc.
if grep -qE 'error\|warning\)\|\(\?:info\|hint\)' "$workflow"; then
  fail "check.yml still inlines the diagnostic matcher regex; it should live only in the register-matchers action"
fi
# And no leftover ::add-matcher:: heredocs in the workflow either.
if grep -q '::add-matcher::' "$workflow"; then
  fail "check.yml still emits ::add-matcher:: inline; matcher registration should be delegated to the composite action"
fi
echo "ok: check.yml no longer inlines the matcher JSON (single canonical source in the action)"

echo "PASS: register-matchers-action"
