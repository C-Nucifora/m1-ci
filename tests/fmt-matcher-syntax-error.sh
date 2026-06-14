#!/usr/bin/env bash
# Regression test for the fmt problem matcher.
#
# The format-check job (`m1-fmt --check`) fails (exit 1) not only when a file
# "would reformat", but ALSO when a script has syntax errors or emits parse
# warnings:
#
#   * m1-fmt/src/main.rs:218 — `<file>: would reformat`        (--check, changed)
#   * m1-fmt/src/main.rs:206 — `m1-fmt: <file>: N syntax error(s); left unchanged`
#   * m1-fmt/src/main.rs:193 — `<file>:<line>: warning: <message>`
#
# m1-fmt/src/main.rs:508 exits 1 on ANY syntax error regardless of --check, so a
# broken script turns the fmt job red. The lint/typecheck jobs annotate every
# diagnostic; before this fix the fmt matcher only recognised `would reformat`,
# so the syntax-error failure case — the exact case a user most needs guidance
# on — produced a red job with NO inline annotation pointing at the file.
#
# The matcher JSON now lives in the register-matchers composite action (the fmt
# variant under `kind: fmt`), so check.yml's jobs share one source instead of
# inlining three near-identical heredocs.
#
# This test:
#   1. Extracts the fmt matcher JSON from the register-matchers action (the
#      `kind: fmt` variant, the FIRST <<'JSON' heredoc) and parses it.
#   2. Behavioural: asserts the matcher set actually MATCHES each of the three
#      m1-fmt output lines above (capturing file / line / message as expected),
#      and does not match unrelated noise.
#   3. Static: asserts the syntax-error owner exists (load-bearing) and the
#      warning owner exists (surfaces parse warnings), each as its own
#      problemMatcher entry with a distinct owner.

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
workflow="$repo_root/.github/actions/register-matchers/action.yml"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

command -v python3 >/dev/null 2>&1 || fail "python3 is required for this test (preinstalled on ubuntu-latest runners)"

python3 - "$workflow" <<'PY'
import json
import re
import sys

workflow = sys.argv[1]
with open(workflow, encoding="utf-8") as fh:
    lines = fh.readlines()

# Locate the register-matchers action's `kind: fmt` matcher heredoc. The action
# writes the fmt variant first, delimited by `<<'JSON'` and a closing `JSON`
# line, then the diagnostic variant. Extract the FIRST such block (the fmt one),
# strip the indentation, and parse it.
start = end = None
for i, line in enumerate(lines):
    if "<<'JSON'" in line:
        start = i + 1
        break
if start is None:
    sys.exit("could not find the fmt matcher heredoc (<<'JSON') in check.yml")
for j in range(start, len(lines)):
    if lines[j].strip() == "JSON":
        end = j
        break
if end is None:
    sys.exit("could not find the closing JSON heredoc delimiter in check.yml")

block = [ln.rstrip("\n") for ln in lines[start:end]]
# Strip the common leading indentation (the YAML run: pipe block indent).
indent = min((len(ln) - len(ln.lstrip(" ")) for ln in block if ln.strip()), default=0)
raw = "\n".join(ln[indent:] for ln in block)

try:
    doc = json.loads(raw)
except json.JSONDecodeError as exc:
    sys.exit("fmt matcher heredoc is not valid JSON: %s\n---\n%s" % (exc, raw))

matchers = doc.get("problemMatcher", [])
if not matchers:
    sys.exit("fmt matcher document has no problemMatcher entries")

owners = {m.get("owner"): m for m in matchers}

def compiled_patterns(m):
    out = []
    for p in m.get("pattern", []):
        out.append((re.compile(p["regexp"]), p))
    return out

# Every owner's regexp must compile (catches a typo'd pattern early).
all_patterns = []
for owner, m in owners.items():
    if not m.get("pattern"):
        sys.exit("matcher owner %r has no pattern" % owner)
    all_patterns.extend((owner, rx, p) for rx, p in compiled_patterns(m))

def any_match(line):
    for owner, rx, p in all_patterns:
        mo = rx.match(line)
        if mo:
            return owner, mo, p
    return None

# --- Behavioural: the three real m1-fmt --check failure/output lines ----------
# Paths mirror a real M1 project: spaces in the filename, nested dirs.

# 1. would reformat (the pre-existing, already-matched case — keep it working).
line = "UQR-EV/01.00/Scripts/Mission Critical.m1scr: would reformat"
hit = any_match(line)
if not hit:
    sys.exit("no matcher matched the 'would reformat' line: %r" % line)
owner, mo, p = hit
if mo.group(p["file"]) != "UQR-EV/01.00/Scripts/Mission Critical.m1scr":
    sys.exit("would-reformat matcher captured the wrong file: %r" % mo.group(p["file"]))
print("ok: 'would reformat' is matched (owner=%s, file captured)" % owner)

# 2. syntax error (THE load-bearing fix): exit 1 even without --check, must
#    annotate the file.
line = "m1-fmt: UQR-EV/01.00/Scripts/Broken.m1scr: 3 syntax error(s); left unchanged"
hit = any_match(line)
if not hit:
    sys.exit(
        "no matcher matched the syntax-error line — a broken script fails the "
        "fmt job with NO annotation: %r" % line
    )
owner, mo, p = hit
if mo.group(p["file"]) != "UQR-EV/01.00/Scripts/Broken.m1scr":
    sys.exit("syntax-error matcher captured the wrong file: %r" % mo.group(p["file"]))
if (p.get("severity") or owners[owner].get("severity")) != "error":
    sys.exit("syntax-error matcher must report severity 'error'")
print("ok: syntax-error line is matched (owner=%s, file captured, severity error)" % owner)

# 2b. The count is variable — a single-error message must match too.
line = "m1-fmt: a.m1scr: 1 syntax error(s); left unchanged"
if not any_match(line):
    sys.exit("syntax-error matcher did not match a single-error (count=1) message: %r" % line)
print("ok: syntax-error matcher matches any error count")

# 3. parse warning: surfaced as a warning annotation (does not itself fail the
#    job). file/line/message captured.
line = "UQR-EV/01.00/Scripts/Demo.m1scr:42: warning: unexpected token"
hit = any_match(line)
if not hit:
    sys.exit("no matcher matched the parse-warning line: %r" % line)
owner, mo, p = hit
if mo.group(p["file"]) != "UQR-EV/01.00/Scripts/Demo.m1scr":
    sys.exit("warning matcher captured the wrong file: %r" % mo.group(p["file"]))
if "line" not in p or mo.group(p["line"]) != "42":
    sys.exit("warning matcher did not capture the line number")
if "message" not in p or mo.group(p["message"]) != "unexpected token":
    sys.exit("warning matcher did not capture the message")
if (p.get("severity") or owners[owner].get("severity")) != "warning":
    sys.exit("parse-warning matcher must report severity 'warning'")
print("ok: parse-warning line is matched (owner=%s, file/line/message captured, severity warning)" % owner)

# --- Negative: a plain summary / success line must NOT be annotated -----------
for noise in (
    "All files formatted.",
    "Formatting 12 file(s)…",
    "m1-fmt 0.13.0",
):
    if any_match(noise):
        sys.exit("a matcher wrongly matched non-diagnostic output: %r" % noise)
print("ok: matchers do not match plain summary/version output")

# --- Static: distinct owners, separate entries -------------------------------
# Each pattern is its own problemMatcher entry (GitHub keys a matcher on a single
# regexp array; multi-line continuation semantics would mis-pair these unrelated
# single-line patterns), with a distinct owner name.
owner_names = [m.get("owner") for m in matchers]
if len(owner_names) != len(set(owner_names)):
    sys.exit("matcher owners are not distinct: %r" % owner_names)
if len(matchers) < 3:
    sys.exit(
        "expected at least 3 fmt matcher entries (would-reformat, syntax-error, "
        "parse-warning); got %d: %r" % (len(matchers), owner_names)
    )
print("ok: %d distinct fmt matcher owners: %r" % (len(matchers), owner_names))

print("PASS: fmt problem matcher annotates would-reformat, syntax-error and parse-warning lines")
PY

echo "PASS: fmt-matcher-syntax-error"
