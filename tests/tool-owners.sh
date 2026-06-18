#!/usr/bin/env bash
# Regression test for the tool->owner map (#<this PR>).
#
# Every M1 tool lives under the C-Nucifora org EXCEPT m1-project, which lives
# under nedlane. That single exception is encoded independently in THREE places,
# with no guard asserting they agree:
#
#   1. hooks/lib.sh    tool_owner()         — `m1-project) echo "nedlane"`, the
#                                             default arm is C-Nucifora. Drives
#                                             the pre-commit hook download URL.
#   2. .github/workflows/drift-canary.yml   — `[m1-project]="nedlane/m1-project"`
#                                             in the `repos` assoc-array. Drives
#                                             which repo the canary queries for
#                                             the latest release.
#   3. .github/workflows/check.yml          — `repo: nedlane/m1-project` passed
#                                             to the install-m1-tool action.
#                                             Drives the CI download URL.
#
# If a second nedlane-owned tool is added (or m1-project moves orgs) all three
# must change in lock-step. Miss one and the hook, the canary, or CI silently
# uses the wrong owner: a 404 -> spurious source-build fallback, or a stale
# drift comparison against a repo that no longer exists.
#
# Every other cross-file invariant in this repo (tools.env vs check.yml
# defaults, m1-ci-ref vs VERSION, example override comments) has a dedicated
# ci.yml guard; the owner map is the one shared constant that had none. This
# test is that guard: it extracts the SET of nedlane-owned tools from each of
# the three sites and asserts all three sets are identical.

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
lib="$repo_root/hooks/lib.sh"
canary="$repo_root/.github/workflows/drift-canary.yml"
check="$repo_root/.github/workflows/check.yml"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# Sorted, newline-separated set of nedlane-owned tool names from each site.

# 1. hooks/lib.sh tool_owner(): every `<tool>) echo "nedlane"` case arm. The
#    `*) echo "C-Nucifora"` default is the implicit owner for everything else,
#    so only the explicit non-default arms are the override set.
lib_owners="$(grep -oE '[A-Za-z0-9._-]+\) echo "nedlane"' "$lib" \
  | sed -E 's/\).*//' | sort -u)"

# 2. drift-canary.yml: every `[<tool>]="nedlane/<tool>"` assoc-array entry.
canary_owners="$(grep -oE '\[[A-Za-z0-9._-]+\]="nedlane/[A-Za-z0-9._-]+"' "$canary" \
  | sed -E 's/^\[([^]]+)\]=.*/\1/' | sort -u)"

# 3. check.yml: every `repo: nedlane/<tool>` literal handed to install-m1-tool.
check_owners="$(grep -oE 'repo:[[:space:]]+nedlane/[A-Za-z0-9._-]+' "$check" \
  | sed -E 's#.*nedlane/##' | sort -u)"

echo "hooks/lib.sh nedlane-owned:      ${lib_owners//$'\n'/ }"
echo "drift-canary.yml nedlane-owned:  ${canary_owners//$'\n'/ }"
echo "check.yml nedlane-owned:         ${check_owners//$'\n'/ }"

# The override set must be non-empty (m1-project exists) so a botched regex that
# silently matches nothing in every site can't pass by vacuous agreement.
[ -n "$lib_owners" ] \
  || fail "hooks/lib.sh tool_owner() has no nedlane override arm — expected at least m1-project"

# All three sets must be byte-identical.
if [ "$lib_owners" != "$canary_owners" ]; then
  fail "nedlane-owned set differs: hooks/lib.sh has [${lib_owners//$'\n'/ }] but drift-canary.yml has [${canary_owners//$'\n'/ }] — update all three sites in lock-step"
fi
if [ "$lib_owners" != "$check_owners" ]; then
  fail "nedlane-owned set differs: hooks/lib.sh has [${lib_owners//$'\n'/ }] but check.yml has [${check_owners//$'\n'/ }] — update all three sites in lock-step"
fi

echo "ok: the nedlane-owned tool set agrees across hooks/lib.sh, drift-canary.yml and check.yml"

echo "PASS: tool-owners"
