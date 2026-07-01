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
  sed -n '2,17p' "$0"
  exit "${1:-0}"
}

install_hermes=0
install_claude=0
install_cursor=0
local_mode=0
uninstall=0
nudge_hook=1
for arg in "$@"; do
  case "$arg" in
    --hermes) install_hermes=1 ;;
    --claude) install_claude=1 ;;
    --cursor) install_cursor=1 ;;
    --local)  local_mode=1 ;;
    --no-nudge-hook) nudge_hook=0 ;;
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
  HOOK_SRC="$SCRIPT_DIR/../hooks/$HOOK_NAME"
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
  HOOK_SRC="$CACHE_DIR/hooks/$HOOK_NAME"
fi

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

# Symlink the hook script itself into <agent>/hooks/, independent of whether
# we can also register it (registration needs jq/yq; the file can still land
# so a user can wire it up by hand if a tool is missing).
install_hook_file() {
  local hooks_dir="$1"
  local label="$2"
  local link="$hooks_dir/$HOOK_NAME"
  if [ "$uninstall" -eq 1 ]; then
    [ -L "$link" ] && rm "$link" && echo "[$label] removed hook symlink $link"
    return 0
  fi
  mkdir -p "$hooks_dir"
  [ -L "$link" ] || [ -e "$link" ] && rm -rf "$link"
  ln -s "$HOOK_SRC" "$link"
  chmod +x "$HOOK_SRC" 2>/dev/null || true
  echo "[$label] linked hook $link -> $HOOK_SRC"
}

backup_file() {
  local f="$1"
  [ -f "$f" ] || return 0
  cp "$f" "$f.bak-$(date +%Y%m%d%H%M%S)"
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
fi
if [ "$install_claude" -eq 1 ]; then
  install_one "$HOME/.claude/skills" "claude"
  register_claude_hook
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
