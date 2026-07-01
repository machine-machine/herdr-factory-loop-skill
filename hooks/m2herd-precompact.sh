#!/usr/bin/env bash
# m2herd-precompact.sh — Claude Code PreCompact hook (m2herd context fabric)
#
# Just before compaction inside a repo that carries an .m2herd/ context fabric
# (cwd or $M2HERD_DIR holds .m2herd/), inject an instruction as
# additionalContext: refresh RESUME.md + overview.json and refile loose
# NOTES.md content into context/<area>/ BEFORE compaction proceeds — so the
# state that survives compaction lives on disk, not in the window about to be
# summarized.
#
# Pure bash + jq. Same envelope shape as m2herd-session.sh but with
# hookEventName "PreCompact". Silent-fail: any problem exits 0 with no output;
# this hook never blocks compaction.

set -u

# Read the (unused but contract-consistent) stdin JSON without hanging: a timed
# read loop, so a host that never closes stdin costs at most 5s per silent read —
# a $(cat) form would block forever because cat runs before any timeout applies.
_stdin=""
while IFS= read -r -t 5 _line 2>/dev/null; do _stdin="${_stdin}${_line}"; done || true

# jq is required for safe JSON encoding; without it, stay silent.
command -v jq >/dev/null 2>&1 || exit 0

# Resolve the repo root: prefer $M2HERD_DIR, else cwd — whichever holds .m2herd/.
ROOT=""
if [ -n "${M2HERD_DIR:-}" ] && [ -d "${M2HERD_DIR}/.m2herd" ]; then
  ROOT="${M2HERD_DIR}"
elif [ -d "./.m2herd" ]; then
  ROOT="$(pwd)"
fi

# No context fabric → nothing to say.
[ -n "$ROOT" ] || exit 0

M2="${ROOT}/.m2herd"

# Drift probe (contract amendment v1.1): if the m2herd engine is on PATH, run
# a bounded `m2herd sync --check`; exit 3 means overview.json and the context/
# tree disagree. Degrade silently when the binary is absent, hangs (killed at
# ~3s), or exits 0/other — the probe must never delay or block compaction.
DRIFT=""
if command -v m2herd >/dev/null 2>&1; then
  _rc=0
  if command -v timeout >/dev/null 2>&1; then
    timeout 3 m2herd sync --check --dir "$ROOT" >/dev/null 2>&1 || _rc=$?
  else
    m2herd sync --check --dir "$ROOT" >/dev/null 2>&1 & _pid=$!
    ( sleep 3; kill "$_pid" 2>/dev/null ) & _watch=$!
    wait "$_pid" 2>/dev/null; _rc=$?
    kill "$_watch" 2>/dev/null; wait "$_watch" 2>/dev/null || true
  fi
  if [ "$_rc" -eq 3 ]; then
    DRIFT=" context drift detected — run \`m2herd sync\` to reconcile overview.json with the context/ tree."
  fi
fi

MSG="Compaction is about to run and an m2herd context fabric exists at ${M2}. \
BEFORE relying on the compacted summary, persist state to disk NOW: \
(1) refresh ${M2}/RESUME.md — where the work stands, in-flight items, and the next 3 commands; \
(2) rewrite ${M2}/overview.json with jq (updated_at, areas[], workers[] states) — whole-file rewrite, no sed patching; \
(3) refile loose ${M2}/NOTES.md content into ${M2}/context/<area>/ (e.g. via 'm2herd.sh refile --area <A>'). \
Anything not offloaded into .m2herd/ may be lost in compaction.${DRIFT}"

# Emit the structured envelope.
jq -cn \
  --arg ctx "$MSG" \
  '{
    hookSpecificOutput: {
      hookEventName: "PreCompact",
      additionalContext: $ctx
    }
  }'

exit 0
