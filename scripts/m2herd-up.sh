#!/usr/bin/env bash
# m2herd-up.sh — m2herd workspace bootstrap + dispatch (slice C of the m2herd contract).
#
# Claude Code (Fable) is the MAIN orchestrator; .m2herd/ is the per-repo context
# fabric. This script does the MECHANICAL herdr work: stand up the workspace shape
# (exactly one orchestrator pane + one machineroom pane live-viewing NOTES.md), fan a
# slice out to a worktree'd worker over the file protocol, and collect its report
# back into .m2herd/dispatch/. Judgment (what to put in a task file, what to do
# with a report) stays with the orchestrator.
#
# Usage:
#   m2herd-up.sh up       [--repo P] [--goal "…"] [--room-only]
#                                                   # ensure herdr workspace: ONE orchestrator pane (claude) + ONE machineroom pane; m2herd.sh init if missing
#                                                   # --room-only: workspace + machineroom ONLY, never spawn an orchestrator — for the
#                                                   #   auto-kick path where the calling Claude Code session IS the orchestrator
#   m2herd-up.sh dispatch --slice S [--repo P] [--base BRANCH] [--agent claude|codex|cursor]
#                         [--headless [--model M]]  # worktree wip/m2herd-<S> off BASE (default: current branch), spawn worker,
#                                                   # file-protocol dispatch of .m2herd/dispatch/S.task.md, record in overview.json workers[]
#                                                   # --headless: no pane/TUI — `claude -p --model M` (default sonnet) or `codex exec`
#                                                   #   in the worktree via nohup; log → dispatch/S.log, answer → dispatch/S.out.md;
#                                                   #   usage (tokens/cost) parsed into workers[] at collect. Cheap hands, Fable judgment.
#   m2herd-up.sh collect  --slice S [--repo P]      # wait idle (pane) / exited (headless pid), keep/copy report to dispatch/S.out.md,
#                                                   # update workers[] state (+tokens/cost for headless)
#   m2herd-up.sh --dry-run <same args>              # print every herdr/git command instead of running it
#
# Binding herdr rules (from CONTRACT-m2herd.md): identify $SELF first and never
# touch it; after `agent start` RE-RESOLVE the pane by cwd from `herdr agent list`
# (the returned pane_id can be off by one); no `--split` (stray-pane bug); settle
# ~1s between `agent send` and the Enter. Idempotent. Safe to re-run.
#
# Trace bundles (evolver contract §1): dispatch ensures a run under
# .m2herd/runs/<run-id>/ (CURRENT pointer + run.json), records the slice into
# run.json's slices[], and writes runs/<id>/slices/<S>/{prompt.md,status.json}
# for BOTH pane and headless workers. collect completes the bundle: copies the
# report.md, flips status.json to done|failed, and fills tokens/cost_usd when
# the headless usage JSON has them. Trace writes are best-effort — a failure
# warns ("trace: ...") but never aborts dispatch/collect; the worker flow is
# the priority, traces are telemetry. Lesson injection (contract §4): when
# .m2herd/evolver/LESSONS.md has content below the M2HERD:LIVE marker, both
# the pane and headless pointer messages gain one extra sentence pointing the
# worker at it; the task file itself is never mutated.

set -euo pipefail

# ---------- arg parsing ------------------------------------------------------
DRY_RUN=0
while [ "${1:-}" = "--dry-run" ]; do DRY_RUN=1; shift; done
CMD="${1:-help}"; shift || true
REPO=""; GOAL=""; SLICE=""; BASE=""; AGENT="claude"; HEADLESS=0; MODEL=""; ROOM_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --goal) GOAL="$2"; shift 2 ;;
    --slice) SLICE="$2"; shift 2 ;;
    --base) BASE="$2"; shift 2 ;;
    --agent) AGENT="$2"; shift 2 ;;
    --headless) HEADLESS=1; shift ;;
    --room-only) ROOM_ONLY=1; shift ;;
    --model) MODEL="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) CMD="help"; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

# Resolve through symlinks ($0 may be ~/.local/bin/m2herd-up → scripts/m2herd-up.sh);
# macOS has no readlink -f, so walk the link chain by hand.
self_path() {
  local p="$0" l
  while [ -L "$p" ]; do
    l="$(readlink "$p")"
    case "$l" in /*) p="$l" ;; *) p="$(dirname "$p")/$l" ;; esac
  done
  printf '%s' "$p"
}
SCRIPT_DIR="$(cd "$(dirname "$(self_path)")" && pwd)"
NOTES_TAB_LABEL="machineroom"
# pre-rename installs used this label; still honored for idempotence
NOTES_TAB_LABEL_OLD="m2herd-notes"
SUBMIT_SETTLE="${SUBMIT_SETTLE:-1}"                 # settle between `agent send` and Enter
WAIT_TIMEOUT="${M2HERD_WAIT_TIMEOUT:-1800000}"      # collect: ms to wait for worker idle

log()        { printf '  %s\n' "$*"; }
plan()       { log "[dry-run] $*"; }
do_or_echo() { if [ "$DRY_RUN" -eq 1 ]; then plan "$*"; else eval "$@"; fi; }
need()       { command -v "$1" >/dev/null 2>&1 || { echo "required tool not on PATH: $1" >&2; exit 1; }; }
utc_now()    { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Are we running inside a herdr-managed pane? Walk the ancestor process chain
# (bounded ~25 hops) and match any ancestor command name containing "herdr".
# Deliberately does NOT trust HERDR_* env vars — those are user-settable outside
# herdr. `ps -o ppid=/-o comm=` behaves the same on macOS and Linux.
inside_herdr() {
  local pid=$$ hops=0 comm ppid
  while [ "$hops" -lt 25 ]; do
    comm="$(ps -o comm= -p "$pid" 2>/dev/null || true)"
    case "$comm" in *herdr*) return 0 ;; esac
    ppid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
    [ -n "$ppid" ] || break
    [ "$ppid" -le 1 ] 2>/dev/null && break
    pid="$ppid"; hops=$((hops + 1))
  done
  return 1
}

# Loud, tty-gated warning that we are NOT inside herdr: panes we spawn land in a
# herdr session nobody is looking at. WARNING only — never aborts, never changes
# behavior. Colorized (yellow/bold via tput) only when stderr is a real tty.
warn_not_in_herdr() { # warn_not_in_herdr [extra-suffix]
  local extra="${1:-}" c1="" c0=""
  if [ -t 2 ] && command -v tput >/dev/null 2>&1; then
    c1="$(tput bold 2>/dev/null || true)$(tput setaf 3 2>/dev/null || true)"
    c0="$(tput sgr0 2>/dev/null || true)"
  fi
  printf '%s\n' "${c1}⚠  not running inside herdr — panes will spawn in a herdr session you are not viewing; attach with \`herdr\` to see them${extra}${c0}" >&2
}

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

# Resolve the orchestrator's pane the SAME way up() does: an agent cwd'd at $REPO
# whose name is m2herd-orch-<basename> (or a bare "claude"). Empty if unresolved
# (no workspace, up never ran, fleet unreachable) — callers fall back gracefully.
resolve_orch_pane() { # -> pane_id
  local orch_name="m2herd-orch-$(basename "$REPO")"
  herdr agent list 2>/dev/null | jq -r --arg c "$REPO" --arg n "$orch_name" \
    '[.result.agents[] | select(.cwd==$c and ((.name // "")==$n or (.name // "")=="claude"))] | first | .pane_id // empty' 2>/dev/null || true
}

# tab_id that owns a given pane (from `herdr pane list`). Empty if not found.
pane_tab_id() { # pane_tab_id <pane_id> -> tab_id
  herdr pane list 2>/dev/null | jq -r --arg p "$1" \
    '[.result.panes[] | select(.pane_id==$p)] | first | .tab_id // empty' 2>/dev/null || true
}

# Worker panes living in <tab> — every pane in the tab that is neither the
# orchestrator nor $SELF, in the order `pane list` returns them (the LAST one is
# the split target for the next worker).
worker_panes_in_tab() { # worker_panes_in_tab <tab_id> <orch_pane> -> pane ids, one per line
  herdr pane list 2>/dev/null | jq -r --arg t "$1" --arg o "$2" --arg s "$SELF" \
    '[.result.panes[] | select(.tab_id==$t and .pane_id!=$o and .pane_id!=$s)] | .[].pane_id' 2>/dev/null || true
}

# Resolve a freshly-split pane by cwd from `herdr pane list` (retries; the list
# can lag the split). A slice's worktree path is unique, so cwd pins the pane.
resolve_pane_by_cwd_panes() { # resolve_pane_by_cwd_panes <cwd> -> pane_id
  local cwd="$1" i pane=""
  for i in 1 2 3 4 5; do
    pane="$(herdr pane list 2>/dev/null | jq -r --arg c "$cwd" \
      '[.result.panes[] | select(.cwd==$c)] | last | .pane_id // empty' 2>/dev/null || true)"
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
record_worker() { # record_worker <slice> <pane> <worktree> <branch> <state> [mode] [model] [pid]
  local slice="$1" pane="$2" wt="$3" branch="$4" state="$5" mode="${6:-tui}" model="${7:-}" pid="${8:-}" tmp
  if [ "$DRY_RUN" -eq 1 ]; then
    plan "jq rewrite $OV: workers[] += {slice:\"$slice\", pane_id:\"$pane\", mode:\"$mode\"${model:+, model:\"$model\"}${pid:+, pid:$pid}, worktree:\"$wt\", branch:\"$branch\", state:\"$state\", …}"
    return 0
  fi
  [ -f "$OV" ] || { echo "no overview.json at $OV (run: m2herd-up.sh up --repo $REPO)" >&2; exit 1; }
  tmp="$(mktemp)"
  jq --arg slice "$slice" --arg pane "$pane" --arg wt "$wt" --arg br "$branch" \
     --arg st "$state" --arg ts "$(utc_now)" --arg mode "$mode" --arg model "$model" --arg pid "$pid" '
    .workers = ((.workers // []) | map(select(.slice != $slice))) + [({
      slice: $slice, pane_id: $pane, worktree: $wt, branch: $br, state: $st, mode: $mode,
      task: (".m2herd/dispatch/" + $slice + ".task.md"),
      out:  (".m2herd/dispatch/" + $slice + ".out.md") }
      + (if $model != "" then {model: $model} else {} end)
      + (if $pid != "" then {pid: ($pid | tonumber)} else {} end))]
    | .updated_at = $ts
  ' "$OV" > "$tmp"
  mv "$tmp" "$OV"
}

set_worker_usage() { # set_worker_usage <slice> <output_tokens> <cost_usd>
  local slice="$1" tok="$2" cost="$3" tmp
  [ "$DRY_RUN" -eq 1 ] && { plan "jq rewrite $OV: workers[slice==$slice] += {tokens:$tok, cost_usd:$cost}"; return 0; }
  [ -f "$OV" ] || return 0
  tmp="$(mktemp)"
  jq --arg s "$slice" --arg tok "$tok" --arg cost "$cost" '
    .workers = ((.workers // []) | map(if .slice == $s then
      . + (if $tok  != "" then {tokens:   ($tok  | tonumber)} else {} end)
        + (if $cost != "" then {cost_usd: ($cost | tonumber)} else {} end)
    else . end))
  ' "$OV" > "$tmp" && mv "$tmp" "$OV"
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

# ---------- run trace bundles (.m2herd/runs/<run-id>/, evolver contract §1) ---
# Best-effort telemetry: every writer here warns and returns 1 on failure
# instead of letting `set -e` tear down dispatch/collect. Callers guard with
# `|| true`.
trace_warn() { log "trace: $* (non-fatal, continuing)"; }

RUN_ID=""   # set by run_ensure

# Ensure .m2herd/runs/CURRENT + run.json exist; create a new run if CURRENT is
# missing. Sets $RUN_ID. Read-modify-write is jq whole-file, same idiom as the
# overview.json writers above.
run_ensure() {
  local runs="$REPO/.m2herd/runs" cur goal rj
  cur="$runs/CURRENT"
  if [ "$DRY_RUN" -eq 1 ]; then
    RUN_ID="$(cat "$cur" 2>/dev/null || true)"
    if [ -z "$RUN_ID" ]; then
      RUN_ID="r-$(date -u +%Y%m%dT%H%M%SZ)"
      plan "mkdir -p $runs/$RUN_ID/slices; write $runs/$RUN_ID/run.json (run_id, created_at, goal, base); write $cur"
    else
      plan "reuse existing run $RUN_ID ($cur)"
    fi
    return 0
  fi
  mkdir -p "$runs" 2>/dev/null || { trace_warn "cannot create $runs"; RUN_ID=""; return 1; }
  RUN_ID="$(cat "$cur" 2>/dev/null || true)"
  if [ -z "$RUN_ID" ]; then
    RUN_ID="r-$(date -u +%Y%m%dT%H%M%SZ)"
    rj="$runs/$RUN_ID/run.json"
    mkdir -p "$runs/$RUN_ID/slices" || { trace_warn "mkdir $runs/$RUN_ID failed"; RUN_ID=""; return 1; }
    goal="$(jq -r '.goal // ""' "$OV" 2>/dev/null || true)"
    jq -n --arg id "$RUN_ID" --arg ts "$(utc_now)" --arg goal "$goal" --arg base "$BASE" \
      '{run_id:$id, created_at:$ts, goal:$goal, base:$base, slices:[]}' > "$rj" 2>/dev/null \
      || { trace_warn "write $rj failed"; RUN_ID=""; return 1; }
    printf '%s' "$RUN_ID" > "$cur" 2>/dev/null || trace_warn "write $cur failed"
    log "trace: new run $RUN_ID"
  fi
  return 0
}

# Append (dedup) a slice to run.json .slices[]. jq whole-file rewrite.
run_append_slice() { # run_append_slice <slice>
  [ -n "$RUN_ID" ] || return 0
  local slice="$1" rj="$REPO/.m2herd/runs/$RUN_ID/run.json" tmp
  if [ "$DRY_RUN" -eq 1 ]; then plan "jq rewrite $rj: slices[] += \"$slice\" (dedup)"; return 0; fi
  [ -f "$rj" ] || { trace_warn "no run.json at $rj"; return 1; }
  tmp="$(mktemp)"
  jq --arg s "$slice" '.slices = (((.slices // []) + [$s]) | unique)' "$rj" > "$tmp" 2>/dev/null \
    && mv "$tmp" "$rj" || { rm -f "$tmp"; trace_warn "append slice to $rj failed"; return 1; }
}

# Write the dispatch half of the bundle: prompt.md (copy of the task file) +
# status.json (state=spawned). Same for pane and headless — runner/model differ.
trace_dispatch_write() { # trace_dispatch_write <slice> <runner:pane|headless> <model> <branch> <wt>
  [ -n "$RUN_ID" ] || return 0
  local slice="$1" runner="$2" model="$3" branch="$4" wt="$5"
  local dir="$REPO/.m2herd/runs/$RUN_ID/slices/$slice" task="$REPO/.m2herd/dispatch/$slice.task.md"
  if [ "$DRY_RUN" -eq 1 ]; then
    plan "mkdir -p $dir; cp $task -> $dir/prompt.md; write $dir/status.json (state=spawned runner=$runner${model:+ model=$model})"
    return 0
  fi
  mkdir -p "$dir" || { trace_warn "mkdir $dir failed"; return 1; }
  cp "$task" "$dir/prompt.md" 2>/dev/null || trace_warn "copy $task -> $dir/prompt.md failed"
  jq -n --arg slice "$slice" --arg agent "$AGENT" --arg runner "$runner" --arg model "$model" \
        --arg branch "$branch" --arg wt "$wt" --arg ts "$(utc_now)" \
    '{slice:$slice, state:"spawned", agent:$agent, runner:$runner, model:$model, branch:$branch,
      worktree:$wt, dispatched_at:$ts, collected_at:"", tokens:0, cost_usd:0}' \
    > "$dir/status.json" 2>/dev/null || trace_warn "write $dir/status.json failed"
}

# Find which run holds a slice at collect time: prefer CURRENT; if CURRENT is
# missing, fall back to the lexically latest run dir containing the slice.
trace_find_run_for_slice() { # trace_find_run_for_slice <slice> -> echoes run-id or empty
  local slice="$1" runs="$REPO/.m2herd/runs" cur rid
  cur="$runs/CURRENT"
  if [ -f "$cur" ]; then
    rid="$(cat "$cur" 2>/dev/null || true)"
    [ -n "$rid" ] && { printf '%s' "$rid"; return 0; }
  fi
  rid="$(ls -1 "$runs" 2>/dev/null | grep '^r-' | sort -r | while IFS= read -r d; do
    if [ -d "$runs/$d/slices/$slice" ]; then printf '%s' "$d"; break; fi
  done)"
  printf '%s' "$rid"
}

# Complete the bundle at collect time: copy report.md, flip status.json to
# done|failed, fill tokens/cost_usd when the caller has them (headless only —
# reuses the same tok/cost values already parsed for set_worker_usage, no
# duplicate parsing).
trace_collect_write() { # trace_collect_write <slice> <state:done|failed> [tokens] [cost_usd]
  local slice="$1" state="$2" tok="${3:-}" cost="${4:-}" out rid dir sj
  out="$REPO/.m2herd/dispatch/$slice.out.md"
  rid="$(trace_find_run_for_slice "$slice")"
  if [ -z "$rid" ]; then trace_warn "no run dir found for slice $slice — skipping report/status update"; return 0; fi
  dir="$REPO/.m2herd/runs/$rid/slices/$slice"; sj="$dir/status.json"
  if [ "$DRY_RUN" -eq 1 ]; then
    plan "cp $out -> $dir/report.md; update $sj (state=$state collected_at=<now>${tok:+ tokens=$tok}${cost:+ cost_usd=$cost})"
    return 0
  fi
  mkdir -p "$dir" || { trace_warn "mkdir $dir failed"; return 1; }
  cp "$out" "$dir/report.md" 2>/dev/null || trace_warn "copy $out -> $dir/report.md failed"
  if [ -f "$sj" ]; then
    local tmp; tmp="$(mktemp)"
    jq --arg st "$state" --arg ts "$(utc_now)" --arg tok "$tok" --arg cost "$cost" '
      .state = $st | .collected_at = $ts
      | .tokens    = (if $tok  != "" then ($tok  | tonumber) else .tokens    end)
      | .cost_usd  = (if $cost != "" then ($cost | tonumber) else .cost_usd  end)
    ' "$sj" > "$tmp" 2>/dev/null && mv "$tmp" "$sj" || { rm -f "$tmp"; trace_warn "update $sj failed"; }
  else
    trace_warn "no status.json at $sj — writing a fresh one"
    jq -n --arg slice "$slice" --arg st "$state" --arg ts "$(utc_now)" --arg tok "${tok:-0}" --arg cost "${cost:-0}" \
      '{slice:$slice, state:$st, collected_at:$ts, tokens:($tok|tonumber), cost_usd:($cost|tonumber)}' \
      > "$sj" 2>/dev/null || trace_warn "write $sj failed"
  fi
}

# ---------- lesson injection (evolver contract §4) -----------------------------
# When LESSONS.md has content below the M2HERD:LIVE marker, both pane and
# headless pointer messages gain one sentence naming it. The task file itself
# is never mutated.
lessons_pointer_suffix() { # -> appended sentence, or empty
  local lf="$REPO/.m2herd/evolver/LESSONS.md" marker='<!-- === M2HERD:LIVE === -->' body
  [ -f "$lf" ] || return 0
  body="$(awk -v m="$marker" 'f{print} $0==m{f=1}' "$lf" 2>/dev/null | sed '/^[[:space:]]*$/d')"
  [ -n "$body" ] || return 0
  printf ' Also read %s (accepted factory lessons) before starting.' "$lf"
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
# Machineroom pane viewer command. Prefer the engine's built-in flicker-free
# watch mode (home-cursor repaint, self-update check every 10 min); the pane is
# a WATCHER, never a writer, in every variant.
notes_viewer_cmd() {
  if command -v m2herd >/dev/null 2>&1; then
    printf '%s' 'm2herd dashboard --watch'
  elif command -v watch >/dev/null 2>&1; then
    printf '%s' 'watch -n 2 -t cat .m2herd/NOTES.md'
  else
    printf '%s' 'while :; do clear; cat .m2herd/NOTES.md; sleep 2; done'
  fi
}

up() {
  resolve_repo; resolve_self
  log "up: repo=$REPO (self pane: ${SELF:-<unknown>})"
  inside_herdr || warn_not_in_herdr

  # 1. .m2herd/ context fabric — scaffold via the engine if missing
  if [ ! -d "$REPO/.m2herd" ]; then
    # No eval: the goal is free text and must never hit a shell parser.
    local init="$SCRIPT_DIR/m2herd.sh"
    [ -x "$init" ] || init="$(command -v m2herd || true)"
    if [ "$DRY_RUN" -eq 1 ]; then
      plan "${init:-m2herd} init --dir '$REPO'${GOAL:+ --goal '<goal>'}"
    else
      [ -n "$init" ] && [ -x "$init" ] || { echo "no .m2herd/ and no m2herd engine found (scripts/m2herd.sh or on PATH) — need slice A's engine" >&2; exit 1; }
      if [ -n "$GOAL" ]; then
        "$init" init --dir "$REPO" --goal "$GOAL"
      else
        "$init" init --dir "$REPO"
      fi
    fi
  else
    log ".m2herd/ present — skipping init"
  fi

  # 2. herdr workspace for the repo — reuse the one already holding a pane cwd'd
  #    at the repo, else create (idempotency key: a pane whose cwd == repo).
  #    Probe the server FIRST: workspace/pane calls all go over the socket, and a
  #    dead server otherwise surfaces only as the cryptic "workspace create failed".
  if [ "$DRY_RUN" -eq 0 ] && ! herdr status server 2>/dev/null | grep -q '^status: running'; then
    echo "herdr server is not running — start herdr first (run \`herdr\`), then re-run m2herd-up up" >&2
    exit 1
  fi
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
  #    --room-only skips this entirely: the SESSION RUNNING THIS COMMAND is the
  #    orchestrator (the auto-kick path — a hook-nudged Claude Code session must
  #    never spawn a second orchestrator next to itself).
  local orch_name="m2herd-orch-$(basename "$REPO")" orch n
  if [ "$ROOM_ONLY" -eq 1 ]; then
    orch="(this session)"
    log "room-only: skipping orchestrator ensure — the calling session is the orchestrator"
    n=1
  else
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
  fi   # end --room-only guard

  # 4. ONE machineroom pane live-viewing NOTES.md. Idempotency key: the tab label —
  #    a labeled tab survives restarts and is observable via `herdr tab list`.
  local viewer tab notes
  viewer="$(notes_viewer_cmd)"
  tab="$(herdr tab list --workspace "$ws" 2>/dev/null | jq -r --arg l "$NOTES_TAB_LABEL" --arg o "$NOTES_TAB_LABEL_OLD" \
    '[.result.tabs[] | select((.label // "")==$l or (.label // "")==$o)] | first | .tab_id // empty' 2>/dev/null || true)"
  if [ -n "$tab" ]; then
    notes="$(herdr pane list --workspace "$ws" 2>/dev/null | jq -r --arg t "$tab" \
      '[.result.panes[] | select(.tab_id==$t)] | first | .pane_id // empty' 2>/dev/null || true)"
    log "machineroom pane exists: ${notes:-<tab $tab, pane unresolved>} (viewer assumed running)"
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
    [ -n "$notes" ] || { echo "machineroom pane never appeared in pane list" >&2; exit 1; }
    if is_self "$notes"; then
      log "! machineroom pane resolved to \$SELF ($notes) — refusing to touch it"
    else
      sleep 1   # let the fresh pane's shell come up before typing into it
      herdr pane run "$notes" "$viewer" >/dev/null 2>&1 || true
      log "machineroom pane started: $notes ($viewer)"
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

  run_ensure || true
  run_append_slice "$SLICE" || true

  # task file is the deliverable definition — the orchestrator writes it first
  if [ ! -f "$task" ]; then
    if [ "$DRY_RUN" -eq 1 ]; then log "! task file missing: $task (write it before a real dispatch)"
    else echo "no task file: $task — write the slice's task there first (file protocol)" >&2; exit 1; fi
  fi

  if [ "$HEADLESS" -eq 1 ]; then
    # verified 2026-07-02: `claude -p` works on the Max plan (usage JSON incl. costUSD);
    # codex exec / opencode run are the non-Anthropic fallbacks. cursor has no headless mode.
    case "$AGENT" in
      claude|codex|opencode) : ;;
      *) echo "--headless supports --agent claude|codex|opencode (cursor has no headless mode)" >&2; exit 2 ;;
    esac
    [ -n "$MODEL" ] || MODEL="sonnet"   # cheap hands by default; Fable stays the judge
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

  # Confinement (learned the hard way: the first live headless worker followed the
  # task file's absolute path back into the MAIN repo and committed the orchestrator's
  # uncommitted work). The task is COPIED into the worktree and the pointer names the
  # copy + an explicit "do all work here" line; only the report may leave the worktree.
  copy_task_into_wt() { # copy_task_into_wt <wt> -> echoes worktree-local task path
    local wtask="$1/TASK-m2herd-$SLICE.md" excl
    # (plan → stderr: this function's stdout is captured by the caller)
    if [ "$DRY_RUN" -eq 1 ]; then plan "cp '$task' '$wtask' (+ git-exclude it in the worktree)" >&2; else
      cp "$task" "$wtask"
      excl="$(git -C "$1" rev-parse --git-path info/exclude 2>/dev/null || true)"
      [ -n "$excl" ] && { grep -qxF "TASK-m2herd-$SLICE.md" "$excl" 2>/dev/null || echo "TASK-m2herd-$SLICE.md" >> "$excl"; }
    fi
    printf '%s' "$wtask"
  }
  confinement_line() { # confinement_line <wt> <branch>
    printf 'You are CONFINED to the worktree %s (branch %s): do ALL reads, edits, and the commit there and NOWHERE else — never follow paths into the main repo checkout.' "$1" "$2"
  }

  # 2a. HEADLESS spawn — no pane, no TUI: nohup'd one-shot in the worktree.
  #     Prompt stays a one-line pointer (file protocol); the report lands in $out
  #     by instruction, the runner's own stdout (usage JSON for claude) in $lg.
  if [ "$HEADLESS" -eq 1 ]; then
    local out="$REPO/.m2herd/dispatch/$SLICE.out.md" lg="$REPO/.m2herd/dispatch/$SLICE.log" hpid="" wtask
    wtask="$(copy_task_into_wt "$wt")"
    local hprompt="$(confinement_line "$wt" "$branch") Read $wtask and follow its instructions exactly. Write your complete report to $out when done (the report file is the ONLY thing you write outside the worktree).$(lessons_pointer_suffix)"
    if [ "$DRY_RUN" -eq 1 ]; then
      case "$AGENT" in
        claude)   plan "cd '$wt' && nohup claude -p '<pointer>' --model '$MODEL' --dangerously-skip-permissions --output-format json > '$lg' 2>&1 &" ;;
        codex)    plan "cd '$wt' && nohup codex exec --dangerously-bypass-approvals-and-sandbox '<pointer>' > '$lg' 2>&1 &" ;;
        opencode) plan "cd '$wt' && nohup opencode run '<pointer>' > '$lg' 2>&1 &" ;;
      esac
      record_worker "$SLICE" "-" "$wt" "$branch" "spawned" "headless" "$MODEL" ""
      trace_dispatch_write "$SLICE" "headless" "$MODEL" "$branch" "$wt" || true
      log "dispatch: dry-run headless plan complete for $SLICE"
      return 0
    fi
    case "$AGENT" in
      claude)   ( cd "$wt" && nohup claude -p "$hprompt" --model "$MODEL" --dangerously-skip-permissions --output-format json > "$lg" 2>&1 & echo $! > "$lg.pid" ) ;;
      codex)    ( cd "$wt" && nohup codex exec --dangerously-bypass-approvals-and-sandbox "$hprompt" > "$lg" 2>&1 & echo $! > "$lg.pid" ) ;;
      opencode) ( cd "$wt" && nohup opencode run "$hprompt" > "$lg" 2>&1 & echo $! > "$lg.pid" ) ;;
    esac
    hpid="$(cat "$lg.pid" 2>/dev/null || true)"; rm -f "$lg.pid"
    [ -n "$hpid" ] || { echo "headless spawn failed (no pid) — see $lg" >&2; exit 1; }
    record_worker "$SLICE" "-" "$wt" "$branch" "spawned" "headless" "$MODEL" "$hpid"
    trace_dispatch_write "$SLICE" "headless" "$MODEL" "$branch" "$wt" || true
    log "dispatch: done — $SLICE headless ($AGENT/$MODEL, pid $hpid), log $lg"
    return 0
  fi

  # 2b. TUI spawn — place the worker pane BESIDE the orchestrator. The orchestrator
  #     owns the LEFT 50% of its tab (NEVER touched); every worker lives in the
  #     RIGHT 50% and subdivides it: 1 worker → right 50%; 2 → top-right 25% +
  #     bottom-right 25%; each further worker halves the LAST worker pane. We drive
  #     this with `herdr pane split` — NOT `agent start --split` (stray-pane bug).
  inside_herdr || warn_not_in_herdr " …or use --headless"
  local wname="$AGENT-m2herd-$SLICE" pane runcmd="$bin${flag:+ $flag}"
  local orch_pane orch_tab last_worker split_pane split_dir
  orch_pane="$(resolve_orch_pane)"
  orch_tab=""
  [ -n "$orch_pane" ] && orch_tab="$(pane_tab_id "$orch_pane")"

  if [ -z "$orch_pane" ] || [ -z "$orch_tab" ]; then
    # FALLBACK: orchestrator pane unresolvable (up never ran, not in a workspace,
    # room-only session name mismatch, fleet unreachable) — use the ORIGINAL
    # `agent start --no-focus` path unchanged, with a log line saying why.
    log "! orchestrator pane unresolved (pane='${orch_pane:-}' tab='${orch_tab:-}') — falling back to 'agent start --no-focus'"
    if [ "$DRY_RUN" -eq 1 ]; then
      plan "herdr agent start '$wname' --cwd '$wt' --no-focus -- \"\$(command -v $bin)\" $flag"
      plan "re-resolve worker pane by cwd from 'herdr agent list' (returned pane_id can be off by one)"
      pane="PANE-DRYRUN"
    else
      herdr agent start "$wname" --cwd "$wt" --no-focus -- "$(command -v "$bin")" $flag >/dev/null 2>&1 || true
      pane="$(resolve_pane_by_cwd "$wt" "$wname")"
      [ -n "$pane" ] || { echo "worker pane never appeared in agent list (cwd $wt)" >&2; exit 1; }
      is_self "$pane" && { echo "resolved worker pane is \$SELF ($pane) — refusing" >&2; exit 1; }
      log "worker spawned (fallback): pane $pane ($wname)"
      sleep 2   # let the TUI boot before the pointer lands
    fi
  else
    # Split target: the LAST existing worker (split DOWN, halving the right column)
    # or, when there are none, the orchestrator itself (split RIGHT into 50/50).
    last_worker="$(worker_panes_in_tab "$orch_tab" "$orch_pane" | tail -1)"
    if [ -n "$last_worker" ]; then split_pane="$last_worker"; split_dir="down"
    else                           split_pane="$orch_pane";  split_dir="right"; fi
    is_self "$split_pane" && { echo "split target resolved to \$SELF ($split_pane) — refusing" >&2; exit 1; }
    local split_note="${last_worker:+last worker $last_worker}"; split_note="${split_note:-no workers yet}"
    if [ "$DRY_RUN" -eq 1 ]; then
      plan "herdr pane split '$split_pane' --direction $split_dir --ratio 0.5 --cwd '$wt' --no-focus   # orch=$orch_pane tab=$orch_tab, $split_note"
      plan "resolve NEW worker pane by cwd '$wt' from 'herdr pane list' (retry; list can lag)"
      plan "sleep 1   # let the new pane's shell come up"
      plan "herdr pane run '<new-pane>' '$runcmd'   # submits command + Enter"
      plan "re-resolve worker agent by cwd from 'herdr agent list' before record"
      pane="PANE-DRYRUN"
    else
      herdr pane split "$split_pane" --direction "$split_dir" --ratio 0.5 --cwd "$wt" --no-focus >/dev/null 2>&1 || true
      pane="$(resolve_pane_by_cwd_panes "$wt")"
      [ -n "$pane" ] || { echo "new worker pane never appeared in pane list (cwd $wt)" >&2; exit 1; }
      is_self "$pane" && { echo "resolved worker pane is \$SELF ($pane) — refusing" >&2; exit 1; }
      log "worker pane split beside orchestrator: $pane (split $split_pane --direction $split_dir @0.5)"
      sleep 1   # let the fresh pane's shell come up before we launch the worker
      herdr pane run "$pane" "$runcmd" >/dev/null 2>&1 || true
      # re-resolve the agent by cwd (agent registration can lag the pane); keep the
      # settle/submit_pointer flow below unchanged. Fall back to the split pane_id.
      local apane; apane="$(resolve_pane_by_cwd "$wt")"
      [ -n "$apane" ] && pane="$apane"
      is_self "$pane" && { echo "resolved worker pane is \$SELF ($pane) — refusing" >&2; exit 1; }
      log "worker started in pane $pane (cwd $wt)"
      sleep 2   # let the TUI boot before the pointer lands
    fi
  fi

  # 3. file-protocol dispatch: one-line pointer, settle, Enter — same confinement
  #    as headless: the worker reads the task COPY inside its own worktree.
  local wtask2; wtask2="$(copy_task_into_wt "$wt")"
  submit_pointer "$pane" "$(confinement_line "$wt" "$branch") Read $wtask2 and follow its instructions exactly.$(lessons_pointer_suffix)"

  # 4. record in overview.json workers[]
  record_worker "$SLICE" "$pane" "$wt" "$branch" "spawned"
  trace_dispatch_write "$SLICE" "pane" "" "$branch" "$wt" || true
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
    trace_collect_write "$SLICE" "done" "" ""
    log "collect: dry-run plan complete for $SLICE"
    return 0
  fi

  [ -f "$OV" ] || { echo "no overview.json at $OV" >&2; exit 1; }
  local wmode wpid
  wmode="$(jq -r --arg s "$SLICE" '[.workers[]? | select(.slice==$s)] | first | .mode // "tui"' "$OV")"

  # HEADLESS collect: wait for the pid to exit, then keep/derive the report and
  # parse usage (tokens / cost) from the runner's JSON log into workers[].
  if [ "$wmode" = "headless" ]; then
    wpid="$(jq -r --arg s "$SLICE" '[.workers[]? | select(.slice==$s)] | first | .pid // empty' "$OV")"
    local lg="$REPO/.m2herd/dispatch/$SLICE.log" waited=0 max=$((WAIT_TIMEOUT / 1000))
    if [ -n "$wpid" ]; then
      log "collect: waiting for headless $SLICE (pid $wpid, max ${max}s)"
      while kill -0 "$wpid" 2>/dev/null; do
        sleep 5; waited=$((waited + 5))
        if [ "$waited" -ge "$max" ]; then
          echo "headless worker $SLICE (pid $wpid) still running after ${max}s" >&2
          set_worker_state "$SLICE" "failed"
          trace_collect_write "$SLICE" "failed" "" "" || true
          exit 1
        fi
      done
    fi
    if [ ! -s "$out" ] && [ -s "$lg" ]; then
      # worker didn't write its report file — salvage the runner's .result text
      jq -r '.result // empty' "$lg" > "$out" 2>/dev/null || true
    fi
    [ -s "$out" ] || { echo "headless worker $SLICE produced no report ($out empty; see $lg)" >&2; set_worker_state "$SLICE" "failed"; trace_collect_write "$SLICE" "failed" "" "" || true; exit 1; }
    local tok cost
    tok="$(jq -r '[.modelUsage[]?.outputTokens] | add // empty' "$lg" 2>/dev/null || true)"
    cost="$(jq -r '[.modelUsage[]?.costUSD] | add // empty' "$lg" 2>/dev/null || true)"
    set_worker_state "$SLICE" "done"
    set_worker_usage "$SLICE" "${tok:-}" "${cost:-}"
    trace_collect_write "$SLICE" "done" "${tok:-}" "${cost:-}" || true
    log "collect: done — $SLICE headless state=done${tok:+, ${tok} out-tokens}${cost:+, \$${cost}}, report at $out"
    return 0
  fi

  pane="$(jq -r --arg s "$SLICE" '[.workers[]? | select(.slice==$s)] | first | .pane_id // empty' "$OV")"
  [ -n "$pane" ] || { echo "slice '$SLICE' not in overview.json workers[] — dispatch it first" >&2; exit 1; }
  is_self "$pane" && { echo "worker pane for $SLICE is \$SELF ($pane) — refusing" >&2; exit 1; }

  log "collect: waiting for $SLICE (pane $pane) to go idle (timeout ${WAIT_TIMEOUT}ms)"
  if ! herdr agent wait "$pane" --status idle --timeout "$WAIT_TIMEOUT" >/dev/null 2>&1; then
    echo "worker $SLICE (pane $pane) did not reach idle within ${WAIT_TIMEOUT}ms" >&2
    set_worker_state "$SLICE" "failed"
    trace_collect_write "$SLICE" "failed" "" "" || true
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
  if [ -s "$out" ]; then trace_collect_write "$SLICE" "done" "" "" || true
  else trace_collect_write "$SLICE" "failed" "" "" || true
  fi
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
