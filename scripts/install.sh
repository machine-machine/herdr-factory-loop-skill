#!/usr/bin/env bash
# install.sh — install the herdr skill into one or more agent skills dirs.
#
# Usage:
#   ./scripts/install.sh                 # install for all detected agents
#   ./scripts/install.sh --hermes        # ~/.hermes/skills/herdr
#   ./scripts/install.sh --claude        # ~/.claude/skills/herdr
#   ./scripts/install.sh --local         # install from the local repo (no clone)
#   ./scripts/install.sh --uninstall
#
# Idempotent. Safe to re-run.

set -euo pipefail

REPO_URL="https://github.com/machine-machine/herdr-factory-loop-skill.git"
SKILL_NAME="herdr"
CACHE_DIR="${HERMES_SKILL_CACHE_DIR:-$HOME/.cache/herdr-factory-loop-skill}"

usage() {
  sed -n '2,12p' "$0"
  exit "${1:-0}"
}

install_hermes=0
install_claude=0
local_mode=0
uninstall=0
for arg in "$@"; do
  case "$arg" in
    --hermes) install_hermes=1 ;;
    --claude) install_claude=1 ;;
    --local)  local_mode=1 ;;
    --uninstall) uninstall=1 ;;
    -h|--help) usage 0 ;;
    *) echo "Unknown arg: $arg" >&2; usage 1 ;;
  esac
done

# Default: install for both if neither flag was given
if [ "$install_hermes" -eq 0 ] && [ "$install_claude" -eq 0 ]; then
  install_hermes=1
  install_claude=1
fi

# Resolve the skill source path
if [ "$local_mode" -eq 1 ]; then
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  SKILL_SRC="$SCRIPT_DIR/../skill"
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

if [ "$install_hermes" -eq 1 ]; then
  install_one "$HOME/.hermes/skills" "hermes"
fi
if [ "$install_claude" -eq 1 ]; then
  install_one "$HOME/.claude/skills" "claude"
fi

if [ "$uninstall" -eq 1 ]; then
  echo "Uninstall complete."
else
  echo "Install complete. Restart your agent session to load the skill."
fi
