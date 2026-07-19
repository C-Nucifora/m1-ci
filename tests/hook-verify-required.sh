#!/usr/bin/env bash
# Regression test: local hooks must not execute an UNVERIFIED downloaded binary.
#
# ensure_tool() downloads a prebuilt tool release over HTTPS and verifies its
# GitHub build provenance with `gh attestation verify` — but only when an
# authenticated `gh` is available. Previously, with no (authenticated) gh the
# hook warned nothing and simply executed whatever the download produced: a
# supply-chain hole precisely on the machines least equipped to notice
# (fresh dev boxes without gh). The rule now:
#
#   - authenticated gh        -> verify (missing attestation still warns, #48)
#   - no/unauthenticated gh   -> REFUSE the downloaded binary, with a clear
#                                remedial message
#   - M1_CI_ALLOW_UNVERIFIED=1 -> explicit, loudly-warned escape hatch
#
# The test drives ensure_tool hermetically: a stub `curl` fakes a successful
# asset download (no network), and a stub `gh` fails `auth status` (the
# unauthenticated case — the same branch as gh being absent entirely).

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# --- stubs ------------------------------------------------------------------
mkdir -p "$tmp/bin"
# curl: "download" succeeds, writing a dummy binary to the -o target.
cat > "$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
out=""
prev=""
for a in "$@"; do
  if [ "$prev" = "-o" ]; then out="$a"; fi
  prev="$a"
done
[ -n "$out" ] || exit 2
printf '#!/bin/sh\necho fake-tool\n' > "$out"
EOF
chmod +x "$tmp/bin/curl"
# gh: present but unauthenticated — every invocation fails.
cat > "$tmp/bin/gh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$tmp/bin/gh"

# A driver that sources lib.sh with the stub dir FIRST in PATH and calls
# ensure_tool for a real pinned tool (m1-fmt).
driver="$tmp/driver.sh"
cat > "$driver" <<EOF
#!/usr/bin/env bash
export PATH="$tmp/bin:\$PATH"
export M1_CI_CACHE="$tmp/cache"
source "$repo_root/hooks/lib.sh"
ensure_tool m1-fmt
EOF
chmod +x "$driver"

# --- 1. unauthenticated gh: the downloaded binary must be REFUSED -----------
set +e
out="$(bash "$driver" 2>&1)"
status=$?
set -e
[ "$status" -ne 0 ] \
  || fail "ensure_tool must refuse an unverifiable download (exit 0, output: $out)"
echo "$out" | grep -qi "verif" \
  || fail "refusal must explain the verification requirement, got: $out"
echo "$out" | grep -q "M1_CI_ALLOW_UNVERIFIED" \
  || fail "refusal must name the M1_CI_ALLOW_UNVERIFIED escape hatch, got: $out"
# Nothing executable may be left in the cache.
if compgen -G "$tmp/cache/m1-fmt-*" > /dev/null; then
  fail "no cached binary may remain after a refused download"
fi
echo "ok: unverifiable download is refused with a remedial message"

# --- 2. explicit escape hatch: proceeds, loudly ------------------------------
set +e
out="$(M1_CI_ALLOW_UNVERIFIED=1 bash "$driver" 2>&1)"
status=$?
set -e
[ "$status" -eq 0 ] \
  || fail "M1_CI_ALLOW_UNVERIFIED=1 must allow the download through, got: $out"
echo "$out" | grep -qi "unverified" \
  || fail "the escape hatch must warn loudly about the unverified binary, got: $out"
# The cached tool is the faked download.
path="$(echo "$out" | tail -n1)"
[ -x "$path" ] || fail "escape-hatch run must print the cached executable path, got: $path"
echo "ok: M1_CI_ALLOW_UNVERIFIED=1 proceeds with a loud warning"

echo "PASS: hook-verify-required"
