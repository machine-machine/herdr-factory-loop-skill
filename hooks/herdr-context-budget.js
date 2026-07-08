#!/usr/bin/env node
// herdr-context-budget.js — Hermes PostToolUse hook (context-budget layer)
//
// Keeps a herd ORCHESTRATOR aware of its context budget and, when usage
// climbs, restructures context on demand: it spills a compact pointer into
// the workspace so the orchestrator can drop raw history and reload from disk.
//
// I/O contract mirrors gsd-context-monitor.js exactly:
//   - stdin JSON ({session_id, cwd, ...}) with a 10s stdin timeout guard
//   - reject session_id containing path separators / traversal (/ \ ..)
//   - read the statusline bridge file /tmp/claude-ctx-<session>.json
//   - honour a stale check + a 5-tool-use debounce (severity escalation
//     bypasses the debounce)
//   - stdout {hookSpecificOutput:{hookEventName:"PostToolUse", additionalContext}}
//   - silent-fail on any error; NEVER block a tool
//
// Budget resolution order (for the advisory + est-tokens figure):
//   1. BUDGET= line in $HERD_WS/herd.conf (or ./herd.conf)
//   2. the bridge file's own `budget` field (if the statusline ever writes one)
//   3. default 384000  (GLM-5.2 context window — the factory default)
//
// Thresholds are on used_pct: WARNING 60, HIGH 75, CRITICAL 85.
// WARNING is advisory only. HIGH/CRITICAL additionally spill
// <ws>/_fleet/context_pointer.md (active stage + a <=10-line ledger digest +
// one link line per stages/*/context/*.md), once per threshold crossing.

const fs = require('fs');
const os = require('os');
const path = require('path');

const WARNING_THRESHOLD = 60;  // used_pct >= 60
const HIGH_THRESHOLD = 75;     // used_pct >= 75
const CRITICAL_THRESHOLD = 85; // used_pct >= 85
const STALE_SECONDS = 60;      // ignore metrics older than 60s
const DEBOUNCE_CALLS = 5;      // min tool uses between advisories
const DEFAULT_BUDGET = 384000; // GLM-5.2 default context window

// Rank levels so escalation (warning -> high -> critical) can bypass debounce.
const LEVEL_RANK = { warning: 1, high: 2, critical: 3 };

let input = '';
// Timeout guard: if stdin doesn't close within 10s (slow piping on large
// tool outputs, or a wedged pipe) exit silently rather than hang until the
// Agent kills us and reports a hook error.
const stdinTimeout = setTimeout(() => process.exit(0), 10000);
process.stdin.setEncoding('utf8');
process.stdin.on('error', () => process.exit(0));
process.stdin.on('data', chunk => input += chunk);
process.stdin.on('end', () => {
  clearTimeout(stdinTimeout);
  try {
    const data = JSON.parse(input);
    const sessionId = data.session_id;
    if (!sessionId) process.exit(0);

    // Reject session IDs with path traversal / separators — sessionId is used
    // to build /tmp paths, so an unsanitised value could escape the temp dir.
    if (/[/\\]|\.\./.test(sessionId)) process.exit(0);

    const cwd = data.cwd || process.cwd();

    // --- resolve the workspace (dir holding herd.conf) + its BUDGET ---------
    const wsDir = resolveWorkspace(cwd);
    let budget = wsDir ? readConfBudget(path.join(wsDir, 'herd.conf')) : null;

    // The statusline writer uses literal /tmp (see contract + context-budget.sh);
    // os.tmpdir() is $TMPDIR (/var/folders/…) on macOS, so check /tmp FIRST and
    // keep os.tmpdir() as the fallback.
    const candidates = [
      path.join('/tmp', `claude-ctx-${sessionId}.json`),
      path.join(os.tmpdir(), `claude-ctx-${sessionId}.json`)
    ];
    const metricsPath = candidates.find(p => { try { return fs.existsSync(p); } catch (e) { return false; } });
    // No bridge file → subagent / fresh session, nothing to measure.
    if (!metricsPath) process.exit(0);
    // Keep the warn/debounce file next to the bridge that was actually found,
    // so debounce state stays consistent when /tmp and os.tmpdir() differ.
    const tmpDir = path.dirname(metricsPath);

    const metrics = JSON.parse(fs.readFileSync(metricsPath, 'utf8'));
    const now = Math.floor(Date.now() / 1000);
    // Timestamp tolerance (ctx-bridge.sh writes both shapes): numeric epoch
    // `timestamp`, else numeric `timestamp_epoch`, else ISO-8601 `timestamp`.
    // A bridge with none of those is unverifiable → treat as stale.
    let ts = Number(metrics.timestamp);
    if (!Number.isFinite(ts)) ts = Number(metrics.timestamp_epoch);
    if (!Number.isFinite(ts)) {
      const parsed = Date.parse(metrics.timestamp);
      if (Number.isFinite(parsed)) ts = Math.floor(parsed / 1000);
    }
    if (!Number.isFinite(ts) || (now - ts) > STALE_SECONDS) process.exit(0);

    // Budget fallbacks: bridge file's own budget, then the factory default.
    if (!budget) budget = Number(metrics.budget) || null;
    if (!budget) budget = DEFAULT_BUDGET;

    // used_pct is the canonical key; `pct` is the ctx-bridge contract alias.
    const usedPct = Number(metrics.used_pct !== undefined ? metrics.used_pct : metrics.pct);
    if (!Number.isFinite(usedPct)) process.exit(0);
    const remaining = metrics.remaining_percentage;

    // Separate warn-file name from gsd-context-monitor's to avoid collision.
    const warnPath = path.join(tmpDir, `claude-ctx-${sessionId}-herdr-budget.json`);

    // Below WARNING → no advisory. Reset the debounce/spill sentinel so the
    // next upward crossing is treated as fresh.
    if (usedPct < WARNING_THRESHOLD) {
      try { if (fs.existsSync(warnPath)) fs.unlinkSync(warnPath); } catch (e) { /* ignore */ }
      process.exit(0);
    }

    let warnData = { callsSinceWarn: 0, lastLevel: null, spilled: {} };
    let firstWarn = true;
    if (fs.existsSync(warnPath)) {
      try {
        warnData = JSON.parse(fs.readFileSync(warnPath, 'utf8'));
        if (!warnData.spilled) warnData.spilled = {};
        firstWarn = false;
      } catch (e) { /* corrupted → reset */ }
    }

    warnData.callsSinceWarn = (warnData.callsSinceWarn || 0) + 1;

    const currentLevel =
      usedPct >= CRITICAL_THRESHOLD ? 'critical'
      : usedPct >= HIGH_THRESHOLD ? 'high'
      : 'warning';

    // Severity escalation (rising level) bypasses the debounce.
    const severityEscalated =
      LEVEL_RANK[currentLevel] > (LEVEL_RANK[warnData.lastLevel] || 0);

    if (!firstWarn && warnData.callsSinceWarn < DEBOUNCE_CALLS && !severityEscalated) {
      try { fs.writeFileSync(warnPath, JSON.stringify(warnData)); } catch (e) { /* ignore */ }
      process.exit(0);
    }

    warnData.callsSinceWarn = 0;
    warnData.lastLevel = currentLevel;

    // --- restructure on demand: HIGH/CRITICAL spill, once per crossing ------
    let pointerPath = null;
    const isHighOrCritical = currentLevel === 'high' || currentLevel === 'critical';
    if (isHighOrCritical && wsDir && !warnData.spilled[currentLevel]) {
      pointerPath = spillPointer(wsDir);
      if (pointerPath) warnData.spilled[currentLevel] = true;
      // At CRITICAL, additionally raise the rotation signal — the loop yields on it
      // (STATUS: NEEDS_ROTATION) so the session can reboot from the pointer. Guarded by
      // the same per-level `spilled` sentinel, so it fires once per crossing. Silent-fail.
      if (currentLevel === 'critical') {
        try {
          const fleetDir = path.join(wsDir, '_fleet');
          fs.mkdirSync(fleetDir, { recursive: true });
          fs.writeFileSync(path.join(fleetDir, '.needs_rotation'), `critical ${usedPct}%\n`);
        } catch (e) { /* ignore */ }
      }
    } else if (isHighOrCritical && wsDir && warnData.spilled[currentLevel]) {
      // Already spilled for this level this crossing — reference the existing file.
      const existing = path.join(wsDir, '_fleet', 'context_pointer.md');
      if (fs.existsSync(existing)) pointerPath = existing;
    }

    try { fs.writeFileSync(warnPath, JSON.stringify(warnData)); } catch (e) { /* ignore */ }

    // --- build the advisory (advisory tone, never imperative) ---------------
    const estTokens = Math.round((usedPct / 100) * budget);
    const usage = `Context usage ${usedPct}% of the ~${budget}-token budget` +
      (Number.isFinite(remaining) ? ` (${remaining}% remaining)` : '') +
      ` — ~${estTokens} tokens in play.`;

    let message;
    if (currentLevel === 'critical') {
      message = `CONTEXT CRITICAL. ${usage} ` +
        'The orchestrator may drop raw worker history and reload from the spilled pointer' +
        (pointerPath ? ` at ${pointerPath}` : '') +
        '; consider re-pointing subsequent worker prompts at each slice context.md rather ' +
        'than carrying the full history inline.';
    } else if (currentLevel === 'high') {
      message = `CONTEXT HIGH. ${usage} ` +
        'A context pointer has been spilled' +
        (pointerPath ? ` to ${pointerPath}` : '') +
        '; the orchestrator may offload raw history to disk and reload working context ' +
        'from the pointer / slice context.md links to stay within budget.';
    } else {
      message = `CONTEXT WARNING. ${usage} ` +
        'Context is getting limited; it may help to lean on the workspace file links ' +
        '(slice context.md) rather than accumulating raw history, and avoid starting new ' +
        'unrelated work.';
    }

    const output = {
      hookSpecificOutput: {
        hookEventName: 'PostToolUse',
        additionalContext: message
      }
    };
    process.stdout.write(JSON.stringify(output));
  } catch (e) {
    // Silent fail — never block tool execution.
    process.exit(0);
  }
});

// Resolve the workspace directory: prefer $HERD_WS, else cwd — whichever holds
// a herd.conf. Returns null when neither does.
function resolveWorkspace(cwd) {
  const candidates = [];
  if (process.env.HERD_WS) candidates.push(process.env.HERD_WS);
  if (cwd) candidates.push(cwd);
  for (const c of candidates) {
    try {
      if (fs.existsSync(path.join(c, 'herd.conf'))) return c;
    } catch (e) { /* ignore */ }
  }
  return null;
}

// Read the BUDGET= line from a herd.conf. Returns a positive number or null.
function readConfBudget(confPath) {
  try {
    const txt = fs.readFileSync(confPath, 'utf8');
    const m = txt.match(/^BUDGET=(.*)$/m);
    if (m) {
      const n = Number(String(m[1]).trim());
      if (Number.isFinite(n) && n > 0) return n;
    }
  } catch (e) { /* ignore */ }
  return null;
}

// Spill a compact context pointer into <ws>/_fleet/context_pointer.md:
//   - the active stage (_fleet/active_stage)
//   - a <=10-line digest of the ledger (_fleet/ledger.tsv)
//   - one link line per stages/*/context/*.md found
// Never inlines file bodies — links only. Returns the written path or null.
function spillPointer(wsDir) {
  try {
    const fleetDir = path.join(wsDir, '_fleet');
    fs.mkdirSync(fleetDir, { recursive: true });

    let activeStage = 'unknown';
    try {
      activeStage = fs.readFileSync(path.join(fleetDir, 'active_stage'), 'utf8').trim() || 'unknown';
    } catch (e) { /* ignore */ }

    const lines = [];
    lines.push('# context_pointer.md — spilled by herdr-context-budget hook');
    lines.push('');
    lines.push('Drop raw history and reload working context from the links below.');
    lines.push('');
    lines.push(`active_stage: ${activeStage}`);
    lines.push('');

    // Ledger digest — at most 10 lines (header + first rows).
    lines.push('## ledger digest');
    try {
      const ledger = fs.readFileSync(path.join(fleetDir, 'ledger.tsv'), 'utf8')
        .split('\n').filter(l => l.length > 0).slice(0, 10);
      if (ledger.length) {
        lines.push('```');
        for (const l of ledger) lines.push(l);
        lines.push('```');
      } else {
        lines.push('(empty)');
      }
    } catch (e) {
      lines.push('(no ledger)');
    }
    lines.push('');

    // Link line per stages/*/context/*.md — links only, never file bodies.
    lines.push('## slice context manifests');
    const links = [];
    try {
      const stagesDir = path.join(wsDir, 'stages');
      for (const stage of fs.readdirSync(stagesDir).sort()) {
        const ctxDir = path.join(stagesDir, stage, 'context');
        let entries;
        try { entries = fs.readdirSync(ctxDir); } catch (e) { continue; }
        for (const f of entries.sort()) {
          if (f.endsWith('.md')) {
            links.push(`- [${stage}/${f}](stages/${stage}/context/${f})`);
          }
        }
      }
    } catch (e) { /* stages/ may not exist */ }
    if (links.length) lines.push(...links);
    else lines.push('(none found)');
    lines.push('');

    const pointerPath = path.join(fleetDir, 'context_pointer.md');
    fs.writeFileSync(pointerPath, lines.join('\n'));
    return pointerPath;
  } catch (e) {
    return null;
  }
}
