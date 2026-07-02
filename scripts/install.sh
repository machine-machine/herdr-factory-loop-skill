#!/usr/bin/env bash
# install.sh — install the herdr skill (and its dispatch-nudge hook) into one
# or more agent skills dirs.
#
# Usage:
#   ./scripts/install.sh                 # install for all detected agents
#   ./scripts/install.sh --hermes        # ~/.hermes/skills/herdr
#   ./scripts/install.sh --claude        # ~/.claude/skills/herdr
#   ./scripts/install.sh --cursor        # ~/.cursor/skills/herdr
#   ./scripts/install.sh --local         # install from the local repo (no clone)
#   ./scripts/install.sh --no-nudge-hook # skip the UserPromptSubmit/pre_llm_call nudge hook
#   ./scripts/install.sh --no-m2herd-hooks # skip the m2herd SessionStart/PreCompact/PostToolUse hooks
#   ./scripts/install.sh --uninstall
#
# Idempotent. Safe to re-run.
#
# What the nudge hook is: a small script (hooks/herdr-dispatch-nudge.sh) wired
# into Claude Code's UserPromptSubmit hook and Hermes's pre_llm_call shell
# hook. It fires every turn and injects a one-paragraph reminder to consider
# fanning decomposable work out to herdr workers — it never decides or spawns
# anything itself, and it never removes the "propose a plan, get explicit
# confirmation before spawning" rule from skill/SKILL.md §9/§11/§13. Installed
# by default for claude/hermes; skipped for cursor (no shell-hook mechanism).
# Before editing a live settings.json/config.yaml this script writes a
# timestamped .bak copy alongside it.

set -euo pipefail

REPO_URL="https://github.com/machine-machine/herdr-factory-loop-skill.git"
SKILL_NAME="herdr"
HOOK_NAME="herdr-dispatch-nudge.sh"
CACHE_DIR="${HERMES_SKILL_CACHE_DIR:-$HOME/.cache/herdr-factory-loop-skill}"

usage() {
  sed -n '2,18p' "$0"
  exit "${1:-0}"
}

install_hermes=0
install_claude=0
install_cursor=0
local_mode=0
uninstall=0
nudge_hook=1
m2herd_hooks=1
for arg in "$@"; do
  case "$arg" in
    --hermes) install_hermes=1 ;;
    --claude) install_claude=1 ;;
    --cursor) install_cursor=1 ;;
    --local)  local_mode=1 ;;
    --no-nudge-hook) nudge_hook=0 ;;
    --no-m2herd-hooks) m2herd_hooks=0 ;;
    --uninstall) uninstall=1 ;;
    -h|--help) usage 0 ;;
    *) echo "Unknown arg: $arg" >&2; usage 1 ;;
  esac
done

# Default: install for all supported agents if no agent flag was given
if [ "$install_hermes" -eq 0 ] && [ "$install_claude" -eq 0 ] && [ "$install_cursor" -eq 0 ]; then
  install_hermes=1
  install_claude=1
  install_cursor=1
fi

# Resolve the skill source path
if [ "$local_mode" -eq 1 ]; then
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  SKILL_SRC="$SCRIPT_DIR/../skill"
  HOOKS_SRC_DIR="$SCRIPT_DIR/../hooks"
  SCRIPTS_SRC_DIR="$SCRIPT_DIR"
  if [ ! -f "$SKILL_SRC/SKILL.md" ]; then
    echo "Local install: $SKILL_SRC/SKILL.md not found." >&2
    echo "Run this from inside a clone of the repo, or omit --local." >&2
    exit 1
  fi
else
  if [ ! -d "$CACHE_DIR" ]; then
    echo "Cloning $REPO_URL to $CACHE_DIR ..."
    git clone --depth 1 "$REPO_URL" "$CACHE_DIR"
  else
    echo "Updating existing clone at $CACHE_DIR ..."
    git -C "$CACHE_DIR" pull --ff-only
  fi
  SKILL_SRC="$CACHE_DIR/skill"
  HOOKS_SRC_DIR="$CACHE_DIR/hooks"
  SCRIPTS_SRC_DIR="$CACHE_DIR/scripts"
fi
HOOK_SRC="$HOOKS_SRC_DIR/$HOOK_NAME"

install_one() {
  local target_dir="$1"
  local label="$2"
  mkdir -p "$target_dir"
  local link="$target_dir/$SKILL_NAME"
  if [ "$uninstall" -eq 1 ]; then
    if [ -L "$link" ]; then
      rm "$link"
      echo "[$label] removed symlink $link"
    elif [ -d "$link" ]; then
      echo "[$label] WARNING: $link is a real directory, not removing (manual cleanup required)" >&2
    else
      echo "[$label] nothing to remove at $link"
    fi
    return 0
  fi
  # Replace any existing symlink/dir with a fresh symlink to SKILL_SRC
  if [ -L "$link" ] || [ -e "$link" ]; then
    rm -rf "$link"
  fi
  ln -s "$SKILL_SRC" "$link"
  echo "[$label] linked $link -> $SKILL_SRC"
}

# Symlink a hook script into <agent>/hooks/, independent of whether we can
# also register it (registration needs jq/yq; the file can still land so a
# user can wire it up by hand if a tool is missing). $3 defaults to the nudge
# hook so pre-m2herd call sites keep working unchanged.
install_hook_file() {
  local hooks_dir="$1"
  local label="$2"
  local name="${3:-$HOOK_NAME}"
  local src="$HOOKS_SRC_DIR/$name"
  local link="$hooks_dir/$name"
  if [ "$uninstall" -eq 1 ]; then
    [ -L "$link" ] && rm "$link" && echo "[$label] removed hook symlink $link"
    return 0
  fi
  mkdir -p "$hooks_dir"
  [ -L "$link" ] || [ -e "$link" ] && rm -rf "$link"
  ln -s "$src" "$link"
  chmod +x "$src" 2>/dev/null || true
  echo "[$label] linked hook $link -> $src"
}

# One backup per file per run: several registration steps may edit the same
# settings file; the .bak must capture the pre-run original, never an
# intermediate state.
BACKUP_TS="$(date +%Y%m%d%H%M%S)"
backup_file() {
  local f="$1"
  [ -f "$f" ] || return 0
  [ -f "$f.bak-$BACKUP_TS" ] || cp "$f" "$f.bak-$BACKUP_TS"
}

# --- Claude Code: register in ~/.claude/settings.json .hooks.UserPromptSubmit
register_claude_hook() {
  local hooks_dir="$HOME/.claude/hooks"
  local settings="$HOME/.claude/settings.json"
  local cmd="bash \"$hooks_dir/$HOOK_NAME\""

  if [ "$uninstall" -eq 1 ]; then
    install_hook_file "$hooks_dir" "claude"
    [ -f "$settings" ] || return 0
    if ! command -v jq >/dev/null 2>&1; then
      echo "[claude] jq not found — cannot remove hook entry from $settings automatically" >&2
      return 0
    fi
    backup_file "$settings"
    local tmp="$settings.tmp.$$"
    jq --arg cmd "$cmd" '
      if has("hooks") and (.hooks | has("UserPromptSubmit")) then
        .hooks.UserPromptSubmit |= map(select(any(.hooks[]?; .command == $cmd) | not))
      else . end
    ' "$settings" > "$tmp" && mv "$tmp" "$settings"
    echo "[claude] removed nudge hook entry from $settings"
    return 0
  fi

  install_hook_file "$hooks_dir" "claude"
  [ "$nudge_hook" -eq 1 ] || return 0
  if ! command -v jq >/dev/null 2>&1; then
    echo "[claude] warn: jq not found — skipping settings.json registration (hook file installed, but inactive until wired up manually)" >&2
    return 0
  fi
  [ -f "$settings" ] || echo '{}' > "$settings"
  backup_file "$settings"
  local tmp="$settings.tmp.$$"
  jq --arg cmd "$cmd" '
    .hooks.UserPromptSubmit = ((.hooks.UserPromptSubmit // []) as $arr |
      if ($arr | any(.hooks[]?.command == $cmd)) then $arr
      else $arr + [{"hooks":[{"type":"command","command":$cmd,"timeout":10}]}]
      end)
  ' "$settings" > "$tmp" && mv "$tmp" "$settings"
  echo "[claude] registered nudge hook in $settings (.hooks.UserPromptSubmit)"
}

# --- m2herd (SKILL.md §16): the three Claude Code hooks + PATH symlinks.
# Dedupe AND uninstall are keyed on the hook FILENAME (the contains($name)
# pattern from the nudge fix), not the full command string — the .js command
# embeds a node path that changes across node/nvm upgrades and would otherwise
# re-append a duplicate live entry on every re-install.
M2HERD_SESSION_HOOK="m2herd-session.sh"
M2HERD_PRECOMPACT_HOOK="m2herd-precompact.sh"
M2HERD_BUDGET_HOOK="m2herd-budget.js"
M2HERD_BUDGET_MATCHER="Bash|Edit|Write|MultiEdit|Agent|Task"

register_m2herd_hooks() {
  local hooks_dir="$HOME/.claude/hooks"
  local settings="$HOME/.claude/settings.json"

  if [ "$uninstall" -eq 1 ]; then
    for h in "$M2HERD_SESSION_HOOK" "$M2HERD_PRECOMPACT_HOOK" "$M2HERD_BUDGET_HOOK"; do
      install_hook_file "$hooks_dir" "claude" "$h"
    done
    [ -f "$settings" ] || return 0
    if ! command -v jq >/dev/null 2>&1; then
      echo "[claude] jq not found — cannot remove m2herd hook entries from $settings automatically" >&2
      return 0
    fi
    backup_file "$settings"
    local tmp="$settings.tmp.$$"
    # Strip only OUR command from each matcher group; drop a group only when
    # that leaves it empty — foreign hooks a user consolidated into the same
    # group keep theirs.
    jq --arg ss "$M2HERD_SESSION_HOOK" --arg pc "$M2HERD_PRECOMPACT_HOOK" --arg bj "$M2HERD_BUDGET_HOOK" '
      def strip($ev; $name):
        if .hooks[$ev] then
          .hooks[$ev] = [ .hooks[$ev][]
            | .hooks = [ (.hooks // [])[] | select(((.command // "") | contains($name)) | not) ]
            | select((.hooks | length) > 0) ]
        else . end;
      .hooks = (.hooks // {})
      | strip("SessionStart"; $ss)
      | strip("PreCompact"; $pc)
      | strip("PostToolUse"; $bj)
    ' "$settings" > "$tmp" && mv "$tmp" "$settings"
    echo "[claude] removed m2herd hook entries from $settings"
    return 0
  fi

  for h in "$M2HERD_SESSION_HOOK" "$M2HERD_PRECOMPACT_HOOK" "$M2HERD_BUDGET_HOOK"; do
    install_hook_file "$hooks_dir" "claude" "$h"
  done
  [ "$m2herd_hooks" -eq 1 ] || return 0
  if ! command -v jq >/dev/null 2>&1; then
    echo "[claude] warn: jq not found — skipping m2herd settings.json registration (hook files installed, but inactive until wired up manually — see SKILL.md §16.5)" >&2
    return 0
  fi
  local budget_ok=1
  if ! command -v node >/dev/null 2>&1; then
    echo "[claude] warn: node not found — skipping the $M2HERD_BUDGET_HOOK PostToolUse hook (SessionStart/PreCompact still registered)" >&2
    budget_ok=0
  fi
  [ -f "$settings" ] || echo '{}' > "$settings"
  backup_file "$settings"
  local tmp="$settings.tmp.$$"
  jq --arg ss "$M2HERD_SESSION_HOOK" --arg pc "$M2HERD_PRECOMPACT_HOOK" --arg bj "$M2HERD_BUDGET_HOOK" \
     --arg sscmd "bash \"$hooks_dir/$M2HERD_SESSION_HOOK\"" \
     --arg pccmd "bash \"$hooks_dir/$M2HERD_PRECOMPACT_HOOK\"" \
     --arg bjcmd "node \"$hooks_dir/$M2HERD_BUDGET_HOOK\"" \
     --arg matcher "$M2HERD_BUDGET_MATCHER" \
     --argjson budget "$budget_ok" '
    def have($ev; $name): [ .hooks[$ev][]?.hooks[]?.command // "" ] | map(contains($name)) | any;
    .hooks = (.hooks // {})
    | (if have("SessionStart"; $ss) then . else
         .hooks.SessionStart = ((.hooks.SessionStart // [])
           + [{"hooks":[{"type":"command","command":$sscmd,"timeout":10}]}]) end)
    | (if have("PreCompact"; $pc) then . else
         .hooks.PreCompact = ((.hooks.PreCompact // [])
           + [{"hooks":[{"type":"command","command":$pccmd,"timeout":10}]}]) end)
    | (if $budget == 0 or have("PostToolUse"; $bj) then . else
         .hooks.PostToolUse = ((.hooks.PostToolUse // [])
           + [{"matcher":$matcher,"hooks":[{"type":"command","command":$bjcmd,"timeout":10}]}]) end)
  ' "$settings" > "$tmp" && mv "$tmp" "$settings"
  echo "[claude] registered m2herd hooks in $settings (SessionStart, PreCompact$([ "$budget_ok" -eq 1 ] && echo ", PostToolUse"))"
}

# PATH wiring: any repo can run the m2herd engine, and the hooks find it via
# `command -v m2herd` (degrading silently when absent).
install_m2herd_bins() {
  local bin_dir="$HOME/.local/bin"
  local pair
  for pair in "m2herd.sh=m2herd" "m2herd-up.sh=m2herd-up"; do
    local src_name="${pair%%=*}" bin_name="${pair#*=}"
    local src="$SCRIPTS_SRC_DIR/$src_name"
    local link="$bin_dir/$bin_name"
    if [ "$uninstall" -eq 1 ]; then
      [ -L "$link" ] && rm "$link" && echo "[claude] removed bin symlink $link"
      continue
    fi
    if [ ! -f "$src" ]; then
      echo "[claude] warn: $src not found — skipping $bin_name symlink" >&2
      continue
    fi
    mkdir -p "$bin_dir"
    [ -L "$link" ] || [ -e "$link" ] && rm -f "$link"
    ln -s "$src" "$link"
    chmod +x "$src" 2>/dev/null || true
    echo "[claude] linked $link -> $src"
  done

  # m2herd-tui: pick the prebuilt for this OS/arch (Go, static). Absent prebuilt
  # is fine — `m2herd dashboard --watch` falls back to the bash renderer.
  local os arch tui_src tui_link="$bin_dir/m2herd-tui"
  if [ "$uninstall" -eq 1 ]; then
    [ -L "$tui_link" ] && rm "$tui_link" && echo "[claude] removed bin symlink $tui_link"
    return 0
  fi
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  arch="$(uname -m)"; case "$arch" in x86_64) arch=amd64 ;; aarch64) arch=arm64 ;; esac
  tui_src="$SCRIPTS_SRC_DIR/../prebuilt/m2herd-tui-$os-$arch"
  if [ -f "$tui_src" ]; then
    [ -L "$tui_link" ] || [ -e "$tui_link" ] && rm -f "$tui_link"
    ln -s "$tui_src" "$tui_link"
    chmod +x "$tui_src" 2>/dev/null || true
    echo "[claude] linked $tui_link -> $tui_src"
  else
    echo "[claude] note: no prebuilt m2herd-tui for $os-$arch — dashboard --watch will use the bash renderer"
  fi
}

# --- Hermes: register in ~/.hermes/config.yaml hooks.pre_llm_call (the
# documented Hermes shell-hook schema — NOT the same shape as settings.json).
register_hermes_hook() {
  local hooks_dir="$HOME/.hermes/hooks"
  local config="$HOME/.hermes/config.yaml"
  local cmd="bash \"$hooks_dir/$HOOK_NAME\""

  if [ "$uninstall" -eq 1 ]; then
    install_hook_file "$hooks_dir" "hermes"
    [ -f "$config" ] || return 0
    if ! command -v yq >/dev/null 2>&1; then
      echo "[hermes] yq not found — cannot remove hook entry from $config automatically" >&2
      return 0
    fi
    backup_file "$config"
    CMD_VAL="$cmd" yq eval -i '
      .hooks.pre_llm_call = ((.hooks.pre_llm_call // []) | map(select(.command != strenv(CMD_VAL))))
    ' "$config"
    echo "[hermes] removed nudge hook entry from $config"
    return 0
  fi

  install_hook_file "$hooks_dir" "hermes"
  [ "$nudge_hook" -eq 1 ] || return 0
  if ! command -v yq >/dev/null 2>&1; then
    echo "[hermes] warn: yq (mikefarah/yq v4) not found — skipping config.yaml registration (hook file installed, but inactive until wired up manually). Install: https://github.com/mikefarah/yq" >&2
    return 0
  fi
  [ -f "$config" ] || { mkdir -p "$HOME/.hermes"; echo 'hooks: {}' > "$config"; }
  backup_file "$config"
  local existing
  existing=$(CMD_VAL="$cmd" yq eval '.hooks.pre_llm_call[]? | select(.command == strenv(CMD_VAL)) | .command' "$config" 2>/dev/null || true)
  if [ -z "$existing" ]; then
    CMD_VAL="$cmd" yq eval -i '.hooks.pre_llm_call += [{"command": strenv(CMD_VAL), "timeout": 10}]' "$config"
    echo "[hermes] registered nudge hook in $config (hooks.pre_llm_call)"
  else
    echo "[hermes] nudge hook already registered in $config"
  fi
  echo "[hermes] note: non-interactive runs (gateway/cron) need one of --accept-hooks, HERMES_ACCEPT_HOOKS=1, or hooks_auto_accept: true — otherwise the first-use consent prompt blocks silently. See skill/SKILL.md §14." >&2
}

if [ "$install_hermes" -eq 1 ]; then
  install_one "$HOME/.hermes/skills" "hermes"
  register_hermes_hook
  # context-budget layer: wire the Hermes hooks (idempotent self-installer).
  hooks_installer="$(cd "$(dirname "$0")" && pwd)/install-hermes-context.sh"
  if [ -x "$hooks_installer" ]; then
    if [ "$uninstall" -eq 1 ]; then
      "$hooks_installer" --uninstall || echo "[hermes] context-budget hooks uninstall failed (non-fatal)" >&2
    else
      "$hooks_installer" || echo "[hermes] context-budget hooks install failed (non-fatal)" >&2
    fi
  fi
fi
if [ "$install_claude" -eq 1 ]; then
  install_one "$HOME/.claude/skills" "claude"
  register_claude_hook
  register_m2herd_hooks
  install_m2herd_bins
fi
if [ "$install_cursor" -eq 1 ]; then
  install_one "$HOME/.cursor/skills" "cursor"
  echo "[cursor] note: cursor has no shell-hook mechanism (see shared/goal_support.md) — nudge hook not installed"
fi

if [ "$uninstall" -eq 1 ]; then
  echo "Uninstall complete."
else
  echo "Install complete. Restart your agent session to load the skill."
fi
