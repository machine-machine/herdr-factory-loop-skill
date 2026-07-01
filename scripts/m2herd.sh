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
#   m2herd.sh dashboard [--dir P]             # tier-1 TUI: read-only render — header (drift dot, ages), NEXT, areas, workers,
#                                             #   open questions, NOTES tail; tput colors on a tty, plain when piped; NEVER writes
#   m2herd.sh selftest                        # tmpdir end-to-end: init → note → refile → sync (+--check drift) → archive → gist → next; jq asserts
#
# --dir defaults to $PWD. Everything idempotent. jq required. overview.json writes are
# whole-file rewrites through jq (never sed patching).

set -euo pipefail

# ---------- arg parsing ------------------------------------------------------
CMD="${1:-help}"; shift || true
DIR="$PWD"; GOAL=""; AREA=""; TEXT=""; CHECK=0; PUSH=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dir)   DIR="$2"; shift 2 ;;
    --goal)  GOAL="$2"; shift 2 ;;
    --area)  AREA="$2"; shift 2 ;;
    --check) CHECK=1; shift ;;
    --push)  PUSH=1; shift ;;
    -h|--help) CMD="help"; shift ;;
    *) if [ -z "$TEXT" ]; then TEXT="$1"; shift; else echo "unknown arg: $1" >&2; exit 2; fi ;;
  esac
done

# ---------- helpers ----------------------------------------------------------
MARKER='<!-- === M2HERD:LIVE === -->'
ts()       { date -u +%Y-%m-%dT%H:%M:%SZ; }
log()      { printf '  %s\n' "$*"; }
OV()       { echo "$DIR/.m2herd/overview.json"; }
tmpl_dir() { cd "$(dirname "$0")/../templates/m2herd" 2>/dev/null && pwd; }
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

# ---------- dashboard: tier-1 TUI — a pure read-only renderer -----------------
# One writer (the orchestrator), many watchers: this code path NEVER writes state.
# herdr READS (agent list) are allowed; herdr sends/closes are FORBIDDEN here.
epoch_of() { date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null || date -u -d "$1" +%s 2>/dev/null || echo 0; }
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
  mt="$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || echo 0)"
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
  local agents="" slice desired pane branch obs mark
  command -v herdr >/dev/null 2>&1 && agents="$(herdr agent list 2>/dev/null || true)"
  echo "WORKERS"
  printf '  %-10s %-9s %-10s %s\n' "slice" "desired" "observed" "branch"
  jq -r '(.workers//[])[] | [.slice, (.state//"?"), (.pane_id//""), (.branch//"-")] | join("\u001f")' "$(OV)" \
  | while IFS=$'\x1f' read -r slice desired pane branch; do
      obs="-"; mark=""
      if [ -n "$agents" ]; then
        obs="$(jq -r --arg p "$pane" '[.result.agents[]? | select(.pane_id==$p) | .agent_status][0] // "gone"' <<<"$agents")"
        case "$desired:$obs" in
          spawned:idle|spawned:gone|working:idle|working:gone|done:working|failed:working) mark=" !" ;;
        esac
      fi
      printf '  %-10s %-9s %-10s %s\n' "$slice" "$desired" "$obs$mark" "$branch"
    done
}

dashboard() {
  resolve_dir; need_init
  local m2="$DIR/.m2herd" B="" D="" G="" Y="" R="" cols=80
  if [ -t 1 ] && command -v tput >/dev/null 2>&1; then   # colors only on a tty; plain when piped
    B="$(tput bold 2>/dev/null || true)"; D="$(tput dim 2>/dev/null || true)"
    G="$(tput setaf 2 2>/dev/null || true)"; Y="$(tput setaf 3 2>/dev/null || true)"
    R="$(tput sgr0 2>/dev/null || true)"
    cols="$(tput cols 2>/dev/null || echo 80)"
  fi
  # header: m2herd · <repo> ── ● <status> · drift ✓|◐  + goal / done_when / budget rows
  local goal st dw sdot dmark
  goal="$(jq -r 'if (.goal//"")=="" then "(none)" else .goal end' "$(OV)")"
  st="$(jq -r '.status//"active"' "$(OV)")"
  dw="$(jq -r 'if (.done_when//"")=="" then "(not coached)" else .done_when end' "$(OV)")"
  if drift_report >/dev/null; then dmark="${G}✓${R}"; else dmark="${Y}◐${R}"; fi
  case "$st" in active) sdot="${G}●${R}" ;; paused) sdot="${Y}●${R}" ;; *) sdot="●" ;; esac
  printf '%sm2herd%s · %s ── %s %s · drift %s\n' "$B" "$R" "$(basename "$DIR")" "$sdot" "$st" "$dmark"
  printf 'goal:      %s\n' "$goal"
  printf 'done_when: %s\n' "$dw"
  budget_row
  echo
  # the self-prompt (same code path as `next`)
  next_cmd
  echo
  # AREAS + WORKERS: side-by-side on a wide tty (>=100 cols), stacked otherwise
  local ablock wblock=""
  ablock="$(render_areas)"
  if [ "$(jq -r '(.workers//[])|length' "$(OV)")" -gt 0 ]; then wblock="$(render_workers)"; fi
  if [ -n "$wblock" ] && [ "$cols" -ge 100 ]; then
    paste -d $'\t' <(printf '%s\n' "$ablock") <(printf '%s\n' "$wblock") \
      | awk -F'\t' '{printf "%-52s %s\n", $1, $2}'
  else
    printf '%s\n' "$ablock"
    if [ -n "$wblock" ]; then echo; printf '%s\n' "$wblock"; fi
  fi
  # OPEN QUESTIONS (only when non-empty)
  if [ "$(jq -r '(.open_questions//[])|length' "$(OV)")" -gt 0 ]; then
    echo
    printf '%sOPEN QUESTIONS%s\n' "$B" "$R"
    jq -r '(.open_questions//[])[] | "  - " + .' "$(OV)"
  fi
  # NOTES tail: last 5 content lines below the marker
  echo
  printf '%sNOTES%s (last 5)\n' "$B" "$R"
  local tail5; tail5="$(live_tail "$m2/NOTES.md" | awk 'NF' | tail -5)"
  if [ -n "$tail5" ]; then printf '%s\n' "$tail5" | sed 's/^/  /'; else echo "  (empty)"; fi
  echo
  printf '%sread-only · steering: .m2herd/inbox/STEER.md%s\n' "$D" "$R"
}

# ---------- selftest: tmpdir end-to-end ---------------------------------------
selftest() {
  need_jq
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

  echo "selftest: PASS"
}

# ---------- dispatch ---------------------------------------------------------
case "$CMD" in
  init)     init ;;
  status)   status_cmd ;;
  note)     note ;;
  refile)   refile ;;
  resume)   resume_cmd ;;
  sync)     sync_cmd ;;
  archive)  archive ;;
  gist)     gist_cmd ;;
  next)      next_cmd ;;
  dashboard) dashboard ;;
  selftest)  selftest ;;
  help|*)    sed -n '2,28p' "$0" ;;
esac
