#!/usr/bin/env bash
# Failed release downloads must not publish partial files as installed binaries.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$repo_root" <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import textwrap

repo = Path(sys.argv[1])
action = (repo / ".github/actions/install-m1-tool/action.yml").read_text()
step = action.split('    - name: Install ${{ inputs.tool }} (prebuilt)\n', 1)[1]
lines = step.split('      run: |\n', 1)[1].splitlines()
body = []
for line in lines:
    if line.strip() and not line.startswith('        '):
        break
    body.append(line)
script = textwrap.dedent('\n'.join(body)).replace('$HOME', '$TEST_INSTALL_ROOT')
assert '${{' not in script
with tempfile.TemporaryDirectory(prefix='m1-download-status-') as directory:
    root = Path(directory)
    fakebin = root / 'bin'
    fakebin.mkdir()
    gh = fakebin / 'gh'
    gh.write_text('''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
with open(os.environ['TOOL_LOG'], 'a') as log:
    log.write(json.dumps(args) + '\\n')
asset = 'm1-fmt-x86_64-unknown-linux-gnu'
if args[:2] == ['release', 'download']:
    tag = [] if os.environ['VERSION'] == 'latest' else [os.environ['VERSION']]
    assert args == ['release', 'download', *tag, '--repo', 'fixture/m1-fmt', '--pattern', asset,
                    '--dir', os.environ['RUNNER_TEMP'], '--clobber'], args
    mode = os.environ['DOWNLOAD_MODE']
    if mode in ('good', 'partial'):
        (Path(os.environ['RUNNER_TEMP']) / asset).write_text('complete fixture bytes' if mode == 'good' else 'partial fixture bytes')
    sys.exit(7 if mode in ('partial', 'missing') else 0)
assert args == ['attestation', 'verify', str(Path(os.environ['RUNNER_TEMP']) / asset), '--repo', 'fixture/m1-fmt'], args
mode = os.environ['ATTEST_MODE']
if mode == 'missing':
    print('no attestations found', file=sys.stderr)
elif mode == 'invalid':
    print('verification failed: synthetic digest mismatch', file=sys.stderr)
sys.exit(0 if mode == 'valid' else 1)
''')
    gh.chmod(0o755)
    for version in ['v1.0.0', 'latest']:
        for label, download, attest in [
            ('partial', 'partial', 'missing'),
            ('partial-invalid', 'partial', 'invalid'),
            ('missing', 'missing', 'valid'),
            ('success-without-file', 'empty', 'valid'),
            ('complete', 'good', 'valid'),
            ('legacy-attestation', 'good', 'missing'),
            ('rejected-attestation', 'good', 'invalid'),
        ]:
            case = root / (version + '-' + label)
            temp = case / 'temp'
            temp.mkdir(parents=True)
            output, log = case / 'outputs', case / 'calls'
            output.touch()
            env = dict(PATH=str(fakebin) + ':/usr/bin:/bin',
                       TMPDIR=os.environ.get('TMPDIR', directory),
                       TEST_INSTALL_ROOT=str(case / 'install-root'), RUNNER_TEMP=str(temp),
                       GITHUB_PATH=str(case / 'path'), GITHUB_OUTPUT=str(output),
                       TOOL='m1-fmt', VERSION=version, REPO='fixture/m1-fmt', CACHE_HIT='false',
                       TOOL_LOG=str(log), DOWNLOAD_MODE=download, ATTEST_MODE=attest)
            dest = case / 'install-root/.local/bin/m1-fmt'
            cached = case / 'install-root/.m1-tool-cache/m1-fmt/m1-fmt'
            asset = temp / 'm1-fmt-x86_64-unknown-linux-gnu'
            # Even a stale prebuilt pathname must not make an unsuccessful transfer usable.
            asset.write_text('stale fixture bytes')
            for reuse in [False, True] if version != 'latest' else [False]:
                if reuse:
                    env['CACHE_HIT'] = 'true'
                    if dest.exists():
                        dest.unlink()
                    output.write_text('')
                log.write_text('')
                result = subprocess.run(['/bin/bash', '--noprofile', '--norc', '-e', '-o', 'pipefail', '-c', script],
                                        cwd=case, env=env, capture_output=True, text=True, timeout=5)
                calls = [json.loads(line) for line in log.read_text().splitlines()]
                failed_transfer = download != 'good'
                invalid = download == 'good' and attest == 'invalid'
                assert result.returncode == (1 if invalid else 0), (version, label, reuse, result)
                if failed_transfer:
                    assert not dest.exists() and not cached.exists() and not asset.exists(), (version, label, reuse)
                    assert 'need-source=true\n' in output.read_text(), result
                    assert len(calls) == 1 and calls[0][:2] == ['release', 'download'], calls
                elif invalid:
                    assert not dest.exists() and not cached.exists(), (version, label, reuse)
                    assert 'need-source=false' not in output.read_text(), result
                    assert [call[:2] for call in calls] == [['release', 'download'], ['attestation', 'verify']], calls
                else:
                    assert dest.read_text() == cached.read_text() == 'complete fixture bytes'
                    assert 'need-source=false\n' in output.read_text(), result
                    assert [call[:2] for call in calls] == ([] if reuse else [['release', 'download'], ['attestation', 'verify']]), calls
            print('ok:', version, label)
print('PASS: install-download-status')
PY
