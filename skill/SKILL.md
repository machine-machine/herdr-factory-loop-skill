---
name: herdr
version: 1.3.0
description: Orchestrate a fleet of AI coding agents through herdr — the terminal workspace manager (workspaces → tabs → panes) running on this machine. Spawn agents, dispatch work, watch lifecycle state (idle/working/blocked), unblock approval prompts, fan out and converge multi-agent work, and manage agent integrations. Trigger when the user mentions herdr, "the fleet", "orchestrate agents", "spawn an agent", "what are my agents doing", panes/workspaces/worktrees, herdr integrations, or wants an agent to drive other coding agents (claude/codex/cursor/opencode/etc.) running in herdr. ALSO trigger when an intent arrives over a chat channel (Mattermost, Discord, Slack, etc.) and the right response is to spin up a parallel herdr "herd" of codex (or mixed) workers to achieve the goal — understand the intent first, then fan out concurrent workers, converge results, and report back on the same channel. ALSO trigger for spec-driven development (SDD) — when the user mentions spec-kit, /speckit.* commands, "factory loop", "SDD", spec→plan→tasks→implement, or wants to onboard the factory (choose Claude Code or Hermes as orchestrator).
---

# herdr Skill

Drive herdr — a terminal workspace manager purpose-built to run **more than one coding agent at a time**. herdr is a local CLI + headless server talking over a Unix-domain socket. You orchestrate the fleet through the `herdr` CLI (which wraps the socket API) or by speaking JSON to the socket directly.

> **You are inside herdr right now.** This Claude session is itself a herdr-managed agent in a pane. Read [Know thyself](#know-thyself-critical) before sending keys or closing anything.

## This install (verified)

| Property | Value |
|----------|-------|
| Binary | `/Users/USERNAME/.local/bin/herdr` (on PATH as `herdr`) |
| Version | `0.6.9` (protocol 13) |
| Server | running — `herdr status` to confirm |
| Socket | `~/.config/herdr/herdr.sock` (default session) |
| Config | `~/.config/herdr/config.toml` |
| Logs | `~/.config/herdr/{herdr,herdr-client,herdr-server}.log` |
| Integrations installed | `claude`, `codex`, `opencode`, `kilo`, `hermes`, `cursor` |
| Integrations available, not installed | `pi`, `omp`, `copilot`, `droid`, `kimi`, `qodercli` |

CLI socket-query subcommands (`agent list`, `pane list`, `pane get`, …) print the **raw JSON socket response** to stdout — pipe through `jq`. Always run non-interactive subcommands; **never** run bare `herdr` (it launches/attaches the TUI and will hang a non-interactive shell).

## The model

```
workspace ──┬── tab ──┬── pane ── (terminal, optionally hosting an agent)
            │         └── pane ── agent: claude, codex, …
            └── tab …
```

- **pane** — a terminal. May host an **agent**. Identified by `pane_id` like `w653edbb5f35571-1`. Also addressable by `terminal_id` (`term_…`).
- **agent** — a detected/reported coding agent in a pane. Has:
  - **lifecycle state**: `idle` | `working` | `blocked` | `done` | `unknown`. From installed **integration hooks** (authoritative) or screen-manifest detection (heuristic).
  - **session identity**: `agent_session.value` (e.g. a Claude session UUID) used for native **restore** after restart.
- `blocked` = the agent is waiting on a human (approval / permission / question prompt). This is your cue to intervene.

`herdr <thing> --help` prints exact syntax for any command group. Full flag/method reference: [reference.md](reference.md).

---

## Core orchestration workflows

### 1. Discover the fleet
```bash
herdr status                                  # server up? version?
herdr agent list | jq '.result.agents'        # every agent: state, cwd, pane_id, session
herdr pane list  | jq '.result.panes'          # every pane (incl. agent-less terminals)
herdr workspace list ; herdr tab list          # topology
```
Quick human-readable roll-up:
```bash
herdr agent list | jq -r '.result.agents[] | "\(.agent_status)\t\(.agent)\t\(.cwd)\t\(.pane_id)"'
```

### 2. Know thyself (CRITICAL)
Before any `send-*`, `run`, `close`, or `server stop`, identify the orchestrator's own pane and exclude it:
```bash
SELF=$(herdr agent list | jq -r '.result.agents[] | select(.focused==true) | .pane_id')
# (or match .agent_session.value against this session's UUID)
```
Never `send-keys`, `send-text`, `pane close`, or `agent attach --takeover` your **own** `$SELF` pane — you will corrupt your own input or kill the session. Treat `$SELF` as read-only.

### 3. Spawn an agent
```bash
# Start a named agent; everything after `--` is the agent's FULL argv —
# argv[0] MUST be the binary (full path is safest). Flags alone fail with
# "No viable candidates found in PATH".
herdr agent start claude --cwd /path/to/repo --split right --no-focus -- \
  "$(command -v claude)" --dangerously-skip-permissions
herdr agent start codex  --workspace <ws_id> --tab <tab_id> -- "$(command -v codex)" ...
```
For **isolated parallel work**, give each agent its own git worktree first:
```bash
herdr worktree create --cwd /repo --branch feature/x --base main --label "feat-x" --json
herdr agent start claude --cwd ~/.herdr/worktrees/<repo>/feature-x --no-focus -- ...
```
`agent start` returns the new pane/agent identifiers in its JSON result — capture them.

### 4. Dispatch work to an agent
`agent send` writes **literal text** (no submit). To submit a prompt to a TUI agent, send the text then an Enter:
```bash
herdr agent send <target> "Refactor the auth module. Report back when done."
herdr pane send-keys <pane_id> Enter
```
For a shell pane, `pane run` types the command **and** presses Enter in one step:
```bash
herdr pane run <pane_id> "pytest -q"
```
`<target>` accepts terminal ids, unique agent names, detected labels, or pane ids.

**Long prompts and reliable answers — use the file protocol.** Never stream a multi-line prompt into a TUI input (newlines can submit early), and never scrape a TUI screen for a deliverable (wrapped, truncated, full of chrome). Instead:
```bash
# 1. Prompt → file; dispatch a one-line pointer
cat > /tmp/task-$ID.md <<EOF
<full task here>
Output protocol: write your COMPLETE answer to /tmp/answer-$ID.md,
then output this exact line in the terminal: TASK_DONE_$ID
EOF
herdr agent send "$PANE" "Read /tmp/task-$ID.md and follow its instructions exactly."
herdr pane send-keys "$PANE" Enter
# 2. Wait on the sentinel; the FILE is the deliverable, not the screen
herdr wait output "$PANE" --match "TASK_DONE_$ID" --timeout 600000
cat /tmp/answer-$ID.md
```
Use `pane read` for *monitoring* (what is the agent doing?), the file protocol for *deliverables* (what did it produce?).

### 5. Monitor & wait
Block until an agent changes state (the backbone of orchestration):
```bash
herdr agent wait <target> --status idle    --timeout 600000   # ms; wait for it to finish
herdr agent wait <target> --status blocked --timeout 600000   # wait until it needs you
herdr wait output <pane_id> --match "BUILD OK" --regex --timeout 120000
```
Read what an agent produced:
```bash
herdr agent read <target> --source recent --lines 80           # recent scrollback
herdr pane  read <pane_id> --source recent-unwrapped --lines 200
herdr pane  read <pane_id> --source visible                    # just the visible screen
```

### 6. Unblock a stuck agent
When state is `blocked`, read the prompt, decide, and answer:
```bash
herdr agent read <target> --source visible              # see the approval/question
herdr pane send-keys <pane_id> Enter                    # accept default
# or choose an option / type an answer:
herdr pane send-text <pane_id> "2" ; herdr pane send-keys <pane_id> Enter
```
Approve only what the user authorized. Surface destructive prompts (deletes, force-push, secrets) to the user instead of auto-approving.

### 7. Fan-out → converge loop
The canonical multi-agent pattern, in bash:
```bash
# fan out: one agent per task, each in its own worktree, none focused
for t in task_a task_b task_c; do
  herdr worktree create --cwd /repo --branch wip/$t --base main --json
  PANE=$(herdr agent start claude --cwd ~/.herdr/worktrees/repo/wip-$t --no-focus -- \
           "$(command -v claude)" --dangerously-skip-permissions | jq -r '.result.agent.pane_id')
  herdr agent send $PANE "$(cat tasks/$t.md)"; herdr pane send-keys $PANE Enter
  echo "$t=$PANE" >> /tmp/fleet.map
done
# converge: poll each to idle, then collect
while read kv; do t=${kv%=*}; p=${kv#*=}
  herdr agent wait $p --status idle --timeout 1800000
  herdr pane read $p --source recent-unwrapped --lines 300 > /tmp/$t.out
done < /tmp/fleet.map
```
For tighter loops, subscribe to events over the socket instead of polling — see §Socket below.

### 8. Notify the human
```bash
herdr notification show "fleet idle" --body "3/3 tasks done" --position top-right --sound done
```

### 9. Channel-driven intent → spin up a herdr "herd"
**Use when:** an intent arrives over a chat channel (Mattermost, Discord, Slack, etc.) and the work is decomposable into **independent sub-tasks** that benefit from running in parallel. The user is *not* at the keyboard — they're waiting for a deliverable on the channel.

If the work is a single small fix, just do it inline — do not fan out. Fan out only when the goal has ≥2 truly independent slices (different files / services / concerns) or when the user explicitly asks for parallel workers.

#### 9.1 Understand the intent (do this FIRST, before any spawning)
1. Re-read the message end-to-end. Channel messages are often terse, use shorthand, or assume context from a thread.
2. Identify the **deliverable**: what does "done" look like? What repo? What branch / base? Are there constraints (must not touch X, must use Y, deadline)?
3. If any of those are ambiguous, **ask one focused clarifying question on the channel** *before* spawning. Do not spawn into ambiguity.
4. Decompose into parallel slices. Good splits:
   - **By file/module**: "refactor auth/, refactor api/, write tests" → 3 workers
   - **By service**: "frontend changes, backend changes, infra changes" → 3 workers
   - **By concern**: "implement, test, document" → 3 workers
   - **By independent feature branch** (when the user asks for several features at once)
   Bad splits: anything that touches the same files, anything that needs a prior slice to exist (do that serially first).
5. Decide the **base ref** for worktrees (usually `main`; or whatever the user / repo state implies).
6. Decide the **worker agent type**. Default to `codex` (good at long-running, focused coding tasks, and it's installed in this fleet). Mix in `claude` for tasks needing broader context or `cursor` for IDE-style work — only when there's a clear reason.
7. **Write the plan down before spawning.** Capture the decomposition in `/tmp/herd-plan.md`: intent, base ref, one line per slice (name → concrete deliverable → files it owns). The plan is the source of truth — every worker prompt in §9.2 derives from it, the converge summary in §9.5 reports against it, and the run report in §10 archives it. If the herd is risky (≥4 workers, or touches deploy/infra/data), post the plan to the channel and get an ack **before** spawning.
8. **Check for prior art.** Before decomposing from scratch, look for an earlier run report on a similar intent (`ls ~/.herdr/runs/ | grep -i <keyword>`, or query fleet memory). A past run's splits, prompts, and "next time" notes are usually a better starting point than a fresh guess.

#### 9.2 Spawn the herd (one worktree per worker, all in parallel)
```bash
# Identify self BEFORE spawning — see §2
SELF=$(herdr agent list | jq -r '.result.agents[] | select(.focused==true) | .pane_id')

REPO=/path/to/repo
BASE=main
INTENT="<the user's goal, restated concretely>"  # e.g. "add OAuth login + rate limiting + audit log"
SPLITS=("oauth" "rate-limit" "audit-log")        # N=3 workers
: > /tmp/herd.map                                # task -> pane_id

for t in "${SPLITS[@]}"; do
  # 1. isolated worktree per worker
  herdr worktree create --cwd "$REPO" --branch "wip/$INTENT/$t" --base "$BASE" --label "$t" --json \
    | jq -r '.result.worktree.path' > /tmp/wt-$t

  WT=$(cat /tmp/wt-$t)
  # 2. spawn codex worker, do NOT take focus
  PANE=$(herdr agent start codex --cwd "$WT" --split right --no-focus -- \
           "$(command -v codex)" --dangerously-skip-permissions \
    | jq -r '.result.agent.pane_id')
  # 3. author a tight, scoped prompt per worker (one slice only)
  cat > /tmp/prompt-$t.md <<EOF
Scope: $t only. Do NOT touch files outside $t's slice.
Repo: $WT  (worktree, branch wip/$INTENT/$t, base $BASE)
Goal: <concrete deliverable for $t from the original intent>
Constraints: <any from the channel, e.g. "do not modify existing tests">
When done: commit on the current branch with a clear message and report back.
EOF
  herdr agent send "$PANE" "$(cat /tmp/prompt-$t.md)"
  herdr pane send-keys "$PANE" Enter

  echo "$t=$PANE=$WT" >> /tmp/herd.map
done
```
Key rules:
- `--no-focus` on **every** worker so you keep the channel-readable pane focused.
- One worktree per worker, branched off the agreed base — workers cannot clobber each other.
- Each prompt is **one slice only**. No "while you're at it…" prompts.
- Write the deliverable definition into the prompt so the worker doesn't have to guess.

#### 9.3 Monitor the herd (event-driven, not polling)
Subscribe to state changes once at the start; react as events arrive:
```bash
# Open a persistent socket; for one-shot polling, see the loop below
socat - UNIX-CONNECT:~/.config/herdr/herdr.sock > /tmp/herd.events <<EOF
{"id":"sub","method":"events.subscribe","params":{"subscriptions":[
  {"type":"pane.agent_status_changed","agent_status":"blocked"},
  {"type":"pane.agent_status_changed","agent_status":"idle"}
]}}
EOF
```
Or poll per-worker (simpler, fine for ≤10 workers):
```bash
while read line; do
  t=${line%%=*}; rest=${line#*=}; p=${rest%%=*}; wt=${rest#*=}
  echo ">> $t: waiting…"
  if ! herdr agent wait "$p" --status idle --timeout 1800000; then
    echo "!! $t: timed out / errored"; continue
  fi
  if [ "$(herdr agent get "$p" | jq -r '.result.pane.agent_status')" = "blocked" ]; then
    # Worker needs approval — see §6, then re-wait
    herdr agent read "$p" --source visible
    # decide: auto-approve (safe) vs escalate to channel (destructive)
  fi
  herdr agent read "$p" --source recent --lines 200 > /tmp/herd-$t.out
  echo ">> $t: done"
done < /tmp/herd.map
```

#### 9.4 Unblock workers (channel-aware approval)
When a worker goes `blocked` on a permission/approval prompt:
- **Auto-approve** routine stuff (running tests, reading files, installing packages in the worktree).
- **Escalate to the channel** for anything destructive (force-push, deleting branches, writing to main, touching secrets, network exfiltration). Post the prompt verbatim and the worker's branch, then wait for the user's reply.
- Never `pane send-keys $SELF` — your own pane is off-limits (§2).
- After approving, the worker resumes; `agent wait` will continue or you can re-issue it.

#### 9.5 Converge
Once all workers are `idle`/`done`:
1. Collect each worker's branch from `/tmp/herd.map`.
2. Merge serially into a single integration branch (or open N PRs — let the user pick on the channel):
   ```bash
   INT_BRANCH="herd/$INTENT"
   git -C "$REPO" switch -c "$INT_BRANCH" "$BASE"
   for t in "${SPLITS[@]}"; do
     wt=$(grep "^$t=" /tmp/herd.map | cut -d= -f3)
     git -C "$REPO" merge --no-ff "wip/$INTENT/$t" -m "merge: $t"
   done
   git -C "$REPO" push -u origin "$INT_BRANCH"
   ```
3. Run the project's test/lint suite on the integration branch.
4. **Review before you report.** Don't hand the user an unreviewed merge — spawn reviewer agents on the integration branch, in parallel, one lens each (correctness, security if the diff touches auth/input/secrets, project conventions):
   ```bash
   for lens in correctness conventions; do
     PANE=$(herdr agent start claude --cwd "$REPO" --no-focus -- \
              "$(command -v claude)" --dangerously-skip-permissions \
       | jq -r '.result.agent.pane_id')
     herdr agent send "$PANE" "Review the diff between $BASE and $INT_BRANCH for $lens issues only. Severity-tag each finding P1 (must fix) / P2 (should fix) / P3 (nit). Output findings as a list, nothing else."
     herdr pane send-keys "$PANE" Enter
     echo "review-$lens=$PANE" >> /tmp/herd.map
   done
   # wait + collect like any other worker (§9.3)
   ```
   Fix P1s before posting the summary (dispatch fixes back to the relevant worker, or fix inline). Carry P2/P3 into the summary as known issues.
5. Post a single summary on the channel: each slice's status, branch names, test result, review verdict (P1s fixed, open P2/P3s), and a one-line "what changed" per slice.
6. **Compound the run** — capture what you learned while it's cheap. See §10. This is not optional bookkeeping; it's what makes the next herd faster than this one.
7. Leave the worktrees and panes in place unless the user asks to tear down. To tear down:
   ```bash
   while read line; do
     t=${line%%=*}; rest=${line#*=}; p=${rest%%=*}; wt=${rest#*=}
     herdr pane close "$p"          # closes the pane; worker dies
     herdr worktree remove --workspace <ws_id> --force
     git -C "$REPO" worktree remove "$wt" --force
     git -C "$REPO" branch -D "wip/$INTENT/$t"
   done < /tmp/herd.map
   ```

#### 9.6 Channel-style checklist (paste into the channel after launch)
```
:herd: started: <INTENT>
workers: <N> (all codex, parallel)
base:   <branch>
branches: wip/<INTENT>/<t1>, wip/<INTENT>/<t2>, …
I'll post when each slice finishes or needs approval.
```

#### 9.7 When NOT to herd
- Single small change → just do it.
- Slices share files → sequence them, don't parallelize.
- User is iterating live with you → stay inline, don't spawn.
- You're not sure what the user wants → ask, don't spawn.

### 10. Compound — make the next herd cheaper than this one
Each orchestration run should make subsequent runs easier, not just ship its own deliverable. Run this after **every** non-trivial herd or fan-out (skip for single-agent dispatches).

#### 10.1 Write the run report
One markdown file per run, in a predictable place, while the details are still fresh:
```bash
mkdir -p ~/.herdr/runs
cat > ~/.herdr/runs/$(date +%Y-%m-%d)-<intent-slug>.md <<EOF
# herd run: <intent>
- plan: $(cat /tmp/herd-plan.md 2>/dev/null || echo "<inline the plan>")
- splits: <which were truly independent; which collided or had to be serialized>
- prompts: <the per-worker prompts that worked — verbatim, they're reusable>
- blockers: <every \`blocked\` event: what prompted it, how resolved, auto-approvable next time?>
- review: <P1/P2/P3 counts; anything a worker prompt could have prevented>
- timings: <per-slice wall clock; which slice was the long pole>
- verdict: <merged / partial / abandoned> — and why
- next time: <ONE concrete change — to a prompt, a split heuristic, or this skill>
EOF
```
The `next time` line is the whole point. Everything else is evidence for it.

#### 10.2 Store it where the fleet can find it
A report nobody can discover compounds nothing. If the fleet has a shared memory system, store the gist there (intent, verdict, the `next time` line, path to the full report) so any agent planning a similar herd later — see §9.1 step 8 — finds it. Otherwise `~/.herdr/runs/` is the index; keep slugs descriptive.

#### 10.3 Promote recurring lessons into this skill
When the same `next time` note shows up in a second run report, it stops being a note and becomes a defect in this skill. Fix it at the source:
- A prompt pattern that keeps working → add it to §9.2.
- A blocker class you keep auto-approving → add it to the §9.4 auto-approve list.
- A split heuristic that keeps failing → amend §9.1 step 4.

Open a PR against this repo (see CONTRIBUTING.md — it's a MINOR bump). The skill is the fleet's institutional memory: a lesson that lives only in a run report gets re-learned; a lesson merged here is learned once, by every future agent.

### 11. SDD factory loop — spec-kit × herdr

The factory loop is herdr orchestration with [github/spec-kit](https://github.com/github/spec-kit) as the front half: **nothing is implemented without a spec, and every herd derives its slices from `tasks.md` instead of ad-hoc decomposition.** Use it whenever the user asks for SDD, the factory loop, or any `/speckit.*` command — and prefer it over §9's freeform decomposition for any feature big enough to herd.

```
constitution → specify → clarify → plan → tasks ──→ herd implements (§9 machinery)
     ▲                                       │              │
     └────────── compound (§10) ◄── converge ◄── analyze ◄──┘
```

#### 11.0 Onboard (once per machine, once per repo)

Run the onboarding TUI from this repo to choose the orchestrator and establish the loop:
```bash
./scripts/onboard.sh                                    # interactive
./scripts/onboard.sh --orchestrator claude --repo /path/to/repo --yes   # scripted
```
It (1) picks **Claude Code or Hermes** as the orchestrator, (2) verifies herdr/jq/git, (3) installs this skill for the chosen agent, (4) installs the `specify` CLI (`uv tool install specify-cli --from git+https://github.com/github/spec-kit.git`), (5) runs `specify init --here` in the target repo, and (6) records the choice in `~/.config/herdr-factory/config.toml`.

Integration mapping: **claude** → `specify init --here --integration claude` (prompts land in `.claude/commands/speckit.*.md`); **hermes** → `specify init --here --integration generic --integration-options="--commands-dir .hermes/commands/"` (same prompts, in `.hermes/commands/`). Older spec-kit builds use `--ai` instead of `--integration` — onboard.sh detects this. Check the active orchestrator any time: `cat ~/.config/herdr-factory/config.toml`.

#### 11.1 The loop, stage by stage

The **orchestrator** (you) runs the spec-kit stages in its own session; only implementation fans out to workers.

| # | Stage | Command / action | Artifact | Gate to pass |
|---|-------|------------------|----------|--------------|
| 1 | Constitution | `/speckit.constitution` (once per repo) | `.specify/memory/constitution.md` | Principles exist |
| 2 | Specify | `/speckit.specify <feature idea>` | `specs/<feature>/spec.md` | User stories + acceptance criteria, no `[NEEDS CLARIFICATION]` left |
| 3 | Clarify | `/speckit.clarify` | updated `spec.md` | Ambiguities resolved (ask the user, don't guess) |
| 4 | Plan | `/speckit.plan <tech context>` | `plan.md`, `research.md`, `data-model.md`, `contracts/` | Plan consistent with constitution |
| 5 | Tasks | `/speckit.tasks` | `tasks.md` (`[P]` = parallelizable) | Every requirement maps to ≥1 task |
| 6 | Implement | herd executes `tasks.md` — §11.2 | commits on `wip/` branches | All assigned tasks done, tests pass per worker |
| 7 | Analyze | `/speckit.analyze` | consistency report | No CRITICAL findings (spec↔plan↔tasks↔code drift) |
| 8 | Converge | merge → test → review (§9.5) | integration branch | Acceptance criteria in `spec.md` verified, P1 review findings fixed |
| 9 | Compound | §10 run report | `~/.herdr/runs/…` | `next time` line written |

Small features (≤3 tasks, no `[P]`): skip the herd, run `/speckit.implement` inline in the orchestrator session. Stages 6–8 above replace `/speckit.implement` only when fanning out.

#### 11.2 Dispatch `tasks.md` to the herd

`tasks.md` is the herd plan — it replaces `/tmp/herd-plan.md` from §9.1 step 7. Tasks marked `[P]` touch disjoint files and may run concurrently; unmarked tasks have ordering dependencies and run serially (in the orchestrator or a single worker) **before** the parallel wave they gate.

```bash
FEATURE_DIR=$(ls -td specs/*/ | head -1)        # active feature (or take it from the spec stage output)
TASKS="$FEATURE_DIR/tasks.md"

# Slices: one worker per [P] task (or per phase-group of [P] tasks for small tasks)
grep -E '^- \[ \] T[0-9]+ \[P\]' "$TASKS"

# Spawn per slice — same worktree machinery as §9.2
SELF=$(herdr agent list | jq -r '.result.agents[] | select(.focused==true) | .pane_id')
while IFS= read -r task; do
  TID=$(echo "$task" | grep -oE 'T[0-9]+' | head -1)
  herdr worktree create --cwd "$REPO" --branch "wip/$FEATURE/$TID" --base "$BASE" --label "$TID" --json \
    | jq -r '.result.worktree.path' > /tmp/wt-$TID
  WT=$(cat /tmp/wt-$TID)
  PANE=$(herdr agent start codex --cwd "$WT" --no-focus -- \
           "$(command -v codex)" --dangerously-skip-permissions \
    | jq -r '.result.agent.pane_id')
  cat > /tmp/prompt-$TID.md <<EOF
You are one worker in an SDD herd. Read these FIRST, in order:
  1. .specify/memory/constitution.md   (project principles — binding)
  2. $FEATURE_DIR/spec.md              (WHAT and acceptance criteria)
  3. $FEATURE_DIR/plan.md              (HOW — stack, structure, contracts)
Your assignment from $FEATURE_DIR/tasks.md: $task
Do this task and ONLY this task. Do NOT edit tasks.md (the orchestrator owns it).
When done: run the tests relevant to your change, commit on the current branch
with message "$TID: <summary>", and report what you did and how you verified it.
EOF
  herdr agent send "$PANE" "$(cat /tmp/prompt-$TID.md)"
  herdr pane send-keys "$PANE" Enter
  echo "$TID=$PANE=$WT" >> /tmp/herd.map
done < <(grep -E '^- \[ \] T[0-9]+ \[P\]' "$TASKS")
```
Monitor, unblock, and converge with the §9.3–9.5 machinery unchanged. SDD-specific rules:
- **Workers never edit `tasks.md`** — parallel edits to it merge-conflict. The orchestrator ticks `- [x]` boxes on the integration branch as each worker's output is verified.
- **The spec is the contract.** A worker that "improves" beyond its task's scope gets its extra changes reverted at converge.
- Run `/speckit.analyze` on the integration branch (stage 7) **before** the §9.5 review wave — it catches spec↔code drift the lens reviewers won't look for.
- At converge, verify against `spec.md`'s acceptance criteria (and any `/speckit.checklist` output), not just "tests pass".

#### 11.3 SDD gates (the loop's contract)

- **No spec → no herd.** If asked to "just implement" something non-trivial in a spec-kit repo, run stages 2–5 first (they're fast) or get the user's explicit waiver.
- `tasks.md` is the only source of slices. If a slice feels wrong, fix `tasks.md` (re-run `/speckit.tasks` or edit it) — don't silently deviate from it.
- A `[NEEDS CLARIFICATION]` marker anywhere in `spec.md` blocks stage 4+. Resolve via `/speckit.clarify` or the user/channel.
- CRITICAL findings from `/speckit.analyze` block the merge — dispatch fixes to workers, re-analyze.
- Every completed loop ends in §10 compound: the run report's `splits` section should grade how well `tasks.md`'s `[P]` markers predicted real independence — feed misses back as a `/speckit.tasks` prompt hint next run.

#### 11.4 When NOT to SDD

- Trivial fix / typo / config tweak → just do it (or `gsd`-style quick path). Specs for one-liners are ceremony.
- Repo has no `.specify/` and the user wants speed → offer onboarding once, don't force it.
- Exploration/spike work ("try X, see if it works") → spike first, spec what survives.

---

## Integrations

Installing an integration drops a lifecycle hook into that agent's config dir so herdr gets **authoritative** state (and session identity for restore) instead of guessing from the screen.
```bash
herdr integration status [--outdated-only]      # what's installed / outdated
herdr integration install droid                 # add a hook
herdr integration uninstall droid
```
Agents: `pi omp claude codex copilot droid kimi opencode kilo hermes qodercli cursor`. After upstream herdr updates, re-run `integration status` and reinstall any `outdated`.

## Socket API (direct, for events & scripting)

Newline-delimited JSON over `~/.config/herdr/herdr.sock`. Request `{"id","method","params"}` → `{"id","result"}` or `{"id","error"}`.
```bash
printf '%s\n' '{"id":"1","method":"ping","params":{}}' | nc -U ~/.config/herdr/herdr.sock
```
Most useful for **event-driven** orchestration (react the instant an agent blocks) rather than polling:
```json
{"id":"sub","method":"events.subscribe","params":{"subscriptions":[{"type":"pane.agent_status_changed","agent_status":"blocked"}]}}
```
Methods mirror the CLI: `agent.*`, `pane.*` (incl. `pane.report_agent`, `pane.wait_for_output`), `workspace.*`, `tab.*`, `worktree.*`, `events.subscribe`/`events.wait`, `notification.show`. Full list + payload shapes: [reference.md](reference.md).

## Reporting custom agents

To make a process herdr doesn't natively detect show up with managed lifecycle state, report it yourself (use a unique `--source`):
```bash
herdr pane report-agent <pane_id> --source custom:mytool --agent mytool --state working --message "indexing"
herdr pane report-agent <pane_id> --source custom:mytool --agent mytool --state idle
herdr pane release-agent <pane_id> --source custom:mytool --agent mytool   # relinquish authority
```

## Gotchas & safety

- **Never run bare `herdr`** non-interactively (TUI attach → hang). Use subcommands.
- **`agent start` argv[0] must be the binary** — `-- --some-flag` fails with "No viable candidates found in PATH". Always `-- "$(command -v claude)" --flags…`. The agent *name* (`claude`) only selects the integration/label, not the binary.
- **`agent start` result shape** — the pane id is at `.result.agent.pane_id` (not `.result.pane_id`).
- **First run in a new cwd may block on the folder-trust prompt** ("Do you trust the files in this folder?"). Watch for early `blocked`, read the visible screen, send Enter to accept — it's safe for worktrees you just created.
- **Protect `$SELF`** — see §2. Don't send keys to, attach-takeover, or close your own pane; don't `herdr server stop` while orchestrating from inside.
- **Timeouts are milliseconds** (`--timeout 600000` = 10 min). macOS has no `timeout(1)`; rely on herdr's own `wait`/`--timeout` flags, or `gtimeout` if coreutils is installed.
- **`send` ≠ submit** — `agent send`/`pane send-text` write literal text; you must send `Enter` separately. `pane run` includes Enter.
- **`blocked` is strict** — herdr only flags `blocked` on a recognized approval/question/permission UI; an agent stuck for other reasons may read as `working`. Cross-check with `pane read --source visible`.
- **Heuristic vs authoritative** — agents without an installed integration are detected from the screen and can misreport. Prefer installing the integration for any agent you orchestrate heavily.
- **Worktree isolation** prevents parallel agents from clobbering each other's working tree; default root `~/.herdr/worktrees/<repo>/<branch-slug>`.
- Use a stable, namespaced `--source` (e.g. `orchestrator:<task>`) whenever you report agent/metadata, so you can later `release-agent` cleanly.

## Quick reference

| Goal | Command |
|------|---------|
| Fleet state | `herdr agent list \| jq '.result.agents'` |
| Spawn | `herdr agent start <name> --cwd P --no-focus -- "$(command -v <bin>)" <flags>` |
| Dispatch | `herdr agent send <t> "…"` then `herdr pane send-keys <p> Enter` |
| Deliverables | file protocol: prompt file → one-line pointer → `wait output --match <sentinel>` → read answer file (§4) |
| Wait done | `herdr agent wait <t> --status idle --timeout MS` |
| Wait needs-me | `herdr agent wait <t> --status blocked --timeout MS` |
| Read output | `herdr agent read <t> --source recent --lines N` |
| Unblock | read visible → `herdr pane send-keys <p> Enter` |
| Worktree | `herdr worktree create --cwd P --branch B --base main` |
| Notify | `herdr notification show "T" --body "B" --sound done` |
| Integrations | `herdr integration status` |
| Channel intent → herd | re-read intent → clarify if needed → write `/tmp/herd-plan.md` → `worktree create` per slice → `agent start codex --no-focus` per slice → subscribe/poll `agent_status_changed` → unblock → converge → review → post summary on channel |
| Review before report | spawn reviewer agents on the integration branch (one lens each) → fix P1s → carry P2/P3 into the summary (§9.5) |
| Compound a run | write `~/.herdr/runs/<date>-<slug>.md` with a `next time` line → store gist in fleet memory → recurring lessons become PRs to this skill (§10) |
| Onboard the factory | `./scripts/onboard.sh` — choose claude/hermes orchestrator, install spec-kit, `specify init` the repo (§11.0) |
| SDD factory loop | `/speckit.specify` → `/speckit.clarify` → `/speckit.plan` → `/speckit.tasks` → herd the `[P]` tasks (§11.2) → `/speckit.analyze` → converge vs `spec.md` → compound (§11) |
| Which orchestrator? | `cat ~/.config/herdr-factory/config.toml` |

Full CLI + socket reference: [reference.md](reference.md).
