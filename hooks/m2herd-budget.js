#!/usr/bin/env node
// m2herd-budget.js — Claude Code PostToolUse hook (m2herd context fabric)
//
// Keeps the m2herd ORCHESTRATOR aware of its context budget. When usage
// climbs, the advisory tells it to offload working context into
// .m2herd/context/<area>/ and refresh .m2herd/RESUME.md — the folder holds
// the context, the orchestrator holds pointers. The hook itself never writes
// into the repo: offloading is the model's job, steered by the advisory.
//
// I/O contract mirrors herdr-context-budget.js exactly:
//   - stdin JSON ({session_id, cwd, ...}) with a 10s stdin timeout guard
//   - reject session_id containing path separators / traversal (/ \ ..)
//   - read the statusline bridge file /tmp/claude-ctx-<session>.json
//   - honour a stale check + a 5-tool-use debounce (severity escalation
//     bypasses the debounce)
//   - stdout {hookSpecificOutput:{hookEventName:"PostToolUse", additionalContext}}
//   - silent-fail on any error; NEVER block a tool
//
// Keyed on .m2herd/ presence ($M2HERD_DIR or cwd), NOT herd.conf. Budget
// resolution: the bridge file's own `budget` field, else default 200000
// (the Claude Code context window — m2herd is Claude-Code-native).
//
// Thresholds are on used_pct: WARNING 60, HIGH 75, CRITICAL 85.

const fs = require('fs');
const os = require('os');
const path = require('path');

const WARNING_THRESHOLD = 60;  // used_pct >= 60
const HIGH_THRESHOLD = 75;     // used_pct >= 75
const CRITICAL_THRESHOLD = 85; // used_pct >= 85
const STALE_SECONDS = 60;      // ignore metrics older than 60s
const DEBOUNCE_CALLS = 5;      // min tool uses between advisories
const DEFAULT_BUDGET = 200000; // Claude Code default context window

// Rank levels so escalation (warning -> high -> critical) can bypass debounce.
const LEVEL_RANK = { warning: 1, high: 2, critical: 3 };

let input = '';
// Timeout guard: if stdin doesn't close within 10s (slow piping on large
// tool outputs, or a wedged pipe) exit silently rather than hang until the
// Agent kills us and reports a hook error.
const stdinTimeout = setTimeout(() => process.exit(0), 10000);
process.stdin.setEncoding('utf8');
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

    // --- keyed on the m2herd context fabric: repo root holding .m2herd/ -----
    const rootDir = resolveM2herdRoot(cwd);
    if (!rootDir) process.exit(0);
    const m2Dir = path.join(rootDir, '.m2herd');

    const tmpDir = os.tmpdir();
    const metricsPath = path.join(tmpDir, `claude-ctx-${sessionId}.json`);
    // No bridge file → subagent / fresh session, nothing to measure.
    if (!fs.existsSync(metricsPath)) process.exit(0);

    const metrics = JSON.parse(fs.readFileSync(metricsPath, 'utf8'));
    const now = Math.floor(Date.now() / 1000);
    if (metrics.timestamp && (now - metrics.timestamp) > STALE_SECONDS) process.exit(0);

    // Budget fallbacks: bridge file's own budget, then the factory default.
    let budget = Number(metrics.budget) || null;
    if (!budget) budget = DEFAULT_BUDGET;

    const usedPct = Number(metrics.used_pct);
    if (!Number.isFinite(usedPct)) process.exit(0);
    const remaining = metrics.remaining_percentage;

    // Separate warn-file name from the herdr/gsd monitors' to avoid collision.
    const warnPath = path.join(tmpDir, `claude-ctx-${sessionId}-m2herd-budget.json`);

    // Below WARNING → no advisory. Reset the debounce sentinel so the next
    // upward crossing is treated as fresh.
    if (usedPct < WARNING_THRESHOLD) {
      try { if (fs.existsSync(warnPath)) fs.unlinkSync(warnPath); } catch (e) { /* ignore */ }
      process.exit(0);
    }

    let warnData = { callsSinceWarn: 0, lastLevel: null };
    let firstWarn = true;
    if (fs.existsSync(warnPath)) {
      try {
        warnData = JSON.parse(fs.readFileSync(warnPath, 'utf8'));
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

    try { fs.writeFileSync(warnPath, JSON.stringify(warnData)); } catch (e) { /* ignore */ }

    // --- build the advisory (advisory tone, never imperative) ---------------
    const estTokens = Math.round((usedPct / 100) * budget);
    const usage = `Context usage ${usedPct}% of the ~${budget}-token budget` +
      (Number.isFinite(remaining) ? ` (${remaining}% remaining)` : '') +
      ` — ~${estTokens} tokens in play.`;

    let message;
    if (currentLevel === 'critical') {
      message = `CONTEXT CRITICAL. ${usage} ` +
        `An m2herd context fabric exists at ${m2Dir}. The orchestrator should ` +
        `offload everything non-essential NOW: distil working context into ` +
        `${m2Dir}/context/<area>/context.md (deep material under context/<area>/deep/), ` +
        `refresh ${m2Dir}/RESUME.md with where the work stands and the next 3 commands, ` +
        `and keep only pointers in the live window — the folder holds the context.`;
    } else if (currentLevel === 'high') {
      message = `CONTEXT HIGH. ${usage} ` +
        `An m2herd context fabric exists at ${m2Dir}. It may help to offload ` +
        `raw history and finished threads into ${m2Dir}/context/<area>/ and refresh ` +
        `${m2Dir}/RESUME.md, keeping only pointers inline so the window stays within budget.`;
    } else {
      message = `CONTEXT WARNING. ${usage} ` +
        `Context is getting limited; it may help to lean on the m2herd fabric at ` +
        `${m2Dir} — refile notes into context/<area>/ and refresh RESUME.md rather ` +
        `than accumulating raw history — and avoid starting new unrelated work.`;
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

// Resolve the repo root holding the .m2herd/ context fabric: prefer
// $M2HERD_DIR, else cwd. Returns null when neither holds .m2herd/.
function resolveM2herdRoot(cwd) {
  const candidates = [];
  if (process.env.M2HERD_DIR) candidates.push(process.env.M2HERD_DIR);
  if (cwd) candidates.push(cwd);
  for (const c of candidates) {
    try {
      if (fs.statSync(path.join(c, '.m2herd')).isDirectory()) return c;
    } catch (e) { /* ignore */ }
  }
  return null;
}
