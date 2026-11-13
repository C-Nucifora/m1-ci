#!/usr/bin/env bash
# Run the actual collection, diagnostic and render bodies with synthetic tools.
# Workflow conditions are projected locally; no hosted runner or upload is used.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
command -v jq >/dev/null || { echo 'jq is required' >&2; exit 1; }

python3 - "$repo_root" <<'PY'
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import textwrap

repo = Path(sys.argv[1])


def body(text):
    lines = text.splitlines()
    start = next(i for i, line in enumerate(lines) if line.strip() == "run: |")
    indent = len(lines[start]) - len(lines[start].lstrip())
    result = []
    for line in lines[start + 1:]:
        if line.strip() and len(line) - len(line.lstrip()) <= indent:
            break
        result.append(line)
    script = textwrap.dedent("\n".join(result)) + "\n"
    assert "${{" not in script, "unexpanded action input"
    return script


def field(step, name):
    return re.search(r"^        " + name + r": (.+)$", step, re.M).group(1)


def eligible(expression, collector, render_id, count, outcome, render_outcome,
             prior_failed, upload=True, cancelled=False):
    # Project only this workflow's conjunctions. Unknown syntax must fail loudly.
    terms = {
        "inputs.sarif-upload": upload,
        "!cancelled()": not cancelled,
        "success()": not prior_failed,
        "failure()": prior_failed,
        f"steps.{collector}.outcome == 'success'": outcome == "success",
        f"steps.{collector}.outputs.count != ''": count != "",
        f"steps.{collector}.outputs.count != '0'": count != "0",
        f"steps.{render_id}.outcome == 'success'": render_outcome == "success",
    }
    parts = expression.split(" && ")
    assert all(part in terms for part in parts), expression
    # Actions implicitly adds success() unless an explicit status function exists.
    if prior_failed and not re.search(r"(?:cancelled|success|failure|always)\(\)", expression):
        return False
    return all(terms[part] for part in parts)


collect = body((repo / ".github/actions/collect-scripts/action.yml").read_text())
render = body((repo / ".github/actions/render-sarif/action.yml").read_text())
workflow = (repo / ".github/workflows/check.yml").read_text()
with tempfile.TemporaryDirectory(prefix="m1-sarif-completeness-") as directory:
    root = Path(directory)
    fakebin = root / "bin"
    fakebin.mkdir()
    finder = fakebin / "find"
    finder.write_text('''#!/usr/bin/env python3
import os, sys
assert sys.argv[1] == "Scripts" and sys.argv[-1] == "-print0", sys.argv
mode = os.environ["FIND_MODE"]
paths = ["Scripts/First space.m1scr", "Scripts/Second\\nline.m1scr"]
if mode != "empty":
    sys.stdout.buffer.write((paths[0] + "\\0").encode())
if mode == "partial":
    sys.stderr.write("find: synthetic directory read failure\\n")
    sys.exit(1)
if mode != "empty":
    sys.stdout.buffer.write((paths[1] + "\\0").encode())
''')
    finder.chmod(0o755)
    for tool in ("m1-lint", "m1-typecheck"):
        fake = fakebin / tool
        fake.write_text('''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
sarif = "--format" in sys.argv
status = int(os.environ["RENDER_STATUS"] if sarif else os.environ["DIAGNOSTIC_STATUS"])
with open(os.environ["TOOL_LOG"], "a") as log:
    log.write(json.dumps(["sarif" if sarif else "diagnostics", status, sys.argv[1:]]) + "\\n")
if sarif:
    paths = sys.argv[sys.argv.index("--format") + 2:]
    print(json.dumps({"version": "2.1.0", "runs": [{"tool": {"driver": {"name": Path(sys.argv[0]).name}},
        "results": [{"message": {"text": path}} for path in paths]}]}))
else:
    print("synthetic diagnostic", file=sys.stderr)
sys.exit(status)
''')
        fake.chmod(0o755)

    for job, tool, gate_name, collector in [
            ("lint", "m1-lint", "Lint (m1-lint)", "collect-sarif"),
            ("typecheck", "m1-typecheck", "Type check (m1-typecheck)", "collect")]:
        job_text = re.search(r"^  " + job + r":\n(.*?)(?=^  [\w-]+:|\Z)", workflow, re.M | re.S).group(1)
        steps = re.split(r"(?=^      - (?:name|uses): )", job_text, flags=re.M)
        gate = next(step for step in steps if step.startswith("      - name: " + gate_name + "\n"))
        renderer = next(step for step in steps if "id: render-sarif-" in step)
        uploader = next(step for step in steps if step.startswith("      - name: Upload SARIF to code scanning\n"))
        render_id = field(renderer, "id")
        render_if, upload_if = field(renderer, "if"), field(uploader, "if")

        # Test each gate independently, even if a stale successful render exists.
        for expression in (render_if, upload_if):
            for outcome, count in [("failure", ""), ("failure", "2"), ("skipped", "2"),
                                   ("success", ""), ("success", "0")]:
                assert not eligible(expression, collector, render_id, count, outcome, "success", True), (job, expression, outcome, count)
            assert eligible(expression, collector, render_id, "2", "success", "success", True), (job, "findings must still upload")
            assert not eligible(expression, collector, render_id, "2", "success", "success", False, upload=False)
            assert not eligible(expression, collector, render_id, "2", "success", "success", False, cancelled=True)
        assert not eligible(upload_if, collector, render_id, "2", "success", "failure", True)

        for label, find_mode, diagnostic_status, render_status in [
                ("partial", "partial", 1, 1), ("clean", "complete", 0, 0),
                ("findings", "complete", 1, 1), ("empty", "empty", 0, 0),
                ("render-error", "complete", 1, 2)]:
            case = root / (job + "-" + label)
            case.mkdir()
            (case / "Scripts").mkdir()
            expected = ["Scripts/First space.m1scr", "Scripts/Second\nline.m1scr"]
            for path in expected:
                (case / path).write_text("// synthetic\n")
            listing = case / "m1-scripts.nul"
            listing.write_bytes(b"old complete list\0")
            output = case / "output"
            output.touch()
            artifact = case / (tool + ".sarif")
            artifact.write_text("old artifact")
            log = case / "calls"
            env = dict(PATH=str(fakebin) + ":/usr/bin:/bin", RUNNER_TEMP=str(case),
                       TMPDIR=os.environ.get("TMPDIR", directory),
                       GITHUB_OUTPUT=str(output), SCRIPTS_PATH="Scripts", CHANGED_ONLY="false",
                       EXCLUDE_DIR="", BASE_SHA="", TOOL=tool, EXTRA_FLAG="", EXTRA_VALUE="",
                       FIND_MODE=find_mode, DIAGNOSTIC_STATUS=str(diagnostic_status),
                       RENDER_STATUS=str(render_status), TOOL_LOG=str(log),
                       LINT_BASELINE="", PROJECT_FILE="", FAIL_ON_WARNING="false")

            def run(script):
                return subprocess.run(["/bin/bash", "--noprofile", "--norc", "-e", "-o", "pipefail", "-c", script],
                                      cwd=case, env=env, text=True, capture_output=True, timeout=5)

            collected = run(collect)
            count = dict(line.split("=", 1) for line in output.read_text().splitlines()).get("count", "")
            outcome = "success" if collected.returncode == 0 else "failure"
            if find_mode == "partial":
                assert collected.returncode == 1 and count == "", collected
                assert "synthetic directory read failure" in collected.stderr
                assert not list(case.glob("m1-scripts.*")), "stale or partial collection survived"
            else:
                assert collected.returncode == 0, collected.stderr
                wanted = [] if find_mode == "empty" else expected
                assert listing.read_bytes() == b"".join(os.fsencode(path) + b"\0" for path in wanted)
                assert count == str(len(wanted)), count

            gate_failed = False
            if outcome == "success" and count != "0":
                diagnostics = run(body(gate))
                assert diagnostics.returncode == (123 if diagnostic_status else 0), diagnostics
                gate_failed = diagnostics.returncode != 0
            if job == "lint":
                full = next(step for step in steps if "id: collect-sarif\n" in step)
                assert eligible(field(full, "if"), collector, render_id, count, outcome, "skipped", gate_failed)
                # The real lint workflow re-collects the full tree after findings.
                output.write_text("")
                recollected = run(collect)
                assert recollected.returncode == collected.returncode, recollected
                if find_mode == "partial":
                    assert not list(case.glob("m1-scripts.*")) and output.read_text() == ""
            prior_failed = gate_failed or outcome != "success"
            rendered = None
            if eligible(render_if, collector, render_id, count, outcome, "skipped", prior_failed):
                rendered = run(render)
            render_outcome = "skipped" if rendered is None else "success" if rendered.returncode == 0 else "failure"
            upload = eligible(upload_if, collector, render_id, count, outcome, render_outcome,
                              prior_failed or render_outcome == "failure")
            assert upload == (label in ("clean", "findings")), (job, label, upload)
            if upload:
                report = json.loads(artifact.read_text())
                paths = [result["message"]["text"] for run_ in report["runs"] for result in run_["results"]]
                assert paths == expected, paths
            elif label == "render-error":
                assert rendered is not None and rendered.returncode != 0 and not artifact.exists()
            else:
                assert rendered is None
                assert not log.exists(), "failed/empty discovery must not invoke a tool"
            if log.exists():
                calls = [json.loads(line) for line in log.read_text().splitlines()]
                assert calls == [["diagnostics", diagnostic_status, expected],
                                 ["sarif", render_status, ["--format", "sarif", *expected]]], calls
            print("ok:", job, label)
print("PASS: collect-sarif-completeness")
PY
