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

set -euo pipefail

payload="$(cat -)"
event=$(printf '%s' "$payload" | jq -r '.hook_event_name // empty' 2>/dev/null || true)

NUDGE='herdr: before starting multi-part or channel-relayed work, check whether it decomposes into >=2 independent slices (different files/services/features) — see the herdr skill Sections 9 (herd), 11 (SDD), 13 (meta-orchestration). If it does, propose a short plan (slices, base branch, worker count/type) and get explicit user/channel confirmation BEFORE spawning any herdr agent, worktree, or branch. Never auto-spawn workers without that confirmation. Trivial or single-file asks: just do the work inline, no herd.'

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
