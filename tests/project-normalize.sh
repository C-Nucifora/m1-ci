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
# Hermetic: the hook uses Python 3.11+ and Perl, downloading nothing.

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

# Configured locale is XML data, never Perl source.
cat > m1-tools.toml <<'EOF'
[project-baseline]
product_version = "1.4.5.556"
file_format = "10109"
locale = "@{[system(q(touch INJECTED))]}<&/$value"
EOF
cat > locales.m1cfg <<'EOF'
<MoTeCM1BuildSession Locale="old" ProductVersion="1.4.5.556">
 <LogSetup Locale="old"/>
 <Configuration Locale="old"/>
</MoTeCM1BuildSession>
EOF
cat > expected-locales.m1cfg <<'EOF'
<MoTeCM1BuildSession Locale="@{[system(q(touch INJECTED))]}&lt;&amp;/$value" ProductVersion="1.4.5.556">
 <LogSetup Locale="@{[system(q(touch INJECTED))]}&lt;&amp;/$value"/>
 <Configuration Locale="@{[system(q(touch INJECTED))]}&lt;&amp;/$value"/>
</MoTeCM1BuildSession>
EOF
"$hook" locales.m1cfg >locale-output.txt 2>&1 && fail "locale rewrite must exit non-zero"
[ ! -e INJECTED ] || fail "locale executed Perl code"
cmp -s locales.m1cfg expected-locales.m1cfg || fail "locale data was not XML escaped"
"$hook" locales.m1cfg >/dev/null 2>&1 || fail "escaped locale must be idempotent"
echo "ok: locale remains escaped data on all supported elements"

# TOML syntax and section placement must not disable baseline assertions.
for syntax in indented literal unrelated; do
  case "$syntax" in
    indented)
      printf '  [project-baseline]\n  product_version = "1"\n  file_format = "1"\n' > m1-tools.toml ;;
    literal)
      cat > m1-tools.toml <<'EOF'
[project-baseline]
product_version = '1'
file_format = '1'
EOF
      ;;
    unrelated)
      cat > m1-tools.toml <<'EOF'
[unrelated]
product_version = "2"
file_format = "2"
[project-baseline]
product_version = "1"
file_format = "1"
EOF
      ;;
  esac
  write_project drift.m1prj "2" "2" "19" "old" "0108"
  cp drift.m1prj before.m1prj
  out="$("$hook" drift.m1prj 2>&1)" && fail "$syntax TOML bypassed drift assertion"
  printf '%s' "$out" | grep -q 'differs from the pinned baseline' || fail "$syntax TOML was not parsed"
  cmp -s drift.m1prj before.m1prj || fail "$syntax drift modified the file"
done
for invalid in '[project-baseline' '[project-baseline]' 'project-baseline = 3'; do
  printf '%s\n' "$invalid" > m1-tools.toml
  rc=0
  "$hook" drift.m1prj >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "invalid baseline must exit 2, got $rc"
  cmp -s drift.m1prj before.m1prj || fail "invalid baseline modified the file"
done
echo "ok: TOML sections and validation cannot bypass assertions"

# Literal TOML strings can contain quotes without corrupting XML attributes.
cat > m1-tools.toml <<'EOF'
[project-baseline]
product_version = '1.4.5.556'
file_format = '10109'
locale = 'A "quoted" & <locale>'
  [project-baseline.system]
  VersionBuild = '0108'
EOF
write_project quoted.m1prj "1.4.5.556" "10109" "9" "old" "0108"
"$hook" quoted.m1prj >/dev/null 2>&1 && fail "quoted locale rewrite must exit non-zero"
grep -q 'Locale="A &quot;quoted&quot; &amp; &lt;locale&gt;"' quoted.m1prj || fail "quoted locale corrupted XML"
"$hook" quoted.m1prj >/dev/null 2>&1 || fail "quoted locale must be idempotent"

# Reject config-controlled attribute syntax before modifying any file.
cat >> m1-tools.toml <<'EOF'
"VersionBuild.*" = "0108"
EOF
cp quoted.m1prj before.m1prj
rc=0
"$hook" quoted.m1prj >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "invalid System attribute must fail configuration validation"
cmp -s quoted.m1prj before.m1prj || fail "invalid System attribute modified the file"

# Rewriting a working file must leave its staged content alone.
write_config
git init -q staged
cp m1-tools.toml staged/
write_project staged/Project.m1prj "1.4.5.556" "10109" "0" "English_Australia.1252" "0108"
git -C staged add Project.m1prj
staged_before="$(git -C staged ls-files -s)"
write_project staged/Project.m1prj "1.4.5.556" "10109" "8" "old" "0108"
(cd staged && "$hook" Project.m1prj >/dev/null 2>&1) && fail "partially staged rewrite must stop commit"
[ "$staged_before" = "$(git -C staged ls-files -s)" ] || fail "hook modified the index"
echo "ok: quoted locale, attribute validation and partial staging"

# XML 1.0 excludes these noncharacters even though TOML accepts them.
for noncharacter in '\uFFFE' '\uFFFF'; do
  printf '[project-baseline]\nproduct_version = "1"\nfile_format = "1"\nlocale = "%s"\n' "$noncharacter" > m1-tools.toml
  cp quoted.m1prj before.m1prj
  rc=0
  "$hook" quoted.m1prj >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "invalid XML locale must exit 2"
  cmp -s quoted.m1prj before.m1prj || fail "invalid XML locale modified the file"
done

echo "PASS: project-normalize"
