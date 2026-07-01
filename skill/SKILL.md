---
name: herdr
version: 2.2.0
description: Orchestrate a fleet of AI coding agents through herdr — the terminal workspace manager (workspaces → tabs → panes) running on this machine. Spawn agents, dispatch work, watch lifecycle state (idle/working/blocked), unblock approval prompts, fan out and converge multi-agent work, and manage agent integrations. Trigger when the user mentions herdr, "the fleet", "orchestrate agents", "spawn an agent", "what are my agents doing", panes/workspaces/worktrees, herdr integrations, or wants an agent to drive other coding agents (claude/codex/cursor/opencode/etc.) running in herdr. ALSO trigger when an intent arrives over a chat channel (Mattermost, Discord, Slack, etc.) and the right response is to spin up a parallel herdr "herd" of codex (or mixed) workers to achieve the goal — understand the intent first, then fan out concurrent workers, converge results, and report back on the same channel. ALSO trigger for spec-driven development (SDD) — when the user mentions spec-kit, /speckit.* commands, "factory loop", "SDD", spec→plan→tasks→implement, or wants to onboard the factory (choose Claude Code, Hermes, or Cursor as orchestrator). ALSO trigger for meta-orchestration — when the user wants to be the "meta-orchestrator" / "orchestrator of orchestrators", oversee or launch multiple orchestrators (each driving its own herd of workers) across several missions/repos, or drive a portfolio of parallel missions with /goal-based autonomy (fleet-loop.sh / fleet-control). ALSO trigger for m2herd — the Claude Code (Fable) main-orchestrator context fabric — when the user mentions m2herd, .m2herd, "context fabric", wants to offload context into the repo folder (the folder holds the context, the orchestrator holds pointers), refile or archive notes/areas, push a project gist to fleet memory, or come back to a project via the resume file (RESUME.md).
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
`agent send` writes **literal text** (no submit). To submit a prompt to a TUI agent, send the text, **let it settle (~1s), then** press Enter:
```bash
herdr agent send <target> "Refactor the auth module. Report back when done."
sleep 1   # let the TUI render the text into its input box first
herdr pane send-keys <pane_id> Enter
```
> **Settle before Enter.** A TUI (claude/codex) needs a beat to render injected text
> into its input box. Fire the Enter back-to-back and it races the text: it submits an
> empty line and the prompt is left sitting in the input, **unsubmitted** — the classic
> "typed but never sent" bug. Always pause between the text and the Enter, and re-send on
> the next reconcile tick if the agent is still idle.
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
sleep 1   # settle so the Enter doesn't race the text injection
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
6. Decide the **worker agent type**. Default to `codex` (good at long-running, focused coding tasks, and it's installed in this fleet). Mix in `claude` for tasks needing broader context, or `cursor` for IDE-style edits and codebase-aware refactors — only when there's a clear reason. Each maps to a herdr integration name and a binary+auto-approve flag:

   | worker | `agent start <name>` | argv |
   |--------|----------------------|------|
   | codex  | `codex`  | `"$(command -v codex)" --dangerously-bypass-approvals-and-sandbox` |
   | claude | `claude` | `"$(command -v claude)" --dangerously-skip-permissions` |
   | cursor | `cursor` | `"$(command -v cursor-agent)" --force` |

   (`cursor-agent --force` = run the Cursor agent TUI auto-approving all commands — the cursor analog of claude's `--dangerously-skip-permissions`. herdr's `cursor` integration is installed, so cursor panes report authoritative lifecycle state like any other agent.)
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
  # 2. spawn worker, do NOT take focus. Swap codex for claude/cursor per the
  #    §9.1-step-6 table — e.g. cursor: agent start cursor -- "$(command -v cursor-agent)" --force
  PANE=$(herdr agent start codex --cwd "$WT" --split right --no-focus -- \
           "$(command -v codex)" --dangerously-bypass-approvals-and-sandbox \
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
It (1) picks **Claude Code, Hermes, or Cursor** (or `all`) as the orchestrator, (2) verifies herdr/jq/git, (3) installs this skill for the chosen agent, (4) installs the `specify` CLI (`uv tool install specify-cli --from git+https://github.com/github/spec-kit.git`), (5) runs `specify init --here` in the target repo, and (6) records the choice in `~/.config/herdr-factory/config.toml`.

Integration mapping: **claude** → `specify init --here --integration claude` (prompts land in `.claude/commands/speckit.*.md`); **cursor** → `specify init --here --integration cursor` (spec-kit-native; prompts in `.cursor/commands/`); **hermes** → `specify init --here --integration generic --integration-options="--commands-dir .hermes/commands/"` (same prompts, in `.hermes/commands/`). The `all` choice initializes the claude integration (Hermes also reads `.claude/commands/*.md`; for Cursor's own command palette re-run `specify init --here --integration cursor`). Older spec-kit builds use `--ai` instead of `--integration` — onboard.sh detects this. Check the active orchestrator any time: `cat ~/.config/herdr-factory/config.toml`.

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
  # swap codex for claude/cursor per the §9.1-step-6 table when a task suits a different worker
  PANE=$(herdr agent start codex --cwd "$WT" --no-focus -- \
           "$(command -v codex)" --dangerously-bypass-approvals-and-sandbox \
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

### 12. ICM-steered orchestration loop

Everything above (§9 herd, §11 SDD) is orchestration you drive by hand or in one bash run.
§12 makes that orchestration **a standing, steerable, disk-reconstructible loop** by adopting
the Interpretable Context Methodology (ICM): the folder is the orchestrator's state, herdr is
its body, and a reconciliation loop keeps them in sync.

The model is a controller: **the folder is desired state, the herdr socket is observed state,
the loop computes the diff and acts.** ICM contributes the inspectable on-disk state that an
ad-hoc herd (`/tmp/herd.map`) lacks; herdr contributes the live execution + lifecycle that ICM
(a passive protocol) lacks. The extended state is:

```
OrchestratorState = AGENT.md + ROUTER.md + active stage CONTEXT.md + declared refs/inputs
                  + FleetObservation (_fleet/agents.json)   ← written every tick
                  + DispatchLedger    (_fleet/ledger.tsv)    ← slice → pane → branch → status
```

#### 12.1 The workspace
`templates/herd-control/` is the scaffold. Layers: `AGENT.md` (0, identity, loaded every tick),
`ROUTER.md` (1, routing by task type **and** fleet state), `stages/NN_*/CONTEXT.md` (2, contracts
— Inputs/Process/Outputs/Verify + a machine-parseable `mode`/`gate`/`deliverable`/`handoff` block),
`_config/`+`shared/` (3, stable reference), `_fleet/`+`stages/*/output/`+`inbox/` (4, working).
Stages: `01_spec→02_plan→03_tasks→04_implement→05_analyze→06_converge`. `04_implement` is
**fanout** (one worker per `slices.tsv` row, in worktrees); the rest are **solo** (you run the
Process — e.g. a `/speckit.*` step — and the loop checks the deliverable + gates).

#### 12.2 The loop
```bash
scripts/herd-loop.sh init --ws ~/herd/<feature> --repo /path/to/repo --base main
scripts/herd-loop.sh tick   --ws ~/herd/<feature>     # one reconciliation pass
scripts/herd-loop.sh run    --ws ~/herd/<feature>     # standing loop
scripts/herd-loop.sh status --ws ~/herd/<feature>
```
Each `tick`: observe fleet → drain `inbox/STEER.md` → for the active stage, spawn missing
workers / collect finished ones / auto-approve routine blocks (`_config/approve_allow.txt`) or
escalate the rest to `stages/<stage>/review/` (`approve_deny.txt` wins) → evaluate exit criteria
→ gate. It does the **mechanical** work and escalates **judgment** via its `STATUS:` line
(`AWAITING_SOLO`, `RECONCILED`, `NEEDS_REVIEW`, `STAGE_COMPLETE`, `ADVANCED`, `DONE`) — the
orchestrator (you, or Hermes) reacts to that line. See `AGENT.md` for the status→action table.

#### 12.3 Steering
Because all state is on disk, you steer by editing files, not interrupting a process. Drop a
command into `inbox/STEER.md` and the loop drains it next tick: `PAUSE` / `RESUME` /
`KILL <slice>` / `RESCOPE <slice>` (after editing its `prompts/<slice>.md`) / `GOTO <stage>` /
`NOTE <text>`. Read `_fleet/ledger.tsv` + `agents.json` to see the whole fleet as herdr sees it.

Discipline (ICM's anti-drift): per-tick context stays tiny — identity + router + active contract
+ `_fleet` + declared inputs, nothing else. Parallelism lives *inside* the fanout stage, not
across stages. Mechanical work is the script's; judgment is the orchestrator's.

### 13. Meta-orchestration — the orchestrator of orchestrators

§12 makes ONE orchestrator a standing, disk-reconstructible loop driving WORKERS for one
feature. §13 adds a tier ABOVE it: a **meta-orchestrator** that launches and oversees
**orchestrators**, each of which drives its own herd. Three tiers, same ICM reconciler at each:

```
meta-orchestrator   fleet-loop.sh  over  templates/fleet-control/   ← reconciles MISSIONS (orchestrators)
  └ orchestrator    herd-loop.sh   over  templates/herd-control/    ← reconciles SLICES (workers)   [§12]
      └ workers      codex / claude / cursor in worktrees                                            [§3,§9]
```

**Use when** the work is a *portfolio* of ≥2 **independent missions** — different repos, or
disjoint services/features in one repo — each big enough to deserve its own orchestrator (its
own spec→plan→tasks→implement→converge). One feature in one repo → don't meta-orchestrate; run
a single orchestrator (§12). A single small change → just do it (§9.7).

#### 13.1 The `/goal` hook — autonomy all the way down

The meta-orchestrator's primitive is **`/goal`**: a session **Stop hook** that blocks an agent
from stopping until a stated condition holds, re-prompting it to keep working. `fleet-loop.sh`
**arms each orchestrator's `/goal`** to its mission's `done_when` (by typing the slash command
into the orchestrator's TUI), so the orchestrator self-drives its herd and the meta only
re-engages when it goes `blocked` or `done`. You (the meta) run under your own `/goal` set to
the fleet's overall done condition. **Hooks all the way down: meta-goal → orchestrator-goals →
workers.** Not every agent supports `/goal` (claude ✅, codex ✅, cursor ❌) — non-goal agents
degrade to a per-tick re-nudge. See `templates/fleet-control/shared/goal_support.md`.

#### 13.2 The workspace + loop

`templates/fleet-control/` mirrors `herd-control/` one level up: `FLEET.md` (L0 meta identity),
`ROUTER.md` (L1), `missions.tsv` (the desired orchestrator set — `mission  orchestrator  repo
intent  done_when`), `goals/<mission>.md` (each orchestrator's generated charter+goal),
`stages/01_dispatch` (**fanout**: launch + oversee one orchestrator per mission) and
`stages/02_converge` (**solo**: integrate across missions + meta run report), `_config/`
(launch / approval / gate policies + `goal_support.txt`), `_fleet/` (observed: `agents.json`,
`missions.ledger.tsv`), `inbox/STEER.md` (live steering).

```bash
scripts/fleet-loop.sh init   --ws ~/fleet/<name> [--worker claude]   # scaffold
# fill ~/fleet/<name>/missions.tsv — one row per INDEPENDENT mission
scripts/fleet-loop.sh tick   --ws ~/fleet/<name>     # one reconciliation pass
scripts/fleet-loop.sh run    --ws ~/fleet/<name>     # standing loop
scripts/fleet-loop.sh status --ws ~/fleet/<name>
```

Each `tick`: observe fleet → drain `inbox/STEER.md` → launch an orchestrator per missing mission
(in its repo, scaffold its herd-control workspace, **arm `/goal`**) → refresh each mission's
status from the orchestrator's pane **and** its `herd-control/_fleet/active_stage == DONE` (the
cross-tier completion signal) → auto-approve routine orchestrator blocks (`_config/approve_allow.txt`)
or escalate the rest to `stages/<stage>/review/` → collect finished missions → gate. It does the
**mechanical** work and escalates **judgment** via its `STATUS:` line (`AWAITING_SOLO`,
`RECONCILED`, `NEEDS_REVIEW`, `MISSION_COMPLETE`, `ADVANCED`, `DONE`) — you react per `FLEET.md`.

#### 13.3 Discipline (same ICM rules, one tier up)

- The meta never reaches two levels down: it sends work to **orchestrators**, never to a
  mission's **workers**; an orchestrator never reasons about another mission. Results flow up via
  `output/`, escalations via `review/`, autonomy down via `/goal`.
- One orchestrator per mission; parallelism lives **across missions** (the meta fanout) — each
  mission's internal `[P]` parallelism belongs to its orchestrator.
- Completion is a **disk** signal (`active_stage == DONE`), not "the TUI looks idle".
- Cross-mission merges to `main` / prod deploys are escalated to the human even when a single
  mission's orchestrator was authorized for its own scope (`_config/gate_policy.md`).

### 14. Default-on dispatch nudge — hooks for Claude Code + Hermes

§9.1–§13 tell *you* when to consider herding. §14 makes that check happen automatically, on
every turn, so the user doesn't have to say "herdr" first — without ever removing the human
confirmation gate before anything gets spawned.

**What it is.** `hooks/herdr-dispatch-nudge.sh`, installed by `scripts/install.sh` and wired into:

| Platform | Event | Registered in |
|----------|-------|----------------|
| Claude Code | `UserPromptSubmit` (fires every turn) | `~/.claude/settings.json` → `.hooks.UserPromptSubmit` |
| Hermes | `pre_llm_call` (fires every turn — Hermes's `UserPromptSubmit` equivalent) | `~/.hermes/config.yaml` → `hooks.pre_llm_call` |
| Cursor | — | not installed; Cursor has no shell-hook mechanism (see `shared/goal_support.md`) |

Both events support context injection. The script discards its stdin payload and always returns
the same short reminder — it does not parse the prompt or make any decision itself:

> herdr: before starting multi-part or channel-relayed work, check whether it decomposes into
> ≥2 independent slices (different files/services/features) — see the herdr skill Sections 9
> (herd), 11 (SDD), 13 (meta-orchestration). If it does, propose a short plan (slices, base
> branch, worker count/type) and get explicit user/channel confirmation BEFORE spawning any
> herdr agent, worktree, or branch. Never auto-spawn workers without that confirmation. Trivial
> or single-file asks: just do the work inline, no herd.

**Why a hook and not a heuristic in the hook itself.** A deterministic script cannot judge
decomposability — that's still the model's job, informed by §9.1–§13. The hook's only role is
to make sure the model re-runs that judgment every turn instead of only when a user happens to
say "herdr" or "spawn workers". The confirm-before-spawn rule (§9.1 step 7, §9.7) is unchanged
and non-negotiable: this hook widens *when* the herd question gets asked, never *who* answers it.

**Install.** On by default for claude/hermes targets:
```bash
./scripts/install.sh                 # installs skill + nudge hook for claude, hermes, cursor
./scripts/install.sh --no-nudge-hook # skip the hook, skill only
./scripts/install.sh --uninstall     # removes both the skill symlink and the hook registration
```
Idempotent (dedupes by command string) and non-destructive — a timestamped `.bak-<ts>` copy of
`settings.json`/`config.yaml` is written before every edit. Requires `jq` (Claude) and
[`yq`](https://github.com/mikefarah/yq) v4 (Hermes); if either is missing, the hook file is still
symlinked in but registration is skipped with a warning (wire it up by hand from the table above).

**Hermes non-interactive gotcha.** Hermes's shell-hook consent model prompts on first use and
persists the decision — but non-interactive runs (gateway, cron, channel-driven work, exactly
the §9 "intent arrives over a chat channel" case this hook is meant to help with) can't answer
that prompt. Set one of `--accept-hooks`, `HERMES_ACCEPT_HOOKS=1`, or `hooks_auto_accept: true`
in `config.yaml`, or the hook silently never fires there.

### 15. Context budgeting & the decomposer

§12 makes the folder the orchestrator's state; §13 stacks a tier above it. Both assume the
orchestrator's **live context window** can hold identity + router + active contract + `_fleet` +
declared inputs. On a long run that assumption breaks: spec/plan/tasks, worker outputs, ledger
state, and screen reads accumulate until the model truncates and starts dropping constraints and
file links. §15 adds a **context-budget layer** to the ICM factory so the orchestrator (typically
Hermes) **stays within a known token budget** and **holds its working knowledge as file links in
the folder** rather than in live context. The doctrine is one line: **the folder holds the
context, the orchestrator holds pointers.** It extends the §12 model — the folder is still desired
state — with a budget the loop and the hooks both respect.

#### 15.1 The budget setting

Every workspace declares a model and a token budget in `herd.conf`, defaulting to **GLM-5.2** with
a **384000**-token window. `herd-loop.sh init` writes `MODEL=GLM-5.2` and `BUDGET=384000` (override
with `--model NAME` / `--budget N`). The decomposer and both hooks resolve the budget in the same
order, so live detection can refine the default without editing every file:

```
herd.conf MODEL/BUDGET  →  ~/.hermes/config.yaml model.context_length  →  default GLM-5.2 / 384000
```

`scripts/context-budget.sh detect --ws WS` prints the resolved `MODEL`, `BUDGET`, and `SOURCE=`
(so the resolution is debuggable), machine-readable as `KEY=VALUE` lines.

#### 15.2 The decomposer — `scripts/context-budget.sh`

The engine is a mechanical, idempotent bash tool (same style as `herd-loop.sh`) with four
subcommands:

```bash
scripts/context-budget.sh detect  --ws WS                       # MODEL / BUDGET / SOURCE
scripts/context-budget.sh status  --ws WS                       # live usage vs budget (bridge file)
scripts/context-budget.sh plan    --ws WS --intent FILE [--fraction 0.25]
scripts/context-budget.sh pointer --ws WS --stage S --slice X
```

`plan` is the decomposer proper. It reads the intent's declared slices (or the `[P]` rows of
`stages/03_tasks/output/tasks.md`) and, for each slice, writes a **per-slice context manifest** at
`stages/<stage>/context/<slice>.md`. The manifest is **links only** — relative file paths with a
one-line purpose each, never inlined bodies (inlining is exactly what fills the window). Each
manifest carries a byte/token-estimate header (`tokens ≈ ceil(bytes / 4)`, matching
`hermes prompt-size`) and is sized to fit a fraction of the budget — **default `BUDGET × 0.25`**.
An oversized slice is **flagged (`fits: NO`), not silently emitted**, so decomposition failures
surface instead of hiding. `status` reads the live bridge file
(`/tmp/claude-ctx-<session>.json`) to report `USED_PCT` / `REMAINING_PCT` against `BUDGET`;
`pointer` regenerates one slice's manifest after a §12.3 `RESCOPE` or an edit. `herd-loop.sh
gen_prompt` then points each worker at its manifest ("Read your context manifest: <path>") instead
of hard-coding a file list into the prompt — the §11.2/§9.2 dispatch pattern, but the context is a
pointer, not a payload.

#### 15.3 The Hermes hooks — awareness + restructure on demand

Two hooks keep a running orchestrator inside the budget without a human watching the gauge:

- **`hooks/herdr-context-budget.js`** — a Hermes **PostToolUse** hook (Node, modeled on
  `gsd-context-monitor.js`: stdin JSON → `{hookSpecificOutput:{additionalContext}}`, stdin timeout
  guard, silent-fail, `session_id` path-traversal guard). It reads the live bridge file plus the
  resolved `BUDGET` and, when usage crosses **WARNING 60% / HIGH 75% / CRITICAL 85%** (debounced,
  severity-escalation bypasses the debounce), injects an advisory telling the orchestrator to
  offload. On **HIGH/CRITICAL** it also **spills** a compact `_fleet/context_pointer.md` — active
  stage, a short ledger digest, and links to each slice's distilled `context.md` — so the
  orchestrator can drop raw history and reload its working set from the pointer. The spill is
  idempotent (one per threshold crossing). It never blocks a tool.
- **`hooks/herdr-context-session.sh`** — a **SessionStart** hook (bash, modeled on
  `gsd-session-state.sh`). When the cwd (or `$HERD_WS`) has a `herd.conf`, it prints an
  `additionalContext` line stating `MODEL`/`BUDGET` and surfaces `_fleet/context_pointer.md` if one
  exists — so a resumed or re-spawned orchestrator starts already inside its budget and already
  pointed at the folder's distilled context.

This is the offload doctrine in motion: the hooks watch usage, the decomposer's manifests are the
distilled context on disk, and the spill re-points the orchestrator at the folder the moment the
window gets tight. Thresholds and the offload doctrine are documented as L3 reference in
[`_config/budget_policy.md`](templates/herd-control/_config/budget_policy.md); the budget-awareness
constraint is also a global bullet in `AGENT.md` so it loads every tick.

#### 15.4 Self-installer & onboarding

`scripts/install-hermes-context.sh` wires the hooks into `~/.hermes/`: it copies
`hooks/*.{js,sh}` into `~/.hermes/hooks/` (chmod +x), `jq`-merges a PostToolUse entry (for the
budget hook) and a SessionStart entry (for the session hook) into `~/.hermes/settings.json` keyed
by command string (re-running adds nothing), sets the GLM-5.2 / 384k default in
`~/.hermes/config.yaml`, and verifies with `hermes hooks doctor`. It **backs up** `settings.json`
and `config.yaml` before touching them, only edits `context_length` (never rewrites the file), and
supports `--dry-run` and `--uninstall`. Onboarding (§11.0) runs it automatically when the chosen
orchestrator is `hermes` or `all`, and `scripts/install.sh --hermes` runs it too — so a Hermes
factory gets the budget layer wired without a separate step.

#### 15.5 Dynamic compression — lossy live window, lossless folder

§15.1–14.4 make the orchestrator budget-*aware* and spill a state pointer. §15.5 adds true
**dynamic compression** on top, with a strict **division of labor** — nothing summarizes the same
bytes twice, and no summary is ever the only copy:

- **Hermes' native compressor compresses the LIVE window, lossily.** Its `~/.hermes/config.yaml`
  `compression:` block (`enabled: true`, `threshold: 0.5` — compress at 50% of the window;
  `target_ratio: 0.2` — down to 20%; `protect_first_n` / `protect_last_n` — keep the head and the
  recent tail verbatim) replaces raw history with LLM summaries in place. This is on by default; we
  only *tune* it to the budget — we do **not** replace it with our own live-window summarizer.
- **The folder holds the lossless deep-dives.** Worker outputs (`stages/*/output/<slice>.out`) and
  the slice manifests (`stages/*/context/<slice>.md`) stay on disk in full, so after Hermes lossily
  compresses the window the orchestrator can reload the *exact* content from the folder. Lossy in
  the window, lossless on disk.
- **The rolling `_fleet/digest.md` bridges the two.** `herd-loop.sh collect_slice` runs
  `context-budget.sh summarize` on each finished worker's `.out` (its final "what I did / how I
  verified" report if present, else a head+tail heuristic — never a full-body copy, ≤6 lines) and
  appends `## <slice>` + that summary + a link back to `output/<slice>.out` to `_fleet/digest.md`
  (append-once per slice, idempotent). The **digest is the summary; the `.out` is the deep-dive** —
  the orchestrator reads the digest to stay oriented and follows the link only when it needs the
  full text. `context-budget.sh compact` regenerates `_fleet/context_pointer.md` as a rolling
  narrative (active stage + the digest + slice `context.md` links, links only) instead of a bare
  state digest.
- **Session-rotation on CRITICAL reboots the orchestrator from the pointer/digest.** When usage
  crosses **CRITICAL 85%**, the §15.3 hook also drops a `_fleet/.needs_rotation` sentinel; the
  `herd-loop.sh run` loop detects it and yields `STATUS: NEEDS_ROTATION` rather than looping on a
  full window. `herd-loop.sh rotate --ws WS` then starts a fresh orchestrator agent, sends it
  "resume from `_fleet/context_pointer.md` + `digest.md`" (the SessionStart hook orients it),
  retires the old pane, and clears the sentinel — enforced reorg by restart. It **refuses to close
  `$SELF`, the new pane, or an empty/unknown pane id**, and `--dry-run` prints the plan while
  spawning and closing nothing. To make rotation **automatic**, run the loop with
  `herd-loop.sh run --auto-rotate --orchestrator PANE [--max-rotations 5]`: on `NEEDS_ROTATION` it
  rotates in place and keeps ticking (capped against runaway; a refused rotate is contained and the
  loop yields to a human instead of crashing). Without `--auto-rotate` the loop yields as above.

Wiring: `context-budget.sh summarize|compact` produce the distilled summaries;
`install-hermes-context.sh --compression on|off` tunes (or disables) the `compression:` block to
budget-aligned values (idempotent, backed up, touches only those keys, `--dry-run` diffs). The
tiers and the lossy-live / lossless-folder contract are documented as L3 reference in
[`_config/budget_policy.md`](templates/herd-control/_config/budget_policy.md).

### 16. m2herd — the Fable main-orchestrator context fabric

§15 keeps a **Hermes** orchestrator inside a token budget over a `herd-control/` workspace.
§16 is the Claude-Code-native superset of the §12/§15 herd-control concepts: **Claude Code
(Fable) is the MAIN orchestrator**, and every repo it orchestrates carries a `.m2herd/`
context fabric at the repo root (gitignored). The base doctrine is one line: **the folder
holds the context, the orchestrator holds pointers.** The orchestrator keeps only the most
important things in its live window and offloads everything else into `.m2herd/`, from which
it can delegate any piece to herdr workers at will. The fabric is an **agentic loop — the
machine prompts itself from its own state**. Its doctrine pillars:

- **Living harness loop.** The folder is a living harness: the hooks are the heartbeat
  (SessionStart orients, PostToolUse watches the budget, PreCompact refiles before compaction
  eats notes), and **`m2herd next` is the pulse they inject** — every wake-up delivers
  orientation AND the next move, derived mechanically from the folder's own state. **Drift is
  an ERROR**: `m2herd.sh sync --check` exits **3** with a human-readable drift report when
  `overview.json` and the `context/` tree disagree (missing areas, orphan entries); plain
  `sync` repairs. Drift is case 1 of `next`, so a drifted fabric prompts its own repair.
- **The orchestrator is also the INTENT COACH.** A fuzzy goal is not dispatchable. The
  orchestrator's first job is to sharpen intent into `goal` + `done_when` + slices, recording
  what it cannot resolve as `open_questions` instead of guessing. An empty `done_when` means
  "intent not yet coached", and `next` refuses to move past it.
- **Read-only dashboard — one writer, many watchers.** The orchestrator is the only writer;
  every other pane is a watcher. `m2herd dashboard` is a pure renderer over existing state —
  no new state, no writes, ever — and it displays the same self-prompt the machine injects
  into itself (the `NEXT:` line is rendered from the same code path as `next`). Any future
  interactive tier may add navigation, never editing — watchers steer only by appending to
  `.m2herd/inbox/STEER.md`, which the orchestrator drains through the loop (§16.2).
- **Self-documentation.** Every refile IS the documentation act; nothing lives only in the
  live window. Offloading context and documenting the project are the same motion.
- **Memory tiers — division of labor.** `.m2herd/` is the PROJECT's working memory (files,
  links, state — things you point workers at). AMS (memory.machinemachine.ai) is the FLEET's
  recall (searchable gists, cross-project). `~/.claude` auto-memory is the orchestrator's own
  lessons. `.m2herd` never tries to be a vector store; AMS never holds file trees.
  `m2herd.sh gist [--push]` is the bridge between the tiers.
- **Decay discipline.** Living ≠ hoarding. `m2herd.sh archive --area A` distills a done area
  down to its header + a short summary while `deep/` stays lossless — the fabric stays small
  enough to stay true.

#### 16.1 The `.m2herd/` layout

`m2herd.sh init` scaffolds this from `templates/m2herd/` (seed files carry a `<!-- marker -->`
line separating template boilerplate from live content) and appends `.m2herd/` to the repo's
`.gitignore` — both idempotent:

```
.m2herd/
  overview.json               # central machine-readable index (goal, status, areas[], workers[])
  RESUME.md                   # come-back file: where we are, in-flight work, next 3 commands
  NOTES.md                    # central notes file (the machineroom pane live-views this)
  context/<area>/context.md   # distilled per-area context; annotation header below
  context/<area>/deep/        # lossless deep-dives (worker outputs, logs, transcripts)
  dispatch/<slice>.task.md    # worker task files (§4 file protocol)
  dispatch/<slice>.out.md     # worker answers
  inbox/STEER.md              # steering inbox: watchers/TUI keys APPEND below the marker; the orchestrator drains it via `next`
```

`overview.json` is the index the orchestrator navigates by: `goal`, `done_when` (the coached
completion condition — `init --goal` seeds it empty, and empty means "intent not yet coached"),
`open_questions[]` (what the intent coach could not resolve — recorded, never guessed),
`status` (`active|paused|done`), `updated_at`, `areas[]` (`name`/`path`/`summary`/`related`,
plus `status: "active"|"archived"`, default `"active"`), `workers[]` (slice → pane_id /
worktree / branch / `state: spawned|working|done|failed` / task / out; may be `[]`), and
`notes_file`/`resume_file` pointers. Writers always rewrite the whole file with jq — no sed
patching. Every `context/<area>/context.md` opens with the annotation header so the
orchestrator can hop between sibling areas without loading them:

```
---
area: <name>
related: [<other area names>]   # where to find the sibling pieces
deep: ./deep/                   # lossless material for this area
updated: <ISO-8601 UTC>
---
```

#### 16.2 The engine — `scripts/m2herd.sh`

Mechanical, idempotent bash (herd-loop.sh style); jq required. `--dir` defaults to `$PWD`.
install.sh symlinks it onto PATH as `m2herd` (§16.5).

```
m2herd.sh init   [--dir P] [--goal "…"]   # scaffold .m2herd/ from templates/m2herd/, gitignore it
m2herd.sh status [--dir P]                # render overview.json human-readably
m2herd.sh note   [--dir P] "text"         # append "- [<UTC ts>] text" to NOTES.md
m2herd.sh refile [--dir P] --area A       # create/refresh context/A/ (+header), move NOTES.md content below the marker into it, update overview.json
m2herd.sh resume [--dir P]                # print RESUME.md + one line per area from overview.json
m2herd.sh sync   [--dir P]                # regenerate overview.json areas[] from the context/ tree; refresh RESUME.md skeleton preserving hand-written notes
m2herd.sh sync   [--dir P] --check        # drift detector: exit 3 + human-readable report when overview.json and context/ disagree; plain sync repairs
m2herd.sh archive [--dir P] --area A      # decay: distill a done area's context.md to header + ≤10 summary lines (status: archived); deep/ stays lossless; overview.json entry gets "status":"archived"
m2herd.sh gist   [--dir P] [--push]       # one-paragraph project gist (goal, status, one line per active area); --push pipes it to $M2HERD_GIST_CMD if set (the --llm pattern), else prints it with a note
m2herd.sh next   [--dir P]                # self-prompting primitive: mechanical priority walk (NO LLM calls), prints exactly one line starting "NEXT: "
m2herd.sh dashboard [--dir P]             # read-only tier-1 TUI: a pure renderer over existing state — no new state, no writes, ever
m2herd.sh selftest                        # tmpdir end-to-end: init → note → refile → sync → status → resume (+ next cases, dashboard smoke); asserts schema fields with jq
```

`next` is the pulse of the agentic loop — it walks a fixed priority ladder and prints exactly
one `NEXT: ` line, so the machine always knows its next move without an LLM in the loop:

1. drift (`sync --check` logic fails) → `NEXT: context drift — run: m2herd sync`
2. non-empty content below the `inbox/STEER.md` marker → `NEXT: drain steering — read .m2herd/inbox/STEER.md, act, then clear below the marker`
3. `done_when` empty → `NEXT: coach the intent — set done_when + record open_questions`
4. loose content in NOTES.md below the marker → `NEXT: refile notes — run: m2herd refile --area <pick>`
5. a `workers[]` entry `spawned|working` whose pane is gone/idle → `NEXT: collect worker <slice> — run: m2herd-up collect --slice <slice>`
6. `open_questions` non-empty → `NEXT: resolve open question: <first>`
7. otherwise → `NEXT: compare RESUME.md against goal/done_when and dispatch or finish`

`dashboard` renders the reference layout, top to bottom: a boxed header line —
`m2herd · <repo-basename> ── ● <status> · drift ✓|◐` (the drift dot from the `sync --check`
logic) — then `goal` / `done_when` / `budget` rows (the budget row reads the newest
`/tmp/claude-ctx-*.json` bridge file: usage bar + "N% of BUDGET" + "updated <age> ago";
omitted when no bridge file exists); the `NEXT:` line (same code path as `next` — the
dashboard displays the same self-prompt the machine injects into itself); the AREAS and
WORKERS tables **side-by-side** when the tty is ≥100 columns, stacked otherwise; the OPEN
QUESTIONS list when non-empty; the last 5 content lines of NOTES.md below the marker; and a
static footer: `read-only · steering: .m2herd/inbox/STEER.md`. AREAS shows name,
active/archived status, per-area age from each context.md `updated:` header, and related
links — archived areas rendered dim on one line; **staleness ages make rot visible**: decay
discipline, rendered. WORKERS (when `workers[]` is non-empty) shows slice, branch, and
**desired vs observed** state: when `herdr` is on PATH the dashboard queries
`herdr agent list` ONCE per render and sets the desired `workers[].state` beside the observed
pane `agent_status`, marking mismatches with `!`; without herdr it degrades silently to
desired-only. herdr READS are allowed in a watcher pane; herdr writes/sends (`agent send`,
`pane send-keys`, spawns, closes) are FORBIDDEN there — the dashboard stays a renderer even
when it looks at the live fleet. Plain ASCII with tput colors on a tty, degrading to plain
when piped.

**Steering goes through the loop.** `init` also scaffolds `.m2herd/inbox/STEER.md`
(boilerplate + a `<!-- marker -->` line, the STEER.md pattern). Anything that wants to steer
the orchestrator — a human, a tier-3 TUI keypress — APPENDS below the marker; the orchestrator
drains it via `next`'s drain-steering case (read, act, clear below the marker). Nothing steers
by editing the state files directly. Tier roadmap (roadmap only — not built): tier 2 adds an
fswatch-triggered repaint; tier 3 a bubbletea/textual TUI with navigation — navigation yes,
editing no; its keys' only write is the STEER.md append above.

The daily loop: `note` whatever matters the moment it matters → `refile --area A` when a topic
has gathered enough notes (this is the documentation act) → `resume` when you come back →
`sync --check` when anything smells stale (exit 3 = drift; run `sync` to repair) →
`archive --area A` when an area is done → `gist --push` to publish the project's one-paragraph
state to fleet memory — or simply run `m2herd next` and do what it says, with `dashboard` open
in the watcher pane. `status`/`resume` show archived areas as a one-line footer, not full
entries.

#### 16.3 The workspace — `scripts/m2herd-up.sh`

The workspace shape is fixed: **exactly ONE orchestrator pane (claude) + ONE machineroom
pane** (tab label `machineroom`; pre-2.1.0 installs used `m2herd-notes`, still honored).
The machineroom pane runs `m2herd dashboard --watch` — the engine's built-in flicker-free
repaint loop (home-cursor redraw, tput colors, human-readable NOTES timestamps) that also
refreshes `m2herd self-update --check` every 10 minutes, so "N commit(s) behind" surfaces
in the dashboard header. Fallbacks when `m2herd` is absent: `watch -n 2 -t cat
.m2herd/NOTES.md`, else the `while :; do clear; cat …; sleep 2; done` loop.
The pane is a WATCHER, never a writer. On PATH as `m2herd-up`.

```
m2herd-up.sh up       [--repo P] [--goal "…"]      # ensure herdr workspace for repo: the one-orchestrator + one-machineroom shape; runs m2herd.sh init if missing
m2herd-up.sh dispatch --slice S [--repo P] [--base BRANCH] [--agent claude|codex|cursor]
                      [--headless [--model M]]      # worktree wip/m2herd-<S> off BASE (default: current branch), spawn worker, file-protocol dispatch of .m2herd/dispatch/S.task.md, record in overview.json workers[]
m2herd-up.sh collect  --slice S [--repo P]          # wait idle (pane) / exited (headless pid), keep/copy report to dispatch/S.out.md, update workers[] state (+tokens/cost)
m2herd-up.sh --dry-run <same args>                  # print every herdr/git command instead of running it
```

It follows the binding herdr rules from this skill: identify `$SELF` first and never touch it
(§2); after `agent start` RE-RESOLVE the pane by cwd from `herdr agent list` (the returned
pane_id can be off by one); no `--split` (stray-pane bug); settle ~1s between `agent send` and
Enter (§4).

**Headless dispatch — cheap hands, Fable judgment.** `dispatch --headless [--model M]` skips
the pane entirely: `claude -p <pointer> --model M --dangerously-skip-permissions
--output-format json` (default model **sonnet**; verified working on the Max plan) — or
`codex exec` / `opencode run` via `--agent` — nohup'd in the worktree. The runner's stdout
(usage JSON) lands in `dispatch/<S>.log`, the report in `dispatch/<S>.out.md` by instruction
(salvaged from the log's `.result` if the worker forgot). `collect` waits on the **pid**, not
a pane, and parses `outputTokens`/`costUSD` into `workers[]`; the dashboard WORKERS table
shows the runner + humanized spend (`sonnet 12k`). Cursor has no headless mode.

**Model-tier policy.** The orchestrator (Fable) spends tokens on *judgment only*: intent
coaching, contract writing, converge decisions, reviews of last resort. Everything else is
delegated down-tier: **sonnet** for standard implementation slices and review fan-outs,
**haiku / codex exec** for mechanical work (renames, doc sweeps, refiles, format fixes).
Default reviewers to sonnet explicitly. TUI panes are for slices that need mid-flight
steering; headless is the default for everything else.

#### 16.4 The three Claude Code hooks

The heartbeat of the living harness. All three key on `.m2herd/` presence in the cwd (or
`$M2HERD_DIR`), silent-fail, never block, and call `command -v m2herd`, degrading silently
when the engine isn't on PATH:

| Hook | Event | What it does |
|------|-------|--------------|
| `hooks/m2herd-session.sh` | `SessionStart` | Injects a digest — overview.json goal/status/areas count + first 30 lines of RESUME.md — as `{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext}}`, then appends the output of `m2herd next` (when the binary exists; bounded ~3s; silent-fail): every wake-up = orientation + the next move. bash + jq, bounded stdin read, always exit 0. |
| `hooks/m2herd-precompact.sh` | `PreCompact` | Injects `additionalContext` instructing the model to refresh RESUME.md + overview.json and refile loose NOTES.md content into `context/<area>/` BEFORE compaction proceeds — compaction never eats un-refiled notes. Keeps its own drift nudge (run `m2herd sync` when overview.json and context/ disagree). Never blocks (exit 0 always). |
| `hooks/m2herd-budget.js` | `PostToolUse` | The §15 budget watcher, natively for Claude Code: same bridge file (`/tmp/claude-ctx-<session>.json`), same 60/75/85% thresholds, debounce, and traversal guard as `herdr-context-budget.js` — but keyed on `.m2herd/` presence, and the advisory tells the orchestrator to offload into `.m2herd/context/<area>/` + refresh RESUME.md. `hookEventName` is ALWAYS `"PostToolUse"`. Silent-fail. |

#### 16.5 Install

Part of the **claude** target of `scripts/install.sh` (on by default):

```bash
./scripts/install.sh --claude            # skill + nudge hook + the three m2herd hooks + PATH symlinks
./scripts/install.sh --no-m2herd-hooks   # skip the m2herd hook registration (files still symlinked)
./scripts/install.sh --uninstall         # removes hook entries, hook symlinks, and PATH symlinks
```

It symlinks the three hook files into `~/.claude/hooks/`, registers them in
`~/.claude/settings.json` (`m2herd-session.sh` → `.hooks.SessionStart`,
`m2herd-precompact.sh` → `.hooks.PreCompact`, `m2herd-budget.js` → `.hooks.PostToolUse` with
matcher `Bash|Edit|Write|MultiEdit|Agent|Task`, all `timeout: 10`), and symlinks
`scripts/m2herd.sh` → `~/.local/bin/m2herd` and `scripts/m2herd-up.sh` → `~/.local/bin/m2herd-up`.
Idempotent — dedupe and uninstall are keyed on the hook FILENAME (not the full command string,
which embeds a node path that changes across upgrades); a timestamped `.bak-<ts>` copy of
`settings.json` is written before every edit; the `.js` hook is skipped with a warning when
`node` is missing (the two bash hooks still register). `./scripts/onboard.sh` wires all of
this in when the chosen orchestrator is claude (or `all`).

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
- **`send` ≠ submit, and Enter must not race the text** — `agent send`/`pane send-text` write literal text; you must send `Enter` separately. Settle ~1s between the text and the Enter so the TUI has rendered the input — fire them back-to-back and the Enter submits an empty line, leaving the prompt typed-but-unsubmitted. `pane run` includes Enter.
- **`blocked` is strict** — herdr only flags `blocked` on a recognized approval/question/permission UI; an agent stuck for other reasons may read as `working`. Cross-check with `pane read --source visible`.
- **Heuristic vs authoritative** — agents without an installed integration are detected from the screen and can misreport. Prefer installing the integration for any agent you orchestrate heavily.
- **Worktree isolation** prevents parallel agents from clobbering each other's working tree; default root `~/.herdr/worktrees/<repo>/<branch-slug>`.
- Use a stable, namespaced `--source` (e.g. `orchestrator:<task>`) whenever you report agent/metadata, so you can later `release-agent` cleanly.

## Quick reference

| Goal | Command |
|------|---------|
| Fleet state | `herdr agent list \| jq '.result.agents'` |
| Spawn | `herdr agent start <name> --cwd P --no-focus -- "$(command -v <bin>)" <flags>` |
| Dispatch | `herdr agent send <t> "…"` → `sleep 1` → `herdr pane send-keys <p> Enter` |
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
| Onboard the factory | `./scripts/onboard.sh` — choose claude/hermes/cursor orchestrator, install spec-kit, `specify init` the repo (§11.0) |
| ICM-steered loop | `scripts/herd-loop.sh init\|tick\|run\|status` over a `templates/herd-control/` workspace — folder=desired, socket=observed, loop reconciles (§12) |
| SDD factory loop | `/speckit.specify` → `/speckit.clarify` → `/speckit.plan` → `/speckit.tasks` → herd the `[P]` tasks (§11.2) → `/speckit.analyze` → converge vs `spec.md` → compound (§11) |
| Meta-orchestrate | `scripts/fleet-loop.sh init\|tick\|run\|status` over a `templates/fleet-control/` workspace — one orchestrator per mission in `missions.tsv`, each `/goal`-armed to self-drive its herd; meta launches/oversees/converges (§13) |
| Which orchestrator? | `cat ~/.config/herdr-factory/config.toml` |
| Dispatch nudge (hooks) | `./scripts/install.sh` wires `hooks/herdr-dispatch-nudge.sh` into Claude's `UserPromptSubmit` + Hermes's `pre_llm_call` — a per-turn reminder to consider herding, never an auto-spawn (§14) |
| m2herd context fabric | `m2herd init\|note\|refile\|resume\|sync --check\|archive\|gist --push\|next\|dashboard` over the repo's `.m2herd/`; `m2herd-up up\|dispatch\|collect` for the 1-orchestrator + 1-watcher-pane workspace (`watch -n 2 -t "m2herd dashboard"`) — folder holds the context, orchestrator holds pointers, `next` is the machine's own next move, the dashboard is read-only (§16) |

Full CLI + socket reference: [reference.md](reference.md).
