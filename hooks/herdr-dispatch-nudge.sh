#!/usr/bin/env bash
# herdr-dispatch-nudge.sh — fires every turn (Claude Code UserPromptSubmit /
# Hermes pre_llm_call) and injects a short reminder to consider fanning work
# out to herdr workers when it's applicable — WITHOUT deciding or spawning
# anything itself. That judgment call (is this decomposable? is it risky
# enough to need a plan-then-ack?) stays with the model; this hook only makes
# sure the model re-checks it on every turn instead of only when the user
# says "herdr".
#
# Installed + registered by scripts/install.sh into:
#   ~/.claude/settings.json  .hooks.UserPromptSubmit   (Claude Code)
#   ~/.hermes/config.yaml    hooks.pre_llm_call         (Hermes)
#
# Never blocks, never spawns anything — always exits 0 with a context
# injection payload shaped for whichever platform invoked it.

# No `set -e`: this hook runs on EVERY prompt and its header contract is
# "always exits 0" — every failure mode below is handled explicitly instead.
set -uo pipefail

# Read stdin without hanging: a timed read loop, so a host that never closes
# stdin costs at most 5s per silent read — a $(cat) form would block forever
# because cat runs before any timeout applies.
payload=""
_line=""
while IFS= read -r -t 5 _line 2>/dev/null; do payload="${payload}${_line}"$'\n'; done
# On EOF after a final unterminated line, read returns non-zero but leaves the
# partial in $_line — append it so a newline-less payload isn't dropped.
if [ -n "${_line:-}" ]; then payload="${payload}${_line}"; fi

NUDGE='herdr: before starting multi-part or channel-relayed work, check whether it decomposes into >=2 independent slices (different files/services/features) — see the herdr skill Sections 9 (herd), 11 (SDD), 13 (meta-orchestration). If it does, propose a short plan (slices, base branch, worker count/type) and get explicit user/channel confirmation BEFORE spawning any herdr agent, worktree, or branch. Never auto-spawn workers without that confirmation. Trivial or single-file asks: just do the work inline, no herd.'

# Without jq we can't parse the event or build JSON safely — emit a static,
# hand-escaped envelope instead (NUDGE's only JSON-special characters are the
# two double quotes, escaped below) so the nudge still lands. Event sniffed
# crudely from the raw payload; default is the Claude Code shape.
if ! command -v jq >/dev/null 2>&1; then
  _esc=${NUDGE//\"/\\\"}
  case "$payload" in
    *pre_llm_call*)
      printf '{"context":"%s"}\n' "$_esc"
      ;;
    *)
      printf '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"%s"}}\n' "$_esc"
      ;;
  esac
  exit 0
fi

event=$(printf '%s' "$payload" | jq -r '.hook_event_name // empty' 2>/dev/null || true)

case "$event" in
  pre_llm_call)
    # Hermes shell-hook wire format for pre_llm_call context injection.
    jq -n --arg c "$NUDGE" '{context: $c}'
    ;;
  *)
    # Claude Code UserPromptSubmit (also the default if hook_event_name is
    # missing/unrecognized — this script is only ever wired to these two
    # events, so this is a safe fallback, not a guess).
    jq -n --arg c "$NUDGE" '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $c}}'
    ;;
esac

exit 0
