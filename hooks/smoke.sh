#!/usr/bin/env bash
# smoke.sh — contract smokes for every hook in this directory.
#
# For each hook, pipe in (a) a realistic sample payload, (b) empty stdin,
# (c) garbage bytes, and assert:
#   - exit code 0 (the silent-fail contract: hooks NEVER block)
#   - where output is produced, it is valid JSON (`jq empty`)
#
# Runnable standalone: `bash hooks/smoke.sh`. Dependency-light: needs jq
# (for JSON validation) and node (for the .js hooks — skipped with a notice
# when node is absent). Exits non-zero iff any assertion fails.

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
PASS=0
FAIL=0
SKIP=0

command -v jq >/dev/null 2>&1 || { echo "smoke: jq is required to run the smokes" >&2; exit 1; }

HAVE_NODE=0
command -v node >/dev/null 2>&1 && HAVE_NODE=1

# run_case <label> <stdin-mode: sample|empty|garbage> <sample-json> <cmd...>
# Pipes the chosen stdin into the hook, asserts exit 0 and (if any stdout)
# valid JSON. Hooks must not need a TTY and must return promptly.
run_case() {
  label="$1"; mode="$2"; sample="$3"; shift 3
  out=""
  rc=0
  case "$mode" in
    sample)  out="$(printf '%s' "$sample" | "$@" 2>/dev/null)" || rc=$? ;;
    empty)   out="$(printf '' | "$@" 2>/dev/null)" || rc=$? ;;
    garbage) out="$(printf '\x00\xff{{{not json\x01\n\xfe' | "$@" 2>/dev/null)" || rc=$? ;;
  esac
  if [ "$rc" -ne 0 ]; then
    echo "FAIL $label [$mode]: exit $rc (contract: always exit 0)"
    FAIL=$((FAIL+1))
    return
  fi
  if [ -n "$out" ] && ! printf '%s' "$out" | jq empty >/dev/null 2>&1; then
    echo "FAIL $label [$mode]: stdout is not valid JSON: ${out:0:120}"
    FAIL=$((FAIL+1))
    return
  fi
  PASS=$((PASS+1))
}

# run_hook <label> <sample-json> <cmd...> — all three stdin modes.
run_hook() {
  label="$1"; sample="$2"; shift 2
  run_case "$label" sample  "$sample" "$@"
  run_case "$label" empty   ""        "$@"
  run_case "$label" garbage ""        "$@"
}

# require_output <label> <stdin-json> <cmd...> — hooks that promise output on
# a realistic payload must actually produce some.
require_output() {
  label="$1"; sample="$2"; shift 2
  out="$(printf '%s' "$sample" | "$@" 2>/dev/null)" || true
  if [ -z "$out" ]; then
    echo "FAIL $label: no output on realistic payload (output expected)"
    FAIL=$((FAIL+1))
  else
    PASS=$((PASS+1))
  fi
}

# --- bash hooks --------------------------------------------------------------

# herdr-dispatch-nudge.sh: fires on every prompt, must always emit an envelope.
NUDGE_SAMPLE='{"hook_event_name":"UserPromptSubmit","session_id":"smoke","cwd":"/tmp","prompt":"hello"}'
run_hook "herdr-dispatch-nudge.sh" "$NUDGE_SAMPLE" bash "$HERE/herdr-dispatch-nudge.sh"
require_output "herdr-dispatch-nudge.sh(output)" "$NUDGE_SAMPLE" bash "$HERE/herdr-dispatch-nudge.sh"
# Hermes shape too.
require_output "herdr-dispatch-nudge.sh(hermes)" '{"hook_event_name":"pre_llm_call"}' bash "$HERE/herdr-dispatch-nudge.sh"
# Final unterminated line must not be dropped: payload without trailing newline
# already covered by printf '%s' above (no newline appended).

# m2herd-session.sh / m2herd-precompact.sh: silent (exit 0, no output) outside
# an .m2herd/ repo; inside one, must emit a valid envelope. Exercise both.
SESSION_SAMPLE='{"hook_event_name":"SessionStart","session_id":"smoke","cwd":"/tmp"}'
run_hook "m2herd-session.sh" "$SESSION_SAMPLE" bash "$HERE/m2herd-session.sh"
run_hook "m2herd-precompact.sh" "$SESSION_SAMPLE" bash "$HERE/m2herd-precompact.sh"

FABRIC_DIR="$(mktemp -d)"
trap 'rm -rf "$FABRIC_DIR"' EXIT
mkdir -p "$FABRIC_DIR/.m2herd"
printf '{"goal":"smoke goal","status":"testing","areas":["a","b"]}\n' > "$FABRIC_DIR/.m2herd/overview.json"
printf '# resume\nsmoke resume line\n' > "$FABRIC_DIR/.m2herd/RESUME.md"
require_output "m2herd-session.sh(fabric)" "$SESSION_SAMPLE" \
  env M2HERD_DIR="$FABRIC_DIR" bash "$HERE/m2herd-session.sh"
require_output "m2herd-precompact.sh(fabric)" "$SESSION_SAMPLE" \
  env M2HERD_DIR="$FABRIC_DIR" bash "$HERE/m2herd-precompact.sh"

# herdr-context-session.sh: silent outside a herd workspace; emits inside one.
run_hook "herdr-context-session.sh" "$SESSION_SAMPLE" bash "$HERE/herdr-context-session.sh"
WS_DIR="$(mktemp -d)"
trap 'rm -rf "$FABRIC_DIR" "$WS_DIR"' EXIT
printf 'MODEL="GLM-5.2"\nBUDGET="384000"\n' > "$WS_DIR/herd.conf"
require_output "herdr-context-session.sh(ws)" "$SESSION_SAMPLE" \
  env HERD_WS="$WS_DIR" bash "$HERE/herdr-context-session.sh"
# Quoted BUDGET must come out bare + numeric in the envelope.
ws_out="$(printf '%s' "$SESSION_SAMPLE" | env HERD_WS="$WS_DIR" bash "$HERE/herdr-context-session.sh" 2>/dev/null)" || true
ws_budget="$(printf '%s' "$ws_out" | jq -r '.hookSpecificOutput.budget' 2>/dev/null)"
if [ "$ws_budget" = "384000" ]; then
  PASS=$((PASS+1))
else
  echo "FAIL herdr-context-session.sh(quote-strip): budget='$ws_budget' (want 384000)"
  FAIL=$((FAIL+1))
fi

# --- ctx-bridge.sh (statusline command + bridge WRITER) -----------------------
# Not a JSON-envelope hook: stdout is a plain statusline line, so run_case's
# jq assertion doesn't apply. Assert: always exit 0; a realistic payload
# writes /tmp/claude-ctx-<sid>.json with correct pct; absent-fields and
# garbage payloads print a line but write NOTHING.
CTX_BRIDGE="$HERE/../scripts/ctx-bridge.sh"
CTX_SID="smokectx$$"
CTX_SID2="smokectx2n$$"
CTX_SID3="smokectx3b$$"
trap 'rm -rf "$FABRIC_DIR" "$WS_DIR" "$FABRIC70_DIR" /tmp/claude-ctx-smokectx*' EXIT
FABRIC70_DIR=""

ctx_case() { # ctx_case <label> <stdin-printf-arg>
  label="$1"; stdin="$2"
  out="$(printf '%b' "$stdin" | bash "$CTX_BRIDGE" 2>/dev/null)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "FAIL $label: exit $rc (contract: always exit 0)"; FAIL=$((FAIL+1)); return 1
  fi
  if [ -z "$out" ]; then
    echo "FAIL $label: no statusline output"; FAIL=$((FAIL+1)); return 1
  fi
  PASS=$((PASS+1)); return 0
}

rm -f "/tmp/claude-ctx-$CTX_SID.json" "/tmp/claude-ctx-$CTX_SID2.json"
CTX_SAMPLE="{\"session_id\":\"$CTX_SID\",\"model\":{\"display_name\":\"Smoke\"},\"context_window\":{\"used_tokens\":230400,\"max_tokens\":384000}}"
if ctx_case "ctx-bridge.sh(sample)" "$CTX_SAMPLE"; then
  bridge="/tmp/claude-ctx-$CTX_SID.json"
  if [ -f "$bridge" ] \
    && [ "$(jq -r '.pct' "$bridge" 2>/dev/null)" = "60" ] \
    && [ "$(jq -r '.used_pct' "$bridge" 2>/dev/null)" = "60" ] \
    && [ "$(jq -r '.used' "$bridge" 2>/dev/null)" = "230400" ] \
    && [ "$(jq -r '.budget' "$bridge" 2>/dev/null)" = "384000" ] \
    && jq -e '.timestamp | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T")' "$bridge" >/dev/null 2>&1; then
    PASS=$((PASS+1))
  else
    echo "FAIL ctx-bridge.sh(bridge-file): $bridge missing or wrong fields: $(cat "$bridge" 2>/dev/null | head -c 200)"
    FAIL=$((FAIL+1))
  fi
fi
# statusline pass-through: model name + ctx N%.
ctx_out="$(printf '%s' "$CTX_SAMPLE" | bash "$CTX_BRIDGE" 2>/dev/null)" || true
case "$ctx_out" in
  *Smoke*"ctx 60%"*) PASS=$((PASS+1)) ;;
  *) echo "FAIL ctx-bridge.sh(statusline): '$ctx_out' (want model + ctx 60%)"; FAIL=$((FAIL+1)) ;;
esac
# absent usage fields: prints, writes nothing.
ctx_case "ctx-bridge.sh(absent-fields)" "{\"session_id\":\"$CTX_SID2\",\"model\":{\"id\":\"m\"}}" || true
if [ -f "/tmp/claude-ctx-$CTX_SID2.json" ]; then
  echo "FAIL ctx-bridge.sh(absent-fields): wrote a bridge file without usage data"; FAIL=$((FAIL+1))
else
  PASS=$((PASS+1))
fi
# empty + garbage stdin: exit 0, no write for either.
ctx_case "ctx-bridge.sh(empty)" "" || true
ctx_case "ctx-bridge.sh(garbage)" '\x00\xff{{{not json\x01\n\xfe' || true

# --- m2herd-session.sh budget-aware branch: fake bridge at 70% ----------------
# Digest must halve the RESUME excerpt (30→15 lines) and append the context
# advisory line.
FABRIC70_DIR="$(mktemp -d)"
mkdir -p "$FABRIC70_DIR/.m2herd"
printf '{"goal":"smoke70","status":"testing","areas":[]}\n' > "$FABRIC70_DIR/.m2herd/overview.json"
{ i=1; while [ "$i" -le 40 ]; do echo "RESUMELINE$i"; i=$((i+1)); done; } > "$FABRIC70_DIR/.m2herd/RESUME.md"
printf '{"used":268800,"budget":384000,"pct":70,"used_pct":70,"remaining_percentage":30,"timestamp":"2099-01-01T00:00:00Z"}' \
  > "/tmp/claude-ctx-$CTX_SID2.json"
SESSION70="{\"hook_event_name\":\"SessionStart\",\"session_id\":\"$CTX_SID2\",\"cwd\":\"/tmp\"}"
s70_out="$(printf '%s' "$SESSION70" | env M2HERD_DIR="$FABRIC70_DIR" bash "$HERE/m2herd-session.sh" 2>/dev/null)" || true
s70_ctx="$(printf '%s' "$s70_out" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null)"
case "$s70_ctx" in
  *"context at 70% — prefer pointers over content"*) PASS=$((PASS+1)) ;;
  *) echo "FAIL m2herd-session.sh(70%-advisory): advisory line missing"; FAIL=$((FAIL+1)) ;;
esac
if printf '%s' "$s70_ctx" | grep -q 'RESUMELINE15' && ! printf '%s' "$s70_ctx" | grep -q 'RESUMELINE16'; then
  PASS=$((PASS+1))
else
  echo "FAIL m2herd-session.sh(70%-halved): RESUME excerpt not halved to 15 lines"; FAIL=$((FAIL+1))
fi
rm -f "/tmp/claude-ctx-$CTX_SID2.json"

# --- node hooks --------------------------------------------------------------

if [ "$HAVE_NODE" -eq 1 ]; then
  BUDGET_SAMPLE='{"hook_event_name":"PostToolUse","session_id":"smoke-nonexistent","cwd":"/tmp"}'
  run_hook "m2herd-budget.js" "$BUDGET_SAMPLE" node "$HERE/m2herd-budget.js"
  run_hook "herdr-context-budget.js" "$BUDGET_SAMPLE" node "$HERE/herdr-context-budget.js"

  # CRITICAL advisory (≥85%) must name the three concrete moves. Fresh
  # epoch-timestamped bridge + a fabric cwd; warn sidecar cleaned first.
  printf '{"used":334080,"budget":384000,"pct":87,"used_pct":87,"timestamp":%s}' "$(date -u +%s)" \
    > "/tmp/claude-ctx-$CTX_SID3.json"
  rm -f "/tmp/claude-ctx-$CTX_SID3-m2herd-budget.json"
  CRIT_SAMPLE="{\"hook_event_name\":\"PostToolUse\",\"session_id\":\"$CTX_SID3\",\"cwd\":\"/tmp\"}"
  crit_out="$(printf '%s' "$CRIT_SAMPLE" | env M2HERD_DIR="$FABRIC70_DIR" node "$HERE/m2herd-budget.js" 2>/dev/null)" || true
  crit_ctx="$(printf '%s' "$crit_out" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null)"
  if printf '%s' "$crit_ctx" | grep -q 'm2herd refile --area' \
    && printf '%s' "$crit_ctx" | grep -q 'm2herd archive --area' \
    && printf '%s' "$crit_ctx" | grep -q 'RESUME.md instead of retained transcript'; then
    PASS=$((PASS+1))
  else
    echo "FAIL m2herd-budget.js(critical-moves): advisory missing the three moves: ${crit_ctx:0:200}"
    FAIL=$((FAIL+1))
  fi
  rm -f "/tmp/claude-ctx-$CTX_SID3.json" "/tmp/claude-ctx-$CTX_SID3-m2herd-budget.json"
else
  echo "SKIP m2herd-budget.js + herdr-context-budget.js: node not on PATH"
  SKIP=$((SKIP+1))
fi

# --- summary -----------------------------------------------------------------

echo "smoke: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
