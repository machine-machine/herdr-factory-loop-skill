#!/usr/bin/env bash
# herd-loop.sh — the ICM-steered herdr reconciler.
#
# The folder (an ICM "herd-control" workspace) is DESIRED state. The herdr socket is
# OBSERVED state. This script reconciles them: it observes the fleet, spawns the workers
# a fanout stage declares, collects finished work, handles or escalates blocked workers,
# and gates stage advancement — writing everything back to disk so the whole orchestrator
# state stays reconstructible from the folder alone (ICM: "state management is the files").
#
# It does the MECHANICAL work only. Judgment (what to spec, how to fix a P1, whether to
# approve a non-routine prompt) is escalated to the orchestrator via the STATUS: line.
#
# Usage:
#   herd-loop.sh init --ws DIR --repo PATH [--base main] [--feature DIR] [--worker codex]
#   herd-loop.sh tick     [--ws DIR] [--dry-run]      # one reconciliation pass
#   herd-loop.sh run      [--ws DIR] [--interval 10] [--max-ticks 0] [--dry-run]
#   herd-loop.sh observe  [--ws DIR]                  # snapshot fleet → _fleet/
#   herd-loop.sh status   [--ws DIR]                  # human-readable rollup
#   herd-loop.sh advance  [--ws DIR]                  # move active stage → its handoff
#
# Workspace is found via --ws, $HERD_WS, or the current dir (must contain AGENT.md).
# Idempotent. Safe to re-run. Reads herd.conf + stage CONTEXT.md; never bare `herdr`.

set -euo pipefail

# ---------- arg parsing ------------------------------------------------------
CMD="${1:-help}"; shift || true
WS=""; REPO=""; BASE="main"; FEATURE=""; WORKER_DEFAULT="codex"
MODEL="GLM-5.2"; BUDGET="384000"          # context-budget layer defaults (GLM-5.2 / 384k)
INTERVAL=10; MAX_TICKS=0; DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --ws) WS="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    --base) BASE="$2"; shift 2 ;;
    --feature) FEATURE="$2"; shift 2 ;;
    --worker) WORKER_DEFAULT="$2"; shift 2 ;;
    --model) MODEL="$2"; shift 2 ;;
    --budget) BUDGET="$2"; shift 2 ;;
    --interval) INTERVAL="$2"; shift 2 ;;
    --max-ticks) MAX_TICKS="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) CMD="help"; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

# ---------- workspace resolution ---------------------------------------------
resolve_ws() {
  [ -n "$WS" ] || WS="${HERD_WS:-$PWD}"
  WS="$(cd "$WS" 2>/dev/null && pwd)" || { echo "no such workspace dir" >&2; exit 1; }
  [ -f "$WS/AGENT.md" ] || { echo "not a herd-control workspace (no AGENT.md): $WS" >&2; exit 1; }
}

conf_get() { grep -E "^$1=" "$WS/herd.conf" 2>/dev/null | head -1 | cut -d= -f2- || true; }
ctx_get()  { grep -iE "^$2:" "$1" 2>/dev/null | head -1 | sed -E 's/^[^:]+:[[:space:]]*//' || true; }
active()   { cat "$WS/_fleet/active_stage" 2>/dev/null || echo "01_spec"; }
ctx_file() { echo "$WS/stages/$(active)/CONTEXT.md"; }
log()      { printf '  %s\n' "$*"; }
do_or_echo() { if [ "$DRY_RUN" -eq 1 ]; then echo "  [dry-run] $*"; else eval "$@"; fi; }

# worker -> "binary<TAB>flag"
worker_argv() {
  case "$1" in
    codex)  printf '%s\t%s\n' "codex" "--dangerously-bypass-approvals-and-sandbox" ;;
    claude) printf '%s\t%s\n' "claude" "--dangerously-skip-permissions" ;;
    cursor) printf '%s\t%s\n' "cursor-agent" "--force" ;;
    *) printf '%s\t%s\n' "$1" "" ;;
  esac
}

# ---------- ledger (TSV: slice worker pane branch worktree status collected) --
LEDGER() { echo "$WS/_fleet/ledger.tsv"; }
ledger_init() { [ -f "$(LEDGER)" ] || printf 'slice\tworker\tpane\tbranch\tworktree\tstatus\tcollected\n' > "$(LEDGER)"; }
ledger_has()  { awk -F'\t' -v s="$1" 'NR>1 && $1==s {f=1} END{exit !f}' "$(LEDGER)"; }
ledger_get()  { awk -F'\t' -v s="$1" -v c="$2" 'NR>1 && $1==s {print $c}' "$(LEDGER)" | head -1; }
ledger_add()  { # empty fields → "-" so IFS=$'\t' read never collapses adjacent tabs
  local f=(); local a; for a in "$1" "$2" "$3" "$4" "$5" "$6" "$7"; do f+=("${a:--}"); done
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${f[@]}" >> "$(LEDGER)"; }
ledger_set()  { # ledger_set <slice> <col> <value>
  local s="$1" c="$2" v="$3" tmp; tmp="$(mktemp)"
  awk -F'\t' -v OFS='\t' -v s="$s" -v c="$c" -v v="$v" 'NR==1{print;next} {if($1==s)$c=v; print}' "$(LEDGER)" > "$tmp"
  mv "$tmp" "$(LEDGER)"
}

# ---------- observe: snapshot fleet → _fleet/ --------------------------------
observe() {
  mkdir -p "$WS/_fleet"
  herdr agent list > "$WS/_fleet/agents.json.tmp" 2>/dev/null && mv "$WS/_fleet/agents.json.tmp" "$WS/_fleet/agents.json" \
    || { echo "  ! herdr agent list failed (server up?)" >&2; return 1; }
  jq -r '.result.agents[] | select(.focused==true) | .pane_id' "$WS/_fleet/agents.json" 2>/dev/null > "$WS/_fleet/self" || true
  ledger_init
  # refresh each ledger row's status from the live snapshot, by pane id
  awk -F'\t' 'NR>1{print $1"\t"$3}' "$(LEDGER)" | while IFS=$'\t' read -r slice pane; do
    [ -n "$pane" ] || continue
    local st; st="$(jq -r --arg p "$pane" '.result.agents[]|select(.pane_id==$p)|.agent_status' "$WS/_fleet/agents.json" 2>/dev/null | head -1)"
    if [ -n "$st" ]; then ledger_set "$slice" 6 "$st"
    elif [ "$pane" != "DRYRUN" ] && [ "$pane" != "-" ]; then ledger_set "$slice" 6 "gone"; fi  # pane vanished (worker died)
  done || true
  return 0
}

is_self() { [ "$1" = "$(cat "$WS/_fleet/self" 2>/dev/null)" ]; }

# ---------- inbox / steering --------------------------------------------------
STEER_HEADER='<!--
inbox/STEER.md — live steering channel (Layer 4). Edit below the marker to steer the loop.
Commands: PAUSE | RESUME | KILL <slice> | RESCOPE <slice> | GOTO <stage> | NOTE <text>
-->

=== STEER ==='
drain_inbox() {
  local f="$WS/inbox/STEER.md"
  [ -f "$f" ] || return 0
  # everything after the marker line
  awk 'p{print} /=== STEER ===/{p=1}' "$f" | sed '/^[[:space:]]*$/d' | while read -r line; do
    # shellcheck disable=SC2086
    set -- $line; local cmd="${1:-}"; shift || true; local arg="$*"
    case "$cmd" in
      PAUSE)   touch "$WS/_fleet/paused"; log "steer: PAUSED" ;;
      RESUME)  rm -f "$WS/_fleet/paused"; log "steer: RESUMED" ;;
      GOTO)    [ -n "$arg" ] && echo "$arg" > "$WS/_fleet/active_stage" && log "steer: GOTO $arg" ;;
      KILL)    local p; p="$(ledger_get "$arg" 3)"; if [ -n "$p" ] && ! is_self "$p"; then do_or_echo "herdr pane close '$p'"; ledger_set "$arg" 6 "abandoned"; log "steer: KILLED $arg"; fi ;;
      RESCOPE) # drop the ledger row so the slice re-spawns with its (edited) prompt
               local tmp; tmp="$(mktemp)"; awk -F'\t' -v s="$arg" 'NR==1||$1!=s' "$(LEDGER)" > "$tmp"; mv "$tmp" "$(LEDGER)"; log "steer: RESCOPE $arg (will re-dispatch)" ;;
      NOTE)    log "steer NOTE (for orchestrator): $arg" ;;
      *)       log "steer (unhandled, orchestrator should read): $line" ;;
    esac
  done || true
  # reset the inbox to the empty template
  [ "$DRY_RUN" -eq 1 ] || printf '%s\n' "$STEER_HEADER" > "$f"
}

# ---------- spawn a worker for a slice ---------------------------------------
gen_prompt() {
  local stage="$1" slice="$2" wt="$3"
  local out="$WS/stages/$stage/prompts/$slice.md"
  mkdir -p "$WS/stages/$stage/prompts"
  [ -f "$out" ] && { echo "$out"; return; }
  # context-budget layer: if a budget-sized manifest exists for this slice, point the
  # worker at it (links only, sized to fit the budget) instead of the full stage inputs.
  local ctx="$WS/stages/$stage/context/$slice.md" ctxline=""
  [ -f "$ctx" ] && ctxline="  0. $ctx   (YOUR CONTEXT MANIFEST — load exactly these links, nothing more)
"
  cat > "$out" <<EOF
You are one worker in an ICM-steered herd. Scope: **$slice only** — do not touch files
outside this slice. Repo: $wt (worktree, branch wip/$stage/$slice).

Read first, in order (load only these):
$ctxline  1. $WS/AGENT.md                          (orchestrator charter — your context)
  2. $WS/stages/01_spec/output/spec.md      (WHAT + acceptance criteria)
  3. $WS/stages/02_plan/output/plan.md      (HOW — stack, structure, contracts)
  4. $WS/stages/03_tasks/output/tasks.md    (your task: the row matching $slice)

Do this slice and ONLY this slice. Do NOT edit tasks.md. When done: run the tests
relevant to your change, commit on the current branch ("$slice: <summary>"), and report
what you did and how you verified it.
EOF
  echo "$out"
}

# Send the one-line pointer + submit. Used at spawn AND as the reconcile nudge — TUIs
# accept input at different times (claude shows a welcome screen, codex loads its model),
# so we may need to (re)send the text, not just Enter. Re-sending to an idle worker is
# safe: it just reads the same prompt file again.
submit_prompt() {
  local pane="$1" pf="$2"
  [ -n "$pane" ] && [ "$pane" != "-" ] && [ "$pane" != "DRYRUN" ] || return 0
  is_self "$pane" && return 0
  herdr agent send "$pane" "Read $pf and follow its instructions exactly." >/dev/null 2>&1 || true
  herdr pane send-keys "$pane" Enter >/dev/null 2>&1 || true
}

spawn_slice() {
  local stage="$1" slice="$2" worker="$3"
  worker="${worker:-$WORKER_DEFAULT}"
  local av bin flag; av="$(worker_argv "$worker")"; bin="${av%%$'\t'*}"; flag="${av##*$'\t'}"
  if ! command -v "$bin" >/dev/null 2>&1; then
    log "! $slice: worker binary '$bin' not on PATH — marking error"; ledger_add "$slice" "$worker" "" "" "" "error" "no"; return
  fi
  local branch="wip/$stage/$slice" wt
  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] spawn $worker for $slice (branch $branch)"; ledger_add "$slice" "$worker" "DRYRUN" "$branch" "" "working" "no"; return
  fi
  wt="$(herdr worktree create --cwd "$REPO" --branch "$branch" --base "$BASE" --label "$slice" --json 2>/dev/null | jq -r '.result.worktree.path')"
  [ -n "$wt" ] && [ "$wt" != "null" ] || { log "! $slice: worktree create failed"; ledger_add "$slice" "$worker" "" "$branch" "" "error" "no"; return; }
  # herdr requires a UNIQUE agent name; the integration is detected from the binary,
  # so a "<worker>-<slice>" label coexists with other workers of the same type.
  local pane; pane="$(herdr agent start "$worker-$slice" --cwd "$wt" --no-focus -- "$(command -v "$bin")" $flag 2>/dev/null | jq -r '.result.agent.pane_id')"
  [ -n "$pane" ] && [ "$pane" != "null" ] || { log "! $slice: agent start failed"; ledger_add "$slice" "$worker" "" "$branch" "$wt" "error" "no"; return; }
  local prompt; prompt="$(gen_prompt "$stage" "$slice" "$wt")"
  ledger_add "$slice" "$worker" "$pane" "$branch" "$wt" "working" "no"
  log "spawned $worker → $slice (pane $pane, $wt)"
  # file protocol: NEVER stream a multi-line prompt into a TUI (newlines submit early).
  # The prompt lives on disk; send a one-line pointer. Settle first, then submit. If the
  # TUI wasn't ready and the text was dropped, the reconcile nudge re-sends it next tick.
  sleep 2
  submit_prompt "$pane" "$prompt"
}

# ---------- handle a blocked worker (approve or escalate) --------------------
handle_blocked() {
  local stage="$1" slice="$2" pane="$3"
  is_self "$pane" && return 0
  local screen; screen="$(herdr agent read "$pane" --source visible 2>/dev/null || true)"
  local allow="$WS/_config/approve_allow.txt" deny="$WS/_config/approve_deny.txt"
  if [ -f "$deny" ] && printf '%s' "$screen" | grep -qiE -f <(grep -vE '^\s*#|^\s*$' "$deny"); then
    escalate "$stage" "$slice" "$screen"; return
  fi
  if [ -f "$allow" ] && printf '%s' "$screen" | grep -qiE -f <(grep -vE '^\s*#|^\s*$' "$allow"); then
    do_or_echo "herdr pane send-keys '$pane' Enter"; log "auto-approved $slice (routine)"; return
  fi
  escalate "$stage" "$slice" "$screen"
}
escalate() {
  local stage="$1" slice="$2" screen="$3" rev="$WS/stages/$1/review/$2.md"
  mkdir -p "$WS/stages/$stage/review"
  { echo "# review needed: $slice (stage $stage)"; echo; echo '```'; printf '%s\n' "$screen"; echo '```'; } > "$rev"
  log "ESCALATED $slice → $rev"
  echo escalated > "$WS/_fleet/.needs_review"
}

# a fanout worker is "done" when it has committed on its branch — NOT merely when the
# TUI is idle (a TUI agent is idle while waiting for input too). Commits beyond base = work.
worker_done() {
  local wt="$1"
  [ -n "$wt" ] && [ "$wt" != "-" ] && [ -d "$wt" ] || return 1
  local n; n="$(git -C "$wt" rev-list --count "$BASE"..HEAD 2>/dev/null || echo 0)"
  [ "${n:-0}" -gt 0 ]
}

# ---------- collect a finished worker ----------------------------------------
collect_slice() {
  local stage="$1" slice="$2" pane="$3"
  local out="$WS/stages/$stage/output/$slice.out"
  # `herdr ... read` prints the raw JSON socket envelope — extract the text payload.
  herdr agent read "$pane" --source recent-unwrapped --lines 300 2>/dev/null \
    | jq -r '.result.read.text // empty' > "$out" 2>/dev/null || true
  [ -s "$out" ] || herdr agent read "$pane" --source recent-unwrapped --lines 300 > "$out" 2>/dev/null || true
  ledger_set "$slice" 7 "yes"
  log "collected $slice → stages/$stage/output/$slice.out"
}

# ---------- tick: one reconciliation pass ------------------------------------
tick() {
  resolve_ws
  REPO="$(conf_get REPO)"; BASE="$(conf_get BASE)"; BASE="${BASE:-main}"
  WORKER_DEFAULT="$(conf_get WORKER_DEFAULT)"; WORKER_DEFAULT="${WORKER_DEFAULT:-codex}"
  rm -f "$WS/_fleet/.needs_review"
  observe || { echo "STATUS: ERROR (cannot observe fleet)"; return 1; }
  drain_inbox
  if [ -f "$WS/_fleet/paused" ]; then echo "STATUS: PAUSED"; return 0; fi

  local stage ctx mode gate deliverable
  stage="$(active)"; ctx="$(ctx_file)"
  [ -f "$ctx" ] || { echo "STATUS: ERROR (no contract for stage $stage)"; return 1; }
  mode="$(ctx_get "$ctx" mode)"; gate="$(ctx_get "$ctx" gate)"; deliverable="$(ctx_get "$ctx" deliverable)"
  log "stage $stage (mode=${mode:-solo}, gate=${gate:-review})"

  local complete=0
  if [ "$mode" = "fanout" ]; then
    local slices="$WS/stages/$stage/slices.tsv"
    if [ ! -f "$slices" ]; then echo "STATUS: AWAITING_SOLO (fanout stage has no slices.tsv yet)"; return 0; fi
    # desired → spawn missing
    grep -vE '^\s*#|^\s*$' "$slices" | while IFS=$'\t' read -r slice worker _; do
      [ -n "$slice" ] || continue
      ledger_has "$slice" || spawn_slice "$stage" "$slice" "${worker:-}"
    done || true
    observe   # refresh statuses for the just-spawned + existing
    # react to each ledger row
    while IFS=$'\t' read -r slice worker pane branch wt status collected; do
      case "$status" in
        blocked) handle_blocked "$stage" "$slice" "$pane" ;;
        idle|done)
          if [ "$collected" = "yes" ]; then :
          elif worker_done "$wt"; then collect_slice "$stage" "$slice" "$pane"
          elif [ "$DRY_RUN" -eq 0 ]; then
            # idle + no commit yet = the prompt was dropped (TUI not ready at spawn) or is
            # sitting unsubmitted. Re-send the pointer + Enter. Self-heals the spawn race
            # regardless of which TUI and how slow it was to accept input.
            submit_prompt "$pane" "$WS/stages/$stage/prompts/$slice.md"; log "nudged $slice (resend prompt)"
          fi ;;
        gone)    # pane vanished. If it committed before dying, salvage it; else escalate.
                 if [ "$collected" != "yes" ] && worker_done "$wt"; then collect_slice "$stage" "$slice" "$pane"
                 elif [ "$collected" != "yes" ]; then
                   { echo "# $slice: worker pane died before committing — re-dispatch (KILL then RESCOPE) or investigate"; } > "$WS/stages/$stage/review/$slice.md" 2>/dev/null || true
                   echo errored > "$WS/_fleet/.needs_review"; log "GONE slice $slice → review"
                 fi ;;
        error)   { echo "# error: $slice failed to spawn/run — see ledger"; } > "$WS/stages/$stage/review/$slice.md" 2>/dev/null || true
                 echo errored > "$WS/_fleet/.needs_review"; log "ERROR slice $slice → review" ;;
        abandoned) : ;;  # deliberately killed; terminal, not blocking completeness
      esac
    done < <(awk -F'\t' 'NR>1' "$(LEDGER)")
    # complete when every desired slice is collected (or terminal)
    complete=1
    while IFS=$'\t' read -r slice worker _; do
      [ -n "$slice" ] || continue
      local c; c="$(ledger_get "$slice" 7)"; local s; s="$(ledger_get "$slice" 6)"
      [ "$c" = "yes" ] || [ "$s" = "abandoned" ] || [ "$s" = "error" ] || complete=0
    done < <(grep -vE '^\s*#|^\s*$' "$slices")
    if [ -f "$WS/_fleet/.needs_review" ]; then echo "STATUS: NEEDS_REVIEW"; return 0; fi
    [ "$complete" -eq 1 ] || { echo "STATUS: RECONCILED"; return 0; }
  else
    # solo stage: the orchestrator runs the Process; we just check the deliverable exists
    local dpath="$WS/stages/$stage/${deliverable%/}"
    if [ -n "$deliverable" ] && [ -f "$dpath" ]; then complete=1
    elif [ -n "$deliverable" ] && [ -d "$dpath" ] && [ -n "$(find "$dpath" -type f ! -name '.gitkeep' 2>/dev/null | head -1)" ]; then complete=1
    else echo "STATUS: AWAITING_SOLO (produce $deliverable, then tick)"; return 0; fi
  fi

  # gate
  if [ "$complete" -eq 1 ]; then
    if [ "$gate" = "auto" ]; then
      advance && { echo "STATUS: ADVANCED → $(active)"; return 0; }
    fi
    herdr notification show "herd: $stage complete" --body "review $WS/stages/$stage/output then advance" >/dev/null 2>&1 || true
    echo "STATUS: STAGE_COMPLETE"
  fi
}

# ---------- advance: active stage → its handoff ------------------------------
advance() {
  resolve_ws
  local stage ctx handoff; stage="$(active)"; ctx="$WS/stages/$stage/CONTEXT.md"
  handoff="$(ctx_get "$ctx" handoff)"
  if [ -z "$handoff" ] || [ "$handoff" = "DONE" ]; then echo "DONE" > "$WS/_fleet/active_stage"; echo "STATUS: DONE"; return 0; fi
  echo "$handoff" > "$WS/_fleet/active_stage"; log "advanced $stage → $handoff"
}

# ---------- run: standing loop -----------------------------------------------
run() {
  resolve_ws
  local n=0
  while true; do
    local out; out="$(tick || true)"; printf '%s\n' "$out"
    local st="${out##*STATUS: }"
    case "$st" in
      DONE|NEEDS_REVIEW|AWAITING_SOLO|STAGE_COMPLETE|PAUSED|ERROR*) log "loop yields on: $st"; break ;;
    esac
    n=$((n+1)); [ "$MAX_TICKS" -gt 0 ] && [ "$n" -ge "$MAX_TICKS" ] && { log "max-ticks reached"; break; }
    sleep "$INTERVAL"
  done
}

# ---------- init: scaffold a workspace from the template ---------------------
init() {
  [ -n "$WS" ] || { echo "init needs --ws DIR" >&2; exit 2; }
  [ -n "$REPO" ] || { echo "init needs --repo PATH" >&2; exit 2; }
  local tmpl; tmpl="$(cd "$(dirname "$0")/../templates/herd-control" && pwd)"
  mkdir -p "$WS"; cp -R "$tmpl/." "$WS/"
  WS="$(cd "$WS" && pwd)"
  cat > "$WS/herd.conf" <<EOF
# herd-control runtime config — written by herd-loop.sh init
REPO=$REPO
BASE=$BASE
FEATURE=$FEATURE
WORKER_DEFAULT=$WORKER_DEFAULT
# context-budget layer (see _config/budget_policy.md, scripts/context-budget.sh)
MODEL=$MODEL
BUDGET=$BUDGET
EOF
  echo "01_spec" > "$WS/_fleet/active_stage"
  ledger_init
  echo "initialized herd-control workspace at $WS (repo=$REPO base=$BASE)"
  echo "next: produce stages/01_spec/output/spec.md, then: herd-loop.sh tick --ws $WS"
}

# ---------- status -----------------------------------------------------------
status() {
  resolve_ws; observe >/dev/null 2>&1 || true
  echo "workspace: $WS"
  echo "active stage: $(active)"
  [ -f "$WS/_fleet/paused" ] && echo "PAUSED"
  echo "ledger:"; column -t -s$'\t' "$(LEDGER)" 2>/dev/null || cat "$(LEDGER)" 2>/dev/null || echo "  (empty)"
}

# ---------- dispatch ---------------------------------------------------------
case "$CMD" in
  init)    init ;;
  observe) resolve_ws; observe; echo "observed → $WS/_fleet/agents.json" ;;
  tick)    tick ;;
  run)     run ;;
  advance) advance ;;
  status)  status ;;
  help|*)  sed -n '2,33p' "$0" ;;
esac
