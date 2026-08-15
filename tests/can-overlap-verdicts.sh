#!/usr/bin/env bash
# Regression test for hooks/m1-can-overlap-check.
#
# `m1-can inspect` is an analysis verb: it emits JSON and exits 0 whatever it
# finds, so the hook applies the verdict. Each verdict means something
# different and must be handled differently:
#
#   same-bus       a real clash            -> fail
#   different-bus  proven safe (ids are per-bus) -> pass
#   unknown        a bus the project has no value for -> pass, but report
#
# Failing on `unknown` would gate on absence of evidence; passing it silently
# would hide a possible clash. It is also the shape most easily got wrong:
# `unknown` overlaps OMIT the top-level "bus" key entirely (only present when
# every module resolved to the same bus), so rendering it blindly prints
# "on bus None".
#
# Hermetic: a stub m1-can is planted in the hook's own cache directory, keyed
# tool+version exactly as ensure_tool expects, so nothing is downloaded.

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
hook="$repo_root/hooks/m1-can-overlap-check"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# ensure_tool resolves $CACHE_DIR/m1-can-<version> from tools.env and returns it
# immediately when executable — so planting the stub there avoids the network.
version="$(grep -E '^M1_CAN_VERSION=' "$repo_root/tools.env" | head -n1 | cut -d= -f2)"
[ -n "$version" ] || fail "M1_CAN_VERSION missing from tools.env"

export M1_CI_CACHE="$tmp/cache"
mkdir -p "$M1_CI_CACHE"
cat > "$M1_CI_CACHE/m1-can-$version" <<'STUB'
#!/usr/bin/env bash
# Stub m1-can: emits the canned report the test selected.
cat "$M1_CAN_STUB_JSON"
STUB
chmod +x "$M1_CI_CACHE/m1-can-$version"

run_case() { # <name> <json> <expected exit>
  export M1_CAN_STUB_JSON="$tmp/$1.json"
  printf '%s' "$2" > "$M1_CAN_STUB_JSON"
  set +e
  out="$("$hook" --project fake.m1prj 2>&1)"
  rc=$?
  set -e
  [ "$rc" -eq "$3" ] || fail "$1: expected exit $3, got $rc — $out"
  printf '%s' "$out"
}

# --- no overlaps ------------------------------------------------------------
out="$(run_case none '{"total_messages":70,"id_overlaps":[]}' 0)"
printf '%s' "$out" | grep -q "CAN ids OK" || fail "clean run should report OK: $out"
echo "ok: no overlaps -> pass"

# --- different-bus: legitimate reuse ---------------------------------------
out="$(run_case diffbus '{"total_messages":70,"id_overlaps":[{"can_id":112,"can_id_hex":"0x70","verdict":"different-bus","depends_on_calibration":false,"messages":[{"path":"A.Msg","module":"A","bus":"0","direction":"TX"},{"path":"B.Msg","module":"B","bus":"2","direction":"RX"}]}]}' 0)"
printf '%s' "$out" | grep -q "different buses" || fail "different-bus should be noted as legitimate: $out"
echo "ok: different-bus -> pass, reported as legitimate"

# --- same-bus: a real clash -------------------------------------------------
out="$(run_case samebus '{"total_messages":70,"id_overlaps":[{"can_id":356,"can_id_hex":"0x164","verdict":"same-bus","bus":"2","depends_on_calibration":false,"messages":[{"path":"S.AIRSPEED","module":"S","bus":"2","direction":"RX"},{"path":"S.ALTITUDE","module":"S","bus":"2","direction":"RX"}]}]}' 1)"
printf '%s' "$out" | grep -q "0x164" || fail "clash must name the identifier: $out"
printf '%s' "$out" | grep -q "S.AIRSPEED" || fail "clash must name both messages: $out"
printf '%s' "$out" | grep -q "S.ALTITUDE" || fail "clash must name both messages: $out"
echo "ok: same-bus -> fail, both messages named"

# --- unknown: reported, not failed, and never rendered as "None" ------------
out="$(run_case unknown '{"total_messages":70,"id_overlaps":[{"can_id":112,"can_id_hex":"0x70","verdict":"unknown","depends_on_calibration":false,"messages":[{"path":"A.Msg","module":"A","bus":"0","direction":"TX"},{"path":"B.Msg","module":"B","direction":"RX"}]}]}' 0)"
printf '%s' "$out" | grep -qi "none" && fail "an unresolved bus must not render as \"None\": $out"
printf '%s' "$out" | grep -q "unresolved" || fail "an unresolved bus must be stated explicitly: $out"
printf '%s' "$out" | grep -q "WARN" || fail "unknown overlaps must be reported: $out"
echo "ok: unknown -> pass, reported, no \"None\""

# --- calibration-dependent verdicts are flagged -----------------------------
out="$(run_case calib '{"total_messages":70,"id_overlaps":[{"can_id":356,"can_id_hex":"0x164","verdict":"same-bus","bus":"2","depends_on_calibration":true,"messages":[{"path":"S.A","module":"S","bus":"2","direction":"RX"},{"path":"S.B","module":"S","bus":"2","direction":"RX"}]}]}' 1)"
printf '%s' "$out" | grep -q "retune" || fail "calibration-dependent verdicts must say so: $out"
echo "ok: depends_on_calibration surfaced"

echo "PASS: can-overlap-verdicts"
