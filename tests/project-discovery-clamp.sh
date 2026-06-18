#!/usr/bin/env bash
# Regression test for Project.m1prj auto-discovery in check.yml's
# project-validate job ("Locate Project.m1prj" step).
#
# The original discovery was:
#   find "$SCRIPTS_PATH/.." "$SCRIPTS_PATH" -maxdepth 3 -type f \
#     -name 'Project.m1prj' -print -quit
# With the default scripts-path "." this searches "./..", the PARENT of the
# caller's checkout. On a GitHub runner that is /home/runner/work/<repo> (the
# workspace's parent), so a Project.m1prj sitting next to the checkout — or in a
# sibling checkout reachable via -maxdepth 3 — is picked up and validated as if
# it belonged to the project under test. And `-print -quit` returns the first
# match in unspecified traversal order, so a repo with several Project.m1prj
# files (multiple vehicle variants) silently validates an arbitrary one.
#
# The fix keeps in-repo upward discovery but:
#   1. confines every candidate to $GITHUB_WORKSPACE (reject anything outside it);
#   2. is deterministic + nearest-first: search $SCRIPTS_PATH first, and only
#      fall back one level up (still clamped to the workspace) if nothing is
#      found below.
#
# This test has two parts:
#   1. Static: assert check.yml's Locate step clamps to GITHUB_WORKSPACE.
#   2. Behavioural: drive the same discovery shell and prove it (a) rejects a
#      Project.m1prj that lives outside the workspace, and (b) prefers the
#      in-repo (under scripts-path) file over one a level up.

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
workflow="$repo_root/.github/workflows/check.yml"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# --- Part 1: static ---------------------------------------------------------
#
# The Locate step must reference GITHUB_WORKSPACE to clamp discovery to the
# caller's checkout. (Before the fix the step never mentioned it, so a match in
# the workspace's parent was accepted.)
awk '/^      - name: Locate Project.m1prj$/{f=1} f{print} /^      - name: Install m1-project$/{f=0}' \
  "$workflow" > "$tmp/locate-step.txt"
[ -s "$tmp/locate-step.txt" ] || fail "could not extract the 'Locate Project.m1prj' step from check.yml"

grep -q 'GITHUB_WORKSPACE' "$tmp/locate-step.txt" \
  || fail "the Locate step does not clamp discovery to GITHUB_WORKSPACE"

# It must no longer hand the unconditional parent ".." to find as a search root
# (that is exactly the out-of-checkout walk this fixes).
# shellcheck disable=SC2016  # grep regex literal; the $ must stay unexpanded
if grep -qE 'find "\$SCRIPTS_PATH/\.\." "\$SCRIPTS_PATH"' "$tmp/locate-step.txt"; then
  fail "the Locate step still searches \$SCRIPTS_PATH/.. as an unclamped find root"
fi

echo "ok: check.yml's Locate step clamps Project.m1prj discovery to GITHUB_WORKSPACE"

# --- Part 2: behavioural ----------------------------------------------------
#
# Reproduce the discovery shell and assert the two properties. The shell here is
# the implementation the workflow uses; if it regresses, the static check above
# already fails, but the behavioural check pins the exact contract.

discover() {
  # $1 = GITHUB_WORKSPACE, $2 = SCRIPTS_PATH (relative to the workspace).
  # Mirrors the Locate step: search scripts-path first, then one level up,
  # rejecting any candidate outside the workspace.
  local GITHUB_WORKSPACE="$1" SCRIPTS_PATH="$2" file ws cand
  ws="$(realpath -m "$GITHUB_WORKSPACE")"
  file=""
  cd "$GITHUB_WORKSPACE" || return 1
  # Nearest first: in-repo under scripts-path.
  file="$(find "$SCRIPTS_PATH" -maxdepth 3 -type f \
    -name 'Project.m1prj' -print 2>/dev/null | sort | head -n1 || true)"
  # Fall back one level up, still clamped to the workspace.
  if [ -z "$file" ]; then
    file="$(find "$SCRIPTS_PATH/.." -maxdepth 3 -type f \
      -name 'Project.m1prj' -print 2>/dev/null | sort | head -n1 || true)"
  fi
  # Reject anything outside the workspace.
  if [ -n "$file" ]; then
    cand="$(cd "$GITHUB_WORKSPACE" && realpath -m "$file")"
    case "$cand/" in
      "$ws"/*) : ;;
      *) file="" ;;
    esac
  fi
  printf '%s\n' "$file"
}

# Layout: a workspace checkout with a parent that ALSO holds a Project.m1prj
# (the runner's /home/runner/work/<repo> situation).
parent="$tmp/work"
ws="$parent/repo"
mkdir -p "$ws"
: > "$parent/Project.m1prj"          # OUTSIDE the checkout — must never be picked
touch -t 200001010000 "$parent/Project.m1prj"

# Case A: no Project.m1prj inside the checkout. With the default scripts-path
# ".", discovery must NOT reach up into the parent and grab the stray file.
got="$(discover "$ws" ".")"
[ -z "$got" ] \
  || fail "discovery returned an out-of-workspace file: '$got' (parent's Project.m1prj must be rejected)"
echo "ok: a Project.m1prj in the workspace's parent is not discovered"

# Case B: a Project.m1prj exists directly under scripts-path AND another sits a
# level up (the project root). Nearest-first must prefer the one UNDER
# scripts-path (the in-repo, deepest match) over the one a level up.
mkdir -p "$ws/UQR-EV/Scripts"
: > "$ws/UQR-EV/Project.m1prj"                # project root (one level up)
: > "$ws/UQR-EV/Scripts/Project.m1prj"        # under scripts-path — must win
got="$(discover "$ws" "UQR-EV/Scripts")"
cand="$(cd "$ws" && realpath -m "$got")"
[ "$cand" = "$(realpath -m "$ws/UQR-EV/Scripts/Project.m1prj")" ] \
  || fail "nearest-first discovery picked '$got' ($cand), expected the under-scripts-path UQR-EV/Scripts/Project.m1prj"
# And it must be inside the workspace.
case "$cand/" in
  "$(realpath -m "$ws")"/*) : ;;
  *) fail "discovered file '$got' resolved outside the workspace" ;;
esac
echo "ok: nearest-first discovery prefers the Project.m1prj under scripts-path"

# Case C: nothing under scripts-path, but a Project.m1prj at the project root
# one level up (still inside the workspace) — the legitimate upward case that
# discovery must still find.
rm -rf "$ws/UQR-EV"
mkdir -p "$ws/Scripts"
: > "$ws/Project.m1prj"                       # repo root, one above scripts-path
got="$(discover "$ws" "Scripts")"
cand="$(cd "$ws" && realpath -m "$got")"
[ "$cand" = "$(realpath -m "$ws/Project.m1prj")" ] \
  || fail "upward discovery within the workspace failed: picked '$got' ($cand), expected the repo-root Project.m1prj"
echo "ok: a Project.m1prj one level up but inside the workspace is still discovered"

echo "PASS: Project.m1prj discovery is clamped to the workspace and deterministic nearest-first"
