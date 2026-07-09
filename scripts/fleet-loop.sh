#!/usr/bin/env bash
# fleet-loop.sh — the meta-orchestrator reconciler (tier 0).
#
# STATUS: legacy, maintained. This script drives the fleet-control (Hermes-era) stack
# (§15), the meta tier above herd-control (§12). It keeps working and keeps getting
# fixes, but for Claude Code orchestration it is superseded by m2herd (§16) — see
# scripts/m2herd.sh + scripts/m2herd-up.sh (`m2herd-up`).
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
#   fleet-loop.sh init    --ws DIR [--worker claude] [--force]  # scaffold a fleet-control workspace
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
WS=""; ORCH_DEFAULT="claude"; INTERVAL=20; MAX_TICKS=0; DRY_RUN=0; FORCE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --ws) WS="$2"; shift 2 ;;
    --worker|--orchestrator) ORCH_DEFAULT="$2"; shift 2 ;;
    --interval) INTERVAL="$2"; shift 2 ;;
    --max-ticks) MAX_TICKS="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --force) FORCE=1; shift ;;
    -h|--help) CMD="help"; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

# ---------- self location (symlink-safe, like m2herd.sh) ----------------------
# macOS has no readlink -f, so walk the link chain by hand.
self_path() {
  local p="$0" l
  while [ -L "$p" ]; do
    l="$(readlink "$p")"
    case "$l" in /*) p="$l" ;; *) p="$(dirname "$p")/$l" ;; esac
  done
  printf '%s' "$p"
}
HERE="$(cd "$(dirname "$(self_path)")" && pwd)"
HERD_LOOP="$HERE/herd-loop.sh"

# ---------- workspace resolution ---------------------------------------------
resolve_ws() {
  [ -n "$WS" ] || WS="${FLEET_WS:-$PWD}"
  WS="$(cd "$WS" 2>/dev/null && pwd)" || { echo "no such workspace dir" >&2; exit 1; }
  [ -f "$WS/FLEET.md" ] || { echo "not a fleet-control workspace (no FLEET.md): $WS" >&2; exit 1; }
  init_dry_state
}

conf_get() { grep -E "^$1=" "$WS/fleet.conf" 2>/dev/null | head -1 | cut -d= -f2- || true; }
ctx_get()  { grep -iE "^$2:" "$1" 2>/dev/null | head -1 | sed -E 's/^[^:]+:[[:space:]]*//' || true; }
active()   { cat "$WS/_fleet/active_stage" 2>/dev/null || echo "01_dispatch"; }
ctx_file() { echo "$WS/stages/$(active)/CONTEXT.md"; }
log()      { printf '  %s\n' "$*"; }
# no eval: execute argv directly (dry-run just prints it)
do_or_echo()  { if [ "$DRY_RUN" -eq 1 ]; then echo "  [dry-run] $*"; else "$@"; fi; }
# state_write <desc> <cmd...> — a real state mutation, fully gated off under --dry-run
state_write() { local desc="$1"; shift; if [ "$DRY_RUN" -eq 1 ]; then log "[dry-run] would: $desc"; else "$@"; fi; }
write_line()  { printf '%s\n' "$2" > "$1"; }

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
    local v; v="$(grep -iE "^${a}[[:space:]]" "$f" 2>/dev/null | head -1 | awk '{print $2}')"
    [ -n "$v" ] && { [ "$v" = yes ] && return 0 || return 1; }
  fi
  case "$a" in claude|codex) return 0 ;; *) return 1 ;; esac
}

# ---------- dry-run state shadow ----------------------------------------------
# --dry-run must be FULLY side-effect-free. All state a tick normally mutates
# (mission ledger, fleet snapshot, self file, .needs_review, nudge counters) is
# shadowed into a throwaway temp dir seeded from the real files; every other write
# is gated behind DRY_RUN checks. Reads of desired state (missions.tsv, active_stage,
# paused, STEER.md, fleet.conf) stay on the real paths.
DRY_STATE=""
init_dry_state() {
  [ "$DRY_RUN" -eq 1 ] || return 0
  [ -n "$DRY_STATE" ] && return 0
  DRY_STATE="$(mktemp -d "${TMPDIR:-/tmp}/fleet-loop-dry.XXXXXX")"
  trap 'rm -rf "$DRY_STATE"' EXIT
  [ -f "$WS/_fleet/missions.ledger.tsv" ] && cp "$WS/_fleet/missions.ledger.tsv" "$DRY_STATE/missions.ledger.tsv" || true
}
FLEET_STATE() { if [ "$DRY_RUN" -eq 1 ] && [ -n "$DRY_STATE" ]; then echo "$DRY_STATE"; else echo "$WS/_fleet"; fi; }
AGENTS_JSON() { echo "$(FLEET_STATE)/agents.json"; }
SELF_FILE()   { echo "$(FLEET_STATE)/self"; }

# ---------- locking ------------------------------------------------------------
# Binding convention: every RMW of shared state (missions.ledger.tsv) runs under
# flock on <file>.lock; writers build the replacement with mktemp in the SAME dir,
# then atomic mv. Under --dry-run the ledger is the shadow copy, so locking is local.
with_lock() { # with_lock <file> <fn> [args...]
  local lf="$1.lock"; shift
  if command -v flock >/dev/null 2>&1; then
    ( flock -w 10 9 || { echo "  ! could not lock $lf (10s) — aborting write" >&2; exit 1; }
      "$@" ) 9>>"$lf"
  else
    "$@"   # no flock on PATH (rare): best effort, single-writer assumption
  fi
}

# ---------- mission ledger (TSV) ---------------------------------------------
# mission  orchestrator  pane  repo  herd_ws  goal_armed  status  collected
LEDGER() { echo "$(FLEET_STATE)/missions.ledger.tsv"; }
ledger_init() { [ -f "$(LEDGER)" ] || printf 'mission\torchestrator\tpane\trepo\therd_ws\tgoal_armed\tstatus\tcollected\n' > "$(LEDGER)"; }
ledger_has()  { awk -F'\t' -v s="$1" 'NR>1 && $1==s {f=1} END{exit !f}' "$(LEDGER)" 2>/dev/null; }
ledger_get()  { awk -F'\t' -v s="$1" -v c="$2" 'NR>1 && $1==s {print $c}' "$(LEDGER)" 2>/dev/null | head -1; }
_ledger_append() { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@" >> "$(LEDGER)"; }
ledger_add()  { # empty fields → "-" so IFS=$'\t' read never collapses adjacent tabs
  local fields=(); local a; for a in "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8"; do fields+=("${a:--}"); done
  with_lock "$(LEDGER)" _ledger_append "${fields[@]}"; }
_ledger_set() { # _ledger_set <mission> <col> <value> — runs under the ledger lock
  local led tmp; led="$(LEDGER)"
  tmp="$(mktemp "$(dirname "$led")/.ledger.XXXXXX")"
  awk -F'\t' -v OFS='\t' -v s="$1" -v c="$2" -v v="$3" 'NR==1{print;next} {if($1==s)$c=v; print}' "$led" > "$tmp"
  mv "$tmp" "$led"
}
ledger_set()  { with_lock "$(LEDGER)" _ledger_set "$1" "$2" "$3"; }
_ledger_del() { local led tmp; led="$(LEDGER)"
  tmp="$(mktemp "$(dirname "$led")/.ledger.XXXXXX")"
  awk -F'\t' -v s="$1" 'NR==1||$1!=s' "$led" > "$tmp"; mv "$tmp" "$led"; }
ledger_del()  { with_lock "$(LEDGER)" _ledger_del "$1"; }

# ---------- self-identity (binding convention) ---------------------------------
# NEVER key on .focused (that is whatever pane the human is looking at). Resolve our
# OWN pane via a bounded ancestor-pid/cwd walk matched against `herdr agent list`
# (same approach m2herd-up.sh ships). _fleet/self holds exactly one pane id, or is
# empty (not inside a herdr pane, or ambiguous). On empty-but-inside-herdr or
# ambiguous, destructive pane actions refuse — fail safe.
SELF_STATE="none"   # none (not a herdr pane) | ok (resolved) | ambiguous (fail safe)
resolve_self() {
  local out; out="$(SELF_FILE)"
  SELF_STATE="none"; : > "$out"
  local pid=$$ hops=0 c ppid comm in_herdr=0 cwds=$'\n'
  while [ "$hops" -lt 25 ] && [ -n "$pid" ]; do
    comm="$(ps -o comm= -p "$pid" 2>/dev/null || true)"
    case "$comm" in *herdr*) in_herdr=1 ;; esac
    c="$(readlink "/proc/$pid/cwd" 2>/dev/null || true)"
    [ -n "$c" ] || c="$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1 || true)"
    if [ -n "$c" ]; then case "$cwds" in *$'\n'"$c"$'\n'*) ;; *) cwds="$cwds$c"$'\n' ;; esac; fi
    ppid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
    { [ -n "$ppid" ] && [ "$ppid" -gt 1 ]; } 2>/dev/null || break
    pid="$ppid"; hops=$((hops+1))
  done
  [ "$in_herdr" -eq 1 ] || return 0     # not inside herdr: no pane can be ours
  local matches n
  matches="$(jq -r --arg cs "$cwds" '
      ($cs | split("\n") | map(select(length>0))) as $set
      | [.result.agents[]
         | select( ((.cwd // "") as $x | $set | index($x)) or ((.foreground_cwd // "") as $x | $set | index($x)) )
         | .pane_id]
      | unique | .[]' "$(AGENTS_JSON)" 2>/dev/null || true)"
  n="$(printf '%s' "$matches" | grep -c . || true)"
  if [ "${n:-0}" -eq 1 ]; then
    printf '%s\n' "$matches" > "$out"; SELF_STATE="ok"
  elif [ "${n:-0}" -gt 1 ]; then
    SELF_STATE="ambiguous"; log "! self-identity ambiguous ($(printf '%s' "$matches" | tr '\n' ' ')) — destructive actions disabled this pass"
  else
    SELF_STATE="ambiguous"; log "! inside herdr but own pane not found in agent list — destructive actions disabled this pass"
  fi
}
is_self() { # true only when self resolved AND equal
  local s; s="$(cat "$(SELF_FILE)" 2>/dev/null || true)"
  [ -n "$s" ] && [ "$1" = "$s" ]
}
can_destroy() { # fail-safe gate for pane close: refuse on self or ambiguous identity
  if [ "$SELF_STATE" = "ambiguous" ]; then log "! refusing destructive action on pane $1 — self-identity ambiguous (fail safe)"; return 1; fi
  if is_self "$1"; then log "! refusing destructive action on pane $1 — own pane"; return 1; fi
  return 0
}

# ---------- observe: snapshot fleet + each mission's true status --------------
observe() {
  local fdir; fdir="$(FLEET_STATE)"
  mkdir -p "$fdir"
  herdr agent list > "$fdir/agents.json.tmp" 2>/dev/null && mv "$fdir/agents.json.tmp" "$fdir/agents.json" \
    || { echo "  ! herdr agent list failed (server up?)" >&2; return 1; }
  resolve_self
  ledger_init
  # refresh each mission's status from (a) the orchestrator pane's lifecycle and
  # (b) its herd-control DONE marker — the cross-tier completion signal.
  awk -F'\t' 'NR>1{print $1"\t"$3"\t"$5}' "$(LEDGER)" | while IFS=$'\t' read -r mission pane herd_ws; do
    [ -n "$mission" ] || continue
    local life="" hstage=""
    if [ -n "$pane" ] && [ "$pane" != "-" ] && [ "$pane" != "DRYRUN" ]; then
      life="$(jq -r --arg p "$pane" '.result.agents[]|select(.pane_id==$p)|.agent_status' "$(AGENTS_JSON)" 2>/dev/null | head -1)"
      [ -n "$life" ] || life="gone"   # orchestrator pane vanished
    fi
    [ -n "$herd_ws" ] && [ "$herd_ws" != "-" ] && hstage="$(cat "$herd_ws/_fleet/active_stage" 2>/dev/null || true)"
    # mission is "done" when its herd-loop reached DONE; otherwise mirror the orchestrator life state.
    if [ "$hstage" = "DONE" ]; then ledger_set "$mission" 7 "done"
    elif [ -n "$life" ]; then ledger_set "$mission" 7 "$life"; fi
  done || true
  return 0
}

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
  if [ "$DRY_RUN" -eq 1 ]; then log "[dry-run] would send to pane $pane: $text"; return 0; fi
  herdr agent send "$pane" "$text" >/dev/null 2>&1 || true
  sleep "$SUBMIT_SETTLE"
  herdr pane send-keys "$pane" Enter >/dev/null 2>&1 || true
}

# Binding rule (mirrors m2herd-up.sh): the pane_id `agent start` returns can be off
# by one — always RE-RESOLVE by cwd from `herdr agent list` (prefer a name match)
# and use the re-resolved id for every send/Enter/close that follows.
resolve_pane_by_cwd() { # resolve_pane_by_cwd <cwd> [name] -> pane_id (retries; list can lag)
  local cwd="$1" name="${2:-}" pane=""
  for _ in 1 2 3 4 5; do
    if [ -n "$name" ]; then
      pane="$(herdr agent list 2>/dev/null | jq -r --arg c "$cwd" --arg n "$name" \
        '[.result.agents[] | select(.cwd==$c and (.name // "")==$n)] | last | .pane_id // empty' 2>/dev/null || true)"
    fi
    [ -n "$pane" ] || pane="$(herdr agent list 2>/dev/null | jq -r --arg c "$cwd" \
      '[.result.agents[] | select(.cwd==$c)] | last | .pane_id // empty' 2>/dev/null || true)"
    [ -n "$pane" ] && break
    sleep 1
  done
  printf '%s' "$pane"
}

# ---------- inbox / steering (same vocabulary as herd-loop.sh) ----------------
STEER_HEADER='<!--
inbox/STEER.md — live steering channel (Layer 4). Edit below the marker to steer the meta-loop.
Commands: PAUSE | RESUME | KILL <mission> | RESCOPE <mission> | GOTO <stage> | NOTE <text>
-->

=== STEER ==='
# escalated / NOTE / unhandled steer lines land in inbox/escalations.log (audit
# trail for the meta-orchestrator), not just stdout.
note_escalation() {
  if [ "$DRY_RUN" -eq 1 ]; then log "[dry-run] would append to inbox/escalations.log: $*"; return 0; fi
  mkdir -p "$WS/inbox"
  printf '%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$WS/inbox/escalations.log"
}
steer_process() { # execute steer commands read from <file>
  awk 'p{print} /=== STEER ===/{p=1}' "$1" | sed '/^[[:space:]]*$/d' | while IFS= read -r line; do
    local cmd="" arg=""
    read -r cmd arg <<<"$line" || true   # field split without glob expansion
    case "$cmd" in
      PAUSE)   state_write "touch _fleet/paused (PAUSE)" touch "$WS/_fleet/paused"; log "steer: PAUSED" ;;
      RESUME)  state_write "rm _fleet/paused (RESUME)" rm -f "$WS/_fleet/paused"; log "steer: RESUMED" ;;
      GOTO)    if [ -n "$arg" ]; then state_write "set active_stage=$arg (GOTO)" write_line "$WS/_fleet/active_stage" "$arg"; log "steer: GOTO $arg"; fi ;;
      KILL)    local p; p="$(ledger_get "$arg" 3)"
               if [ -n "$p" ] && [ "$p" != "-" ] && can_destroy "$p"; then
                 do_or_echo herdr pane close "$p" || log "! KILL $arg: pane close failed (already gone?)"
                 ledger_set "$arg" 7 "abandoned"; log "steer: KILLED mission $arg"
               fi ;;
      RESCOPE) ledger_del "$arg"; log "steer: RESCOPE $arg (will re-launch with edited goal)" ;;
      NOTE)    note_escalation "NOTE: $arg"; log "steer NOTE (for meta-orchestrator): $arg" ;;
      *)       note_escalation "UNHANDLED steer line: $line"; log "steer (unhandled, meta should read): $line" ;;
    esac
  done || true
}
drain_inbox() {
  local f="$WS/inbox/STEER.md" d="$WS/inbox/STEER.md.draining"
  if [ "$DRY_RUN" -eq 1 ]; then
    [ -f "$f" ] || return 0
    steer_process "$f"     # peek only: no rename, no template rewrite
    log "[dry-run] would drain inbox/STEER.md and reset it to the template"
    return 0
  fi
  # recover a drain interrupted by a crash (leftover .draining), then drain current.
  [ -f "$d" ] && { steer_process "$d"; rm -f "$d"; }
  [ -f "$f" ] || return 0
  # TOCTOU-safe drain: atomically rename FIRST, process the renamed file, and only
  # then write the fresh template. A human write landing between the rename and the
  # template lands in a brand-new STEER.md, which noclobber leaves untouched.
  mv -f "$f" "$d"
  steer_process "$d"
  ( set -o noclobber; printf '%s\n' "$STEER_HEADER" > "$f" ) 2>/dev/null \
    || log "! STEER.md was recreated mid-drain — left untouched (drained next tick)"
  rm -f "$d"
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
# NEVER sends a vacuous `/goal ` (empty condition would arm a goal that can't clear).
arm_goal() {
  local pane="$1" cond="$2" agent="$3"
  [ -n "$pane" ] && [ "$pane" != "-" ] && [ "$pane" != "DRYRUN" ] || return 0
  is_self "$pane" && return 0
  if [ -z "$cond" ]; then log "! empty done_when — not sending /goal (skipping arm)"; return 1; fi
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
  local herd_ws; herd_ws="$HOME/.herdr/fleet/$(basename "$WS")/$mission"
  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] would launch $orch for mission '$mission' (repo $repo, herd_ws $herd_ws); arm /goal=$(goal_supported "$orch" && echo yes || echo no)"
    ledger_add "$mission" "$orch" "DRYRUN" "$repo" "$herd_ws" "$(goal_supported "$orch" && echo yes || echo no)" "working" "no"; return   # shadow ledger only
  fi
  # launch the orchestrator agent in its repo (NOT a worktree — the orchestrator itself
  # creates per-worker worktrees via its herd-loop). Unique herdr name per mission.
  local reported pane
  reported="$(herdr agent start "$orch-orch-$mission" --cwd "$repo" --no-focus -- "$(command -v "$bin")" $flag 2>/dev/null | jq -r '.result.agent.pane_id // empty')"
  pane="$(resolve_pane_by_cwd "$repo" "$orch-orch-$mission")"
  if [ -z "$pane" ]; then
    pane="$reported"
    [ -n "$pane" ] && [ "$pane" != "null" ] && log "! $mission: could not re-resolve pane by cwd — falling back to reported id $pane"
  fi
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
# grep a pane screen against a pattern-list file. Echoes: match | nomatch | error.
# "error" covers an unreadable file and grep failures — callers treat it FAIL-CLOSED
# (never auto-approve on it).
list_check() { # list_check <patterns-file> <screen>
  local f="$1" screen="$2" pats rc=0
  [ -e "$f" ] || { echo nomatch; return 0; }
  [ -r "$f" ] || { echo error; return 0; }
  pats="$(grep -vE '^\s*#|^\s*$' "$f" 2>/dev/null || true)"
  [ -n "$pats" ] || { echo nomatch; return 0; }
  printf '%s' "$screen" | grep -qiE -f <(printf '%s\n' "$pats") || rc=$?
  case "$rc" in 0) echo match ;; 1) echo nomatch ;; *) echo error ;; esac
}
handle_blocked() {
  local mission="$1" pane="$2"
  is_self "$pane" && return 0
  local screen; screen="$(herdr agent read "$pane" --source visible 2>/dev/null || true)"
  local allow="$WS/_config/approve_allow.txt" deny="$WS/_config/approve_deny.txt"
  local dres ares
  dres="$(list_check "$deny" "$screen")"
  if [ "$dres" != "nomatch" ]; then     # match OR error: fail closed → escalate
    [ "$dres" = "error" ] && log "! deny-list check failed ($deny unreadable or bad pattern) — failing CLOSED, escalating"
    escalate "$mission" "$screen"; return
  fi
  ares="$(list_check "$allow" "$screen")"
  if [ "$ares" = "match" ]; then
    do_or_echo herdr pane send-keys "$pane" Enter; log "auto-approved $mission (routine)"; return
  fi
  [ "$ares" = "error" ] && log "! allow-list check failed ($allow unreadable or bad pattern) — not auto-approving"
  escalate "$mission" "$screen"
}
needs_review() { echo "$1" > "$(FLEET_STATE)/.needs_review"; }
escalate() {
  local mission="$1" screen="$2" rev; rev="$WS/stages/$(active)/review/$mission.md"
  if [ "$DRY_RUN" -eq 1 ]; then log "[dry-run] would ESCALATE mission $mission → $rev"; needs_review escalated; return 0; fi
  mkdir -p "$WS/stages/$(active)/review"
  { echo "# review needed: mission $mission"; echo; echo '```'; printf '%s\n' "$screen"; echo '```'; } > "$rev"
  note_escalation "escalated mission $mission → $rev"
  log "ESCALATED mission $mission → $rev"; needs_review escalated
}
review_note() { # review_note <stage> <mission> <line...> — short review file, errors NOT eaten
  local stage="$1" mission="$2"; shift 2
  local rev="$WS/stages/$stage/review/$mission.md"
  if [ "$DRY_RUN" -eq 1 ]; then log "[dry-run] would write review note $rev"; return 0; fi
  mkdir -p "$WS/stages/$stage/review"
  printf '%s\n' "$@" > "$rev"
}

# ---------- nudge accounting: cap fruitless re-sends ---------------------------
NUDGE_MAX=3
nudge_file()  { echo "$(FLEET_STATE)/nudges/$1"; }
nudge_count() {
  local f; f="$(nudge_file "$1")"
  [ -f "$f" ] || f="$WS/_fleet/nudges/$1"   # dry-run shadow empty → read the real counter
  cat "$f" 2>/dev/null || echo 0
}
nudge_bump()  { local f; f="$(nudge_file "$1")"; mkdir -p "$(dirname "$f")"; echo "$2" > "$f"; }
nudge_clear() { rm -f "$(nudge_file "$1")" 2>/dev/null || true; }

# re-nudge an orchestrator that has no /goal (or whose goal was dropped) and is idle
nudge_orchestrator() {
  local mission="$1" pane="$2" herd_ws="$3"
  [ -n "$pane" ] && [ "$pane" != "-" ] && [ "$pane" != "DRYRUN" ] || return 0
  is_self "$pane" && return 0
  submit_pane "$pane" "Continue your mission: drive $HERD_LOOP run --ws $herd_ws until your 'Done when' holds. Read goals/$mission.md if you've lost context."
}

collect_mission() {
  local mission="$1" herd_ws="$2"
  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] would collect mission $mission → stages/$(active)/output/$mission.md"
    ledger_set "$mission" 8 "yes"; return 0   # shadow ledger only
  fi
  local out; out="$WS/stages/$(active)/output/$mission.md"; mkdir -p "$WS/stages/$(active)/output"
  { echo "# mission $mission — collected $(active)"; echo;
    echo "herd_ws: $herd_ws"; echo "herd active_stage: $(cat "$herd_ws/_fleet/active_stage" 2>/dev/null || echo '?')"; echo;
    echo "## ledger"; column -t -s$'\t' "$herd_ws/_fleet/ledger.tsv" 2>/dev/null || cat "$herd_ws/_fleet/ledger.tsv" 2>/dev/null || echo "(none)";
  } > "$out"
  ledger_set "$mission" 8 "yes"; nudge_clear "$mission"
  log "collected mission $mission → stages/$(active)/output/$mission.md"
}

# ---------- tick -------------------------------------------------------------
tick() {
  resolve_ws
  ORCH_DEFAULT="$(conf_get ORCH_DEFAULT)"; ORCH_DEFAULT="${ORCH_DEFAULT:-claude}"
  rm -f "$(FLEET_STATE)/.needs_review"
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
    # awk-parsed per field (consistent with the done_when lookup below): a malformed
    # row (fewer than 5 tab-separated cols) is SKIPPED with a warning, never
    # field-shifted the way IFS=$'\t' read would on an empty middle column.
    grep -vE '^\s*#|^\s*$' "$missions" | while IFS= read -r line; do
      local nf; nf="$(awk -F'\t' '{print NF}' <<<"$line")"
      if [ "${nf:-0}" -lt 5 ]; then log "! missions.tsv: skipping malformed row (need 5 tab-separated cols, got ${nf:-0}): ${line:0:60}"; continue; fi
      local mission orch repo intent done_when
      mission="$(awk -F'\t' '{print $1}' <<<"$line")"
      orch="$(awk -F'\t' '{print $2}' <<<"$line")"
      repo="$(awk -F'\t' '{print $3}' <<<"$line")"
      intent="$(awk -F'\t' '{print $4}' <<<"$line")"
      done_when="$(awk -F'\t' '{print $5}' <<<"$line")"
      [ -n "$mission" ] || continue
      ledger_has "$mission" || launch_mission "$mission" "$orch" "$repo" "$intent" "$done_when"
    done || true
    observe
    # react to each mission row
    while IFS=$'\t' read -r mission orch pane repo herd_ws goal status collected; do
      [ -n "$mission" ] || continue
      case "$status" in
        working) nudge_clear "$mission" ;;   # progressing again → reset the nudge cap
        blocked) handle_blocked "$mission" "$pane" ;;
        done)    [ "$collected" = "yes" ] || collect_mission "$mission" "$herd_ws" ;;
        idle)    # orchestrator idle but herd not DONE: re-arm goal or nudge it onward —
                 # but only NUDGE_MAX fruitless times, then flag for review instead of
                 # hammering it every tick forever.
                 local nn; nn="$(nudge_count "$mission")"
                 if [ "${nn:-0}" -ge "$NUDGE_MAX" ]; then
                   review_note "$stage" "$mission" \
                     "# mission $mission: orchestrator still idle after $NUDGE_MAX nudges/re-arms" \
                     "" \
                     "herd_ws $herd_ws never reached DONE. Investigate the pane ($pane)," \
                     "then KILL/RESCOPE via inbox/STEER.md or collect manually."
                   needs_review stalled; log "STALLED mission $mission (nudged $nn×) → review"
                 else
                   if [ "$goal" = "yes" ]; then
                     local dw; dw="$(awk -F'\t' -v m="$mission" '$1==m{print $5}' "$missions" | head -1)"
                     if [ -n "$dw" ]; then arm_goal "$pane" "$dw" "$orch" || true
                     else log "! $mission: done_when unreadable from missions.tsv — skipping /goal re-arm"; fi
                   else nudge_orchestrator "$mission" "$pane" "$herd_ws"; fi
                   nudge_bump "$mission" "$((nn+1))"
                 fi ;;
        gone)    if [ "$collected" != "yes" ]; then
                   review_note "$stage" "$mission" "# mission $mission: orchestrator pane died — re-launch (KILL then RESCOPE) or investigate"
                   needs_review errored; log "GONE mission $mission → review"; fi ;;
        error)   review_note "$stage" "$mission" "# error: mission $mission failed to launch — see ledger"
                 needs_review errored; log "ERROR mission $mission → review" ;;
        abandoned) : ;;
      esac
    done < <(awk -F'\t' 'NR>1' "$(LEDGER)")
    # complete when every desired (well-formed) mission is collected (or terminal)
    complete=1
    while IFS=$'\t' read -r mission _; do
      [ -n "$mission" ] || continue
      local c s; c="$(ledger_get "$mission" 8)"; s="$(ledger_get "$mission" 7)"
      [ "$c" = "yes" ] || [ "$s" = "abandoned" ] || [ "$s" = "error" ] || complete=0
    done < <(grep -vE '^\s*#|^\s*$' "$missions" | awk -F'\t' 'NF>=5')
    if [ -f "$(FLEET_STATE)/.needs_review" ]; then echo "STATUS: NEEDS_REVIEW"; return 0; fi
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
    if [ "$gate" = "auto" ]; then
      if [ "$DRY_RUN" -eq 1 ]; then
        log "[dry-run] would auto-advance past $stage"; echo "STATUS: MISSION_COMPLETE"; return 0
      fi
      advance && { echo "STATUS: ADVANCED → $(active)"; return 0; }
    fi
    [ "$DRY_RUN" -eq 1 ] || herdr notification show "fleet: $stage complete" --body "review $WS/stages/$stage/output then advance" >/dev/null 2>&1 || true
    echo "STATUS: MISSION_COMPLETE"
  fi
}

advance() {
  resolve_ws
  local stage ctx handoff; stage="$(active)"; ctx="$WS/stages/$stage/CONTEXT.md"
  handoff="$(ctx_get "$ctx" handoff)"
  if [ -z "$handoff" ] || [ "$handoff" = "DONE" ]; then
    state_write "set active_stage=DONE" write_line "$WS/_fleet/active_stage" "DONE"; echo "STATUS: DONE"; return 0
  fi
  state_write "set active_stage=$handoff" write_line "$WS/_fleet/active_stage" "$handoff"
  log "advanced $stage → $handoff"
}

run() {
  resolve_ws; local n=0 bad=0
  while true; do
    local out st=""
    out="$(tick || true)"; printf '%s\n' "$out"
    case "$out" in *"STATUS: "*) st="${out##*STATUS: }" ;; esac
    case "$st" in
      DONE|NEEDS_REVIEW|AWAITING_SOLO|MISSION_COMPLETE|PAUSED|ERROR*) log "loop yields on: $st"; break ;;
      RECONCILED|ADVANCED*) bad=0 ;;
      *)  # tick produced no STATUS: line (or an unknown one): don't hammer forever
          bad=$((bad+1)); log "! tick produced no/unknown STATUS ($bad/3): '${st:-<empty>}'"
          if [ "$bad" -ge 3 ]; then
            echo "STATUS: ERROR (3 consecutive ticks without a recognizable STATUS: line)"
            exit 1
          fi ;;
    esac
    n=$((n+1)); [ "$MAX_TICKS" -gt 0 ] && [ "$n" -ge "$MAX_TICKS" ] && { log "max-ticks reached"; break; }
    sleep "$INTERVAL"
  done
}

init() {
  [ -n "$WS" ] || { echo "init needs --ws DIR" >&2; exit 2; }
  local tmpl; tmpl="$(cd "$HERE/../templates/fleet-control" && pwd)"
  # never cp -R over a LIVE workspace by accident; --force refreshes templates but
  # preserves runtime state (active_stage, ledger, missions.tsv).
  if [ -f "$WS/FLEET.md" ] || [ -f "$WS/fleet.conf" ] || [ -d "$WS/_fleet" ]; then
    if [ "$FORCE" -ne 1 ]; then
      echo "init: REFUSING — $WS already looks like a fleet-control workspace (re-run with --force to refresh templates; active_stage + ledger + missions.tsv are preserved)" >&2
      exit 2
    fi
    log "init --force: refreshing templates over $WS (preserving active_stage + ledger + missions.tsv)"
  fi
  local prev_stage="" prev_missions=""
  prev_stage="$(cat "$WS/_fleet/active_stage" 2>/dev/null || true)"
  if [ -f "$WS/missions.tsv" ]; then prev_missions="$(mktemp)"; cp "$WS/missions.tsv" "$prev_missions"; fi
  mkdir -p "$WS"; cp -R "$tmpl/." "$WS/"
  WS="$(cd "$WS" && pwd)"
  if [ -n "$prev_missions" ]; then mv "$prev_missions" "$WS/missions.tsv"; fi
  cat > "$WS/fleet.conf" <<EOF
# fleet-control runtime config — written by fleet-loop.sh init
ORCH_DEFAULT=$ORCH_DEFAULT
EOF
  mkdir -p "$WS/_fleet"
  if [ -n "$prev_stage" ]; then printf '%s\n' "$prev_stage" > "$WS/_fleet/active_stage"
  else echo "01_dispatch" > "$WS/_fleet/active_stage"; fi
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
  observe) resolve_ws; observe; echo "observed → $(AGENTS_JSON) + missions.ledger.tsv" ;;
  tick)    tick ;;
  run)     run ;;
  advance) advance ;;
  status)  status ;;
  help|*)  sed -n '2,38p' "$0" ;;
esac
