#!/usr/bin/env bash
# test-herd-board.sh — offline integration test for scripts/herd-board (docs/herd-flow-v2.md §3).
#
# Writes events through the real herd-phase CLI, puts fake `herdr`, `gh`, `herd-limits` and `herd-clash` on PATH,
# runs `herd-board --once` and checks the lanes. HOME is a temp dir, so nothing under ~/.cache or ~/.claude is read
# or written. The board is copied next to herd_events.py in a temp dir, so sibling tools that land in scripts/
# later cannot leak into the "tool absent" case.
#
# Usage: tests/board/test-herd-board.sh        (exit 0 = all checks passed)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
PY="$(command -v python3)"
pass=0 fail=0
ok()   { echo "ok: $1"; pass=$((pass + 1)); }
bad()  { echo "FAIL: $1"; fail=$((fail + 1)); }
has()  { if grep -qF -- "$2" <<<"$OUT"; then ok "$1"; else bad "$1 (missing: $2)"; printf '%s\n' "$OUT" | sed 's/^/    | /'; fi; }
hasnt(){ if grep -qF -- "$2" <<<"$OUT"; then bad "$1 (unexpected: $2)"; else ok "$1"; fi; }

mkdir -p "$T/home" "$T/board" "$T/fake" "$T/notools"
cp "$REPO_ROOT/scripts/herd-board" "$REPO_ROOT/scripts/herd_events.py" "$REPO_ROOT/scripts/herd-phase" "$T/board/"
chmod +x "$T/board/herd-board" "$T/board/herd-phase"
SHA_A=$(printf 'a%.0s' $(seq 40)); SHA_B=$(printf 'b%.0s' $(seq 40)); SHA_C=$(printf 'c%.0s' $(seq 40))

# --- fakes -----------------------------------------------------------------------------------------------------
cat >"$T/fake/herdr" <<EOF
#!/usr/bin/env bash
echo "herdr \$*" >>"$T/calls.log"
if [ "\$1 \$2" = "agent list" ]; then
  cat <<'J'
{"result": {"agents": [
  {"pane_id": "w1:p1", "agent_status": "working", "cwd": "$T/wt/acme-api/run"},
  {"pane_id": "w1:p2", "agent_status": "blocked", "cwd": "$T/wt/acme-api/blk"},
  {"pane_id": "w1:p3", "agent_status": "idle",    "cwd": "$T/wt/acme-api/rep"},
  {"pane_id": "w0:p9", "agent_status": "working", "cwd": "$T/wt/acme-api/old"}
]}}
J
  exit 0
fi
[ "\$1 \$2" = "tab list" ] && [ -z "\${FAKE_HERDR_DOWN:-}" ] && { echo '{"result": {"tabs": []}}'; exit 0; }
exit 1
EOF
cat >"$T/fake/gh" <<EOF
#!/usr/bin/env bash
echo "gh \$*" >>"$T/calls.log"
case "\$*" in
  "pr view 20 -R acme/acme-api"*) echo "OPEN $SHA_A" ;;     # reviewed head -> clean
  "pr view 30 -R acme/acme-api"*) echo "OPEN $SHA_C" ;;     # reviewed $SHA_B, now $SHA_C -> stale
  "api repos/acme/acme-api/commits/HEAD"*) echo "$SHA_A" ;;
  *"search/issues"*) echo "acme-api 77" ;;
  *) exit 1 ;;
esac
EOF
# same shapes as scripts/herd-limits --json (exit 0 = slot free, 1 = no slot)
cat >"$T/fake/herd-limits" <<'EOF'
#!/usr/bin/env bash
case " $* " in *" --json "*) ;; *) echo "fake herd-limits: board must ask with --json" >&2; exit 2 ;; esac
if [ -n "${FAKE_LIMITS_FULL:-}" ]; then
  echo '{"ok": false, "used": 6, "max": 6, "review": 2, "free_mb": 12000, "min_free_mb": 8000, "load": 1.5, "max_load": 40, "reasons": ["all 6 slots used"]}'
  exit 1
fi
echo '{"ok": true, "used": 3, "max": 6, "review": 1, "free_mb": 12000, "min_free_mb": 8000, "load": 1.5, "max_load": 40, "reasons": []}'
EOF
cat >"$T/fake/herd-clash" <<'EOF'
#!/usr/bin/env bash
[ "${2:-}" = "--json" ] || { echo "usage: herd-clash <herd> --json" >&2; exit 2; }
# same shape as scripts/herd-clash --json
echo '{"pairs": [{"repo": "acme-api", "slices": ["blk", "run"], "files": ["src/a.py"], "relation": null}],
 "by_slice": {"blk": [{"other": "run"}], "run": [{"other": "blk"}]}, "changed": {}, "skipped": []}'
EOF
chmod +x "$T/fake/"*
ln -s "$T/fake/herdr" "$T/notools/herdr"; ln -s "$T/fake/gh" "$T/notools/gh"

export HOME="$T/home" NO_COLOR=1 COLUMNS=110 LINES=60 HERD_BOARD_LANG=de HERD_BOARD_ORG=acme \
  HERD_BOARD_REPOS="api=acme-api"
BASEPATH="$(dirname "$PY"):/usr/bin:/bin"
board() { PATH="$T/fake:$BASEPATH" "$T/board/herd-board" "$@"; }
phase() { PATH="$T/fake:$BASEPATH" "$T/board/herd-phase" "$@" >/dev/null; }

# --- a v2 herd written through herd-phase ----------------------------------------------------------------------
H="$T/herde-v2"; mkdir -p "$H"
for s in run blk rep; do mkdir -p "$T/wt/acme-api/$s"; done
phase "$H" q1 queued --field pos=1
phase "$H" run working --field pane=w1:p1 --field model=claude-opus-5-5 --field effort=high \
  --field "wt=[\"$T/wt/acme-api/run\"]"
phase "$H" blk working --field pane=w1:p2 --field model=fable-5.1 --field effort=medium
phase "$H" rep working --field pane=w1:p3 --field model=claude-sonnet-5-5 --field effort=medium
echo "report" >"$H/rep.out.md"
echo '{"short": "baut die Lanes", "step": 1, "of": 3}' >"$H/run.status.json"
for s in okp stp; do
  phase "$H" "$s" queued; phase "$H" "$s" working --field pane=w1:gone --field model=claude-opus-5-5 --field effort=high
  phase "$H" "$s" accepted; phase "$H" "$s" review_running --field round=1
done
phase "$H" okp review_ok --field "prs=[\"api#20@$SHA_A\"]" --field "main=[\"api@$SHA_A\"]"
phase "$H" stp review_ok --field "prs=[\"api#30@$SHA_B\"]" --field "main=[\"api@$SHA_A\"]"
phase "$H" fx queued; phase "$H" fx working; phase "$H" fx accepted; phase "$H" fx review_running
phase "$H" fx review_befund --field befunde_file=fx.befunde-abc1234.md; phase "$H" fx fix_queued
if phase "$H" q1 merged 2>/dev/null; then bad "herd-phase refuses queued -> merged"; else ok "herd-phase refuses queued -> merged"; fi

# --- a v1 herd: herd.map only ----------------------------------------------------------------------------------
V1="$T/herde-v1"; mkdir -p "$V1"
echo "old=w0:p9" >"$V1/herd.map"
echo '{"satz": "alter Worker", "schritt": 2, "von": 4}' >"$V1/old.status.json"

# --- checks ----------------------------------------------------------------------------------------------------
OUT="$(board --help)"; has "--help prints usage" "Usage: herd-board"
if board --bogus >/dev/null 2>&1; then bad "unknown option exits non-zero"; else ok "unknown option exits non-zero"; fi
OUT="$(board --selftest 2>&1)" && ok "--selftest passes ($(grep -c '^ok:' <<<"$OUT") checks)" || {
  bad "--selftest passes"; printf '%s\n' "$OUT" | grep -v '^ok:'; }

: >"$T/calls.log"
OUT="$(board --once "$H" "$V1")"
has "header: du + Plätze from herd-limits" "du: 2 Plätze 3/6 (1 Review)"
has "needs you: merge word" "✓✓ okp Wort: „merge okp“ · api#20@aaaaaaa"
has "needs you: blocked, with clash + tag" "? blk ⇄ run braucht Antwort F·md"
has "queue: fix first" "! fx Befunde zurück, startet als 1."
has "queue: queued second" "◌ q1 startet als 2."
has "working: tag + clash" "● run ⇄ blk baut die Lanes O·hi"
has "working: progress bar" "███░░░░░░░ 1/3"
has "reported: thin ✓" "✓ rep prüfe ich S·md"
has "ready: stale by PR head" "⟳ stp veraltet: api#30 hat neue Commits"
has "merged today from the search" "Heute gemergt 77"
has "v1 fallback line" "herde-v1: v1-Herde — herd-recover migriert"
has "v1 row the old way" "● old alter Worker"
if grep -q $'\033' <<<"$OUT"; then bad "NO_COLOR: no escape codes"; else ok "NO_COLOR: no escape codes"; fi
if grep -v '^herdr agent list$' "$T/calls.log" | grep -q '^herdr'; then
  bad "only 'herdr agent list' is called"; grep '^herdr' "$T/calls.log"; else ok "only 'herdr agent list' is called"; fi

OUT="$(FAKE_LIMITS_FULL=1 board --once "$H")"
has "no slot: queue says why" "◌ q1 startet als 2. · kein Platz frei"
has "no slot: header shows full" "Plätze 6/6 (2 Review)"

OUT="$(HERD_BOARD_LANG=en board --once "$H")"
has "en strings" "Needs you"; has "en merge word" "say “merge okp”"

OUT="$(PATH="$T/notools:$BASEPATH" "$T/board/herd-board" --once "$H")"
hasnt "herd-clash absent: no clash mark" "⇄"
hasnt "herd-limits absent: no slots" "Plätze"
has "herd-clash absent: board still renders" "● run baut die Lanes"

# the real sibling tools, when they exist next to the board in the repo: the board must still render
if [ -x "$REPO_ROOT/scripts/herd-clash" ] && [ -x "$REPO_ROOT/scripts/herd-limits" ]; then
  mkdir -p "$T/real"
  cp "$REPO_ROOT/scripts/herd-clash" "$REPO_ROOT/scripts/herd-limits" "$T/board/"
  OUT="$(PATH="$T/notools:$BASEPATH" "$T/board/herd-board" --once "$H")"
  has "real herd-limits/herd-clash next to the board: renders" "● run baut die Lanes"
  has "real herd-limits: header slots" "Plätze 0/6 (0 Review)"
  OUT="$(FAKE_HERDR_DOWN=1 PATH="$T/notools:$BASEPATH" "$T/board/herd-board" --once "$H")"
  hasnt "real herd-limits unmeasurable (exit 2): no slots" "Plätze"
  rm -f "$T/board/herd-clash" "$T/board/herd-limits"
else
  echo "skip: real herd-clash/herd-limits not in scripts/ yet"
fi

echo "test-herd-board: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
