#!/usr/bin/env bash
# m2herd-steer-gate.sh — Claude Code UserPromptSubmit / Stop hook (m2herd STEER inbox)
#
# The deterministic trigger of "intelligent determinism" (docs/herd-flow-v2.md, section STEER):
# when the fabric's inbox/STEER.md holds findings nobody has triaged yet, inject ONE line of
# additionalContext naming the count, the top 3 keys and the exact `m2herd-steer` commands. The
# judgment (act, ticket, register, delegate, drop) stays with the orchestrator, steered by
# templates/herd/rules/STEER.md; `m2herd-steer verify` is the deterministic proof afterwards.
#
#   silent   when nothing is open, inside herd worker panes (M2HERD_WORKER=1, HERD_SLICE set by
#            herd-spawn, or the pane listed in a registered herd.map), in subagents, on a Stop that
#            this hook chain already held once (stop_hook_active), or with M2HERD_STEER_GATE=0
#   rate     the same set of open keys at most once per 30 min per session (M2HERD_STEER_RATE)
#   never    blocks: no `decision`, always exit 0, any failure is silence
#
# Wire as  UserPromptSubmit: bash <skill>/hooks/m2herd-steer-gate.sh
#          Stop:             bash <skill>/hooks/m2herd-steer-gate.sh Stop
# The body lives in `m2herd-steer gate` (python3 stdlib); this wrapper only finds it.

set -u

# Timed stdin read (same contract as the other hooks): a host that never closes stdin costs at
# most 5s, a $(cat) would block forever.
payload=""
_line=""
while IFS= read -r -t 5 _line 2>/dev/null; do payload="${payload}${_line}"$'\n'; done || true
if [ -n "${_line:-}" ]; then payload="${payload}${_line}"; fi

# Cheap exits before python starts.
[ "${M2HERD_WORKER:-}" = "1" ] && exit 0
[ -n "${HERD_SLICE:-}" ] && exit 0
[ "${M2HERD_STEER_GATE:-}" = "0" ] && exit 0
command -v python3 >/dev/null 2>&1 || exit 0

# Find the engine: explicit override, the repo copy next to this (possibly symlinked) hook, PATH.
_self="$0"
if command -v readlink >/dev/null 2>&1 && _r="$(readlink -f "$0" 2>/dev/null)" && [ -n "$_r" ]; then _self="$_r"; fi
_here="$(cd "$(dirname "$_self")" 2>/dev/null && pwd)"
bin=""
for c in "${M2HERD_STEER_BIN:-}" "${_here:-.}/../scripts/m2herd-steer" "$(command -v m2herd-steer 2>/dev/null || true)"; do
  if [ -n "$c" ] && [ -f "$c" ]; then bin="$c"; break; fi
done
[ -n "$bin" ] || exit 0

out=""
if command -v timeout >/dev/null 2>&1; then
  out="$(printf '%s' "$payload" | PYTHONDONTWRITEBYTECODE=1 timeout 8 python3 "$bin" gate --event "${1:-}" 2>/dev/null)" || true
else
  out="$(printf '%s' "$payload" | PYTHONDONTWRITEBYTECODE=1 python3 "$bin" gate --event "${1:-}" 2>/dev/null)" || true
fi
# Only a single JSON object goes out; anything else is noise.
case "$out" in
  '{'*'}') printf '%s\n' "$out" ;;
esac
exit 0
