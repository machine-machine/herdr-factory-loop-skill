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
#   m2herd-up.sh dispatch --slice S [--repo P] [--base BRANCH] [--agent claude|codex|cursor|opencode]
#                         [--runner pane|headless] [--headless [--model M]]
#                                                   # worktree wip/m2herd-<S> off BASE (default: workers.base, else current branch), spawn worker,
#                                                   # file-protocol dispatch of .m2herd/dispatch/S.task.md, record in overview.json workers[]
#                                                   # --headless: no pane/TUI — `claude -p --model M` (default sonnet), `codex exec`, or `opencode run`
#                                                   #   in the worktree via nohup; log → dispatch/S.log, stderr → dispatch/S.stderr.log,
#                                                   #   answer → dispatch/S.out.md;
#                                                   #   usage (tokens/cost) parsed into workers[] at collect. Cheap hands, Fable judgment.
#   m2herd-up.sh collect  --slice S [--repo P] [--no-verify]
#                                                   # wait idle (pane) / exited (headless pid), keep/copy report to dispatch/S.out.md,
#                                                   # update workers[] state (+tokens/cost for headless). Then the VERIFY GATE runs an
#                                                   #   INDEPENDENT check in the worker's worktree (workers have fabricated "ALL_OK"
#                                                   #   claims before — never trust the report alone): command = task-file `verify:`
#                                                   #   line > settings workers.verify_cmd > `bash scripts/lint.sh` when that file
#                                                   #   exists in the worktree; bounded (timeout 300s); output →
#                                                   #   runs/<run>/slices/S/verify.log; verified true|false + verify_cmd recorded in
#                                                   #   status.json; on fail the slice is FAILED (+ failures.json entry).
#                                                   #   --no-verify skips the gate (logged loudly).
#   m2herd-up.sh watch    [--repo P] [--interval 60] [--max-resumes 3] [--once]
#                                                   # SENTINEL: reconcile loop over workers[] in state spawned|working — encodes the
#                                                   #   babysitting runs 1-3 needed by hand. Per TUI worker each tick: read the pane
#                                                   #   (lines joined so wrap can't split a signature) + agent_status, then ladder:
#                                                   #   crash signature (stream disconnected / Transport error / ECONNRESET / Unable to
#                                                   #     connect to API) while not working → resume nudge (agent send, settle, Enter);
#                                                   #   rate-limit menu ("What do you want to do?" + "limit to reset") → Enter (accept
#                                                   #     stop-and-wait default), log the reset time when visible;
#                                                   #   blocked on approval → escalate only ("WATCH: <slice> blocked on approval —
#                                                   #     needs human/orchestrator"), NEVER auto-approve (deny/allow policy is
#                                                   #     herd-loop's job);
#                                                   #   idle + committed + report present → run the normal collect path;
#                                                   #   idle + no commit (git log <base>..HEAD empty, porcelain clean) → stall nudge.
#                                                   #   Resume count lives in the trace status.json ("resumes": N); past --max-resumes
#                                                   #   the worker is marked failed (locked write) and left alone. Headless workers:
#                                                   #   pid + log-tail check; a crash signature = failed at once (claude -p can't
#                                                   #   resume). Never touches $SELF or panes not recorded in workers[]. --once =
#                                                   #   single pass (orchestrator/scripted use); default loops until every watched
#                                                   #   worker is done|failed. One status line per tick:
#                                                   #   WATCH: <slice>=<state>[/<signature>] …   Exit 0 all done, 1 if any failed.
#   m2herd-up.sh down     [--slice S | --all] [--repo P] [--force]
#                                                   # tear worker(s) down: close pane (never $SELF; unknown self = fail safe),
#                                                   #   remove worktree (dirty ones only with --force), delete branch when merged
#                                                   #   (else kept + reported), set workers[] state=down. Idempotent.
#                                                   #   retry a slice = clean `down --slice S`, then dispatch it again.
#   m2herd-up.sh --dry-run <same args>              # print every herdr/git command instead of running it
#
# Settings: .m2herd/settings.json is read-only config here; missing/invalid
# values fall back to built-ins. Keys follow the settled engine schema
# (m2herd.sh config): workers.agent, workers.max, workers.model, workers.base,
# workers.runner, workers.settle_seconds, workers.wait_timeout_minutes,
# workers.verify_cmd. routing[].pattern uses bash `case "$slice" in $pattern)`
# glob semantics (optional agent/runner/model per rule), and the first matching
# routing rule wins. Precedence: CLI flag > routing > workers defaults.
#
# Binding herdr rules (from CONTRACT-m2herd.md): identify $SELF first and never
# touch it; after `agent start` RE-RESOLVE the pane by cwd from `herdr agent list`
# (the returned pane_id can be off by one); no `--split` (stray-pane bug); settle
# before `agent send` Enter submission. Idempotent. Safe to re-run.
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
REPO=""; GOAL=""; SLICE=""; BASE=""; AGENT=""; HEADLESS=0; MODEL=""; RUNNER=""; ROOM_ONLY=0
ALL=0; FORCE=0; NO_VERIFY=0; INTERVAL=""; MAX_RESUMES=""; ONCE=0
BASE_EXPLICIT=0; AGENT_EXPLICIT=0; MODEL_EXPLICIT=0; RUNNER_EXPLICIT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --goal) GOAL="$2"; shift 2 ;;
    --slice) SLICE="$2"; shift 2 ;;
    --base) BASE="$2"; BASE_EXPLICIT=1; shift 2 ;;
    --agent) AGENT="$2"; AGENT_EXPLICIT=1; shift 2 ;;
    --headless) HEADLESS=1; RUNNER="headless"; RUNNER_EXPLICIT=1; shift ;;
    --runner) RUNNER="$2"; RUNNER_EXPLICIT=1; shift 2 ;;
    --room-only) ROOM_ONLY=1; shift ;;
    --all) ALL=1; shift ;;
    --force) FORCE=1; shift ;;
    --no-verify) NO_VERIFY=1; shift ;;
    --interval) INTERVAL="$2"; shift 2 ;;
    --max-resumes) MAX_RESUMES="$2"; shift 2 ;;
    --once) ONCE=1; shift ;;
    --model) MODEL="$2"; MODEL_EXPLICIT=1; shift 2 ;;
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
BUILTIN_AGENT="claude"
BUILTIN_RUNNER="pane"
BUILTIN_MAX_CONCURRENT=4
BUILTIN_SETTLE_SECONDS=2
BUILTIN_WAIT_TIMEOUT_MINUTES=30
BUILTIN_WATCH_INTERVAL=60
BUILTIN_MAX_RESUMES=3
SUBMIT_SETTLE="$BUILTIN_SETTLE_SECONDS"             # settle between `agent send` and Enter
WAIT_TIMEOUT=$((BUILTIN_WAIT_TIMEOUT_MINUTES * 60 * 1000)) # collect: ms to wait for worker idle

log()        { printf '  %s\n' "$*"; }
plan()       { log "[dry-run] $*"; }
need()       { command -v "$1" >/dev/null 2>&1 || { echo "required tool not on PATH: $1" >&2; exit 1; }; }
utc_now()    { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Central token validation (binding cross-slice convention). A slice name
# becomes filenames under .m2herd/dispatch/, the branch wip/m2herd-<S>, and
# prompt text — one gate covers all three. Pure `case` so embedded newlines
# can't sneak past a line-oriented regex tool.
validate_token() { # validate_token <what> <value>
  case "$2" in
    ''|*..*|[!A-Za-z0-9]*|*[!A-Za-z0-9._-]*)
      echo "invalid $1 '$2': must match ^[A-Za-z0-9][A-Za-z0-9._-]*\$ (no '..')" >&2
      exit 2 ;;
  esac
}

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

# Read-only settings.json helper. Missing file, invalid JSON, missing path,
# null/empty, object/array, or jq failure all return the caller's default.
settings_get() { # settings_get <jq-path> <default>
  local path="$1" default="$2" sf="$REPO/.m2herd/settings.json" v
  [ -f "$sf" ] || { printf '%s' "$default"; return 0; }
  v="$(jq -er "$path // empty | select(type == \"string\" or type == \"number\")" "$sf" 2>/dev/null || true)"
  [ -n "$v" ] || { printf '%s' "$default"; return 0; }
  printf '%s' "$v"
}

valid_agent() {
  case "$1" in claude|codex|cursor|opencode) return 0 ;; *) return 1 ;; esac
}

valid_runner() {
  case "$1" in pane|headless) return 0 ;; *) return 1 ;; esac
}

positive_int_or_default() { # positive_int_or_default <value> <default>
  case "$1" in ''|*[!0-9]*) printf '%s' "$2"; return 0 ;; esac
  [ "$1" -gt 0 ] 2>/dev/null && printf '%s' "$1" || printf '%s' "$2"
}

settings_first_route() { # settings_first_route <slice> -> first matching routing object, or empty
  local slice="$1" sf="$REPO/.m2herd/settings.json" r pat
  [ -f "$sf" ] || return 0
  jq -e . "$sf" >/dev/null 2>&1 || return 0
  while IFS= read -r r; do
    pat="$(printf '%s' "$r" | jq -r '.pattern // empty' 2>/dev/null || true)"
    [ -n "$pat" ] || continue
    case "$slice" in
      $pat) printf '%s' "$r"; return 0 ;;
    esac
  done <<EOF
$(jq -c '.routing[]? | objects' "$sf" 2>/dev/null || true)
EOF
  return 0
}

resolve_dispatch_settings() {
  local route="" route_pattern="" route_agent="" route_model="" route_runner=""
  local def_agent def_model def_runner base_setting max_raw wait_raw settle_raw wait_min

  def_agent="$(settings_get '.workers.agent' "$BUILTIN_AGENT")"
  valid_agent "$def_agent" || def_agent="$BUILTIN_AGENT"
  def_model="$(settings_get '.workers.model' "")"
  def_runner="$(settings_get '.workers.runner' "$BUILTIN_RUNNER")"
  valid_runner "$def_runner" || def_runner="$BUILTIN_RUNNER"

  if [ -n "$SLICE" ]; then
    route="$(settings_first_route "$SLICE")"
    if [ -n "$route" ]; then
      route_pattern="$(printf '%s' "$route" | jq -r '.pattern // empty')"
      route_agent="$(printf '%s' "$route" | jq -r '.agent // empty')"
      route_model="$(printf '%s' "$route" | jq -r '.model // empty')"
      route_runner="$(printf '%s' "$route" | jq -r '.runner // empty')"
      valid_agent "$route_agent" || route_agent=""
      valid_runner "$route_runner" || route_runner=""
    fi
  fi

  if [ "$AGENT_EXPLICIT" -eq 1 ]; then
    valid_agent "$AGENT" || { echo "invalid --agent '$AGENT' (expected claude|codex|cursor|opencode)" >&2; exit 2; }
    AGENT_SOURCE="cli"
  elif [ -n "$route_agent" ]; then
    AGENT="$route_agent"; AGENT_SOURCE="routing: $route_pattern"
  else
    AGENT="$def_agent"; AGENT_SOURCE="workers.agent"
  fi

  if [ "$MODEL_EXPLICIT" -eq 1 ]; then
    MODEL_SOURCE="cli"
  elif [ -n "$route_model" ]; then
    MODEL="$route_model"; MODEL_SOURCE="routing: $route_pattern"
  else
    MODEL="$def_model"; MODEL_SOURCE="workers.model"
  fi

  if [ "$RUNNER_EXPLICIT" -eq 1 ]; then
    valid_runner "$RUNNER" || { echo "invalid --runner '$RUNNER' (expected pane|headless)" >&2; exit 2; }
    RUNNER_SOURCE="cli"
  elif [ -n "$route_runner" ]; then
    RUNNER="$route_runner"; RUNNER_SOURCE="routing: $route_pattern"
  else
    RUNNER="$def_runner"; RUNNER_SOURCE="workers.runner"
  fi
  case "$RUNNER" in
    headless) HEADLESS=1 ;;
    pane) HEADLESS=0 ;;
  esac

  if [ "$BASE_EXPLICIT" -eq 0 ] && [ -z "$BASE" ]; then
    base_setting="$(settings_get '.workers.base' "")"
    [ -n "$base_setting" ] && BASE="$base_setting"
  fi

  settle_raw="$(settings_get '.workers.settle_seconds' "$BUILTIN_SETTLE_SECONDS")"
  SUBMIT_SETTLE="$(positive_int_or_default "$settle_raw" "$BUILTIN_SETTLE_SECONDS")"
  wait_raw="$(settings_get '.workers.wait_timeout_minutes' "$BUILTIN_WAIT_TIMEOUT_MINUTES")"
  wait_min="$(positive_int_or_default "$wait_raw" "$BUILTIN_WAIT_TIMEOUT_MINUTES")"
  WAIT_TIMEOUT=$((wait_min * 60 * 1000))

  max_raw="$(settings_get '.workers.max' "$BUILTIN_MAX_CONCURRENT")"
  MAX_CONCURRENT="$(positive_int_or_default "$max_raw" "$BUILTIN_MAX_CONCURRENT")"
}

log_resolution() {
  log "resolution: agent=$AGENT ($AGENT_SOURCE), runner=$RUNNER ($RUNNER_SOURCE), model=${MODEL:-<default>} ($MODEL_SOURCE)"
  log "settings: settle_seconds=$SUBMIT_SETTLE, wait_timeout_minutes=$((WAIT_TIMEOUT / 60000)), max=$MAX_CONCURRENT"
}

enforce_max_concurrent() {
  local active=0
  [ -f "$OV" ] && active="$(jq -r '[.workers[]? | select(.state == "spawned" or .state == "working")] | length' "$OV" 2>/dev/null || echo 0)"
  if [ "${active:-0}" -ge "$MAX_CONCURRENT" ]; then
    echo "workers.max=$MAX_CONCURRENT reached — collect or raise: m2herd config set workers.max $((MAX_CONCURRENT + 1))" >&2
    exit 1
  fi
}

# Binding rule: identify the orchestrator's OWN pane BEFORE any send/close and
# treat it as read-only. NEVER keyed on focus (the human may be looking at any
# pane): walk THIS process's ancestry (PPid chain, bounded 15 hops — same ps
# idiom as inside_herdr) and for every ancestor whose command name looks like an
# agent binary, match its cwd against `herdr agent list`. Exactly one agent at
# that cwd → that pane is $SELF. Zero everywhere / ambiguous / fleet unreachable
# → $SELF stays EMPTY, which means UNKNOWN (not "no pane"): destructive ops must
# go through maybe_self(), which fails safe by treating unknown as "could be me".
SELF=""
resolve_self() {
  SELF=""
  local agents pid=$$ hops=0 comm cwd ppid n
  agents="$(herdr agent list 2>/dev/null | jq -c '[.result.agents[]? | {pane_id, cwd}]' 2>/dev/null || true)"
  if [ -z "$agents" ] || [ "$agents" = "[]" ] || [ "$agents" = "null" ]; then
    return 0   # fleet unreachable or no agents — $SELF stays unknown
  fi
  while [ "$hops" -lt 15 ]; do
    comm="$(ps -o comm= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
    cwd="$(readlink "/proc/$pid/cwd" 2>/dev/null || true)"
    if [ -n "$cwd" ]; then
      case "$comm" in
        *claude*|*codex*|*cursor*|*opencode*|*hermes*)
          n="$(printf '%s' "$agents" | jq -r --arg c "$cwd" '[.[] | select(.cwd==$c)] | length' 2>/dev/null || echo 0)"
          if [ "${n:-0}" -eq 1 ]; then
            SELF="$(printf '%s' "$agents" | jq -r --arg c "$cwd" \
              '[.[] | select(.cwd==$c)] | first | .pane_id // empty' 2>/dev/null || true)"
            return 0
          elif [ "${n:-0}" -gt 1 ]; then
            log "! self resolution ambiguous: $n agents share cwd $cwd — \$SELF stays unknown (fail safe)"
            return 0
          fi
          ;;
      esac
    fi
    ppid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
    [ -n "$ppid" ] || break
    [ "$ppid" -le 1 ] 2>/dev/null && break
    pid="$ppid"; hops=$((hops + 1))
  done
  return 0
}
is_self() { [ -n "$SELF" ] && [ "$1" = "$SELF" ]; }
# Fail-safe self test for DESTRUCTIVE ops (pane close): unknown $SELF counts as
# "could be me" — returns 0 (refuse) and logs why.
maybe_self() {
  if [ -z "$SELF" ]; then
    log "! \$SELF unresolved — treating pane $1 as possibly-self (fail safe)"
    return 0
  fi
  [ "$1" = "$SELF" ]
}

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

# Workspace for this repo, by the SAME label up() creates (m2herd:<basename>);
# falls back to any pane cwd'd at the repo; creates the workspace when missing.
# The fallback `agent start` must ALWAYS pass --workspace — without it herdr
# drops the worker into whatever workspace the human happens to have focused.
resolve_repo_ws() { # -> workspace_id or empty
  local label="m2herd:$(basename "$REPO")" ws
  ws="$(herdr workspace list 2>/dev/null | jq -r --arg l "$label" \
    '[.result.workspaces[]? | select((.label // "")==$l)] | first | .workspace_id // empty' 2>/dev/null || true)"
  [ -n "$ws" ] || ws="$(herdr pane list 2>/dev/null | jq -r --arg c "$REPO" \
    '[.result.panes[] | select(.cwd==$c)] | first | .workspace_id // empty' 2>/dev/null || true)"
  if [ -z "$ws" ]; then
    herdr workspace create --cwd "$REPO" --label "$label" --no-focus >/dev/null 2>&1 || true
    ws="$(herdr workspace list 2>/dev/null | jq -r --arg l "$label" \
      '[.result.workspaces[]? | select((.label // "")==$l)] | first | .workspace_id // empty' 2>/dev/null || true)"
    [ -n "$ws" ] || ws="$(herdr pane list 2>/dev/null | jq -r --arg c "$REPO" \
      '[.result.panes[] | select(.cwd==$c)] | first | .workspace_id // empty' 2>/dev/null || true)"
  fi
  printf '%s' "$ws"
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
# Locked RMW (binding cross-slice convention): flock on $OV.lock serializes
# every writer (m2herd.sh uses the same lock file); the tmp file lives in the
# SAME dir as $OV so mv is an atomic rename, never a cross-filesystem copy; the
# tmp is removed on failure. Stock macOS has no flock — degrade to the atomic
# rename alone. jq args + filter pass straight through; $OV is appended here.
ov_update() { # ov_update <jq args…> '<filter>'
  local dir tmp lock="$OV.lock"
  dir="$(dirname "$OV")"
  tmp="$(mktemp "$dir/.overview.json.tmp.XXXXXX")" || return 1
  if command -v flock >/dev/null 2>&1; then
    if ( flock -w 30 9 && jq "$@" "$OV" > "$tmp" && mv "$tmp" "$OV" ) 9>>"$lock"; then return 0; fi
  else
    if jq "$@" "$OV" > "$tmp" && mv "$tmp" "$OV"; then return 0; fi
  fi
  rm -f "$tmp"
  return 1
}

record_worker() { # record_worker <slice> <pane> <worktree> <branch> <state> [mode] [model] [pid] [pid_start] [pid_comm]
  local slice="$1" pane="$2" wt="$3" branch="$4" state="$5" mode="${6:-tui}" model="${7:-}" pid="${8:-}" pid_start="${9:-}" pid_comm="${10:-}"
  if [ "$DRY_RUN" -eq 1 ]; then
    plan "jq rewrite $OV (locked): workers[] += {slice:\"$slice\", pane_id:\"$pane\", mode:\"$mode\", agent:\"$AGENT\"${model:+, model:\"$model\"}${pid:+, pid:$pid}, worktree:\"$wt\", branch:\"$branch\", state:\"$state\", …}"
    return 0
  fi
  [ -f "$OV" ] || { echo "no overview.json at $OV (run: m2herd-up.sh up --repo $REPO)" >&2; exit 1; }
  ov_update --arg slice "$slice" --arg pane "$pane" --arg wt "$wt" --arg br "$branch" \
     --arg st "$state" --arg ts "$(utc_now)" --arg mode "$mode" --arg agent "$AGENT" \
     --arg model "$model" --arg pid "$pid" --arg pstart "$pid_start" --arg pcomm "$pid_comm" '
    .workers = ((.workers // []) | map(select(.slice != $slice))) + [({
      slice: $slice, pane_id: $pane, worktree: $wt, branch: $br, state: $st, mode: $mode, agent: $agent,
      task: (".m2herd/dispatch/" + $slice + ".task.md"),
      out:  (".m2herd/dispatch/" + $slice + ".out.md") }
      + (if $model != "" then {model: $model} else {} end)
      + (if $pid != "" then {pid: ($pid | tonumber)} else {} end)
      + (if $pstart != "" then {pid_start: $pstart} else {} end)
      + (if $pcomm != "" then {pid_comm: $pcomm} else {} end))]
    | .updated_at = $ts
  ' || { echo "overview.json update failed (lock timeout or jq error)" >&2; exit 1; }
}

set_worker_usage() { # set_worker_usage <slice> <output_tokens> <cost_usd> — best-effort
  local slice="$1" tok="$2" cost="$3"
  [ "$DRY_RUN" -eq 1 ] && { plan "jq rewrite $OV (locked): workers[slice==$slice] += {tokens:$tok, cost_usd:$cost}"; return 0; }
  [ -f "$OV" ] || return 0
  ov_update --arg s "$slice" --arg tok "$tok" --arg cost "$cost" '
    .workers = ((.workers // []) | map(if .slice == $s then
      . + (if $tok  != "" then {tokens:   ($tok  | tonumber)} else {} end)
        + (if $cost != "" then {cost_usd: ($cost | tonumber)} else {} end)
    else . end))
  ' || log "! usage update failed for $slice (non-fatal)"
}

set_worker_state() { # set_worker_state <slice> <state>
  local slice="$1" state="$2"
  if [ "$DRY_RUN" -eq 1 ]; then plan "jq rewrite $OV (locked): workers[slice==$slice].state = \"$state\""; return 0; fi
  [ -f "$OV" ] || { echo "no overview.json at $OV" >&2; exit 1; }
  ov_update --arg slice "$slice" --arg st "$state" --arg ts "$(utc_now)" '
    .workers = ((.workers // []) | map(if .slice == $slice then .state = $st else . end))
    | .updated_at = $ts
  ' || { echo "overview.json update failed (lock timeout or jq error)" >&2; exit 1; }
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
  if [ -n "$RUN_ID" ] && [ ! -f "$runs/$RUN_ID/run.json" ]; then
    # stale CURRENT (run dir wiped) — recreate the bundle so recording resumes
    # instead of silently never writing traces again
    trace_warn "CURRENT points at $RUN_ID but run.json is missing — recreating it"
    if mkdir -p "$runs/$RUN_ID/slices" 2>/dev/null; then
      goal="$(jq -r '.goal // ""' "$OV" 2>/dev/null || true)"
      jq -n --arg id "$RUN_ID" --arg ts "$(utc_now)" --arg goal "$goal" --arg base "$BASE" \
        '{run_id:$id, created_at:$ts, goal:$goal, base:$base, slices:[]}' > "$runs/$RUN_ID/run.json" 2>/dev/null \
        || { trace_warn "recreate $runs/$RUN_ID/run.json failed"; RUN_ID=""; return 1; }
    else
      trace_warn "mkdir $runs/$RUN_ID failed"; RUN_ID=""; return 1
    fi
  fi
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
  tmp="$(mktemp "$(dirname "$rj")/.run.json.tmp.XXXXXX")" || { trace_warn "mktemp for $rj failed"; return 1; }
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

# Find which run holds a slice at collect time: CURRENT counts ONLY when that
# run's run.json actually lists the slice in slices[] (a slice dispatched under
# an older run must not report into whatever run is current now); otherwise fall
# back to the lexically latest run dir containing the slice.
trace_find_run_for_slice() { # trace_find_run_for_slice <slice> -> echoes run-id or empty
  local slice="$1" runs="$REPO/.m2herd/runs" cur rid
  cur="$runs/CURRENT"
  if [ -f "$cur" ]; then
    rid="$(cat "$cur" 2>/dev/null || true)"
    if [ -n "$rid" ] && [ -f "$runs/$rid/run.json" ] \
       && jq -e --arg s "$slice" '(.slices // []) | index($s) != null' "$runs/$rid/run.json" >/dev/null 2>&1; then
      printf '%s' "$rid"; return 0
    fi
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
    local tmp; tmp="$(mktemp "$dir/.status.json.tmp.XXXXXX")" || { trace_warn "mktemp for $sj failed"; return 1; }
    jq --arg st "$state" --arg ts "$(utc_now)" --arg tok "$tok" --arg cost "$cost" '
      .state = $st | .collected_at = $ts
      | .tokens    = (if $tok  != "" then ($tok  | tonumber) else .tokens    end)
      | .cost_usd  = (if $cost != "" then ($cost | tonumber) else .cost_usd  end)
    ' "$sj" > "$tmp" 2>/dev/null && mv "$tmp" "$sj" || { rm -f "$tmp"; trace_warn "update $sj failed"; }
  else
    trace_warn "no status.json at $sj — writing a fresh one"
    jq -n --arg slice "$slice" --arg st "$state" --arg ts "$(utc_now)" --arg tok "${tok:-0}" --arg cost "${cost:-0}" \
      '{slice:$slice, state:$st, agent:"", runner:"", model:"", branch:"", worktree:"",
        dispatched_at:"", collected_at:$ts, tokens:($tok|tonumber), cost_usd:($cost|tonumber)}' \
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

# ---------- pane inspection helpers (dispatch verify + watch) ------------------
# Pane text NORMALIZED for signature matching: lowercased with ALL whitespace
# removed. The TUI hard-wraps lines mid-word ("cras\nhed"), so any newline- or
# space-preserving match can lose a signature split across a wrap — joining
# everything makes "stream disconnected" findable as "streamdisconnected" no
# matter where the wrap fell.
pane_norm_text() { # pane_norm_text <pane> [lines] -> normalized visible text
  herdr pane read "$1" --source visible --lines "${2:-200}" --format text 2>/dev/null \
    | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]' || true
}

pane_raw_text() { # pane_raw_text <pane> [lines] -> visible text, lines intact
  herdr pane read "$1" --source visible --lines "${2:-200}" --format text 2>/dev/null || true
}

agent_status_of() { # agent_status_of <pane> -> idle|working|blocked|done|unknown
  local st
  st="$(herdr agent get "$1" 2>/dev/null | jq -r '.result.agent.agent_status // empty' 2>/dev/null || true)"
  printf '%s' "${st:-unknown}"
}

# Dispatch submission VERIFY (lesson prompt_lost_after_dispatch: worker sat idle
# with the pointer stuck unsubmitted in its input; a manual re-send fixed it).
# After the pointer send: status working = submitted; pointer text still on
# screen while NOT working = unsubmitted input — re-send Enter, up to 2x.
verify_submission() { # verify_submission <pane> <pointer-text>
  local pane="$1" text="$2" frag norm status try
  is_self "$pane" && return 0
  if [ "$DRY_RUN" -eq 1 ]; then
    plan "verify submission: wait settle, re-read pane '$pane'; pointer still unsubmitted → re-send Enter (up to 2x); input empty + status working → ok"
    return 0
  fi
  frag="$(printf '%.60s' "$text" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
  for try in 1 2 3; do
    sleep "$SUBMIT_SETTLE"
    status="$(agent_status_of "$pane")"
    if [ "$status" = "working" ]; then
      log "dispatch: pointer submitted (agent working)"
      return 0
    fi
    norm="$(pane_norm_text "$pane" 60)"
    case "$norm" in
      *"$frag"*)
        if [ "$try" -le 2 ]; then
          log "dispatch: pointer still unsubmitted in pane $pane (status $status) — re-sending Enter ($try/2)"
          herdr pane send-keys "$pane" Enter >/dev/null 2>&1 || true
        else
          log "! dispatch: pointer may still be unsubmitted in pane $pane after 2 Enter re-sends — check the pane"
          return 0
        fi ;;
      *)
        log "dispatch: pane input clear (status $status) — pointer submitted"
        return 0 ;;
    esac
  done
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
  validate_token slice "$SLICE"
  resolve_repo; resolve_self
  resolve_dispatch_settings
  [ -n "$BASE" ] || BASE="$(git -C "$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)"
  local branch="wip/m2herd-$SLICE" task="$REPO/.m2herd/dispatch/$SLICE.task.md"
  if [ "$HEADLESS" -eq 1 ] && [ -z "$MODEL" ]; then
    MODEL="sonnet"
    MODEL_SOURCE="headless default"
  fi
  log "dispatch: slice=$SLICE repo=$REPO base=$BASE agent=$AGENT (self pane: ${SELF:-<unknown>})"
  log_resolution
  enforce_max_concurrent

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
    # stderr goes to its own file so the JSON log stays parseable (usage parse
    # at collect reads $lg as pure JSON for claude).
    local out="$REPO/.m2herd/dispatch/$SLICE.out.md" lg="$REPO/.m2herd/dispatch/$SLICE.log"
    local errlg="$REPO/.m2herd/dispatch/$SLICE.stderr.log" hpid="" hstart="" hcomm="" wtask
    wtask="$(copy_task_into_wt "$wt")"
    local hprompt="$(confinement_line "$wt" "$branch") Read $wtask and follow its instructions exactly. Write your complete report to $out when done (the report file is the ONLY thing you write outside the worktree).$(lessons_pointer_suffix)"
    if [ "$DRY_RUN" -eq 1 ]; then
      case "$AGENT" in
        claude)   plan "cd '$wt' && nohup claude -p '<pointer>' --model '$MODEL' --dangerously-skip-permissions --output-format json > '$lg' 2> '$errlg' &" ;;
        codex)    plan "cd '$wt' && nohup codex exec --dangerously-bypass-approvals-and-sandbox '<pointer>' > '$lg' 2> '$errlg' &" ;;
        opencode) plan "cd '$wt' && nohup opencode run '<pointer>' > '$lg' 2> '$errlg' &" ;;
      esac
      plan "record pid + its start-time/comm (ps -o lstart=/-o comm=) so collect can verify the pid was not recycled"
      record_worker "$SLICE" "-" "$wt" "$branch" "spawned" "headless" "$MODEL" ""
      trace_dispatch_write "$SLICE" "headless" "$MODEL" "$branch" "$wt" || true
      log "dispatch: dry-run headless plan complete for $SLICE"
      return 0
    fi
    case "$AGENT" in
      claude)   ( cd "$wt" && nohup claude -p "$hprompt" --model "$MODEL" --dangerously-skip-permissions --output-format json > "$lg" 2> "$errlg" & echo $! > "$lg.pid" ) ;;
      codex)    ( cd "$wt" && nohup codex exec --dangerously-bypass-approvals-and-sandbox "$hprompt" > "$lg" 2> "$errlg" & echo $! > "$lg.pid" ) ;;
      opencode) ( cd "$wt" && nohup opencode run "$hprompt" > "$lg" 2> "$errlg" & echo $! > "$lg.pid" ) ;;
    esac
    hpid="$(cat "$lg.pid" 2>/dev/null || true)"; rm -f "$lg.pid"
    [ -n "$hpid" ] || { echo "headless spawn failed (no pid) — see $lg / $errlg" >&2; exit 1; }
    # pin the pid's identity NOW: start-time + comm let collect prove the pid it
    # waits on is still OUR worker, not a recycled pid (fix: recycled-pid hang)
    hstart="$(ps -o lstart= -p "$hpid" 2>/dev/null | tr -s ' ' | sed 's/^ //;s/ $//' || true)"
    hcomm="$(ps -o comm= -p "$hpid" 2>/dev/null | tr -d ' ' || true)"
    record_worker "$SLICE" "-" "$wt" "$branch" "spawned" "headless" "$MODEL" "$hpid" "$hstart" "$hcomm"
    trace_dispatch_write "$SLICE" "headless" "$MODEL" "$branch" "$wt" || true
    log "dispatch: done — $SLICE headless ($AGENT/$MODEL, pid $hpid), log $lg, stderr $errlg"
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

  # Name/cwd matching is brittle: the orchestrator pane's REGISTERED cwd can
  # differ from $REPO (pane born elsewhere, orchestrator cd'd later). When the
  # ancestor-walk self-identity resolved $SELF, this session IS the orchestrator
  # — use $SELF's tab as the orchestrator tab.
  if { [ -z "$orch_pane" ] || [ -z "$orch_tab" ]; } && [ -n "$SELF" ]; then
    orch_pane="$SELF"
    orch_tab="$(pane_tab_id "$SELF")"
    [ -n "$orch_tab" ] && log "orchestrator unresolved by name/cwd — using \$SELF pane $SELF (tab $orch_tab)"
  fi

  if [ -z "$orch_pane" ] || [ -z "$orch_tab" ]; then
    # FALLBACK: orchestrator pane unresolvable (up never ran, not in a workspace,
    # room-only session name mismatch, fleet unreachable) — `agent start
    # --no-focus`, pinned to the repo's workspace by label (created if missing):
    # never let the worker land in whatever workspace the human has focused.
    local ws
    if [ "$DRY_RUN" -eq 1 ]; then
      log "! orchestrator pane unresolved (pane='${orch_pane:-}' tab='${orch_tab:-}') — falling back to 'agent start --no-focus'"
      plan "resolve/create workspace by label 'm2herd:$(basename "$REPO")' (herdr workspace list/create)"
      plan "herdr agent start '$wname' --workspace '<ws>' --cwd '$wt' --no-focus -- \"\$(command -v $bin)\" $flag"
      plan "re-resolve worker pane by cwd from 'herdr agent list' (returned pane_id can be off by one)"
      pane="PANE-DRYRUN"
    else
      ws="$(resolve_repo_ws)"
      [ -n "$ws" ] || { echo "cannot resolve or create workspace 'm2herd:$(basename "$REPO")' (herdr server up?)" >&2; exit 1; }
      log "! orchestrator pane unresolved (pane='${orch_pane:-}' tab='${orch_tab:-}') — falling back to 'agent start --no-focus' in workspace $ws"
      herdr agent start "$wname" --workspace "$ws" --cwd "$wt" --no-focus -- "$(command -v "$bin")" $flag >/dev/null 2>&1 || true
      pane="$(resolve_pane_by_cwd "$wt" "$wname")"
      [ -n "$pane" ] || { echo "worker pane never appeared in agent list (cwd $wt)" >&2; exit 1; }
      is_self "$pane" && { echo "resolved worker pane is \$SELF ($pane) — refusing" >&2; exit 1; }
      log "worker spawned (fallback): pane $pane ($wname) in workspace $ws"
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
  local wtask2 pointer
  wtask2="$(copy_task_into_wt "$wt")"
  pointer="$(confinement_line "$wt" "$branch") Read $wtask2 and follow its instructions exactly.$(lessons_pointer_suffix)"
  submit_pointer "$pane" "$pointer"
  verify_submission "$pane" "$pointer"

  # 4. record in overview.json workers[]
  record_worker "$SLICE" "$pane" "$wt" "$branch" "spawned"
  trace_dispatch_write "$SLICE" "pane" "" "$branch" "$wt" || true
  log "dispatch: done — $SLICE recorded in overview.json (state=spawned)"
}

# ---------- verify gate (collect) ----------------------------------------------
# Independent verification AFTER the report lands and BEFORE any down: workers
# have fabricated "go build/vet ALL_OK" with no go toolchain on the machine —
# never trust the report alone. Command source, first hit wins:
#   1. a literal `verify: <command>` line near the top of the slice's task file
#   2. settings workers.verify_cmd
#   3. `bash scripts/lint.sh` when scripts/lint.sh exists in the worktree
verify_cmd_for_slice() { # verify_cmd_for_slice <slice> <wt> -> echoes command, or empty
  local slice="$1" wt="$2" task="$REPO/.m2herd/dispatch/$slice.task.md" cmd=""
  [ -f "$task" ] && cmd="$(head -20 "$task" | sed -n 's/^[Vv]erify:[[:space:]]*//p' | head -1)"
  [ -n "$cmd" ] || cmd="$(settings_get '.workers.verify_cmd' "")"
  if [ -z "$cmd" ] && [ -n "$wt" ] && [ -f "$wt/scripts/lint.sh" ]; then cmd="bash scripts/lint.sh"; fi
  printf '%s' "$cmd"
}

# Run the verify command in the worker's worktree, bounded, output captured to
# runs/<run>/slices/<slice>/verify.log (dispatch/<slice>.verify.log when no run
# bundle exists). Returns the command's exit code; a missing worktree is a fail.
run_verify_cmd() { # run_verify_cmd <slice> <wt> <cmd> -> exit code of <cmd>
  local slice="$1" wt="$2" cmd="$3" rid vlog rc=0
  rid="$(trace_find_run_for_slice "$slice")"
  if [ -n "$rid" ] && mkdir -p "$REPO/.m2herd/runs/$rid/slices/$slice" 2>/dev/null; then
    vlog="$REPO/.m2herd/runs/$rid/slices/$slice/verify.log"
  else
    trace_warn "no run bundle for $slice — verify.log falls back to dispatch/"
    vlog="$REPO/.m2herd/dispatch/$slice.verify.log"
  fi
  VERIFY_LOG="$vlog"
  if [ -z "$wt" ] || [ ! -d "$wt" ]; then
    printf 'VERIFY FAILED: worktree %s is gone at collect time (%s) — cannot run: %s\n' \
      "${wt:-<none recorded>}" "$(utc_now)" "$cmd" > "$vlog" 2>/dev/null || true
    return 1
  fi
  log "collect: VERIFY GATE — running '$cmd' in $wt (timeout 300s) → $vlog"
  if command -v timeout >/dev/null 2>&1; then
    ( cd "$wt" && timeout 300 bash -c "$cmd" ) > "$vlog" 2>&1 || rc=$?
  else
    # stock macOS has no timeout(1) — run unbounded rather than not at all
    ( cd "$wt" && bash -c "$cmd" ) > "$vlog" 2>&1 || rc=$?
  fi
  [ "$rc" -eq 124 ] && printf '\nVERIFY TIMEOUT: command exceeded 300s\n' >> "$vlog" 2>/dev/null
  return "$rc"
}

# Record verified true|false + verify_cmd into the trace status.json (best-effort,
# same idiom as the other trace writers).
trace_set_verified() { # trace_set_verified <slice> <true|false> <cmd>
  local slice="$1" v="$2" cmd="$3" rid sj tmp
  rid="$(trace_find_run_for_slice "$slice")"
  [ -n "$rid" ] || { trace_warn "no run bundle for $slice — verified flag not recorded"; return 1; }
  sj="$REPO/.m2herd/runs/$rid/slices/$slice/status.json"
  [ -f "$sj" ] || { trace_warn "no status.json at $sj — verified flag not recorded"; return 1; }
  tmp="$(mktemp "$(dirname "$sj")/.status.json.tmp.XXXXXX")" || { trace_warn "mktemp for $sj failed"; return 1; }
  jq --argjson v "$v" --arg c "$cmd" '.verified = $v | .verify_cmd = $c' "$sj" > "$tmp" 2>/dev/null \
    && mv "$tmp" "$sj" || { rm -f "$tmp"; trace_warn "verified update to $sj failed"; return 1; }
}

# Append one failure entry to the slice's failures.json (the evolver reads
# {kind, severity, where, evidence} — same shape m2herd.sh evolve analyze maps).
trace_append_failure() { # trace_append_failure <slice> <kind> <evidence>
  local slice="$1" kind="$2" evidence="$3" rid dir ff tmp
  rid="$(trace_find_run_for_slice "$slice")"
  [ -n "$rid" ] || { trace_warn "no run bundle for $slice — failures.json not written"; return 1; }
  dir="$REPO/.m2herd/runs/$rid/slices/$slice"; ff="$dir/failures.json"
  mkdir -p "$dir" 2>/dev/null || { trace_warn "mkdir $dir failed"; return 1; }
  [ -s "$ff" ] || printf '[]' > "$ff"
  tmp="$(mktemp "$dir/.failures.json.tmp.XXXXXX")" || { trace_warn "mktemp for $ff failed"; return 1; }
  jq --arg k "$kind" --arg w "slice:$slice" --arg e "$evidence" --arg ts "$(utc_now)" \
    '. + [{kind:$k, severity:"high", where:$w, evidence:$e, at:$ts}]' "$ff" > "$tmp" 2>/dev/null \
    && mv "$tmp" "$ff" || { rm -f "$tmp"; trace_warn "append to $ff failed"; return 1; }
}

# Verify gate + final state for a collect whose report landed. Every successful
# collect path funnels through here. On verify FAIL the slice is marked failed
# in BOTH overview.json and the trace status.json and collect exits 1 — a report
# that doesn't survive independent verification is not "done".
finish_collect() { # finish_collect <slice> <wt> [tokens] [cost_usd]
  local slice="$1" wt="$2" tok="${3:-}" cost="${4:-}" vcmd="" vrc=0
  VERIFY_LOG=""
  if [ "$NO_VERIFY" -eq 1 ]; then
    log "!! verification SKIPPED for $slice (--no-verify)"
    set_worker_state "$slice" "done"
    trace_collect_write "$slice" "done" "$tok" "$cost" || true
    return 0
  fi
  vcmd="$(verify_cmd_for_slice "$slice" "$wt")"
  if [ -z "$vcmd" ]; then
    log "!! verification SKIPPED for $slice — no verify command (no task 'verify:' line, no workers.verify_cmd, no scripts/lint.sh in worktree)"
    set_worker_state "$slice" "done"
    trace_collect_write "$slice" "done" "$tok" "$cost" || true
    return 0
  fi
  run_verify_cmd "$slice" "$wt" "$vcmd" || vrc=$?
  if [ "$vrc" -eq 0 ]; then
    set_worker_state "$slice" "done"
    trace_collect_write "$slice" "done" "$tok" "$cost" || true
    trace_set_verified "$slice" true "$vcmd" || true
    log "collect: verify PASSED for $slice ('$vcmd')"
    return 0
  fi
  echo "!! VERIFY FAILED for $slice: '$vcmd' exited $vrc — report landed but the slice is FAILED; see ${VERIFY_LOG:-verify.log}" >&2
  set_worker_state "$slice" "failed"
  trace_collect_write "$slice" "failed" "$tok" "$cost" || true
  trace_set_verified "$slice" false "$vcmd" || true
  trace_append_failure "$slice" "verify_failed" "verify command '$vcmd' exited $vrc in ${wt:-<no worktree>} (see verify.log)" || true
  exit 1
}

# ---------- collect: wait idle, copy report, verify, update state ---------------
collect() {
  [ -n "$SLICE" ] || { echo "collect needs --slice S" >&2; exit 2; }
  validate_token slice "$SLICE"
  resolve_repo; resolve_self
  resolve_dispatch_settings
  local out="$REPO/.m2herd/dispatch/$SLICE.out.md" pane
  if [ "$DRY_RUN" -eq 1 ]; then
    pane="$(jq -r --arg s "$SLICE" '[.workers[]? | select(.slice==$s)] | first | .pane_id // empty' "$OV" 2>/dev/null || true)"
    pane="${pane:-PANE-DRYRUN}"
    plan "herdr agent wait '$pane' --status idle --timeout $WAIT_TIMEOUT"
    plan "herdr agent read '$pane' --source recent-unwrapped --lines 300  # → $out (unless worker already wrote it)"
    if [ "$NO_VERIFY" -eq 1 ]; then
      plan "verification SKIPPED (--no-verify)"
    else
      plan "VERIFY GATE: cmd = task 'verify:' line > workers.verify_cmd > 'bash scripts/lint.sh' (when present in worktree);"
      plan "  run in the worker's worktree (timeout 300s) → runs/<run>/slices/$SLICE/verify.log;"
      plan "  record verified true|false + verify_cmd in status.json; on fail: failures.json entry + state=failed"
    fi
    set_worker_state "$SLICE" "done"
    trace_collect_write "$SLICE" "done" "" ""
    log "collect: dry-run plan complete for $SLICE"
    return 0
  fi

  [ -f "$OV" ] || { echo "no overview.json at $OV" >&2; exit 1; }
  local wmode wpid wwt
  wmode="$(jq -r --arg s "$SLICE" '[.workers[]? | select(.slice==$s)] | first | .mode // "tui"' "$OV")"
  wwt="$(jq -r --arg s "$SLICE" '[.workers[]? | select(.slice==$s)] | first | .worktree // empty' "$OV")"

  # HEADLESS collect: wait for the pid to exit — but only after proving it is
  # still OUR worker (start-time recorded at dispatch; a recycled pid must not
  # hang the collect). Then keep/derive the report per agent and parse usage
  # (tokens / cost) from the runner's JSON log into workers[].
  if [ "$wmode" = "headless" ]; then
    wpid="$(jq -r --arg s "$SLICE" '[.workers[]? | select(.slice==$s)] | first | .pid // empty' "$OV")"
    local wagent wstart
    wagent="$(jq -r --arg s "$SLICE" '[.workers[]? | select(.slice==$s)] | first | .agent // "claude"' "$OV")"
    wstart="$(jq -r --arg s "$SLICE" '[.workers[]? | select(.slice==$s)] | first | .pid_start // empty' "$OV")"
    local lg="$REPO/.m2herd/dispatch/$SLICE.log" errlg="$REPO/.m2herd/dispatch/$SLICE.stderr.log"
    local waited=0 max=$((WAIT_TIMEOUT / 1000))
    if [ -n "$wpid" ]; then
      local curstart
      curstart="$(ps -o lstart= -p "$wpid" 2>/dev/null | tr -s ' ' | sed 's/^ //;s/ $//' || true)"
      if [ -z "$curstart" ]; then
        log "collect: pid $wpid already exited — reading report"
      elif [ -n "$wstart" ] && [ "$curstart" != "$wstart" ]; then
        log "collect: pid $wpid start-time mismatch (recorded '$wstart', found '$curstart') — recycled pid, our worker already exited; not waiting on it"
      else
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
    else
      # No pid recorded — the worker may STILL be running; don't instantly fail
      # it. Bounded wait on the log/report instead: done when the report shows
      # up or the log has been quiet for 60s.
      log "collect: no pid recorded for $SLICE — waiting on report/log activity instead (max ${max}s)"
      local sz lastsz="" quiet=0
      while [ "$waited" -lt "$max" ]; do
        [ -s "$out" ] && break
        sz="$(wc -c < "$lg" 2>/dev/null | tr -d ' ' || echo 0)"
        if [ "$sz" = "$lastsz" ]; then quiet=$((quiet + 5)); else quiet=0; lastsz="$sz"; fi
        if [ "$quiet" -ge 60 ]; then log "collect: log quiet ${quiet}s — assuming the runner exited"; break; fi
        sleep 5; waited=$((waited + 5))
      done
    fi
    if [ ! -s "$out" ] && [ -s "$lg" ]; then
      # worker didn't write its report file — salvage per agent: claude logs a
      # JSON envelope (.result), codex/opencode/anything else log plain text
      case "$wagent" in
        claude) jq -r '.result // empty' "$lg" > "$out" 2>/dev/null || true ;;
        *)      tail -n 60 "$lg" > "$out" 2>/dev/null || true ;;
      esac
    fi
    [ -s "$out" ] || { echo "headless worker $SLICE produced no report ($out empty; see $lg and $errlg)" >&2; set_worker_state "$SLICE" "failed"; trace_collect_write "$SLICE" "failed" "" "" || true; exit 1; }
    local tok="" cost=""
    if [ "$wagent" = "claude" ] && [ -s "$lg" ] && jq -e . "$lg" >/dev/null 2>&1; then
      tok="$(jq -r '[.modelUsage[]?.outputTokens] | add // empty' "$lg" 2>/dev/null || true)"
      cost="$(jq -r '[.modelUsage[]?.costUSD] | add // empty' "$lg" 2>/dev/null || true)"
    fi
    set_worker_usage "$SLICE" "${tok:-}" "${cost:-}"
    finish_collect "$SLICE" "$wwt" "${tok:-}" "${cost:-}"
    log "collect: done — $SLICE headless state=done${tok:+, ${tok} out-tokens}${cost:+, \$${cost}}, report at $out"
    return 0
  fi

  pane="$(jq -r --arg s "$SLICE" '[.workers[]? | select(.slice==$s)] | first | .pane_id // empty' "$OV")"
  [ -n "$pane" ] || { echo "slice '$SLICE' not in overview.json workers[] — dispatch it first" >&2; exit 1; }
  is_self "$pane" && { echo "worker pane for $SLICE is \$SELF ($pane) — refusing" >&2; exit 1; }

  # Dead-pane check BEFORE the long wait: a closed pane must not burn the full
  # WAIT_TIMEOUT. An empty pane list means the fleet is unreachable — then we
  # can't tell "gone" from "unreachable", so skip the check and let the wait
  # itself fail.
  local known_panes
  known_panes="$(herdr pane list 2>/dev/null | jq -r '.result.panes[]?.pane_id' 2>/dev/null || true)"
  if [ -n "$known_panes" ] && ! printf '%s\n' "$known_panes" | grep -qxF "$pane"; then
    if [ -s "$out" ]; then
      log "pane $pane is gone but the worker already wrote $out — keeping it"
      finish_collect "$SLICE" "$wwt"
      log "collect: done — $SLICE state=done (pane closed after writing its report)"
      return 0
    fi
    echo "worker pane $pane for $SLICE no longer exists — marking failed" >&2
    printf 'FAILED %s: worker pane %s disappeared before collect and no report was written (checked %s).\n' \
      "$SLICE" "$pane" "$(utc_now)" > "$out"
    set_worker_state "$SLICE" "failed"
    trace_collect_write "$SLICE" "failed" "" "" || true
    exit 1
  fi

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

  # State honesty: an empty report is a FAILED collect — say so in BOTH
  # overview.json and the trace status.json, never a hollow "done".
  if [ -s "$out" ]; then
    finish_collect "$SLICE" "$wwt"
    log "collect: done — $SLICE state=done, report at $out"
  else
    echo "worker $SLICE went idle but produced no report ($out empty)" >&2
    set_worker_state "$SLICE" "failed"
    trace_collect_write "$SLICE" "failed" "" "" || true
    exit 1
  fi
}

# ---------- watch: sentinel — auto-resume crashed/stalled workers ---------------
# Encodes the manual babysitting from runs 1-3 (LESSONS.md): codex workers
# crashed 2x each on "stream disconnected: Transport error", claude workers died
# on ECONNRESET, each needed a hand-typed resume nudge, and rate-limit menus
# stalled workers for minutes. A reconcile loop over workers[] in state
# spawned|working: detect the stall, climb the response ladder, and only
# escalate what genuinely needs a human (approval prompts — auto-approval stays
# OUT of scope here; deny/allow policy is herd-loop's job). Only pane_ids
# recorded in workers[] are ever touched, and those were proven non-$SELF at
# dispatch; is_self re-checks anyway before every send.

RESUME_NUDGE="connection dropped — continue exactly where you left off: finish your task items, commit your work, and write your report."
STALL_NUDGE="you appear stopped with no commit on your branch — continue exactly where you left off: finish your task items, commit your work, and write your report."
REPORT_NUDGE="your commits landed but no report file exists — write your complete report to the path named in your task file, then stop."

WATCH_TOKEN=""      # set by watch_one_*: "<slice>=<state>[/<signature>]"
WATCHED=""          # slices seen active this watch — the exit-code set

crash_signature_of() { # crash_signature_of <norm-text> -> echoes name; rc 1 when none
  case "$1" in
    *streamdisconnected*)   printf 'stream-disconnected' ;;
    *transporterror*)       printf 'transport-error' ;;
    *econnreset*)           printf 'econnreset' ;;
    *unabletoconnecttoapi*) printf 'api-unreachable' ;;
    *) return 1 ;;
  esac
}

rate_limit_menu() { # rate_limit_menu <norm-text> — the interactive limit menu
  case "$1" in
    *whatdoyouwanttodo*) case "$1" in *limittoreset*) return 0 ;; esac ;;
  esac
  return 1
}

# Resume count lives in the slice's trace status.json ("resumes": N); when no
# run bundle exists the count degrades to dispatch/<slice>.resumes so
# --max-resumes still holds.
resumes_status_json() { # resumes_status_json <slice> -> path, or empty
  local rid p=""
  rid="$(trace_find_run_for_slice "$1")"
  [ -n "$rid" ] && p="$REPO/.m2herd/runs/$rid/slices/$1/status.json"
  if [ -n "$p" ] && [ -f "$p" ]; then printf '%s' "$p"; fi
  return 0
}

resumes_get() { # resumes_get <slice> -> N (0 when untracked)
  local sj n=""
  sj="$(resumes_status_json "$1")"
  if [ -n "$sj" ]; then n="$(jq -r '.resumes // 0' "$sj" 2>/dev/null || true)"
  else n="$(cat "$REPO/.m2herd/dispatch/$1.resumes" 2>/dev/null || true)"; fi
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  printf '%s' "$n"
}

resumes_bump() { # resumes_bump <slice> — increment the counter (no output)
  local sj n tmp
  n=$(( $(resumes_get "$1") + 1 ))
  sj="$(resumes_status_json "$1")"
  if [ "$DRY_RUN" -eq 1 ]; then
    plan "record resumes=$n for $1 (${sj:-$REPO/.m2herd/dispatch/$1.resumes})"
  elif [ -n "$sj" ]; then
    tmp="$(mktemp "$(dirname "$sj")/.status.json.tmp.XXXXXX")" || { trace_warn "mktemp for $sj failed"; return 0; }
    jq --argjson n "$n" '.resumes = $n' "$sj" > "$tmp" 2>/dev/null && mv "$tmp" "$sj" \
      || { rm -f "$tmp"; trace_warn "resumes update to $sj failed"; }
  else
    trace_warn "no run bundle for $1 — tracking resumes in dispatch/$1.resumes"
    printf '%s' "$n" > "$REPO/.m2herd/dispatch/$1.resumes" 2>/dev/null || true
  fi
  return 0
}

# Base ref for the "did it commit anything" check: the run bundle recorded the
# dispatch-time base; fall back to settings, then the repo's current branch.
slice_base() { # slice_base <slice> -> ref
  local rid b=""
  rid="$(trace_find_run_for_slice "$1")"
  [ -n "$rid" ] && b="$(jq -r '.base // empty' "$REPO/.m2herd/runs/$rid/run.json" 2>/dev/null || true)"
  [ -n "$b" ] || b="$(settings_get '.workers.base' "")"
  [ -n "$b" ] || b="$(git -C "$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)"
  printf '%s' "$b"
}

# Terminal failure via the SAME locked/trace writers the rest of the script
# uses; after this the watch loop stops touching the worker.
watch_fail() { # watch_fail <slice> <kind> <evidence>
  printf 'WATCH: %s marked FAILED — %s\n' "$1" "$3"
  set_worker_state "$1" "failed"
  trace_collect_write "$1" "failed" "" "" || true
  trace_append_failure "$1" "$2" "$3" || true
}

# Reuse the existing collect path (wait-idle short-circuits: we only call this
# when the worker is already idle/exited). Runs in a subshell so collect's
# `exit 1` on a failed verify/report can't kill the watch loop.
watch_collect() { # watch_collect <slice> -> 0 done, 1 failed
  if [ "$DRY_RUN" -eq 1 ]; then plan "run the collect path for $1 (collect --slice $1)"; return 0; fi
  log "watch: collecting $1"
  if ( SLICE="$1" && collect ) </dev/null; then return 0; else return 1; fi
}

# One resume-ladder step for a stalled TUI worker: enforce --max-resumes, bump
# the counter, nudge (agent send, settle, Enter — submit_pointer).
watch_nudge() { # watch_nudge <slice> <pane> <signature> <status> <nudge-text>
  local s="$1" pane="$2" sig="$3" status="$4" text="$5" n
  n="$(resumes_get "$s")"
  if [ "$n" -ge "$WATCH_MAX_RESUMES" ]; then
    watch_fail "$s" "resume_exhausted" "signature '$sig' after $n resumes (max $WATCH_MAX_RESUMES) — not touching it again"
    WATCH_TOKEN="$s=failed/$sig:resumes-exhausted"
    return 0
  fi
  resumes_bump "$s"
  log "watch: $s signature '$sig' (status $status) — resume nudge $((n + 1))/$WATCH_MAX_RESUMES"
  submit_pointer "$pane" "$text"
  set_worker_state "$s" "working"
  WATCH_TOKEN="$s=working/$sig:nudged$((n + 1))"
}

watch_one_tui() { # watch_one_tui <slice> <pane> <wt> <state>
  local s="$1" pane="$2" wt="$3" state="$4"
  local raw norm status sig known out commits="?" dirty="?" base reset
  WATCH_TOKEN="$s=$state"
  if [ -z "$pane" ] || [ "$pane" = "-" ]; then WATCH_TOKEN="$s=$state/no-pane"; return 0; fi
  if is_self "$pane"; then WATCH_TOKEN="$s=$state/self-skip"; return 0; fi

  # dead pane → straight to collect: its dead-pane branch keeps a landed report
  # (verify gate included) or marks the slice failed with a written-out reason.
  known="$(herdr pane list 2>/dev/null | jq -r '.result.panes[]?.pane_id' 2>/dev/null || true)"
  if [ -n "$known" ] && ! printf '%s\n' "$known" | grep -qxF "$pane"; then
    log "watch: $s pane $pane is gone — handing to collect"
    if watch_collect "$s"; then WATCH_TOKEN="$s=done/pane-gone-collected"; else WATCH_TOKEN="$s=failed/pane-gone"; fi
    return 0
  fi

  raw="$(pane_raw_text "$pane")"
  norm="$(printf '%s' "$raw" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
  status="$(agent_status_of "$pane")"
  if [ -z "$norm" ] && [ "$status" = "unknown" ]; then
    # can't read it AND can't classify it (fleet hiccup?) — observe, never act
    WATCH_TOKEN="$s=$state/unreadable"
    return 0
  fi

  # 1. crash signature while not actively working → resume nudge. The "not
  #    working" gate stops re-nudging a worker that already resumed but still
  #    shows the old error text on screen.
  if sig="$(crash_signature_of "$norm")" && [ "$status" != "working" ]; then
    watch_nudge "$s" "$pane" "$sig" "$status" "$RESUME_NUDGE"
    return 0
  fi

  # 2. rate-limit menu → accept the stop-and-wait default (Enter), log the
  #    reset time when visible. Not a resume — nothing was lost.
  if rate_limit_menu "$norm"; then
    reset="$(printf '%s' "$raw" | grep -i 'reset' | head -1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' || true)"
    log "watch: $s rate-limit menu — pressing Enter (stop-and-wait)${reset:+; menu says: $reset}"
    if [ "$DRY_RUN" -eq 1 ]; then plan "herdr pane send-keys '$pane' Enter"
    else herdr pane send-keys "$pane" Enter >/dev/null 2>&1 || true; fi
    WATCH_TOKEN="$s=$state/rate-limit:accepted"
    return 0
  fi

  # 3. blocked on an approval prompt → escalate ONLY. Auto-approval is out of
  #    scope by design (deny/allow policy belongs to herd-loop).
  if [ "$status" = "blocked" ]; then
    printf 'WATCH: %s blocked on approval — needs human/orchestrator\n' "$s"
    WATCH_TOKEN="$s=blocked/approval"
    return 0
  fi

  # 4. idle-ish (idle|done, plus unknown: a dead TUI drops agent detection and
  #    that is exactly the crashed-back-to-shell case) → git decides.
  case "$status" in
    idle|done|unknown)
      out="$REPO/.m2herd/dispatch/$s.out.md"
      if [ -n "$wt" ] && [ -d "$wt" ]; then
        base="$(slice_base "$s")"
        if git -C "$wt" rev-parse --verify -q "$base" >/dev/null 2>&1; then
          commits="$(git -C "$wt" log --oneline "$base..HEAD" 2>/dev/null | wc -l | tr -d ' ')"
        fi
        dirty="$(git -C "$wt" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
      fi
      if [ -s "$out" ] && [ "$commits" != "?" ] && [ "$commits" -gt 0 ]; then
        # idle + committed + report present → the worker is done; collect it
        if watch_collect "$s"; then WATCH_TOKEN="$s=done/collected"; else WATCH_TOKEN="$s=failed/collect"; fi
      elif [ "$commits" = "0" ]; then
        # idle + empty input + no commit — worker forgot/stopped (dirty=$dirty)
        log "watch: $s idle with 0 commits (dirty files: $dirty)"
        watch_nudge "$s" "$pane" "idle-no-commit" "$status" "$STALL_NUDGE"
      elif [ "$commits" != "?" ] && [ ! -s "$out" ]; then
        watch_nudge "$s" "$pane" "idle-no-report" "$status" "$REPORT_NUDGE"
      else
        WATCH_TOKEN="$s=$state/idle-unverifiable"   # base ref or worktree gone — observe only
      fi
      ;;
    *)
      WATCH_TOKEN="$s=working"
      ;;
  esac
  return 0
}

watch_one_headless() { # watch_one_headless <slice> <state>
  local s="$1" state="$2" pid pstart curstart norm sig alive=0 out
  WATCH_TOKEN="$s=$state"
  pid="$(jq -r --arg s "$s" '[.workers[]? | select(.slice==$s)] | first | .pid // empty' "$OV" 2>/dev/null || true)"
  pstart="$(jq -r --arg s "$s" '[.workers[]? | select(.slice==$s)] | first | .pid_start // empty' "$OV" 2>/dev/null || true)"
  out="$REPO/.m2herd/dispatch/$s.out.md"
  norm="$( { tail -c 4000 "$REPO/.m2herd/dispatch/$s.log" 2>/dev/null; tail -c 4000 "$REPO/.m2herd/dispatch/$s.stderr.log" 2>/dev/null; } \
    | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]' || true)"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    curstart="$(ps -o lstart= -p "$pid" 2>/dev/null | tr -s ' ' | sed 's/^ //;s/ $//' || true)"
    if [ -z "$pstart" ] || [ "$curstart" = "$pstart" ]; then alive=1; fi   # start-time mismatch = recycled pid
  fi
  # crash signature in the log tail with no report = failed at once (a one-shot
  # `claude -p` / `codex exec` cannot be resume-nudged); a landed report means
  # the worker survived its errors — let collect (and the verify gate) judge it.
  if [ ! -s "$out" ] && sig="$(crash_signature_of "$norm")"; then
    watch_fail "$s" "worker_crash" "headless crash signature '$sig' in log tail — one-shot runner cannot be resumed"
    WATCH_TOKEN="$s=failed/$sig"
  elif [ "$alive" -eq 1 ]; then
    WATCH_TOKEN="$s=working/pid$pid"
  else
    if watch_collect "$s"; then WATCH_TOKEN="$s=done/collected"; else WATCH_TOKEN="$s=failed/collect"; fi
  fi
  return 0
}

watch() {
  resolve_repo; resolve_self
  resolve_dispatch_settings
  WATCH_INTERVAL="$(positive_int_or_default "${INTERVAL:-$BUILTIN_WATCH_INTERVAL}" "$BUILTIN_WATCH_INTERVAL")"
  WATCH_MAX_RESUMES="$(positive_int_or_default "${MAX_RESUMES:-$BUILTIN_MAX_RESUMES}" "$BUILTIN_MAX_RESUMES")"
  if [ ! -f "$OV" ]; then
    if [ "$DRY_RUN" -eq 1 ]; then plan "read $OV workers[] (absent — nothing to watch)"; return 0; fi
    echo "no overview.json at $OV — nothing to watch" >&2; exit 1
  fi
  local once="$ONCE"
  if [ "$DRY_RUN" -eq 1 ] && [ "$once" -eq 0 ]; then once=1; log "watch: dry-run — single pass, actions planned only"; fi
  log "watch: repo=$REPO interval=${WATCH_INTERVAL}s max-resumes=$WATCH_MAX_RESUMES once=$once (self pane: ${SELF:-<unknown>})"
  local active s w pane wt mode state line rc=0
  while :; do
    active="$(jq -r '[.workers[]? | select(.state=="spawned" or .state=="working")] | .[].slice' "$OV" 2>/dev/null || true)"
    [ -n "$active" ] || break
    line=""
    for s in $active; do
      case " $WATCHED " in *" $s "*) : ;; *) WATCHED="$WATCHED $s" ;; esac
      w="$(jq -c --arg s "$s" '[.workers[]? | select(.slice==$s)] | first' "$OV" 2>/dev/null || true)"
      pane="$(printf '%s' "$w" | jq -r '.pane_id // empty')"
      wt="$(printf '%s' "$w" | jq -r '.worktree // empty')"
      mode="$(printf '%s' "$w" | jq -r '.mode // "tui"')"
      state="$(printf '%s' "$w" | jq -r '.state // "unknown"')"
      if [ "$mode" = "headless" ]; then
        watch_one_headless "$s" "$state"
      else
        watch_one_tui "$s" "$pane" "$wt" "$state"
      fi
      line="${line:+$line }$WATCH_TOKEN"
    done
    printf 'WATCH: %s\n' "$line"
    [ "$once" -eq 1 ] && break
    sleep "$WATCH_INTERVAL"
  done
  [ -n "$WATCHED" ] || log "watch: no workers in state spawned|working — nothing to do"
  for s in $WATCHED; do
    state="$(jq -r --arg s "$s" '[.workers[]? | select(.slice==$s)] | first | .state // "unknown"' "$OV" 2>/dev/null || echo unknown)"
    [ "$state" = "failed" ] && rc=1
  done
  log "watch: done — watched:${WATCHED:- <none>} (exit $rc)"
  exit "$rc"
}

# ---------- down: tear a worker down (pane → worktree → branch → state) --------
# Idempotent: every step skips cleanly when its target is already gone. Retrying
# a slice = clean `down --slice S`, then a normal dispatch recreates everything.
down_one() { # down_one <slice> -> 0 ok, 1 something refused/failed
  local s="$1" w pane wt branch fflag="" rc=0
  w="$(jq -c --arg s "$s" '[.workers[]? | select(.slice==$s)] | first // empty' "$OV" 2>/dev/null || true)"
  if [ -z "$w" ] || [ "$w" = "null" ]; then log "down: slice '$s' not in workers[] — nothing to do"; return 0; fi
  pane="$(printf '%s' "$w" | jq -r '.pane_id // empty')"
  wt="$(printf '%s' "$w" | jq -r '.worktree // empty')"
  branch="$(printf '%s' "$w" | jq -r '.branch // empty')"

  # 1. pane — resolve LIVE by the worktree cwd first (observed: down left 8 of 9
  #    panes open — the pane_id recorded at dispatch goes stale, and the old
  #    `|| true`d close swallowed every failure). The worktree path is unique,
  #    so an agent-list/pane-list cwd match is authoritative; the recorded
  #    pane_id is only the fallback. Check the close RESULT and report
  #    closed / not-found / FAILED per pane. Never $SELF; unknown $SELF counts
  #    as "could be me" (fail safe).
  local mode live_pane="" target="" known
  mode="$(printf '%s' "$w" | jq -r '.mode // "tui"')"
  if [ "$mode" != "headless" ] && [ -n "$wt" ]; then
    live_pane="$(herdr agent list 2>/dev/null | jq -r --arg c "$wt" \
      '[.result.agents[]? | select(.cwd==$c)] | last | .pane_id // empty' 2>/dev/null || true)"
    [ -n "$live_pane" ] || live_pane="$(herdr pane list 2>/dev/null | jq -r --arg c "$wt" \
      '[.result.panes[]? | select(.cwd==$c)] | last | .pane_id // empty' 2>/dev/null || true)"
  fi
  target="$live_pane"
  if [ -z "$target" ] && [ -n "$pane" ] && [ "$pane" != "-" ]; then target="$pane"; fi
  if [ -n "$live_pane" ] && [ -n "$pane" ] && [ "$pane" != "-" ] && [ "$live_pane" != "$pane" ]; then
    log "down: recorded pane_id $pane is stale — live pane for $wt is $live_pane (closing that)"
  fi
  if [ -n "$target" ]; then
    if maybe_self "$target"; then
      log "down: NOT closing pane $target (is or could be \$SELF) — close it by hand"
    elif [ "$DRY_RUN" -eq 1 ]; then
      plan "herdr pane close '$target'   # ${live_pane:+resolved live by cwd $wt; }recorded=$pane; verify it left 'herdr pane list'"
    else
      known="$(herdr pane list 2>/dev/null | jq -r '.result.panes[]?.pane_id' 2>/dev/null || true)"
      if [ -n "$known" ] && ! printf '%s\n' "$known" | grep -qxF "$target"; then
        log "down: pane $target not-found (already gone)"
      elif herdr pane close "$target" >/dev/null 2>&1; then
        # trust but verify: the close used to be || true'd and panes survived
        sleep 1
        known="$(herdr pane list 2>/dev/null | jq -r '.result.panes[]?.pane_id' 2>/dev/null || true)"
        if [ -n "$known" ] && printf '%s\n' "$known" | grep -qxF "$target"; then
          log "! down: pane close reported ok but $target is STILL LISTED — close it by hand"; rc=1
        else
          log "down: pane $target closed"
        fi
      else
        log "! down: pane close FAILED for $target — close it by hand"; rc=1
      fi
    fi
  elif [ "$mode" = "headless" ]; then
    : # headless worker — no pane to close
  else
    log "down: no pane resolved for $s (recorded='${pane:-}', no live match for ${wt:-<no worktree>})"
  fi

  # 2. worktree — git itself refuses a dirty one; --force forwards to git
  [ "$FORCE" -eq 1 ] && fflag="--force"
  if [ -n "$wt" ] && [ -d "$wt" ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
      plan "git -C '$REPO' worktree remove ${fflag:+$fflag }'$wt'"
    elif git -C "$REPO" worktree remove $fflag "$wt" >/dev/null 2>&1; then
      log "down: worktree removed: $wt"
    elif [ "$FORCE" -eq 1 ]; then
      log "! down: worktree remove --force failed for $wt (locked?) — remove it by hand"; rc=1
    else
      log "! down: worktree $wt is dirty or locked — refusing (re-run with --force)"; rc=1
    fi
  fi

  # 3. branch — delete only when merged; otherwise keep it and say so
  if [ -n "$branch" ] && git -C "$REPO" show-ref --verify --quiet "refs/heads/$branch" 2>/dev/null; then
    if [ "$DRY_RUN" -eq 1 ]; then
      plan "git -C '$REPO' branch -d '$branch'   # -d deletes only when merged"
    elif git -C "$REPO" branch -d "$branch" >/dev/null 2>&1; then
      log "down: branch $branch deleted (was merged)"
    else
      log "down: branch $branch kept — unmerged or still checked out (delete by hand: git -C $REPO branch -D $branch)"
    fi
  fi

  # 4. state (locked write) — only when nothing was refused; a dirty-refused
  # worktree keeps its old state so the refusal stays visible in overview.json
  if [ "$rc" -eq 0 ]; then
    set_worker_state "$s" "down"
  else
    log "down: leaving $s state unchanged (teardown incomplete)"
  fi
  return "$rc"
}

down() {
  resolve_repo; resolve_self
  if [ "$ALL" -eq 0 ] && [ -z "$SLICE" ]; then echo "down needs --slice S or --all" >&2; exit 2; fi
  if [ "$DRY_RUN" -eq 1 ] && [ ! -f "$OV" ]; then plan "read $OV workers[] (absent — nothing to do)"; return 0; fi
  [ -f "$OV" ] || { echo "no overview.json at $OV" >&2; exit 1; }
  local targets s rc=0
  if [ "$ALL" -eq 1 ]; then
    targets="$(jq -r '.workers[]?.slice // empty' "$OV" 2>/dev/null || true)"
    [ -n "$targets" ] || { log "down: no workers recorded — nothing to do"; return 0; }
  else
    validate_token slice "$SLICE"
    targets="$SLICE"
  fi
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    down_one "$s" || rc=1
  done <<EOF
$targets
EOF
  [ "$rc" -eq 0 ] || exit 1
  log "down: done"
}

# ---------- dispatch table -----------------------------------------------------
need jq
case "$CMD" in
  up)       up ;;
  dispatch) dispatch ;;
  collect)  collect ;;
  watch)    watch ;;
  down)     down ;;
  help|*)   awk 'NR >= 2 { if ($0 ~ /^set -euo pipefail/) exit; print }' "$0" ;;
esac
