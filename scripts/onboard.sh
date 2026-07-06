#!/usr/bin/env bash
# onboard.sh — interactive onboarding TUI for the herdr factory loop.
#
# Walks you through:
#   1. Choosing an orchestrator: Claude Code, Hermes, Cursor, or all
#   2. Verifying the substrate (herdr server, jq, git)
#   3. Installing this skill for the chosen orchestrator(s)
#   4. Installing spec-kit's `specify` CLI (github/spec-kit)
#   5. Initializing spec-kit (the SDD loop) in a target repo
#   6. Writing ~/.config/herdr-factory/config.toml
#
# Usage:
#   ./scripts/onboard.sh                # interactive TUI
#   ./scripts/onboard.sh --orchestrator claude|hermes|cursor|all \
#                        [--repo /path/to/repo] [--yes] [--force]
#   --yes    non-interactive; assumes claude when --orchestrator is omitted
#   --force  pass --force through to 'specify init' (overwrite existing files)
#
# Idempotent. Safe to re-run.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/herdr-factory"
CONFIG_FILE="$CONFIG_DIR/config.toml"
SPEC_KIT_GIT="git+https://github.com/github/spec-kit.git"

# ---------- presentation -----------------------------------------------------

if [ -t 1 ] && command -v tput >/dev/null 2>&1 && [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
  BOLD=$(tput bold); RESET=$(tput sgr0)
  CYAN=$(tput setaf 6); GREEN=$(tput setaf 2); YELLOW=$(tput setaf 3); RED=$(tput setaf 1)
else
  BOLD=""; RESET=""; CYAN=""; GREEN=""; YELLOW=""; RED=""
fi

banner() {
  cat <<EOF
${CYAN}${BOLD}
  ┌─────────────────────────────────────────────────────┐
  │            herdr  ×  spec-kit  factory loop          │
  │                                                     │
  │   spec → plan → tasks → herd implements → verify    │
  └─────────────────────────────────────────────────────┘
${RESET}
EOF
}

say()  { printf '%s\n' "$*"; }
ok()   { printf '%s\n' "  ${GREEN}✓${RESET} $*"; }
warn() { printf '%s\n' "  ${YELLOW}!${RESET} $*"; }
fail() { printf '%s\n' "  ${RED}✗${RESET} $*"; }
step() { printf '\n%s\n' "${BOLD}── $* ──${RESET}"; }

# A controlling terminal we can actually read from ([ -e /dev/tty ] is true
# even when the device cannot be opened, e.g. CI or a headless worker pane).
has_tty() { [ -t 0 ] || { : </dev/tty; } 2>/dev/null; }

no_tty_usage() {
  {
    fail "interactive input needed but no terminal is available."
    say  "  Re-run non-interactively, e.g.:"
    say  "    ./scripts/onboard.sh --orchestrator claude|hermes|cursor|all [--repo /path/to/repo] [--yes]"
  } >&2
  exit 1
}

# tty_read VARNAME — read one line from the controlling terminal into VARNAME;
# exits with usage guidance when there is no terminal to read from.
tty_read() {
  has_tty || no_tty_usage
  IFS= read -r "$1" </dev/tty || no_tty_usage
}

# menu LABEL OPTION... — prints chosen option to stdout.
# Uses gum if available, otherwise a numbered prompt.
menu() {
  local label="$1"; shift
  if command -v gum >/dev/null 2>&1 && has_tty; then
    gum choose --header "$label" "$@"
    return
  fi
  say "${BOLD}$label${RESET}" >&2
  local i=1 opt
  for opt in "$@"; do say "    ${CYAN}$i)${RESET} $opt" >&2; i=$((i+1)); done
  local choice
  while true; do
    printf '  %s' "choose [1-$#]: " >&2
    tty_read choice
    if [ "$choice" -ge 1 ] 2>/dev/null && [ "$choice" -le $# ]; then
      eval "printf '%s\n' \"\${$choice}\""
      return
    fi
    warn "enter a number between 1 and $#" >&2
  done
}

confirm() {
  local prompt="$1"
  [ "$ASSUME_YES" -eq 1 ] && return 0
  if command -v gum >/dev/null 2>&1 && has_tty; then
    gum confirm "$prompt"
    return
  fi
  local ans
  printf '  %s [y/N]: ' "$prompt" >&2
  tty_read ans
  [ "$ans" = "y" ] || [ "$ans" = "Y" ]
}

# ---------- args -------------------------------------------------------------

ORCHESTRATOR=""
TARGET_REPO=""
ASSUME_YES=0
FORCE_INIT=0
need_val() { [ "$#" -ge 2 ] || { fail "$1 requires a value"; exit 1; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --orchestrator) need_val "$@"; ORCHESTRATOR="$2"; shift 2 ;;
    --repo)         need_val "$@"; TARGET_REPO="$2"; shift 2 ;;
    --yes|-y)       ASSUME_YES=1; shift ;;
    --force)        FORCE_INIT=1; shift ;;
    -h|--help)      sed -n '2,19p' "$0"; exit 0 ;;
    *) fail "unknown arg: $1"; exit 1 ;;
  esac
done

banner

# ---------- step 1: orchestrator ----------------------------------------------

step "1/6  Orchestrator"
say "  The orchestrator is the agent that drives the SDD loop and herds the workers."
if [ -z "$ORCHESTRATOR" ] && [ "$ASSUME_YES" -eq 1 ]; then
  ORCHESTRATOR="claude"
  warn "--yes given without --orchestrator — defaulting to 'claude' (pass --orchestrator to override)"
fi
if [ -z "$ORCHESTRATOR" ]; then
  has_tty || no_tty_usage
  CHOICE=$(menu "Which orchestrator should run the factory loop?" \
    "claude  — Claude Code drives spec-kit + the herd" \
    "hermes  — Hermes drives spec-kit + the herd" \
    "cursor  — Cursor (cursor-agent) drives spec-kit + the herd" \
    "all     — install for all, pick per-session")
  ORCHESTRATOR="${CHOICE%% *}"
fi
# `both` accepted as a legacy alias for `all` (pre-cursor onboarding).
[ "$ORCHESTRATOR" = "both" ] && ORCHESTRATOR="all"
case "$ORCHESTRATOR" in
  claude|hermes|cursor|all) ok "orchestrator: ${BOLD}$ORCHESTRATOR${RESET}" ;;
  *) fail "invalid orchestrator '$ORCHESTRATOR' (claude|hermes|cursor|all)"; exit 1 ;;
esac

# ---------- step 2: substrate checks -------------------------------------------

step "2/6  Substrate checks"
MISSING=0
HERDR_OK=1
if command -v herdr >/dev/null 2>&1; then
  if herdr status >/dev/null 2>&1; then
    ok "herdr server is running ($(herdr --version 2>/dev/null | head -1 || echo 'version unknown'))"
  else
    warn "herdr is installed but the server is not running — start it with: herdr server start"
  fi
else
  HERDR_OK=0
  warn "herdr not found on PATH — onboarding can finish, but the herd cannot run without it."
  warn "  install: clone https://github.com/machine-machine/herdr and follow its README"
  warn "  (binary lands in ~/.local/bin/herdr; verify with: herdr status)"
fi
# Required + recommended tools — report everything missing at once, exit once.
for tool in jq git; do
  if command -v "$tool" >/dev/null 2>&1; then ok "$tool found"; else
    fail "$tool not found (required) — install via your package manager (apt/brew install $tool)"
    MISSING=1
  fi
done
command -v node >/dev/null 2>&1 && ok "node found" \
  || warn "node not on PATH — the m2herd/context-budget PostToolUse hooks need it (https://nodejs.org or your package manager)"
command -v tmux >/dev/null 2>&1 && ok "tmux found" \
  || warn "tmux not on PATH — herdr panes run on tmux (apt/brew install tmux)"
if command -v uv >/dev/null 2>&1 || command -v uvx >/dev/null 2>&1; then
  ok "uv/uvx found"
else
  warn "neither uv nor uvx on PATH — needed for spec-kit (install: curl -LsSf https://astral.sh/uv/install.sh | sh)"
fi
if command -v yq >/dev/null 2>&1; then
  if yq --version 2>&1 | grep -qi mikefarah; then
    ok "yq found (mikefarah/yq)"
  else
    warn "yq on PATH looks like python-yq — Hermes hook registration needs mikefarah/yq v4 ('yq eval -i'): https://github.com/mikefarah/yq"
  fi
else
  warn "yq not on PATH — Hermes config.yaml hook registration will be skipped (install mikefarah/yq v4: https://github.com/mikefarah/yq)"
fi
case "$ORCHESTRATOR" in
  claude|all) command -v claude >/dev/null 2>&1 && ok "claude CLI found" || warn "claude CLI not on PATH" ;;
esac
case "$ORCHESTRATOR" in
  hermes|all) command -v hermes >/dev/null 2>&1 && ok "hermes CLI found" || warn "hermes CLI not on PATH" ;;
esac
case "$ORCHESTRATOR" in
  cursor|all) command -v cursor-agent >/dev/null 2>&1 && ok "cursor-agent CLI found" || warn "cursor-agent CLI not on PATH (install: https://cursor.com/cli)" ;;
esac
if [ "$MISSING" -eq 1 ]; then
  fail "fix the missing required tools above, then re-run onboarding"
  exit 1
fi

# ---------- step 3: install the skill ------------------------------------------

step "3/6  Install the herdr skill for $ORCHESTRATOR"
say "  Also wires up the dispatch-nudge hook (skill/SKILL.md §14): a per-turn"
say "  reminder to consider fanning decomposable work out to herdr workers —"
say "  it never spawns anything itself, only proposes; you still confirm."
say "  For Claude Code the install also registers the three m2herd hooks"
say "  (SessionStart / PreCompact / PostToolUse — skill/SKILL.md §16) and puts"
say "  m2herd + m2herd-up on PATH (~/.local/bin), so the per-repo .m2herd/"
say "  context fabric orients every session; skip with --no-m2herd-hooks."
case "$ORCHESTRATOR" in
  claude) "$SCRIPT_DIR/install.sh" --local --claude ;;
  hermes) "$SCRIPT_DIR/install.sh" --local --hermes ;;
  cursor) "$SCRIPT_DIR/install.sh" --local --cursor ;;
  all)    "$SCRIPT_DIR/install.sh" --local ;;
esac
# install.sh runs install-hermes-context.sh for hermes/all — the context-budget
# hooks (default GLM-5.2 / 384k) keep the Hermes orchestrator within budget.
case "$ORCHESTRATOR" in
  hermes|all) command -v hermes >/dev/null 2>&1 && hermes hooks doctor >/dev/null 2>&1 \
                && ok "Hermes context-budget hooks active (see 'hermes hooks list')" || true ;;
esac

# ---------- step 4: spec-kit CLI ------------------------------------------------

step "4/6  spec-kit (github/spec-kit)"
SPECIFY_BIN=""
if command -v specify >/dev/null 2>&1; then
  SPECIFY_BIN=$(command -v specify)
  ok "specify CLI already installed: $SPECIFY_BIN"
elif command -v uv >/dev/null 2>&1; then
  if confirm "Install the specify CLI via 'uv tool install'?"; then
    uv tool install specify-cli --from "$SPEC_KIT_GIT"
    SPECIFY_BIN=$(command -v specify || true)
    # uv installs into ~/.local/bin, which may not be on PATH yet
    [ -z "$SPECIFY_BIN" ] && [ -x "$HOME/.local/bin/specify" ] && SPECIFY_BIN="$HOME/.local/bin/specify"
    [ -n "$SPECIFY_BIN" ] && ok "installed specify CLI: $SPECIFY_BIN" || warn "install ran but 'specify' is not on PATH — check 'uv tool list'"
  else
    warn "skipped — you can use ephemeral runs: uvx --from $SPEC_KIT_GIT specify ..."
  fi
elif command -v uvx >/dev/null 2>&1; then
  warn "uv not found; falling back to ephemeral runs via: uvx --from $SPEC_KIT_GIT specify ..."
else
  warn "neither uv nor uvx found — install uv first: curl -LsSf https://astral.sh/uv/install.sh | sh"
fi

specify_cmd() {
  if [ -n "$SPECIFY_BIN" ]; then "$SPECIFY_BIN" "$@"; else uvx --from "$SPEC_KIT_GIT" specify "$@"; fi
}

# ---------- step 5: establish the SDD loop in a repo ----------------------------

step "5/6  Establish the SDD loop in a repo"
if [ -z "$TARGET_REPO" ] && [ "$ASSUME_YES" -eq 0 ]; then
  if has_tty; then
    printf '  %s' "Path to the repo to initialize with spec-kit (empty = skip): "
    read -r TARGET_REPO </dev/tty || TARGET_REPO=""
  else
    warn "no terminal to prompt for a repo — skipping spec-kit init (pass --repo /path to set one)"
  fi
fi
SPECKIT_INITIALIZED="false"
if [ -n "$TARGET_REPO" ]; then
  TARGET_REPO=$(cd "$TARGET_REPO" 2>/dev/null && pwd) || { fail "no such directory: $TARGET_REPO"; exit 1; }
  if [ -d "$TARGET_REPO/.specify" ]; then
    ok "$TARGET_REPO already has .specify/ — skipping init"
    SPECKIT_INITIALIZED="true"
  else
    # spec-kit renamed --ai to --integration; detect which this build wants.
    # (capture help first: grep -q would SIGPIPE specify and trip pipefail)
    INIT_HELP=$(specify_cmd init --help 2>/dev/null || true)
    AGENT_FLAG="--ai"
    HAS_GENERIC=0
    if printf '%s' "$INIT_HELP" | grep -q -- '--integration'; then
      AGENT_FLAG="--integration"
      HAS_GENERIC=1
    fi
    # Pick the integration for the chosen orchestrator. claude and cursor are
    # spec-kit-native (prompts land in .claude/commands/ and .cursor/commands/
    # respectively). Hermes is not native: use the generic integration so the
    # /speckit.* prompts land in .hermes/commands/ (falls back to claude
    # templates on old spec-kit builds — Hermes can read .claude/commands/*.md).
    INIT_ARGS=(init --here --script sh)
    # --force overwrites existing files in the target repo — only pass it
    # through when the user explicitly asked (onboard.sh --force).
    if [ "$FORCE_INIT" -eq 1 ]; then
      if printf '%s' "$INIT_HELP" | grep -q -- '--force'; then
        INIT_ARGS+=(--force)
      else
        warn "this spec-kit build has no --force flag — ignoring onboard.sh --force"
      fi
    elif [ "$ASSUME_YES" -eq 1 ]; then
      warn "spec-kit may prompt or refuse if $TARGET_REPO is not empty — re-run with --force to overwrite"
    fi
    case "$ORCHESTRATOR" in
      hermes)
        if [ "$HAS_GENERIC" -eq 1 ]; then
          INIT_ARGS+=("$AGENT_FLAG" generic --integration-options="--commands-dir .hermes/commands/")
        else
          INIT_ARGS+=("$AGENT_FLAG" claude --ignore-agent-tools)
        fi ;;
      claude) INIT_ARGS+=("$AGENT_FLAG" claude) ;;
      cursor) INIT_ARGS+=("$AGENT_FLAG" cursor) ;;  # native; prompts → .cursor/commands/
      all)    INIT_ARGS+=("$AGENT_FLAG" claude) ;;  # claude native; hermes reads .claude/commands/*.md; re-run with --integration cursor for .cursor/commands/
    esac
    say "  Running: specify ${INIT_ARGS[*]}  (in $TARGET_REPO)"
    if confirm "Proceed?"; then
      (cd "$TARGET_REPO" && specify_cmd "${INIT_ARGS[@]}")
      SPECKIT_INITIALIZED="true"
      ok "spec-kit initialized — /speckit.* commands are now available in $TARGET_REPO"
    else
      warn "skipped spec-kit init"
    fi
  fi
else
  warn "no repo given — run 'specify init --here' later in any repo to establish the loop there"
fi

# ---------- step 6: write config -------------------------------------------------

step "6/6  Write factory config"
mkdir -p "$CONFIG_DIR"
if [ -f "$CONFIG_FILE" ]; then
  CONFIG_BAK="$CONFIG_FILE.bak-$(date +%Y%m%d%H%M%S)"
  cp "$CONFIG_FILE" "$CONFIG_BAK"
  ok "backed up existing config to $CONFIG_BAK"
fi
cat > "$CONFIG_FILE" <<EOF
# herdr factory loop — written by scripts/onboard.sh, safe to edit.
[orchestrator]
primary = "$ORCHESTRATOR"

[speckit]
cli = "${SPECIFY_BIN:-uvx --from $SPEC_KIT_GIT specify}"
last_repo = "${TARGET_REPO:-}"
initialized = $SPECKIT_INITIALIZED

[onboarding]
date = "$(date +%Y-%m-%d)"
skill_repo = "$REPO_ROOT"
EOF
ok "wrote $CONFIG_FILE"

# ---------- done -----------------------------------------------------------------

if [ "$HERDR_OK" -eq 0 ]; then
  printf '\n'
  warn "herdr is still missing — install it before running the herd (the 'herd implements' step needs it)"
fi
printf '\n%s\n' "${GREEN}${BOLD}Onboarding complete.${RESET} The SDD factory loop:"
cat <<EOF

  ${CYAN}1.${RESET} /speckit.constitution   — project principles (once per repo)
  ${CYAN}2.${RESET} /speckit.specify        — WHAT to build → specs/<feature>/spec.md
  ${CYAN}3.${RESET} /speckit.clarify        — resolve underspecified requirements
  ${CYAN}4.${RESET} /speckit.plan           — HOW to build it → plan.md
  ${CYAN}5.${RESET} /speckit.tasks          — actionable task list → tasks.md ([P] = parallel)
  ${CYAN}6.${RESET} herd implements         — herdr fans [P] tasks out to workers (SKILL.md §11)
  ${CYAN}7.${RESET} /speckit.analyze        — cross-artifact consistency gate before merge
  ${CYAN}8.${RESET} converge + compound     — merge, verify against spec.md, write run report (§10)

Start a ${BOLD}$ORCHESTRATOR${RESET} session in your repo and say: "run the factory loop on <feature idea>".
EOF
