#!/usr/bin/env bash
# test_install_links.sh — install.sh links every herd flow v2 tool into ~/.local/bin, idempotently,
# and --uninstall removes exactly the links it made. Runs against a throwaway HOME (never the real one)
# with fake herdr/pi on PATH that fail loudly if called.
#
#   bash tests/docs/test_install_links.sh
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/install-links-test.XXXXXX")"
trap 'rm -rf "${tmp:?}"' EXIT
export HOME="$tmp/home"
mkdir -p "$HOME" "$tmp/fakebin"
for b in herdr pi; do
  printf '#!/bin/sh\necho "fake %s must not be called: $*" >&2\nexit 99\n' "$b" > "$tmp/fakebin/$b"
  chmod +x "$tmp/fakebin/$b"
done
export PATH="$tmp/fakebin:$HOME/.local/bin:$PATH"

pass=0 fail=0
check() { if eval "$2"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL $1"; fi; }

bins="m2herd m2herd-up m2herd-migrate herd-board herd-spawn herd-phase herd-watch herd-limits herd-recover herd-clash herd-merge herd-context m2herd-purge m2herd-steer"
declare -A src=([m2herd]=m2herd.sh [m2herd-up]=m2herd-up.sh [herd-spawn]=herd-spawn.sh)

# a link of the user's own, pointing elsewhere, must survive --uninstall
mkdir -p "$HOME/.local/bin" "$tmp/own"
printf '#!/bin/sh\n' > "$tmp/own/herd-limits"
ln -s "$tmp/own/herd-limits" "$HOME/.local/bin/herd-limits-own"
# a hand-placed real file where a link goes is moved aside, never deleted
printf '#!/bin/sh\necho local\n' > "$HOME/.local/bin/herd-clash"

out1="$(bash "$REPO/scripts/install.sh" --claude 2>&1)" || { echo "$out1"; echo "FAIL install exit"; exit 1; }
for b in $bins; do
  s="${src[$b]:-$b}"
  check "linked $b" '[ -L "$HOME/.local/bin/$b" ] && [ "$(readlink "$HOME/.local/bin/$b")" = "$REPO/scripts/$s" ]'
done
check "real file moved aside" 'ls "$HOME/.local/bin/" | grep -q "^herd-clash.bak-"'
check "moved file kept its content" 'grep -q local "$HOME"/.local/bin/herd-clash.bak-*'

# linked tools resolve their own dir (herd_events import) through the symlink
check "herd-phase --help via link" '"$HOME/.local/bin/herd-phase" --help >/dev/null 2>&1'
check "herd-context --help via link" '"$HOME/.local/bin/herd-context" --help >/dev/null 2>&1'
check "m2herd-migrate --help via link" '"$HOME/.local/bin/m2herd-migrate" --help >/dev/null 2>&1'

# idempotent: a second run leaves the same links and no new backups
before="$(ls -la "$HOME/.local/bin" | awk '{print $9, $10, $11}' | sort)"
out2="$(bash "$REPO/scripts/install.sh" --claude 2>&1)" || { echo "$out2"; echo "FAIL reinstall exit"; exit 1; }
after="$(ls -la "$HOME/.local/bin" | awk '{print $9, $10, $11}' | sort)"
check "second install identical" '[ "$before" = "$after" ]'
check "no fake binary called" '! grep -q "must not be called" <<<"$out1$out2"'

# retired herd-review-mark is noted, never touched
printf '#!/bin/sh\n' > "$HOME/.local/bin/herd-review-mark"
out3="$(bash "$REPO/scripts/install.sh" --claude 2>&1)"
check "retired herd-review-mark noted" 'grep -q "herd-review-mark is retired" <<<"$out3"'
check "retired herd-review-mark kept" '[ -f "$HOME/.local/bin/herd-review-mark" ]'

out4="$(bash "$REPO/scripts/install.sh" --claude --uninstall 2>&1)" || { echo "$out4"; echo "FAIL uninstall exit"; exit 1; }
for b in $bins; do
  check "unlinked $b" '[ ! -e "$HOME/.local/bin/$b" ] && [ ! -L "$HOME/.local/bin/$b" ]'
done
check "own link survives uninstall" '[ -L "$HOME/.local/bin/herd-limits-own" ]'
check "backup survives uninstall" 'ls "$HOME/.local/bin/" | grep -q "^herd-clash.bak-"'

# a foreign link under one of our names is kept by --uninstall
ln -s "$tmp/own/herd-limits" "$HOME/.local/bin/herd-limits"
out5="$(bash "$REPO/scripts/install.sh" --claude --uninstall 2>&1)"
check "foreign link with our name kept" '[ -L "$HOME/.local/bin/herd-limits" ] && grep -q "kept .*herd-limits" <<<"$out5"'

echo "test_install_links: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
