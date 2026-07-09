#!/usr/bin/env bash
# context-budget.sh — the mechanical context-budget engine for the ICM herd.
#
# The orchestrator's live context is a scarce resource. This engine keeps it bounded:
# it DETECTS the model/budget, reports live STATUS against a bridge file, decomposes an
# intent into per-slice context manifests (PLAN), and (re)writes a single slice's manifest
# (POINTER). Manifests hold FILE LINKS ONLY — never inlined bodies — so the folder holds the
# context and the orchestrator holds pointers (ICM: "state management is the files").
#
# It does the MECHANICAL work only (byte→token estimate `ceil(bytes/4)`, threshold math,
# file writes). Judgment stays with the orchestrator.
#
# Config resolution chain for MODEL/BUDGET (first non-empty wins):
#   1. explicit --model/--budget flags
#   2. herd.conf MODEL/BUDGET                (existing behavior — legacy workspaces unchanged)
#   3. the workspace repo's .m2herd/settings.json, read-only via jq, when present
#      (BUDGET ← .orchestrator.budget; not in the m2herd default schema, so this only
#       fires when a user has set it — absent key falls through)
#   4. ~/.hermes/config.yaml model.context_length (+ cache)
#   5. built-in defaults (GLM-5.2 / 384000)
#
# Usage:
#   context-budget.sh detect    [--ws DIR] [--model NAME] [--budget N]
#   context-budget.sh status    [--ws DIR] [--session ID]
#   context-budget.sh plan      --ws DIR --intent FILE [--stage S] [--fraction 0.25]
#   context-budget.sh pointer   --ws DIR --stage S --slice X [--fraction 0.25]
#   context-budget.sh summarize --ws DIR --stage S --slice X [--llm "CMD"]
#   context-budget.sh compact   --ws DIR
#   context-budget.sh selftest
#
# Workspace (status/plan/pointer) is found via --ws or $HERD_WS and must contain AGENT.md.
# `detect` needs no workspace (falls back to defaults). Idempotent. Safe to re-run.

set -euo pipefail

# ---------- arg parsing ------------------------------------------------------
CMD="${1:-help}"; shift || true
WS=""; INTENT=""; STAGE=""; SLICE=""; SESSION=""; FRACTION="0.25"
MODEL_OVERRIDE=""; BUDGET_OVERRIDE=""; LLM=""
while [ $# -gt 0 ]; do
  case "$1" in
    --ws) WS="$2"; shift 2 ;;
    --intent) INTENT="$2"; shift 2 ;;
    --stage) STAGE="$2"; shift 2 ;;
    --slice) SLICE="$2"; shift 2 ;;
    --session) SESSION="$2"; shift 2 ;;
    --fraction) FRACTION="$2"; shift 2 ;;
    --llm) LLM="$2"; shift 2 ;;
    --model) MODEL_OVERRIDE="$2"; shift 2 ;;
    --budget) BUDGET_OVERRIDE="$2"; shift 2 ;;
    -h|--help) CMD="help"; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

DEFAULT_MODEL="GLM-5.2"
DEFAULT_BUDGET="384000"
HERMES_CONFIG="${HERMES_CONFIG:-$HOME/.hermes/config.yaml}"
HERMES_CACHE="${HERMES_CACHE:-$HOME/.hermes/context_length_cache.yaml}"

log() { printf '  %s\n' "$*"; }

# ---------- workspace resolution ---------------------------------------------
# strict: status/plan/pointer must target a real herd-control workspace (AGENT.md marker).
resolve_ws() {
  [ -n "$WS" ] || WS="${HERD_WS:-$PWD}"
  WS="$(cd "$WS" 2>/dev/null && pwd)" || { echo "no such workspace dir" >&2; exit 1; }
  [ -f "$WS/AGENT.md" ] || { echo "not a herd-control workspace (no AGENT.md): $WS" >&2; exit 1; }
}
# soft: detect works with or without a workspace; a bad --ws just falls through to defaults.
soft_ws() {
  [ -n "$WS" ] || WS="${HERD_WS:-}"
  [ -n "$WS" ] || return 0
  WS="$(cd "$WS" 2>/dev/null && pwd)" || WS=""
}

conf_get() { grep -E "^$1=" "$WS/herd.conf" 2>/dev/null | head -1 | cut -d= -f2- || true; }
# read-only fallback into the workspace repo's m2herd settings (see header chain).
# Absent repo/file/key/jq → empty, and the chain falls through to the next rung.
m2_settings_get() { # m2_settings_get <jq-path> -> value or empty
  local r f; r="$(conf_get REPO)"; [ -n "$r" ] || r="$WS"
  f="$r/.m2herd/settings.json"
  [ -n "$r" ] && [ -f "$f" ] && command -v jq >/dev/null 2>&1 || return 0
  jq -er "$1 // empty" "$f" 2>/dev/null || true
}

# repo root the slice file-links are relative to (herd.conf REPO, else the workspace itself).
repo_root() {
  local r; r="$(conf_get REPO)"
  [ -n "$r" ] && [ -d "$r" ] && { echo "$r"; return; }
  echo "$WS"
}

# ---------- estimate helpers -------------------------------------------------
# est_tokens = ceil(bytes / 4) — same heuristic as `hermes prompt-size`.
est_tokens() { local b="${1:-0}"; echo "$(( (b + 3) / 4 ))"; }
file_bytes() { [ -f "$1" ] && wc -c < "$1" 2>/dev/null | tr -d ' ' || echo 0; }

# ---------- config.yaml parsing (model.context_length) -----------------------
# pull one indented key out of a top-level `model:` block without a YAML parser.
yaml_model_key() { # yaml_model_key <file> <key>
  [ -f "$1" ] || return 0
  awk -v k="$2" '
    /^[^[:space:]#]/ { inmodel = ($1 == "model:") }
    inmodel && $1 == k":" { sub(/^[[:space:]]*[^:]+:[[:space:]]*/, ""); gsub(/[[:space:]]+$/, ""); print; exit }
  ' "$1"
}

# ---------- detect: resolve MODEL / BUDGET / SOURCE --------------------------
# order: herd.conf → repo .m2herd/settings.json (orchestrator.budget) →
#        ~/.hermes/config.yaml model.context_length (+cache) → GLM-5.2/384000.
resolve_budget() { # sets globals MODEL BUDGET SOURCE
  local cm cb
  # explicit CLI overrides win outright.
  if [ -n "$MODEL_OVERRIDE" ] || [ -n "$BUDGET_OVERRIDE" ]; then
    MODEL="${MODEL_OVERRIDE:-$DEFAULT_MODEL}"; BUDGET="${BUDGET_OVERRIDE:-$DEFAULT_BUDGET}"; SOURCE="override"; return
  fi
  # 1. herd.conf
  cm="$(conf_get MODEL)"; cb="$(conf_get BUDGET)"
  if [ -n "$cb" ]; then
    MODEL="${cm:-$DEFAULT_MODEL}"; BUDGET="$cb"; SOURCE="herd.conf"; return
  fi
  # 2. repo .m2herd/settings.json — herd.conf MODEL (if any) still names the model.
  cb="$(m2_settings_get '.orchestrator.budget')"
  if [ -n "$cb" ]; then
    MODEL="${cm:-$DEFAULT_MODEL}"; BUDGET="$cb"; SOURCE="m2herd-settings"; return
  fi
  # 3. ~/.hermes/config.yaml (context_length), then the cache file
  cb="$(yaml_model_key "$HERMES_CONFIG" context_length)"
  cm="$(yaml_model_key "$HERMES_CONFIG" default)"
  if [ -z "$cb" ] && [ -f "$HERMES_CACHE" ]; then
    cb="$(grep -oE 'context_length:[[:space:]]*[0-9]+' "$HERMES_CACHE" 2>/dev/null | grep -oE '[0-9]+' | head -1 || true)"
  fi
  if [ -n "$cb" ]; then
    MODEL="${cm:-$DEFAULT_MODEL}"; BUDGET="$cb"; SOURCE="hermes-config"; return
  fi
  # 4. default
  MODEL="$DEFAULT_MODEL"; BUDGET="$DEFAULT_BUDGET"; SOURCE="default"
}

detect() {
  soft_ws
  resolve_budget
  printf 'MODEL=%s\n'  "$MODEL"
  printf 'BUDGET=%s\n' "$BUDGET"
  printf 'SOURCE=%s\n' "$SOURCE"
}

# ---------- status: live usage vs budget (reads the bridge file) -------------
# session comes from --session, env, or the most-recently-touched bridge file.
find_bridge() {
  local s="${SESSION:-${HERMES_SESSION_ID:-${CLAUDE_SESSION_ID:-${HERD_SESSION:-}}}}"
  if [ -n "$s" ]; then
    echo "/tmp/claude-ctx-$s.json"; return
  fi
  ls -t /tmp/claude-ctx-*.json 2>/dev/null | head -1 || true
}

status() {
  resolve_ws
  resolve_budget
  local bridge used rem
  bridge="$(find_bridge)"
  if [ -z "$bridge" ] || [ ! -f "$bridge" ]; then
    printf 'USED_PCT=unknown\n'
    printf 'REMAINING_PCT=unknown\n'
    printf 'BUDGET=%s\n' "$BUDGET"
    printf 'EST_TOKENS=unknown\n'
    return 0
  fi
  used="$(jq -r '.used_pct // empty' "$bridge" 2>/dev/null || true)"
  rem="$(jq -r '.remaining_percentage // empty' "$bridge" 2>/dev/null || true)"
  [ -n "$used" ] || used="unknown"
  [ -n "$rem" ] || rem="unknown"
  local est="unknown"
  if [ "$used" != "unknown" ]; then
    est="$(awk -v u="$used" -v b="$BUDGET" 'BEGIN{printf "%d", (u/100.0)*b}')"
  fi
  printf 'USED_PCT=%s\n'      "$used"
  printf 'REMAINING_PCT=%s\n' "$rem"
  printf 'BUDGET=%s\n'        "$BUDGET"
  printf 'EST_TOKENS=%s\n'    "$est"
}

# ---------- slice resolution -------------------------------------------------
# emit `slice<TAB>file file …` rows from an intent file (declared `slice<TAB>files` lines)
# or, failing that, from the `[P]` rows of stages/03_tasks/output/tasks.md.
slices_from_intent() { # slices_from_intent <intent-file>
  [ -f "$1" ] || return 0
  # keep only lines that carry a real TAB (slice<TAB>files…); skip comments/blanks.
  grep -vE '^\s*#|^\s*$' "$1" 2>/dev/null | awk -F'\t' 'NF>=2 && $1!="" {print}' || true
}
slices_from_tasks() { # slices_from_tasks <tasks-file>
  [ -f "$1" ] || return 0
  # rows like: - **[P] budget-engine** (worker: claude) — `scripts/context-budget.sh`
  grep -E '\[P\]' "$1" 2>/dev/null | while IFS= read -r line; do
    local slice files=""
    slice="$(printf '%s' "$line" | sed -nE 's/.*\[P\][[:space:]]+([A-Za-z0-9_-]+).*/\1/p')"
    [ -n "$slice" ] || continue
    # every `backtick path backtick` token on the row is a file link.
    files="$(printf '%s' "$line" | grep -oE '`[^`]+`' | tr -d '`' | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
    printf '%s\t%s\n' "$slice" "$files"
  done || true
}

# one-line purpose for a file link (heading / first comment / fallback).
file_purpose() { # file_purpose <abs-path>
  local f="$1" p=""
  if [ -f "$f" ]; then
    case "$f" in
      *.md) p="$(grep -m1 -E '^#+[[:space:]]' "$f" 2>/dev/null | sed -E 's/^#+[[:space:]]*//')" ;;
      *)    p="$(grep -m1 -E '^#[^!]' "$f" 2>/dev/null | sed -E 's/^#+[[:space:]]*//')" ;;
    esac
    [ -n "$p" ] || p="source file"
  else
    p="(to be created)"
  fi
  printf '%s' "$p" | head -c 100
}

# ---------- write one slice's context manifest (links only, sized header) ----
write_manifest() { # write_manifest <out-md> <slice> <files-space-sep>
  local out="$1" slice="$2" files="$3" root; root="$(repo_root)"
  mkdir -p "$(dirname "$out")"
  local total=0 f abs bytes
  # first pass: size the slice.
  for f in $files; do
    case "$f" in /*) abs="$f" ;; *) abs="$root/$f" ;; esac
    bytes="$(file_bytes "$abs")"; total=$(( total + bytes ))
  done
  local tokens cap fits
  tokens="$(est_tokens "$total")"
  cap="$(awk -v b="$BUDGET" -v fr="$FRACTION" 'BEGIN{printf "%d", b*fr}')"
  if [ "$tokens" -le "$cap" ]; then fits="yes"; else fits="NO"; fi
  # header + links (NEVER the file bodies).
  {
    printf -- '<!-- context manifest for slice `%s` — generated by context-budget.sh; links only -->\n' "$slice"
    printf '# context: %s\n\n' "$slice"
    printf 'slice: %s\n' "$slice"
    printf 'est_bytes: %s\n' "$total"
    printf 'est_tokens: %s\n' "$tokens"
    printf 'budget_fraction: %s\n' "$FRACTION"
    printf 'slice_budget_tokens: %s\n' "$cap"
    printf 'fits: %s\n\n' "$fits"
    if [ "$fits" = "NO" ]; then
      printf '> [!WARNING] OVERSIZED — est_tokens %s > slice budget %s. Split this slice before dispatch.\n\n' "$tokens" "$cap"
    fi
    printf '## file links\n\n'
    if [ -z "${files// }" ]; then
      printf '_(no file links declared for this slice)_\n'
    else
      for f in $files; do
        case "$f" in /*) abs="$f" ;; *) abs="$root/$f" ;; esac
        printf -- '- `%s` — %s\n' "$f" "$(file_purpose "$abs")"
      done
    fi
  } > "$out"
  echo "$out"
}

# ---------- plan: decompose an intent into per-slice manifests ---------------
# --stage S targets the manifests at stages/S/context/ (default 03_tasks, the planning
# stage — unchanged). Pass the fanout stage (e.g. --stage 04_implement) to write them
# where gen_prompt will look; `herd-loop.sh advance` also copies 03_tasks manifests
# forward, so the default stays correct either way.
plan() {
  resolve_ws
  [ -n "$INTENT" ] || { echo "plan needs --intent FILE" >&2; exit 2; }
  resolve_budget
  local rows; rows="$(slices_from_intent "$INTENT")"
  [ -n "$rows" ] || rows="$(slices_from_tasks "$WS/stages/03_tasks/output/tasks.md")"
  [ -n "$rows" ] || { echo "no slices found in intent or tasks.md" >&2; exit 1; }
  local ctxdir="$WS/stages/${STAGE:-03_tasks}/context" n=0 oversized=0
  mkdir -p "$ctxdir"
  local slice files out
  while IFS=$'\t' read -r slice files; do
    [ -n "$slice" ] || continue
    out="$ctxdir/$slice.md"
    write_manifest "$out" "$slice" "$files" >/dev/null
    n=$(( n + 1 ))
    if grep -q '^fits: NO' "$out"; then oversized=$(( oversized + 1 )); log "OVERSIZED slice: $slice (see $out)"; fi
    log "wrote $out"
  done <<< "$rows"
  echo "planned $n slice(s) → $ctxdir (oversized: $oversized)"
  [ "$oversized" -eq 0 ]
}

# ---------- pointer: (re)write one slice's manifest --------------------------
pointer() {
  resolve_ws
  [ -n "$STAGE" ] || { echo "pointer needs --stage S" >&2; exit 2; }
  [ -n "$SLICE" ] || { echo "pointer needs --slice X" >&2; exit 2; }
  resolve_budget
  # resolve this slice's files from the intent (if given) else tasks.md.
  local rows="" files=""
  if [ -n "$INTENT" ]; then rows="$(slices_from_intent "$INTENT")"; fi
  [ -n "$rows" ] || rows="$(slices_from_tasks "$WS/stages/03_tasks/output/tasks.md")"
  local s f
  while IFS=$'\t' read -r s f; do
    [ "$s" = "$SLICE" ] && { files="$f"; break; }
  done <<< "$rows"
  local out="$WS/stages/$STAGE/context/$SLICE.md"
  write_manifest "$out" "$SLICE" "$files" >/dev/null
  echo "pointer → $out"
}

# ---------- summarize: distill one worker output to ≤6 lines -----------------
# pull the worker's final report from the tail: grep the last ~40 lines for a
# "what I did / how I verified"-style block and take from the LAST such marker.
report_block() { # report_block <out-file>
  local f="$1" tail40 startln
  tail40="$(tail -40 "$f")"
  # take the FIRST marker in the tail window — the start of the final report block.
  startln="$(printf '%s\n' "$tail40" \
    | grep -niE 'what i did|how i verified|verif(ied|ication)|^#+.*(report|summary|done)|^(summary|report|done)[[:space:]:]' \
    | head -1 | cut -d: -f1 || true)"
  [ -n "$startln" ] || return 0
  printf '%s\n' "$tail40" | tail -n +"$startln" | grep -vE '^[[:space:]]*$' | head -6
}

# read stages/S/output/X.out; emit a ≤6-line summary. NEVER copy the whole file.
summarize() {
  resolve_ws
  [ -n "$STAGE" ] || { echo "summarize needs --stage S" >&2; exit 2; }
  [ -n "$SLICE" ] || { echo "summarize needs --slice X" >&2; exit 2; }
  local out="$WS/stages/$STAGE/output/$SLICE.out"
  [ -f "$out" ] || { echo "no such output file: $out" >&2; exit 1; }
  local summary=""
  # --llm "CMD": run CMD < the .out and use its stdout.
  if [ -n "$LLM" ]; then
    summary="$(eval "$LLM" < "$out" 2>/dev/null || true)"
  fi
  # heuristic: prefer the worker's final report block …
  [ -n "$summary" ] || summary="$(report_block "$out")"
  # … else head(3)+tail(3).
  [ -n "$summary" ] || summary="$( { head -3 "$out"; tail -3 "$out"; } 2>/dev/null )"
  # always cap to ≤6 lines.
  summary="$(printf '%s\n' "$summary" | head -6)"
  printf '%s\n' "$summary"
}

# ---------- compact: regenerate _fleet/context_pointer.md (rolling) ----------
# active stage = highest-numbered stage dir with a worker output, else any stage.
active_stage() {
  local d s last="" anystage=""
  for d in "$WS"/stages/*/; do
    [ -d "$d" ] || continue
    s="$(basename "$d")"; anystage="$s"
    ls "$d"output/*.out >/dev/null 2>&1 && last="$s"
  done
  printf '%s' "${last:-${anystage:-unknown}}"
}

compact() {
  resolve_ws
  local fleet="$WS/_fleet"
  mkdir -p "$fleet"
  local out="$fleet/context_pointer.md" active; active="$(active_stage)"
  {
    printf '# context_pointer.md\n\n'
    printf '<!-- rolling summary — regenerated by context-budget.sh compact; links only -->\n\n'
    printf 'active_stage: %s\n\n' "$active"
    printf '## digest\n\n'
    if [ -f "$fleet/digest.md" ]; then
      cat "$fleet/digest.md"; printf '\n'
    else
      printf '_(no digest yet — [_fleet/digest.md](digest.md) will appear once slices are collected)_\n\n'
    fi
    printf '## slice context\n\n'
    local any=0 c rel
    for c in "$WS"/stages/*/context/*.md; do
      [ -f "$c" ] || continue
      any=1; rel="${c#"$WS"/}"
      printf -- '- [%s](%s)\n' "$rel" "$rel"
    done
    [ "$any" -eq 1 ] || printf '_(no slice context manifests yet)_\n'
  } > "$out"
  echo "$out"
}

# ---------- selftest: exercise each subcommand against a temp workspace ------
selftest() {
  local tmp; tmp="$(mktemp -d)"
  trap '[ -n "${tmp:-}" ] && rm -rf "$tmp"' EXIT
  local ws="$tmp/ws" repo="$tmp/repo"
  mkdir -p "$ws/stages/03_tasks/output" "$repo/scripts" "$repo/hooks"
  printf '# AGENT.md\n' > "$ws/AGENT.md"
  cat > "$ws/herd.conf" <<EOF
REPO=$repo
BASE=main
MODEL=GLM-5.2
BUDGET=384000
EOF
  # a couple of real-ish files so the estimator has bytes to count.
  printf '#!/usr/bin/env bash\n# budget engine entrypoint\nSECRET_BODY_MARKER=nope\n' > "$repo/scripts/context-budget.sh"
  printf '// awareness hook\nconsole.log("SECRET_BODY_MARKER");\n' > "$repo/hooks/herdr-context-budget.js"
  cat > "$ws/stages/03_tasks/output/tasks.md" <<'EOF'
# tasks
- **[P] budget-engine** (worker: claude) — `scripts/context-budget.sh`
- **[P] hermes-hooks** (worker: claude) — `hooks/herdr-context-budget.js`
EOF
  # an intent file in the declared slice<TAB>files form.
  printf 'budget-engine\tscripts/context-budget.sh\n' > "$ws/intent.tsv"

  local fail=0
  assert_nonempty() { # assert_nonempty <label> <output>
    if [ -z "$2" ]; then echo "FAIL: $1 produced no output" >&2; fail=1; else echo "ok: $1"; fi
  }

  WS="$ws"; INTENT=""; STAGE=""; SLICE=""; FRACTION="0.25"
  MODEL_OVERRIDE=""; BUDGET_OVERRIDE=""; SESSION=""; LLM=""

  assert_nonempty "detect"  "$(detect)"
  detect | grep -q '^BUDGET=384000' || { echo "FAIL: detect BUDGET not from herd.conf" >&2; fail=1; }

  # settings.json fallback: herd.conf without BUDGET → repo .m2herd/settings.json
  # orchestrator.budget; then restore herd.conf and assert it still wins.
  mkdir -p "$repo/.m2herd"
  printf '{"orchestrator":{"budget":123456}}\n' > "$repo/.m2herd/settings.json"
  printf 'REPO=%s\nBASE=main\n' "$repo" > "$ws/herd.conf"
  detect | grep -q '^BUDGET=123456' || { echo "FAIL: detect BUDGET not from .m2herd/settings.json fallback" >&2; fail=1; }
  detect | grep -q '^SOURCE=m2herd-settings' || { echo "FAIL: detect SOURCE not m2herd-settings" >&2; fail=1; }
  cat > "$ws/herd.conf" <<EOF
REPO=$repo
BASE=main
MODEL=GLM-5.2
BUDGET=384000
EOF
  detect | grep -q '^BUDGET=384000' || { echo "FAIL: herd.conf BUDGET did not win over settings.json" >&2; fail=1; }
  echo "ok: settings.json fallback chain"

  assert_nonempty "status"  "$(status)"
  status | grep -q '^BUDGET=' || { echo "FAIL: status missing BUDGET" >&2; fail=1; }

  INTENT="$ws/intent.tsv"
  assert_nonempty "plan"    "$(plan)"
  [ -f "$ws/stages/03_tasks/context/budget-engine.md" ] || { echo "FAIL: plan wrote no manifest" >&2; fail=1; }
  grep -q '^fits: ' "$ws/stages/03_tasks/context/budget-engine.md" || { echo "FAIL: manifest missing fits header" >&2; fail=1; }
  # manifests must link, never inline the body.
  if grep -q 'SECRET_BODY_MARKER' "$ws/stages/03_tasks/context/budget-engine.md"; then
    echo "FAIL: manifest inlined file body (must be links only)" >&2; fail=1
  fi

  # plan --stage: manifests land under the requested stage, not 03_tasks.
  INTENT="$ws/intent.tsv"; STAGE="09_custom"
  assert_nonempty "plan(--stage)" "$(plan)"
  [ -f "$ws/stages/09_custom/context/budget-engine.md" ] || { echo "FAIL: plan --stage wrote no manifest under 09_custom" >&2; fail=1; }

  INTENT=""; STAGE="04_implement"; SLICE="budget-engine"
  assert_nonempty "pointer" "$(pointer)"
  [ -f "$ws/stages/04_implement/context/budget-engine.md" ] || { echo "FAIL: pointer wrote no manifest" >&2; fail=1; }

  # plan falls back to tasks.md [P] rows when no intent is given.
  INTENT=""; STAGE=""; SLICE=""
  assert_nonempty "plan(tasks-fallback)" "$(INTENT="$ws/does-not-exist.tsv" plan 2>/dev/null || true)"

  # --- summarize: a fixture .out with a planted body marker + a final report block.
  mkdir -p "$ws/stages/04_implement/output"
  local sfix="$ws/stages/04_implement/output/summarizer.out"
  {
    printf 'boot: worker starting on slice summarizer\n'
    local i; for i in $(seq 1 30); do printf 'trace line %s — SUMMARIZE_BODY_MARKER deep-dive detail\n' "$i"; done
    printf '\n## What I did\n'
    printf -- '- added summarize + compact to context-budget.sh\n'
    printf -- '- how I verified: bash -n clean; selftest PASSED\n'
  } > "$sfix"
  INTENT=""; STAGE="04_implement"; SLICE="summarizer"; LLM=""
  local sumout; sumout="$(summarize)"
  assert_nonempty "summarize" "$sumout"
  # (b) STRICTLY shorter than the input (compare bytes).
  local in_b out_b
  in_b="$(wc -c < "$sfix" | tr -d ' ')"
  out_b="$(printf '%s' "$sumout" | wc -c | tr -d ' ')"
  if [ "$out_b" -ge "$in_b" ]; then
    echo "FAIL: summarize not shorter than input ($out_b >= $in_b)" >&2; fail=1
  else echo "ok: summarize shorter than input ($out_b < $in_b)"; fi
  # (c) free of the planted body marker (summary must distill, not copy).
  if printf '%s' "$sumout" | grep -q 'SUMMARIZE_BODY_MARKER'; then
    echo "FAIL: summarize copied the file body (marker leaked)" >&2; fail=1
  else echo "ok: summarize free of body marker"; fi
  # ≤6 lines, always.
  if [ "$(printf '%s\n' "$sumout" | wc -l | tr -d ' ')" -gt 6 ]; then
    echo "FAIL: summarize exceeded 6 lines" >&2; fail=1
  fi
  # --llm "CMD" path: pipe the .out through a filter, still capped to ≤6 lines.
  LLM="head -2"; local llmout; llmout="$(summarize)"; LLM=""
  assert_nonempty "summarize(--llm)" "$llmout"

  # --- compact: rolling pointer with a digest present.
  mkdir -p "$ws/_fleet"
  printf '## summarizer\n\ndistilled summary\n\n[deep-dive](output/summarizer.out)\n' > "$ws/_fleet/digest.md"
  INTENT=""; STAGE=""; SLICE=""
  assert_nonempty "compact" "$(compact)"
  [ -f "$ws/_fleet/context_pointer.md" ] || { echo "FAIL: compact wrote no context_pointer.md" >&2; fail=1; }
  grep -q '^# context_pointer.md' "$ws/_fleet/context_pointer.md" || { echo "FAIL: pointer missing header" >&2; fail=1; }
  grep -q '^active_stage:' "$ws/_fleet/context_pointer.md" || { echo "FAIL: pointer missing active_stage" >&2; fail=1; }
  # pointer links slice context, never inlines the .out body.
  if grep -q 'SUMMARIZE_BODY_MARKER' "$ws/_fleet/context_pointer.md"; then
    echo "FAIL: pointer inlined a deep-dive body (must be links only)" >&2; fail=1
  fi

  if [ "$fail" -ne 0 ]; then echo "selftest: FAILED" >&2; exit 1; fi
  echo "selftest: PASSED"
}

# ---------- dispatch ---------------------------------------------------------
case "$CMD" in
  detect)    detect ;;
  status)    status ;;
  plan)      plan ;;
  pointer)   pointer ;;
  summarize) summarize ;;
  compact)   compact ;;
  selftest)  selftest ;;
  help|*)    sed -n '2,32p' "$0" ;;
esac
