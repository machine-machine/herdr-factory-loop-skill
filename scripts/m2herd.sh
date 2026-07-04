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
#                                             #   (drift → coach intent → refile notes → collect worker → open question → compare/dispatch)
#   m2herd.sh dashboard [--dir P] [--watch [--interval N]]
#                                             # tier-1 TUI: read-only render — header (drift dot, update line, ages), NEXT, areas,
#                                             #   workers, open questions, NOTES tail; tput colors on a tty, plain when piped; NEVER
#                                             #   writes to the fabric. --watch: flicker-free repaint loop (home-cursor redraw, no
#                                             #   clear) every N s (default 2), refreshing the self-update check every 10 min
#   m2herd.sh self-update [--check]           # --check: fetch the engine repo, cache behind-count in ~/.cache/m2herd/update-status
#                                             #   (dashboard renders it); no flag: ff-only pull of the engine repo (refuses dirty tree)
#   m2herd.sh selftest                        # tmpdir end-to-end: init → note → refile → sync (+--check drift) → archive → gist → next; jq asserts
#
# --dir defaults to $PWD. Everything idempotent. jq required. overview.json writes are
# whole-file rewrites through jq (never sed patching).

set -euo pipefail

# ---------- arg parsing ------------------------------------------------------
CMD="${1:-help}"; shift || true
DIR="$PWD"; GOAL=""; AREA=""; TEXT=""; CHECK=0; PUSH=0; WATCH=0; INTERVAL=2
while [ $# -gt 0 ]; do
  case "$1" in
    --dir)   DIR="$2"; shift 2 ;;
    --goal)  GOAL="$2"; shift 2 ;;
    --area)  AREA="$2"; shift 2 ;;
    --check) CHECK=1; shift ;;
    --push)  PUSH=1; shift ;;
    --watch) WATCH=1; shift ;;
    --interval) INTERVAL="$2"; shift 2 ;;
    -h|--help) CMD="help"; shift ;;
    *) if [ -z "$TEXT" ]; then TEXT="$1"; shift; else echo "unknown arg: $1" >&2; exit 2; fi ;;
  esac
done

# ---------- helpers ----------------------------------------------------------
MARKER='<!-- === M2HERD:LIVE === -->'
ts()       { date -u +%Y-%m-%dT%H:%M:%SZ; }
log()      { printf '  %s\n' "$*"; }
OV()       { echo "$DIR/.m2herd/overview.json"; }
# Resolve through symlinks ($0 may be ~/.local/bin/m2herd → scripts/m2herd.sh);
# macOS has no readlink -f, so walk the link chain by hand.
self_path() {
  local p="$0" l
  while [ -L "$p" ]; do
    l="$(readlink "$p")"
    case "$l" in /*) p="$l" ;; *) p="$(dirname "$p")/$l" ;; esac
  done
  printf '%s' "$p"
}
tmpl_dir() { cd "$(dirname "$(self_path)")/../templates/m2herd" 2>/dev/null && pwd; }
need_jq()  { command -v jq >/dev/null 2>&1 || { echo "m2herd.sh: jq is required" >&2; exit 1; }; }
resolve_dir() { DIR="$(cd "$DIR" 2>/dev/null && pwd)" || { echo "no such dir: $DIR" >&2; exit 1; }; need_jq; }
need_init(){ [ -f "$(OV)" ] || { echo "no .m2herd/ at $DIR (run: m2herd.sh init --dir $DIR)" >&2; exit 1; }; }
# whole-file overview.json rewrite through jq: ov_put [jq args…] '<filter>'
ov_put()   { local tmp; tmp="$(mktemp)"; jq "$@" "$(OV)" > "$tmp" && mv "$tmp" "$(OV)"; }

live_tail() { awk -v m="$MARKER" 'p{print} index($0,m){p=1}' "$1"; }   # content below the marker
keep_head() { awk -v m="$MARKER" '{print} index($0,m){exit}' "$1"; }   # boilerplate through the marker
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

# ---------- init: scaffold .m2herd/ from templates/m2herd/ --------------------
init() {
  resolve_dir
  local tmpl m2="$DIR/.m2herd"
  tmpl="$(tmpl_dir)" || { echo "templates/m2herd/ not found next to $0" >&2; exit 1; }
  mkdir -p "$m2/context" "$m2/dispatch" "$m2/inbox"
  [ -f "$m2/RESUME.md" ] || cp "$tmpl/RESUME.md" "$m2/RESUME.md"
  [ -f "$m2/NOTES.md" ]  || cp "$tmpl/NOTES.md"  "$m2/NOTES.md"
  [ -f "$m2/inbox/STEER.md" ] || cp "$tmpl/inbox/STEER.md" "$m2/inbox/STEER.md"
  if [ ! -f "$m2/overview.json" ]; then
    jq --arg g "$GOAL" --arg ts "$(ts)" '.goal=$g | .updated_at=$ts' "$tmpl/overview.json" > "$m2/overview.json"
  else
    # backfill optional v1.2 fields on older fabrics; empty done_when = "intent not yet coached"
    ov_put --arg g "$GOAL" --arg ts "$(ts)" '
      (if $g != "" then .goal=$g | .updated_at=$ts else . end)
      | .done_when = (.done_when // "") | .open_questions = (.open_questions // [])'
  fi
  grep -qxF '.m2herd/' "$DIR/.gitignore" 2>/dev/null || printf '.m2herd/\n' >> "$DIR/.gitignore"
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
  local m2="$DIR/.m2herd" adir="$DIR/.m2herd/context/$AREA" cf now body related live first tmp
  cf="$adir/context.md"; now="$(ts)"
  mkdir -p "$adir/deep"
  body="$(body_of "$cf")"
  related="$(hdr_get "$cf" related | tr -d '[]')"
  [ -n "$related" ] || related="$(jq -r --arg n "$AREA" '[.areas[]?|select(.name==$n)|(.related//[])|join(", ")][0] // ""' "$(OV)")"
  live="$(live_tail "$m2/NOTES.md")"
  tmp="$(mktemp)"
  {
    write_header "$AREA" "$related" ""      # refiling (re)activates the area
    [ -z "$body" ] || printf '%s\n' "$body"
    if has_ink "$live"; then printf '\n## refiled %s\n\n%s\n' "$now" "$live"; fi
  } > "$tmp" && mv "$tmp" "$cf"
  if has_ink "$live"; then
    tmp="$(mktemp)"; keep_head "$m2/NOTES.md" > "$tmp" && mv "$tmp" "$m2/NOTES.md"
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
refresh_resume() {
  local m2="$DIR/.m2herd" resume tpl live tmp
  resume="$m2/RESUME.md"; tpl="$(tmpl_dir)/RESUME.md"
  [ -f "$tpl" ] || { echo "template RESUME.md not found next to $0" >&2; exit 1; }
  live=""
  [ -f "$resume" ] && live="$(live_tail "$resume")"
  has_ink "$live" || live="$(live_tail "$tpl")"
  tmp="$(mktemp)"
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
  } > "$tmp" && mv "$tmp" "$resume"
}

# DRIFT lines for overview.json vs the context/ tree; returns 1 when drift exists
drift_report() {
  local m2="$DIR/.m2herd" tree ov missing orphan drift=0 n
  tree="$(for d in "$m2"/context/*/; do [ -d "$d" ] || continue; basename "$d"; done | sort; true)"
  ov="$(jq -r '.areas[]?.name' "$(OV)" | sort)"
  missing="$(comm -23 <(printf '%s\n' "$tree" | sed '/^$/d') <(printf '%s\n' "$ov" | sed '/^$/d'))"
  orphan="$(comm -13 <(printf '%s\n' "$tree" | sed '/^$/d') <(printf '%s\n' "$ov" | sed '/^$/d'))"
  if [ -n "$missing" ]; then drift=1; for n in $missing; do echo "DRIFT missing: context/$n/ exists but overview.json has no area '$n'"; done; fi
  if [ -n "$orphan" ];  then drift=1; for n in $orphan;  do echo "DRIFT orphan:  overview.json lists area '$n' but context/$n/ does not exist"; done; fi
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
  local m2="$DIR/.m2herd" cf="$DIR/.m2herd/context/$AREA/context.md" now related summary tmp
  [ -f "$cf" ] || { echo "no such area to archive: context/$AREA/context.md" >&2; exit 1; }
  now="$(ts)"
  related="$(hdr_get "$cf" related | tr -d '[]')"
  summary="$(body_of "$cf" | awk 'NF' | head -10)"
  tmp="$(mktemp)"
  {
    write_header "$AREA" "$related" "archived"
    [ -z "$summary" ] || printf '%s\n' "$summary"
  } > "$tmp" && mv "$tmp" "$cf"
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

# ---------- resume -----------------------------------------------------------
resume_cmd() {
  resolve_dir; need_init
  cat "$DIR/.m2herd/RESUME.md"
  echo
  echo "areas:"
  jq -r '
    ((.areas//[])[] | select((.status//"active")!="archived")
      | "  - " + .name + ": " + (if (.summary//"")=="" then "(no summary)" else .summary end) + "  → " + .path),
    (if ((.areas//[])|map(select((.status//"active")=="archived"))|length)>0
     then "  archived: " + ((.areas//[])|map(select((.status//"active")=="archived")|.name)|join(", "))
     else empty end)
  ' "$(OV)"
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
# first spawned|working worker whose pane is gone or idle (needs herdr to verify; else none)
stale_worker() {
  command -v herdr >/dev/null 2>&1 || return 0
  local agents; agents="$(herdr agent list 2>/dev/null)" || return 0
  [ -n "$agents" ] || return 0
  jq -r '(.workers // [])[] | select(.state=="spawned" or .state=="working") | .slice + "\t" + (.pane_id // "")' "$(OV)" \
  | while IFS=$'\t' read -r slice pane; do
      [ -n "$slice" ] || continue
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

# mechanical priority walk — NO LLM, exactly one "NEXT: " line
next_cmd() {
  resolve_dir; need_init
  local m2="$DIR/.m2herd" w q
  if ! drift_report >/dev/null; then
    echo "NEXT: context drift — run: m2herd sync"; return 0
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

# budget row from the newest /tmp/claude-ctx-*.json bridge file; silent no-op when none
budget_row() {
  local f="" c pct budget mt filled bar
  for c in $(ls -t /tmp/claude-ctx-*.json 2>/dev/null); do
    if jq -e '.used_pct|numbers' "$c" >/dev/null 2>&1; then f="$c"; break; fi
  done
  [ -n "$f" ] || return 0
  pct="$(jq -r '.used_pct' "$f")"; pct="${pct%.*}"; [ -n "$pct" ] || pct=0
  budget="$(jq -r '.budget // 384000' "$f")"
  filled=$((pct * 20 / 100)); [ "$filled" -le 20 ] || filled=20; [ "$filled" -ge 0 ] || filled=0
  bar="$(printf '%*s' "$filled" '' | tr ' ' '█')$(printf '%*s' "$((20 - filled))" '' | tr ' ' '░')"
  mt="$(file_mtime "$f")"
  case "$mt" in ''|*[!0-9]*) mt=0 ;; esac   # never let a stat surprise reach the integer tests
  printf 'budget:    %s %s%% of %s · updated %s ago\n' "$bar" "$pct" "$budget" "$(age_secs "$mt")"
}

# plain (uncolored) blocks so the side-by-side column merge pads correctly
render_areas() {
  local names n astatus rel aage
  echo "AREAS"
  names="$(jq -r '(.areas//[])[].name' "$(OV)")"
  [ -n "$names" ] || { echo "  (no areas yet)"; return 0; }
  for n in $names; do
    astatus="$(jq -r --arg n "$n" '[.areas[]|select(.name==$n)|(.status//"active")][0]' "$(OV)")"
    rel="$(jq -r --arg n "$n" '[.areas[]|select(.name==$n)|(.related//[])|join(", ")][0] // ""' "$(OV)")"
    aage="$(age_of "$(hdr_get "$DIR/.m2herd/context/$n/context.md" updated)")"
    if [ "$astatus" = "archived" ]; then
      printf '  %-14s archived  %s\n' "$n" "$aage"
    else
      printf '  %-14s active    %-5s %s\n' "$n" "$aage" "${rel:+(related: $rel)}"
    fi
  done
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
  local Y="$1" R="$2" word n when age now
  [ -f "$UPDATE_CACHE" ] || return 0
  read -r word n when < "$UPDATE_CACHE" 2>/dev/null || return 0
  [ "$word" = "behind" ] || return 0
  now="$(date -u +%s)"
  age="$(( now - $(epoch_of "$when") ))"
  [ "$age" -le "$now" ] || age=0   # epoch_of returns 0 on parse failure → treat as fresh-unknown
  [ "$age" -lt 86400 ] || return 0
  printf 'update:    %s%s commit(s) behind — run: m2herd self-update%s\n' "$Y" "$n" "$R"
}

# ---------- dashboard --watch: flicker-free repaint loop -----------------------
# Home-cursor redraw (no `clear` per frame → no blink); alt-screen + hidden
# cursor, restored on exit. Refreshes the self-update check every 10 min.
dashboard_watch() {
  local iv="$INTERVAL" chk=600 last=0 now frame
  if command -v tput >/dev/null 2>&1 && [ -t 1 ]; then
    tput smcup 2>/dev/null || true; tput civis 2>/dev/null || true
    trap 'tput cnorm 2>/dev/null || true; tput rmcup 2>/dev/null || true' EXIT INT TERM
  fi
  printf '\033[2J'
  while :; do
    now="$(date +%s)"
    if [ $((now - last)) -ge "$chk" ]; then
      ( CHECK=1 self_update_cmd >/dev/null 2>&1 ) || true
      last="$now"
    fi
    frame="$(M2HERD_FORCE_TTY=1 COLUMNS="${COLUMNS:-$(tput cols 2>/dev/null || echo 100)}" dashboard 2>&1 || true)"
    printf '\033[H%s\n\033[0J' "$frame"
    sleep "$iv"
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

# ---------- selftest: tmpdir end-to-end ---------------------------------------
selftest() {
  need_jq
  # tmpdir fixtures have no machineroom; suppress the room nudge so the other
  # next-cases stay assertable (the room case is verified live, not here).
  export M2HERD_SKIP_ROOM_CHECK=1
  local self td ov rc
  self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  td="$(mktemp -d)"; trap "rm -rf '$td'" EXIT
  echo "selftest: workdir $td"
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
  # next case 6: nothing pending → compare and dispatch/finish; exactly one NEXT line
  "$self" next --dir "$td" | grep -q '^NEXT: compare RESUME.md against goal/done_when' || fail "next(6): want compare/dispatch"
  [ "$("$self" next --dir "$td" | wc -l | tr -d ' ')" = "1" ] || fail "next printed more than one line"

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
  printf '%s\n' "$dash" | grep -q '^read-only · steering: .m2herd/inbox/STEER.md$' || fail "dashboard missing the footer"

  # boot: non-git dir → colorful (but non-fatal) warning; still scaffolds + boots clean
  local td2 td3 boot_out
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
  dashboard)
    # Tier-3 chain: --watch prefers the Go TUI (m2herd-tui, bubbletea) when installed —
    # correct Unicode widths + adaptive colors on any terminal. M2HERD_NO_TUI=1 forces
    # the bash fallback; the one-shot render (no --watch) always stays bash (hook/CI-safe).
    if [ "$WATCH" -eq 1 ] && [ "${M2HERD_NO_TUI:-}" != "1" ] && command -v m2herd-tui >/dev/null 2>&1; then
      exec m2herd-tui --dir "$DIR"
    elif [ "$WATCH" -eq 1 ]; then dashboard_watch; else dashboard; fi ;;
  self-update) self_update_cmd ;;
  selftest)  selftest ;;
  help|*)    sed -n '2,30p' "$0" ;;
esac
