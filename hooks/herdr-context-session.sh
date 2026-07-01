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

# Read the (unused but contract-consistent) stdin JSON without hanging.
read -r -t 5 _stdin <<<"$(cat 2>/dev/null || true)" 2>/dev/null || true

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

conf_get() { grep -E "^$1=" "$WS/herd.conf" 2>/dev/null | head -1 | cut -d= -f2- || true; }

MODEL="$(conf_get MODEL)"
BUDGET="$(conf_get BUDGET)"
[ -n "$MODEL" ]  || MODEL="GLM-5.2"
[ -n "$BUDGET" ] || BUDGET="384000"

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
