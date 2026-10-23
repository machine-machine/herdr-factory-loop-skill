#!/usr/bin/env bash
# herd-spawn <herd> <slice> [--resume] [--no-limits]   (docs/herd-flow-v2.md §4)
#
# Starts one herd worker ALWAYS in the tab "herde" of the anchor's workspace, never as a split in the
# orchestrator tab (that tab holds only the orchestrator and its herd-board). The tab is found by its label and
# created when missing; further workers split the TALLEST pane of the tab (down, or right once it has < 24
# rows — splitting under the last worker shrank panes to 0 rows, and 0-row panes cannot resume after a herdr
# restart). Focus goes back to the anchor afterwards.
#
# Reads from the herd dir:
#   <slice>.task.md   header `model:` (default claude-opus-5-5) and `effort:` (default high)
#   <slice>.repos     `repo branch base` per line; worktree = $HERD_WT_ROOT/<repo>/<slice>, the first one is the
#                     pane's cwd. A missing worktree is created by $HERD_SETUP or an executable <herd>/setup-wt.sh
#                     (called as `<cmd> <repo> <slice> <branch> <base>`), otherwise the start is refused.
#   <slice>.ctx.worker.md (from herd-context) or COMMON.md — the rules the prompt points at, when present.
# Refuses when herd-limits reports no free slot (prints why), or when the slice's last phase does not allow
# `working`. A new start runs `claude --session-id <uuid4> --model <m> --effort <e>`; --resume continues the
# session recorded in the last `working` event with `claude --resume <id>`, and when the last phase is
# `fix_queued` the prompt points at its befunde_file. A resumed worker whose pane is still alive and idle gets
# the prompt via `herdr agent prompt` in its own pane (never a second TUI on the same session).
# On success writes the `working` event via herd-phase (pane, session_id, model, effort, wt) and registers the
# herd dir with the anchor's herd-board (~/.cache/herd-board/<anchor>.herds).
#
# Exit: 0 started, 1 usage/input error, 3 no slot, 4 herdr failed, 5 started but the event write failed.
#
# Environment:
#   HERD_ANCHOR             orchestrator pane (default: HERD_ORCH_PANE, then HERDR_PANE_ID)
#   HERD_SPAWN_TAB          tab label (default: herde)
#   HERD_SPAWN_BY           `by` of the working event (default orchestrator; herd-watch sets watch)
#   HERD_WT_ROOT            worktree root (default ~/.herdr/worktrees)
#   HERD_SETUP              worktree setup command (see above)
#   HERD_GIT_NAME/HERD_GIT_EMAIL  exported as GIT_AUTHOR_* and GIT_COMMITTER_* in the worker shell
#   HERD_SPAWN_UNSET_KEYS=0 keep ANTHROPIC_API_KEY/ANTHROPIC_AUTH_TOKEN (default: unset — a stale key shadows a
#                           working claude.ai login and every worker dies with 401)
#   HERD_SPAWN_ENV          extra shell words run before claude
#   HERD_RESUME             note for a plain --resume (default: a restart note)
#   HERD_SPAWN_CONTEXT=0    do not regenerate <slice>.ctx.worker.md with herd-context before the start
set -euo pipefail

here=$(dirname "$(realpath "$0")")
usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; }
die() { echo "herd-spawn: $*" >&2; exit "${2:-1}"; }

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --selftest) exec python3 "$here/../tests/spawnwatch/test_spawnwatch.py" -k Spawn ;;
esac

herd=${1:-}; slice=${2:-}
[ -n "$herd" ] && [ -n "$slice" ] || { usage >&2; exit 1; }
shift 2
resume=0; check_limits=1
for a in "$@"; do
  case $a in
    --resume) resume=1 ;;
    --no-limits) check_limits=0 ;;
    *) die "unknown argument $a" ;;
  esac
done
[ -d "$herd" ] || die "herd dir $herd missing"
herd=$(cd "$herd" && pwd)   # panes and the board need absolute paths
anchor=${HERD_ANCHOR:-${HERD_ORCH_PANE:-${HERDR_PANE_ID:-}}}
[ -n "$anchor" ] || die "no anchor pane: run from inside a herdr pane or set HERD_ANCHOR"
ws=${anchor%%:*}
label=${HERD_SPAWN_TAB:-herde}
[ -f "$herd/$slice.task.md" ] || die "$slice.task.md missing in $herd"

# --- the slice as declared + its event history (via herd_events, never parsed twice) ---------------------------
meta=$(python3 - "$here" "$herd" "$slice" "$resume" <<'PY'
import json, os, sys
sys.path.insert(0, sys.argv[1])
import herd_events as he
herd, s, resume = sys.argv[2], sys.argv[3], sys.argv[4] == "1"
hdr = he.task_header(herd, s)
out = {"model": hdr.get("model") or "claude-opus-5-5", "effort": hdr.get("effort") or "high"}
try:
    out["repos"] = he.repos(herd, s)
except ValueError as e:
    out["error"] = str(e)
st = he.state(herd)
cur = st.get(s)
out["phase"] = cur["phase"] if cur else ""
out["allowed"] = "working" in he.TRANSITIONS.get(cur["phase"] if cur else None, set())
out["befunde_file"] = cur.get("befunde_file", "") if cur else ""
# the newest working event carries the session to continue and the pane it last ran in
last_work = None
for ev in he.read(herd):
    if ev["slice"] == s and ev["phase"] == "working":
        last_work = ev
out["session_id"] = (last_work or {}).get("session_id", "")
out["last_pane"] = (last_work or {}).get("pane", "")
print(json.dumps(out))
PY
)
err=$(jq -r '.error // empty' <<<"$meta")
[ -z "$err" ] || die "$err"
model=$(jq -r .model <<<"$meta"); effort=$(jq -r .effort <<<"$meta")
phase=$(jq -r .phase <<<"$meta"); befunde=$(jq -r .befunde_file <<<"$meta")
sid_old=$(jq -r .session_id <<<"$meta"); last_pane=$(jq -r .last_pane <<<"$meta")
model_re='^[][A-Za-z0-9._:@-]+$'   # e.g. claude-opus-5-5, claude-opus-5-5[1m]
[[ $model =~ $model_re ]] || die "bad model '$model' in $slice.task.md"
case $effort in low|medium|high|xhigh|max) ;; *) die "bad effort '$effort' in $slice.task.md (low|medium|high|xhigh|max)" ;; esac
[ "$(jq -r .allowed <<<"$meta")" = true ] || die "$slice is ${phase:-?} — ${phase:-nothing} -> working is not allowed"
[ "$(jq '.repos | length' <<<"$meta")" -gt 0 ] || die "$slice.repos missing or empty (one line per repo: repo branch base)"
if [ "$resume" = 1 ] && [ -z "$sid_old" ]; then
  die "--resume: no session_id recorded for $slice — start it without --resume"
fi

# --- worktrees -------------------------------------------------------------------------------------------------
wt_root=${HERD_WT_ROOT:-$HOME/.herdr/worktrees}
setup=${HERD_SETUP:-}
[ -z "$setup" ] && [ -x "$herd/setup-wt.sh" ] && setup="$herd/setup-wt.sh"
wts=()
while IFS=$'\t' read -r repo branch base; do
  wt="$wt_root/$repo/$slice"
  if [ ! -d "$wt" ]; then
    [ -n "$setup" ] || die "worktree $wt missing (set HERD_SETUP or add $herd/setup-wt.sh)"
    # shellcheck disable=SC2086  # HERD_SETUP may carry its own arguments
    $setup "$repo" "$slice" "$branch" "$base" >&2 || die "setup $repo/$slice failed ($setup)"
    [ -d "$wt" ] || die "setup ran but $wt is still missing"
  fi
  wts+=("$(cd "$wt" && pwd)")
done < <(jq -r '.repos[] | [.repo, .branch, .base] | @tsv' <<<"$meta")
first=${wts[0]}
wt_json=$(printf '%s\n' "${wts[@]}" | jq -R . | jq -sc .)

# --- budget ----------------------------------------------------------------------------------------------------
if [ "$check_limits" = 1 ]; then
  lim_rc=0
  lim=$("$here/herd-limits" "$herd" --anchor "$anchor" 2>&1) || lim_rc=$?
  [ "$lim_rc" = 0 ] || die "no slot for $slice: $lim" 3
fi

# --- prompt + command ------------------------------------------------------------------------------------------
name=$(basename "$herd")
task="$herd/$slice.task.md"
rules=""
# a herd that uses herd-context (ctx.env or an earlier ctx file) gets it regenerated on every start, so a fix
# round started by herd-watch carries the befunde file and current heads; a failure only warns
if [ "${HERD_SPAWN_CONTEXT:-1}" != 0 ] && [ -x "$here/herd-context" ] && \
   { [ -f "$herd/ctx.env" ] || [ -f "$herd/$slice.ctx.worker.md" ]; }; then
  "$here/herd-context" worker "$herd" "$slice" >/dev/null 2>&1 || echo "herd-spawn: herd-context worker $slice failed — using the old context file" >&2
fi
if [ -f "$herd/$slice.ctx.worker.md" ]; then rules="$herd/$slice.ctx.worker.md"
elif [ -f "$herd/COMMON.md" ]; then rules="$herd/COMMON.md"; fi
if [ "$resume" = 1 ]; then
  sid=$sid_old
  if [ "$phase" = fix_queued ]; then
    [ -n "$befunde" ] || die "$slice is fix_queued but the event has no befunde_file"
    case $befunde in /*) ;; *) befunde="$herd/$befunde" ;; esac
    prompt="Orchestrator: the review found problems in your slice $slice. Read $befunde, fix every medium and high finding in your worktrees ($(IFS=' '; echo "${wts[*]}")), re-run the touched tests, push, update $herd/$slice.status.json and report again as the first time."
  else
    prompt=${HERD_RESUME:-"Orchestrator: your session was resumed after an interruption; background jobs are gone. Check your worktrees (git status, git log), rewrite $herd/$slice.status.json and continue your task $task."}
  fi
else
  sid=$(python3 -c 'import uuid; print(uuid.uuid4())')
  prompt="You are worker $slice of herd $name."
  [ -n "$rules" ] && prompt="$prompt Read $rules first, then your task $task, and work through it." \
                  || prompt="$prompt Read your task $task and work through it."
  if [ "$phase" = fix_queued ] && [ -n "$befunde" ]; then
    case $befunde in /*) ;; *) befunde="$herd/$befunde" ;; esac
    prompt="$prompt This is a fix round: the review findings are in $befunde."
  fi
fi

pre="cd $(printf '%q' "$first"); export HERD_DIR=$(printf '%q' "$herd") HERD_SLICE=$(printf '%q' "$slice"); "
[ "${HERD_SPAWN_UNSET_KEYS:-1}" = 0 ] || pre="${pre}unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN; "
if [ -n "${HERD_GIT_NAME:-}" ]; then
  q=$(printf '%q' "$HERD_GIT_NAME"); pre="${pre}export GIT_AUTHOR_NAME=$q GIT_COMMITTER_NAME=$q; "
fi
if [ -n "${HERD_GIT_EMAIL:-}" ]; then
  q=$(printf '%q' "$HERD_GIT_EMAIL"); pre="${pre}export GIT_AUTHOR_EMAIL=$q GIT_COMMITTER_EMAIL=$q; "
fi
[ -n "${HERD_SPAWN_ENV:-}" ] && pre="$pre$HERD_SPAWN_ENV; "
# --permission-mode auto, not --dangerously-skip-permissions: an orchestrator in auto mode gets the latter
# blocked as unsafe agent creation. The prompt is argv, so no separate `agent prompt` can race the TUI.
if [ "$resume" = 1 ]; then
  cmd="${pre}claude --resume $sid --model $(printf '%q' "$model") --effort $effort --permission-mode auto $(printf '%q' "$prompt")"
else
  cmd="${pre}claude --session-id $sid --model $(printf '%q' "$model") --effort $effort --permission-mode auto $(printf '%q' "$prompt")"
fi

hj() { herdr "$@" || die "herdr $* failed" 4; }

# --- a resumed worker whose pane is still alive: talk to it there ----------------------------------------------
pane=""; mode=new
if [ "$resume" = 1 ] && [ -n "$last_pane" ]; then
  agents=$(hj agent list)
  a_status=$(jq -r --arg p "$last_pane" '.result.agents[] | select(.pane_id==$p) | .agent_status' <<<"$agents" | head -1)
  a_sess=$(jq -r --arg p "$last_pane" '.result.agents[] | select(.pane_id==$p) | (.agent_session.value // "")' <<<"$agents" | head -1)
  if [ -n "$a_status" ] && { [ -z "$a_sess" ] || [ "$a_sess" = "$sid" ]; }; then
    case $a_status in
      working|blocked) die "$slice is still $a_status in $last_pane — nothing to resume" ;;
      *) pane=$last_pane; mode=prompt ;;
    esac
  elif [ -z "$a_status" ] && hj pane list | jq -e --arg p "$last_pane" '.result.panes[] | select(.pane_id==$p)' >/dev/null; then
    pane=$last_pane; mode=run   # bare shell left after the TUI died: resume in place
  fi
fi

# --- otherwise place a new pane in the herde tab ---------------------------------------------------------------
created=0
if [ -z "$pane" ]; then
  tab=$(hj tab list | jq -r --arg ws "$ws" --arg l "$label" '.result.tabs[] | select(.workspace_id==$ws and .label==$l) | .tab_id' | head -1)
  big=""; rows=0
  if [ -n "$tab" ]; then
    read -r big rows < <(hj pane list | jq -r --arg t "$tab" '[.result.panes[] | select(.tab_id==$t)] | max_by(.scroll.viewport_rows // 0) | if . then "\(.pane_id) \(.scroll.viewport_rows // 0)" else "" end') || true
  fi
  if [ -z "$big" ]; then   # no herde tab (or an empty one about to close)
    # first worker: open a pane next to the anchor, then move it straight into a new tab
    pane=$(hj pane split --pane "$anchor" --direction right --cwd "$first" --no-focus | jq -r '.result.pane.pane_id')
    tab=$(hj pane move "$pane" --new-tab | jq -r '.result.move_result.created_tab.tab_id')
    hj tab rename "$tab" "$label" >/dev/null
  else
    dir=down; [ "${rows:-0}" -ge 24 ] || dir=right
    pane=$(hj pane split --pane "$big" --direction "$dir" --cwd "$first" --no-focus | jq -r '.result.pane.pane_id')
  fi
  [ -n "$pane" ] && [ "$pane" != null ] || die "herdr returned no pane id" 4
  created=1
  # a pane move steals focus — hand it back to the orchestrator
  herdr agent focus "$anchor" >/dev/null 2>&1 || herdr tab focus "${anchor%:*}:t1" >/dev/null 2>&1 || true
fi

if [ "$mode" = prompt ]; then
  herdr agent prompt "$pane" "$prompt" >/dev/null || die "herdr agent prompt $pane failed" 4
elif ! herdr pane run "$pane" "$cmd" >/dev/null; then
  [ "$created" = 1 ] && herdr pane close "$pane" >/dev/null 2>&1 || true
  die "herdr pane run $pane failed" 4
fi

note="started"; [ "$resume" = 1 ] && note="resumed session ($mode)"
[ "$phase" = fix_queued ] && note="$note, fix round"
if ! "$here/herd-phase" "$herd" "$slice" working --by "${HERD_SPAWN_BY:-orchestrator}" \
    --field "pane=$pane" --field "session_id=$sid" --field "model=$model" --field "effort=$effort" \
    --field "wt=$wt_json" --note "$note" >/dev/null; then
  die "$slice runs in $pane but the working event could not be written — fix with herd-phase by hand" 5
fi

reg=$HOME/.cache/herd-board/${anchor//:/_}.herds
mkdir -p "${reg%/*}"; grep -qxF "$herd" "$reg" 2>/dev/null || echo "$herd" >> "$reg"
command -v herd-board >/dev/null 2>&1 && { herd-board --open --anchor "$anchor" >/dev/null 2>&1 || true; }
echo "$slice $note in $pane (session $sid, $model/$effort)"
