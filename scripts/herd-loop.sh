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
#   herd-loop.sh init --ws DIR --repo PATH [--base main] [--feature DIR] [--worker codex] [--force]
#   herd-loop.sh tick     [--ws DIR] [--dry-run]      # one reconciliation pass
#   herd-loop.sh run      [--ws DIR] [--interval 10] [--max-ticks 0] [--dry-run]
#                         [--auto-rotate [--orchestrator PANE] [--max-rotations 5]]  # self-rotate on CRITICAL
#   herd-loop.sh observe  [--ws DIR]                  # snapshot fleet → _fleet/
#   herd-loop.sh status   [--ws DIR]                  # human-readable rollup
#   herd-loop.sh advance  [--ws DIR]                  # move active stage → its handoff
#   herd-loop.sh rotate   [--ws DIR] [--orchestrator PANE] [--dry-run]  # retire+restart orchestrator
#
# Workspace is found via --ws, $HERD_WS, or the current dir (must contain AGENT.md).
# Idempotent. Safe to re-run. Reads herd.conf + stage CONTEXT.md; never bare `herdr`.

set -euo pipefail

# ---------- arg parsing ------------------------------------------------------
CMD="${1:-help}"; shift || true
WS=""; REPO=""; BASE="main"; FEATURE=""; WORKER_DEFAULT="codex"
MODEL="GLM-5.2"; BUDGET="384000"          # context-budget layer defaults (GLM-5.2 / 384k)
INTERVAL=10; MAX_TICKS=0; DRY_RUN=0; ORCH=""; FORCE=0
AUTO_ROTATE=0; MAX_ROTATIONS=5            # run --auto-rotate: rotate on CRITICAL, capped
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
    --force) FORCE=1; shift ;;
    --orchestrator) ORCH="$2"; shift 2 ;;
    --auto-rotate) AUTO_ROTATE=1; shift ;;
    --max-rotations) MAX_ROTATIONS="$2"; shift 2 ;;
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
SCRIPT_DIR="$(cd "$(dirname "$(self_path)")" && pwd)"

# ---------- workspace resolution ---------------------------------------------
resolve_ws() {
  [ -n "$WS" ] || WS="${HERD_WS:-$PWD}"
  WS="$(cd "$WS" 2>/dev/null && pwd)" || { echo "no such workspace dir" >&2; exit 1; }
  [ -f "$WS/AGENT.md" ] || { echo "not a herd-control workspace (no AGENT.md): $WS" >&2; exit 1; }
  init_dry_state
}

conf_get() { grep -E "^$1=" "$WS/herd.conf" 2>/dev/null | head -1 | cut -d= -f2- || true; }
ctx_get()  { grep -iE "^$2:" "$1" 2>/dev/null | head -1 | sed -E 's/^[^:]+:[[:space:]]*//' || true; }
active()   { cat "$WS/_fleet/active_stage" 2>/dev/null || echo "01_spec"; }
ctx_file() { echo "$WS/stages/$(active)/CONTEXT.md"; }
log()      { printf '  %s\n' "$*"; }
# no eval: execute argv directly (dry-run just prints it)
do_or_echo()  { if [ "$DRY_RUN" -eq 1 ]; then echo "  [dry-run] $*"; else "$@"; fi; }
# state_write <desc> <cmd...> — a real state mutation, fully gated off under --dry-run
state_write() { local desc="$1"; shift; if [ "$DRY_RUN" -eq 1 ]; then log "[dry-run] would: $desc"; else "$@"; fi; }
write_line()  { printf '%s\n' "$2" > "$1"; }

# worker -> "binary<TAB>flag"
worker_argv() {
  case "$1" in
    codex)  printf '%s\t%s\n' "codex" "--dangerously-bypass-approvals-and-sandbox" ;;
    claude) printf '%s\t%s\n' "claude" "--dangerously-skip-permissions" ;;
    cursor) printf '%s\t%s\n' "cursor-agent" "--force" ;;
    *) printf '%s\t%s\n' "$1" "" ;;
  esac
}

# ---------- dry-run state shadow ----------------------------------------------
# --dry-run must be FULLY side-effect-free. All state a tick normally mutates
# (ledger, fleet snapshot, self file, .needs_review, nudge counters) is shadowed
# into a throwaway temp dir seeded from the real files; every other write is gated
# behind DRY_RUN checks. Reads of desired state (active_stage, paused, STEER.md,
# slices.tsv, herd.conf) stay on the real paths so the simulation is faithful.
DRY_STATE=""
init_dry_state() {
  [ "$DRY_RUN" -eq 1 ] || return 0
  [ -n "$DRY_STATE" ] && return 0
  DRY_STATE="$(mktemp -d "${TMPDIR:-/tmp}/herd-loop-dry.XXXXXX")"
  trap 'rm -rf "$DRY_STATE"' EXIT
  [ -f "$WS/_fleet/ledger.tsv" ] && cp "$WS/_fleet/ledger.tsv" "$DRY_STATE/ledger.tsv" || true
}
FLEET_STATE() { if [ "$DRY_RUN" -eq 1 ] && [ -n "$DRY_STATE" ]; then echo "$DRY_STATE"; else echo "$WS/_fleet"; fi; }
AGENTS_JSON() { echo "$(FLEET_STATE)/agents.json"; }
SELF_FILE()   { echo "$(FLEET_STATE)/self"; }

# ---------- locking ------------------------------------------------------------
# Binding convention: every RMW of shared state (ledger.tsv) runs under flock on
# <file>.lock; writers build the replacement with mktemp in the SAME dir, then
# atomic mv. Under --dry-run the ledger is the shadow copy, so locking is local.
with_lock() { # with_lock <file> <fn> [args...]
  local lf="$1.lock"; shift
  if command -v flock >/dev/null 2>&1; then
    ( flock -w 10 9 || { echo "  ! could not lock $lf (10s) — aborting write" >&2; exit 1; }
      "$@" ) 9>>"$lf"
  else
    "$@"   # no flock on PATH (rare): best effort, single-writer assumption
  fi
}

# ---------- ledger (TSV: slice worker pane branch worktree status collected) --
LEDGER() { echo "$(FLEET_STATE)/ledger.tsv"; }
ledger_init() { [ -f "$(LEDGER)" ] || printf 'slice\tworker\tpane\tbranch\tworktree\tstatus\tcollected\n' > "$(LEDGER)"; }
ledger_has()  { awk -F'\t' -v s="$1" 'NR>1 && $1==s {f=1} END{exit !f}' "$(LEDGER)" 2>/dev/null; }
ledger_get()  { awk -F'\t' -v s="$1" -v c="$2" 'NR>1 && $1==s {print $c}' "$(LEDGER)" 2>/dev/null | head -1; }
_ledger_append() { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@" >> "$(LEDGER)"; }
ledger_add()  { # empty fields → "-" so IFS=$'\t' read never collapses adjacent tabs
  local fields=(); local a; for a in "$1" "$2" "$3" "$4" "$5" "$6" "$7"; do fields+=("${a:--}"); done
  with_lock "$(LEDGER)" _ledger_append "${fields[@]}"; }
_ledger_set() { # _ledger_set <slice> <col> <value> — runs under the ledger lock
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

# ---------- observe: snapshot fleet → _fleet/ --------------------------------
observe() {
  local fdir; fdir="$(FLEET_STATE)"
  mkdir -p "$fdir"
  herdr agent list > "$fdir/agents.json.tmp" 2>/dev/null && mv "$fdir/agents.json.tmp" "$fdir/agents.json" \
    || { echo "  ! herdr agent list failed (server up?)" >&2; return 1; }
  resolve_self
  ledger_init
  # refresh each ledger row's status from the live snapshot, by pane id
  awk -F'\t' 'NR>1{print $1"\t"$3}' "$(LEDGER)" | while IFS=$'\t' read -r slice pane; do
    [ -n "$pane" ] || continue
    local st; st="$(jq -r --arg p "$pane" '.result.agents[]|select(.pane_id==$p)|.agent_status' "$(AGENTS_JSON)" 2>/dev/null | head -1)"
    if [ -n "$st" ]; then ledger_set "$slice" 6 "$st"
    elif [ "$pane" != "DRYRUN" ] && [ "$pane" != "-" ]; then ledger_set "$slice" 6 "gone"; fi  # pane vanished (worker died)
  done || true
  return 0
}

# ---------- inbox / steering --------------------------------------------------
STEER_HEADER='<!--
inbox/STEER.md — live steering channel (Layer 4). Edit below the marker to steer the loop.
Commands: PAUSE | RESUME | KILL <slice> | RESCOPE <slice> | GOTO <stage> | NOTE <text>
-->

=== STEER ==='
# escalated / NOTE / unhandled steer lines land in inbox/escalations.log (audit
# trail for the orchestrator), not just stdout.
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
                 ledger_set "$arg" 6 "abandoned"; log "steer: KILLED $arg"
               fi ;;
      RESCOPE) # drop the ledger row so the slice re-spawns with its (edited) prompt
               ledger_del "$arg"; log "steer: RESCOPE $arg (will re-dispatch)" ;;
      NOTE)    note_escalation "NOTE: $arg"; log "steer NOTE (for orchestrator): $arg" ;;
      *)       note_escalation "UNHANDLED steer line: $line"; log "steer (unhandled, orchestrator should read): $line" ;;
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
relevant to your change, commit on the current branch ("$slice: <summary>"), write a
short report (what you did + how you verified it) to REPORT.md at the worktree root —
the loop reads REPORT.md as your completion signal — and say the same in chat.
EOF
  echo "$out"
}

# Send the one-line pointer + submit. Used at spawn AND as the reconcile nudge — TUIs
# accept input at different times (claude shows a welcome screen, codex loads its model),
# so we may need to (re)send the text, not just Enter. Re-sending to an idle worker is
# safe: it just reads the same prompt file again.
#
# A TUI needs a beat to render the injected text into its input box. If the Enter races
# the text it submits an empty line and the pointer is left sitting in the input box,
# unsubmitted — the "typed but never sent" symptom. Settle between the text and the Enter.
# Override the delay with SUBMIT_SETTLE (seconds) for slow machines.
SUBMIT_SETTLE="${SUBMIT_SETTLE:-1}"
submit_prompt() {
  local pane="$1" pf="$2"
  [ -n "$pane" ] && [ "$pane" != "-" ] && [ "$pane" != "DRYRUN" ] || return 0
  is_self "$pane" && return 0
  if [ "$DRY_RUN" -eq 1 ]; then log "[dry-run] would send prompt pointer $pf to pane $pane"; return 0; fi
  herdr agent send "$pane" "Read $pf and follow its instructions exactly." >/dev/null 2>&1 || true
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

spawn_slice() {
  local stage="$1" slice="$2" worker="$3"
  worker="${worker:-$WORKER_DEFAULT}"
  local av bin flag; av="$(worker_argv "$worker")"; bin="${av%%$'\t'*}"; flag="${av##*$'\t'}"
  if ! command -v "$bin" >/dev/null 2>&1; then
    log "! $slice: worker binary '$bin' not on PATH — marking error"; ledger_add "$slice" "$worker" "" "" "" "error" "no"; return
  fi
  local branch="wip/$stage/$slice" wt
  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] would spawn $worker for $slice (branch $branch: worktree + prompt + ledger row + send)"
    ledger_add "$slice" "$worker" "DRYRUN" "$branch" "" "working" "no"; return   # shadow ledger only
  fi
  wt="$(herdr worktree create --cwd "$REPO" --branch "$branch" --base "$BASE" --label "$slice" --json 2>/dev/null | jq -r '.result.worktree.path')"
  [ -n "$wt" ] && [ "$wt" != "null" ] || { log "! $slice: worktree create failed"; ledger_add "$slice" "$worker" "" "$branch" "" "error" "no"; return; }
  # herdr requires a UNIQUE agent name; the integration is detected from the binary,
  # so a "<worker>-<slice>" label coexists with other workers of the same type.
  local reported pane
  reported="$(herdr agent start "$worker-$slice" --cwd "$wt" --no-focus -- "$(command -v "$bin")" $flag 2>/dev/null | jq -r '.result.agent.pane_id // empty')"
  pane="$(resolve_pane_by_cwd "$wt" "$worker-$slice")"
  if [ -z "$pane" ]; then
    pane="$reported"
    [ -n "$pane" ] && [ "$pane" != "null" ] && log "! $slice: could not re-resolve pane by cwd — falling back to reported id $pane"
  fi
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
  local stage="$1" slice="$2" pane="$3"
  is_self "$pane" && return 0
  local screen; screen="$(herdr agent read "$pane" --source visible 2>/dev/null || true)"
  local allow="$WS/_config/approve_allow.txt" deny="$WS/_config/approve_deny.txt"
  local dres ares
  dres="$(list_check "$deny" "$screen")"
  if [ "$dres" != "nomatch" ]; then     # match OR error: fail closed → escalate
    [ "$dres" = "error" ] && log "! deny-list check failed ($deny unreadable or bad pattern) — failing CLOSED, escalating"
    escalate "$stage" "$slice" "$screen"; return
  fi
  ares="$(list_check "$allow" "$screen")"
  if [ "$ares" = "match" ]; then
    do_or_echo herdr pane send-keys "$pane" Enter; log "auto-approved $slice (routine)"; return
  fi
  [ "$ares" = "error" ] && log "! allow-list check failed ($allow unreadable or bad pattern) — not auto-approving"
  escalate "$stage" "$slice" "$screen"
}
needs_review() { echo "$1" > "$(FLEET_STATE)/.needs_review"; }
escalate() {
  local stage="$1" slice="$2" screen="$3" rev="$WS/stages/$1/review/$2.md"
  if [ "$DRY_RUN" -eq 1 ]; then log "[dry-run] would ESCALATE $slice → $rev"; needs_review escalated; return 0; fi
  mkdir -p "$WS/stages/$stage/review"
  { echo "# review needed: $slice (stage $stage)"; echo; echo '```'; printf '%s\n' "$screen"; echo '```'; } > "$rev"
  note_escalation "escalated $slice (stage $stage) → $rev"
  log "ESCALATED $slice → $rev"
  needs_review escalated
}
review_note() { # review_note <stage> <slice> <line...> — short review file, errors NOT eaten
  local stage="$1" slice="$2"; shift 2
  local rev="$WS/stages/$stage/review/$slice.md"
  if [ "$DRY_RUN" -eq 1 ]; then log "[dry-run] would write review note $rev"; return 0; fi
  mkdir -p "$WS/stages/$stage/review"
  printf '%s\n' "$@" > "$rev"
}

# a fanout worker is "done" when EITHER (a) its pane is idle/done/gone AND it has
# committed beyond base — a TUI is idle while waiting for input too, and an early
# mid-work commit must not trigger premature collection — or (b) it wrote REPORT.md
# at the worktree root (the slice's answer file), the explicit completion signal.
worker_done() { # worker_done <worktree> <status>
  local wt="$1" status="${2:-}"
  [ -n "$wt" ] && [ "$wt" != "-" ] && [ -d "$wt" ] || return 1
  [ -f "$wt/REPORT.md" ] && return 0
  case "$status" in idle|done|gone) ;; *) return 1 ;; esac
  local n; n="$(git -C "$wt" rev-list --count "$BASE"..HEAD 2>/dev/null || echo 0)"
  [ "${n:-0}" -gt 0 ]
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

# ---------- rolling digest: store summaries, keep deep-dives in files ---------
# A short per-slice summary of the worker's output, distilled by context-budget.sh
# summarize when present; else a 1-line note. The full .out stays on disk (deep-dive).
digest_summary() {
  local stage="$1" slice="$2" cb summary=""
  cb="$SCRIPT_DIR/context-budget.sh"
  if [ -x "$cb" ] && grep -q 'summarize)' "$cb" 2>/dev/null; then
    summary="$("$cb" summarize --ws "$WS" --stage "$stage" --slice "$slice" 2>/dev/null || true)"
  fi
  [ -n "$summary" ] || summary="(worker $slice finished — see deep-dive)"
  printf '%s' "$summary"
}
# Append `## <slice>` + summary + deep-dive link to _fleet/digest.md. Idempotent:
# skip if a `## <slice>` section already exists (append-once per slice).
digest_append() {
  local stage="$1" slice="$2" digest="$WS/_fleet/digest.md"
  [ -f "$digest" ] && grep -qxF "## $slice" "$digest" && return 0
  mkdir -p "$WS/_fleet"
  local summary; summary="$(digest_summary "$stage" "$slice")"
  printf '## %s\n%s\n\n[deep-dive](../stages/%s/output/%s.out)\n\n' "$slice" "$summary" "$stage" "$slice" >> "$digest"
  log "digest += $slice"
}

# ---------- collect a finished worker ----------------------------------------
collect_slice() {
  local stage="$1" slice="$2" pane="$3"
  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] would collect $slice (pane $pane → stages/$stage/output/$slice.out + digest)"
    ledger_set "$slice" 7 "yes"; return 0   # shadow ledger only
  fi
  local out="$WS/stages/$stage/output/$slice.out"
  mkdir -p "$WS/stages/$stage/output"
  # `herdr ... read` prints the raw JSON socket envelope — extract the text payload.
  herdr agent read "$pane" --source recent-unwrapped --lines 300 2>/dev/null \
    | jq -r '.result.read.text // empty' > "$out" 2>/dev/null || true
  [ -s "$out" ] || herdr agent read "$pane" --source recent-unwrapped --lines 300 > "$out" 2>/dev/null || true
  ledger_set "$slice" 7 "yes"
  nudge_clear "$slice"
  log "collected $slice → stages/$stage/output/$slice.out"
  digest_append "$stage" "$slice"
}

# ---------- tick: one reconciliation pass ------------------------------------
tick() {
  resolve_ws
  REPO="$(conf_get REPO)"; BASE="$(conf_get BASE)"; BASE="${BASE:-main}"
  WORKER_DEFAULT="$(conf_get WORKER_DEFAULT)"; WORKER_DEFAULT="${WORKER_DEFAULT:-codex}"
  rm -f "$(FLEET_STATE)/.needs_review"
  observe || { echo "STATUS: ERROR (cannot observe fleet)"; return 1; }
  drain_inbox
  if [ -f "$WS/_fleet/paused" ]; then echo "STATUS: PAUSED"; return 0; fi
  # CRITICAL context crossing (set by the budget hook): don't silently loop — yield so
  # the orchestrator (or `herd-loop.sh rotate`) can reboot the session from the pointer.
  if [ -f "$WS/_fleet/.needs_rotation" ]; then echo "STATUS: NEEDS_ROTATION"; return 0; fi

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
        working) nudge_clear "$slice" ;;   # progressing again → reset the nudge cap
        blocked) handle_blocked "$stage" "$slice" "$pane" ;;
        idle|done)
          if [ "$collected" = "yes" ]; then :
          elif worker_done "$wt" "$status"; then collect_slice "$stage" "$slice" "$pane"
          else
            # idle + not done = the prompt was dropped (TUI not ready at spawn) or is
            # sitting unsubmitted. Re-send the pointer + Enter — but only NUDGE_MAX
            # times; an analysis-only or stuck slice then goes to review, not an
            # infinite nudge loop.
            local nn; nn="$(nudge_count "$slice")"
            if [ "${nn:-0}" -ge "$NUDGE_MAX" ]; then
              review_note "$stage" "$slice" \
                "# $slice: idle with no completion signal after $NUDGE_MAX nudges" \
                "" \
                "No commits beyond base and no REPORT.md in $wt." \
                "Investigate the pane ($pane), then KILL/RESCOPE via inbox/STEER.md or collect manually."
              needs_review stalled; log "STALLED $slice (nudged $nn×, no progress) → review"
            else
              submit_prompt "$pane" "$WS/stages/$stage/prompts/$slice.md"
              nudge_bump "$slice" "$((nn+1))"
              log "nudged $slice (resend prompt, $((nn+1))/$NUDGE_MAX)"
            fi
          fi ;;
        gone)    # pane vanished. If it finished before dying, salvage it; else escalate.
                 if [ "$collected" != "yes" ] && worker_done "$wt" "$status"; then collect_slice "$stage" "$slice" "$pane"
                 elif [ "$collected" != "yes" ]; then
                   review_note "$stage" "$slice" "# $slice: worker pane died before committing — re-dispatch (KILL then RESCOPE) or investigate"
                   needs_review errored; log "GONE slice $slice → review"
                 fi ;;
        error)   review_note "$stage" "$slice" "# error: $slice failed to spawn/run — see ledger"
                 needs_review errored; log "ERROR slice $slice → review" ;;
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
    if [ -f "$(FLEET_STATE)/.needs_review" ]; then echo "STATUS: NEEDS_REVIEW"; return 0; fi
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
      if [ "$DRY_RUN" -eq 1 ]; then
        log "[dry-run] would auto-advance past $stage"; echo "STATUS: STAGE_COMPLETE"; return 0
      fi
      advance && { echo "STATUS: ADVANCED → $(active)"; return 0; }
    fi
    [ "$DRY_RUN" -eq 1 ] || herdr notification show "herd: $stage complete" --body "review $WS/stages/$stage/output then advance" >/dev/null 2>&1 || true
    echo "STATUS: STAGE_COMPLETE"
  fi
}

# ---------- advance: active stage → its handoff ------------------------------
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

# ---------- rotate: retire the old orchestrator, boot a fresh one -------------
# Enforced context reorg by restart: start a fresh orchestrator (same agent as the
# retiring pane, or ORCH_AGENT= from herd.conf — never a hardcoded binary) that boots
# from the spilled pointer + digest, then close the old pane. REFUSES to close an
# empty pane, $SELF, an ambiguous self, or the freshly-started pane. --dry-run
# spawns/closes nothing.
rotate() {
  resolve_ws
  REPO="$(conf_get REPO)"
  observe >/dev/null 2>&1 || true            # refresh _fleet/self + agents.json
  local self; self="$(cat "$(SELF_FILE)" 2>/dev/null || true)"
  # old orchestrator pane: --orchestrator wins, else _fleet/orchestrator on disk.
  local old="$ORCH"
  [ -n "$old" ] || old="$(cat "$WS/_fleet/orchestrator" 2>/dev/null || true)"

  # --- refuse before touching anything -----------------------------------------
  if [ -z "$old" ]; then
    echo "rotate: REFUSING — no old orchestrator pane (pass --orchestrator PANE or write $WS/_fleet/orchestrator)" >&2
    exit 2
  fi
  if [ "$SELF_STATE" = "ambiguous" ]; then
    echo "rotate: REFUSING — cannot resolve own pane unambiguously (fail safe: might close self)" >&2
    exit 2
  fi
  if [ -n "$self" ] && [ "$old" = "$self" ]; then
    echo "rotate: REFUSING — orchestrator pane ($old) is \$SELF, the loop's own pane" >&2
    exit 2
  fi
  # replacement agent: ORCH_AGENT= in herd.conf wins, else the retiring pane's own
  # agent from the fleet snapshot (the orchestrator row's own agent — not hardcoded).
  local agent; agent="$(conf_get ORCH_AGENT)"
  [ -n "$agent" ] || agent="$(jq -r --arg p "$old" '[.result.agents[] | select(.pane_id==$p)] | first | .agent // empty' "$(AGENTS_JSON)" 2>/dev/null || true)"
  if [ -z "$agent" ]; then
    echo "rotate: REFUSING — cannot derive replacement agent (old pane $old not in agent list; set ORCH_AGENT= in herd.conf)" >&2
    exit 2
  fi
  local av bin flag; av="$(worker_argv "$agent")"; bin="${av%%$'\t'*}"; flag="${av##*$'\t'}"
  if [ -z "$bin" ] || ! command -v "$bin" >/dev/null 2>&1; then
    echo "rotate: REFUSING — replacement agent binary '$bin' not on PATH" >&2; exit 2
  fi
  # unique herdr agent name per rotation: <agent>-r2, <agent>-r3, ...
  local rc name; rc="$(cat "$WS/_fleet/rotation_count" 2>/dev/null || echo 1)"
  case "$rc" in ''|*[!0-9]*) rc=1 ;; esac
  name="$agent-r$((rc+1))"

  log "rotate plan:"
  log "  old orchestrator pane : $old"
  log "  repo                  : ${REPO:-<unset>}"
  log "  start new             : herdr agent start $name --cwd \"$REPO\" --no-focus -- $bin${flag:+ $flag}"
  log "  resume pointer        : $WS/_fleet/context_pointer.md + $WS/_fleet/digest.md"

  if [ "$DRY_RUN" -eq 1 ]; then
    log "  [dry-run] would send the resume pointer to the new pane"
    log "  [dry-run] would re-resolve the new pane by cwd from 'herdr agent list'"
    log "  [dry-run] would poll (a few tries) until the new pane is listed"
    log "  [dry-run] would: herdr pane close $old"
    log "  [dry-run] would record the new pane, bump rotation_count, clear $WS/_fleet/.needs_rotation"
    log "rotate: dry-run complete — spawned/closed nothing"
    return 0
  fi

  local reported new
  reported="$(herdr agent start "$name" --cwd "$REPO" --no-focus -- "$(command -v "$bin")" $flag 2>/dev/null | jq -r '.result.agent.pane_id // empty')"
  # binding rule: agent start's pane_id can be off by one — re-resolve by cwd.
  new="$(resolve_pane_by_cwd "$REPO" "$name")"
  if [ -z "$new" ]; then
    new="$reported"
    [ -n "$new" ] && log "! could not re-resolve new pane by cwd — falling back to reported id $new"
  fi
  if [ -z "$new" ] || [ "$new" = "null" ]; then echo "rotate: agent start failed" >&2; exit 1; fi
  if [ "$new" = "$old" ]; then
    echo "rotate: REFUSING — new pane ($new) equals old pane; not closing anything" >&2
    exit 1
  fi
  log "started new orchestrator (pane $new, $name)"
  herdr agent send "$new" "You are the herd orchestrator; resume from $WS/_fleet/context_pointer.md and $WS/_fleet/digest.md and continue the loop." >/dev/null 2>&1 || true

  # poll (a few tries) until the new pane is actually listed before retiring the old one.
  local listed=0
  for _ in 1 2 3 4 5; do
    if herdr agent list 2>/dev/null | jq -e --arg p "$new" '.result.agents[]|select(.pane_id==$p)' >/dev/null 2>&1; then listed=1; break; fi
    sleep 1
  done
  if [ "$listed" -ne 1 ]; then
    echo "rotate: new pane $new never appeared in agent list — NOT closing old pane $old" >&2
    exit 1
  fi

  herdr pane close "$old" >/dev/null 2>&1 || true
  log "closed old orchestrator (pane $old)"
  # Record the new pane so the NEXT rotation retires it, not the stale (renumbered) old id.
  printf '%s\n' "$new" > "$WS/_fleet/orchestrator"
  echo "$((rc+1))" > "$WS/_fleet/rotation_count"
  rm -f "$WS/_fleet/.needs_rotation"
  log "rotate: complete — new orchestrator $new ($name), retired $old"
}

# ---------- run: standing loop -----------------------------------------------
run() {
  resolve_ws
  # --auto-rotate needs to know which pane the orchestrator is; warn early if it can't.
  if [ "$AUTO_ROTATE" -eq 1 ] && [ -z "$ORCH" ] && [ ! -f "$WS/_fleet/orchestrator" ]; then
    log "! --auto-rotate set but no orchestrator pane known (pass --orchestrator PANE or write $WS/_fleet/orchestrator); rotations will refuse and the loop will yield instead"
  fi
  local n=0 rots=0 bad=0
  while true; do
    local out st=""
    out="$(tick || true)"; printf '%s\n' "$out"
    case "$out" in *"STATUS: "*) st="${out##*STATUS: }" ;; esac
    case "$st" in
      NEEDS_ROTATION)
        bad=0
        if [ "$AUTO_ROTATE" -ne 1 ]; then log "loop yields on: $st"; break; fi
        if [ "$MAX_ROTATIONS" -gt 0 ] && [ "$rots" -ge "$MAX_ROTATIONS" ]; then
          log "auto-rotate: cap ($MAX_ROTATIONS) reached — yielding for human"; log "loop yields on: $st"; break
        fi
        log "auto-rotate: NEEDS_ROTATION → rotating (#$((rots+1)))"
        # Subshell contains rotate's `exit` on a REFUSE so a bad rotate can't kill the loop;
        # its filesystem/herdr side effects (spawn, close, clear .needs_rotation) still persist.
        if ( rotate ); then
          # rotate recorded the new pane in _fleet/orchestrator; drop the stale --orchestrator
          # override so the next rotation resolves from disk instead of the closed pane id.
          ORCH=""
          rots=$((rots+1)); log "auto-rotate: rotated (#$rots); continuing loop"
        else
          log "auto-rotate: rotate refused/failed — yielding for human"; log "loop yields on: $st"; break
        fi ;;
      DONE|NEEDS_REVIEW|AWAITING_SOLO|STAGE_COMPLETE|PAUSED|ERROR*) log "loop yields on: $st"; break ;;
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

# ---------- init: scaffold a workspace from the template ---------------------
init() {
  [ -n "$WS" ] || { echo "init needs --ws DIR" >&2; exit 2; }
  [ -n "$REPO" ] || { echo "init needs --repo PATH" >&2; exit 2; }
  local tmpl; tmpl="$(cd "$SCRIPT_DIR/../templates/herd-control" && pwd)"
  # never cp -R over a LIVE workspace by accident; --force refreshes templates but
  # preserves runtime state (active_stage, ledger).
  if [ -f "$WS/AGENT.md" ] || [ -f "$WS/herd.conf" ] || [ -d "$WS/_fleet" ]; then
    if [ "$FORCE" -ne 1 ]; then
      echo "init: REFUSING — $WS already looks like a herd-control workspace (re-run with --force to refresh templates; active_stage + ledger are preserved)" >&2
      exit 2
    fi
    log "init --force: refreshing templates over $WS (preserving active_stage + ledger)"
  fi
  local prev_stage=""; prev_stage="$(cat "$WS/_fleet/active_stage" 2>/dev/null || true)"
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
# rotate: replacement orchestrator agent (default: the retiring pane's own agent)
# ORCH_AGENT=hermes
EOF
  mkdir -p "$WS/_fleet"
  if [ -n "$prev_stage" ]; then printf '%s\n' "$prev_stage" > "$WS/_fleet/active_stage"
  else echo "01_spec" > "$WS/_fleet/active_stage"; fi
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
  observe) resolve_ws; observe; echo "observed → $(AGENTS_JSON)" ;;
  tick)    tick ;;
  run)     run ;;
  advance) advance ;;
  rotate)  rotate ;;
  status)  status ;;
  help|*)  sed -n '2,24p' "$0" ;;
esac
