// Offline test for templates/herd/workflows/*.js (docs/herd-flow-v2.md §5).
// Runs the Workflow-tool scripts under stub globals. Agents that run a script built by the workflow
// (start/pin/record) really execute it with bash against throwaway git repos and the real
// scripts/herd-phase, so the exact commands and transitions are tested end to end. Review, skeptic,
// probe and fixer agents return canned results per scenario.
// Usage: node tests/workflows/run.mjs [--help] [-v]
import { execFileSync } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

if (process.argv.includes('--help') || process.argv.includes('-h')) {
  console.log('usage: node tests/workflows/run.mjs [-v]\n  offline test of review-fix-loop.js + review-open-prs.js with stubbed agents; temp dirs only')
  process.exit(0)
}
const VERBOSE = process.argv.includes('-v')
const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..')
const WF = path.join(ROOT, 'templates/herd/workflows')
const LOOP = path.join(WF, 'review-fix-loop.js')
const REVIEW = path.join(WF, 'review-open-prs.js')
const TMP = fs.mkdtempSync(path.join(process.env.TMPDIR || os.tmpdir(), 'wf-test-'))
const BIN = path.join(TMP, 'bin')
fs.mkdirSync(BIN)
for (const tool of ['herdr', 'gh', 'lage']) {
  fs.writeFileSync(path.join(BIN, tool), `#!/usr/bin/env bash\necho "stub ${tool} must not be called: $*" >&2\nexit 97\n`, { mode: 0o755 })
}
const ENV = { ...process.env, PATH: `${BIN}:${path.join(ROOT, 'scripts')}:${process.env.PATH}`, GIT_CONFIG_NOSYSTEM: '1', HOME: TMP,
  GIT_AUTHOR_NAME: 't', GIT_AUTHOR_EMAIL: 't@t', GIT_COMMITTER_NAME: 't', GIT_COMMITTER_EMAIL: 't@t' }
// a git without ~/.gitconfig still needs these for worktree/range-diff
const sh = (cmd, cwd) => execFileSync('bash', ['-c', cmd], { cwd: cwd || TMP, env: ENV, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] })

let pass = 0, fail = 0
function ok(cond, msg) { if (cond) { pass++; if (VERBOSE) console.log('  ok  ' + msg) } else { fail++; console.log('  FAIL ' + msg) } }

// ---------- static checks ----------
function staticChecks(file) {
  const src = fs.readFileSync(file, 'utf8')
  const name = path.basename(file)
  ok(src.startsWith('export const meta = {'), `${name}: begins with export const meta`)
  const end = src.indexOf('\n}\n')
  const lit = src.slice('export const meta = '.length, end + 2)
  ok(!/\$\{|\.\.\.|=>|\bfunction\b/.test(lit), `${name}: meta has no interpolation/spread/function`)
  ok(!/[A-Za-z_]\s*\(/.test(lit.replace(/'(?:[^'\\]|\\.)*'/g, "''")), `${name}: meta has no calls`)
  let meta = null
  try { meta = new Function(`"use strict"; return (${lit})`)() } catch (e) { /* reported below */ }
  ok(meta && meta.name && meta.description, `${name}: meta evaluates to a literal with name + description`)
  const code = src.replace(/'(?:[^'\\\n]|\\.)*'/g, "''")
  ok(!/Date\.now|Math\.random|new Date\s*\(|\brequire\s*\(|\bimport\s|\bprocess\.|\bfs\./.test(code.slice(end)), `${name}: no Date.now/Math.random/new Date/require/import/process/fs`)
  // generic leftovers of the per-herd copies; a team adds its own words via HERD_LEAK_WORDS="a,b"
  const local = (process.env.HERD_LEAK_WORDS || '').split(',').map(w => w.trim()).filter(Boolean)
  for (const bad of ['/workspace', 'setup-wt', '#202', '#205', "'<branch>'", 'herde-2', ...local]) {
    ok(!src.includes(bad), `${name}: no hard-coded ${bad}`)
  }
  return meta
}

// ---------- stub runtime ----------
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor
function compile(file) {
  const body = fs.readFileSync(file, 'utf8').replace(/^export const meta =/, 'const meta =')
  return new AsyncFunction('agent', 'parallel', 'pipeline', 'phase', 'log', 'workflow', 'args', 'budget', body)
}
function runtime(handler) {
  const calls = []
  const logs = []
  const agent = async (prompt, opts = {}) => { calls.push({ prompt, ...opts }); return handler(prompt, opts, calls) }
  const parallel = thunks => Promise.all(thunks.map(t => Promise.resolve().then(t).catch(e => { logs.push('THROW ' + e.stack); return null })))
  const pipeline = (items, ...stages) => Promise.all(items.map((it, i) => stages.reduce((p, st) => p.then(prev => st(prev, it, i)), Promise.resolve(undefined)).catch(() => null)))
  const log = m => { logs.push(m); if (VERBOSE) console.log('    log: ' + m) }
  const phase = () => {}
  const budget = { total: null, spent: () => 0, remaining: () => Infinity }
  let depth = 0
  const workflow = async (ref, a) => {
    if (depth) throw new Error('nested workflow()')
    depth++
    try { return await compile(ref.scriptPath)(agent, parallel, pipeline, phase, log, null, a, budget) } finally { depth-- }
  }
  return { calls, logs, run: (file, a) => compile(file)(agent, parallel, pipeline, phase, log, workflow, a, budget) }
}
function bash(prompt) {
  const script = prompt.slice(prompt.indexOf('\n\n') + 2)
  try { return { exit_code: 0, stdout: sh(script) } } catch (e) { return { exit_code: e.status || 1, stdout: String(e.stdout || '') + String(e.stderr || '') } }
}

// ---------- fixture: origin with PR refs, worker worktrees, herd dir ----------
function repoFixture(name) {
  const origin = path.join(TMP, `${name}.git`)
  const src = path.join(TMP, 'src', name)
  sh(`git init -q --bare -b main ${origin} && git clone -q ${origin} ${src} 2>/dev/null; cd ${src} && git checkout -q -b main 2>/dev/null || true
      echo base > a.txt && git add a.txt && git commit -qm base && git push -q origin main`)
  return { origin, src }
}
function prBranch(fx, branch, n, file, content, wtName) {
  const wt = path.join(TMP, 'wt', path.basename(fx.src), wtName)
  sh(`git -C ${fx.src} worktree add -q -b ${branch} ${wt} origin/main && cd ${wt} && mkdir -p $(dirname ${file}) && echo ${content} > ${file} && git add -A && git commit -qm ${branch} && git push -q origin HEAD:${branch} HEAD:refs/pull/${n}/head`)
  return { wt, sha: sh(`git -C ${wt} rev-parse HEAD`).trim() }
}
function pushMore(fx, w, n, branch, file, content) {
  sh(`cd ${w.wt} && echo ${content} >> ${file} && git commit -qam more && git push -q origin HEAD:${branch} HEAD:refs/pull/${n}/head`)
  return sh(`git -C ${w.wt} rev-parse HEAD`).trim()
}
const hp = (herd, a) => sh(`herd-phase ${herd} ${a}`)
const events = herd => fs.readFileSync(path.join(herd, 'herd.events.jsonl'), 'utf8').trim().split('\n').map(l => JSON.parse(l))
const lastOf = (herd, s) => events(herd).filter(e => e.slice === s).pop()

const CLEAN = { summary: 'fine', tests: '3 passed', description_ok: true, findings: [] }
const LOWONLY = { summary: 'one nit', tests: '3 passed', description_ok: true, findings: [{ severity: 'low', title: 'typo in label', file: 'b.txt', line: 1, description: 'label says Revire', repro: 'open b.txt' }] }
const MEDIUM = { summary: 'one bug', tests: '3 passed, 1 failed', description_ok: true, findings: [{ severity: 'medium', title: 'off by one in range', file: 'migrations/001.sql', line: 4, description: 'last row dropped', repro: 'run with 3 rows -> 2' }] }
function integ(mainSha, repo, mine) { return { repo, main_sha: mainSha, order: mine, conflicts_main: [], conflicts_predecessor: [], predecessor_problems: [], baseline_result: '10 passed', candidate_result: '12 passed', new_failures: [] } }

function handlerFor(sc) {
  return (prompt, opts) => {
    const l = opts.label || ''
    if (l.startsWith('start:') || l.startsWith('pin:') || l.startsWith('record:')) {
      const r = bash(prompt)
      if (VERBOSE && r.exit_code) console.log(`    ${l} exit ${r.exit_code}: ${r.stdout}`)
      return r
    }
    if (l.startsWith('review:')) return sc.review(l, opts)
    if (l.startsWith('verify:')) return sc.verify ? sc.verify(l, opts) : { refuted: true, reason: 'not reproducible', severity_corrected: 'none' }
    if (l.startsWith('integrate:')) return sc.integrate(l, opts, prompt)
    if (l.startsWith('fix:')) return sc.fix(l, opts)
    throw new Error('unexpected agent ' + l)
  }
}

// ---------- scenarios ----------
async function main() {
  console.log(`workflow tests in ${TMP}`)
  const metaLoop = staticChecks(LOOP)
  const metaRev = staticChecks(REVIEW)
  ok(metaLoop && metaLoop.phases.map(p => p.title).join() === 'Start,Review,Fix,Record', 'loop meta phases')
  ok(metaRev && metaRev.phases.map(p => p.title).join() === 'Pin,Review,Verify,Integrate', 'review meta phases')
  for (const f of [LOOP, REVIEW]) {
    let err = null
    try { compile(f) } catch (e) { err = e }
    ok(!err, `${path.basename(f)} compiles as async body${err ? ': ' + err.message : ''}`)
  }

  const api = repoFixture('api')
  const ui = repoFixture('ui')
  const apiMain = sh(`git -C ${api.src} rev-parse origin/main`).trim()
  const uiMain = sh(`git -C ${ui.src} rev-parse origin/main`).trim()
  const SETUP = { 'org/api': 'echo "$HERD_REPO $HERD_SLICE $HERD_SHA" > .setup-ran' }
  const base = (herd, groups, extra) => ({ herd, reviewScript: REVIEW, groups, setup: SETUP, tests: { 'org/api': 'true', ui: 'true' }, run_id: 'r1', ...extra })

  // --- 1. clean package (api + ui, two slices), lows go to NACH-MERGE, pinned to the ACCEPTED sha ---
  {
    const herd = path.join(TMP, 'herd1')
    const a = prBranch(api, 'feat/reviere', 10, 'b.txt', 'x', 'reviere')
    const u = prBranch(ui, 'feat/reviere-ui', 4, 'c.txt', 'y', 'reviere-ui')
    hp(herd, 'reviere working')
    hp(herd, `reviere accepted --field prs='["api#10@${a.sha.slice(0, 7)}"]'`)
    hp(herd, 'reviere-ui working')
    hp(herd, `reviere-ui accepted --field prs='["org/ui#4@${u.sha.slice(0, 7)}"]'`)
    const moved = pushMore(api, a, 10, 'feat/reviere', 'b.txt', 'later')   // head moves after acceptance
    const groups = [{ name: 'reviere', slices: ['reviere', 'reviere-ui'], prs: [
      { repo: 'org/api', short: 'api', n: 10, head: 'feat/reviere', base: 'origin/main', wt: a.wt, worker_model: 'claude-opus-5-5' },
      { repo: 'org/ui', short: 'ui', n: 4, head: 'feat/reviere-ui', base: 'main', wt: u.wt, worker_model: 'claude-fable-5-1' }] }]
    const rt = runtime(handlerFor({
      review: l => l.endsWith('api#10') ? LOWONLY : CLEAN,
      // the probe agent types repo freely ('api', not 'org/api'); main must still be keyed by the known repo
      integrate: (l, o, p) => l.endsWith(':api') ? integ(apiMain, 'api', ['api#10']) : integ(uiMain, 'UI', ['ui#4']),
    }))
    const res = await rt.run(LOOP, base(herd, groups))
    const r = res.results[0]
    ok(r.outcome === 'review_ok', `clean: outcome review_ok (got ${r.outcome} ${r.error || ''})`)
    const ea = lastOf(herd, 'reviere'), eu = lastOf(herd, 'reviere-ui')
    ok(ea.phase === 'review_ok' && eu.phase === 'review_ok', 'clean: both slices review_ok in herd.events.jsonl')
    ok(JSON.stringify(ea.prs) === JSON.stringify([`api#10@${a.sha}`]), 'clean: api pinned to the accepted sha40, not the moved head')
    ok(moved !== a.sha && JSON.stringify(eu.prs) === JSON.stringify([`ui#4@${u.sha}`]), 'clean: ui pinned to accepted sha40')
    ok(JSON.stringify(ea.main) === JSON.stringify([`api@${apiMain}`]) && JSON.stringify(eu.main) === JSON.stringify([`ui@${uiMain}`]), 'clean: main shas per repo recorded')
    ok(ea.run_id === 'r1' && ea.by === 'loop', 'clean: run_id + by=loop')
    ok(ea.lows.length === 1 && /typo in label/.test(ea.lows[0]) && eu.lows.length === 0, 'clean: lows listed in review_ok.lows')
    const nm = fs.readFileSync(path.join(herd, 'NACH-MERGE.md'), 'utf8')
    ok(/## reviere — review r1/.test(nm) && /\[low\] api#10: typo in label/.test(nm), 'clean: low appended to NACH-MERGE.md')
    const hist = events(herd).filter(e => e.slice === 'reviere').map(e => e.phase).join(',')
    ok(hist === 'working,accepted,review_running,review_ok', `clean: transitions ${hist}`)
    const rv = `${a.wt}--review`
    ok(fs.existsSync(rv) && sh(`git -C ${rv} rev-parse HEAD`).trim() === a.sha, 'clean: <slice>--review worktree exists at the accepted sha')
    ok(fs.readFileSync(path.join(rv, '.setup-ran'), 'utf8').trim() === `org/api reviere ${a.sha}`, 'clean: setup ran in the review worktree with HERD_* env')
    ok(!fs.existsSync(path.join(`${u.wt}--review`, '.setup-ran')), 'clean: no setup for a repo without a setup command')
    ok(sh(`git -C ${a.wt} rev-parse HEAD`).trim() === moved, 'clean: worker worktree untouched')
    const rev = rt.calls.filter(c => (c.label || '').startsWith('review:'))
    const rApi = rev.find(c => c.label.endsWith('api#10')), rUi = rev.find(c => c.label.endsWith('ui#4'))
    ok(rApi.model === 'claude-fable-5-1' && rUi.model === 'claude-opus-5-5', 'clean: main reviewer = the other model than the worker')
    ok(rApi.effort === 'high', 'clean: reviewer effort high on a non-hot change')
    ok(rApi.prompt.includes(`${a.wt}--review`) && rApi.prompt.includes(a.sha), 'clean: reviewer prompt names the review worktree + pinned sha')
    const ints = rt.calls.filter(c => (c.label || '').startsWith('integrate:'))
    ok(ints.length === 2 && ints.every(c => c.effort === 'xhigh' && c.model === 'claude-opus-5-5'), 'clean: one integration probe per repo, opus xhigh')
    ok(ints.every(c => c.prompt.includes('refs/remotes/origin/main')), 'clean: probe merges onto current main')
    ok(rt.calls.filter(c => (c.label || '').startsWith('verify:')).length === 0, 'clean: low findings get no skeptics')
    ok(rt.calls.every(c => c.model), 'clean: every agent has an explicit model')
    ok(rt.logs.some(m => /head moved after acceptance/.test(m)), 'clean: moved head is logged')
  }

  // --- 2. finding path: medium on a hot file survives 1:1 -> review_befund + fix_queued + befunde file ---
  {
    const herd = path.join(TMP, 'herd2')
    const a = prBranch(api, 'fix/kollision', 20, 'migrations/001.sql', 'z', 'kollision')
    hp(herd, 'kollision working')
    hp(herd, `kollision accepted --field prs='["api#20@${a.sha.slice(0, 7)}"]'`)
    const groups = [
      { name: 'first', slices: ['first'], prs: [{ repo: 'org/api', short: 'api', n: 10, head: 'feat/reviere', base: 'main', wt: path.join(TMP, 'wt/api/reviere'), worker_model: 'claude-opus-5-5' }] },
      { name: 'kollision', slices: ['kollision'], prs: [{ repo: 'org/api', short: 'api', n: 20, head: 'fix/kollision', base: 'main', wt: a.wt, worker_model: 'claude-fable-5-1' }] }]
    const rt = runtime(handlerFor({
      review: () => MEDIUM,
      verify: (l, o) => o.model === 'claude-opus-5-5' ? { refuted: false, reason: 'reproduced: 3 rows -> 2', severity_corrected: 'medium' } : { refuted: true, reason: 'could not reproduce', severity_corrected: 'none' },
      integrate: () => integ(apiMain, 'org/api', ['api#10', 'api#20']),
    }))
    const res = await rt.run(LOOP, base(herd, groups, { review: ['kollision'] }))
    const r = res.results[0]
    ok(res.results.length === 1 && r.outcome === 'review_befund', `finding: outcome review_befund (got ${r.outcome} ${r.error || ''})`)
    const evs = events(herd).filter(e => e.slice === 'kollision')
    ok(evs.map(e => e.phase).join() === 'working,accepted,review_running,review_befund,fix_queued', 'finding: review_befund then fix_queued')
    const bf = path.join(herd, `kollision.befunde-${a.sha.slice(0, 7)}.md`)
    ok(evs[3].befunde_file === bf && evs[4].befunde_file === bf && JSON.stringify(evs[3].prs) === JSON.stringify([`api#20@${a.sha}`]), 'finding: befunde_file + prs on the events')
    const txt = fs.existsSync(bf) ? fs.readFileSync(bf, 'utf8') : ''
    ok(/off by one in range/.test(txt) && /migrations\/001\.sql:4/.test(txt) && /reproduced: 3 rows/.test(txt) && /--resume/.test(txt), 'finding: befunde file has finding, file:line, skeptic reasons, resume hint')
    ok(!fs.existsSync(path.join(herd, 'NACH-MERGE.md')), 'finding: nothing appended to NACH-MERGE.md')
    const rv = rt.calls.find(c => (c.label || '').startsWith('review:'))
    ok(rv.model === 'claude-opus-5-5' && rv.effort === 'xhigh', 'finding: fable worker -> opus reviewer, xhigh on a migration')
    const sk = rt.calls.filter(c => (c.label || '').startsWith('verify:'))
    ok(sk.length === 2 && sk.map(c => c.model).sort().join() === 'claude-fable-5-1,claude-opus-5-5' && sk.every(c => c.effort === 'medium'), 'finding: skeptics one opus + one fable, medium')
    ok(rt.calls.filter(c => (c.label || '').startsWith('fix:')).length === 0, 'finding: fixBy=worker spawns no fixer')
    const ip = rt.calls.find(c => (c.label || '').startsWith('integrate:')).prompt
    ok(/earlier packages before it: api#10 \(first/.test(ip), 'finding: probe baseline = earlier package in planned order')
    ok(!lastOf(herd, 'first'), 'finding: groups not selected by args.review get no events')
  }

  // --- 3. refuse: a slice still working -> not_started, nothing written ---
  {
    const herd = path.join(TMP, 'herd3')
    hp(herd, 'busy working')
    const before = events(herd).length
    const rt = runtime(handlerFor({ review: () => CLEAN, integrate: () => integ(apiMain, 'org/api', []) }))
    const res = await rt.run(LOOP, base(herd, [{ name: 'busy', slices: ['busy'], prs: [{ repo: 'org/api', short: 'api', n: 10, head: 'feat/reviere', base: 'main', wt: path.join(TMP, 'wt/api/reviere'), worker_model: 'claude-opus-5-5' }] }]))
    ok(res.results[0].outcome === 'not_started' && /busy=working/.test(res.results[0].error), 'refuse: working slice is not started')
    ok(events(herd).length === before && rt.calls.length === 1, 'refuse: no event written, no review agents')
  }

  // --- 4. fixer mode: finding, fixer pushes, round 2 clean -> review_ok at the new head ---
  {
    const herd = path.join(TMP, 'herd4')
    const a = prBranch(api, 'feat/fixme', 30, 'd.txt', 'q', 'fixme')
    hp(herd, 'fixme working')
    hp(herd, `fixme accepted --field prs='["api#30@${a.sha.slice(0, 7)}"]'`)
    let newHead = null, round = 0
    const rt = runtime(handlerFor({
      review: () => (++round === 1 ? { ...MEDIUM, findings: [{ ...MEDIUM.findings[0], file: 'd.txt' }] } : CLEAN),
      verify: () => ({ refuted: false, reason: 'yes', severity_corrected: 'high' }),
      integrate: () => integ(apiMain, 'org/api', ['api#30']),
      fix: () => { newHead = pushMore(api, a, 30, 'feat/fixme', 'd.txt', 'fixed'); return { fixed: ['off by one in range'], not_fixed: [], commits: [`api#30 ${newHead.slice(0, 7)}`], tests: '1 passed' } },
    }))
    const res = await rt.run(LOOP, base(herd, [{ name: 'fixme', slices: ['fixme'], prs: [{ repo: 'org/api', short: 'api', n: 30, head: 'feat/fixme', base: 'main', wt: a.wt, worker_model: 'claude-opus-5-5' }] }], { fixBy: 'fixer', git: { name: 'Bot', email: 'b@x', coauthor: 'Co-Authored-By: X <x@y>' } }))
    const r = res.results[0]
    ok(r.outcome === 'review_ok' && r.rounds === 2, `fixer: clean after round 2 (got ${r.outcome} r${r.rounds})`)
    const e = lastOf(herd, 'fixme')
    ok(e.phase === 'review_ok' && JSON.stringify(e.prs) === JSON.stringify([`api#30@${newHead}`]), 'fixer: review_ok records the fixer\'s new head')
    const fx = rt.calls.filter(c => (c.label || '').startsWith('fix:'))
    ok(fx.length === 1 && fx[0].model === 'claude-opus-5-5' && fx[0].effort === 'high', 'fixer: one fixer, same model as the worker')
    ok(fx[0].prompt.includes(`merge --ff-only origin/feat/fixme`) && fx[0].prompt.includes('push origin HEAD:feat/fixme') && !fx[0].prompt.includes('<branch>'), 'fixer: real branch names in sync/push commands')
    ok(fx[0].prompt.includes("-c user.name='Bot'") && fx[0].prompt.includes('Co-Authored-By: X'), 'fixer: git identity from args')
    ok(rt.calls.filter(c => (c.label || '').startsWith('integrate:')).length === 2, 'fixer: probe runs every round')
    ok(events(herd).filter(x => x.slice === 'fixme' && x.phase === 'review_running').length === 1, 'fixer: review_running written once')
  }

  // --- 5. stale delta: review_ok, main moved, PR unchanged -> probe only, no reviewer ---
  {
    const herd = path.join(TMP, 'herd5')
    const a = prBranch(api, 'feat/stale', 40, 'e.txt', 's', 'stale')
    hp(herd, 'stale working')
    hp(herd, `stale accepted --field prs='["api#40@${a.sha.slice(0, 7)}"]'`)
    hp(herd, 'stale review_running')
    hp(herd, `stale review_ok --field prs='["api#40@${a.sha}"]'`)
    const rt = runtime(handlerFor({ review: () => { throw new Error('reviewer must not run') }, integrate: () => integ(apiMain, 'org/api', ['api#40']) }))
    const g = [{ name: 'stale', slices: ['stale'], prs: [{ repo: 'org/api', short: 'api', n: 40, head: 'feat/stale', base: 'main', wt: a.wt, worker_model: 'claude-opus-5-5' }] }]
    const res = await rt.run(LOOP, base(herd, g))
    ok(res.results[0].outcome === 'review_ok', `stale: probe-only re-run ends review_ok (got ${res.results[0].outcome} ${res.results[0].error || ''})`)
    ok(rt.calls.filter(c => (c.label || '').startsWith('review:')).length === 0, 'stale: delta mode skips the reviewer when nothing changed')
    ok(/probe review/.test(lastOf(herd, 'stale').note), 'stale: note says probe')
    // code changed since review_ok -> delta review
    const nh = pushMore(api, a, 40, 'feat/stale', 'e.txt', 'changed')
    const rt2 = runtime(handlerFor({ review: () => CLEAN, integrate: () => integ(apiMain, 'org/api', ['api#40']) }))
    await rt2.run(LOOP, base(herd, g))
    const rv = rt2.calls.find(c => (c.label || '').startsWith('review:'))
    ok(rv && /DELTA review/.test(rv.prompt) && rv.prompt.includes(nh), 'stale: changed code gets a delta review of the new head')
    const rt3 = runtime(handlerFor({ review: () => CLEAN, integrate: () => integ(apiMain, 'org/api', ['api#40']) }))
    await rt3.run(LOOP, base(herd, g, { stale: 'full' }))
    const rv3 = rt3.calls.find(c => (c.label || '').startsWith('review:'))
    ok(rv3 && !/DELTA/.test(rv3.prompt), 'stale: stale=full re-reviews fully')
    // main moves, branch is rebased without code change -> range-diff all "=" -> probe only
    sh(`cd ${api.src} && git checkout -q main && git pull -q origin main && echo m > main2.txt && git add main2.txt && git commit -qm main2 && git push -q origin main`)
    sh(`cd ${a.wt} && git fetch -q origin && git rebase -q origin/main && git push -q -f origin HEAD:feat/stale HEAD:refs/pull/40/head`)
    const rt4 = runtime(handlerFor({ review: () => { throw new Error('reviewer must not run') }, integrate: () => integ(apiMain, 'org/api', ['api#40']) }))
    const r4 = await rt4.run(LOOP, base(herd, g))
    ok(r4.results[0].outcome === 'review_ok' && rt4.calls.filter(c => (c.label || '').startsWith('review:')).length === 0, 'stale: rebase without code change -> probe only')
    ok(lastOf(herd, 'stale').prs[0] === `api#40@${sh(`git -C ${a.wt} rev-parse HEAD`).trim()}`, 'stale: probe-only review_ok records the rebased head')
  }

  // --- 5b. fixer: same spot orange twice -> other model; maxFix exhausted -> back to the worker ---
  {
    const herd = path.join(TMP, 'herd5b')
    const a = prBranch(api, 'feat/stuck', 45, 'h.txt', 'k', 'stuck')
    hp(herd, 'stuck working')
    hp(herd, `stuck accepted --field prs='["api#45@${a.sha.slice(0, 7)}"]'`)
    const BUG = { ...MEDIUM, findings: [{ ...MEDIUM.findings[0], file: 'h.txt' }] }
    const rt = runtime(handlerFor({
      review: () => BUG,
      verify: () => ({ refuted: false, reason: 'yes', severity_corrected: 'medium' }),
      integrate: () => integ(apiMain, 'org/api', ['api#45']),
      fix: () => ({ fixed: [], not_fixed: ['off by one in range: tried'], commits: [], tests: '' }),
    }))
    const g = [{ name: 'stuck', slices: ['stuck'], prs: [{ repo: 'org/api', short: 'api', n: 45, head: 'feat/stuck', base: 'main', wt: a.wt, worker_model: 'claude-opus-5-5' }] }]
    const res = await rt.run(LOOP, base(herd, g, { fixBy: 'fixer', maxFix: 2 }))
    const fx = rt.calls.filter(c => (c.label || '').startsWith('fix:'))
    ok(fx.map(c => c.model).join() === 'claude-opus-5-5,claude-fable-5-1', `fixer: model switches after the 2nd orange round at the same spot (${fx.map(c => c.model).join()})`)
    ok(res.results[0].outcome === 'review_befund' && res.results[0].rounds === 3, 'fixer: gives up after maxFix rounds')
    const evs = events(herd).filter(e => e.slice === 'stuck').map(e => e.phase).join()
    ok(evs === 'working,accepted,review_running,review_befund,fix_queued', `fixer: exhausted loop hands back via fix_queued (${evs})`)
    ok(/gave up after 2 round/.test(lastOf(herd, 'stuck').note), 'fixer: fix_queued note says the fixer gave up')
    ok(/round 2: 1 blocking, fixer fixed 0/.test(fs.readFileSync(lastOf(herd, 'stuck').befunde_file, 'utf8')), 'fixer: befunde file carries the loop history')
  }

  // --- 6. integration failure blocks without skeptics; probe null blocks; fable fallback to opus ---
  {
    const herd = path.join(TMP, 'herd6')
    const a = prBranch(api, 'feat/integ', 50, 'f.txt', 'i', 'integ')
    hp(herd, 'integ working')
    hp(herd, `integ accepted --field prs='["api#50@${a.sha.slice(0, 7)}"]'`)
    const rt = runtime(handlerFor({
      review: (l, o) => (o.model === 'claude-fable-5-1' ? null : CLEAN),
      integrate: () => ({ ...integ(apiMain, 'org/api', ['api#50']), new_failures: [{ test: 'tests/test_x.py::test_y', pr: 'api#50', evidence: 'AssertionError 2 != 3' }] }),
    }))
    const res = await rt.run(LOOP, base(herd, [{ name: 'integ', slices: ['integ'], prs: [{ repo: 'org/api', short: 'api', n: 50, head: 'feat/integ', base: 'main', wt: a.wt, worker_model: 'claude-opus-5-5' }] }]))
    ok(res.results[0].outcome === 'review_befund', 'integ: new test failure from the probe blocks')
    ok(rt.calls.filter(c => (c.label || '').startsWith('review:')).map(c => c.model).join() === 'claude-fable-5-1,claude-opus-5-5', 'integ: unavailable fable reviewer falls back to opus')
    const bf = fs.readFileSync(lastOf(herd, 'integ').befunde_file, 'utf8')
    ok(/test_x\.py::test_y/.test(bf) && /source: integration/.test(bf), 'integ: befunde file names the failing test')
  }

  // --- 7. review-open-prs standalone: no herd, no prior -> pins the head, writes no state ---
  {
    const a = prBranch(api, 'feat/solo', 60, 'g.txt', 'o', 'solo')
    const rt = runtime(handlerFor({ review: () => CLEAN, integrate: () => integ(apiMain, 'org/api', ['api#60']) }))
    const res = await rt.run(REVIEW, { groups: [{ name: 'solo', slices: ['solo'], prs: [{ repo: 'org/api', short: 'api', n: 60, head: 'feat/solo', base: 'main', wt: a.wt }] }] })
    ok(res.groups.length === 1 && res.groups[0].pins['api#60'].pin === a.sha && res.groups[0].findings.length === 0, 'standalone: reviews the current head, no findings')
    ok(rt.calls.every(c => !/herd-phase/.test(c.prompt)), 'standalone: no herd-phase anywhere')
  }

  console.log(`${pass} passed, ${fail} failed`)
  if (!fail && !process.env.KEEP_TMP) fs.rmSync(TMP, { recursive: true, force: true })
  process.exit(fail ? 1 : 0)
}

main().catch(e => { console.log('CRASH ' + e.stack); process.exit(2) })
