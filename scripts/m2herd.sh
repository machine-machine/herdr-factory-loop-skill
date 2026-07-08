#!/usr/bin/env bash
# m2herd.sh — the m2herd context-fabric engine.
#
# .m2herd/ is the per-repo context fabric for a Claude-Code main orchestrator: the folder
# holds the context, the orchestrator holds pointers. This script does the MECHANICAL work
# only — scaffold, append, refile, regenerate, distill — so the whole fabric stays
# reconstructible from disk alone. Judgment (what to note, when to refile or archive)
# stays with the orchestrator.
#
# Usage:
#   m2herd.sh boot    [--dir P] [--goal "…"]  # recommended entry point: init (if needed) + sync + resume + next
#                                             #   git-repo preflight: prints a colorful (non-fatal) warning if --dir is not a git repo
#   m2herd.sh init    [--dir P] [--goal "…"]  # scaffold .m2herd/ from templates/m2herd/, gitignore it
#   m2herd.sh status  [--dir P]               # render overview.json human-readably
#   m2herd.sh note    [--dir P] "text"        # append "- [<UTC ts>] text" to NOTES.md
#   m2herd.sh refile  [--dir P] --area A      # create/refresh context/A/ (+header), move live NOTES.md content into it, update overview.json
#   m2herd.sh resume  [--dir P]               # print RESUME.md + one line per area from overview.json
#   m2herd.sh sync    [--dir P] [--check]     # regenerate overview.json areas[] from the context/ tree; refresh RESUME.md skeleton
#                                             #   --check: report drift (missing areas, orphan entries) and exit 3 instead of repairing
#   m2herd.sh archive [--dir P] --area A      # distill context/A/context.md to header + <=10 summary lines, mark archived (deep/ untouched)
#   m2herd.sh gist    [--dir P] [--push]      # one-paragraph project gist; --push pipes it to $M2HERD_GIST_CMD if set
#   m2herd.sh next    [--dir P]               # self-prompting primitive: mechanical priority walk, prints exactly one "NEXT: " line
#                                             #   (drift → context budget ≥75% → steer → machineroom → coach intent → refile notes
#                                             #    → collect worker → failed worker → reap panes → open question → compare/dispatch)
#   m2herd.sh evolve analyze  [--dir P] [--run <id|latest|current>]
#                                             # mechanical: read .m2herd/runs/<run-id>/, write signatures + skeleton
#                                             #   proposals under .m2herd/evolver/; no LLM, no network; idempotent
#   m2herd.sh evolve proposals [--dir P]      # list proposals: id, kind, risk, status
#   m2herd.sh evolve show <id> [--dir P]      # print a proposal file
#   m2herd.sh evolve apply <id> [--dir P] [--ack-repo]
#                                             # memory/policy: append lesson to LESSONS.md, mark applied
#                                             #   template: same, but target must be under .m2herd/
#                                             #   repo: never edits target; prints a branch/patch recommendation;
#                                             #   marks applied only with --ack-repo
#   m2herd.sh evolve reject <id> [--dir P]    # flip proposal status to rejected
#   m2herd.sh room    [--dir P]               # the machineroom viewer in THIS terminal: Go TUI (m2herd-tui) when installed,
#                                             #   else the flicker-free bash watch — one command, always the best/latest viewer
#   m2herd.sh dashboard [--dir P] [--watch [--interval N]]
#                                             # tier-1 TUI: read-only render — header (drift dot, update line, ages), NEXT, areas,
#                                             #   workers, open questions, NOTES tail; tput colors on a tty, plain when piped; NEVER
#                                             #   writes to the fabric. --watch: flicker-free repaint loop (home-cursor redraw, no
#                                             #   clear) every N s (default 2), refreshing the self-update check every 10 min
#   m2herd.sh config list|get|set [--dir P] ... # read/write .m2herd/settings.json with defaults + validation
#   m2herd.sh doctor  [--dir P]               # "why is it not working": jq/git/herdr/symlinks/node/hooks/statusline-bridge/
#                                             #   .m2herd-drift/go checks — ok|warn|FAIL + one-line remedy; exit 1 iff any FAIL
#   m2herd.sh reap    [--dir P] [--dry-run]   # close herdr panes of FINISHED (done|failed) workers so idle claude/codex
#                                             #   sessions stop holding API connections — never $SELF, never a working pane
#   m2herd.sh self-update [--check]           # --check: fetch the engine repo, cache behind-count in ~/.cache/m2herd/update-status
#                                             #   (dashboard renders it); no flag: ff-only pull of the engine repo (refuses dirty tree)
#   m2herd.sh selftest                        # tmpdir end-to-end: init → note → refile → sync (+--check drift) → archive → gist → next; jq asserts
#
# --dir defaults to $PWD. Everything idempotent. jq required. overview.json writes are
# whole-file rewrites through jq (never sed patching).

set -euo pipefail

# ---------- arg parsing ------------------------------------------------------
CMD="${1:-help}"; shift || true
# `evolve` is a subcommand group: the word right after it (analyze/proposals/
# show/apply/reject) is consumed here as EVOLVE_ACTION, same idiom as CMD itself.
EVOLVE_ACTION=""
if [ "$CMD" = "evolve" ]; then EVOLVE_ACTION="${1:-}"; shift || true; fi
CONFIG_ACTION=""; CONFIG_PATH=""; CONFIG_VALUE=""
DIR="$PWD"; GOAL=""; AREA=""; TEXT=""; CHECK=0; PUSH=0; WATCH=0; INTERVAL=2; RUN=""; ACK_REPO=0; DRYRUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dir)   DIR="$2"; shift 2 ;;
    --dry-run) DRYRUN=1; shift ;;
    --goal)  GOAL="$2"; shift 2 ;;
    --area)  AREA="$2"; shift 2 ;;
    --check) CHECK=1; shift ;;
    --push)  PUSH=1; shift ;;
    --watch) WATCH=1; shift ;;
    --interval) INTERVAL="$2"; shift 2 ;;
    --run)   RUN="$2"; shift 2 ;;
    --ack-repo) ACK_REPO=1; shift ;;
    -h|--help) CMD="help"; shift ;;
    *)
      if [ "$CMD" = "config" ]; then
        if [ -z "$CONFIG_ACTION" ]; then CONFIG_ACTION="$1"; shift
        elif [ -z "$CONFIG_PATH" ]; then CONFIG_PATH="$1"; shift
        elif [ -z "$CONFIG_VALUE" ]; then CONFIG_VALUE="$1"; shift
        else echo "unknown arg: $1" >&2; exit 2; fi
      elif [ -z "$TEXT" ]; then TEXT="$1"; shift
      else echo "unknown arg: $1" >&2; exit 2; fi ;;
  esac
done

# ---------- helpers ----------------------------------------------------------
MARKER='<!-- === M2HERD:LIVE === -->'
ts()       { date -u +%Y-%m-%dT%H:%M:%SZ; }
log()      { printf '  %s\n' "$*"; }
OV()       { echo "$DIR/.m2herd/overview.json"; }
SETTINGS(){ echo "$DIR/.m2herd/settings.json"; }
# Resolve through symlinks ($0 may be ~/.local/bin/m2herd → scripts/m2herd.sh);
# macOS has no readlink -f, so walk the link chain by hand.
resolve_link() {
  local p="$1" l
  while [ -L "$p" ]; do
    l="$(readlink "$p")"
    case "$l" in /*) p="$l" ;; *) p="$(dirname "$p")/$l" ;; esac
  done
  printf '%s' "$p"
}
self_path() { resolve_link "$0"; }
tmpl_dir() { cd "$(dirname "$(self_path)")/../templates/m2herd" 2>/dev/null && pwd; }
need_jq()  { command -v jq >/dev/null 2>&1 || { echo "m2herd.sh: jq is required" >&2; exit 1; }; }
resolve_dir() { DIR="$(cd "$DIR" 2>/dev/null && pwd)" || { echo "no such dir: $DIR" >&2; exit 1; }; need_jq; }
need_init(){ [ -f "$(OV)" ] || { echo "no .m2herd/ at $DIR (run: m2herd.sh init --dir $DIR)" >&2; exit 1; }; }
# VALIDATION convention (shared with m2herd-up.sh): tokens spliced into fabric
# paths (--area, --run, evolve proposal ids) must match ^[A-Za-z0-9][A-Za-z0-9._-]*$
# and never contain '..' — rejects path traversal and shell-hostile names.
validate_token() { # validate_token <label> <value>
  if [[ ! "$2" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || [[ "$2" == *..* ]]; then
    echo "invalid $1: '$2' (allowed: [A-Za-z0-9][A-Za-z0-9._-]*, no '..')" >&2; exit 2
  fi
}
# LOCKING convention (shared with m2herd-up.sh): every read-modify-write of a
# fabric file serializes on flock of "<file>.lock" (lock lives NEXT to the state
# file); tmp files are mktemp'd in the SAME directory as the target so the final
# mv is an atomic rename, and removed when the generator fails. Systems without
# flock (stock macOS) degrade to unlocked — same behavior as before.
with_lock() { # with_lock <lockfile> <cmd…>
  local lf="$1"; shift
  if command -v flock >/dev/null 2>&1; then ( flock 9; "$@" ) 9>"$lf"; else "$@"; fi
}
# whole-file overview.json rewrite through jq: ov_put [jq args…] '<filter>'
ov_put()   { with_lock "$(OV).lock" ov_put_locked "$@"; }
ov_put_locked() {
  local ov tmp; ov="$(OV)"
  tmp="$(mktemp "$(dirname "$ov")/.overview.XXXXXX")"
  if jq "$@" "$ov" > "$tmp"; then mv "$tmp" "$ov"; else rm -f "$tmp"; return 1; fi
}

settings_defaults_json() {
  jq -n '{
    schema_version: 1,
    _doc: ".m2herd/context/settings-ux/context.md",
    orchestrator: {agent: "claude", runner: "pane"},
    workers: {agent: "claude", runner: "pane", max: 3, base: "", model: "",
              settle_seconds: 2, wait_timeout_minutes: 30},
    routing: []
  }'
}

# settings_get <jq-path> <default>
# Internal primitive for shell callers: absent file/field or invalid JSON returns
# the caller default and never terminates the process.
settings_get() {
  local path="${1:?settings_get needs a jq path}" default="${2:-}" f
  f="$(SETTINGS)"
  if [ ! -f "$f" ]; then printf '%s\n' "$default"; return 0; fi
  jq -er --arg default "$default" "$path // \$default" "$f" 2>/dev/null || printf '%s\n' "$default"
}

settings_effective_json() {
  local f; f="$(SETTINGS)"
  if [ -f "$f" ] && jq -e 'type=="object"' "$f" >/dev/null 2>&1; then
    jq -s '
      .[0] as $d | .[1] as $u
      | $d
      | .schema_version = ($u.schema_version // $d.schema_version)
      | ._doc = ($u._doc // $d._doc)
      | .orchestrator = ($d.orchestrator * ($u.orchestrator // {}))
      | .workers = ($d.workers * ($u.workers // {}))
      | .routing = ($u.routing // $d.routing)
    ' <(settings_defaults_json) "$f"
  else
    settings_defaults_json
  fi
}

settings_validate_agent() {
  case "$2" in claude|codex|cursor|opencode) return 0 ;; esac
  echo "config set: $1 must be one of: claude, codex, cursor, opencode" >&2; exit 2
}
settings_validate_runner() {
  case "$2" in pane|headless) return 0 ;; esac
  echo "config set: $1 must be one of: pane, headless" >&2; exit 2
}
settings_validate_nonneg() {
  jq -en --argjson n "$2" '$n | (type=="number") and (. >= 0)' >/dev/null 2>&1 \
    || { echo "config set: $1 must be numeric and >= 0" >&2; exit 2; }
}
settings_validate_min1() {
  jq -en --argjson n "$2" '$n | (type=="number") and (. >= 1)' >/dev/null 2>&1 \
    || { echo "config set: $1 must be numeric and >= 1" >&2; exit 2; }
}
# routing rules: {pattern, agent} required; runner (pane|headless) and model (string) optional
settings_validate_routing() {
  jq -e '
    type=="array" and all(.[]; type=="object"
      and ((.pattern // "") | type=="string" and length > 0)
      and (.agent | IN("claude","codex","cursor","opencode"))
      and ((.runner // "pane") | IN("pane","headless"))
      and ((.model // "") | type=="string"))
  ' >/dev/null 2>&1 || { echo "config set: routing must be a JSON array of {pattern, agent[, runner, model]} rules" >&2; exit 2; }
}

settings_jq_path() {
  case "$1" in
    schema_version) echo '.schema_version' ;;
    _doc) echo '._doc' ;;
    orchestrator.agent) echo '.orchestrator.agent' ;;
    orchestrator.runner) echo '.orchestrator.runner' ;;
    workers.agent) echo '.workers.agent' ;;
    workers.runner) echo '.workers.runner' ;;
    workers.max) echo '.workers.max' ;;
    workers.base) echo '.workers.base' ;;
    workers.model) echo '.workers.model' ;;
    workers.settle_seconds) echo '.workers.settle_seconds' ;;
    workers.wait_timeout_minutes) echo '.workers.wait_timeout_minutes' ;;
    routing) echo '.routing' ;;
    *) echo "unknown config path: $1" >&2; exit 2 ;;
  esac
}

live_tail() { awk -v m="$MARKER" 'p{print} index($0,m){p=1}' "$1"; }   # content below the marker
keep_head() { awk -v m="$MARKER" '{print} index($0,m){exit}' "$1"; }   # boilerplate through the marker
# reset a marker file to boilerplate-through-marker (post-refile NOTES truncation);
# run under with_lock "<file>.lock" per the locking convention above
notes_truncate() {
  local nf="$1" tmp
  tmp="$(mktemp "$(dirname "$nf")/.notes.XXXXXX")"
  if keep_head "$nf" > "$tmp"; then mv "$tmp" "$nf"; else rm -f "$tmp"; return 1; fi
}
has_ink()   { printf '%s' "$1" | grep -q '[^[:space:]]'; }

# context.md body: everything after the closing --- of the annotation header
body_of() {
  [ -f "$1" ] || return 0
  if head -1 "$1" | grep -qx -- '---'; then awk 'c>=2{print} /^---$/{c++}' "$1"; else cat "$1"; fi
}
# value of a key from the annotation header (comments stripped)
hdr_get() {
  awk -v k="$2" '
    NR==1 && $0!="---"{exit}
    NR>1 && $0=="---"{exit}
    $0 ~ "^"k":"{sub("^"k":[[:space:]]*",""); sub("[[:space:]]*#.*$",""); print; exit}
  ' "$1" 2>/dev/null || true
}
# write_header <area> <related-csv> <status-or-empty>
write_header() {
  printf -- '---\narea: %s\n' "$1"
  printf 'related: [%s]   # where to find the sibling pieces\n' "$2"
  printf 'deep: ./deep/                   # lossless material for this area\n'
  printf 'updated: %s\n' "$(ts)"
  [ -z "$3" ] || printf 'status: %s\n' "$3"
  printf -- '---\n'
}
# first non-empty, non-heading line, "- [ts] " prefix stripped — used as a summary
first_line() { awk 'NF && $1 !~ /^#/ {print; exit}' | sed -E 's/^- \[[^]]+\] //' | cut -c1-160; }

# value of a key from a proposal's YAML frontmatter (between the two --- fences)
frontmatter_get() {
  awk -v k="$2" 'BEGIN{c=0} { if ($0=="---"){c++; if (c==2) exit; next}
    if (c==1 && $0 ~ "^"k":"){sub("^"k":[[:space:]]*","");print;exit} }' "$1" 2>/dev/null
}
# rewrite the `status:` line inside a proposal's frontmatter fence, body untouched
set_status() { with_lock "$1.lock" set_status_locked "$1" "$2"; }
set_status_locked() {
  local f="$1" st="$2" tmp
  tmp="$(mktemp "$(dirname "$f")/.status.XXXXXX")"
  if awk -v st="$st" 'BEGIN{c=0}
    { if ($0=="---"){c++; print; next}
      if (c==1 && $0 ~ /^status:/){print "status: " st} else {print} }' "$f" > "$tmp"
  then mv "$tmp" "$f"; else rm -f "$tmp"; return 1; fi
}

# ---------- init: scaffold .m2herd/ from templates/m2herd/ --------------------
init() {
  resolve_dir
  local tmpl m2="$DIR/.m2herd"
  tmpl="$(tmpl_dir)" || { echo "templates/m2herd/ not found next to $0" >&2; exit 1; }
  mkdir -p "$m2/context" "$m2/dispatch" "$m2/inbox"
  [ -f "$m2/RESUME.md" ] || cp "$tmpl/RESUME.md" "$m2/RESUME.md"
  [ -f "$m2/NOTES.md" ]  || cp "$tmpl/NOTES.md"  "$m2/NOTES.md"
  [ -f "$m2/inbox/STEER.md" ] || cp "$tmpl/inbox/STEER.md" "$m2/inbox/STEER.md"
  mkdir -p "$m2/evolver" "$m2/runs"
  [ -f "$m2/evolver/README.md" ]  || cp "$tmpl/evolver/README.md"  "$m2/evolver/README.md"  2>/dev/null || true
  [ -f "$m2/evolver/LESSONS.md" ] || cp "$tmpl/evolver/LESSONS.md" "$m2/evolver/LESSONS.md" 2>/dev/null || true
  [ -f "$m2/runs/README.md" ]     || cp "$tmpl/runs/README.md"     "$m2/runs/README.md"     2>/dev/null || true
  [ -f "$m2/settings.json" ]       || cp "$tmpl/settings.json"      "$m2/settings.json"      2>/dev/null || settings_defaults_json > "$m2/settings.json"
  if [ ! -f "$m2/overview.json" ]; then
    local tmp; tmp="$(mktemp "$m2/.overview.XXXXXX")"
    if jq --arg g "$GOAL" --arg ts "$(ts)" '.goal=$g | .updated_at=$ts' "$tmpl/overview.json" > "$tmp"
    then mv "$tmp" "$m2/overview.json"; else rm -f "$tmp"; return 1; fi
  else
    # backfill optional v1.2 fields on older fabrics; empty done_when = "intent not yet coached"
    ov_put --arg g "$GOAL" --arg ts "$(ts)" '
      (if $g != "" then .goal=$g | .updated_at=$ts else . end)
      | .done_when = (.done_when // "") | .open_questions = (.open_questions // [])'
  fi
  if ! grep -qxF '.m2herd/' "$DIR/.gitignore" 2>/dev/null; then
    # a .gitignore without a trailing newline would glue '.m2herd/' onto its last pattern
    if [ -s "$DIR/.gitignore" ] && [ -n "$(tail -c1 "$DIR/.gitignore" 2>/dev/null)" ]; then echo >> "$DIR/.gitignore"; fi
    printf '.m2herd/\n' >> "$DIR/.gitignore"
  fi
  log "initialized .m2herd/ at $m2 (gitignored)"
}

# ---------- note: append a timestamped line below the marker ------------------
note() {
  resolve_dir; need_init
  [ -n "$TEXT" ] || { echo "note needs text: m2herd.sh note \"…\"" >&2; exit 2; }
  printf -- '- [%s] %s\n' "$(ts)" "$TEXT" >> "$DIR/.m2herd/NOTES.md"
  log "noted → .m2herd/NOTES.md"
}

# ---------- refile: move live notes into context/<area>/ ----------------------
refile() {
  resolve_dir; need_init
  [ -n "$AREA" ] || { echo "refile needs --area A" >&2; exit 2; }
  validate_token area "$AREA"
  local m2="$DIR/.m2herd" adir="$DIR/.m2herd/context/$AREA" cf now body related live first tmp
  cf="$adir/context.md"; now="$(ts)"
  mkdir -p "$adir/deep"
  body="$(body_of "$cf")"
  related="$(hdr_get "$cf" related | tr -d '[]')"
  [ -n "$related" ] || related="$(jq -r --arg n "$AREA" '[.areas[]?|select(.name==$n)|(.related//[])|join(", ")][0] // ""' "$(OV)")"
  live="$(live_tail "$m2/NOTES.md")"
  tmp="$(mktemp "$adir/.context.XXXXXX")"
  {
    write_header "$AREA" "$related" ""      # refiling (re)activates the area
    [ -z "$body" ] || printf '%s\n' "$body"
    if has_ink "$live"; then printf '\n## refiled %s\n\n%s\n' "$now" "$live"; fi
  } > "$tmp" && mv "$tmp" "$cf" || { rm -f "$tmp"; return 1; }
  if has_ink "$live"; then
    with_lock "$m2/NOTES.md.lock" notes_truncate "$m2/NOTES.md"
    log "refiled live notes → context/$AREA/context.md"
  else
    log "no live notes to move — context/$AREA/ refreshed"
  fi
  first="$(printf '%s\n' "$live" | first_line)"
  ov_put --arg n "$AREA" --arg ts "$now" --arg s "$first" '
    .updated_at=$ts
    | if any(.areas[]?; .name==$n) then
        .areas = [ .areas[] | if .name==$n
                   then (.status="active" | (if $s!="" then .summary=$s else . end))
                   else . end ]
      else
        .areas += [{name:$n, path:(".m2herd/context/"+$n+"/"), summary:$s, related:[], status:"active"}]
      end'
  log "overview.json updated (area $AREA)"
}

# ---------- sync: regenerate overview from the context/ tree ------------------
# emit areas[] as JSON from the context/ tree (file header wins; overview summary is fallback)
areas_from_tree() {
  local m2="$DIR/.m2herd" areas="[]" d name cf summary related status
  for d in "$m2"/context/*/; do
    [ -d "$d" ] || continue
    name="$(basename "$d")"; cf="${d}context.md"
    related="$(hdr_get "$cf" related | tr -d '[]')"
    status="$(hdr_get "$cf" status)"; [ "$status" = "archived" ] || status="active"
    summary="$(body_of "$cf" | first_line)"
    [ -n "$summary" ] || summary="$(jq -r --arg n "$name" '[.areas[]?|select(.name==$n)|.summary][0] // ""' "$(OV)")"
    areas="$(jq --arg n "$name" --arg s "$summary" --arg st "$status" --arg rel "$related" \
      '. + [{name:$n, path:(".m2herd/context/"+$n+"/"), summary:$s,
             related: ($rel | split(",") | map(gsub("^\\s+|\\s+$";"")) | map(select(.!=""))),
             status:$st}]' <<<"$areas")"
  done
  printf '%s' "$areas"
}

# refresh RESUME.md: regenerate boilerplate + snapshot above the marker, preserve below
refresh_resume() { with_lock "$DIR/.m2herd/RESUME.md.lock" refresh_resume_locked; }
refresh_resume_locked() {
  local m2="$DIR/.m2herd" resume tpl live tmp
  resume="$m2/RESUME.md"; tpl="$(tmpl_dir)/RESUME.md"
  [ -f "$tpl" ] || { echo "template RESUME.md not found next to $0" >&2; exit 1; }
  live=""
  [ -f "$resume" ] && live="$(live_tail "$resume")"
  has_ink "$live" || live="$(live_tail "$tpl")"
  tmp="$(mktemp "$m2/.resume.XXXXXX")"
  {
    awk '{print} /^-->$/{exit}' "$tpl"
    echo
    echo "# RESUME"
    echo
    jq -r '
      "goal:   " + (if (.goal//"")=="" then "(none)" else .goal end),
      "status: " + (.status//"active"),
      "areas:  " + ((.areas//[])|map(select((.status//"active")!="archived"))|length|tostring)
                 + " active, " + ((.areas//[])|map(select((.status//"active")=="archived"))|length|tostring) + " archived",
      "synced: " + (.updated_at//"?")' "$(OV)"
    echo
    printf '%s\n' "$MARKER"
    printf '%s\n' "$live"
  } > "$tmp" && mv "$tmp" "$resume" || { rm -f "$tmp"; return 1; }
}

# DRIFT lines for overview.json vs the context/ tree; returns 1 when drift exists
drift_report() {
  local m2="$DIR/.m2herd" tree ov missing orphan drift=0 n
  tree="$(for d in "$m2"/context/*/; do [ -d "$d" ] || continue; basename "$d"; done | sort; true)"
  ov="$(jq -r '.areas[]?.name' "$(OV)" | sort)"
  missing="$(comm -23 <(printf '%s\n' "$tree" | sed '/^$/d') <(printf '%s\n' "$ov" | sed '/^$/d'))"
  orphan="$(comm -13 <(printf '%s\n' "$tree" | sed '/^$/d') <(printf '%s\n' "$ov" | sed '/^$/d'))"
  # here-string while-read (not `for n in $var`): area names with spaces stay whole
  if [ -n "$missing" ]; then drift=1; while IFS= read -r n; do [ -n "$n" ] || continue; echo "DRIFT missing: context/$n/ exists but overview.json has no area '$n'"; done <<<"$missing"; fi
  if [ -n "$orphan" ];  then drift=1; while IFS= read -r n; do [ -n "$n" ] || continue; echo "DRIFT orphan:  overview.json lists area '$n' but context/$n/ does not exist"; done <<<"$orphan"; fi
  [ "$drift" -eq 0 ]
}

sync_cmd() {
  resolve_dir; need_init
  local now; now="$(ts)"
  if [ "$CHECK" -eq 1 ]; then
    # drift report only — the living-harness loop treats drift as an ERROR (exit 3)
    if drift_report; then echo "in sync (overview.json matches context/ tree)"; return 0; fi
    echo "drift detected — repair with: m2herd.sh sync --dir $DIR"
    exit 3
  fi
  local areas
  areas="$(areas_from_tree)"
  ov_put --argjson a "$areas" --arg ts "$now" '.areas=$a | .updated_at=$ts'
  log "overview.json areas synced ($(jq 'length' <<<"$areas") from context/)"
  refresh_resume
  log "RESUME.md skeleton refreshed (live notes preserved)"
}

# ---------- archive: distill a done area (decay discipline) -------------------
archive() {
  resolve_dir; need_init
  [ -n "$AREA" ] || { echo "archive needs --area A" >&2; exit 2; }
  validate_token area "$AREA"
  local m2="$DIR/.m2herd" cf="$DIR/.m2herd/context/$AREA/context.md" now related summary tmp
  [ -f "$cf" ] || { echo "no such area to archive: context/$AREA/context.md" >&2; exit 1; }
  now="$(ts)"
  related="$(hdr_get "$cf" related | tr -d '[]')"
  summary="$(body_of "$cf" | awk 'NF' | head -10)"
  tmp="$(mktemp "$(dirname "$cf")/.context.XXXXXX")"
  {
    write_header "$AREA" "$related" "archived"
    [ -z "$summary" ] || printf '%s\n' "$summary"
  } > "$tmp" && mv "$tmp" "$cf" || { rm -f "$tmp"; return 1; }
  ov_put --arg n "$AREA" --arg ts "$now" '
    .updated_at=$ts
    | if any(.areas[]?; .name==$n) then
        .areas = [ .areas[] | if .name==$n then .status="archived" else . end ]
      else
        .areas += [{name:$n, path:(".m2herd/context/"+$n+"/"), summary:"", related:[], status:"archived"}]
      end'
  log "archived context/$AREA/ (distilled to <=10 summary lines; deep/ untouched)"
}

# ---------- status -----------------------------------------------------------
status_cmd() {
  resolve_dir; need_init
  echo "workspace: $DIR/.m2herd"
  jq -r '
    def act:  (.areas//[]) | map(select((.status//"active")!="archived"));
    def arch: (.areas//[]) | map(select((.status//"active")=="archived"));
    "goal:    " + (if (.goal//"")=="" then "(none)" else .goal end),
    "done:    " + (if (.done_when//"")=="" then "(intent not yet coached — set done_when)" else .done_when end),
    "status:  " + (.status//"active"),
    "updated: " + (.updated_at//"?"),
    "notes:   " + (.notes_file//".m2herd/NOTES.md"),
    "resume:  " + (.resume_file//".m2herd/RESUME.md"),
    ("areas (" + (act|length|tostring) + " active):"),
    (act[] | "  - " + .name + "  " + .path
       + (if (.summary//"")!="" then "  — " + .summary else "" end)
       + (if ((.related//[])|length)>0 then "  (related: " + (.related|join(", ")) + ")" else "" end)),
    ("workers (" + ((.workers//[])|length|tostring) + "):"),
    ((.workers//[])[] | "  - " + .slice + "  [" + (.state//"?") + "]  pane=" + (.pane_id//"-") + "  branch=" + (.branch//"-")),
    (if (arch|length)>0 then "archived: " + (arch|map(.name)|join(", ")) else empty end)
  ' "$(OV)"
}

# ---------- config: .m2herd/settings.json -----------------------------------
config_list() {
  local eff
  eff="$(settings_effective_json)"
  jq -r --argjson d "$(settings_defaults_json)" '
    def mark($p; $v): if $v != ($d | getpath($p)) then "* " else "  " end;
    (mark(["schema_version"]; .schema_version) + "schema_version=" + (.schema_version|tostring)),
    (mark(["orchestrator","agent"]; .orchestrator.agent) + "orchestrator.agent=" + .orchestrator.agent),
    (mark(["orchestrator","runner"]; .orchestrator.runner) + "orchestrator.runner=" + .orchestrator.runner),
    (mark(["workers","agent"]; .workers.agent) + "workers.agent=" + .workers.agent),
    (mark(["workers","runner"]; .workers.runner) + "workers.runner=" + .workers.runner),
    (mark(["workers","max"]; .workers.max) + "workers.max=" + (.workers.max|tostring)),
    (mark(["workers","base"]; .workers.base) + "workers.base=" + .workers.base),
    (mark(["workers","model"]; .workers.model) + "workers.model=" + .workers.model),
    (mark(["workers","settle_seconds"]; .workers.settle_seconds) + "workers.settle_seconds=" + (.workers.settle_seconds|tostring)),
    (mark(["workers","wait_timeout_minutes"]; .workers.wait_timeout_minutes) + "workers.wait_timeout_minutes=" + (.workers.wait_timeout_minutes|tostring)),
    (mark(["routing"]; .routing) + "routing=" + (.routing|tojson))
  ' <<<"$eff"
}

config_get() {
  [ -n "$CONFIG_PATH" ] || { echo "usage: m2herd.sh config get <dotted.path> [--dir P]" >&2; exit 2; }
  local filter; filter="$(settings_jq_path "$CONFIG_PATH")"
  settings_effective_json | jq -cr "$filter"
}

settings_set_locked() {
  local key="$1" value="$2" f tmp eff
  f="$(SETTINGS)"
  mkdir -p "$(dirname "$f")"
  case "$key" in
    orchestrator.agent|workers.agent) settings_validate_agent "$key" "$value" ;;
    orchestrator.runner|workers.runner) settings_validate_runner "$key" "$value" ;;
    workers.max) settings_validate_nonneg "$key" "$value" ;;
    workers.base|workers.model) : ;;   # free-form strings (branch name / model id)
    workers.settle_seconds) settings_validate_nonneg "$key" "$value" ;;
    workers.wait_timeout_minutes) settings_validate_min1 "$key" "$value" ;;
    routing) printf '%s' "$value" | settings_validate_routing ;;
    *) echo "unknown or read-only config path: $key" >&2; exit 2 ;;
  esac
  eff="$(settings_effective_json)"
  tmp="$(mktemp "$(dirname "$f")/.settings.json.XXXXXX")"
  case "$key" in
    orchestrator.agent)  jq --arg v "$value" '.orchestrator.agent=$v' <<<"$eff" > "$tmp" ;;
    orchestrator.runner) jq --arg v "$value" '.orchestrator.runner=$v' <<<"$eff" > "$tmp" ;;
    workers.agent)       jq --arg v "$value" '.workers.agent=$v' <<<"$eff" > "$tmp" ;;
    workers.runner)      jq --arg v "$value" '.workers.runner=$v' <<<"$eff" > "$tmp" ;;
    workers.max)         jq --argjson v "$value" '.workers.max=$v' <<<"$eff" > "$tmp" ;;
    workers.base)        jq --arg v "$value" '.workers.base=$v' <<<"$eff" > "$tmp" ;;
    workers.model)       jq --arg v "$value" '.workers.model=$v' <<<"$eff" > "$tmp" ;;
    workers.settle_seconds)       jq --argjson v "$value" '.workers.settle_seconds=$v' <<<"$eff" > "$tmp" ;;
    workers.wait_timeout_minutes) jq --argjson v "$value" '.workers.wait_timeout_minutes=$v' <<<"$eff" > "$tmp" ;;
    routing)             jq --argjson v "$value" '.routing=$v' <<<"$eff" > "$tmp" ;;
  esac
  if jq '.' "$tmp" > "$tmp.pretty"; then mv "$tmp.pretty" "$tmp"; else rm -f "$tmp" "$tmp.pretty"; return 1; fi
  mv "$tmp" "$f"
}

config_set() {
  [ -n "$CONFIG_PATH" ] && [ -n "$CONFIG_VALUE" ] \
    || { echo "usage: m2herd.sh config set <dotted.path> <value> [--dir P]" >&2; exit 2; }
  with_lock "$(SETTINGS).lock" settings_set_locked "$CONFIG_PATH" "$CONFIG_VALUE"
}

config_cmd() {
  resolve_dir; need_init
  case "${CONFIG_ACTION:-}" in
    list) config_list ;;
    get)  config_get ;;
    set)  config_set ;;
    *) echo "usage: m2herd.sh config {list|get|set} ... [--dir P]" >&2; exit 2 ;;
  esac
}

# ---------- resume -----------------------------------------------------------
resume_cmd() {
  resolve_dir; need_init
  # ~40-line report cap: RESUME.md (leading comment stripped, head ≤20 lines),
  # areas (≤8 + one rollup line), lessons stay last-5. Full detail on disk.
  local rf="$DIR/.m2herd/RESUME.md" body blines
  if grep -q '^-->$' "$rf" 2>/dev/null; then body="$(awk 'p{print} /^-->$/{p=1}' "$rf")"; else body="$(cat "$rf")"; fi
  blines="$(printf '%s\n' "$body" | wc -l | tr -d ' ')"
  if [ "$blines" -gt 20 ]; then
    printf '%s\n' "$body" | head -20
    echo "… ($((blines - 20)) more lines — read .m2herd/RESUME.md)"
  else
    printf '%s\n' "$body"
  fi
  echo
  echo "areas:"
  jq -r '
    def act: [ (.areas//[])[] | select((.status//"active")!="archived") ];
    (act[:8][] | "  - " + .name + ": " + (if (.summary//"")=="" then "(no summary)" else .summary end) + "  → " + .path),
    (if (act|length) > 8
     then "  …and " + ((act|length) - 8 | tostring) + " more areas — m2herd status for all"
     else empty end),
    (if ((.areas//[])|map(select((.status//"active")=="archived"))|length)>0
     then "  archived: " + ((.areas//[])|map(select((.status//"active")=="archived")|.name)|join(", "))
     else empty end)
  ' "$(OV)"
  local lf="$DIR/.m2herd/evolver/LESSONS.md" tail5
  if [ -f "$lf" ]; then
    tail5="$(live_tail "$lf" | awk 'NF' | tail -5)"
    if has_ink "$tail5"; then
      echo
      echo "Recent factory lessons:"
      printf '%s\n' "$tail5" | sed 's/^/  /'
    fi
  fi
}

# ---------- gist: the .m2herd → AMS memory bridge ------------------------------
gist_cmd() {
  resolve_dir; need_init
  local g
  g="$(jq -r '
    def act: (.areas//[]) | map(select((.status//"active")!="archived"));
    "m2herd gist — goal: " + (if (.goal//"")=="" then "(none)" else .goal end)
    + " [" + (.status//"active") + ", updated " + (.updated_at//"?") + ", "
    + (act|length|tostring) + " active area(s)]."
    + (if (act|length)>0
       then "\n" + (act | map("- " + .name + ": " + (if (.summary//"")=="" then "(no summary)" else .summary end)) | join("\n"))
       else "" end)
  ' "$(OV)")"
  if [ "$PUSH" -eq 1 ]; then
    if [ -n "${M2HERD_GIST_CMD:-}" ]; then
      printf '%s\n' "$g" | sh -c "$M2HERD_GIST_CMD"
      log "gist pushed via \$M2HERD_GIST_CMD"
    else
      printf '%s\n' "$g"
      log "note: \$M2HERD_GIST_CMD not set — printed the gist instead of pushing"
    fi
  else
    printf '%s\n' "$g"
  fi
}

# ---------- next: the self-prompting primitive --------------------------------
# first spawned|working worker whose pane is gone or idle (needs herdr to verify; else none).
# Headless workers (mode=headless, or pane_id "-"/empty) have no pane in `agent list`
# — never mark them gone from it; judge liveness by their recorded pid (kill -0)
# when present, else skip: a live headless worker must NOT trigger a collect nudge.
stale_worker() {
  command -v herdr >/dev/null 2>&1 || return 0
  local agents; agents="$(herdr agent list 2>/dev/null)" || return 0
  [ -n "$agents" ] || return 0
  jq -r '(.workers // [])[] | select(.state=="spawned" or .state=="working")
         | [.slice, (.pane_id // ""), (.mode // "tui"), ((.pid // "")|tostring)] | join("\u001f")' "$(OV)" \
  | while IFS=$'\x1f' read -r slice pane mode pid; do
      [ -n "$slice" ] || continue
      if [ "$mode" = "headless" ] || [ "$pane" = "-" ] || [ -z "$pane" ]; then
        if [ -n "$pid" ] && [ "$pid" != "null" ] && [ "$pid" -gt 0 ] 2>/dev/null; then
          kill -0 "$pid" 2>/dev/null || { echo "$slice"; break; }
        fi
        continue
      fi
      st="$(jq -r --arg p "$pane" '[.result.agents[]? | select(.pane_id==$p) | .agent_status][0] // "gone"' <<<"$agents")"
      if [ "$st" = "gone" ] || [ "$st" = "idle" ]; then echo "$slice"; break; fi
    done
}

# Is a machineroom tab (label machineroom, or pre-rename m2herd-notes) watching
# THIS repo? "Watching" = one of the tab's panes is cwd'd inside $DIR. Degrades
# to "yes" (suppressing the nudge) when herdr is absent/unreachable, and can be
# forced off with M2HERD_SKIP_ROOM_CHECK=1 (selftest runs in rooms-less tmpdirs).
machineroom_watching() {
  [ "${M2HERD_SKIP_ROOM_CHECK:-}" = "1" ] && return 0
  command -v herdr >/dev/null 2>&1 || return 0
  local tabs panes
  tabs="$(herdr tab list 2>/dev/null | jq -r '[.result.tabs[]? | select((.label//"")=="machineroom" or (.label//"")=="m2herd-notes") | .tab_id] | join(" ")' 2>/dev/null || true)"
  [ -n "$tabs" ] || { herdr status >/dev/null 2>&1 || return 0; return 1; }   # server down → suppress; up + no tabs → nudge
  local t
  for t in $tabs; do
    if herdr pane list 2>/dev/null | jq -e --arg t "$t" --arg d "$DIR" \
        '[.result.panes[]? | select(.tab_id==$t and ((.cwd//"") | startswith($d)))] | length > 0' >/dev/null 2>&1; then
      return 0
    fi
  done
  return 1
}

# active area with the biggest context.md (offload target for the budget rung)
largest_area() {
  local n sz best="" bestsz=0
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    sz="$(wc -c < "$DIR/.m2herd/context/$n/context.md" 2>/dev/null | tr -d ' ')" || sz=0
    case "$sz" in ''|*[!0-9]*) sz=0 ;; esac
    if [ "$sz" -gt "$bestsz" ]; then bestsz="$sz"; best="$n"; fi
  done < <(jq -r '(.areas//[])[] | select((.status//"active")!="archived") | .name' "$(OV)")
  printf '%s' "$best"
}

# mechanical priority walk — NO LLM, exactly one "NEXT: " line.
# Ladder order (first hit wins): drift → context budget (fresh bridge ≥75%) →
# steer inbox → machineroom up → coach intent (done_when) → refile notes →
# collect stale worker → failed worker → reap finished panes → open question →
# compare/dispatch.
next_cmd() {
  resolve_dir; need_init
  local m2="$DIR/.m2herd" w q bf pct mt big
  if ! drift_report >/dev/null; then
    echo "NEXT: context drift — run: m2herd sync"; return 0
  fi
  # budget rung: fresh (≤30 min) bridge file at ≥75% → offload before anything piles on
  bf="$(newest_bridge_file)"
  if [ -n "$bf" ]; then
    mt="$(file_mtime "$bf")"
    if [ $(( $(date -u +%s) - mt )) -le 1800 ]; then
      pct="$(bridge_pct "$bf")"
      if [ "$pct" -ge 75 ]; then
        big="$(largest_area)"; [ -n "$big" ] || big="<pick>"
        echo "NEXT: context at ${pct}% — offload: m2herd refile --area $big, or archive stale areas"; return 0
      fi
    fi
  fi
  if [ -f "$m2/inbox/STEER.md" ] && has_ink "$(live_tail "$m2/inbox/STEER.md")"; then
    echo "NEXT: drain steering — read .m2herd/inbox/STEER.md, act, then clear below the marker"; return 0
  fi
  if ! machineroom_watching; then
    echo "NEXT: bring up the machineroom — run: m2herd-up up --room-only --repo $DIR"; return 0
  fi
  if [ -z "$(jq -r '.done_when // ""' "$(OV)")" ]; then
    echo "NEXT: coach the intent — set done_when + record open_questions (m2herd.sh has no opinion; you do)"; return 0
  fi
  if has_ink "$(live_tail "$m2/NOTES.md")"; then
    echo "NEXT: refile notes — run: m2herd refile --area <pick>"; return 0
  fi
  w="$(stale_worker)"
  if [ -n "$w" ]; then
    echo "NEXT: collect worker $w — run: m2herd-up collect --slice $w"; return 0
  fi
  w="$(jq -r '[(.workers // [])[] | select((.state//"")=="failed") | .slice][0] // ""' "$(OV)")"
  if [ -n "$w" ]; then
    echo "NEXT: worker $w failed — read dispatch/$w.out.md, then retry or clean up"; return 0
  fi
  w="$(reapable_count)"
  if [ "${w:-0}" -gt 0 ] 2>/dev/null; then
    echo "NEXT: reap $w finished worker pane(s) — run: m2herd reap (idle agents hold API connections)"; return 0
  fi
  q="$(jq -r '(.open_questions // [])[0] // ""' "$(OV)")"
  if [ -n "$q" ]; then
    echo "NEXT: resolve open question: $q"; return 0
  fi
  echo "NEXT: compare RESUME.md against goal/done_when and dispatch or finish"
}

# ---------- boot: single-command entry point ----------------------------------
# init (if needed) + sync + resume + next, with a git-repo preflight. Worker
# dispatch relies on git worktrees/branches, so a non-git --dir gets a loud
# (but non-fatal) heads-up here — same tput-on-tty-else-plain pattern as dashboard.
boot() {
  resolve_dir
  local B="" Y="" R=""
  if { [ -t 1 ] || [ "${M2HERD_FORCE_TTY:-}" = "1" ]; } && command -v tput >/dev/null 2>&1; then
    B="$(tput bold 2>/dev/null || true)"; Y="$(tput setaf 3 2>/dev/null || true)"; R="$(tput sgr0 2>/dev/null || true)"
  fi
  if ! git -C "$DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    printf '%s⚠ WARNING: %s is not a git repository%s\n' "$B$Y" "$DIR" "$R" >&2
    printf '%sm2herd worker dispatch relies on git worktrees/branches — run `git init` first.%s\n' "$B$Y" "$R" >&2
  fi
  if [ -f "$(OV)" ]; then
    log "boot: .m2herd/ already present at $DIR/.m2herd — skipping init"
  else
    init
  fi
  sync_cmd
  resume_cmd
  next_cmd
}

# ---------- dashboard: tier-1 TUI — a pure read-only renderer -----------------
# One writer (the orchestrator), many watchers: this code path NEVER writes state.
# herdr READS (agent list) are allowed; herdr sends/closes are FORBIDDEN here.
epoch_of() { date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null || date -u -d "$1" +%s 2>/dev/null || echo 0; }
# GNU first, BSD fallback. GNU `stat -f` SUCCEEDS with a filesystem dump and GNU
# `date -r` means file-mtime, so the naive BSD-first || chains break on Linux.
file_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }
fmt_epoch()  { date -d "@$1" "+$2" 2>/dev/null || date -r "$1" "+$2" 2>/dev/null || true; }
age_secs() { # epoch → humanized 42s / 3m / 7h / 4d
  local now d
  [ "${1:-0}" -gt 0 ] || { echo "?"; return 0; }
  now="$(date -u +%s)"; d=$((now - $1)); [ "$d" -ge 0 ] || d=0
  if   [ "$d" -lt 60 ];    then echo "${d}s"
  elif [ "$d" -lt 3600 ];  then echo "$((d/60))m"
  elif [ "$d" -lt 86400 ]; then echo "$((d/3600))h"
  else                          echo "$((d/86400))d"; fi
}
age_of() { age_secs "$(epoch_of "${1:-}")"; }

# newest claude-ctx-*.json bridge file OWNED BY THIS UID under $BRIDGE_DIR
# (default /tmp; M2HERD_BRIDGE_DIR overrides — selftest isolation). Prints the
# path, or nothing. Null-safe glob loop — no `ls -t` word-splitting, and /tmp
# is world-writable so foreign-uid bridge files are ignored.
BRIDGE_DIR="${M2HERD_BRIDGE_DIR:-/tmp}"
newest_bridge_file() {
  local f="" c mt best=0
  for c in "$BRIDGE_DIR"/claude-ctx-*.json; do
    [ -f "$c" ] || continue                              # unmatched glob stays literal
    [ -O "$c" ] || continue                              # not ours → ignore
    jq -e '.used_pct|numbers' "$c" >/dev/null 2>&1 || continue
    mt="$(file_mtime "$c")"
    case "$mt" in ''|*[!0-9]*) mt=0 ;; esac   # never let a stat surprise reach the integer tests
    if [ "$mt" -gt "$best" ]; then best="$mt"; f="$c"; fi
  done
  [ -n "$f" ] && printf '%s' "$f"
  return 0
}
# integer used_pct from a bridge file ("83.4" → 83; garbage → 0)
bridge_pct() {
  local pct; pct="$(jq -r '.used_pct' "$1" 2>/dev/null)"; pct="${pct%.*}"
  case "$pct" in ''|*[!0-9]*) pct=0 ;; esac
  printf '%s' "$pct"
}

# budget row from the newest bridge file; silent no-op when none
budget_row() {
  local f pct budget best filled bar
  f="$(newest_bridge_file)"
  [ -n "$f" ] || return 0
  best="$(file_mtime "$f")"
  pct="$(bridge_pct "$f")"
  budget="$(jq -r '.budget // 384000' "$f")"
  filled=$((pct * 20 / 100)); [ "$filled" -le 20 ] || filled=20; [ "$filled" -ge 0 ] || filled=0
  bar="$(printf '%*s' "$filled" '' | tr ' ' '█')$(printf '%*s' "$((20 - filled))" '' | tr ' ' '░')"
  printf 'budget:    %s %s%% of %s · updated %s ago\n' "$bar" "$pct" "$budget" "$(age_secs "$best")"
}

settings_row() {
  [ -f "$(SETTINGS)" ] || return 0
  settings_effective_json | jq -r '"settings: workers=" + .workers.agent + "/" + .workers.runner
    + " max=" + (.workers.max|tostring)
    + " rules=" + ((.routing//[])|length|tostring)'
}

# plain (uncolored) blocks so the side-by-side column merge pads correctly
render_areas() {
  local names n astatus rel aage
  echo "AREAS"
  names="$(jq -r '(.areas//[])[].name' "$(OV)")"
  [ -n "$names" ] || { echo "  (no areas yet)"; return 0; }
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    astatus="$(jq -r --arg n "$n" '[.areas[]|select(.name==$n)|(.status//"active")][0]' "$(OV)")"
    rel="$(jq -r --arg n "$n" '[.areas[]|select(.name==$n)|(.related//[])|join(", ")][0] // ""' "$(OV)")"
    aage="$(age_of "$(hdr_get "$DIR/.m2herd/context/$n/context.md" updated)")"
    if [ "$astatus" = "archived" ]; then
      printf '  %-14s archived  %s\n' "$n" "$aage"
    else
      printf '  %-14s active    %-5s %s\n' "$n" "$aage" "${rel:+(related: $rel)}"
    fi
  done <<<"$names"
}
# desired vs observed: ONE `herdr agent list` query; mismatch marked "!"; degrades to "-"
render_workers() {
  local agents="" slice desired pane branch mode model tokens obs mark runner
  command -v herdr >/dev/null 2>&1 && agents="$(herdr agent list 2>/dev/null || true)"
  echo "WORKERS"
  printf '  %-10s %-9s %-10s %-14s %s\n' "slice" "desired" "observed" "runner" "branch"
  jq -r '(.workers//[])[] | [.slice, (.state//"?"), (.pane_id//""), (.branch//"-"),
         (.mode//"tui"), (.model//""), ((.tokens//"")|tostring)] | join("\u001f")' "$(OV)" \
  | while IFS=$'\x1f' read -r slice desired pane branch mode model tokens; do
      obs="-"; mark=""; runner="tui"
      if [ "$mode" = "headless" ]; then
        obs="headless"; runner="${model:-?}"
        # humanize the spend column (12345 -> 12k)
        if [ -n "$tokens" ]; then
          if [ "$tokens" -ge 1000 ] 2>/dev/null; then runner="$runner $((tokens / 1000))k"; else runner="$runner ${tokens}t"; fi
        fi
      elif [ -n "$agents" ]; then
        obs="$(jq -r --arg p "$pane" '[.result.agents[]? | select(.pane_id==$p) | .agent_status][0] // "gone"' <<<"$agents")"
        case "$desired:$obs" in
          spawned:idle|spawned:gone|working:idle|working:gone|done:working|failed:working) mark=" !" ;;
        esac
      fi
      printf '  %-10s %-9s %-10s %-14s %s\n' "$slice" "$desired" "$obs$mark" "$runner" "$branch"
    done
}

# ---------- self-update: keep the installed engine current --------------------
UPDATE_CACHE="$HOME/.cache/m2herd/update-status"

# engine repo root (through the symlink chain — $0 may be ~/.local/bin/m2herd)
engine_repo() { cd "$(dirname "$(self_path)")/.." 2>/dev/null && pwd; }

self_update_cmd() {
  need_jq
  local repo behind
  repo="$(engine_repo)" || { echo "self-update: cannot resolve engine repo" >&2; exit 1; }
  git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || { echo "self-update: $repo is not a git repo" >&2; exit 1; }
  mkdir -p "$(dirname "$UPDATE_CACHE")"
  if [ "$CHECK" -eq 1 ]; then
    if ! GIT_TERMINAL_PROMPT=0 git -C "$repo" fetch --quiet origin main 2>/dev/null; then
      printf 'unknown 0 %s\n' "$(ts)" > "$UPDATE_CACHE"
      echo "self-update: fetch failed (offline?) — status unknown"; return 0
    fi
    behind="$(git -C "$repo" rev-list --count HEAD..origin/main 2>/dev/null || echo 0)"
    if [ "$behind" -gt 0 ]; then
      printf 'behind %s %s\n' "$behind" "$(ts)" > "$UPDATE_CACHE"
      echo "update available: $behind commit(s) behind — run: m2herd self-update"
    else
      printf 'up-to-date 0 %s\n' "$(ts)" > "$UPDATE_CACHE"
      echo "m2herd up-to-date"
    fi
    return 0
  fi
  # real update: ff-only, never on a dirty tree
  if [ -n "$(git -C "$repo" status --porcelain 2>/dev/null)" ]; then
    echo "self-update: REFUSING — engine repo has uncommitted changes: $repo" >&2; exit 2
  fi
  GIT_TERMINAL_PROMPT=0 git -C "$repo" pull --ff-only origin main
  printf 'up-to-date 0 %s\n' "$(ts)" > "$UPDATE_CACHE"
  log "self-update: engine at $(git -C "$repo" log --oneline -1)"
}

# header row rendered by dashboard: only when the cached check is fresh (<24h) and behind
update_row() {
  local Y="$1" R="$2" word n when age now ep
  [ -f "$UPDATE_CACHE" ] || return 0
  read -r word n when < "$UPDATE_CACHE" 2>/dev/null || return 0
  [ "$word" = "behind" ] || return 0
  now="$(date -u +%s)"
  ep="$(epoch_of "$when")"
  # epoch_of returns 0 on parse failure → treat the check as fresh-unknown (age 0)
  if [ "${ep:-0}" -gt 0 ] 2>/dev/null; then
    age=$((now - ep)); [ "$age" -ge 0 ] || age=0
  else
    age=0
  fi
  [ "$age" -lt 86400 ] || return 0
  printf 'update:    %s%s commit(s) behind — run: m2herd self-update%s\n' "$Y" "$n" "$R"
}

# ---------- dashboard --watch: flicker-free repaint loop -----------------------
# Home-cursor redraw (no `clear` per frame → no blink); alt-screen + hidden
# cursor, restored on exit. Refreshes the self-update check every 10 min.
dashboard_watch() {
  local iv="$INTERVAL" chk=600 last=0 now frame stop=0
  case "$iv" in ''|*[!0-9]*) echo "dashboard --interval must be an integer >= 1 (got: $INTERVAL)" >&2; exit 2 ;; esac
  [ "$iv" -ge 1 ] || { echo "dashboard --interval must be an integer >= 1 (got: $INTERVAL)" >&2; exit 2; }
  if command -v tput >/dev/null 2>&1 && [ -t 1 ]; then
    tput smcup 2>/dev/null || true; tput civis 2>/dev/null || true
    # screen restore ONLY on EXIT; INT/TERM just flag the loop to break so the
    # last repaint can't race the restore (no repaint after rmcup)
    trap 'tput cnorm 2>/dev/null || true; tput rmcup 2>/dev/null || true' EXIT
  fi
  trap 'stop=1' INT TERM
  printf '\033[2J'
  while [ "$stop" -eq 0 ]; do
    now="$(date +%s)"
    if [ $((now - last)) -ge "$chk" ]; then
      ( CHECK=1 self_update_cmd >/dev/null 2>&1 ) || true
      last="$now"
    fi
    frame="$(M2HERD_FORCE_TTY=1 COLUMNS="${COLUMNS:-$(tput cols 2>/dev/null || echo 100)}" dashboard 2>&1 || true)"
    [ "$stop" -eq 0 ] || break
    printf '\033[H%s\n\033[0J' "$frame"
    sleep "$iv" || true
  done
}

dashboard() {
  resolve_dir; need_init
  local m2="$DIR/.m2herd" B="" D="" G="" Y="" RD="" C="" M="" R="" cols=80
  # colors on a tty, plain when piped; M2HERD_FORCE_TTY=1 keeps colors when the
  # frame is captured by --watch (which redraws it on a real tty).
  if { [ -t 1 ] || [ "${M2HERD_FORCE_TTY:-}" = "1" ]; } && command -v tput >/dev/null 2>&1; then
    B="$(tput bold 2>/dev/null || true)"; D="$(tput dim 2>/dev/null || true)"
    G="$(tput setaf 2 2>/dev/null || true)"; Y="$(tput setaf 3 2>/dev/null || true)"
    RD="$(tput setaf 1 2>/dev/null || true)"; C="$(tput setaf 6 2>/dev/null || true)"
    M="$(tput setaf 5 2>/dev/null || true)"
    R="$(tput sgr0 2>/dev/null || true)"
    cols="${COLUMNS:-$(tput cols 2>/dev/null || echo 80)}"
  fi
  # colorize a table block AFTER width-alignment so padding stays correct:
  # state words get their color, ANSI added post-join.
  paint_states() {
    if [ -n "$R" ]; then
      sed -e "s/ active /${G} active ${R}/g" -e "s/ archived/${D} archived${R}/g" \
          -e "s/ done / ${G}done${R} /g" -e "s/ working / ${Y}working${R} /g" \
          -e "s/ failed / ${RD}failed${R} /g" -e "s/ spawned / ${Y}spawned${R} /g"
    else cat; fi
  }
  # header: m2herd · <repo> ── ● <status> · drift ✓|◐  + goal / done_when / budget rows
  local goal st dw sdot dmark
  goal="$(jq -r 'if (.goal//"")=="" then "(none)" else .goal end' "$(OV)")"
  st="$(jq -r '.status//"active"' "$(OV)")"
  dw="$(jq -r 'if (.done_when//"")=="" then "(not coached)" else .done_when end' "$(OV)")"
  local scol=""
  if drift_report >/dev/null; then dmark="${G}✓${R}"; else dmark="${Y}◐${R}"; fi
  case "$st" in active) sdot="${G}●${R}"; scol="$G" ;; paused) sdot="${Y}●${R}"; scol="$Y" ;; *) sdot="●" ;; esac
  printf '%sm2herd%s · %s%s%s ── %s %s%s%s · drift %s\n' "$B$C" "$R" "$B" "$(basename "$DIR")" "$R" "$sdot" "$scol" "$st" "$R" "$dmark"
  printf '%sgoal:%s      %s\n' "$D" "$R" "$goal"
  printf '%sdone_when:%s %s\n' "$D" "$R" "$dw"
  budget_row
  settings_row | while IFS= read -r line; do [ -n "$line" ] && printf '%s%s%s\n' "$D" "$line" "$R"; done
  update_row "$Y" "$R"
  echo
  # the self-prompt (same code path as `next`) — bold magenta prefix
  local nx; nx="$(next_cmd)"
  printf '%sNEXT:%s%s\n' "$B$M" "$R" "${nx#NEXT:}"
  echo
  # AREAS + WORKERS: side-by-side on a wide tty (>=100 cols), stacked otherwise
  local ablock wblock=""
  ablock="$(render_areas)"
  if [ "$(jq -r '(.workers//[])|length' "$(OV)")" -gt 0 ]; then wblock="$(render_workers)"; fi
  if [ -n "$wblock" ] && [ "$cols" -ge 100 ]; then
    paste -d $'\t' <(printf '%s\n' "$ablock") <(printf '%s\n' "$wblock") \
      | awk -F'\t' '{printf "%-52s %s\n", $1, $2}' | paint_states
  else
    printf '%s\n' "$ablock" | paint_states
    if [ -n "$wblock" ]; then echo; printf '%s\n' "$wblock" | paint_states; fi
  fi
  # OPEN QUESTIONS (only when non-empty)
  if [ "$(jq -r '(.open_questions//[])|length' "$(OV)")" -gt 0 ]; then
    echo
    printf '%sOPEN QUESTIONS%s\n' "$B" "$R"
    jq -r '(.open_questions//[])[] | "  - " + .' "$(OV)"
  fi
  # NOTES tail: last 5 content lines below the marker; ISO timestamps rendered
  # local + human-short (HH:MM today, "Mon D HH:MM" otherwise), dimmed.
  echo
  printf '%sNOTES%s (last 5)\n' "$B" "$R"
  local tail5 line iso rest ep hum today
  tail5="$(live_tail "$m2/NOTES.md" | awk 'NF' | tail -5)"
  today="$(date +%Y-%m-%d)"
  if [ -n "$tail5" ]; then
    printf '%s\n' "$tail5" | while IFS= read -r line; do
      case "$line" in
        "- ["*Z"]"*)
          iso="${line#- [}"; iso="${iso%%]*}"; rest="${line#*\] }"
          ep="$(epoch_of "$iso")"
          if [ "${ep:-0}" -gt 0 ] 2>/dev/null; then
            if [ "$(fmt_epoch "$ep" %Y-%m-%d)" = "$today" ]; then hum="$(fmt_epoch "$ep" %H:%M)"; else hum="$(fmt_epoch "$ep" '%b %-d %H:%M')"; fi
            printf '  - %s[%s]%s %s\n' "$D" "$hum" "$R" "$rest"
          else printf '  %s\n' "$line"; fi ;;
        *) printf '  %s\n' "$line" ;;
      esac
    done
  else echo "  (empty)"; fi
  echo
  printf '%sread-only · steering: .m2herd/inbox/STEER.md%s\n' "$D" "$R"
}

# ---------- evolve: continual-harness factory evolver -------------------------
# .m2herd/runs/ (written by m2herd-up.sh) → .m2herd/evolver/{signatures,proposals,LESSONS.md}
# Mechanical only — no LLM, no network; same doctrine as `next`. See
# .m2herd/dispatch/_evolver-contract.md for the binding file/format contract.
evolve_dirs() {
  RUNS_DIR="$DIR/.m2herd/runs"
  EVO_DIR="$DIR/.m2herd/evolver"
  mkdir -p "$EVO_DIR/signatures" "$EVO_DIR/proposals"
}

# --run <id|latest|current> (default: current, falling back to latest); prints
# the resolved run-id, or nothing if none can be found.
resolve_run_id() {
  local want="${RUN:-current}" id
  case "$want" in
    latest)
      ls -1 "$RUNS_DIR" 2>/dev/null | grep '^r-' | sort | tail -1 || true ;;
    current|"")
      if [ -f "$RUNS_DIR/CURRENT" ] && [ -s "$RUNS_DIR/CURRENT" ]; then
        id="$(cat "$RUNS_DIR/CURRENT")"
        if [ -n "$id" ] && [ -d "$RUNS_DIR/$id" ]; then printf '%s' "$id"; return 0; fi
      fi
      ls -1 "$RUNS_DIR" 2>/dev/null | grep '^r-' | sort | tail -1 || true ;;
    *)
      validate_token "run id" "$want"
      [ -d "$RUNS_DIR/$want" ] && printf '%s' "$want" ;;
  esac
}

ensure_lessons_file() {
  local lf="$EVO_DIR/LESSONS.md"
  [ -f "$lf" ] || cat > "$lf" <<EOF
# Factory Lessons

Accepted lessons from the m2herd factory evolver. Do not hand-edit above the marker.

$MARKER
EOF
}
# append "- [ts] (<proposal-id>) <lesson>" to LESSONS.md, once per proposal-id;
# the dedup-check + append is a read-modify-write → serialized per the locking convention
append_lesson_once() {
  local pid="$1" lesson="$2" lf
  [ -n "$lesson" ] || return 0
  ensure_lessons_file
  lf="$EVO_DIR/LESSONS.md"
  with_lock "$lf.lock" append_lesson_locked "$pid" "$lesson" "$lf"
}
append_lesson_locked() {
  live_tail "$3" | grep -qF "($1)" && return 0
  printf -- '- [%s] (%s) %s\n' "$(ts)" "$1" "$2" >> "$3"
}

# kebab slug from a signature kind + its "slice:<name>" where field
slug_of() {
  printf '%s-%s' "$1" "$2" \
    | tr '[:upper:]_' '[:lower:]-' | tr -c 'a-z0-9-' '-' | tr -s '-' | sed -e 's/^-//' -e 's/-$//'
}

# write_proposal <id> <run> <kind> <target> <risk> <status> <lesson> <evidence>
write_proposal() {
  cat > "$EVO_DIR/proposals/$1.md" <<EOF
---
id: $1
run: $2
kind: $3
target: $4
risk: $5
status: $6
lesson: $7
---

## Observed failure
$8

## Proposed change
Append this lesson to LESSONS.md so future dispatches carry it forward.

## Rollback
Remove the corresponding lesson line from .m2herd/evolver/LESSONS.md and reject this proposal.

## Acceptance check
Next run of this slice/signature does not recur.
EOF
}

evolve_analyze() {
  resolve_dir; need_init; evolve_dirs
  if [ ! -d "$RUNS_DIR" ] || [ -z "$(ls -d "$RUNS_DIR"/r-* 2>/dev/null)" ]; then
    log "no run traces at .m2herd/runs/ yet — dispatch a herd first (m2herd-up dispatch)"
    return 0
  fi
  local run_id; run_id="$(resolve_run_id || true)"
  if [ -z "$run_id" ]; then
    log "no matching run found for --run ${RUN:-current}"
    return 0
  fi
  local run_dir="$RUNS_DIR/$run_id" run_json="$RUNS_DIR/$run_id/run.json"
  local sig_file="$EVO_DIR/signatures/$run_id.json"
  local sigs="[]" slices slice sdir status_f report_f fail_f

  slices="$(jq -r '.slices[]? // empty' "$run_json" 2>/dev/null || true)"
  while IFS= read -r slice; do
    [ -n "$slice" ] || continue
    sdir="$run_dir/slices/$slice"
    status_f="$sdir/status.json"; report_f="$sdir/report.md"; fail_f="$sdir/failures.json"
    if [ ! -d "$sdir" ] || [ ! -f "$status_f" ]; then
      sigs="$(jq --arg w "slice:$slice" --arg e "status.json missing for dispatched slice $slice" \
        '. + [{kind:"missing_status", severity:"medium", where:$w, evidence:$e, confidence:"medium", source:"mechanical"}]' <<<"$sigs")"
      continue
    fi
    if jq -e '.state=="failed"' "$status_f" >/dev/null 2>&1; then
      sigs="$(jq --arg w "slice:$slice" --arg e "status.json state=failed for slice $slice" \
        '. + [{kind:"slice_failed", severity:"high", where:$w, evidence:$e, confidence:"high", source:"mechanical"}]' <<<"$sigs")"
    fi
    if [ ! -s "$report_f" ]; then
      sigs="$(jq --arg w "slice:$slice" --arg e "report.md missing or empty for slice $slice" \
        '. + [{kind:"missing_report", severity:"medium", where:$w, evidence:$e, confidence:"medium", source:"mechanical"}]' <<<"$sigs")"
    fi
    if [ -s "$fail_f" ]; then
      sigs="$(jq --slurpfile extra "$fail_f" \
        '. + ([$extra[0][]? | {kind, severity, where, evidence, confidence:"high", source:"failures.json"}])' <<<"$sigs")"
    fi
  done <<<"$slices"

  local sig_tmp; sig_tmp="$(mktemp "$EVO_DIR/signatures/.sig.XXXXXX")"
  if printf '%s' "$sigs" | jq '.' > "$sig_tmp"; then mv "$sig_tmp" "$sig_file"; else rm -f "$sig_tmp"; return 1; fi
  local n; n="$(jq 'length' <<<"$sigs")"
  log "wrote signatures → .m2herd/evolver/signatures/$run_id.json ($n signature(s))"

  local today created=0 i kind where evidence slice_name slug pid lesson seen_pids="" dup
  today="$(date -u +%Y-%m-%d)"
  if [ "$n" -gt 0 ]; then
    for i in $(seq 0 $((n - 1))); do
      kind="$(jq -r ".[$i].kind" <<<"$sigs")"
      where="$(jq -r ".[$i].where" <<<"$sigs")"
      evidence="$(jq -r ".[$i].evidence" <<<"$sigs")"
      slice_name="${where#slice:}"
      slug="$(slug_of "$kind" "$slice_name")"
      pid="${today}-${run_id}-${slug}"
      # distinct signatures may share (kind, slice) — suffix the within-pass ordinal so
      # every signature gets its own proposal file and re-runs regenerate the SAME ids
      dup="$(printf '%s' "$seen_pids" | grep -cxF "$pid" || true)"   # -F: ids contain dots — never regex-match
      seen_pids="$seen_pids$pid
"
      [ "$dup" -gt 0 ] && pid="$pid-$((dup + 1))"
      if [ ! -f "$EVO_DIR/proposals/$pid.md" ]; then
        evidence="$(printf '%s' "$evidence" | tr '\n' ' ')"
        lesson="signature $kind at $where: $evidence"
        write_proposal "$pid" "$run_id" "memory" ".m2herd/evolver/LESSONS.md" "low" "proposed" "$lesson" "$evidence"
        created=$((created + 1))
      fi
    done
  fi
  log "proposals: $created new (re-run is idempotent — keyed on proposal-id)"
}

evolve_proposals() {
  resolve_dir; need_init; evolve_dirs
  local files f id kind risk status out
  files="$(ls -1 "$EVO_DIR"/proposals/*.md 2>/dev/null | sort || true)"
  if [ -z "$files" ]; then log "no proposals yet — run: m2herd evolve analyze"; return 0; fi
  # accumulate then print once (a single write) so a downstream `grep -q`/`head`
  # closing the pipe early can't SIGPIPE us mid-loop
  out="$(printf '%-46s %-16s %-6s %s' "id" "kind" "risk" "status")"
  while IFS= read -r f; do
    id="$(frontmatter_get "$f" id)"; kind="$(frontmatter_get "$f" kind)"
    risk="$(frontmatter_get "$f" risk)"; status="$(frontmatter_get "$f" status)"
    out="$out
$(printf '%-46s %-16s %-6s %s' "$id" "$kind" "$risk" "$status")"
  done <<< "$files"
  printf '%s\n' "$out"
}

evolve_show() {
  resolve_dir; need_init; evolve_dirs
  [ -n "$TEXT" ] || { echo "evolve show needs a proposal id: m2herd evolve show <id>" >&2; exit 2; }
  # token has no '/' or '..' → resolved path stays under .m2herd/evolver/proposals/
  validate_token "proposal id" "$TEXT"
  local f="$EVO_DIR/proposals/$TEXT.md"
  [ -f "$f" ] || { echo "no such proposal: $TEXT" >&2; exit 1; }
  cat "$f"
}

evolve_apply() {
  resolve_dir; need_init; evolve_dirs
  [ -n "$TEXT" ] || { echo "evolve apply needs a proposal id: m2herd evolve apply <id>" >&2; exit 2; }
  # token has no '/' or '..' → resolved path stays under .m2herd/evolver/proposals/
  validate_token "proposal id" "$TEXT"
  local f="$EVO_DIR/proposals/$TEXT.md"
  [ -f "$f" ] || { echo "no such proposal: $TEXT" >&2; exit 1; }
  local kind target status lesson
  kind="$(frontmatter_get "$f" kind)"; target="$(frontmatter_get "$f" target)"
  status="$(frontmatter_get "$f" status)"; lesson="$(frontmatter_get "$f" lesson)"
  if [ "$status" = "applied" ]; then log "already applied: $TEXT"; return 0; fi
  case "$kind" in
    memory|policy)
      append_lesson_once "$TEXT" "$lesson"
      set_status "$f" "applied"
      log "applied $TEXT → lesson recorded in .m2herd/evolver/LESSONS.md"
      ;;
    template)
      case "$target" in
        .m2herd/*) : ;;
        *) echo "evolve apply: template target must be under .m2herd/ (got: $target) — refusing" >&2; exit 1 ;;
      esac
      append_lesson_once "$TEXT" "$lesson"
      set_status "$f" "applied"
      log "applied $TEXT (template target: $target)"
      ;;
    repo)
      if [ "$ACK_REPO" -eq 1 ]; then
        set_status "$f" "applied"
        log "applied $TEXT (--ack-repo) — repo target was NOT edited: $target"
      else
        log "repo-kind proposal — NOT auto-editing $target"
        log "recommendation: open a branch, apply by hand from .m2herd/evolver/proposals/$TEXT.md; re-run 'evolve apply $TEXT --ack-repo' once done"
      fi
      ;;
    *) echo "evolve apply: unknown kind '$kind' in $TEXT" >&2; exit 1 ;;
  esac
}

evolve_reject() {
  resolve_dir; need_init; evolve_dirs
  [ -n "$TEXT" ] || { echo "evolve reject needs a proposal id: m2herd evolve reject <id>" >&2; exit 2; }
  # token has no '/' or '..' → resolved path stays under .m2herd/evolver/proposals/
  validate_token "proposal id" "$TEXT"
  local f="$EVO_DIR/proposals/$TEXT.md"
  [ -f "$f" ] || { echo "no such proposal: $TEXT" >&2; exit 1; }
  set_status "$f" "rejected"
  log "rejected $TEXT"
}

# ---------- reap: close panes of finished workers ------------------------------
# A pane worker that reached done|failed keeps its claude/codex TUI session
# alive — an idle process still holding an API connection slot. reap closes
# those panes mechanically and clears the pane_id bookkeeping in overview.json.
# Safety mirrors m2herd-up.sh: NEVER $SELF (unknown self = fail safe, skip),
# never a pane whose LIVE agent_status is still "working" (state mismatch —
# collect first), headless workers untouched (no pane to close).
#
# Self resolution (same idiom as m2herd-up.sh): walk THIS process's ancestry
# and match agent-binary ancestors' cwd against `herdr agent list`. Ambiguous
# or unreachable → $SELF stays EMPTY = UNKNOWN, and maybe_self() treats
# unknown as "could be me".
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
maybe_self() {
  if [ -z "$SELF" ]; then
    log "! \$SELF unresolved — treating pane $1 as possibly-self (fail safe)"
    return 0
  fi
  [ "$1" = "$SELF" ]
}

# count of finished pane workers whose pane still exists in the fleet — the
# `next` reap rung; 0 when herdr is absent/unreachable (nothing actionable)
reapable_count() {
  command -v herdr >/dev/null 2>&1 || { echo 0; return 0; }
  local agents panes
  agents="$(herdr agent list 2>/dev/null || true)"
  [ -n "$agents" ] || { echo 0; return 0; }
  panes="$(jq -c '[.result.agents[]?.pane_id]' <<<"$agents" 2>/dev/null || echo '[]')"
  jq -r --argjson p "$panes" '
    [ (.workers//[])[]
      | select((.state//"")=="done" or (.state//"")=="failed")
      | select((.mode//"tui")!="headless")
      | select(((.pane_id//"") != "") and ((.pane_id//"") != "-"))
      | select(.pane_id | IN($p[])) ] | length' "$(OV)" 2>/dev/null || echo 0
}

reap_cmd() {
  resolve_dir; need_init
  command -v herdr >/dev/null 2>&1 || { log "reap: herdr not on PATH — no panes to close"; return 0; }
  local agents; agents="$(herdr agent list 2>/dev/null || true)"
  [ -n "$agents" ] || { log "reap: herdr server unreachable — no panes to close"; return 0; }
  resolve_self
  local closed=0 gone=0 skipped=0 slice state pane mode obs
  # the jq snapshot streams from the pre-rewrite inode; ov_put's atomic rename
  # inside the loop cannot corrupt this read
  while IFS=$'\x1f' read -r slice state pane mode; do
    [ -n "$slice" ] || continue
    case "$state" in done|failed) : ;; *) continue ;; esac
    if [ "$mode" = "headless" ] || [ "$pane" = "-" ] || [ -z "$pane" ]; then continue; fi
    obs="$(jq -r --arg p "$pane" '[.result.agents[]? | select(.pane_id==$p) | .agent_status][0] // "gone"' <<<"$agents")"
    if [ "$obs" = "gone" ]; then
      if [ "$DRYRUN" -eq 1 ]; then
        log "reap: would clear pane bookkeeping for $slice (pane $pane already gone)"
      else
        ov_put --arg s "$slice" '.workers = [ .workers[] | if .slice==$s then .pane_id="-" else . end ]'
        log "reap: pane $pane already gone — cleared bookkeeping for $slice"
      fi
      gone=$((gone + 1)); continue
    fi
    if [ "$obs" = "working" ]; then
      log "reap: SKIP $slice — pane $pane still working (state=$state mismatch; collect first)"
      skipped=$((skipped + 1)); continue
    fi
    if maybe_self "$pane"; then
      log "reap: SKIP $slice — pane $pane is (or could be) \$SELF"
      skipped=$((skipped + 1)); continue
    fi
    if [ "$DRYRUN" -eq 1 ]; then
      log "reap: would close pane $pane ($slice, state=$state, observed=$obs)"
    else
      herdr pane close "$pane" >/dev/null 2>&1 || true   # already-gone is fine
      ov_put --arg s "$slice" '.workers = [ .workers[] | if .slice==$s then .pane_id="-" else . end ]'
      log "reap: closed pane $pane ($slice, state=$state)"
    fi
    closed=$((closed + 1))
  done < <(jq -r '(.workers//[])[] | [.slice, (.state//"?"), (.pane_id//""), (.mode//"tui")] | join("\u001f")' "$(OV)")
  local suffix=""; [ "$DRYRUN" -eq 1 ] && suffix=" (dry-run — nothing touched)"
  log "reap: $closed closed, $gone already gone, $skipped skipped$suffix"
}

# ---------- doctor: one command answering "why is it not working" -------------
# Each check prints ok|warn|FAIL|note + a one-line remedy. Exit 1 iff any FAIL
# (warns don't fail). FAIL is reserved for hard breakage: jq/git missing, herdr
# installed but its server dead, a PATH symlink whose target file is gone, and
# fabric drift. Environment nits (herdr not installed, hooks/statusline not
# registered, node/go absent) are warns/notes — the fabric still works degraded.
doctor_cmd() {
  DIR="$(cd "$DIR" 2>/dev/null && pwd)" || { echo "no such dir: $DIR" >&2; exit 1; }
  local fails=0 warns=0 settings="$HOME/.claude/settings.json"
  d_ok()   { printf '  ok    %s\n' "$*"; }
  d_note() { printf '  note  %s\n' "$*"; }
  d_warn() { printf '  warn  %s\n' "$*"; warns=$((warns + 1)); }
  d_fail() { printf '  FAIL  %s\n' "$*"; fails=$((fails + 1)); }
  echo "m2herd doctor — $DIR"

  # core tools (doctor itself must not die on missing jq — it reports it)
  if command -v jq  >/dev/null 2>&1; then d_ok "jq present"
  else d_fail "jq missing — install it (apt/brew install jq); every fabric write needs it"; fi
  if command -v git >/dev/null 2>&1; then d_ok "git present"
  else d_fail "git missing — install it; worker dispatch needs worktrees/branches"; fi

  # herdr: absent → graceful skip (headless workers still work); present+dead server → FAIL
  if command -v herdr >/dev/null 2>&1; then
    if herdr status >/dev/null 2>&1; then d_ok "herdr on PATH + server responds"
    else d_fail "herdr on PATH but server not responding — start the herdr app/server"; fi
  else
    d_warn "herdr not on PATH — pane workers unavailable (headless still works); skipping server check"
  fi

  # PATH symlinks: missing → warn; target file gone → FAIL; target in a
  # different repo than this engine → warn (stale-symlink detection)
  local engine name link tgt tgt_repo
  engine="$(engine_repo 2>/dev/null || true)"
  for name in m2herd m2herd-up; do
    link="$(command -v "$name" 2>/dev/null || true)"
    if [ -z "$link" ]; then
      d_warn "$name not on PATH — run: scripts/install.sh (symlinks into ~/.local/bin)"
      continue
    fi
    tgt="$(resolve_link "$link")"
    if [ ! -f "$tgt" ]; then
      d_fail "$name → $tgt is gone (dangling symlink) — re-run: scripts/install.sh"
      continue
    fi
    tgt_repo="$(cd "$(dirname "$tgt")/.." 2>/dev/null && pwd || true)"
    if [ -n "$engine" ] && [ -n "$tgt_repo" ] && [ "$tgt_repo" != "$engine" ]; then
      d_warn "$name points at another repo ($tgt) — stale symlink? this engine: $engine"
    else
      d_ok "$name on PATH → $tgt"
    fi
  done

  # node (the m2herd-budget.js PostToolUse hook runs under node)
  if command -v node >/dev/null 2>&1; then d_ok "node present (budget hook can run)"
  else d_warn "node missing — m2herd-budget.js hook inert; install node for budget sensing"; fi

  # hooks registered in ~/.claude/settings.json — keyed on FILENAME (commands
  # embed node/nvm paths that change across upgrades; see install.sh)
  if [ -f "$settings" ]; then
    local h missing=""
    for h in m2herd-session.sh m2herd-precompact.sh m2herd-budget.js; do
      grep -q "$h" "$settings" 2>/dev/null || missing="$missing $h"
    done
    if [ -z "$missing" ]; then d_ok "m2herd hooks registered in ~/.claude/settings.json"
    else d_warn "hooks not registered:$missing — run: scripts/install.sh"; fi
  else
    d_warn "no ~/.claude/settings.json — Claude Code not set up here? run: scripts/install.sh"
  fi

  # statusline/ctx bridge: WRITER registered (statusLine key) + a fresh (≤30 min)
  # bridge file — both, or budget sensing is dead
  local bf="" fresh=0 mt
  bf="$(newest_bridge_file)"
  if [ -n "$bf" ]; then
    mt="$(file_mtime "$bf")"
    [ $(( $(date -u +%s) - mt )) -le 1800 ] && fresh=1
  fi
  if grep -q '"statusLine"' "$settings" 2>/dev/null && [ "$fresh" -eq 1 ]; then
    d_ok "statusline bridge registered + fresh $(basename "$bf") ($(bridge_pct "$bf")% used)"
  else
    d_warn "budget sensing dead — register scripts/ctx-bridge.sh as statusline (needs a statusLine entry in ~/.claude/settings.json writing $BRIDGE_DIR/claude-ctx-<session>.json)"
  fi

  # fabric in the target dir + drift
  if [ -f "$DIR/.m2herd/overview.json" ]; then
    if command -v jq >/dev/null 2>&1; then
      if drift_report >/dev/null 2>&1; then d_ok ".m2herd/ present, overview.json matches context/ tree"
      else d_fail ".m2herd/ drifted — run: m2herd sync --dir $DIR"; fi
    else
      d_warn ".m2herd/ present but jq missing — cannot drift-check"
    fi
  else
    d_warn "no .m2herd/ at $DIR — bootstrap it: m2herd boot --dir $DIR"
  fi

  # go toolchain: optional (tier-3 TUI only) — note, never a warn/FAIL
  if command -v go >/dev/null 2>&1; then d_note "go toolchain present — m2herd-tui buildable (optional)"
  else d_note "go toolchain absent — m2herd-tui (optional) unavailable; bash dashboard still works"; fi

  echo
  if [ "$fails" -gt 0 ]; then
    echo "doctor: $fails FAIL, $warns warn — fix the FAIL lines above"
    exit 1
  fi
  echo "doctor: healthy ($warns warn)"
}

# ---------- selftest: tmpdir end-to-end ---------------------------------------
selftest() {
  need_jq
  # tmpdir fixtures have no machineroom; suppress the room nudge so the other
  # next-cases stay assertable (the room case is verified live, not here).
  export M2HERD_SKIP_ROOM_CHECK=1
  local self ov rc lp1 lp2
  self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  # td/td2/td3 stay global (NOT local): the EXIT trap fires after this function
  # returns, so locals would already be gone — all three are registered here
  td="$(mktemp -d)"; td2=""; td3=""
  trap 'rm -rf "$td" ${td2:+"$td2"} ${td3:+"$td3"}' EXIT
  echo "selftest: workdir $td"
  # bridge isolation: the budget rung/row must not see the REAL /tmp bridge
  # files of whatever Claude session happens to be running this selftest
  mkdir -p "$td/bridge"; export M2HERD_BRIDGE_DIR="$td/bridge"
  step() { echo "+ m2herd.sh $*"; "$self" "$@" >/dev/null || { echo "selftest FAIL at: $*" >&2; exit 1; }; }
  fail() { echo "selftest FAIL: $*" >&2; exit 1; }

  # end-to-end: init → note → refile → sync → status → resume
  step init --dir "$td" --goal "selftest goal"
  step init --dir "$td"                          # idempotent re-init (must not clobber the goal)
  step note --dir "$td" "first note for demo"
  step refile --dir "$td" --area demo
  step sync --dir "$td"
  step status --dir "$td"
  step resume --dir "$td"

  ov="$td/.m2herd/overview.json"
  jq -e '
    (.goal=="selftest goal") and (.status=="active")
    and (.updated_at|type=="string" and length>0)
    and (.areas|type=="array") and (.workers|type=="array")
    and (.notes_file==".m2herd/NOTES.md") and (.resume_file==".m2herd/RESUME.md")
    and (.done_when=="") and (.open_questions==[])
    and (.areas[0].name=="demo")
  ' "$ov" >/dev/null || { cat "$ov" >&2; fail "overview.json schema assert"; }
  grep -q "first note for demo" "$td/.m2herd/context/demo/context.md" \
    || fail "note was not refiled into context/demo/context.md"
  if live_tail "$td/.m2herd/NOTES.md" | grep -q '[^[:space:]]'; then
    fail "NOTES.md live section not reset after refile"
  fi
  grep -qxF '.m2herd/' "$td/.gitignore" || fail ".m2herd/ not gitignored"
  [ -f "$td/.m2herd/inbox/STEER.md" ] || fail "init did not scaffold inbox/STEER.md"
  [ -f "$td/.m2herd/settings.json" ] || fail "init did not seed settings.json"

  # config: defaults, get/set round-trip, validation, missing-file fallback, JSON routing, locked writers
  [ "$("$self" config get workers.agent --dir "$td")" = "claude" ] || fail "config get: default workers.agent"
  rm -f "$td/.m2herd/settings.json"
  [ "$("$self" config get workers.max --dir "$td")" = "3" ] || fail "config get: missing settings.json should return defaults"
  printf '{not json\n' > "$td/.m2herd/settings.json"
  [ "$("$self" config get workers.agent --dir "$td")" = "claude" ] || fail "config get: invalid settings.json should return defaults"
  step config set workers.agent codex --dir "$td"
  [ "$("$self" config get workers.agent --dir "$td")" = "codex" ] || fail "config set/get workers.agent round-trip"
  "$self" config list --dir "$td" | grep -q '^\* workers.agent=codex$' || fail "config list did not mark non-default workers.agent"
  rc=0; "$self" config set workers.agent bogus --dir "$td" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "config set invalid enum exited $rc (want 2)"
  step config set workers.max 5 --dir "$td"
  # v1 schema completion: base/model strings, settle/wait numerics with floors
  [ "$("$self" config get workers.settle_seconds --dir "$td")" = "2" ] || fail "config get: default workers.settle_seconds"
  [ "$("$self" config get workers.wait_timeout_minutes --dir "$td")" = "30" ] || fail "config get: default workers.wait_timeout_minutes"
  step config set workers.base main --dir "$td"
  [ "$("$self" config get workers.base --dir "$td")" = "main" ] || fail "config set/get workers.base round-trip"
  step config set workers.model gpt-5.2-codex --dir "$td"
  [ "$("$self" config get workers.model --dir "$td")" = "gpt-5.2-codex" ] || fail "config set/get workers.model round-trip"
  step config set workers.settle_seconds 4 --dir "$td"
  [ "$("$self" config get workers.settle_seconds --dir "$td")" = "4" ] || fail "config set/get workers.settle_seconds round-trip"
  step config set workers.wait_timeout_minutes 45 --dir "$td"
  [ "$("$self" config get workers.wait_timeout_minutes --dir "$td")" = "45" ] || fail "config set/get workers.wait_timeout_minutes round-trip"
  rc=0; "$self" config set workers.settle_seconds -1 --dir "$td" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "config set workers.settle_seconds -1 exited $rc (want 2)"
  rc=0; "$self" config set workers.wait_timeout_minutes 0 --dir "$td" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "config set workers.wait_timeout_minutes 0 exited $rc (want 2)"
  # routing entries: optional runner (pane|headless) + model accepted; bogus runner rejected
  step config set routing '[{"pattern":"*.rs","agent":"codex","runner":"headless","model":"gpt-5.2"}]' --dir "$td"
  [ "$("$self" config get routing --dir "$td" | jq -r '.[0].runner')" = "headless" ] || fail "routing entry lost its runner field"
  rc=0; "$self" config set routing '[{"pattern":"*.rs","agent":"codex","runner":"bogus"}]' --dir "$td" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "config set routing with bogus runner exited $rc (want 2)"
  step config set routing '[{"pattern":"*.go","agent":"codex"},{"pattern":"docs/**","agent":"claude"}]' --dir "$td"
  [ "$("$self" config get routing --dir "$td" | jq 'length')" = "2" ] || fail "config set/get routing JSON array"
  "$self" config set orchestrator.agent cursor --dir "$td" >/dev/null 2>&1 & lp1=$!
  "$self" config set workers.runner headless --dir "$td" >/dev/null 2>&1 & lp2=$!
  wait "$lp1" || fail "concurrent config writer A exited non-zero"
  wait "$lp2" || fail "concurrent config writer B exited non-zero"
  [ "$("$self" config get orchestrator.agent --dir "$td")" = "cursor" ] || fail "concurrent config set lost orchestrator.agent"
  [ "$("$self" config get workers.runner --dir "$td")" = "headless" ] || fail "concurrent config set lost workers.runner"

  # next STEER case: live steering outranks coach-intent (done_when is still empty here)
  printf 'PAUSE everything please\n' >> "$td/.m2herd/inbox/STEER.md"
  "$self" next --dir "$td" | grep -q '^NEXT: drain steering' || fail "next(steer): want drain-steering"
  keep_head "$td/.m2herd/inbox/STEER.md" > "$td/.m2herd/inbox/STEER.md.new" \
    && mv "$td/.m2herd/inbox/STEER.md.new" "$td/.m2herd/inbox/STEER.md"

  # next case 2: done_when empty → coach the intent
  "$self" next --dir "$td" | grep -q '^NEXT: coach the intent' || fail "next(2): want coach-the-intent"
  jq '.done_when="demo context refiled and synced"' "$ov" > "$ov.tmp" && mv "$ov.tmp" "$ov"
  # next case 3: loose content below the NOTES.md marker → refile
  step note --dir "$td" "loose note awaiting refile"
  "$self" next --dir "$td" | grep -q '^NEXT: refile notes' || fail "next(3): want refile-notes"
  step refile --dir "$td" --area demo

  # drift: mutate the tree → --check exits 3; plain sync repairs; --check then exits 0
  mkdir -p "$td/.m2herd/context/extra/deep"
  printf -- '---\narea: extra\nrelated: []\ndeep: ./deep/\nupdated: %s\n---\nextra area body\n' "$(ts)" \
    > "$td/.m2herd/context/extra/context.md"
  rc=0; "$self" sync --check --dir "$td" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 3 ] || fail "sync --check exited $rc on drifted tree (want 3)"
  # next case 1: drift outranks everything
  "$self" next --dir "$td" | grep -q '^NEXT: context drift' || fail "next(1): want context-drift"
  step sync --dir "$td"
  rc=0; "$self" sync --check --dir "$td" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || fail "sync --check exited $rc after repair (want 0)"

  # archive: distill + mark archived; deep/ untouched; survives sync; rendered as footer
  printf 'deep dive artifact\n' > "$td/.m2herd/context/extra/deep/artifact.txt"
  step archive --dir "$td" --area extra
  jq -e '.areas[] | select(.name=="extra") | .status=="archived"' "$ov" >/dev/null \
    || fail "overview.json area 'extra' not marked archived"
  grep -q '^status: archived' "$td/.m2herd/context/extra/context.md" \
    || fail "archived context.md header missing 'status: archived'"
  [ -f "$td/.m2herd/context/extra/deep/artifact.txt" ] || fail "archive touched deep/"
  step sync --dir "$td"
  jq -e '.areas[] | select(.name=="extra") | .status=="archived"' "$ov" >/dev/null \
    || fail "sync lost the archived status"
  "$self" status --dir "$td" | grep -q '^archived: extra' || fail "status missing archived one-line footer"
  "$self" resume --dir "$td" | grep -q 'archived: extra'  || fail "resume missing archived one-line footer"

  # gist: goal + ACTIVE areas only; --push degrades to print without $M2HERD_GIST_CMD
  "$self" gist --dir "$td" | grep -q "selftest goal" || fail "gist missing the goal"
  if "$self" gist --dir "$td" | grep -q -- '- extra:'; then fail "gist lists an archived area"; fi
  "$self" gist --dir "$td" | grep -q -- '- demo:' || fail "gist missing the active area line"
  M2HERD_GIST_CMD='cat > /dev/null' "$self" gist --dir "$td" --push >/dev/null \
    || fail "gist --push via \$M2HERD_GIST_CMD"
  "$self" gist --dir "$td" --push | grep -q 'M2HERD_GIST_CMD not set' \
    || fail "gist --push without \$M2HERD_GIST_CMD should print with a note"

  # next case 5: open_questions outrank the steady state
  jq '.open_questions=["which DB backs the demo area?"]' "$ov" > "$ov.tmp" && mv "$ov.tmp" "$ov"
  "$self" next --dir "$td" | grep -q '^NEXT: resolve open question: which DB' || fail "next(5): want open-question"
  jq '.open_questions=[]' "$ov" > "$ov.tmp" && mv "$ov.tmp" "$ov"
  # next case 5b: a failed worker outranks open questions and the steady state
  jq '.workers=[{slice:"sliceX", state:"failed", pane_id:"-", branch:"wip/m2herd-sliceX"}]' "$ov" > "$ov.tmp" && mv "$ov.tmp" "$ov"
  "$self" next --dir "$td" | grep -q '^NEXT: worker sliceX failed — read dispatch/sliceX.out.md' \
    || fail "next(5b): want failed-worker line"
  jq '.workers=[]' "$ov" > "$ov.tmp" && mv "$ov.tmp" "$ov"
  # next case 6: nothing pending → compare and dispatch/finish; exactly one NEXT line
  "$self" next --dir "$td" | grep -q '^NEXT: compare RESUME.md against goal/done_when' || fail "next(6): want compare/dispatch"
  [ "$("$self" next --dir "$td" | wc -l | tr -d ' ')" = "1" ] || fail "next printed more than one line"

  # next budget rung: fresh bridge file at 80% outranks everything below drift
  printf '{"used_pct": 80, "budget": 384000}\n' > "$td/bridge/claude-ctx-selftest.json"
  "$self" next --dir "$td" | grep -q '^NEXT: context at 80% — offload: m2herd refile --area ' \
    || fail "next(budget): want context-offload line at 80%"
  rm -f "$td/bridge/claude-ctx-selftest.json"
  "$self" next --dir "$td" | grep -q '^NEXT: compare RESUME.md' || fail "next(budget): rung did not clear with the bridge file"

  # reap: a done worker whose pane vanished → exit 0, bookkeeping cleared;
  # --dry-run touches nothing. Needs a live fleet — skipped gracefully without one.
  if command -v herdr >/dev/null 2>&1 && herdr status >/dev/null 2>&1; then
    jq '.workers=[{slice:"reapX", state:"done", pane_id:"pane-selftest-gone", branch:"wip/m2herd-reapX", mode:"tui"}]' \
      "$ov" > "$ov.tmp" && mv "$ov.tmp" "$ov"
    "$self" reap --dir "$td" --dry-run >/dev/null || fail "reap --dry-run exited non-zero"
    jq -e '.workers[0].pane_id=="pane-selftest-gone"' "$ov" >/dev/null || fail "reap --dry-run mutated overview.json"
    step reap --dir "$td"
    jq -e '.workers[0].pane_id=="-"' "$ov" >/dev/null || fail "reap did not clear the gone pane's bookkeeping"
    jq '.workers=[]' "$ov" > "$ov.tmp" && mv "$ov.tmp" "$ov"
  else
    echo "  (reap case skipped — herdr absent or server unreachable)"
  fi

  # dashboard: read-only render — NEXT line + area rows present, and NO writes to the fabric
  local before after dash
  before="$(find "$td/.m2herd" -type f -exec cksum {} + | sort)"
  dash="$("$self" dashboard --dir "$td")" || fail "dashboard exited non-zero"
  after="$(find "$td/.m2herd" -type f -exec cksum {} + | sort)"
  [ "$before" = "$after" ] || fail "dashboard WROTE to .m2herd/ (must be a pure renderer)"
  printf '%s\n' "$dash" | grep -q '^NEXT: ' || fail "dashboard missing the NEXT line"
  printf '%s\n' "$dash" | grep -q '^  demo .*active' || fail "dashboard missing the active area row"
  printf '%s\n' "$dash" | grep -q 'extra .*archived' || fail "dashboard missing the archived area row"
  printf '%s\n' "$dash" | grep -q '^m2herd · .* · drift' || fail "dashboard missing the boxed header line"
  printf '%s\n' "$dash" | grep -q '^settings: workers=codex/headless max=5 rules=2$' || fail "dashboard missing settings summary line"
  printf '%s\n' "$dash" | grep -q '^read-only · steering: .m2herd/inbox/STEER.md$' || fail "dashboard missing the footer"

  # locking: two concurrent overview.json writers must BOTH land (flock convention)
  "$self" refile --dir "$td" --area lockA >/dev/null 2>&1 & lp1=$!
  "$self" refile --dir "$td" --area lockB >/dev/null 2>&1 & lp2=$!
  wait "$lp1" || fail "concurrent writer A (refile lockA) exited non-zero"
  wait "$lp2" || fail "concurrent writer B (refile lockB) exited non-zero"
  jq -e 'any(.areas[]?; .name=="lockA") and any(.areas[]?; .name=="lockB")' "$ov" >/dev/null \
    || fail "concurrent locked writers lost an overview.json update"
  step sync --dir "$td"   # fold the new areas in so later drift checks stay clean

  # validation: traversal --area is rejected (one-line error, exit 2, nothing written)
  rc=0; "$self" refile --dir "$td" --area '../escape' >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "refile --area ../escape exited $rc (want 2)"
  [ ! -e "$td/.m2herd/escape" ] || fail "refile --area ../escape wrote outside context/"
  rc=0; "$self" archive --dir "$td" --area '../escape' >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "archive --area ../escape exited $rc (want 2)"

  # boot: non-git dir → colorful (but non-fatal) warning; still scaffolds + boots clean
  local boot_out
  td2="$(mktemp -d)"
  boot_out="$("$self" boot --dir "$td2" --goal "boot selftest goal" 2>&1)" || fail "boot exited non-zero on a non-git dir"
  printf '%s\n' "$boot_out" | grep -qi 'not a git repository' || fail "boot(non-git): missing warning text"
  printf '%s\n' "$boot_out" | grep -q 'git init' || fail "boot(non-git): warning missing the git-init recommendation"
  [ -f "$td2/.m2herd/overview.json" ] || fail "boot(non-git): did not scaffold .m2herd/"
  rm -rf "$td2"

  # boot: git-inited dir → no warning, still boots clean
  td3="$(mktemp -d)"
  ( cd "$td3" && git init -q )
  boot_out="$("$self" boot --dir "$td3" --goal "boot selftest goal" 2>&1)" || fail "boot exited non-zero on a git dir"
  if printf '%s\n' "$boot_out" | grep -qi 'not a git repository'; then fail "boot(git): unexpected warning on a real git repo"; fi
  [ -f "$td3/.m2herd/overview.json" ] || fail "boot(git): did not scaffold .m2herd/"
  rm -rf "$td3"

  # doctor: healthy fixture exits 0 (warns allowed, FAILs not); herdr checks
  # skip gracefully when herdr is absent from this machine's PATH
  local doc_out drc
  drc=0; doc_out="$("$self" doctor --dir "$td" 2>&1)" || drc=$?
  [ "$drc" -eq 0 ] || { printf '%s\n' "$doc_out" >&2; fail "doctor exited $drc on a healthy fixture (want 0)"; }
  printf '%s\n' "$doc_out" | grep -q 'jq present' || fail "doctor: missing the jq check line"
  printf '%s\n' "$doc_out" | grep -q '^doctor: healthy' || fail "doctor: missing the healthy summary line"
  if printf '%s\n' "$doc_out" | grep -q 'FAIL'; then fail "doctor reported FAIL on a healthy fixture"; fi

  # evolve: graceful no-op before any run trace exists
  "$self" evolve analyze --dir "$td" | grep -qi 'no run traces' || fail "evolve analyze: missing graceful no-runs message"

  # evolve: fabricate .m2herd/runs/CURRENT + one run with one failed slice + failures.json
  local run_id run_dir sig_file prop_count prop_count2 pid_memory pid_other lesson_count
  run_id="r-$(date -u +%Y%m%dT%H%M%SZ)"
  run_dir="$td/.m2herd/runs/$run_id"
  mkdir -p "$run_dir/slices/demo-slice"
  printf '%s' "$run_id" > "$td/.m2herd/runs/CURRENT"
  jq -n --arg id "$run_id" --arg ts "$(ts)" --arg goal "selftest goal" \
    '{run_id:$id, created_at:$ts, goal:$goal, base:"main", slices:["demo-slice"]}' \
    > "$run_dir/run.json"
  printf 'worker report\n' > "$run_dir/slices/demo-slice/report.md"
  jq -n '{slice:"demo-slice", state:"failed", agent:"claude", runner:"pane", model:"",
          branch:"wip/m2herd-demo-slice", worktree:"", dispatched_at:"", collected_at:"", tokens:0, cost_usd:0}' \
    > "$run_dir/slices/demo-slice/status.json"
  jq -n '[{kind:"test_failure", severity:"high", where:"slice:demo-slice",
           evidence:"pnpm test failed", suspected_cause:"broke contract"}]' \
    > "$run_dir/slices/demo-slice/failures.json"

  step evolve analyze --dir "$td"
  sig_file="$td/.m2herd/evolver/signatures/$run_id.json"
  [ -f "$sig_file" ] || fail "evolve analyze did not write signatures/$run_id.json"
  jq -e 'length >= 2' "$sig_file" >/dev/null || fail "evolve analyze: expected >=2 signatures"
  prop_count="$(ls "$td/.m2herd/evolver/proposals"/*.md 2>/dev/null | wc -l | tr -d ' ')"
  [ "$prop_count" -ge 2 ] || fail "evolve analyze: expected >=2 proposals, got $prop_count"

  # idempotent re-run: no duplicate proposal files
  step evolve analyze --dir "$td"
  prop_count2="$(ls "$td/.m2herd/evolver/proposals"/*.md 2>/dev/null | wc -l | tr -d ' ')"
  [ "$prop_count2" = "$prop_count" ] || fail "evolve analyze re-run duplicated proposals ($prop_count -> $prop_count2)"

  "$self" evolve proposals --dir "$td" | grep -q "$run_id" || fail "evolve proposals: missing run-derived ids"

  pid_memory="$(basename "$(ls "$td/.m2herd/evolver/proposals"/*.md | head -1)" .md)"
  pid_other="$(basename "$(ls "$td/.m2herd/evolver/proposals"/*.md | sed -n '2p')" .md)"
  "$self" evolve show "$pid_memory" --dir "$td" | grep -q '^kind: memory' || fail "evolve show: missing expected frontmatter"

  # validation: traversal proposal ids are rejected before any path is resolved
  rc=0; "$self" evolve show '../../evolver/LESSONS' --dir "$td" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "evolve show traversal id exited $rc (want 2)"
  rc=0; "$self" evolve apply '../LESSONS' --dir "$td" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "evolve apply traversal id exited $rc (want 2)"
  rc=0; "$self" evolve reject '..' --dir "$td" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "evolve reject traversal id exited $rc (want 2)"

  step evolve apply "$pid_memory" --dir "$td"
  grep -qF "($pid_memory)" "$td/.m2herd/evolver/LESSONS.md" || fail "evolve apply: lesson not recorded in LESSONS.md"
  grep -q '^status: applied' "$td/.m2herd/evolver/proposals/$pid_memory.md" || fail "evolve apply: status not flipped to applied"

  # re-apply: idempotent, no duplicate lesson line
  step evolve apply "$pid_memory" --dir "$td"
  lesson_count="$(grep -cF "($pid_memory)" "$td/.m2herd/evolver/LESSONS.md")"
  [ "$lesson_count" = "1" ] || fail "evolve apply re-run duplicated the lesson line (count=$lesson_count)"

  step evolve reject "$pid_other" --dir "$td"
  grep -q '^status: rejected' "$td/.m2herd/evolver/proposals/$pid_other.md" || fail "evolve reject: status not flipped to rejected"

  local resume_out; resume_out="$("$self" resume --dir "$td")"
  printf '%s\n' "$resume_out" | grep -q 'Recent factory lessons:' || fail "resume: missing 'Recent factory lessons:' section"

  # resume cap: >8 active areas → 8 rows + one rollup line; report stays ~40 lines;
  # lessons section survives the cap
  local i rlines
  for i in 1 2 3 4 5 6 7 8 9 10; do
    mkdir -p "$td/.m2herd/context/bulk$i/deep"
    printf -- '---\narea: bulk%s\nrelated: []\ndeep: ./deep/\nupdated: %s\n---\nbulk area %s body\n' "$i" "$(ts)" "$i" \
      > "$td/.m2herd/context/bulk$i/context.md"
  done
  step sync --dir "$td"
  resume_out="$("$self" resume --dir "$td")"
  printf '%s\n' "$resume_out" | grep -q 'more areas — m2herd status for all' || fail "resume: missing the area rollup line"
  [ "$(printf '%s\n' "$resume_out" | grep -c ' → .m2herd/context/')" -eq 8 ] || fail "resume: expected exactly 8 area rows under the cap"
  printf '%s\n' "$resume_out" | grep -q 'Recent factory lessons:' || fail "resume: lessons section lost under the cap"
  rlines="$(printf '%s\n' "$resume_out" | wc -l | tr -d ' ')"
  [ "$rlines" -le 45 ] || fail "resume report is $rlines lines (want <= ~40)"

  echo "selftest: PASS"
}

# ---------- dispatch ---------------------------------------------------------
case "$CMD" in
  boot)     boot ;;
  init)     init ;;
  status)   status_cmd ;;
  note)     note ;;
  refile)   refile ;;
  resume)   resume_cmd ;;
  sync)     sync_cmd ;;
  archive)  archive ;;
  gist)     gist_cmd ;;
  next)      next_cmd ;;
  config)   config_cmd ;;
  doctor)   doctor_cmd ;;
  reap)     reap_cmd ;;
  evolve)
    case "$EVOLVE_ACTION" in
      analyze)   evolve_analyze ;;
      proposals) evolve_proposals ;;
      show)      evolve_show ;;
      apply)     evolve_apply ;;
      reject)    evolve_reject ;;
      *) echo "usage: m2herd.sh evolve {analyze|proposals|show|apply|reject} ..." >&2; exit 2 ;;
    esac
    ;;
  dashboard)
    # Tier-3 chain: --watch prefers the Go TUI (m2herd-tui, bubbletea) when installed —
    # correct Unicode widths + adaptive colors on any terminal. M2HERD_NO_TUI=1 forces
    # the bash fallback; the one-shot render (no --watch) always stays bash (hook/CI-safe).
    if [ "$WATCH" -eq 1 ] && [ "${M2HERD_NO_TUI:-}" != "1" ] && command -v m2herd-tui >/dev/null 2>&1; then
      exec m2herd-tui --dir "$DIR"
    elif [ "$WATCH" -eq 1 ]; then dashboard_watch; else dashboard; fi ;;
  room)
    # The machineroom viewer in THIS terminal: always the best available watcher
    # (Go TUI when installed, else the flicker-free bash watch). Same read-only
    # doctrine as dashboard. `m2herd-up room` runs this inside the herdr pane.
    if [ "${M2HERD_NO_TUI:-}" != "1" ] && command -v m2herd-tui >/dev/null 2>&1; then
      exec m2herd-tui --dir "$DIR"
    else dashboard_watch; fi ;;
  self-update) self_update_cmd ;;
  selftest)  selftest ;;
  help|*)    sed -n '2,50p' "$0" ;;
esac
