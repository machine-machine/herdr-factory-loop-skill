#!/usr/bin/env bash
# m2herd-up.sh — m2herd workspace bootstrap + dispatch (slice C of the m2herd contract).
#
# Claude Code (Fable) is the MAIN orchestrator; .m2herd/ is the per-repo context
# fabric. This script does the MECHANICAL herdr work: stand up the workspace shape
# (exactly one orchestrator pane + one notes pane live-viewing NOTES.md), fan a
# slice out to a worktree'd worker over the file protocol, and collect its report
# back into .m2herd/dispatch/. Judgment (what to put in a task file, what to do
# with a report) stays with the orchestrator.
#
# Usage:
#   m2herd-up.sh up       [--repo P] [--goal "…"]   # ensure herdr workspace: ONE orchestrator pane (claude) + ONE notes pane; m2herd.sh init if missing
#   m2herd-up.sh dispatch --slice S [--repo P] [--base BRANCH] [--agent claude|codex|cursor]
#                                                   # worktree wip/m2herd-<S> off BASE (default: current branch), spawn worker,
#                                                   # file-protocol dispatch of .m2herd/dispatch/S.task.md, record in overview.json workers[]
#   m2herd-up.sh collect  --slice S [--repo P]      # wait idle, copy worker report to dispatch/S.out.md, update workers[] state
#   m2herd-up.sh --dry-run <same args>              # print every herdr/git command instead of running it
#
# Binding herdr rules (from CONTRACT-m2herd.md): identify $SELF first and never
# touch it; after `agent start` RE-RESOLVE the pane by cwd from `herdr agent list`
# (the returned pane_id can be off by one); no `--split` (stray-pane bug); settle
# ~1s between `agent send` and the Enter. Idempotent. Safe to re-run.

set -euo pipefail

# ---------- arg parsing ------------------------------------------------------
DRY_RUN=0
while [ "${1:-}" = "--dry-run" ]; do DRY_RUN=1; shift; done
CMD="${1:-help}"; shift || true
REPO=""; GOAL=""; SLICE=""; BASE=""; AGENT="claude"
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --goal) GOAL="$2"; shift 2 ;;
    --slice) SLICE="$2"; shift 2 ;;
    --base) BASE="$2"; shift 2 ;;
    --agent) AGENT="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) CMD="help"; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NOTES_TAB_LABEL="m2herd-notes"
SUBMIT_SETTLE="${SUBMIT_SETTLE:-1}"                 # settle between `agent send` and Enter
WAIT_TIMEOUT="${M2HERD_WAIT_TIMEOUT:-1800000}"      # collect: ms to wait for worker idle

log()        { printf '  %s\n' "$*"; }
plan()       { log "[dry-run] $*"; }
do_or_echo() { if [ "$DRY_RUN" -eq 1 ]; then plan "$*"; else eval "$@"; fi; }
need()       { command -v "$1" >/dev/null 2>&1 || { echo "required tool not on PATH: $1" >&2; exit 1; }; }
utc_now()    { date -u +%Y-%m-%dT%H:%M:%SZ; }

# ---------- repo / self resolution -------------------------------------------
resolve_repo() {
  [ -n "$REPO" ] || REPO="$PWD"
  REPO="$(cd "$REPO" 2>/dev/null && pwd)" || { echo "no such repo dir: $REPO" >&2; exit 1; }
  git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || { echo "not a git repo: $REPO" >&2; exit 1; }
  OV="$REPO/.m2herd/overview.json"
}

# Binding rule: identify the orchestrator's own pane BEFORE any send/close and
# treat it as read-only. Empty when the fleet is unreachable (dry-run tolerates).
SELF=""
resolve_self() {
  SELF="$(herdr agent list 2>/dev/null | jq -r '[.result.agents[] | select(.focused==true)] | first | .pane_id // empty' 2>/dev/null || true)"
}
is_self() { [ -n "$SELF" ] && [ "$1" = "$SELF" ]; }

# Binding rule: the pane_id returned by `agent start` can be off by one — always
# RE-RESOLVE by cwd from `herdr agent list` (prefer a name match when given).
resolve_pane_by_cwd() { # resolve_pane_by_cwd <cwd> [name] -> pane_id (retries; list can lag)
  local cwd="$1" name="${2:-}" i pane=""
  for i in 1 2 3 4 5; do
    if [ -n "$name" ]; then
      pane="$(herdr agent list 2>/dev/null | jq -r --arg c "$cwd" --arg n "$name" \
        '[.result.agents[] | select(.cwd==$c and .name==$n)] | last | .pane_id // empty' 2>/dev/null || true)"
    fi
    [ -n "$pane" ] || pane="$(herdr agent list 2>/dev/null | jq -r --arg c "$cwd" \
      '[.result.agents[] | select(.cwd==$c)] | last | .pane_id // empty' 2>/dev/null || true)"
    [ -n "$pane" ] && break
    sleep 1
  done
  printf '%s' "$pane"
}

# worker -> "binary<TAB>flag" (same table as herd-loop.sh)
worker_argv() {
  case "$1" in
    codex)  printf '%s\t%s\n' "codex" "--dangerously-bypass-approvals-and-sandbox" ;;
    claude) printf '%s\t%s\n' "claude" "--dangerously-skip-permissions" ;;
    cursor) printf '%s\t%s\n' "cursor-agent" "--force" ;;
    *) printf '%s\t%s\n' "$1" "" ;;
  esac
}

# ---------- overview.json writers (always rewrite the whole file with jq) -----
record_worker() { # record_worker <slice> <pane> <worktree> <branch> <state>
  local slice="$1" pane="$2" wt="$3" branch="$4" state="$5" tmp
  if [ "$DRY_RUN" -eq 1 ]; then
    plan "jq rewrite $OV: workers[] += {slice:\"$slice\", pane_id:\"$pane\", worktree:\"$wt\", branch:\"$branch\", state:\"$state\", task:\".m2herd/dispatch/$slice.task.md\", out:\".m2herd/dispatch/$slice.out.md\"}"
    return 0
  fi
  [ -f "$OV" ] || { echo "no overview.json at $OV (run: m2herd-up.sh up --repo $REPO)" >&2; exit 1; }
  tmp="$(mktemp)"
  jq --arg slice "$slice" --arg pane "$pane" --arg wt "$wt" --arg br "$branch" \
     --arg st "$state" --arg ts "$(utc_now)" '
    .workers = ((.workers // []) | map(select(.slice != $slice))) + [{
      slice: $slice, pane_id: $pane, worktree: $wt, branch: $br, state: $st,
      task: (".m2herd/dispatch/" + $slice + ".task.md"),
      out:  (".m2herd/dispatch/" + $slice + ".out.md") }]
    | .updated_at = $ts
  ' "$OV" > "$tmp"
  mv "$tmp" "$OV"
}

set_worker_state() { # set_worker_state <slice> <state>
  local slice="$1" state="$2" tmp
  if [ "$DRY_RUN" -eq 1 ]; then plan "jq rewrite $OV: workers[slice==$slice].state = \"$state\""; return 0; fi
  [ -f "$OV" ] || { echo "no overview.json at $OV" >&2; exit 1; }
  tmp="$(mktemp)"
  jq --arg slice "$slice" --arg st "$state" --arg ts "$(utc_now)" '
    .workers = ((.workers // []) | map(if .slice == $slice then .state = $st else . end))
    | .updated_at = $ts
  ' "$OV" > "$tmp"
  mv "$tmp" "$OV"
}

# ---------- file-protocol submit (settle before Enter) ------------------------
submit_pointer() { # submit_pointer <pane> <text>
  local pane="$1" text="$2"
  is_self "$pane" && { log "! refusing to send to \$SELF pane $pane"; return 0; }
  if [ "$DRY_RUN" -eq 1 ]; then
    plan "herdr agent send '$pane' \"$text\""
    plan "sleep $SUBMIT_SETTLE   # settle so the Enter doesn't race the text injection"
    plan "herdr pane send-keys '$pane' Enter"
    return 0
  fi
  herdr agent send "$pane" "$text" >/dev/null 2>&1 || true
  sleep "$SUBMIT_SETTLE"
  herdr pane send-keys "$pane" Enter >/dev/null 2>&1 || true
}

# ---------- up: workspace bootstrap -------------------------------------------
# Notes pane viewer command (exact strings from the contract).
notes_viewer_cmd() {
  if command -v watch >/dev/null 2>&1; then
    printf '%s' 'watch -n 2 -t cat .m2herd/NOTES.md'
  else
    printf '%s' 'while :; do clear; cat .m2herd/NOTES.md; sleep 2; done'
  fi
}

up() {
  resolve_repo; resolve_self
  log "up: repo=$REPO (self pane: ${SELF:-<unknown>})"

  # 1. .m2herd/ context fabric — scaffold via the engine if missing
  if [ ! -d "$REPO/.m2herd" ]; then
    local init="$SCRIPT_DIR/m2herd.sh" initargs="init --dir \"$REPO\""
    [ -n "$GOAL" ] && initargs="$initargs --goal \"$GOAL\""
    if [ "$DRY_RUN" -eq 1 ]; then
      plan "$init $initargs"
    else
      [ -x "$init" ] || { echo "no .m2herd/ and $init not found/executable — need slice A's engine" >&2; exit 1; }
      eval "\"$init\" $initargs"
    fi
  else
    log ".m2herd/ present — skipping init"
  fi

  # 2. herdr workspace for the repo — reuse the one already holding a pane cwd'd
  #    at the repo, else create (idempotency key: a pane whose cwd == repo).
  local ws
  ws="$(herdr pane list 2>/dev/null | jq -r --arg c "$REPO" \
    '[.result.panes[] | select(.cwd==$c)] | first | .workspace_id // empty' 2>/dev/null || true)"
  if [ -n "$ws" ]; then
    log "workspace exists: $ws"
  elif [ "$DRY_RUN" -eq 1 ]; then
    plan "herdr workspace create --cwd '$REPO' --label 'm2herd:$(basename "$REPO")' --no-focus"
    ws="WS-DRYRUN"
  else
    herdr workspace create --cwd "$REPO" --label "m2herd:$(basename "$REPO")" --no-focus >/dev/null 2>&1 || true
    ws="$(herdr pane list 2>/dev/null | jq -r --arg c "$REPO" \
      '[.result.panes[] | select(.cwd==$c)] | first | .workspace_id // empty' 2>/dev/null || true)"
    [ -n "$ws" ] || { echo "workspace create failed (herdr server up?)" >&2; exit 1; }
    log "workspace created: $ws"
  fi

  # 3. EXACTLY ONE orchestrator pane (claude). Idempotent: spawn only when none
  #    exists; never close extras (one could be $SELF mid-work) — warn instead.
  local orch_name="m2herd-orch-$(basename "$REPO")" orch n
  orch="$(herdr agent list 2>/dev/null | jq -r --arg c "$REPO" --arg n "$orch_name" \
    '[.result.agents[] | select(.cwd==$c and ((.name // "")==$n or (.name // "")=="claude"))] | map(.pane_id) | join("\n")' 2>/dev/null || true)"
  n="$(printf '%s' "$orch" | grep -c . || true)"
  if [ "${n:-0}" -eq 0 ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
      plan "herdr agent start '$orch_name' --workspace '$ws' --cwd '$REPO' --no-focus -- \"\$(command -v claude)\" --dangerously-skip-permissions"
      plan "re-resolve orchestrator pane by cwd from 'herdr agent list' (returned pane_id can be off by one)"
      orch="PANE-DRYRUN"
    else
      need claude
      herdr agent start "$orch_name" --workspace "$ws" --cwd "$REPO" --no-focus -- \
        "$(command -v claude)" --dangerously-skip-permissions >/dev/null 2>&1 || true
      orch="$(resolve_pane_by_cwd "$REPO" "$orch_name")"
      [ -n "$orch" ] || { echo "orchestrator pane never appeared in agent list" >&2; exit 1; }
      log "orchestrator spawned: pane $orch ($orch_name)"
    fi
  elif [ "$n" -eq 1 ]; then
    orch="$(printf '%s' "$orch" | head -1)"
    log "orchestrator pane exists: $orch"
  else
    orch="$(printf '%s' "$orch" | head -1)"
    log "! $n orchestrator panes found (want EXACTLY ONE) — keeping $orch; close extras by hand (never \$SELF)"
  fi

  # 4. ONE notes pane live-viewing NOTES.md. Idempotency key: the tab label —
  #    a labeled tab survives restarts and is observable via `herdr tab list`.
  local viewer tab notes
  viewer="$(notes_viewer_cmd)"
  tab="$(herdr tab list --workspace "$ws" 2>/dev/null | jq -r --arg l "$NOTES_TAB_LABEL" \
    '[.result.tabs[] | select((.label // "")==$l)] | first | .tab_id // empty' 2>/dev/null || true)"
  if [ -n "$tab" ]; then
    notes="$(herdr pane list --workspace "$ws" 2>/dev/null | jq -r --arg t "$tab" \
      '[.result.panes[] | select(.tab_id==$t)] | first | .pane_id // empty' 2>/dev/null || true)"
    log "notes pane exists: ${notes:-<tab $tab, pane unresolved>} (viewer assumed running)"
  elif [ "$DRY_RUN" -eq 1 ]; then
    plan "herdr tab create --workspace '$ws' --cwd '$REPO' --label '$NOTES_TAB_LABEL' --no-focus"
    plan "herdr pane run '<notes-pane>' '$viewer'"
  else
    herdr tab create --workspace "$ws" --cwd "$REPO" --label "$NOTES_TAB_LABEL" --no-focus >/dev/null 2>&1 || true
    tab="$(herdr tab list --workspace "$ws" 2>/dev/null | jq -r --arg l "$NOTES_TAB_LABEL" \
      '[.result.tabs[] | select((.label // "")==$l)] | first | .tab_id // empty' 2>/dev/null || true)"
    [ -n "$tab" ] || { echo "notes tab create failed" >&2; exit 1; }
    notes="$(herdr pane list --workspace "$ws" 2>/dev/null | jq -r --arg t "$tab" \
      '[.result.panes[] | select(.tab_id==$t)] | first | .pane_id // empty' 2>/dev/null || true)"
    [ -n "$notes" ] || { echo "notes pane never appeared in pane list" >&2; exit 1; }
    if is_self "$notes"; then
      log "! notes pane resolved to \$SELF ($notes) — refusing to touch it"
    else
      sleep 1   # let the fresh pane's shell come up before typing into it
      herdr pane run "$notes" "$viewer" >/dev/null 2>&1 || true
      log "notes pane started: $notes ($viewer)"
    fi
  fi

  log "up: done — workspace $ws, orchestrator ${orch:-?}, notes ${notes:-<pending>}"
}

# ---------- dispatch: worktree + worker + file-protocol task -------------------
dispatch() {
  [ -n "$SLICE" ] || { echo "dispatch needs --slice S" >&2; exit 2; }
  resolve_repo; resolve_self
  [ -n "$BASE" ] || BASE="$(git -C "$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)"
  local branch="wip/m2herd-$SLICE" task="$REPO/.m2herd/dispatch/$SLICE.task.md"
  log "dispatch: slice=$SLICE repo=$REPO base=$BASE agent=$AGENT (self pane: ${SELF:-<unknown>})"

  # task file is the deliverable definition — the orchestrator writes it first
  if [ ! -f "$task" ]; then
    if [ "$DRY_RUN" -eq 1 ]; then log "! task file missing: $task (write it before a real dispatch)"
    else echo "no task file: $task — write the slice's task there first (file protocol)" >&2; exit 1; fi
  fi

  local av bin flag; av="$(worker_argv "$AGENT")"; bin="${av%%$'\t'*}"; flag="${av##*$'\t'}"
  if [ "$DRY_RUN" -eq 0 ] && ! command -v "$bin" >/dev/null 2>&1; then
    echo "worker binary '$bin' not on PATH" >&2; exit 1
  fi

  # 1. isolated worktree off BASE
  local wt
  if [ "$DRY_RUN" -eq 1 ]; then
    plan "herdr worktree create --cwd '$REPO' --branch '$branch' --base '$BASE' --label 'm2herd-$SLICE' --json"
    wt="$HOME/.herdr/worktrees/$(basename "$REPO")/wip-m2herd-$SLICE"
    log "(worktree path placeholder: $wt)"
  else
    wt="$(herdr worktree create --cwd "$REPO" --branch "$branch" --base "$BASE" --label "m2herd-$SLICE" --json 2>/dev/null | jq -r '.result.worktree.path // empty')"
    [ -n "$wt" ] || { echo "worktree create failed for $branch" >&2; exit 1; }
    log "worktree: $wt ($branch off $BASE)"
  fi

  # 2. spawn the worker — unique agent name, NO --split (stray-pane bug), no focus
  local wname="$AGENT-m2herd-$SLICE" pane
  if [ "$DRY_RUN" -eq 1 ]; then
    plan "herdr agent start '$wname' --cwd '$wt' --no-focus -- \"\$(command -v $bin)\" $flag"
    plan "re-resolve worker pane by cwd from 'herdr agent list' (returned pane_id can be off by one)"
    pane="PANE-DRYRUN"
  else
    herdr agent start "$wname" --cwd "$wt" --no-focus -- "$(command -v "$bin")" $flag >/dev/null 2>&1 || true
    pane="$(resolve_pane_by_cwd "$wt" "$wname")"
    [ -n "$pane" ] || { echo "worker pane never appeared in agent list (cwd $wt)" >&2; exit 1; }
    is_self "$pane" && { echo "resolved worker pane is \$SELF ($pane) — refusing" >&2; exit 1; }
    log "worker spawned: pane $pane ($wname)"
    sleep 2   # let the TUI boot before the pointer lands
  fi

  # 3. file-protocol dispatch: one-line pointer, settle, Enter
  submit_pointer "$pane" "Read $task and follow its instructions exactly."

  # 4. record in overview.json workers[]
  record_worker "$SLICE" "$pane" "$wt" "$branch" "spawned"
  log "dispatch: done — $SLICE recorded in overview.json (state=spawned)"
}

# ---------- collect: wait idle, copy report, update state ----------------------
collect() {
  [ -n "$SLICE" ] || { echo "collect needs --slice S" >&2; exit 2; }
  resolve_repo; resolve_self
  local out="$REPO/.m2herd/dispatch/$SLICE.out.md" pane
  if [ "$DRY_RUN" -eq 1 ]; then
    pane="$(jq -r --arg s "$SLICE" '[.workers[]? | select(.slice==$s)] | first | .pane_id // empty' "$OV" 2>/dev/null || true)"
    pane="${pane:-PANE-DRYRUN}"
    plan "herdr agent wait '$pane' --status idle --timeout $WAIT_TIMEOUT"
    plan "herdr agent read '$pane' --source recent-unwrapped --lines 300  # → $out (unless worker already wrote it)"
    set_worker_state "$SLICE" "done"
    log "collect: dry-run plan complete for $SLICE"
    return 0
  fi

  [ -f "$OV" ] || { echo "no overview.json at $OV" >&2; exit 1; }
  pane="$(jq -r --arg s "$SLICE" '[.workers[]? | select(.slice==$s)] | first | .pane_id // empty' "$OV")"
  [ -n "$pane" ] || { echo "slice '$SLICE' not in overview.json workers[] — dispatch it first" >&2; exit 1; }
  is_self "$pane" && { echo "worker pane for $SLICE is \$SELF ($pane) — refusing" >&2; exit 1; }

  log "collect: waiting for $SLICE (pane $pane) to go idle (timeout ${WAIT_TIMEOUT}ms)"
  if ! herdr agent wait "$pane" --status idle --timeout "$WAIT_TIMEOUT" >/dev/null 2>&1; then
    echo "worker $SLICE (pane $pane) did not reach idle within ${WAIT_TIMEOUT}ms" >&2
    set_worker_state "$SLICE" "failed"
    exit 1
  fi

  # the FILE is the deliverable: keep a report the worker already wrote via the
  # file protocol; only fall back to scraping the pane scrollback.
  if [ -s "$out" ]; then
    log "worker already wrote $out — keeping it"
  else
    # `herdr agent read` prints the raw JSON socket envelope — extract the text payload.
    herdr agent read "$pane" --source recent-unwrapped --lines 300 2>/dev/null \
      | jq -r '.result.read.text // empty' > "$out" 2>/dev/null || true
    [ -s "$out" ] || herdr agent read "$pane" --source recent-unwrapped --lines 300 > "$out" 2>/dev/null || true
    log "copied worker report → $out"
  fi

  set_worker_state "$SLICE" "done"
  log "collect: done — $SLICE state=done, report at $out"
}

# ---------- dispatch table -----------------------------------------------------
need jq
case "$CMD" in
  up)       up ;;
  dispatch) dispatch ;;
  collect)  collect ;;
  help|*)   sed -n '2,24p' "$0" ;;
esac
