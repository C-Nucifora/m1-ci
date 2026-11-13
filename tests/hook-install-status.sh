#!/usr/bin/env bash
# Exercise real hooks in default Bash, including bin="$(ensure_tool ...)".
# Every download/install is a synthetic stub using an isolated cache.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"

python3 - "$repo_root" <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

repo = Path(sys.argv[1])
if sys.platform != "linux" or os.uname().machine != "x86_64":
    sys.exit("hook-install-status requires Linux x86_64, matching CI")
pins = dict(line.split("=", 1) for line in (repo / "tools.env").read_text().splitlines()
            if line.startswith("M1_"))
with tempfile.TemporaryDirectory(prefix="m1-hook-install-") as directory:
    root = Path(directory)
    fakebin = root / "bin"
    fakebin.mkdir()
    fake = fakebin / "fake.py"
    fake.write_text('''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
name = Path(sys.argv[0]).name
with open(os.environ["TOOL_LOG"], "a") as log:
    log.write(json.dumps([name, sys.argv[1:]]) + "\\n")
if name == "curl":
    assert sys.argv[1:4] == ["-fsSL", "-o", os.environ["DEST"] + ".tmp"], sys.argv
    assert sys.argv[4] == os.environ["DOWNLOAD_URL"], sys.argv
    sys.exit(22)
if name == "cargo":
    assert sys.argv[1:] == ["install", "--locked", "--git", os.environ["SOURCE_URL"],
        "--tag", os.environ["PIN"], "--root", os.environ["BUILD_ROOT"], os.environ["TOOL"]], sys.argv
    if os.environ["INSTALL_MODE"] == "fail":
        sys.stderr.write("cargo: synthetic install failure\\n")
        sys.exit(7)
    if os.environ["INSTALL_MODE"] == "fresh":
        installed = Path(os.environ["BUILD_ROOT"]) / "bin" / os.environ["TOOL"]
        installed.parent.mkdir(parents=True, exist_ok=True)
        installed.write_bytes(Path(os.environ["FRESH"]).read_bytes())
        installed.chmod(0o755)
    sys.exit(0)
if name == "cp":
    assert sys.argv[1:] == [str(Path(os.environ["BUILD_ROOT"]) / "bin" / os.environ["TOOL"]), os.environ["DEST"]], sys.argv
    if os.environ["COPY_FAIL"] == "true":
        sys.exit(23)
    os.execv("/bin/cp", ["cp", *sys.argv[1:]])
sys.exit("unexpected external tool: " + name)
''')
    fake.chmod(0o755)
    for name in ("curl", "cargo", "cp", "gh"):
        (fakebin / name).symlink_to(fake.name)

    def payload(marker):
        return ("#!/usr/bin/env python3\nimport json, os, sys\n"
                "with open(os.environ['TOOL_LOG'], 'a') as log:\n"
                f"    log.write(json.dumps([{marker!r}, sys.argv[1:]]) + '\\n')\n").encode()

    hooks = [("m1-fmt", "m1-fmt"), ("m1-lint", "m1-lint"),
             ("m1-typecheck", "m1-typecheck"), ("m1-project-validate", "m1-project"),
             ("m1-can-export-check", "m1-can"), ("m1-can-overlap-check", "m1-can")]
    cases = [(hook, tool, "failed-retained", "fail", True, False, False, 7)
             for hook, tool in hooks]
    cases += [("m1-fmt", "m1-fmt", label, mode, retained, copy_fail, direct, status)
              for label, mode, retained, copy_fail, direct, status in [
                  ("failed-empty", "fail", False, False, False, 7),
                  ("success-fresh", "fresh", True, False, False, 0),
                  ("missing-output", "missing", False, False, False, 1),
                  ("copy-failed", "fresh", True, True, False, 23),
                  ("direct-failure-control", "fail", True, False, True, 7),
                  ("cache-hit", "fail", False, False, False, 0)]]
    for hook, tool, label, mode, retained, copy_fail, direct, expected_status in cases:
        case = root / (hook + "-" + label)
        case.mkdir()
        cache = case / "cache"
        pin = pins["M1_" + tool.removeprefix("m1-").upper() + "_VERSION"]
        build = cache / ("cargo-" + tool + "-" + pin)
        installed = build / "bin" / tool
        installed.parent.mkdir(parents=True)
        dest = cache / (tool + "-" + pin)
        if retained:
            installed.write_bytes(payload("retained"))
            installed.chmod(0o755)
        if label == "cache-hit":
            dest.write_bytes(payload("cached"))
            dest.chmod(0o755)
        fresh = case / "fresh"
        fresh.write_bytes(payload("fresh"))
        log = case / "calls"
        owner = "nedlane" if tool in ("m1-project", "m1-can") else "C-Nucifora"
        env = dict(PATH=str(fakebin) + ":/usr/bin:/bin", M1_CI_CACHE=str(cache),
                   TMPDIR=os.environ.get("TMPDIR", directory),
                   TOOL=tool, PIN=pin, DEST=str(dest), BUILD_ROOT=str(build),
                   SOURCE_URL=f"https://github.com/{owner}/{tool}.git",
                   DOWNLOAD_URL=f"https://github.com/{owner}/{tool}/releases/download/{pin}/{tool}-x86_64-unknown-linux-gnu",
                   TOOL_LOG=str(log), INSTALL_MODE=mode, COPY_FAIL=str(copy_fail).lower(), FRESH=str(fresh))
        # No SHELLOPTS, BASH_ENV or POSIX mode is inherited from the test runner.
        # The actual hook's substitution must propagate the failure itself.
        argv = ["/bin/bash", "--noprofile", "--norc"]
        if direct:
            env["HOOK_LIB"] = str(repo / "hooks/lib.sh")
            argv += ["-c", '. "$HOOK_LIB"\nensure_tool m1-fmt\n']
        else:
            args = {"m1-can-export-check": [],
                    "m1-can-overlap-check": ["--project", "Project.m1prj"],
                    "m1-project-validate": ["Project.m1prj"]}.get(hook, ["Scripts/First space.m1scr"])
            argv += [str(repo / "hooks" / hook), *args]
        result = subprocess.run(argv, env=env, cwd=case, capture_output=True, text=True, timeout=5)
        assert result.returncode == expected_status, (hook, label, result)
        assert result.stdout == "", (hook, label, "must not report success or run retained bytes", result.stdout)
        calls = [json.loads(line) for line in log.read_text().splitlines()]
        names = [call[0] for call in calls]
        if label == "cache-hit":
            assert names == ["cached"], calls
        elif expected_status == 7:
            assert names == ["curl", "cargo"], calls
            assert not dest.exists(), (hook, label, "failed install published a binary")
        elif expected_status:
            assert names == ["curl", "cargo", "cp"], calls
            assert not dest.exists(), (hook, label, "failed copy published a binary")
        else:
            assert names == ["curl", "cargo", "cp", "fresh"], calls
            assert calls[-1][1] == ["--check", "Scripts/First space.m1scr"], calls
            assert dest.read_bytes() == fresh.read_bytes() != payload("retained")
            # A published successful install keeps the existing no-install fast path.
            log.write_text("")
            cached = subprocess.run(argv, env=env, cwd=case, capture_output=True, text=True, timeout=5)
            assert cached.returncode == 0, cached
            assert [json.loads(line)[0] for line in log.read_text().splitlines()] == ["fresh"]
        print("ok:", hook, label)
print("PASS: hook-install-status")
PY
