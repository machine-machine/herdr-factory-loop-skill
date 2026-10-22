#!/usr/bin/env bash
# herd-spawn <herd-dir> <slice> <worktree> [model]
#
# Starts one herd worker ALWAYS in the tab "herde" of the caller's workspace, never as a split in the
# orchestrator tab (that tab holds only the orchestrator and its herd-board). Creates the tab when it is
# missing; further workers split down under the last worker. Full agent TUIs squeezed into small splits
# show nothing but their status bar — the board is the view, the herde tab is where you drop in to talk.
#
# Writes <slice>=<pane> into <herd-dir>/herd.map and <slice> into active.txt, and registers the herd dir
# with the caller's herd-board. The worker prompt points at COMMON.md and <slice>.task.md in the herd
# dir — both must exist first (see templates/herd/COMMON.md for the status contract the board reads).
#
# Environment:
#   HERD_SPAWN_TAB          tab label (default: herde)
#   HERD_SPAWN_UNSET_KEYS=1 unset ANTHROPIC_API_KEY/ANTHROPIC_AUTH_TOKEN in the worker shell — a stale key in
#                           the environment shadows a working claude.ai login and every worker dies with 401
#   HERD_SPAWN_ENV          extra shell words run before claude, e.g. "export GIT_AUTHOR_NAME='…' …"
set -euo pipefail
herd=${1:?herd-dir}; slice=${2:?slice}; wt=${3:?worktree}; model=${4:-claude-opus-5-5}
self=${HERDR_PANE_ID:?run from inside a herdr pane}
ws=${self%%:*}
label=${HERD_SPAWN_TAB:-herde}
[ -f "$herd/COMMON.md" ] && [ -f "$herd/$slice.task.md" ] || { echo "COMMON.md or $slice.task.md missing in $herd" >&2; exit 1; }
[ -d "$wt" ] || { echo "worktree $wt missing" >&2; exit 1; }
herd=$(cd "$herd" && pwd); wt=$(cd "$wt" && pwd)   # panes and the board need absolute paths

tabs=$(herdr tab list)
tab=$(jq -r --arg ws "$ws" --arg l "$label" '.result.tabs[] | select(.workspace_id==$ws and .label==$l) | .tab_id' <<<"$tabs" | head -1)

if [ -z "$tab" ]; then
  # first worker: open a pane next to me, then move it straight into a new tab
  pane=$(herdr pane split --pane "$self" --direction right --cwd "$wt" --no-focus | jq -r '.result.pane.pane_id')
  tab=$(herdr pane move "$pane" --new-tab | jq -r '.result.move_result.created_tab.tab_id')
  herdr tab rename "$tab" "$label" >/dev/null
else
  # under the most recent worker in that tab
  last=$(herdr pane list | jq -r --arg t "$tab" '[.result.panes[] | select(.tab_id==$t)] | last | .pane_id')
  pane=$(herdr pane split --pane "$last" --direction down --cwd "$wt" --no-focus | jq -r '.result.pane.pane_id')
fi
# a pane move steals focus — hand it back to the orchestrator
herdr agent focus "$self" >/dev/null 2>&1 || herdr tab focus "${self%:*}:t1" >/dev/null 2>&1 || true

sed -i "/^$slice=/d" "$herd/herd.map" 2>/dev/null || true
echo "$slice=$pane" >> "$herd/herd.map"
grep -qx "$slice" "$herd/active.txt" 2>/dev/null || echo "$slice" >> "$herd/active.txt"
reg=~/.cache/herd-board/${self//:/_}.herds
mkdir -p "${reg%/*}"; grep -qx "$herd" "$reg" 2>/dev/null || echo "$herd" >> "$reg"
herd-board --open --anchor "$self" >/dev/null 2>&1 || true

name=$(basename "$herd")
pre=""
[ "${HERD_SPAWN_UNSET_KEYS:-0}" = 1 ] && pre="unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN; "
[ -n "${HERD_SPAWN_ENV:-}" ] && pre="$pre$HERD_SPAWN_ENV; "
# --permission-mode auto, not --dangerously-skip-permissions: an orchestrator in auto mode gets the latter
# blocked as unsafe agent creation. The prompt is argv, so no separate `agent prompt` can race the TUI.
herdr pane run "$pane" "${pre}claude --model $model --permission-mode auto 'You are worker $slice of herd $name. Read $herd/COMMON.md first, then your task $herd/$slice.task.md, and work through it.'" >/dev/null
echo "$slice started in $pane (tab $tab \"$label\")"
