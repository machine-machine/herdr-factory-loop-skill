#!/usr/bin/env bash
# m2herd-prompt-intent.sh — Claude Code UserPromptSubmit hook (prompt optimiser)
#
# While a prompt is being authored in .m2herd/prompt/prompt.md, every turn is one of
# two very different things and the agent must not mix them up:
#   a FOLLOWUP carries state -> it is filed verbatim as CONTEXT, never reworded,
#     never turned into a task;
#   an INTENT is an instruction -> it is filed as an INTENT and decomposed under the
#     four questions with an external verifier.
# This hook classifies the turn mechanically and says which branch to take, so the
# decision is not left to the model's mood.
#
# Silent unless a prompt is actively being authored (prompt.md exists and still fails
# audit). Pure bash + jq, 5s stdin guard, silent-fail, never blocks a turn.

set -u

_stdin=""; _line=""
while IFS= read -r -t 5 _line 2>/dev/null; do _stdin="${_stdin}${_line}"; done || true
if [ -n "${_line:-}" ]; then _stdin="${_stdin}${_line}"; fi
[ -n "$_stdin" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

# only inside a fabric repo carrying a prompt under construction
DIR=""
if [ -n "${M2HERD_DIR:-}" ] && [ -f "${M2HERD_DIR}/.m2herd/prompt/prompt.md" ]; then
  DIR="$M2HERD_DIR"
elif [ -f "./.m2herd/prompt/prompt.md" ]; then
  DIR="$(pwd)"
fi
[ -n "$DIR" ] || exit 0

PROMPT="$(printf '%s' "$_stdin" | jq -r '.prompt // empty' 2>/dev/null)" || exit 0
[ -n "$PROMPT" ] || exit 0
case "$PROMPT" in /|!*) exit 0 ;; esac
# chatter: fewer than four words is not worth a classification
[ "$(printf '%s' "$PROMPT" | wc -w)" -ge 4 ] || exit 0

ENGINE="$DIR/scripts/m2herd.sh"
[ -x "$ENGINE" ] || ENGINE="$(command -v m2herd 2>/dev/null || true)"
[ -n "$ENGINE" ] || exit 0

# the classifier lives in the engine: one implementation, not two.
# Candidates in order — a stale engine on PATH must not mute a newer local one.
LOGIC=""
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
for cand in "$SELF_DIR/../scripts/m2herd.sh" "$DIR/scripts/m2herd.sh" "$(command -v m2herd 2>/dev/null || true)"; do
  [ -n "$cand" ] && [ -x "$cand" ] || continue
  LOGIC="$(cd "$DIR" && bash "$cand" prompt classify "$PROMPT" 2>/dev/null)"
  [ -n "$LOGIC" ] && break
done
[ -n "$LOGIC" ] || exit 0
KIND="${LOGIC%%$'\t'*}"
BASIS="${LOGIC#*$'\t'}"
case "$KIND" in context|intent|constraint|correction) : ;; *) exit 0 ;; esac

case "$KIND" in
  context)    MSG="This turn is FOLLOWUP INFORMATION ($BASIS). File it verbatim, do not reword it, do not turn it into a task: m2herd prompt add \"<text>\" (it routes to ## Context). If it contradicts an existing intent use --as correction instead." ;;
  constraint) MSG="This turn is a BOUNDARY ($BASIS). File it as a constraint, not as work: m2herd prompt add --as constraint \"<text>\"." ;;
  correction) MSG="This turn CORRECTS an earlier intent ($BASIS). File it with --as correction so the superseded intent is struck through: m2herd prompt add --as correction \"<text>\"." ;;
  intent)     MSG="This turn carries an INTENT ($BASIS). File it with m2herd prompt add \"<text>\", then decompose it under the four interview questions and give it a runnable verifier — the agent never grades itself." ;;
esac

jq -cn --arg m "«prompt-forge» $MSG" \
  '{hookSpecificOutput:{hookEventName:"UserPromptSubmit",additionalContext:$m}}' 2>/dev/null || exit 0