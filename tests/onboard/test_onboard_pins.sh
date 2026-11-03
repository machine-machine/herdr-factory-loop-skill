#!/usr/bin/env bash
# onboard.sh pin checks never abort onboarding: an existing specify of unknown origin (pipx, PyPI)
# is warned about and recorded, config.toml is written. Offline: temp HOME, fake uv/specify.
set -u
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0 fail=0
check() { if eval "$2"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL $1"; fi; }
mkdir -p "$T/bin" "$T/uvtools" "$T/home"
printf '#!/bin/sh\necho specify\n' > "$T/bin/specify"
printf '#!/bin/sh\n[ "$1 $2" = "tool dir" ] && echo %s/uvtools\n' "$T" > "$T/bin/uv"
chmod +x "$T/bin/specify" "$T/bin/uv"
run() { HOME="$T/home" XDG_CONFIG_HOME="$T/home/.config" PATH="$T/bin:$PATH" M2HERD_AUTO_UPDATE=0 bash "$REPO/scripts/onboard.sh" --yes --orchestrator cursor > "$T/out" 2>&1; }
cfg="$T/home/.config/herdr-factory/config.toml"

run; rc=$?
check "unknown specify origin: onboarding completes" '[ "$rc" -eq 0 ]'
check "unknown specify origin: warned with the pin command" 'grep -q "spec-kit is at an unknown commit" "$T/out"'
check "config records ref and empty installed" 'grep -q "^ref = \"" "$cfg" && grep -q "^installed = \"\"" "$cfg"'

# a uv tool install at the pinned commit is recognised
pin="$(sed -n 's/^SPEC_KIT_REF="\(.*\)"/\1/p' "$REPO/scripts/onboard.sh")"
d="$T/uvtools/specify-cli/lib/python3.12/site-packages/specify_cli-1.0.dist-info"; mkdir -p "$d"
printf '{"url":"x","vcs_info":{"vcs":"git","commit_id":"%s"}}\n' "$pin" > "$d/direct_url.json"
run; rc=$?
check "pinned specify: recognised" '[ "$rc" -eq 0 ] && grep -q "spec-kit at the pinned commit" "$T/out" && grep -q "^installed = \"$pin\"" "$cfg"'
echo "test_onboard_pins: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
