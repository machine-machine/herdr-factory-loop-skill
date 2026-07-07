#!/usr/bin/env bash
# ctx-bridge.sh — Claude Code statusline command + context-budget bridge WRITER.
#
# The whole budget layer (hooks/m2herd-budget.js, hooks/herdr-context-budget.js,
# scripts/context-budget.sh status, the m2herd.sh dashboard budget row) READS
# /tmp/claude-ctx-<session-id>.json — this script is the thing that WRITES it.
# Wire it as the Claude Code statusline command (settings.json):
#   "statusLine": {"type": "command", "command": "bash <repo>/scripts/ctx-bridge.sh"}
# Claude Code pipes a JSON payload to the statusline command on every refresh;
# we parse it, persist the context metrics, and print a one-line statusline —
# so the script stays useful as a statusline in its own right.
#
# Statusline payload fields handled (all parsed defensively — any may be absent):
#   .session_id                                       bridge-file key (sanitised)
#   .model.display_name | .model.id                   shown in the statusline
#   .context_window.used_tokens | .tokens_used | .used   context tokens in play
#   .context_window.max_tokens | .context_window_size | .size   window size
#   .context.used_tokens | .context.max_tokens        older payload shape
# Cost fields (.cost.*) are NOT context usage and are ignored.
#
# Bridge file written (superset of the readers' contract):
#   {"used":N, "budget":N, "pct":N, "used_pct":N, "remaining_percentage":N,
#    "timestamp":"<ISO-8601 UTC>", "timestamp_epoch":N}
# used_pct mirrors pct (context-budget.sh / m2herd.sh key on used_pct);
# timestamp_epoch mirrors timestamp for the js hooks' numeric stale check.
# Written atomically (same-dir tmp + mv), always to LITERAL /tmp — every
# reader checks /tmp first; the $TMPDIR fallback is the readers' side.
#
# Contract: bounded stdin read, never blocks, ALWAYS exits 0. Without jq it
# prints a static line and writes nothing. Without usable usage fields it
# prints the model line and writes nothing.

set -u

DEFAULT_BUDGET=384000

# Bounded stdin read: the payload is small; 64 KiB is plenty and head returns
# as soon as stdin closes — no hang, no unbounded buffering. tr strips null
# bytes so a binary-garbage payload can't trigger bash's null-byte warning.
payload="$( (head -c 65536 2>/dev/null || true) | tr -d '\0' 2>/dev/null || true)"

if ! command -v jq >/dev/null 2>&1; then
  printf 'claude · ctx n/a (jq missing)\n'
  exit 0
fi

# One defensive jq pass: model name, session id, used tokens, window size.
# Garbage / non-JSON payloads make jq fail → parsed stays empty → static line.
parsed="$(printf '%s' "$payload" | jq -r '
  [ (.model.display_name // .model.id // "claude" | tostring),
    (.session_id // "" | tostring),
    ((.context_window.used_tokens // .context_window.tokens_used
      // .context_window.used // .context.used_tokens // "") | tostring),
    ((.context_window.max_tokens // .context_window.context_window_size
      // .context_window.size // .context.max_tokens // "") | tostring)
  ] | @tsv' 2>/dev/null || true)"

if [ -z "$parsed" ]; then
  printf 'claude\n'
  exit 0
fi

model="$(printf '%s' "$parsed" | cut -f1)"
sid="$(printf '%s' "$parsed" | cut -f2)"
used="$(printf '%s' "$parsed" | cut -f3)"
budget="$(printf '%s' "$parsed" | cut -f4)"
[ -n "$model" ] || model="claude"

# used must be a plain non-negative integer; else we have nothing to persist.
case "$used" in ''|*[!0-9]*) used="" ;; esac
# budget falls back to the factory default (PAIRED VALUE: m2herd-budget.js /
# context-budget.sh assume 384000 for the same bridge file).
case "$budget" in ''|*[!0-9]*|0) budget="$DEFAULT_BUDGET" ;; esac

if [ -z "$used" ]; then
  printf '%s\n' "$model"
  exit 0
fi

pct=$(( (used * 100 + budget / 2) / budget ))
[ "$pct" -le 100 ] || pct=100
[ "$pct" -ge 0 ] || pct=0

# Persist the bridge file only for a sane session id: non-empty, no path
# separators / traversal (it is interpolated into a /tmp path).
write_ok=0
if [ -n "$sid" ]; then
  case "$sid" in
    */*|*\\*|*..*) : ;;  # unsafe id → print only, write nothing
    *)
      ts_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      ts_epoch="$(date -u +%s)"
      tmp="$(mktemp "/tmp/claude-ctx-${sid}.XXXXXX" 2>/dev/null || true)"
      if [ -n "$tmp" ]; then
        if jq -n \
          --argjson used "$used" --argjson budget "$budget" --argjson pct "$pct" \
          --arg ts "$ts_iso" --argjson epoch "$ts_epoch" \
          '{used:$used, budget:$budget, pct:$pct, used_pct:$pct,
            remaining_percentage:(100-$pct), timestamp:$ts, timestamp_epoch:$epoch}' \
          > "$tmp" 2>/dev/null; then
          mv -f "$tmp" "/tmp/claude-ctx-${sid}.json" 2>/dev/null && write_ok=1
        fi
        rm -f "$tmp" 2>/dev/null || true
      fi
      ;;
  esac
fi
: "$write_ok"  # informational only — the statusline prints either way

printf '%s · ctx %s%%\n' "$model" "$pct"
exit 0
