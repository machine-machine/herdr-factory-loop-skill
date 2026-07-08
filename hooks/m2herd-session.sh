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
_line=""
while IFS= read -r -t 5 _line 2>/dev/null; do _stdin="${_stdin}${_line}"; done || true
# On EOF after a final unterminated line, read returns non-zero but leaves the
# partial in $_line — append it so a newline-less payload isn't dropped.
if [ -n "${_line:-}" ]; then _stdin="${_stdin}${_line}"; fi

# jq is required for safe JSON encoding; without it, stay silent.
command -v jq >/dev/null 2>&1 || exit 0

# Session id from the stdin payload — used to find this session's own bridge
# file. Sanitised like the js hooks: no path separators / traversal (it is
# interpolated into a /tmp path).
SID="$(printf '%s' "$_stdin" | jq -r '.session_id // empty' 2>/dev/null || true)"
case "$SID" in */*|*\\*|*..*) SID="" ;; esac

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

# --- context-budget awareness (reads the ctx-bridge statusline bridge file) --
# Prefer THIS session's bridge file (from $SID) in /tmp then $TMPDIR; else the
# newest fresh one. Both must be ≤30 min old — an older bridge describes a
# window that no longer exists. Warn/debounce sidecars (…-m2herd-budget.json /
# …-herdr-budget.json) share the glob and are skipped by name; anything whose
# pct/used_pct doesn't parse numeric is skipped too. Never fails the hook.
_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }
CTX_PCT=""
_now="$(date -u +%s 2>/dev/null || echo 0)"
_bridge=""
if [ -n "$SID" ]; then
  for _d in /tmp "${TMPDIR:-}"; do
    [ -n "$_d" ] || continue
    _c="$_d/claude-ctx-$SID.json"
    [ -f "$_c" ] || continue
    _mt="$(_mtime "$_c")"
    case "$_mt" in ''|*[!0-9]*) _mt=0 ;; esac
    if [ $((_now - _mt)) -le 1800 ]; then _bridge="$_c"; break; fi
  done
fi
if [ -z "$_bridge" ]; then
  _best=0
  for _d in /tmp "${TMPDIR:-}"; do
    [ -n "$_d" ] && [ -d "$_d" ] || continue
    for _c in "$_d"/claude-ctx-*.json; do
      [ -f "$_c" ] || continue
      [ -O "$_c" ] || continue
      case "$_c" in *-m2herd-budget.json|*-herdr-budget.json) continue ;; esac
      _mt="$(_mtime "$_c")"
      case "$_mt" in ''|*[!0-9]*) _mt=0 ;; esac
      [ $((_now - _mt)) -le 1800 ] || continue
      if [ "$_mt" -gt "$_best" ]; then _best="$_mt"; _bridge="$_c"; fi
    done
  done
fi
if [ -n "$_bridge" ]; then
  CTX_PCT="$(jq -r '(.pct // .used_pct) // empty' "$_bridge" 2>/dev/null || true)"
  CTX_PCT="${CTX_PCT%.*}"
  case "$CTX_PCT" in ''|*[!0-9]*) CTX_PCT="" ;; esac
fi

# Budget-aware digest sizing: at ≥60% context, halve the RESUME excerpt.
RESUME_LINES=30
if [ -n "$CTX_PCT" ] && [ "$CTX_PCT" -ge 60 ]; then RESUME_LINES=15; fi

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
  RESUME="$(head -"$RESUME_LINES" "$M2/RESUME.md" 2>/dev/null || true)"
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
      # No `timeout` binary: poll the job table instead of forking a detached
      # sleep-then-kill watcher — no orphaned sleep child, and because we only
      # kill while `jobs -r` still lists the (unreaped) child, the kill can
      # never hit a recycled PID.
      m2herd next --dir "$ROOT" >"$_out" 2>/dev/null & _pid=$!
      _i=0
      while [ "$_i" -lt 3 ] && jobs -r 2>/dev/null | grep -q .; do
        sleep 1
        _i=$((_i+1))
      done
      if jobs -r 2>/dev/null | grep -q .; then kill "$_pid" 2>/dev/null || true; fi
      wait "$_pid" 2>/dev/null || true
      NEXT="$(head -3 "$_out" 2>/dev/null || true)"
      rm -f "$_out" 2>/dev/null || true
    fi
  fi
  # Only trust well-shaped output: the first line must be "NEXT: ..." —
  # anything else (errors, usage text, partial output) is noise, not orientation.
  case "$NEXT" in "NEXT: "*) ;; *) NEXT="";; esac
fi

# Build the digest.
MSG="m2herd context fabric detected at ${M2}."
MSG="${MSG} goal: ${GOAL:-(unset)} | status: ${STATUS:-(unset)} | areas: ${AREAS}."
if [ -n "$RESUME" ]; then
  MSG="${MSG}
--- RESUME.md (first ${RESUME_LINES} lines) ---
${RESUME}"
else
  MSG="${MSG} No RESUME.md yet — run 'm2herd.sh status' to orient."
fi
if [ -n "$NEXT" ]; then
  MSG="${MSG}
${NEXT}"
fi
# Budget-aware nudge: above 60% the digest itself must stay lean and the
# orchestrator should lean on the fabric, not the transcript.
if [ -n "$CTX_PCT" ] && [ "$CTX_PCT" -ge 60 ]; then
  MSG="${MSG}
context at ${CTX_PCT}% — prefer pointers over content; offload with m2herd refile/archive"
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
