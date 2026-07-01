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
# Usage:
#   context-budget.sh detect  [--ws DIR] [--model NAME] [--budget N]
#   context-budget.sh status  [--ws DIR] [--session ID]
#   context-budget.sh plan    --ws DIR --intent FILE [--fraction 0.25]
#   context-budget.sh pointer --ws DIR --stage S --slice X [--fraction 0.25]
#   context-budget.sh selftest
#
# Workspace (status/plan/pointer) is found via --ws or $HERD_WS and must contain AGENT.md.
# `detect` needs no workspace (falls back to defaults). Idempotent. Safe to re-run.

set -euo pipefail

# ---------- arg parsing ------------------------------------------------------
CMD="${1:-help}"; shift || true
WS=""; INTENT=""; STAGE=""; SLICE=""; SESSION=""; FRACTION="0.25"
MODEL_OVERRIDE=""; BUDGET_OVERRIDE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --ws) WS="$2"; shift 2 ;;
    --intent) INTENT="$2"; shift 2 ;;
    --stage) STAGE="$2"; shift 2 ;;
    --slice) SLICE="$2"; shift 2 ;;
    --session) SESSION="$2"; shift 2 ;;
    --fraction) FRACTION="$2"; shift 2 ;;
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
# order: herd.conf → ~/.hermes/config.yaml model.context_length (+cache) → GLM-5.2/384000.
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
  # 2. ~/.hermes/config.yaml (context_length), then the cache file
  cb="$(yaml_model_key "$HERMES_CONFIG" context_length)"
  cm="$(yaml_model_key "$HERMES_CONFIG" default)"
  if [ -z "$cb" ] && [ -f "$HERMES_CACHE" ]; then
    cb="$(grep -oE 'context_length:[[:space:]]*[0-9]+' "$HERMES_CACHE" 2>/dev/null | grep -oE '[0-9]+' | head -1 || true)"
  fi
  if [ -n "$cb" ]; then
    MODEL="${cm:-$DEFAULT_MODEL}"; BUDGET="$cb"; SOURCE="hermes-config"; return
  fi
  # 3. default
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
plan() {
  resolve_ws
  [ -n "$INTENT" ] || { echo "plan needs --intent FILE" >&2; exit 2; }
  resolve_budget
  local rows; rows="$(slices_from_intent "$INTENT")"
  [ -n "$rows" ] || rows="$(slices_from_tasks "$WS/stages/03_tasks/output/tasks.md")"
  [ -n "$rows" ] || { echo "no slices found in intent or tasks.md" >&2; exit 1; }
  local ctxdir="$WS/stages/03_tasks/context" n=0 oversized=0
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
  MODEL_OVERRIDE=""; BUDGET_OVERRIDE=""; SESSION=""

  assert_nonempty "detect"  "$(detect)"
  detect | grep -q '^BUDGET=384000' || { echo "FAIL: detect BUDGET not from herd.conf" >&2; fail=1; }

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

  INTENT=""; STAGE="04_implement"; SLICE="budget-engine"
  assert_nonempty "pointer" "$(pointer)"
  [ -f "$ws/stages/04_implement/context/budget-engine.md" ] || { echo "FAIL: pointer wrote no manifest" >&2; fail=1; }

  # plan falls back to tasks.md [P] rows when no intent is given.
  INTENT=""; STAGE=""; SLICE=""
  assert_nonempty "plan(tasks-fallback)" "$(INTENT="$ws/does-not-exist.tsv" plan 2>/dev/null || true)"

  if [ "$fail" -ne 0 ]; then echo "selftest: FAILED" >&2; exit 1; fi
  echo "selftest: PASSED"
}

# ---------- dispatch ---------------------------------------------------------
case "$CMD" in
  detect)   detect ;;
  status)   status ;;
  plan)     plan ;;
  pointer)  pointer ;;
  selftest) selftest ;;
  help|*)   sed -n '2,30p' "$0" ;;
esac
