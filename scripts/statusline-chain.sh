#!/usr/bin/env bash
# statusline-chain.sh — one statusLine slot, two consumers.
#
# Claude Code allows exactly one statusLine. The fabric's ctx-bridge.sh is what writes
# /tmp/claude-ctx-<sid>.json for the budget hooks; LifeOS owns the visible frame. Feed the
# same payload to both: ctx-bridge's output is discarded (it only exists to write the file,
# and its line would garble the frame), LifeOS's output is the answer.
#
# Re-apply after any LifeOS component deploy that resets settings.statusLine.
payload="$(cat)"
bridge="$HOME/.claude/hooks/ctx-bridge.sh"
lifeos="$HOME/.claude/LIFEOS/LIFEOS_StatusLine.sh"

[ -x "$bridge" ] && printf '%s' "$payload" | "$bridge" >/dev/null 2>&1
if [ -x "$lifeos" ]; then
  printf '%s' "$payload" | bash "$lifeos"
else
  printf '%s' "$payload" | bash "$bridge" 2>/dev/null || echo "claude"
fi