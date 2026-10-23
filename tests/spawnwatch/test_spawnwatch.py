#!/usr/bin/env python3
"""Offline tests for herd-spawn.sh, herd-limits, herd-watch and herd-recover (docs/herd-flow-v2.md §4).

Everything runs in a temp dir: HOME, the herd, the worktrees and the herdr/gh/lage/herd-board/claude stubs
(tests/spawnwatch/fakes) come first on a PATH that excludes ~/.local/bin, so no live herdr server, no GitHub
and no lage index is ever touched.

  python3 tests/spawnwatch/test_spawnwatch.py [-v] [-k Limits|Spawn|Watch|Recover]
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
import uuid

HERE = os.path.dirname(os.path.realpath(__file__))
SCRIPTS = os.path.normpath(os.path.join(HERE, "..", "..", "scripts"))
FAKES = os.path.join(HERE, "fakes")
sys.path.insert(0, SCRIPTS)
sys.dont_write_bytecode = True
import herd_events as he  # noqa: E402

ANCHOR = "w1:p1"


def rd(p):
    with open(p, encoding="utf-8") as f:
        return f.read()


def wr(p, text):
    with open(p, "w", encoding="utf-8") as f:
        f.write(text)


def system_path():
    """Dirs of the real tools the scripts need, never ~/.local/bin (live herd tools, lage)."""
    local = os.path.expanduser("~/.local/bin")
    dirs = []
    for tool in ("python3", "jq", "git", "bash", "sed", "flock", "realpath", "env", "grep"):
        p = shutil.which(tool, path=os.pathsep.join(d for d in os.environ["PATH"].split(os.pathsep) if d != local))
        if p and os.path.dirname(p) not in dirs:
            dirs.append(os.path.dirname(p))
    return os.pathsep.join([FAKES] + dirs)


class Base(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="spawnwatch-")
        self.home = os.path.join(self.root, "home")
        self.herd = os.path.join(self.root, "herd")
        self.wtroot = os.path.join(self.root, "wt")
        for d in (self.home, self.herd, self.wtroot):
            os.makedirs(d)
        self.meminfo = os.path.join(self.root, "meminfo")
        self.loadavg = os.path.join(self.root, "loadavg")
        self.set_machine(16000, 1.0)
        self.state = os.path.join(self.root, "herdr.json")
        self.herdr({"tabs": [{"tab_id": "w1:t1", "workspace_id": "w1", "label": "orch"}],
                    "panes": [{"pane_id": ANCHOR, "tab_id": "w1:t1", "scroll": {"viewport_rows": 50}}],
                    "agents": [{"pane_id": ANCHOR, "tab_id": "w1:t1", "agent_status": "working",
                                "agent_session": {"value": "orch-session"}}]})
        self.env = {
            "PATH": system_path(), "HOME": self.home, "LANG": "C.UTF-8", "PYTHONDONTWRITEBYTECODE": "1",
            "FAKE_HERDR_STATE": self.state, "FAKE_HERDR_LOG": os.path.join(self.root, "herdr.log"),
            "FAKE_GH_LOG": os.path.join(self.root, "gh.log"), "FAKE_GH_PRS": os.path.join(self.root, "prs.json"),
            "FAKE_TOOL_LOG": os.path.join(self.root, "tools.log"),
            "HERD_LIMITS_MEMINFO": self.meminfo, "HERD_LIMITS_LOADAVG": self.loadavg,
            "HERD_WT_ROOT": self.wtroot, "HERD_ANCHOR": ANCHOR, "HERD_MAX_LOAD": "10",
            "HERD_STATE_DIR": os.path.join(self.root, "state"),
        }

    def tearDown(self):
        shutil.rmtree(self.root, ignore_errors=True)

    # --- fixtures -------------------------------------------------------------------------------------------------
    def set_machine(self, free_mb, load):
        wr(self.meminfo, f"MemTotal: 32000000 kB\nMemAvailable: {free_mb * 1024} kB\n")
        wr(self.loadavg, f"{load} 1.0 1.0 1/100 1234\n")

    def herdr(self, st=None):
        if st is None:
            return json.loads(rd(self.state))
        wr(self.state, json.dumps(st))

    def herdr_calls(self):
        try:
            return [json.loads(l) for l in rd(self.env["FAKE_HERDR_LOG"]).splitlines()]
        except OSError:
            return []

    def add_herde(self, workers):
        """tab herde with panes [(pane, rows, status or None)]."""
        st = self.herdr()
        st["tabs"].append({"tab_id": "w1:t2", "workspace_id": "w1", "label": "herde"})
        for pane, rows, status in workers:
            st["panes"].append({"pane_id": pane, "tab_id": "w1:t2", "scroll": {"viewport_rows": rows}})
            if status:
                st["agents"].append({"pane_id": pane, "tab_id": "w1:t2", "agent_status": status,
                                     "agent_session": {"value": ""}})
        self.herdr(st)

    def slice(self, s, header="", repos=("api",), wt=True):
        wr(os.path.join(self.herd, f"{s}.task.md"), f"{header}\n# Task {s}\n\nDo it.\n")
        wr(os.path.join(self.herd, f"{s}.repos"), 
            "".join(f"{r} feat/{s} origin/main\n" for r in repos))
        if wt:
            for r in repos:
                os.makedirs(os.path.join(self.wtroot, r, s), exist_ok=True)

    def phase(self, s, *phases, **fields):
        for p in phases:
            he.append(self.herd, s, p, **(fields if p == phases[-1] else {}))

    def run_script(self, name, *args, env=None):
        e = dict(self.env, **(env or {}))
        return subprocess.run([os.path.join(SCRIPTS, name), *args], capture_output=True, text=True, env=e, timeout=120)


class LimitsTest(Base):
    def test_counts_working_and_blocked_in_herde_only(self):
        self.add_herde([("w1:p2", 30, "working"), ("w1:p3", 30, "blocked"), ("w1:p4", 30, "idle"),
                        ("w1:p5", 30, "done")])
        st = self.herdr()
        st["tabs"].append({"tab_id": "w2:t1", "workspace_id": "w2", "label": "herde"})
        st["agents"].append({"pane_id": "w2:p1", "tab_id": "w2:t1", "agent_status": "working"})
        self.herdr(st)
        r = self.run_script("herd-limits", self.herd, "--json")
        self.assertEqual(r.returncode, 0, r.stderr)
        d = json.loads(r.stdout)
        self.assertEqual((d["workers"], d["used"], d["max"]), (2, 2, 6))
        r = self.run_script("herd-limits", self.herd, env={"HERD_MAX_SLOTS": "2"})
        self.assertEqual(r.returncode, 1)
        self.assertIn("slots 2/2", r.stdout)
        self.assertIn("no slot: all 2 slots used", r.stdout)

    def test_limits_env_file_and_env_precedence(self):
        self.add_herde([("w1:p2", 30, "working")])
        wr(os.path.join(self.herd, "limits.env"), "export HERD_MAX_SLOTS=1  # tight\nHERD_MIN_FREE_MB='100'\n")
        r = self.run_script("herd-limits", self.herd)
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("(min 100)", r.stdout)
        r = self.run_script("herd-limits", self.herd, env={"HERD_MAX_SLOTS": "3"})
        self.assertEqual(r.returncode, 0, r.stdout)

    def test_memory_and_load(self):
        self.set_machine(5000, 12.5)
        r = self.run_script("herd-limits", self.herd)
        self.assertEqual(r.returncode, 1)
        self.assertIn("only 5000 MB free (min 8000)", r.stdout)
        self.assertIn("load 12.50 >= 10.0", r.stdout)

    def test_default_load_is_cores_times_2_5(self):
        e = dict(self.env)
        del e["HERD_MAX_LOAD"]
        r = subprocess.run([os.path.join(SCRIPTS, "herd-limits"), "--json"], capture_output=True, text=True, env=e)
        self.assertEqual(json.loads(r.stdout)["max_load"], round((os.cpu_count() or 1) * 2.5, 1))

    def test_review_agents_from_board_registry(self):
        reg = os.path.join(self.home, ".cache", "herd-board", "w1_p1.agents")
        wdir = os.path.join(self.root, "wf_1")
        os.makedirs(reg)
        os.makedirs(wdir)
        with open(os.path.join(wdir, "journal.jsonl"), "w") as f:
            for aid, typ in (("a1", "started"), ("a2", "started"), ("a3", "started"), ("a2", "result")):
                f.write(json.dumps({"type": typ, "agentId": aid}) + "\n")
        for aid in ("a1", "a2", "a3"):
            wr(os.path.join(wdir, f"agent-{aid}.jsonl"), "{}\n")
        old = time.time() - 3600
        os.utime(os.path.join(wdir, "agent-a3.jsonl"), (old, old))   # stale: not counted
        wr(os.path.join(reg, "wf_1"), f"wf review\n{wdir}\n")
        wr(os.path.join(reg, "sub1"), "subagent\n/nonexistent.jsonl\n")   # plain subagent: ignored
        d = json.loads(self.run_script("herd-limits", "--json").stdout)
        self.assertEqual((d["review"], d["used"]), (1, 1))
        shutil.rmtree(reg)
        wr(reg, "4\n")
        r = self.run_script("herd-limits", "--plus", "1")
        self.assertIn("slots 5/6 (4 review)", r.stdout)

    def test_herdr_down_is_no_slot(self):
        st = self.herdr()
        st["fail"] = ["tab list"]
        self.herdr(st)
        r = self.run_script("herd-limits")
        self.assertEqual(r.returncode, 2)
        self.assertIn("cannot measure", r.stderr)

    def test_help(self):
        r = self.run_script("herd-limits", "--help")
        self.assertEqual(r.returncode, 0)
        self.assertIn("HERD_MAX_SLOTS", r.stdout)


class SpawnTest(Base):
    def spawn(self, s, *args, env=None):
        return self.run_script("herd-spawn.sh", self.herd, s, *args,
                               env=dict({"HERD_GIT_NAME": "Herd Bot", "HERD_GIT_EMAIL": "bot@example.org"}, **(env or {})))

    def runs(self):
        return [c for c in self.herdr_calls() if c[:2] == ["pane", "run"]]

    def test_first_worker_creates_herde_tab_and_records_event(self):
        self.slice("alpha", "tickets: 1\nmodel: claude-fable-5-1\neffort: xhigh", repos=("api", "ui"))
        wr(os.path.join(self.herd, "COMMON.md"), "rules\n")
        r = self.spawn("alpha")
        self.assertEqual(r.returncode, 0, r.stderr)
        calls = self.herdr_calls()
        split = next(c for c in calls if c[:2] == ["pane", "split"])
        self.assertEqual(split[split.index("--pane") + 1], ANCHOR)
        self.assertIn(["pane", "move", "w1:p11", "--new-tab"], calls)
        self.assertTrue(any(c[:2] == ["tab", "rename"] and c[3] == "herde" for c in calls))
        self.assertIn(["agent", "focus", ANCHOR], calls)
        ev = he.last(self.herd, "alpha")
        self.assertEqual((ev["phase"], ev["by"], ev["pane"], ev["model"], ev["effort"]),
                         ("working", "orchestrator", "w1:p11", "claude-fable-5-1", "xhigh"))
        self.assertEqual(ev["wt"], [os.path.join(self.wtroot, "api", "alpha"), os.path.join(self.wtroot, "ui", "alpha")])
        uuid.UUID(ev["session_id"], version=4)
        line = self.runs()[0][3]
        self.assertIn(f"claude --session-id {ev['session_id']} --model claude-fable-5-1 --effort xhigh --permission-mode auto", line)
        self.assertIn("GIT_AUTHOR_NAME=Herd\\ Bot GIT_COMMITTER_NAME=Herd\\ Bot", line)
        self.assertIn("GIT_AUTHOR_EMAIL=bot@example.org", line)
        self.assertIn("unset ANTHROPIC_API_KEY", line)
        self.assertIn("COMMON.md", line)
        self.assertNotIn("Mariusz", line)
        reg = rd(os.path.join(self.home, ".cache", "herd-board", "w1_p1.herds")).split()
        self.assertEqual(reg, [self.herd])
        self.assertIn("herd-board --open --anchor w1:p1", rd(self.env["FAKE_TOOL_LOG"]))
        self.assertFalse(os.path.exists(os.path.join(self.herd, "herd.map")))
        self.assertFalse(os.path.exists(os.path.join(self.herd, "active.txt")))

    def test_defaults_and_ctx_prompt(self):
        self.slice("beta")
        wr(os.path.join(self.herd, "beta.ctx.worker.md"), "ctx\n")
        self.assertEqual(self.spawn("beta").returncode, 0)
        ev = he.last(self.herd, "beta")
        self.assertEqual((ev["model"], ev["effort"]), ("claude-opus-5-5", "high"))
        self.assertIn("beta.ctx.worker.md", self.runs()[0][3])

    def test_splits_tallest_pane_down_then_right(self):
        self.add_herde([("w1:p2", 20, "working"), ("w1:p3", 30, "working")])
        self.slice("gamma")
        self.assertEqual(self.spawn("gamma").returncode, 0)
        split = next(c for c in self.herdr_calls() if c[:2] == ["pane", "split"])
        self.assertEqual((split[split.index("--pane") + 1], split[split.index("--direction") + 1]), ("w1:p3", "down"))
        st = self.herdr()
        for p in st["panes"]:
            if p["tab_id"] == "w1:t2":
                p["scroll"]["viewport_rows"] = 20
        self.herdr(st)
        self.slice("delta")
        self.assertEqual(self.spawn("delta").returncode, 0)
        split = [c for c in self.herdr_calls() if c[:2] == ["pane", "split"]][-1]
        self.assertEqual(split[split.index("--direction") + 1], "right")
        self.assertFalse(any(c[:2] == ["pane", "move"] for c in self.herdr_calls()))

    def test_refuses_without_slot(self):
        self.slice("eps")
        r = self.spawn("eps", env={"HERD_MAX_SLOTS": "0"})
        self.assertEqual(r.returncode, 3)
        self.assertIn("no slot for eps", r.stderr)
        self.assertIn("all 0 slots used", r.stderr)
        self.assertIsNone(he.last(self.herd, "eps"))
        self.assertFalse(self.runs())
        self.assertEqual(self.spawn("eps", "--no-limits", env={"HERD_MAX_SLOTS": "0"}).returncode, 0)

    def test_refuses_bad_transition_and_bad_input(self):
        self.slice("zeta")
        self.phase("zeta", "working", "accepted", "review_running", "review_ok")
        r = self.spawn("zeta")
        self.assertEqual(r.returncode, 1)
        self.assertIn("review_ok -> working is not allowed", r.stderr)
        self.slice("eta", "effort: turbo")
        self.assertIn("bad effort", self.spawn("eta").stderr)
        self.slice("theta", wt=False)
        r = self.spawn("theta")
        self.assertIn("worktree", r.stderr)
        self.assertEqual(r.returncode, 1)
        wr(os.path.join(self.herd, "iota.task.md"), "x\n")
        self.assertIn("iota.repos missing", self.spawn("iota").stderr)
        self.assertFalse(self.runs())

    def test_setup_hook_creates_missing_worktree(self):
        self.slice("kappa", wt=False)
        hook = os.path.join(self.root, "setup.sh")
        wr(hook, f'#!/usr/bin/env bash\nmkdir -p "{self.wtroot}/$1/$2"; echo "$@" > "{self.root}/setup.args"\n')
        os.chmod(hook, 0o755)
        r = self.spawn("kappa", env={"HERD_SETUP": hook})
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(rd(os.path.join(self.root, "setup.args")).split(),
                         ["api", "kappa", "feat/kappa", "origin/main"])

    def test_resume_fix_queued_in_new_pane(self):
        self.slice("lam")
        sid = str(uuid.uuid4())
        self.phase("lam", "working", pane="w1:p9", session_id=sid)
        self.phase("lam", "accepted", "review_running", "review_befund")
        self.phase("lam", "fix_queued", befunde_file="lam.befunde-abc1234.md")
        r = self.spawn("lam", "--resume", env={"HERD_SPAWN_BY": "watch"})
        self.assertEqual(r.returncode, 0, r.stderr)
        line = self.runs()[0][3]
        self.assertIn(f"claude --resume {sid} --model claude-opus-5-5 --effort high", line)
        self.assertIn(os.path.join(self.herd, "lam.befunde-abc1234.md"), line)
        ev = he.last(self.herd, "lam")
        self.assertEqual((ev["phase"], ev["session_id"], ev["by"]), ("working", sid, "watch"))
        self.assertIn("fix round", ev["note"])

    def test_resume_prompts_live_idle_pane(self):
        self.add_herde([("w1:p2", 40, None)])
        sid = str(uuid.uuid4())
        st = self.herdr()
        st["agents"].append({"pane_id": "w1:p2", "tab_id": "w1:t2", "agent_status": "idle",
                             "agent_session": {"value": sid}})
        self.herdr(st)
        self.slice("mu")
        self.phase("mu", "working", pane="w1:p2", session_id=sid)
        self.phase("mu", "accepted", "review_running", "review_befund")
        self.phase("mu", "fix_queued", befunde_file="/abs/mu.befunde.md")
        r = self.spawn("mu", "--resume")
        self.assertEqual(r.returncode, 0, r.stderr)
        calls = self.herdr_calls()
        prompt = next(c for c in calls if c[:2] == ["agent", "prompt"])
        self.assertEqual(prompt[2], "w1:p2")
        self.assertIn("/abs/mu.befunde.md", prompt[3])
        self.assertFalse(any(c[:2] in (["pane", "split"], ["pane", "run"]) for c in calls))
        self.assertEqual(he.last(self.herd, "mu")["pane"], "w1:p2")

    def test_resume_refuses_running_and_without_session(self):
        self.add_herde([("w1:p2", 40, "working")])
        self.slice("nu")
        self.phase("nu", "working", pane="w1:p2", session_id="")
        self.phase("nu", "accepted")
        self.assertIn("no session_id recorded", self.spawn("nu", "--resume").stderr)
        self.slice("xi")
        self.phase("xi", "working", pane="w1:p2", session_id=str(uuid.uuid4()))
        self.phase("xi", "parked", reason="test")
        self.assertIn("still working in w1:p2", self.spawn("xi", "--resume").stderr)

    def test_resume_bare_shell_pane_runs_in_place(self):
        self.add_herde([("w1:p2", 40, None)])
        self.slice("omi")
        sid = str(uuid.uuid4())
        self.phase("omi", "working", pane="w1:p2", session_id=sid)
        self.phase("omi", "parked", reason="crash")
        r = self.spawn("omi", "--resume", env={"HERD_RESUME": "Restart note."})
        self.assertEqual(r.returncode, 0, r.stderr)
        run = self.runs()[0]
        self.assertEqual(run[2], "w1:p2")
        self.assertIn(f"--resume {sid}", run[3])
        self.assertIn("Restart\\ note.", run[3])

    def test_pane_run_failure_closes_pane_and_writes_nothing(self):
        self.slice("pi")
        st = self.herdr()
        st["fail"] = ["pane run"]
        self.herdr(st)
        r = self.spawn("pi")
        self.assertEqual(r.returncode, 4)
        self.assertIsNone(he.last(self.herd, "pi"))
        self.assertTrue(any(c[:2] == ["pane", "close"] for c in self.herdr_calls()))

    def test_help(self):
        r = self.run_script("herd-spawn.sh", "--help")
        self.assertEqual(r.returncode, 0)
        self.assertIn("HERD_GIT_NAME", r.stdout)


class WatchTest(Base):
    def setUp(self):
        super().setUp()
        self.env["HERD_ORCH_PANE"] = ANCHOR
        self.env["HERD_WATCH_GRACE"] = "0"

    def tick(self, env=None):
        r = self.run_script("herd-watch", self.herd, "--once", env=env)
        self.assertEqual(r.returncode, 0, r.stderr)
        return r.stdout

    def prompts(self):
        return [c for c in self.herdr_calls() if c[:2] == ["agent", "prompt"] and c[2] == ANCHOR]

    def test_fix_queued_starts_before_queued_one_per_tick(self):
        self.slice("aa")
        self.phase("aa", "queued", pos=1)
        self.slice("bb")
        sid = str(uuid.uuid4())
        self.phase("bb", "working", pane="w1:p77", session_id=sid)
        self.phase("bb", "accepted", "review_running", "review_befund")
        self.phase("bb", "fix_queued", befunde_file="bb.befunde-1234567.md")
        out = self.tick()
        self.assertIn("STARTED bb (fix_queued, resume)", out)
        self.assertEqual(he.last(self.herd, "aa")["phase"], "queued")
        bb = he.last(self.herd, "bb")
        self.assertEqual((bb["phase"], bb["session_id"], bb["by"]), ("working", sid, "watch"))
        self.tick()
        self.assertEqual(he.last(self.herd, "aa")["phase"], "working")

    def test_queue_order_by_pos(self):
        for s, pos in (("cc", 2), ("dd", 1)):
            self.slice(s)
            self.phase(s, "queued", pos=pos)
        self.tick()
        self.assertEqual((he.last(self.herd, "dd")["phase"], he.last(self.herd, "cc")["phase"]), ("working", "queued"))

    def test_stacked_on_waits_for_accepted_base(self):
        self.slice("base")
        self.phase("base", "working", pane="w1:p1", session_id="x")   # alive: the anchor pane
        self.slice("child", "stacked_on: base")
        self.phase("child", "queued")
        out = self.tick()
        self.assertIn("WAITING child: base base is working, needs at least accepted", out)
        self.assertEqual(he.last(self.herd, "child")["phase"], "queued")
        self.phase("base", "accepted")
        self.tick()
        self.assertEqual(he.last(self.herd, "child")["phase"], "working")

    def test_failed_start_stays_queued_and_retries(self):
        self.slice("ee")
        self.phase("ee", "queued")
        st = self.herdr()
        st["fail"] = ["pane run"]
        self.herdr(st)
        out = self.tick()
        self.assertIn("START FAILED ee", out)
        self.assertEqual(he.last(self.herd, "ee")["phase"], "queued")
        self.assertIn("START FAILED ee", rd(os.path.join(self.herd, "watch.log")))
        st = self.herdr()
        self.assertFalse([t for t in st["tabs"] if t["label"] == "herde"])   # the failed pane was closed
        st["fail"] = []
        self.herdr(st)
        out = self.tick()
        self.assertEqual(he.last(self.herd, "ee")["phase"], "working", out)

    def test_empty_herde_tab_is_not_split(self):
        self.slice("ef")
        self.phase("ef", "queued")
        st = self.herdr()
        st["tabs"].append({"tab_id": "w1:t2", "workspace_id": "w1", "label": "herde"})   # no panes left in it
        self.herdr(st)
        self.assertIn("STARTED ef", self.tick())

    def test_broken_head_does_not_block_queue(self):
        self.slice("ff", wt=False)
        self.phase("ff", "queued", pos=1)
        self.slice("gg")
        self.phase("gg", "queued", pos=2)
        out = self.tick()
        self.assertIn("START FAILED ff", out)
        self.assertEqual((he.last(self.herd, "ff")["phase"], he.last(self.herd, "gg")["phase"]), ("queued", "working"))

    def test_no_slot_waits(self):
        self.slice("hh")
        self.phase("hh", "queued")
        out = self.tick(env={"HERD_MAX_SLOTS": "0"})
        self.assertIn("WAITING hh: slots 0/0", out)
        self.assertEqual(he.last(self.herd, "hh")["phase"], "queued")

    def test_queued_with_history_resumes(self):
        self.slice("ii")
        sid = str(uuid.uuid4())
        self.phase("ii", "working", pane="w1:p55", session_id=sid)
        self.phase("ii", "parked", reason="crash")
        self.phase("ii", "queued")
        self.assertIn("STARTED ii (queued, resume)", self.tick())
        self.assertEqual(he.last(self.herd, "ii")["session_id"], sid)

    def live_worker(self, s, status):
        self.add_herde([("w1:p2", 40, status)])
        self.slice(s)
        self.phase(s, "working", pane="w1:p2", session_id="sess", wt=[os.path.join(self.wtroot, "api", s)])

    def set_status(self, status):
        st = self.herdr()
        for a in st["agents"]:
            if a["pane_id"] == "w1:p2":
                a["agent_status"] = status
        self.herdr(st)

    def test_reported_wakes_once_and_done_counts(self):
        self.live_worker("jj", "working")
        wr(os.path.join(self.herd, "jj.out.md"), "report\n")
        self.tick()
        self.assertEqual(self.prompts(), [])          # still working: not reported
        self.set_status("done")
        self.tick()
        self.tick()
        p = self.prompts()
        self.assertEqual(len(p), 1)
        self.assertIn("jj reported", p[0][3])

    def test_old_report_of_previous_round_is_not_reported(self):
        wr(os.path.join(self.herd, "kk.out.md"), "old\n")
        old = time.time() - 3600
        os.utime(os.path.join(self.herd, "kk.out.md"), (old, old))
        self.live_worker("kk", "idle")
        self.tick()
        self.assertEqual(self.prompts(), [])

    def test_blocked_wakes_once_per_episode(self):
        self.live_worker("ll", "blocked")
        self.tick()
        self.tick()
        self.assertEqual(len(self.prompts()), 1)
        self.set_status("working")
        self.tick()
        self.set_status("blocked")
        self.tick()
        self.assertEqual(len(self.prompts()), 2)
        self.assertIn("ll blocked", self.prompts()[1][3])

    def test_gone_wakes_once_and_not_when_herdr_down(self):
        self.slice("mm")
        self.phase("mm", "working", pane="w1:p99", session_id="s")
        st = self.herdr()
        st["fail"] = ["agent list"]
        self.herdr(st)
        out = self.tick()
        self.assertIn("herdr unreadable", out)
        self.assertEqual(self.prompts(), [])
        st["fail"] = []
        self.herdr(st)
        self.tick()
        self.tick()
        self.assertEqual(len(self.prompts()), 1)
        self.assertIn("mm gone", self.prompts()[0][3])

    def test_without_orch_pane_only_logs(self):
        self.live_worker("nn", "blocked")
        out = self.tick(env={"HERD_ORCH_PANE": ""})
        self.assertIn("HERD_ORCH_PANE unset", out)
        self.assertFalse(any(c[:2] == ["agent", "prompt"] for c in self.herdr_calls()))

    def test_failed_wake_is_retried(self):
        self.live_worker("oo", "blocked")
        st = self.herdr()
        st["fail"] = ["agent prompt"]
        self.herdr(st)
        self.assertIn("WAKE FAILED", self.tick())
        st = self.herdr()
        st["fail"] = []
        self.herdr(st)
        self.assertIn("BLOCKED oo: woke", self.tick())

    def test_long_running_and_single_instance(self):
        p = subprocess.Popen([os.path.join(SCRIPTS, "herd-watch"), self.herd, "--interval", "0.2"],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=self.env)
        try:
            time.sleep(1.5)
            self.assertIsNone(p.poll(), "herd-watch exited on its own")
            r = self.run_script("herd-watch", self.herd, "--once")
            self.assertEqual(r.returncode, 3)
            self.assertIn("already watches", r.stderr)
        finally:
            p.terminate()
            p.wait(timeout=10)

    def test_help(self):
        self.assertIn("fix_queued", self.run_script("herd-watch", "--help").stdout)


class RecoverTest(Base):
    def git(self, *a, cwd=None):
        subprocess.run(["git", *a], cwd=cwd, check=True, capture_output=True,
                       env=dict(self.env, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@t", GIT_COMMITTER_NAME="t",
                                GIT_COMMITTER_EMAIL="t@t"))

    def prs(self, d):
        wr(self.env["FAKE_GH_PRS"], json.dumps(d))

    def v1_herd(self):
        h = self.herd
        for s in ("done1", "live1", "queued1", "paused1", "signed1", "fresh1"):
            self.slice(s, "model: claude-fable-5-1" if s == "signed1" else "")
        wr(os.path.join(h, "herd.map"), "done1=w1:p20\nlive1=w1:p2\nsigned1=w1:p21\npaused1=w1:p22\n"
                                                    "live1=w1:p2\n")
        wr(os.path.join(h, "active.txt"), "live1\npaused1\n")
        wr(os.path.join(h, "done.txt"), "done1\nsigned1\n")
        wr(os.path.join(h, "queue.txt"), "queued1\npaused1\n")
        wr(os.path.join(h, "live1.started"), "1792698366\n")
        wr(os.path.join(h, "done1.out.md"), "r\n")
        wr(os.path.join(h, "done1.status.json"), json.dumps({"pr": "api #12"}))
        wr(os.path.join(h, "signed1.freigabe"), 
            "acme/api #210 6cb1f804f415745b2db41910d9340cfb7645c64d\nacme/ui #86 eb59eb70c7cd67423409397cd139f1a9f10cbfa1\n")
        cache = os.path.join(self.home, ".cache", "herd-board")
        os.makedirs(cache)
        wr(os.path.join(cache, "review-state.json"), json.dumps({"api#210": "ok"}))
        # transcript of live1's worktree names its session
        tdir = os.path.join(self.home, ".claude", "projects",
                            os.path.join(self.wtroot, "api", "live1").replace("/", "-").replace(".", "-"))
        os.makedirs(tdir)
        wr(os.path.join(tdir, "11111111-2222-4333-8444-555555555555.jsonl"), "{}\n")
        self.add_herde([("w1:p2", 40, None)])   # live1: bare shell left, its TUI died
        self.prs({"acme/api#210": {"state": "MERGED", "headRefOid": "6cb1f80", "mergeCommit": {"oid": "abcdef0123"}},
                  "acme/ui#86": {"state": "MERGED", "headRefOid": "eb59eb7", "mergeCommit": {"oid": "1234567890"}},
                  "cwd:done1#12": {"state": "OPEN", "headRefOid": "ffff"}})

    def test_migrates_v1_herd(self):
        self.v1_herd()
        r = self.run_script("herd-recover", self.herd)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        st = he.state(self.herd)
        evs = he.read(self.herd)
        self.assertTrue(all(e["by"] == "recover" for e in evs))
        self.assertEqual(st["queued1"]["phase"], "queued")
        self.assertEqual(st["queued1"]["pos"], 1)
        self.assertEqual(st["paused1"]["history"], ["working", "parked", "queued"])
        self.assertEqual(st["done1"]["phase"], "working")       # reported is computed by the board
        self.assertIn("done.txt", st["done1"]["note"])
        self.assertEqual(st["signed1"]["history"], ["working", "review_ok", "merged"])
        self.assertEqual(st["signed1"]["prs"], ["api#210@abcdef0", "ui#86@1234567"])
        self.assertEqual(st["signed1"]["v1_review"], {"api#210": "ok"})
        ok = next(e for e in evs if e["slice"] == "signed1" and e["phase"] == "review_ok")
        self.assertEqual(ok["prs"][0], "api#210@6cb1f804f415745b2db41910d9340cfb7645c64d")
        self.assertEqual(ok["forced_from"], "working")
        w = next(e for e in evs if e["slice"] == "signed1" and e["phase"] == "working")
        self.assertEqual((w["model"], w["pane"]), ("claude-fable-5-1", "w1:p21"))
        live = [e for e in evs if e["slice"] == "live1"]
        self.assertEqual(live[0]["session_id"], "11111111-2222-4333-8444-555555555555")
        self.assertEqual(live[0]["started_at"], "2026-10-22T19:46:06Z")   # epoch 1792698366
        # live1's TUI died (bare shell): reconcile parks and re-queues it for a resume
        self.assertEqual([e["phase"] for e in live], ["working", "parked", "queued"])
        self.assertNotIn("fresh1", st)
        self.assertIn("fresh1: task only", r.stdout)
        # v1 files stay, a second run does not migrate again
        self.assertTrue(os.path.exists(os.path.join(self.herd, "herd.map")))
        n = len(evs)
        r2 = self.run_script("herd-recover", self.herd)
        self.assertIn("already holds events", r2.stdout)
        self.assertEqual(len(he.read(self.herd)), n)

    def test_dry_run_writes_nothing(self):
        self.v1_herd()
        r = self.run_script("herd-recover", self.herd, "--dry-run")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("would write signed1: review_ok -> merged", r.stdout)
        self.assertIn("would write live1: working -> parked", r.stdout)
        self.assertEqual(he.read(self.herd), [])

    def test_no_gh_skips_github(self):
        self.v1_herd()
        r = self.run_script("herd-recover", self.herd, "--no-gh")
        self.assertEqual(r.returncode, 0)
        self.assertEqual(he.last(self.herd, "signed1")["phase"], "review_ok")
        self.assertFalse(os.path.exists(self.env["FAKE_GH_LOG"]))

    def test_reconcile_v2_herd(self):
        self.add_herde([("w1:p2", 40, "working")])
        for s in ("alive", "dead", "nosess", "reported", "ok", "closed", "rr"):
            self.slice(s)
        self.phase("alive", "working", pane="w1:p2", session_id="a")
        self.phase("dead", "working", pane="w1:p50", session_id="d")
        self.phase("nosess", "working", pane="w1:p51")
        self.phase("reported", "working", pane="w1:p52", session_id="r")
        wr(os.path.join(self.herd, "reported.out.md"), "x\n")
        self.phase("ok", "working", "accepted", "review_running")
        self.phase("ok", "review_ok", prs=["api#5@aaaaaaa"], main=["api@bbbb"])
        self.phase("closed", "working", "accepted")
        self.phase("closed", "accepted", force=True, note="t", prs=["api#6@ccccccc"])
        self.phase("rr", "working", "accepted", "review_running")
        self.prs({"acme/api#5": {"state": "MERGED", "mergeCommit": {"oid": "9876543210"}},
                  "acme/api#6": {"state": "CLOSED"}})
        r = self.run_script("herd-recover", self.herd, env={"HERD_BOARD_ORG": "acme"})
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        st = he.state(self.herd)
        self.assertEqual(st["alive"]["phase"], "working")
        self.assertEqual(st["dead"]["history"][-2:], ["parked", "queued"])
        self.assertEqual(st["nosess"]["phase"], "parked")
        self.assertIn("no session_id recorded", r.stdout)
        self.assertEqual(st["reported"]["phase"], "working")
        self.assertEqual((st["ok"]["phase"], st["ok"]["prs"]), ("merged", ["api#5@9876543"]))
        self.assertNotIn("forced_from", st["ok"])
        self.assertEqual(st["closed"]["phase"], "accepted")
        self.assertIn("CLOSED without merge", r.stdout)
        self.assertIn("rr: review_running since", r.stdout)

    def test_empty_git_objects(self):
        src = os.path.join(self.root, "src", "api")
        os.makedirs(src)
        self.git("init", "-q", "-b", "main", cwd=src)
        wr(os.path.join(src, "f"), "x\n")
        self.git("add", "f", cwd=src)
        self.git("commit", "-qm", "init", cwd=src)
        self.slice("gitty", wt=False)
        os.makedirs(os.path.join(self.wtroot, "api"))
        self.git("worktree", "add", "-q", "-b", "feat/gitty", os.path.join(self.wtroot, "api", "gitty"), cwd=src)
        r = self.run_script("herd-recover", self.herd)
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertIn("api: ok", r.stdout)
        os.makedirs(os.path.join(src, ".git", "objects", "ab"), exist_ok=True)
        wr(os.path.join(src, ".git", "objects", "ab", "cdef0123456789"), "")
        r = self.run_script("herd-recover", self.herd)
        self.assertEqual(r.returncode, 1)
        self.assertIn("api: 1 EMPTY object file(s)", r.stdout)
        self.assertIn("ab/cdef0123456789", r.stdout)

    def test_board_hint_and_open(self):
        r = self.run_script("herd-recover", self.herd)
        self.assertIn("herd-board --open --anchor w1:p1", r.stdout)
        r = self.run_script("herd-recover", self.herd, "--open-board")
        self.assertIn("herd-board --open --anchor w1:p1", rd(self.env["FAKE_TOOL_LOG"]))
        reg = os.path.join(self.home, ".cache", "herd-board", "w1_p1.herds")
        self.assertEqual(rd(reg).split(), [self.herd])

    def test_help(self):
        self.assertIn("migration", self.run_script("herd-recover", "--help").stdout.lower())


if __name__ == "__main__":
    unittest.main()
