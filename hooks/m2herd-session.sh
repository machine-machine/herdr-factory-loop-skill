#!/usr/bin/env bash
# m2herd-session.sh — Claude Code SessionStart hook (m2herd context fabric)
#
# When a session starts inside a repo that carries an .m2herd/ context fabric
# (cwd or $M2HERD_DIR holds .m2herd/), inject a digest as additionalContext:
# the overview.json goal/status/areas count plus the first 30 lines of
# RESUME.md, and (when the m2herd engine is on PATH) the one-line `m2herd next`
# move — so a resumed orchestrator starts already oriented on where the work
# stands and what to do next.
#
# Pure bash + jq. Same JSON envelope as herdr-context-session.sh. Silent-fail:
# any problem exits 0 with no output so the hook never blocks a session start.

set -u

# Read the (unused but contract-consistent) stdin JSON without hanging: a timed
# read loop, so a host that never closes stdin costs at most 5s per silent read —
# a $(cat) form would block forever because cat runs before any timeout applies.
_stdin=""
while IFS= read -r -t 5 _line 2>/dev/null; do _stdin="${_stdin}${_line}"; done || true

# jq is required for safe JSON encoding; without it, stay silent.
command -v jq >/dev/null 2>&1 || exit 0

# Resolve the repo root: prefer $M2HERD_DIR, else cwd — whichever holds .m2herd/.
ROOT=""
if [ -n "${M2HERD_DIR:-}" ] && [ -d "${M2HERD_DIR}/.m2herd" ]; then
  ROOT="${M2HERD_DIR}"
elif [ -d "./.m2herd" ]; then
  ROOT="$(pwd)"
fi

# No context fabric → nothing to say.
[ -n "$ROOT" ] || exit 0

M2="${ROOT}/.m2herd"

GOAL=""
STATUS=""
AREAS="0"
if [ -f "$M2/overview.json" ]; then
  GOAL="$(jq -r '.goal // empty' "$M2/overview.json" 2>/dev/null || true)"
  STATUS="$(jq -r '.status // empty' "$M2/overview.json" 2>/dev/null || true)"
  AREAS="$(jq -r '(.areas // []) | length' "$M2/overview.json" 2>/dev/null || true)"
  [ -n "$AREAS" ] || AREAS="0"
fi

RESUME=""
if [ -f "$M2/RESUME.md" ]; then
  RESUME="$(head -30 "$M2/RESUME.md" 2>/dev/null || true)"
fi

# Next-move probe (contract amendment v1.2, supersedes the v1.1 drift nudge —
# drift is case 1 of `next`): if the m2herd engine is on PATH, run a bounded
# `m2herd next` and append its one-line "NEXT: ..." to the digest so every
# wake-up carries orientation + the next move. Degrade silently when the
# binary is absent, hangs (killed at ~3s), or produces nothing — the probe
# must never delay or block the session.
NEXT=""
if command -v m2herd >/dev/null 2>&1; then
  if command -v timeout >/dev/null 2>&1; then
    NEXT="$(timeout 3 m2herd next --dir "$ROOT" 2>/dev/null | head -3 || true)"
  else
    _out="$(mktemp 2>/dev/null || true)"
    if [ -n "$_out" ]; then
      m2herd next --dir "$ROOT" >"$_out" 2>/dev/null & _pid=$!
      ( sleep 3; kill "$_pid" 2>/dev/null ) & _watch=$!
      wait "$_pid" 2>/dev/null || true
      kill "$_watch" 2>/dev/null; wait "$_watch" 2>/dev/null || true
      NEXT="$(head -3 "$_out" 2>/dev/null || true)"
      rm -f "$_out" 2>/dev/null || true
    fi
  fi
fi

# Build the digest.
MSG="m2herd context fabric detected at ${M2}."
MSG="${MSG} goal: ${GOAL:-(unset)} | status: ${STATUS:-(unset)} | areas: ${AREAS}."
if [ -n "$RESUME" ]; then
  MSG="${MSG}
--- RESUME.md (first 30 lines) ---
${RESUME}"
else
  MSG="${MSG} No RESUME.md yet — run 'm2herd.sh status' to orient."
fi
if [ -n "$NEXT" ]; then
  MSG="${MSG}
${NEXT}"
fi

# The orchestrator mandate — this is what makes a Claude Code session "kick off"
# the fabric on its own: housekeeping is pre-authorized, delegation is not.
MSG="${MSG}
You are the m2herd MAIN ORCHESTRATOR for this repo. On your first turn, perform the
NEXT housekeeping above without being asked (bring up the machineroom via
'm2herd-up up --room-only', run 'm2herd sync', refile notes) alongside the user's
request. Spawning WORKERS, worktrees, or branches still requires explicit user
confirmation — housekeeping is pre-authorized, delegation is not."

# Emit the structured envelope. Typed fields let tests assert the contract
# without grepping the prose.
jq -cn \
  --arg ctx "$MSG" \
  --arg goal "$GOAL" \
  --arg status "$STATUS" \
  --arg areas "$AREAS" \
  '{
    hookSpecificOutput: {
      hookEventName: "SessionStart",
      additionalContext: $ctx,
      goal: $goal,
      status: $status,
      areas_count: ($areas | tonumber? // 0)
    }
  }'

exit 0
