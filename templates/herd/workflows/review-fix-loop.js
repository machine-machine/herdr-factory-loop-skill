export const meta = {
  name: 'review-fix-loop',
  description: 'Herd review loop per package: herd-phase review_running, review round (review-open-prs.js), then review_ok with head+main shas or review_befund + fix_queued with a befunde file; optional in-loop fixer',
  whenToUse: 'The orchestrator runs it when a package is accepted (or a review_ok package went stale). All herd state is written through herd-phase by agents running exact scripts.',
  phases: [
    { title: 'Start', detail: 'check every slice is accepted/review_ok, write review_running' },
    { title: 'Review', detail: 'child workflow review-open-prs.js: pin, review, verify, integrate' },
    { title: 'Fix', detail: 'only with fixBy=fixer: one fixer per package, pushes to the PR branches' },
    { title: 'Record', detail: 'write befunde files, NACH-MERGE.md, review_ok | review_befund + fix_queued' },
  ],
}

// Contract: docs/herd-flow-v2.md §1 + §5. A workflow script cannot run shell, so every state write is a
// script built here, byte for byte, and run verbatim by an agent. Nothing project-specific is hard-coded.
// args:
//   herd         absolute herd dir (REQUIRED) — herd.events.jsonl, <slice>.befunde-<sha7>.md, NACH-MERGE.md
//   reviewScript absolute path of review-open-prs.js (REQUIRED; workflow() needs a path)
//   groups       [{name, slices, prs:[{repo, short, n, head, base, wt, worker_model, slice?, title?, note?}]}]
//                in PLANNED MERGE ORDER (also the integration probe's order)
//   review       names of the groups to run now (default: all); the others only serve as probe baseline
//   setup        {<repo>: command} run in a fresh <slice>--review / probe worktree (env HERD_WT, HERD_SRC_WT, HERD_REPO, HERD_SLICE, HERD_SHA)
//   tests        {<repo>: command} touched suites for the integration probe
//   fixBy        'worker' (default: befund -> fix_queued, no fixer) | 'fixer' (in-loop fixer, max maxFix rounds)
//   reviewModel  'other' (default) | 'same';  stale 'delta' (default) | 'full'
//   run_id       id recorded in the events (default 'loop'); pass a timestamp, the script cannot make one
//   herdPhase    herd-phase command (default 'herd-phase' on PATH)
//   maxFix       fixer rounds (default 3);  models {opus, fable};  hot {<repo>: [regex]};  rules, register, lang
//   git          {name, email, coauthor} for fixer commits (default: the worktree's own git identity)

const A = args || {}
if (!A.herd) throw new Error('review-fix-loop: args.herd (absolute herd dir) is required')
if (!A.reviewScript) throw new Error('review-fix-loop: args.reviewScript (absolute path of review-open-prs.js) is required')
const HERD = String(A.herd).replace(/\/+$/, '')
const HP = A.herdPhase || 'herd-phase'
const RUN = A.run_id || 'loop'
const FIX_BY = A.fixBy === 'fixer' ? 'fixer' : 'worker'
const MAX_FIX = A.maxFix || 3
const OPUS = (A.models && A.models.opus) || 'claude-opus-5-5'
const FABLE = (A.models && A.models.fable) || 'claude-fable-5-1'
const GROUPS = A.groups || []
const WANT = A.review && A.review.length ? new Set(A.review) : null
const BLOCKING = ['high', 'medium']

function sq(s) { return "'" + String(s).replace(/'/g, "'\\''") + "'" }
function keyOf(pr) { return `${pr.short}#${pr.n}` }
function fld(k, v) { return `--field ${sq(k + '=' + (typeof v === 'string' ? v : JSON.stringify(v)))}` }
function phaseCmd(slice, ph, fields, note) {
  return [HP, sq(HERD), sq(slice), ph, '--by loop'].concat(fields.map(([k, v]) => fld(k, v))).concat(note ? [`--note ${sq(note)}`] : []).join(' ')
}
function heredoc(path, content, append, i) {
  let tag = `HERD_EOF_${i}`
  while (content.split('\n').includes(tag)) tag += 'X'
  return `cat ${append ? '>>' : '>'} ${sq(path)} <<'${tag}'\n${content.replace(/\n?$/, '\n')}${tag}`
}
function sliceOf(g, pr) {
  if (pr.slice) return pr.slice
  const b = String(pr.wt || '').replace(/\/+$/, '').split('/').pop()
  if ((g.slices || []).includes(b)) return b
  if ((g.slices || []).length === 1) return g.slices[0]
  throw new Error(`group ${g.name}: cannot tell the slice of ${keyOf(pr)} — set pr.slice`)
}
function slicesOf(g) { return (g.slices && g.slices.length) ? g.slices : [...new Set(g.prs.map(pr => sliceOf(g, pr)))] }
function fline(f) { return `${f.pr}: ${f.title} (${f.file}${f.line ? ':' + f.line : ''})` }
function spot(f) { return `${f.pr}|${f.file}|${f.title}` }

const RUNNER = {
  type: 'object',
  properties: {
    exit_code: { type: 'integer' },
    stdout: { type: 'string', description: 'complete stdout + stderr of the script, verbatim' },
  },
  required: ['exit_code', 'stdout'],
}
const runScript = (script, label, ph) => agent(`Run this bash script exactly as written in ONE Bash call (do not edit, split, re-quote or "fix" it; never add --force), then return its exit code and its complete output verbatim. Do nothing else — if it fails, report the failure, do not repair anything.\n\n${script}`, { label, phase: ph, schema: RUNNER, model: OPUS, effort: 'low' })

const FIX = {
  type: 'object',
  properties: {
    fixed: { type: 'array', items: { type: 'string' }, description: 'titles of fixed findings' },
    not_fixed: { type: 'array', items: { type: 'string' }, description: 'title + why not (does not reproduce, intended, would break something else)' },
    commits: { type: 'array', items: { type: 'string' }, description: 'short#n sha' },
    tests: { type: 'string' },
  },
  required: ['fixed', 'not_fixed', 'commits', 'tests'],
}

// ---- Start: refuse unless every slice is accepted | review_ok (| review_running = resume), then write review_running ----
const START_PY = [
  'import json,os,shutil,sys',
  'hp=shutil.which(sys.argv[1]) or sys.argv[1]',
  'sys.path.insert(0, os.path.dirname(os.path.realpath(hp)))',
  'import herd_events as he',
  'herd=sys.argv[2]; want=sys.argv[3:]',
  'st=he.state(herd); evs=he.read(herd); out={}; bad=[]',
  'for s in want:',
  '    cur=(st.get(s) or {}).get("phase")',
  '    basis=next((e for e in reversed(evs) if e["slice"]==s and e["phase"] in ("accepted","review_ok")), None)',
  '    out[s]={"current":cur,"basis":basis}; print("HERD_CUR "+s+" "+str(cur))',
  '    if cur not in ("accepted","review_ok","review_running") or basis is None: bad.append(s+"="+str(cur))',
  'print("HERD_STATE "+json.dumps(out))',
  'if bad: print("HERD_REFUSE "+" ".join(bad)); sys.exit(3)',
].join('\n')

function startScript(g) {
  const slices = slicesOf(g)
  const lines = ['set -euo pipefail',
    `out=$(python3 -c ${sq(START_PY)} ${[HP, HERD].concat(slices).map(sq).join(' ')}) || { printf '%s\\n' "$out"; exit 3; }`,
    'printf \'%s\\n\' "$out"']
  for (const s of slices) {
    lines.push(`if ! printf '%s\\n' "$out" | grep -qx ${sq(`HERD_CUR ${s} review_running`)}; then`)
    lines.push(`  ${phaseCmd(s, 'review_running', [['run_id', RUN], ['round', 1]], `review loop started (fix_by=${FIX_BY})`)}`)
    lines.push('fi')
  }
  // context files the reviewer/fixer prompts point at; best effort, skipped when herd-context is not installed
  const roles = FIX_BY === 'fixer' ? ['reviewer', 'fixer'] : ['reviewer']
  for (const s of slices) for (const r of roles) {
    lines.push(`if command -v herd-context >/dev/null 2>&1; then herd-context ${r} ${sq(HERD)} ${sq(s)} >/dev/null 2>&1 || echo ${sq(`HERD_CTX_FAILED ${r} ${s}`)}; fi`)
  }
  lines.push('echo HERD_START_DONE')
  return lines.join('\n')
}

function parseState(stdout) {
  const l = String(stdout || '').split('\n').find(x => x.startsWith('HERD_STATE '))
  if (!l) return null
  try { return JSON.parse(l.slice(11)) } catch (e) { return null }
}

// ---- Fixer (fixBy=fixer only) ----
function fmt(list) {
  return list.map((f, i) => `${i + 1}. [${f.severity_final}${f.unverified ? ', unverified' : ''}] ${f.pr} — ${f.title} (${f.file}${f.line ? ':' + f.line : ''})\n${f.description}\nRepro: ${f.repro}${(f.reasons || []).length ? '\nSkeptics: ' + f.reasons.join(' | ').slice(0, 1500) : ''}`).join('\n\n')
}
function fixPrompt(g, todo, round) {
  const id = A.git && A.git.name ? `-c user.name=${sq(A.git.name)} -c user.email=${sq(A.git.email || '')} ` : ''
  const wts = g.prs.map(pr => `${pr.repo} #${pr.n}: worktree ${pr.wt}, branch ${pr.head}`).join('; ')
  const sync = g.prs.map(pr => `\`git -C ${pr.wt} fetch origin && git -C ${pr.wt} merge --ff-only origin/${pr.head}\``).join(', ')
  const push = g.prs.map(pr => `\`git -C ${pr.wt} push origin HEAD:${pr.head}\``).join(', ')
  const ctx = slicesOf(g).map(s => `${HERD}/${s}.ctx.fixer.md, ${HERD}/${s}.task.md, ${HERD}/${s}.out.md`).join('; ')
  return `You fix review findings for herd package "${g.name}" (fix round ${round}). Work ONLY in these existing worktrees, on their PR branches: ${wts}.
First, in every worktree: \`git status --porcelain\` must be empty (otherwise do not touch it and report), then sync: ${sync}.
Context (read what exists): ${ctx}; earlier findings ${HERD}/<slice>.befunde-*.md.${A.register ? ` Decisions register: ${A.register} — a recorded decision is intent.` : ''}

Findings of this round:
${fmt(todo)}

For each finding: reproduce it yourself first. Reproducible -> smallest clean fix + a test that fails without the fix. Not reproducible, intended, or a fix would break a recorded decision -> do not change, explain in not_fixed. No over-correction: keep the PR's original intent.
Tests: only the touched test files${g.prs.map(pr => (A.tests || {})[pr.repo] || (A.tests || {})[pr.short] ? ` (${pr.short}: narrow \`${(A.tests || {})[pr.repo] || (A.tests || {})[pr.short]}\`)` : '').join('')}; no full suites.
Commit with \`git ${id}commit\`${A.git && A.git.coauthor ? `, message ends with the line "${A.git.coauthor}"` : ''}. Then push without force: ${push}. Extend each PR text with a section "Review loop fix round ${round}" (what, why, how to check) via \`gh pr edit <n> -R <repo> --body-file\`, keeping the rest. Add a short paragraph "Review loop fix" to the slice's out.md in ${HERD}.
Forbidden: merging, herd-phase, tickets, mail, staging, reading credentials, other branches/worktrees, force-push, pkill/pgrep -f.${A.rules ? '\n' + A.rules : ''}`
}

// ---- Record ----
function befundeText(g, slice, sha7, blocking, lows, integ, round, hist) {
  const lines = [`# Review findings — ${slice} @ ${sha7}`, '',
    `Package ${g.name}, run ${RUN}, round ${round}, fix_by ${FIX_BY}. Written by review-fix-loop.js; resume the worker with \`herd-spawn ${HERD} ${slice} --resume\`.`, '',
    '## To fix (medium/high, survived two skeptics or came from the integration probe)', '']
  blocking.forEach((f, i) => {
    lines.push(`### ${i + 1}. [${f.severity_final}] ${f.pr} — ${f.title}`, '', `File: ${f.file}${f.line ? ':' + f.line : ''}${f.source ? ` (source: ${f.source})` : ''}`, '', f.description, '', `Repro: ${f.repro}`)
    if ((f.reasons || []).length) lines.push('', `Skeptics: ${f.reasons.join(' | ')}`)
    lines.push('')
  })
  if (lows.length) lines.push('## Low (optional, also fine after merge)', '', ...lows.map(f => `- ${fline(f)}: ${f.description}`), '')
  if (integ.length) lines.push('## Integration probe', '', ...integ.map(r => r.error ? `- ${r.repo}: ${r.error}` : `- ${r.repo} on main ${r.main_sha}: order ${(r.order || []).join(' -> ')}; baseline ${r.baseline_result}; candidate ${r.candidate_result}${(r.predecessor_problems || []).length ? '; earlier packages: ' + r.predecessor_problems.join('; ') : ''}`), '')
  if (hist.length) lines.push('## Loop history', '', ...hist.map(h => `- round ${h.round}: ${h.blocking.length} blocking${h.fix ? `, fixer fixed ${h.fix.fixed.length}, not fixed ${h.fix.not_fixed.length}` : ''}`), '')
  return lines.join('\n')
}

function recordScript(g, gr, round, hist) {
  const parts = ['set -euo pipefail']
  const out = {}
  const mainByRepo = Object.fromEntries((gr.integration || []).filter(r => r && r.main_sha).map(r => [r.repo, r.main_sha]))
  let i = 0
  for (const slice of slicesOf(g)) {
    const prs = g.prs.filter(pr => sliceOf(g, pr) === slice)
    const found = gr.findings.filter(f => f.slice === slice)
    const blocking = found.filter(f => BLOCKING.includes(f.severity_final))
    const lows = found.filter(f => f.severity_final === 'low')
    const prList = prs.map(pr => `${keyOf(pr)}@${gr.pins[keyOf(pr)].pin}`)
    if (!prs.length) continue
    if (blocking.length) {
      const sha7 = gr.pins[keyOf(prs[0])].pin.slice(0, 7)
      const file = `${HERD}/${slice}.befunde-${sha7}.md`
      parts.push(heredoc(file, befundeText(g, slice, sha7, blocking, lows, gr.integration || [], round, hist), false, i++))
      parts.push(phaseCmd(slice, 'review_befund', [['prs', prList], ['run_id', RUN], ['befunde_file', file]], `${blocking.length} medium/high finding(s) in round ${round}`))
      parts.push(phaseCmd(slice, 'fix_queued', [['befunde_file', file]], FIX_BY === 'fixer' ? `in-loop fixer gave up after ${round - 1} round(s); back to the worker` : 'findings go back to the worker'))
      out[slice] = { outcome: 'review_befund', prs: prList, befunde_file: file, blocking: blocking.map(fline), lows: lows.map(fline) }
    } else {
      const repos = [...new Set(prs.map(pr => pr.repo))]
      const main = repos.map(r => `${prs.find(pr => pr.repo === r).short}@${mainByRepo[r]}`)
      const lowLines = lows.map(fline)
      if (lowLines.length) parts.push(heredoc(`${HERD}/NACH-MERGE.md`, [`## ${slice} — review ${RUN} (${prList.join(', ')})`, '', ...lows.map(f => `- [low] ${fline(f)}: ${f.description}`), ''].join('\n'), true, i++))
      const modes = prs.map(pr => (gr.modes || {})[keyOf(pr)] || 'full')
      parts.push(phaseCmd(slice, 'review_ok', [['prs', prList], ['main', main], ['run_id', RUN], ['lows', lowLines]], `clean after round ${round} (${[...new Set(modes)].join('/')} review, integration probe passed)`))
      out[slice] = { outcome: 'review_ok', prs: prList, main, lows: lowLines }
    }
  }
  parts.push('echo HERD_RECORD_DONE')
  return { script: parts.join('\n'), slices: out }
}

// ---- per package ----
async function loop(g) {
  const slices = slicesOf(g)
  const st = await runScript(startScript(g), `start:${g.name}`, 'Start')
  const state = st && parseState(st.stdout)
  if (!st || st.exit_code !== 0 || !state) {
    const why = st ? (String(st.stdout).split('\n').find(l => l.startsWith('HERD_REFUSE')) || `exit ${st.exit_code}`) : 'start agent returned nothing'
    log(`${g.name}: not started — ${why}`)
    return { group: g.name, outcome: 'not_started', error: why, output: st && st.stdout }
  }
  let prior = {}
  for (const s of slices) {
    const x = state[s]
    prior[s] = x.current === 'review_running' ? { phase: 'review_running', prs: (x.basis || {}).prs } : { phase: x.basis.phase, prs: x.basis.prs }
    if (x.current === 'review_running') log(`${g.name}/${s}: resuming an interrupted review — pinning the current head`)
  }
  const hist = []
  const seen = {}
  let gr = null
  let round = 1
  for (; ; round++) {
    const res = await workflow({ scriptPath: A.reviewScript }, {
      herd: HERD, groups: GROUPS, review: [g.name], prior, round, setup: A.setup, tests: A.tests,
      reviewModel: A.reviewModel, stale: A.stale, models: A.models, hot: A.hot, rules: A.rules, register: A.register, lang: A.lang,
    })
    gr = res && (res.groups || []).find(x => x.name === g.name)
    if (!gr || gr.error) {
      const why = gr ? gr.error : 'review workflow returned nothing'
      log(`${g.name}: review round ${round} failed — ${why}; slices stay review_running, re-run the loop to resume`)
      return { group: g.name, outcome: 'error', rounds: round, error: why, hist }
    }
    const blocking = gr.findings.filter(f => BLOCKING.includes(f.severity_final))
    hist.push({ round, blocking: blocking.map(fline), lows: gr.findings.filter(f => f.severity_final === 'low').map(fline) })
    log(`${g.name} round ${round}: ${blocking.length} medium/high, ${gr.findings.length - blocking.length} low`)
    if (!blocking.length || FIX_BY === 'worker' || round > MAX_FIX) break
    // fixer: same model as the worker; switch after the 2nd orange round at the same spot (MODELS.md)
    const worker = (g.prs[0] && g.prs[0].worker_model) || OPUS
    blocking.forEach(f => { seen[spot(f)] = (seen[spot(f)] || 0) + 1 })
    const stuck = blocking.some(f => seen[spot(f)] >= 2)
    const model = stuck ? (/fable/i.test(worker) ? OPUS : FABLE) : worker
    if (stuck) log(`${g.name}: same spot orange twice — fixer switches to ${model}`)
    let fix = await agent(fixPrompt(g, blocking, round), { label: `fix:${g.name}#${round}`, phase: 'Fix', schema: FIX, model, effort: 'high' })
    if (!fix && model !== OPUS) fix = await agent(fixPrompt(g, blocking, round), { label: `fix:${g.name}#${round}~opus`, phase: 'Fix', schema: FIX, model: OPUS, effort: 'high' })
    hist[hist.length - 1].fix = fix || { fixed: [], not_fixed: ['fixer returned nothing'], commits: [], tests: '' }
    if (!fix) break
    // the next round reviews what the fixer pushed: pin the current head, full review
    prior = Object.fromEntries(slices.map(s => [s, { phase: 'review_running', prs: (prior[s] || {}).prs }]))
  }
  const rec = recordScript(g, gr, round, hist)
  const done = await runScript(rec.script, `record:${g.name}`, 'Record')
  const ok = done && done.exit_code === 0 && String(done.stdout).includes('HERD_RECORD_DONE')
  if (!ok) log(`${g.name}: recording failed — the orchestrator must run the returned script by hand`)
  const outcome = Object.values(rec.slices).some(s => s.outcome === 'review_befund') ? 'review_befund' : 'review_ok'
  return { group: g.name, outcome: ok ? outcome : 'record_failed', rounds: round, slices: rec.slices, hist, record: done, script: ok ? undefined : rec.script }
}

const todo = GROUPS.filter(g => !WANT || WANT.has(g.name))
if (!todo.length) log('review-fix-loop: no group selected (check args.groups / args.review)')
const results = await parallel(todo.map(g => () => loop(g)))
return { run_id: RUN, fix_by: FIX_BY, results: results.map((r, i) => r || { group: todo[i].name, outcome: 'error', error: 'loop crashed' }) }
