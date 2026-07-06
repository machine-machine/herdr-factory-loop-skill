#!/usr/bin/env bash
# herdr-context-session.sh — Hermes SessionStart hook (context-budget layer)
#
# When a session starts inside a herd-control workspace (cwd or $HERD_WS holds
# a herd.conf), emit a one-line orientation as additionalContext: the resolved
# MODEL/BUDGET and, if a spilled _fleet/context_pointer.md exists, its path — so
# a resumed orchestrator starts already aware of its budget and where its
# offloaded working context lives.
#
# Pure bash + jq. Same JSON envelope as gsd-session-state.sh. Silent-fail: any
# problem exits 0 with no output so the hook never blocks a session start.

set -u

# Read the (unused but contract-consistent) stdin JSON without hanging: a timed
# read loop, so a host that never closes stdin costs at most 5s per silent read —
# the previous $(cat) form blocked forever because cat ran before the timeout applied.
_stdin=""
_line=""
while IFS= read -r -t 5 _line 2>/dev/null; do _stdin="${_stdin}${_line}"; done || true
# On EOF after a final unterminated line, read returns non-zero but leaves the
# partial in $_line — append it so a newline-less payload isn't dropped.
if [ -n "${_line:-}" ]; then _stdin="${_stdin}${_line}"; fi

# jq is required for safe JSON encoding; without it, stay silent.
command -v jq >/dev/null 2>&1 || exit 0

# Resolve the workspace dir: prefer $HERD_WS, else cwd — whichever holds a herd.conf.
WS=""
if [ -n "${HERD_WS:-}" ] && [ -f "${HERD_WS}/herd.conf" ]; then
  WS="${HERD_WS}"
elif [ -f "./herd.conf" ]; then
  WS="$(pwd)"
fi

# Not a herd workspace → nothing to say.
[ -n "$WS" ] || exit 0

# Values may be shell-quoted in herd.conf (BUDGET="384000"); strip one layer
# of surrounding quotes so downstream consumers see the bare value, matching
# how the JS hooks' Number() coercion treats the same file.
conf_get() {
  _v="$(grep -E "^$1=" "$WS/herd.conf" 2>/dev/null | head -1 | cut -d= -f2- || true)"
  case "$_v" in
    \"*\") _v="${_v#\"}"; _v="${_v%\"}" ;;
    \'*\') _v="${_v#\'}"; _v="${_v%\'}" ;;
  esac
  printf '%s' "$_v"
}

MODEL="$(conf_get MODEL)"
BUDGET="$(conf_get BUDGET)"
[ -n "$MODEL" ]  || MODEL="GLM-5.2"
# BUDGET must be a positive integer before we advertise it as a token budget
# (the JS hooks reject non-numeric values via Number(); mirror that here).
BUDGET="$(printf '%s' "$BUDGET" | tr -d '[:space:]')"
case "$BUDGET" in ''|*[!0-9]*) BUDGET="384000" ;; esac
[ "$BUDGET" -gt 0 ] 2>/dev/null || BUDGET="384000"

POINTER=""
if [ -f "$WS/_fleet/context_pointer.md" ]; then
  POINTER="$WS/_fleet/context_pointer.md"
fi

# Build the one-line advisory.
MSG="herd-control budget: MODEL=${MODEL} BUDGET=${BUDGET}."
if [ -n "$POINTER" ]; then
  MSG="${MSG} A context pointer is available at ${POINTER} — reload working context from it to start within budget."
else
  MSG="${MSG} No context pointer spilled yet; lean on slice context.md links rather than raw history to stay within budget."
fi

# Emit the structured envelope. Typed fields let tests assert the contract
# without grepping the prose.
jq -cn \
  --arg ctx "$MSG" \
  --arg model "$MODEL" \
  --arg budget "$BUDGET" \
  --arg pointer "$POINTER" \
  '{
    hookSpecificOutput: {
      hookEventName: "SessionStart",
      additionalContext: $ctx,
      model: $model,
      budget: $budget,
      pointer_present: ($pointer | length > 0),
      pointer_path: $pointer
    }
  }'

exit 0
