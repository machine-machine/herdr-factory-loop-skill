#!/usr/bin/env bash
# install-hermes-context.sh — self-installer for the Hermes context-budget hooks.
#
# Wires the two context-budget hooks into ~/.hermes/, sets the Hermes context
# window default, and verifies the install. Idempotent: safe to re-run.
#
# Usage:
#   ./scripts/install-hermes-context.sh                  # install with defaults
#   ./scripts/install-hermes-context.sh --budget 512000  # custom context budget
#   ./scripts/install-hermes-context.sh --model GLM-5.2   # record intended model
#   ./scripts/install-hermes-context.sh --compression off # disable Hermes native compression
#   ./scripts/install-hermes-context.sh --dry-run        # show actions, change nothing
#   ./scripts/install-hermes-context.sh --uninstall      # remove hooks + entries
#   ./scripts/install-hermes-context.sh --help
#
# Idempotent. Safe to re-run.

set -euo pipefail

# --- defaults ---------------------------------------------------------------
BUDGET=384000
MODEL="GLM-5.2"
COMPRESSION=on
DRY_RUN=0
UNINSTALL=0

HERMES_DIR="${HERMES_HOME:-$HOME/.hermes}"
HOOKS_DIR="$HERMES_DIR/hooks"
SETTINGS="$HERMES_DIR/settings.json"
CONFIG="$HERMES_DIR/config.yaml"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC_HOOKS="$REPO_ROOT/hooks"

# The two hook files this installer manages.
HOOK_JS="herdr-context-budget.js"
HOOK_SH="herdr-context-session.sh"

# --- messaging helpers (match install.sh style) -----------------------------
usage() {
  sed -n '2,17p' "$0"
  exit "${1:-0}"
}
say()  { echo "$*"; }
info() { echo "  $*"; }
pass() { echo "  ✓ $*"; }
fail() { echo "  ✗ $*" >&2; }

# --- arg parsing ------------------------------------------------------------
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run)   DRY_RUN=1 ;;
    --uninstall) UNINSTALL=1 ;;
    --budget)    shift; BUDGET="${1:?--budget requires a value}" ;;
    --model)     shift; MODEL="${1:?--model requires a value}" ;;
    --compression) shift; COMPRESSION="${1:?--compression requires on|off}" ;;
    -h|--help)   usage 0 ;;
    *) echo "Unknown arg: $1" >&2; usage 1 ;;
  esac
  shift
done

if ! echo "$BUDGET" | grep -qE '^[0-9]+$'; then
  echo "Error: --budget must be an integer (got '$BUDGET')" >&2
  exit 1
fi

case "$COMPRESSION" in
  on|off) ;;
  *) echo "Error: --compression must be 'on' or 'off' (got '$COMPRESSION')" >&2; exit 1 ;;
esac
# Desired compression.enabled value as a YAML boolean.
[ "$COMPRESSION" = on ] && COMPRESSION_ENABLED=true || COMPRESSION_ENABLED=false

command -v jq >/dev/null 2>&1 || { echo "Error: jq is required but not on PATH." >&2; exit 1; }

# Resolve node for the JS hook command (match existing settings entries, which
# quote the absolute node path). Fall back to bare 'node' if not resolvable.
NODE_BIN="$(command -v node 2>/dev/null || true)"
[ -n "$NODE_BIN" ] || NODE_BIN="node"

# The exact command strings we key idempotent merges on.
BUDGET_CMD="\"$NODE_BIN\" \"$HOOKS_DIR/$HOOK_JS\""
SESSION_CMD="bash \"$HOOKS_DIR/$HOOK_SH\""

TS="$(date +%Y%m%d%H%M%S)"

# ---------------------------------------------------------------------------
# settings.json: build the merged JSON (idempotent, keyed by command string).
# Prints the merged document to stdout; does not write anything itself.
# ---------------------------------------------------------------------------
merged_settings() {
  local src="$1"
  jq \
    --arg pcmd "$BUDGET_CMD" \
    --arg scmd "$SESSION_CMD" \
    '
    .hooks = (.hooks // {})
    | .hooks.PostToolUse = (.hooks.PostToolUse // [])
    | .hooks.SessionStart = (.hooks.SessionStart // [])
    | (if ([.hooks.PostToolUse[].hooks[]?.command] | index($pcmd)) then .
       else .hooks.PostToolUse += [{
         matcher: "Bash|Edit|Write|MultiEdit|Agent|Task",
         hooks: [{ type: "command", command: $pcmd, timeout: 10 }]
       }] end)
    | (if ([.hooks.SessionStart[].hooks[]?.command] | index($scmd)) then .
       else .hooks.SessionStart += [{
         hooks: [{ type: "command", command: $scmd }]
       }] end)
    ' "$src"
}

# settings.json with our two entries stripped out (restore-safe uninstall).
stripped_settings() {
  local src="$1"
  jq \
    --arg pcmd "$BUDGET_CMD" \
    --arg scmd "$SESSION_CMD" \
    '
    .hooks = (.hooks // {})
    | (if .hooks.PostToolUse then
        .hooks.PostToolUse = [ .hooks.PostToolUse[]
          | select(((.hooks // []) | map(.command) | index($pcmd)) | not) ]
       else . end)
    | (if .hooks.SessionStart then
        .hooks.SessionStart = [ .hooks.SessionStart[]
          | select(((.hooks // []) | map(.command) | index($scmd)) | not) ]
       else . end)
    ' "$src"
}

# Back up config.yaml once per run (multiple config steps share one .bak.$TS,
# so the backup always captures the pre-run original, never an intermediate).
backup_config() {
  [ -f "$CONFIG.bak.$TS" ] && return 0
  cp "$CONFIG" "$CONFIG.bak.$TS" && info "backed up → $CONFIG.bak.$TS"
}

# ---------------------------------------------------------------------------
# config.yaml: rewrite ONLY model.context_length; record MODEL as a comment.
# Prints the rewritten file to stdout; touches no other key.
# ---------------------------------------------------------------------------
rewrite_config() {
  local src="$1"
  awk -v budget="$BUDGET" -v model="$MODEL" '
    /^model:[[:space:]]*$/ { in_model=1; print; next }
    # a new top-level key (no leading space, not a comment) closes the model block
    in_model && /^[^[:space:]#]/ { in_model=0 }
    in_model && /^[[:space:]]+context_length:[[:space:]]*/ {
      match($0, /^[[:space:]]+/); indent=substr($0, 1, RLENGTH)
      printf "%scontext_length: %s  # MODEL=%s (install-hermes-context.sh)\n", indent, budget, model
      done=1; next
    }
    { print }
    END { if (!done) exit 3 }
  ' "$src"
}

# ---------------------------------------------------------------------------
# config.yaml: rewrite ONLY compression.enabled within the top-level
# compression: block. Prints the rewritten file to stdout; touches no other
# key (threshold/target_ratio/etc. are left exactly as Hermes has them).
# ---------------------------------------------------------------------------
rewrite_compression() {
  local src="$1"
  awk -v want="$COMPRESSION_ENABLED" '
    /^compression:[[:space:]]*$/ { in_comp=1; print; next }
    # a new top-level key (no leading space, not a comment) closes the block
    in_comp && /^[^[:space:]#]/ { in_comp=0 }
    in_comp && /^[[:space:]]+enabled:[[:space:]]*/ {
      match($0, /^[[:space:]]+/); indent=substr($0, 1, RLENGTH)
      printf "%senabled: %s\n", indent, want
      done=1; next
    }
    { print }
    END { if (!done) exit 3 }
  ' "$src"
}

# ---------------------------------------------------------------------------
# install
# ---------------------------------------------------------------------------
do_install() {
  say "Installing Hermes context-budget hooks → $HERMES_DIR"
  say "  budget=$BUDGET  model=$MODEL  compression=$COMPRESSION  dry-run=$DRY_RUN"
  say

  # 1. Copy hook files -------------------------------------------------------
  say "[1/4] hook files → $HOOKS_DIR"
  local f missing=0
  for f in "$HOOK_JS" "$HOOK_SH"; do
    if [ ! -f "$SRC_HOOKS/$f" ]; then
      fail "source $SRC_HOOKS/$f not found (produced by a sibling slice) — skipping copy"
      missing=1
      continue
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
      info "would copy $SRC_HOOKS/$f → $HOOKS_DIR/$f (chmod +x)"
    else
      mkdir -p "$HOOKS_DIR"
      cp "$SRC_HOOKS/$f" "$HOOKS_DIR/$f"
      chmod +x "$HOOKS_DIR/$f"
      pass "copied $f"
    fi
  done
  [ "$missing" -eq 1 ] && info "(installer still wires settings/config; hooks activate once the files land)"
  say

  # 2. Merge settings.json ---------------------------------------------------
  say "[2/4] settings.json ← 1 PostToolUse + 1 SessionStart entry (idempotent)"
  if [ ! -f "$SETTINGS" ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
      info "would create $SETTINGS with the two hook entries"
    else
      mkdir -p "$HERMES_DIR"
      echo '{"hooks":{}}' > "$SETTINGS"
      pass "created empty $SETTINGS"
    fi
  fi
  local base="$SETTINGS"
  [ -f "$base" ] || base=/dev/null
  local tmp; tmp="$(mktemp)"
  if [ "$base" = /dev/null ]; then echo '{"hooks":{}}' | merged_settings /dev/stdin > "$tmp"
  else merged_settings "$base" > "$tmp"; fi

  if [ "$DRY_RUN" -eq 1 ]; then
    info "diff (current → merged):"
    if [ -f "$SETTINGS" ]; then
      diff -u "$SETTINGS" "$tmp" | sed 's/^/    /' || true
    else
      sed 's/^/    + /' "$tmp"
    fi
  else
    if [ -f "$SETTINGS" ] && diff -q "$SETTINGS" "$tmp" >/dev/null 2>&1; then
      pass "settings.json already current — no change (idempotent)"
    else
      [ -f "$SETTINGS" ] && cp "$SETTINGS" "$SETTINGS.bak.$TS" && info "backed up → $SETTINGS.bak.$TS"
      mv "$tmp" "$SETTINGS"
      pass "settings.json merged"
      tmp=""
    fi
  fi
  [ -n "$tmp" ] && rm -f "$tmp"
  say

  # 3. config.yaml context_length -------------------------------------------
  say "[3/4] config.yaml model.context_length → $BUDGET"
  if [ ! -f "$CONFIG" ]; then
    fail "$CONFIG not found — skipping context_length update"
  else
    local ctmp rc=0
    ctmp="$(mktemp)"
    rewrite_config "$CONFIG" > "$ctmp" || rc=$?
    if [ "$rc" -eq 3 ]; then
      fail "no model.context_length key found in $CONFIG — leaving file untouched"
      rm -f "$ctmp"
    elif [ "$DRY_RUN" -eq 1 ]; then
      info "diff (current → updated):"
      diff -u "$CONFIG" "$ctmp" | sed 's/^/    /' || true
      rm -f "$ctmp"
    elif diff -q "$CONFIG" "$ctmp" >/dev/null 2>&1; then
      pass "config.yaml already at context_length=$BUDGET — no change (idempotent)"
      rm -f "$ctmp"
    else
      backup_config
      mv "$ctmp" "$CONFIG"
      pass "config.yaml context_length set to $BUDGET (MODEL=$MODEL recorded)"
    fi
  fi
  say

  # 4. config.yaml compression: block ---------------------------------------
  say "[4/4] config.yaml compression.enabled → $COMPRESSION_ENABLED"
  if [ ! -f "$CONFIG" ]; then
    fail "$CONFIG not found — skipping compression update"
  else
    local xtmp rc=0
    xtmp="$(mktemp)"
    rewrite_compression "$CONFIG" > "$xtmp" || rc=$?
    if [ "$rc" -eq 3 ]; then
      fail "no compression.enabled key found in $CONFIG — leaving file untouched"
      rm -f "$xtmp"
    elif [ "$DRY_RUN" -eq 1 ]; then
      info "diff (current → updated):"
      diff -u "$CONFIG" "$xtmp" | sed 's/^/    /' || true
      rm -f "$xtmp"
    elif diff -q "$CONFIG" "$xtmp" >/dev/null 2>&1; then
      pass "config.yaml already at compression.enabled=$COMPRESSION_ENABLED — no change (idempotent)"
      rm -f "$xtmp"
    else
      backup_config
      mv "$xtmp" "$CONFIG"
      pass "config.yaml compression.enabled set to $COMPRESSION_ENABLED"
    fi
  fi
  say
}

# ---------------------------------------------------------------------------
# uninstall
# ---------------------------------------------------------------------------
do_uninstall() {
  say "Uninstalling Hermes context-budget hooks from $HERMES_DIR"
  say "  dry-run=$DRY_RUN"
  say

  # 1. Strip settings.json entries ------------------------------------------
  say "[1/2] settings.json ← remove the two hook entries"
  if [ ! -f "$SETTINGS" ]; then
    info "no $SETTINGS — nothing to strip"
  else
    local tmp; tmp="$(mktemp)"
    stripped_settings "$SETTINGS" > "$tmp"
    if [ "$DRY_RUN" -eq 1 ]; then
      info "diff (current → stripped):"
      diff -u "$SETTINGS" "$tmp" | sed 's/^/    /' || true
      rm -f "$tmp"
    elif diff -q "$SETTINGS" "$tmp" >/dev/null 2>&1; then
      pass "settings.json has no matching entries — no change"
      rm -f "$tmp"
    else
      cp "$SETTINGS" "$SETTINGS.bak.$TS" && info "backed up → $SETTINGS.bak.$TS"
      mv "$tmp" "$SETTINGS"
      pass "settings.json entries removed"
    fi
  fi
  say

  # 2. Delete copied hook files ---------------------------------------------
  say "[2/2] remove copied hook files"
  local f
  for f in "$HOOK_JS" "$HOOK_SH"; do
    if [ ! -e "$HOOKS_DIR/$f" ]; then
      info "$HOOKS_DIR/$f absent — nothing to remove"
    elif [ "$DRY_RUN" -eq 1 ]; then
      info "would remove $HOOKS_DIR/$f"
    else
      rm -f "$HOOKS_DIR/$f"
      pass "removed $f"
    fi
  done
  say
  info "Note: config.yaml context_length left as-is (a backup exists if it was changed)."
  info "Note: config.yaml compression.enabled left as-is — uninstall does not force it off."
  say
}

# ---------------------------------------------------------------------------
# verify
# ---------------------------------------------------------------------------
verify() {
  say "Verification"
  # settings.json contains (or, after uninstall, lacks) our entries?
  if [ -f "$SETTINGS" ]; then
    local has_p has_s
    has_p="$(jq --arg c "$BUDGET_CMD" '[.hooks.PostToolUse[]?.hooks[]?.command] | index($c) != null' "$SETTINGS" 2>/dev/null || echo false)"
    has_s="$(jq --arg c "$SESSION_CMD" '[.hooks.SessionStart[]?.hooks[]?.command] | index($c) != null' "$SETTINGS" 2>/dev/null || echo false)"
    if [ "$UNINSTALL" -eq 1 ]; then
      [ "$has_p" = false ] && pass "PostToolUse entry removed" || fail "PostToolUse entry still present"
      [ "$has_s" = false ] && pass "SessionStart entry removed" || fail "SessionStart entry still present"
    else
      [ "$has_p" = true ] && pass "PostToolUse budget hook registered" || fail "PostToolUse budget hook missing"
      [ "$has_s" = true ] && pass "SessionStart session hook registered" || fail "SessionStart session hook missing"
    fi
  else
    info "no settings.json to inspect"
  fi

  # Report the resulting compression.enabled value from the config.yaml block.
  if [ -f "$CONFIG" ]; then
    local comp_val
    comp_val="$(awk '
      /^compression:[[:space:]]*$/ { in_comp=1; next }
      in_comp && /^[^[:space:]#]/ { in_comp=0 }
      in_comp && /^[[:space:]]+enabled:[[:space:]]*/ { print $2; exit }
    ' "$CONFIG")"
    if [ -n "$comp_val" ]; then
      pass "config.yaml compression.enabled = $comp_val"
    else
      info "no compression.enabled key found in $CONFIG"
    fi
  fi

  if command -v hermes >/dev/null 2>&1; then
    say "  running: hermes hooks doctor"
    if hermes hooks doctor 2>&1 | sed 's/^/    /'; then
      pass "hermes hooks doctor completed"
    else
      fail "hermes hooks doctor reported problems (see above)"
    fi
  else
    info "hermes not on PATH — skipping 'hermes hooks doctor'"
  fi
  say
}

# ---------------------------------------------------------------------------
main() {
  if [ "$DRY_RUN" -eq 1 ]; then
    say "=== DRY RUN — no files will change ==="
    say
  fi
  if [ "$UNINSTALL" -eq 1 ]; then
    do_uninstall
  else
    do_install
  fi
  if [ "$DRY_RUN" -eq 0 ]; then
    verify
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    say "Dry run complete. Re-run without --dry-run to apply."
  elif [ "$UNINSTALL" -eq 1 ]; then
    say "Uninstall complete."
  else
    say "Install complete. Restart Hermes to load the hooks."
  fi
}

main
