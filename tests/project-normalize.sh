#!/usr/bin/env bash
# Regression test for hooks/m1-project-normalize.
#
# The hook splits M1 Build's per-save output into two categories and MUST treat
# them differently:
#
#   normalised  BuildNumber, VersionMajor/Minor, Locale — noise, rewritten
#   asserted    ProductVersion, FileFormat, System@*    — facts about the M1
#               Build and firmware that produced the file, reported only
#
# Getting that split wrong is not cosmetic. Rewriting an asserted attribute
# fabricates history: forcing FileFormat backwards labels a converted file as
# the old format, and forcing ProductVersion backwards produces a file claiming
# an M1 Build wrote a format it cannot emit. Rewriting System@ silently reverts
# a deliberate firmware-package change.
#
# It also has to survive the filenames these projects actually use: M1 Build
# happily writes "Logging Setup.m1dls" and "PDM P14.m1dbc". A joined-string
# accumulator word-splits those into separate arguments, rewriting the wrong
# paths and printing an unrunnable `git add` line.
#
# Hermetic: the hook shells out to perl only, downloading nothing.

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
hook="$repo_root/hooks/m1-project-normalize"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# A project carrying the decoys that must never be rewritten: a nested
# revision-history <Project> entry and a <File> element, both with their own
# version attributes. Only the <Project> that also carries FileFormat is the
# real header.
write_project() { # <path> <productversion> <fileformat> <buildnumber> <locale> <systembuild>
  cat > "$1" <<EOF
<?xml version="1.0"?>
<MoTeCM1BuildSession Locale="$5" DefaultLocale="C" ProductName="M1Build (x64)" ProductVersion="$2">
 <Project FileFormat="$3" Name="TEST" VersionMajor="1" VersionMinor="0" BuildNumber="$4">
  <Project Name="HISTORY" Version="old build" Major="1" Minor="1" Build="9"/>
  <File Name="thing" BuildNumber="21"/>
  <System VersionMajor="1" VersionMinor="4" VersionRelease="0" VersionBuild="$6" SelectedRelease="0"/>
 </Project>
</MoTeCM1BuildSession>
EOF
}

write_config() {
  cat > "$tmp/m1-tools.toml" <<'EOF'
[project-baseline]
product_version = "1.4.5.556"
file_format = "10109"
locale = "English_Australia.1252"

[project-baseline.system]
VersionBuild = "0108"
EOF
}

cd "$tmp"

# --- 1. no [project-baseline] at all is a clean no-op -----------------------
: > m1-tools.toml
write_project "clean.m1prj" "1.4.5.556" "10109" "0" "English_Australia.1252" "0108"
cp clean.m1prj expected.m1prj
"$hook" clean.m1prj >/dev/null 2>&1 || fail "no-config should exit 0"
cmp -s clean.m1prj expected.m1prj || fail "no-config must not modify the file"
echo "ok: no [project-baseline] -> no-op"

write_config

# --- 2. an already-baselined file passes untouched --------------------------
"$hook" clean.m1prj >/dev/null 2>&1 || fail "baselined file should exit 0"
cmp -s clean.m1prj expected.m1prj || fail "baselined file must not be modified"
echo "ok: already at baseline -> exit 0, untouched"

# --- 3. per-save noise is normalised, decoys are left alone -----------------
write_project "noisy.m1prj" "1.4.5.556" "10109" "162" "English_United States.1252" "0108"
if "$hook" noisy.m1prj >/dev/null 2>&1; then
  fail "a rewrite must exit non-zero so the change is reviewed and re-staged"
fi
cmp -s noisy.m1prj expected.m1prj || fail "noise was not normalised back to the baseline"
grep -q 'Name="HISTORY" Version="old build" Major="1" Minor="1" Build="9"' noisy.m1prj \
  || fail "the revision-history <Project> decoy was rewritten"
grep -q '<File Name="thing" BuildNumber="21"/>' noisy.m1prj \
  || fail "the <File> BuildNumber decoy was rewritten"
echo "ok: BuildNumber + Locale normalised; history/File decoys untouched"

# --- 4. asserted facts are reported, never rewritten ------------------------
for case in "ProductVersion:1.4.4.981:10109:0108" \
            "FileFormat:1.4.5.556:10108:0108" \
            "System:1.4.5.556:10109:0107"; do
  name="${case%%:*}"; rest="${case#*:}"
  pv="${rest%%:*}"; rest="${rest#*:}"
  ff="${rest%%:*}"; sb="${rest##*:}"
  write_project "drift.m1prj" "$pv" "$ff" "0" "English_Australia.1252" "$sb"
  cp drift.m1prj before.m1prj
  out="$("$hook" drift.m1prj 2>&1)" && fail "$name drift must exit non-zero"
  cmp -s drift.m1prj before.m1prj || fail "$name drift must NOT modify the file"
  printf '%s' "$out" | grep -q "differs from the pinned baseline" \
    || fail "$name drift must report the mismatch"
  echo "ok: $name drift reported, file untouched"
done

# --- 5. filenames with spaces survive intact --------------------------------
spaced="Logging Setup.m1dls"
write_project "$spaced" "1.4.5.556" "10109" "77" "English_United States.1252" "0108"
out="$("$hook" "$spaced" 2>&1)" && fail "spaced-filename rewrite must exit non-zero"
cmp -s "$spaced" expected.m1prj || fail "the spaced file was not normalised"
[ ! -e "Logging" ] && [ ! -e "Setup.m1dls" ] || fail "the filename was word-split into separate paths"
printf '%s' "$out" | grep -qE "git add .*(Logging\\\\ Setup|'Logging Setup'|\"Logging Setup\")" \
  || fail "the staging command must quote/escape the space: $out"
echo "ok: filename with spaces normalised, staging command shell-safe"

echo "PASS: project-normalize"
