#!/usr/bin/env bash
# fleet-loop.sh — the meta-orchestrator reconciler (tier 0).
#
# Same ICM idea as herd-loop.sh, one level up. herd-loop.sh reconciles WORKERS for one
# feature; fleet-loop.sh reconciles ORCHESTRATORS for a whole portfolio of missions:
#
#     fleet-loop.sh (meta)  →  herd-loop.sh (orchestrator)  →  workers (codex/claude/cursor)
#
# A `fleet-control/` workspace is DESIRED state (a set of MISSIONS in missions.tsv). The
# herdr socket + each orchestrator's own herd-control `_fleet/active_stage` are OBSERVED
# state. Each tick this script: launches an orchestrator per missing mission (in its repo,
# scaffolds its herd-control workspace, arms its `/goal` so it self-drives via its Stop
# hook), refreshes mission status from the fleet + each orchestrator's DONE marker, handles
# or escalates blocked orchestrators, collects finished missions' run reports, and gates.
#
# It does MECHANICAL work only. Judgment (whether a cross-mission conflict is acceptable,
# whether to approve a non-routine orchestrator escalation) is escalated to the
# meta-orchestrator (you / Hermes) via the STATUS: line.
#
# Usage:
#   fleet-loop.sh init    --ws DIR [--worker claude]      # scaffold a fleet-control workspace
#   fleet-loop.sh tick    [--ws DIR] [--dry-run]          # one reconciliation pass
#   fleet-loop.sh run     [--ws DIR] [--interval 20] [--max-ticks 0] [--dry-run]
#   fleet-loop.sh observe [--ws DIR]                      # snapshot fleet + mission statuses
#   fleet-loop.sh status  [--ws DIR]                      # human-readable rollup
#   fleet-loop.sh advance [--ws DIR]                      # active stage → its handoff
#
# Workspace is found via --ws, $FLEET_WS, or the current dir (must contain FLEET.md).
# Idempotent. Safe to re-run. Reads fleet.conf + stage CONTEXT.md + missions.tsv. Never bare `herdr`.

set -euo pipefail

# ---------- arg parsing ------------------------------------------------------
CMD="${1:-help}"; shift || true
WS=""; ORCH_DEFAULT="claude"; INTERVAL=20; MAX_TICKS=0; DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --ws) WS="$2"; shift 2 ;;
    --worker|--orchestrator) ORCH_DEFAULT="$2"; shift 2 ;;
    --interval) INTERVAL="$2"; shift 2 ;;
    --max-ticks) MAX_TICKS="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) CMD="help"; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

HERE="$(cd "$(dirname "$0")" && pwd)"
HERD_LOOP="$HERE/herd-loop.sh"

# ---------- workspace resolution ---------------------------------------------
resolve_ws() {
  [ -n "$WS" ] || WS="${FLEET_WS:-$PWD}"
  WS="$(cd "$WS" 2>/dev/null && pwd)" || { echo "no such workspace dir" >&2; exit 1; }
  [ -f "$WS/FLEET.md" ] || { echo "not a fleet-control workspace (no FLEET.md): $WS" >&2; exit 1; }
}

conf_get() { grep -E "^$1=" "$WS/fleet.conf" 2>/dev/null | head -1 | cut -d= -f2- || true; }
ctx_get()  { grep -iE "^$2:" "$1" 2>/dev/null | head -1 | sed -E 's/^[^:]+:[[:space:]]*//' || true; }
active()   { cat "$WS/_fleet/active_stage" 2>/dev/null || echo "01_dispatch"; }
ctx_file() { echo "$WS/stages/$(active)/CONTEXT.md"; }
log()      { printf '  %s\n' "$*"; }
do_or_echo() { if [ "$DRY_RUN" -eq 1 ]; then echo "  [dry-run] $*"; else eval "$@"; fi; }

# orchestrator/worker -> "binary<TAB>flag" (same matrix herd-loop.sh uses)
agent_argv() {
  case "$1" in
    codex)  printf '%s\t%s\n' "codex" "--dangerously-bypass-approvals-and-sandbox" ;;
    claude) printf '%s\t%s\n' "claude" "--dangerously-skip-permissions" ;;
    cursor) printf '%s\t%s\n' "cursor-agent" "--force" ;;
    *) printf '%s\t%s\n' "$1" "" ;;
  esac
}

# Per-agent `/goal` capability. `/goal <condition>` arms a session Stop hook that blocks
# the agent from stopping until the condition holds — the autonomy primitive that lets an
# orchestrator self-drive without the meta babysitting it. Agents WITHOUT goal support
# degrade gracefully: the meta re-nudges them each tick instead (see reconcile loop).
# Override per-fleet in _config/goal_support.txt ("<agent> <yes|no>" lines).
goal_supported() {
  local a="$1" f="$WS/_config/goal_support.txt"
  if [ -f "$f" ]; then
    local v; v="$(grep -iE "^$a[[:space:]]" "$f" 2>/dev/null | head -1 | awk '{print $2}')"
    [ -n "$v" ] && { [ "$v" = yes ] && return 0 || return 1; }
  fi
  case "$a" in claude|codex) return 0 ;; *) return 1 ;; esac
}

# ---------- mission ledger (TSV) ---------------------------------------------
# mission  orchestrator  pane  repo  herd_ws  goal_armed  status  collected
LEDGER() { echo "$WS/_fleet/missions.ledger.tsv"; }
ledger_init() { [ -f "$(LEDGER)" ] || printf 'mission\torchestrator\tpane\trepo\therd_ws\tgoal_armed\tstatus\tcollected\n' > "$(LEDGER)"; }
ledger_has()  { awk -F'\t' -v s="$1" 'NR>1 && $1==s {f=1} END{exit !f}' "$(LEDGER)"; }
ledger_get()  { awk -F'\t' -v s="$1" -v c="$2" 'NR>1 && $1==s {print $c}' "$(LEDGER)" | head -1; }
ledger_add()  { local f=(); local a; for a in "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8"; do f+=("${a:--}"); done
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${f[@]}" >> "$(LEDGER)"; }
ledger_set()  { local s="$1" c="$2" v="$3" tmp; tmp="$(mktemp)"
  awk -F'\t' -v OFS='\t' -v s="$s" -v c="$c" -v v="$v" 'NR==1{print;next} {if($1==s)$c=v; print}' "$(LEDGER)" > "$tmp"; mv "$tmp" "$(LEDGER)"; }

# ---------- observe: snapshot fleet + each mission's true status --------------
observe() {
  mkdir -p "$WS/_fleet"
  herdr agent list > "$WS/_fleet/agents.json.tmp" 2>/dev/null && mv "$WS/_fleet/agents.json.tmp" "$WS/_fleet/agents.json" \
    || { echo "  ! herdr agent list failed (server up?)" >&2; return 1; }
  jq -r '.result.agents[] | select(.focused==true) | .pane_id' "$WS/_fleet/agents.json" 2>/dev/null > "$WS/_fleet/self" || true
  ledger_init
  # refresh each mission's status from (a) the orchestrator pane's lifecycle and
  # (b) its herd-control DONE marker — the cross-tier completion signal.
  awk -F'\t' 'NR>1{print $1"\t"$3"\t"$5}' "$(LEDGER)" | while IFS=$'\t' read -r mission pane herd_ws; do
    [ -n "$mission" ] || continue
    local life="" hstage=""
    if [ -n "$pane" ] && [ "$pane" != "-" ] && [ "$pane" != "DRYRUN" ]; then
      life="$(jq -r --arg p "$pane" '.result.agents[]|select(.pane_id==$p)|.agent_status' "$WS/_fleet/agents.json" 2>/dev/null | head -1)"
      [ -n "$life" ] || life="gone"   # orchestrator pane vanished
    fi
    [ -n "$herd_ws" ] && [ "$herd_ws" != "-" ] && hstage="$(cat "$herd_ws/_fleet/active_stage" 2>/dev/null || true)"
    # mission is "done" when its herd-loop reached DONE; otherwise mirror the orchestrator life state.
    if [ "$hstage" = "DONE" ]; then ledger_set "$mission" 7 "done"
    elif [ -n "$life" ]; then ledger_set "$mission" 7 "$life"; fi
  done || true
  return 0
}

is_self() { [ "$1" = "$(cat "$WS/_fleet/self" 2>/dev/null)" ]; }

# Send literal text to a TUI pane, then submit. A TUI (claude/codex) needs a beat to
# render injected text into its input box; if the Enter races the text it submits an
# empty line and the typed prompt is left sitting in the input, unsubmitted. Settle
# between the two. Override the delay with SUBMIT_SETTLE (seconds) in fleet.conf for
# slow machines. The reconcile/continue nudge re-sends next tick if it still didn't take.
SUBMIT_SETTLE="${SUBMIT_SETTLE:-1}"
submit_pane() {
  local pane="$1" text="$2"
  [ -n "$pane" ] && [ "$pane" != "-" ] && [ "$pane" != "DRYRUN" ] || return 0
  is_self "$pane" && return 0
  herdr agent send "$pane" "$text" >/dev/null 2>&1 || true
  sleep "$SUBMIT_SETTLE"
  herdr pane send-keys "$pane" Enter >/dev/null 2>&1 || true
}

# ---------- inbox / steering (same vocabulary as herd-loop.sh) ----------------
STEER_HEADER='<!--
inbox/STEER.md — live steering channel (Layer 4). Edit below the marker to steer the meta-loop.
Commands: PAUSE | RESUME | KILL <mission> | RESCOPE <mission> | GOTO <stage> | NOTE <text>
-->

=== STEER ==='
drain_inbox() {
  local f="$WS/inbox/STEER.md"; [ -f "$f" ] || return 0
  awk 'p{print} /=== STEER ===/{p=1}' "$f" | sed '/^[[:space:]]*$/d' | while read -r line; do
    # shellcheck disable=SC2086
    set -- $line; local cmd="${1:-}"; shift || true; local arg="$*"
    case "$cmd" in
      PAUSE)   touch "$WS/_fleet/paused"; log "steer: PAUSED" ;;
      RESUME)  rm -f "$WS/_fleet/paused"; log "steer: RESUMED" ;;
      GOTO)    [ -n "$arg" ] && echo "$arg" > "$WS/_fleet/active_stage" && log "steer: GOTO $arg" ;;
      KILL)    local p; p="$(ledger_get "$arg" 3)"; if [ -n "$p" ] && ! is_self "$p"; then do_or_echo "herdr pane close '$p'"; ledger_set "$arg" 7 "abandoned"; log "steer: KILLED mission $arg"; fi ;;
      RESCOPE) local tmp; tmp="$(mktemp)"; awk -F'\t' -v s="$arg" 'NR==1||$1!=s' "$(LEDGER)" > "$tmp"; mv "$tmp" "$(LEDGER)"; log "steer: RESCOPE $arg (will re-launch with edited goal)" ;;
      NOTE)    log "steer NOTE (for meta-orchestrator): $arg" ;;
      *)       log "steer (unhandled, meta should read): $line" ;;
    esac
  done || true
  [ "$DRY_RUN" -eq 1 ] || printf '%s\n' "$STEER_HEADER" > "$f"
}

# ---------- launch an orchestrator for a mission -----------------------------
gen_brief() { # writes goals/<mission>.md (the orchestrator's charter+goal) if absent; echoes its path
  local mission="$1" repo="$2" herd_ws="$3" intent="$4" done_when="$5"
  local out="$WS/goals/$mission.md"; mkdir -p "$WS/goals"
  [ -f "$out" ] && { echo "$out"; return; }
  cat > "$out" <<EOF
# Mission: $mission

You are an **orchestrator** in a meta-orchestrated fleet. You drive WORKERS (not the
meta). Your herd-control workspace: $herd_ws  ·  repo: $repo

## Intent
$intent

## Done when
$done_when

## How to run
1. If $herd_ws is not yet initialized: \`$HERD_LOOP init --ws $herd_ws --repo $repo\`.
2. Produce stages/01_spec/output/spec.md from the Intent above (or run /speckit.specify).
3. Drive the loop: \`$HERD_LOOP run --ws $herd_ws\`. React to each STATUS: line per your
   AGENT.md charter (AWAITING_SOLO → run the stage Process; NEEDS_REVIEW → decide; etc.).
4. You own this mission end-to-end. Report back (write a run report under ~/.herdr/runs/)
   and let your goal clear when "Done when" holds. Do NOT touch other missions' worktrees.
EOF
  echo "$out"
}

# arm the orchestrator's /goal so it self-drives via its Stop hook (the meta then only
# re-engages on block / done). No-op for agents without goal support — they get re-nudged.
arm_goal() {
  local pane="$1" cond="$2" agent="$3"
  [ -n "$pane" ] && [ "$pane" != "-" ] && [ "$pane" != "DRYRUN" ] || return 0
  is_self "$pane" && return 0
  if goal_supported "$agent"; then
    submit_pane "$pane" "/goal $cond"
    return 0
  fi
  return 1
}

bootstrap_orchestrator() {
  local pane="$1" brief="$2"
  [ -n "$pane" ] && [ "$pane" != "-" ] && [ "$pane" != "DRYRUN" ] || return 0
  is_self "$pane" && return 0
  submit_pane "$pane" "Read $brief and follow it exactly. You are the orchestrator for this mission."
}

launch_mission() {
  local mission="$1" orch="$2" repo="$3" intent="$4" done_when="$5"
  orch="${orch:-$ORCH_DEFAULT}"
  local av bin flag; av="$(agent_argv "$orch")"; bin="${av%%$'\t'*}"; flag="${av##*$'\t'}"
  if ! command -v "$bin" >/dev/null 2>&1; then
    log "! $mission: orchestrator binary '$bin' not on PATH — marking error"; ledger_add "$mission" "$orch" "" "$repo" "" "no" "error" "no"; return
  fi
  local herd_ws="$HOME/.herdr/fleet/$(basename "$WS")/$mission"
  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] launch $orch for mission '$mission' (repo $repo, herd_ws $herd_ws); arm /goal=$(goal_supported "$orch" && echo yes || echo no)"
    ledger_add "$mission" "$orch" "DRYRUN" "$repo" "$herd_ws" "$(goal_supported "$orch" && echo yes || echo no)" "working" "no"; return
  fi
  # launch the orchestrator agent in its repo (NOT a worktree — the orchestrator itself
  # creates per-worker worktrees via its herd-loop). Unique herdr name per mission.
  local pane; pane="$(herdr agent start "$orch-orch-$mission" --cwd "$repo" --no-focus -- "$(command -v "$bin")" $flag 2>/dev/null | jq -r '.result.agent.pane_id')"
  [ -n "$pane" ] && [ "$pane" != "null" ] || { log "! $mission: orchestrator start failed"; ledger_add "$mission" "$orch" "" "$repo" "$herd_ws" "no" "error" "no"; return; }
  local brief; brief="$(gen_brief "$mission" "$repo" "$herd_ws" "$intent" "$done_when")"
  ledger_add "$mission" "$orch" "$pane" "$repo" "$herd_ws" "no" "working" "no"
  log "launched $orch → mission '$mission' (pane $pane, herd_ws $herd_ws)"
  sleep 2
  bootstrap_orchestrator "$pane" "$brief"
  if arm_goal "$pane" "$done_when" "$orch"; then ledger_set "$mission" 6 "yes"; log "armed /goal on $mission"
  else log "no /goal for $orch — will re-nudge $mission each tick"; fi
}

# ---------- handle a blocked orchestrator (approve or escalate) ---------------
handle_blocked() {
  local mission="$1" pane="$2"
  is_self "$pane" && return 0
  local screen; screen="$(herdr agent read "$pane" --source visible 2>/dev/null || true)"
  local allow="$WS/_config/approve_allow.txt" deny="$WS/_config/approve_deny.txt"
  if [ -f "$deny" ] && printf '%s' "$screen" | grep -qiE -f <(grep -vE '^\s*#|^\s*$' "$deny"); then escalate "$mission" "$screen"; return; fi
  if [ -f "$allow" ] && printf '%s' "$screen" | grep -qiE -f <(grep -vE '^\s*#|^\s*$' "$allow"); then
    do_or_echo "herdr pane send-keys '$pane' Enter"; log "auto-approved $mission (routine)"; return; fi
  escalate "$mission" "$screen"
}
escalate() {
  local mission="$1" screen="$2" rev="$WS/stages/$(active)/review/$mission.md"
  mkdir -p "$WS/stages/$(active)/review"
  { echo "# review needed: mission $mission"; echo; echo '```'; printf '%s\n' "$screen"; echo '```'; } > "$rev"
  log "ESCALATED mission $mission → $rev"; echo escalated > "$WS/_fleet/.needs_review"
}

# re-nudge an orchestrator that has no /goal (or whose goal was dropped) and is idle
nudge_orchestrator() {
  local mission="$1" pane="$2" herd_ws="$3"
  [ -n "$pane" ] && [ "$pane" != "-" ] && [ "$pane" != "DRYRUN" ] || return 0
  is_self "$pane" && return 0
  submit_pane "$pane" "Continue your mission: drive $HERD_LOOP run --ws $herd_ws until your 'Done when' holds. Read goals/$mission.md if you've lost context."
}

collect_mission() {
  local mission="$1" herd_ws="$2"
  local out="$WS/stages/$(active)/output/$mission.md"; mkdir -p "$WS/stages/$(active)/output"
  { echo "# mission $mission — collected $(active)"; echo;
    echo "herd_ws: $herd_ws"; echo "herd active_stage: $(cat "$herd_ws/_fleet/active_stage" 2>/dev/null || echo '?')"; echo;
    echo "## ledger"; column -t -s$'\t' "$herd_ws/_fleet/ledger.tsv" 2>/dev/null || cat "$herd_ws/_fleet/ledger.tsv" 2>/dev/null || echo "(none)";
  } > "$out" 2>/dev/null || true
  ledger_set "$mission" 8 "yes"; log "collected mission $mission → stages/$(active)/output/$mission.md"
}

# ---------- tick -------------------------------------------------------------
tick() {
  resolve_ws
  ORCH_DEFAULT="$(conf_get ORCH_DEFAULT)"; ORCH_DEFAULT="${ORCH_DEFAULT:-claude}"
  rm -f "$WS/_fleet/.needs_review"
  observe || { echo "STATUS: ERROR (cannot observe fleet)"; return 1; }
  drain_inbox
  if [ -f "$WS/_fleet/paused" ]; then echo "STATUS: PAUSED"; return 0; fi

  local stage ctx mode gate; stage="$(active)"; ctx="$(ctx_file)"
  [ -f "$ctx" ] || { echo "STATUS: ERROR (no contract for stage $stage)"; return 1; }
  mode="$(ctx_get "$ctx" mode)"; gate="$(ctx_get "$ctx" gate)"
  log "stage $stage (mode=${mode:-solo}, gate=${gate:-review})"

  local complete=0
  if [ "$mode" = "fanout" ]; then
    local missions="$WS/missions.tsv"
    [ -f "$missions" ] || { echo "STATUS: AWAITING_SOLO (no missions.tsv yet)"; return 0; }
    # desired → launch missing.  cols: mission  orchestrator  repo  intent  done_when
    grep -vE '^\s*#|^\s*$' "$missions" | while IFS=$'\t' read -r mission orch repo intent done_when; do
      [ -n "$mission" ] || continue
      ledger_has "$mission" || launch_mission "$mission" "${orch:-}" "$repo" "$intent" "$done_when"
    done || true
    observe
    # react to each mission row
    while IFS=$'\t' read -r mission orch pane repo herd_ws goal status collected; do
      [ -n "$mission" ] || continue
      case "$status" in
        blocked) handle_blocked "$mission" "$pane" ;;
        done)    [ "$collected" = "yes" ] || collect_mission "$mission" "$herd_ws" ;;
        idle)    # orchestrator idle but herd not DONE: re-arm goal or nudge it onward
                 if [ "$goal" = "yes" ]; then
                   local dw; dw="$(awk -F'\t' -v m="$mission" '$1==m{print $5}' "$missions" | head -1)"
                   arm_goal "$pane" "$dw" "$orch" || true
                 else nudge_orchestrator "$mission" "$pane" "$herd_ws"; fi ;;
        gone)    if [ "$collected" != "yes" ]; then
                   { echo "# mission $mission: orchestrator pane died — re-launch (KILL then RESCOPE) or investigate"; } > "$WS/stages/$stage/review/$mission.md" 2>/dev/null || true
                   echo errored > "$WS/_fleet/.needs_review"; log "GONE mission $mission → review"; fi ;;
        error)   { echo "# error: mission $mission failed to launch — see ledger"; } > "$WS/stages/$stage/review/$mission.md" 2>/dev/null || true
                 echo errored > "$WS/_fleet/.needs_review"; log "ERROR mission $mission → review" ;;
        abandoned) : ;;
      esac
    done < <(awk -F'\t' 'NR>1' "$(LEDGER)")
    # complete when every desired mission is collected (or terminal)
    complete=1
    while IFS=$'\t' read -r mission _; do
      [ -n "$mission" ] || continue
      local c s; c="$(ledger_get "$mission" 8)"; s="$(ledger_get "$mission" 7)"
      [ "$c" = "yes" ] || [ "$s" = "abandoned" ] || [ "$s" = "error" ] || complete=0
    done < <(grep -vE '^\s*#|^\s*$' "$missions")
    if [ -f "$WS/_fleet/.needs_review" ]; then echo "STATUS: NEEDS_REVIEW"; return 0; fi
    [ "$complete" -eq 1 ] || { echo "STATUS: RECONCILED"; return 0; }
  else
    # solo stage (e.g. 02_converge): the meta runs the Process; we check the deliverable
    local deliverable; deliverable="$(ctx_get "$ctx" deliverable)"
    local dpath="$WS/stages/$stage/${deliverable%/}"
    if [ -n "$deliverable" ] && [ -f "$dpath" ]; then complete=1
    elif [ -n "$deliverable" ] && [ -d "$dpath" ] && [ -n "$(find "$dpath" -type f ! -name '.gitkeep' 2>/dev/null | head -1)" ]; then complete=1
    else echo "STATUS: AWAITING_SOLO (produce $deliverable, then tick)"; return 0; fi
  fi

  if [ "$complete" -eq 1 ]; then
    if [ "$gate" = "auto" ]; then advance && { echo "STATUS: ADVANCED → $(active)"; return 0; }; fi
    herdr notification show "fleet: $stage complete" --body "review $WS/stages/$stage/output then advance" >/dev/null 2>&1 || true
    echo "STATUS: MISSION_COMPLETE"
  fi
}

advance() {
  resolve_ws
  local stage ctx handoff; stage="$(active)"; ctx="$WS/stages/$stage/CONTEXT.md"
  handoff="$(ctx_get "$ctx" handoff)"
  if [ -z "$handoff" ] || [ "$handoff" = "DONE" ]; then echo "DONE" > "$WS/_fleet/active_stage"; echo "STATUS: DONE"; return 0; fi
  echo "$handoff" > "$WS/_fleet/active_stage"; log "advanced $stage → $handoff"
}

run() {
  resolve_ws; local n=0
  while true; do
    local out; out="$(tick || true)"; printf '%s\n' "$out"
    local st="${out##*STATUS: }"
    case "$st" in
      DONE|NEEDS_REVIEW|AWAITING_SOLO|MISSION_COMPLETE|PAUSED|ERROR*) log "loop yields on: $st"; break ;;
    esac
    n=$((n+1)); [ "$MAX_TICKS" -gt 0 ] && [ "$n" -ge "$MAX_TICKS" ] && { log "max-ticks reached"; break; }
    sleep "$INTERVAL"
  done
}

init() {
  [ -n "$WS" ] || { echo "init needs --ws DIR" >&2; exit 2; }
  local tmpl; tmpl="$(cd "$HERE/../templates/fleet-control" && pwd)"
  mkdir -p "$WS"; cp -R "$tmpl/." "$WS/"
  WS="$(cd "$WS" && pwd)"
  cat > "$WS/fleet.conf" <<EOF
# fleet-control runtime config — written by fleet-loop.sh init
ORCH_DEFAULT=$ORCH_DEFAULT
EOF
  echo "01_dispatch" > "$WS/_fleet/active_stage"
  ledger_init
  echo "initialized fleet-control workspace at $WS (default orchestrator=$ORCH_DEFAULT)"
  echo "next: fill missions.tsv (mission<TAB>orchestrator<TAB>repo<TAB>intent<TAB>done_when), then: fleet-loop.sh tick --ws $WS"
}

status() {
  resolve_ws; observe >/dev/null 2>&1 || true
  echo "fleet workspace: $WS"; echo "active stage: $(active)"
  [ -f "$WS/_fleet/paused" ] && echo "PAUSED"
  echo "missions:"; column -t -s$'\t' "$(LEDGER)" 2>/dev/null || cat "$(LEDGER)" 2>/dev/null || echo "  (none)"
}

case "$CMD" in
  init)    init ;;
  observe) resolve_ws; observe; echo "observed → $WS/_fleet/agents.json + missions.ledger.tsv" ;;
  tick)    tick ;;
  run)     run ;;
  advance) advance ;;
  status)  status ;;
  help|*)  sed -n '2,38p' "$0" ;;
esac
