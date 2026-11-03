#!/usr/bin/env bash
# An empty missions.tsv is not a finished portfolio (fleet-loop.sh tick). Offline: temp HOME, no herdr.
set -u
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0 fail=0
check() { if eval "$2"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL $1"; fi; }
HOME="$T" bash "$REPO/scripts/fleet-loop.sh" init --ws "$T/f" >/dev/null 2>&1
out="$(HOME="$T" bash "$REPO/scripts/fleet-loop.sh" tick --ws "$T/f" --dry-run 2>&1)"
check "empty fleet waits for missions" 'printf "%s" "$out" | grep -q "STATUS: AWAITING_SOLO"'
check "empty fleet is not complete" '! printf "%s" "$out" | grep -q "MISSION_COMPLETE"'
echo "test_empty_fleet: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
