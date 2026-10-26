#!/usr/bin/env python3
"""m2herd-steer + hooks/m2herd-steer-gate.sh against a synthetic fabric (offline, temp HOME).

  python3 tests/steer/test_steer.py

The synthetic STEER.md mirrors the shapes a live fabric collected: a snapshot watcher re-posting
the same findings every run with changing counters, growing id lists, a subject whose status
changes and findings that drop out; an event-style watcher (one finding per line); human/TUI lines.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.realpath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", ".."))
STEER_BIN = os.path.join(REPO, "scripts", "m2herd-steer")
GATE = os.path.join(REPO, "hooks", "m2herd-steer-gate.sh")
MARKER = "<!-- === M2HERD:LIVE === -->"

W = "Reconcile-Watch"
HINT = ". Check: /srv/fabric/queue.sqlite3"


def snap(ts, *findings):
    return f"- {ts} {W}: " + "; ".join(findings) + HINT


IDS = ["5000000001", "5000000002", "5000000003", "5000000004"]
ENTRIES = [
    snap("2026-10-05T10:35:35+00:00", "111111111: old lane after 3 tries", "222222222: question/WAITING still open",
         "23 mentions still to check", "Open follow-up: " + IDS[0]),
    snap("2026-10-13T04:35:53+00:00", "111111111: old lane after 3 tries", "222222222: question/WAITING still open",
         "23 mentions still to check", "Open follow-up: " + ",".join(IDS[:3])),
    snap("2026-10-13T05:05:58+00:00", "111111111: old lane after 4 tries", "222222222: question/WAITING still open",
         "444444444:5000000009 NEEDS_HUMAN", "23 mentions still to check", "Open follow-up: " + ",".join(IDS[:3])),
    "- 2026-10-14T08:00:00Z ci-watch: PR #41 red on run 987654321",
    "- 2026-10-14T08:10:00Z ci-watch: PR #42 red on run 987654399",
    "- [2026-10-14T09:00:00Z] PAUSE the herd; rebase api first",
    snap("2026-10-14T10:05:29+00:00", "111111111: old lane after 4 tries", "222222222: tab gone; check queue",
         "444444444:5000000009 NEEDS_HUMAN", "25 mentions still to check", "Open follow-up: " + ",".join(IDS[:3])),
    "- 2026-10-14T11:00:00Z ci-watch: PR #43 red on run 987654444",
    snap("2026-10-15T06:05:30+00:00", "222222222: tab gone; check queue", "25 mentions still to check",
         "Open follow-up: " + ",".join(IDS[:3])),
    "- 2026-10-15T07:00:00Z ci-watch: PR #41 green on run 987654500",
    snap("2026-10-15T07:05:34+00:00", "222222222: tab gone; check queue", "25 mentions still to check",
         "Open follow-up: " + ",".join(IDS[:3])),
    "rebase the ui branch before the api\n  (continuation line of the same human note)",
]


def read(p):
    with open(p, encoding="utf-8") as f:
        return f.read()


def header():
    with open(os.path.join(REPO, "templates", "m2herd", "inbox", "STEER.md"), encoding="utf-8") as f:
        return f.read()


class Fabric:
    def __init__(self, entries=ENTRIES):
        self.tmp = tempfile.mkdtemp(prefix="steer-test-")
        self.root = os.path.join(self.tmp, "proj")
        self.m2 = os.path.join(self.root, ".m2herd")
        self.inbox = os.path.join(self.m2, "inbox")
        os.makedirs(self.inbox)
        self.home = os.path.join(self.tmp, "home")
        os.makedirs(self.home)
        self.steer = os.path.join(self.inbox, "STEER.md")
        self.ledger = os.path.join(self.inbox, "steer.ledger.jsonl")
        with open(self.steer, "w", encoding="utf-8") as f:
            f.write(header() + "".join(e + "\n" for e in entries))

    def env(self, **kw):
        env = {k: v for k, v in os.environ.items()
               if k not in ("M2HERD_DIR", "M2HERD_WORKER", "HERD_SLICE", "HERDR_PANE_ID", "M2HERD_STEER_GATE",
                            "M2HERD_STEER_NOW", "M2HERD_STEER_BIN", "M2HERD_STEER_STATE_DIR", "M2HERD_STEER_RATE")}
        env.update({"HOME": self.home, "PYTHONDONTWRITEBYTECODE": "1", "M2HERD_STEER_NOW": "2026-10-16T12:00:00Z",
                    "PATH": os.path.dirname(shutil.which("python3")) + ":/usr/bin:/bin"})
        env.update({k: v for k, v in kw.items() if v is not None})
        for k, v in kw.items():
            if v is None:
                env.pop(k, None)
        return env

    def run(self, *args, now=None, **env):
        e = self.env(**env)
        if now:
            e["M2HERD_STEER_NOW"] = now
        return subprocess.run([sys.executable, STEER_BIN, "--fabric", self.root] + list(args), cwd=self.root,
                              env=e, capture_output=True, text=True, timeout=60)

    def items(self, *flags, now=None):
        p = self.run("list", "--json", *flags, now=now)
        assert p.returncode == 0, p.stderr
        return json.loads(p.stdout)

    def by_text(self, data, needle):
        hits = [i for i in data["items"] if needle in i["text"]]
        assert len(hits) == 1, (needle, [i["text"] for i in hits])
        return hits[0]

    def append(self, line):
        with open(self.steer, "a", encoding="utf-8") as f:
            f.write(line + "\n")

    def gate(self, payload, *args, now=None, **env):
        e = self.env(**env)
        if now:
            e["M2HERD_STEER_NOW"] = now
        data = payload if isinstance(payload, (bytes, str)) else json.dumps(payload)
        return subprocess.run(["bash", GATE] + list(args), input=data if isinstance(data, bytes) else data.encode(),
                              cwd=self.root, env=e, capture_output=True, timeout=60)

    def close(self):
        shutil.rmtree(self.tmp, ignore_errors=True)


class Base(unittest.TestCase):
    def setUp(self):
        self.f = Fabric()

    def tearDown(self):
        self.f.close()


class Intake(Base):
    def test_dedupe_and_counts(self):
        d = self.f.items("--all")
        self.assertEqual(d["entries"], len(ENTRIES))
        mentions = self.f.by_text(d, "mentions still to check")
        self.assertEqual(mentions["count"], 6, "23 -> 25 is a counter, not a new item")
        self.assertEqual(mentions["first"], "2026-10-05T10:35:35Z")
        self.assertEqual(mentions["last"], "2026-10-15T07:05:34Z")
        lane = self.f.by_text(d, "old lane")
        self.assertEqual(lane["count"], 4, "3 tries -> 4 tries keeps the key")
        follow = self.f.by_text(d, "Open follow-up")
        self.assertEqual(follow["count"], 6, "a growing id list is one item")
        self.assertEqual(follow["ids"], IDS[:3])
        self.assertEqual(follow["hint"], "Check: /srv/fabric/queue.sqlite3")
        # 6 snapshot findings (lane, two 222.. states, NEEDS_HUMAN, mentions, list) + 4 ci + 2 human
        self.assertEqual(d["items_total"], 12, [i["text"] for i in d["items"]])

    def test_keys_are_stable(self):
        a = {i["text"]: i["key"] for i in self.f.items("--all")["items"]}
        other = Fabric([e.replace("2026-10-13", "2026-10-12") for e in ENTRIES])
        try:
            b = {i["text"]: i["key"] for i in other.items("--all")["items"]}
        finally:
            other.close()
        self.assertEqual(sorted(a.values()), sorted(b.values()), "timestamps never enter a key")
        self.assertTrue(any(k.startswith("222222222-") for k in a.values()), "id subjects lead the key")

    def test_continuation_clause_stays_with_its_subject(self):
        d = self.f.items("--all")
        self.f.by_text(d, "222222222: tab gone; check queue")
        human = self.f.by_text(d, "rebase the ui branch")
        self.assertIn("continuation line", human["text"])
        tui = self.f.by_text(d, "PAUSE the herd")
        self.assertEqual(tui["source"], "", "a TUI line is not split and has no source")
        self.assertIn("rebase api first", tui["text"])

    def test_supersession(self):
        d = self.f.items("--all")
        st = {i["text"]: i for i in d["items"]}
        old = self.f.by_text(d, "question/WAITING")
        self.assertEqual(old["status"], "superseded")
        self.assertEqual(old["close"]["reason"], "newer status for the same subject")
        self.assertEqual(self.f.by_text(d, "old lane")["status"], "superseded", "absent from the last 2 reports")
        self.assertEqual(self.f.by_text(d, "NEEDS_HUMAN")["status"], "superseded")
        self.assertEqual(self.f.by_text(d, "PR #41 red")["status"], "superseded", "PR #41 went green")
        for t in ("PR #42 red", "PR #43 red"):
            self.assertEqual(self.f.by_text(d, t)["status"], "open", "event-style watcher: absence means nothing")
        self.assertEqual(self.f.by_text(d, "PR #41 green")["status"], "open")
        self.assertEqual(self.f.by_text(d, "tab gone")["status"], "open")
        opened = sorted(i["text"][:20] for i in d["items"] if i["status"] == "open")
        self.assertEqual(len(opened), 8, (opened, st.keys()))

    def test_repeating_event_watcher_is_not_a_snapshot(self):
        ev = ["- 2026-10-14T08:00:00Z ci-watch: PR #42 red on run 987654399",
              "- 2026-10-14T09:00:00Z ci-watch: PR #42 red on run 987654410",
              "- 2026-10-14T10:00:00Z ci-watch: PR #43 red on run 987654444",
              "- 2026-10-14T11:00:00Z ci-watch: PR #43 red on run 987654460"]
        f = Fabric(ev)
        try:
            d = f.items("--all")
            self.assertEqual(sorted(i["status"] for i in d["items"]), ["open", "open"],
                             "one finding per line: repeats share a key, absence still means nothing")
            self.assertEqual(f.run("pending-count").stdout.strip(), "2")
            f.append("- 2026-10-14T12:00:00Z ci-watch: PR #44 red on run 987654470")
            f.append("- 2026-10-14T13:00:00Z ci-watch: PR #44 red on run 987654480")
            self.assertEqual(f.run("pending-count").stdout.strip(), "3", "no flapping with more reports")
        finally:
            f.close()

    def test_pending_count_and_verify(self):
        p = self.f.run("pending-count")
        self.assertEqual(p.stdout.strip(), "8")
        v = self.f.run("verify")
        self.assertEqual(v.returncode, 1)
        self.assertIn("open item", v.stderr)
        keys = [i["key"] for i in self.f.items("--open")["items"]]
        a = self.f.run("ack", *keys[:-1], "--action", "ticket", "--note", "T-1: follow up")
        self.assertEqual(a.returncode, 0, a.stderr)
        self.assertEqual(self.f.run("verify").returncode, 1)
        d = self.f.run("defer", keys[-1], "--until", "2026-10-20", "--note", "waiting for the deploy")
        self.assertEqual(d.returncode, 0, d.stderr)
        v = self.f.run("verify")
        self.assertEqual(v.returncode, 0, v.stderr)
        self.assertEqual(self.f.run("pending-count").stdout.strip(), "0")
        self.assertEqual(self.f.run("verify", now="2026-10-21T00:00:00Z").returncode, 1, "deferral expired")


class Ledger(Base):
    def key(self, needle):
        return self.f.by_text(self.f.items("--all"), needle)["key"]

    def test_append_only(self):
        self.f.run("list")
        before = read(self.f.ledger)
        k = self.key("PR #42")
        self.f.run("ack", k, "--action", "done", "--note", "rerun green")
        self.f.append("- 2026-10-16T08:00:00Z ci-watch: PR #44 red on run 987654600")
        self.f.run("list")
        self.f.run("compact")
        after = read(self.f.ledger)
        self.assertTrue(after.startswith(before), "the ledger is only ever appended to")
        evs = [json.loads(x)["ev"] for x in after.splitlines()]
        for ev in ("seen", "ack", "superseded"):
            self.assertIn(ev, evs)

    def test_repeat_list_writes_nothing_new(self):
        self.f.run("list")
        a = read(self.f.ledger)
        self.f.run("list")
        self.f.run("pending-count")
        self.assertEqual(read(self.f.ledger), a, "intake is idempotent")

    def test_done_reopens_on_repeat(self):
        k = self.key("PR #42")
        self.f.run("ack", k, "--action", "done", "--note", "rerun green")
        self.assertEqual(self.f.by_text(self.f.items("--all"), "PR #42")["status"], "acked")
        self.f.append("- 2026-10-16T09:00:00Z ci-watch: PR #42 red on run 987654777")
        it = self.f.by_text(self.f.items("--all"), "PR #42")
        self.assertEqual((it["status"], it["reopened"]), ("open", "reported again after done"))

    def test_dropped_is_sticky(self):
        k = self.key("mentions still to check")
        self.f.run("ack", k, "--action", "dropped", "--note", "the watcher re-reports history; noise")
        self.f.append(snap("2026-10-16T09:00:00+00:00", "222222222: tab gone; check queue",
                           "26 mentions still to check", "Open follow-up: " + ",".join(IDS[:3])))
        it = self.f.by_text(self.f.items("--all"), "mentions still to check")
        self.assertEqual(it["status"], "acked")
        self.assertEqual(it["count"], 7)

    def test_ticket_reopens_only_on_new_ids(self):
        k = self.key("Open follow-up")
        self.f.run("ack", k, "--action", "ticket", "--note", "T-7: work the follow-up list")
        self.f.append(snap("2026-10-16T09:00:00+00:00", "Open follow-up: " + ",".join(IDS[:3])))
        self.assertEqual(self.f.by_text(self.f.items("--all"), "Open follow-up")["status"], "acked")
        self.f.append(snap("2026-10-16T09:30:00+00:00", "Open follow-up: " + ",".join(IDS)))
        it = self.f.by_text(self.f.items("--all"), "Open follow-up")
        self.assertEqual((it["status"], it["reopened"]), ("open", "1 new id(s) since ticket"))

    def test_ticket_ignores_incidental_ids(self):
        k = self.key("PR #43 red")
        self.f.run("ack", k, "--action", "ticket", "--note", "T-9: CI red")
        self.f.append("- 2026-10-15T11:00:00Z ci-watch: PR #43 red on run 987654470")
        it = self.f.by_text(self.f.items("--all"), "PR #43 red")
        self.assertEqual((it["status"], it["count"]), ("acked", 2), "a new run number is not new work")

    def test_superseded_reopens_when_reported_again(self):
        self.assertEqual(self.f.by_text(self.f.items("--all"), "old lane")["status"], "superseded")
        self.f.append(snap("2026-10-16T09:00:00+00:00", "111111111: old lane after 5 tries"))
        it = self.f.by_text(self.f.items("--all"), "old lane")
        self.assertEqual((it["status"], it["reopened"]), ("open", "reported again after superseded"))

    def test_validation(self):
        self.assertEqual(self.f.run("ack", "nope-000000", "--action", "done", "--note", "x").returncode, 2)
        self.assertEqual(self.f.run("ack", "2", "--action", "done", "--note", "x").returncode, 2, "ambiguous")
        k = self.key("PR #43")
        self.assertEqual(self.f.run("ack", k, "--action", "done", "--note", "  ").returncode, 2, "note required")
        self.assertEqual(self.f.run("ack", k, "--action", "maybe", "--note", "x").returncode, 2)
        self.assertEqual(self.f.run("defer", k, "--until", "2026-10-01", "--note", "x").returncode, 2, "past date")
        self.assertEqual(self.f.run("defer", k, "--until", "soon", "--note", "x").returncode, 2)
        p = self.f.run("ack", k[:12], "--action", "done", "--note", "unique prefix")
        self.assertEqual(p.returncode, 0, p.stderr)

    def test_hand_cleared_file_keeps_items_open(self):
        before = self.f.run("pending-count").stdout.strip()
        text = read(self.f.steer)
        with open(self.f.steer, "w", encoding="utf-8") as f:
            f.write(text[:text.index(MARKER) + len(MARKER)] + "\n")
        self.assertEqual(self.f.run("pending-count").stdout.strip(), before, "deleting lines is not triage")
        evs = [json.loads(x)["ev"] for x in read(self.f.ledger).splitlines()]
        self.assertIn("vanished", evs)
        # the same lines written back are new reports, not a replay of the old ones
        with open(self.f.steer, "a", encoding="utf-8") as f:
            f.write(ENTRIES[3] + "\n")
        self.assertEqual(self.f.by_text(self.f.items("--all"), "PR #41 red")["count"], 2)


class Compact(Base):
    def test_moves_only_closed_entries(self):
        self.f.run("list")
        open_keys = [i["key"] for i in self.f.items("--open")["items"]]
        ci = [i["key"] for i in self.f.items("--open")["items"] if i["source"] == "ci-watch"]
        self.f.run("ack", *ci, "--action", "done", "--note", "green on main")
        before = self.f.items("--all")
        p = self.f.run("compact", "--dry-run")
        self.assertIn("would move", p.stdout)
        p = self.f.run("compact")
        self.assertEqual(p.returncode, 0, p.stderr)
        arch = os.path.join(self.f.m2, "archives", "steer", "2026-10.md")
        self.assertTrue(os.path.isfile(arch))
        archived = read(arch)
        live = read(self.f.steer)
        self.assertTrue(live.startswith(header().split(MARKER)[0]), "head kept verbatim")
        self.assertIn(MARKER, live)
        for e in ENTRIES[3:5] + [ENTRIES[7], ENTRIES[9]]:
            self.assertIn(e, archived)
            self.assertNotIn(e, live)
        for e in (ENTRIES[5], ENTRIES[-1].split("\n")[0], ENTRIES[-2]):
            self.assertIn(e, live, "an entry with an open finding stays")
        self.assertNotIn(ENTRIES[5], archived)
        after = self.f.items("--all")
        self.assertEqual(after["items_total"], before["items_total"])
        self.assertEqual(after["counts"], before["counts"], "compaction changes no item")
        self.assertEqual(self.f.by_text(after, "PR #42")["count"], 1)
        self.assertEqual(len([k for k in open_keys if k not in ci]),
                         int(self.f.run("pending-count").stdout.strip()))
        # an identical line appended after compaction is a new report
        self.f.append(ENTRIES[4])
        it = self.f.by_text(self.f.items("--all"), "PR #42")
        self.assertEqual((it["count"], it["status"]), (2, "open"))

    def test_second_compact_is_a_no_op(self):
        p = self.f.run("compact")
        self.assertIn("moved 1 entries", p.stdout, "only the PR #41 red line is fully superseded")
        live = read(self.f.steer)
        p = self.f.run("compact")
        self.assertIn("nothing to compact", p.stdout)
        self.assertEqual(read(self.f.steer), live)

    def test_late_unlocked_append_survives(self):
        """A watcher appending without the lock while compact rewrites: its line must land in the new file."""
        self.f.run("list")
        code = (
            "import importlib.machinery, importlib.util, os, sys\n"
            "ld = importlib.machinery.SourceFileLoader('steer', sys.argv[1])\n"
            "m = importlib.util.module_from_spec(importlib.util.spec_from_loader('steer', ld)); ld.exec_module(m)\n"
            "real = os.replace\n"
            "def late(a, b):\n"
            "    with open(b, 'a', encoding='utf-8') as f: f.write(sys.argv[3] + '\\n')\n"
            "    real(a, b)\n"
            "m.os.replace = late\n"
            "sys.exit(m.main(['--fabric', sys.argv[2], 'compact']))\n")
        late_line = "- 2026-10-16T12:00:01Z ci-watch: PR #46 red on run 987654900"
        p = subprocess.run([sys.executable, "-c", code, STEER_BIN, self.f.root, late_line], cwd=self.f.root,
                           env=self.f.env(), capture_output=True, text=True, timeout=60)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn(late_line, read(self.f.steer))
        self.assertEqual(self.f.by_text(self.f.items("--all"), "PR #46")["count"], 1)


class Gate(Base):
    P = {"session_id": "s1", "hook_event_name": "UserPromptSubmit", "prompt": "hello"}

    def payload(self, **kw):
        d = dict(self.P, cwd=self.f.root)
        d.update(kw)
        return d

    def out(self, p):
        self.assertEqual(p.returncode, 0, p.stderr)
        return json.loads(p.stdout) if p.stdout.strip() else None

    def test_format_and_rate_limit(self):
        o = self.out(self.f.gate(self.payload()))
        hso = o["hookSpecificOutput"]
        self.assertEqual(hso["hookEventName"], "UserPromptSubmit")
        line = hso["additionalContext"]
        self.assertNotIn("\n", line, "ONE line")
        self.assertIn("STEER: 8 open item(s)", line)
        self.assertIn(".m2herd/inbox/STEER.md", line)
        top = [i["key"] for i in self.f.items("--open")["items"]][:3]
        self.assertIn("(top: " + ", ".join(top) + ")", line)
        self.assertEqual(top[0], self.f.by_text(self.f.items("--open"), "PAUSE the herd")["key"],
                         "urgent words (PAUSE, NEEDS_HUMAN, FAIL ...) sort first")
        self.assertTrue(os.path.isfile(os.path.join(self.f.home, ".m2herd", "state", "proj", "steer-gate.json")),
                        "rate-limit state is runtime state, outside the fabric")
        for cmd in ("m2herd-steer list --open", "m2herd-steer ack <key>", "m2herd-steer defer <key>",
                    "m2herd-steer verify", "templates/herd/rules/STEER.md"):
            self.assertIn(cmd, line)
        self.assertNotIn("decision", json.dumps(o), "never blocks")
        self.assertIn("Mid-task: finish first", line)
        # same set, same session, within 30 min: silent
        self.assertIsNone(self.out(self.f.gate(self.payload(), now="2026-10-16T12:20:00Z")))
        # another session has not seen it
        self.assertIsNotNone(self.out(self.f.gate(self.payload(session_id="s2"), now="2026-10-16T12:20:00Z")))
        # 31 minutes later: again
        self.assertIsNotNone(self.out(self.f.gate(self.payload(), now="2026-10-16T12:31:00Z")))
        # a new open item changes the set: at once
        self.f.append("- 2026-10-16T12:32:00Z ci-watch: PR #45 red on run 987654800")
        o = self.out(self.f.gate(self.payload(), now="2026-10-16T12:33:00Z"))
        self.assertIn("STEER: 9 open item(s)", o["hookSpecificOutput"]["additionalContext"])

    def test_stop_event(self):
        o = self.out(self.f.gate(self.payload(hook_event_name="Stop"), "Stop"))
        self.assertEqual(o["hookSpecificOutput"]["hookEventName"], "Stop")
        # additionalContext on Stop makes Claude Code continue the turn: the nudge must fit a turn end
        line = o["hookSpecificOutput"]["additionalContext"]
        self.assertNotIn("Mid-task", line)
        self.assertIn("Turn end: triage now", line)
        with open(os.path.join(REPO, "docs", "herd-flow-v2.md"), encoding="utf-8") as fh:
            sec = fh.read().split("## 8.", 1)[1].split("\n## ", 1)[0]
        self.assertNotIn("never blocks a turn", sec)
        self.assertIn("continues the turn", sec)
        o = self.out(self.f.gate({"session_id": "s3", "cwd": self.f.root}, "Stop"))
        self.assertEqual(o["hookSpecificOutput"]["hookEventName"], "Stop", "event from argv when payload lacks it")
        self.assertIsNone(self.out(self.f.gate(self.payload(session_id="s4", hook_event_name="Stop",
                                                            stop_hook_active=True), "Stop")))

    def test_silent_cases(self):
        self.assertIsNone(self.out(self.f.gate(self.payload(), M2HERD_WORKER="1")))
        self.assertIsNone(self.out(self.f.gate(self.payload(), HERD_SLICE="api-x")))
        self.assertIsNone(self.out(self.f.gate(self.payload(), M2HERD_STEER_GATE="0")))
        self.assertIsNone(self.out(self.f.gate(self.payload(agent_id="sub-1"))))
        self.assertIsNone(self.out(self.f.gate(self.payload(cwd=self.f.home))), "no fabric")
        self.assertFalse(os.path.exists(os.path.join(self.f.home, ".m2herd", "state", "proj", "steer-gate.json")),
                         "a silent gate records nothing")
        for junk in (b"", b"\x00\xff{{{not json\x01\n\xfe", b"[1,2]"):
            p = self.f.gate(junk)
            self.assertEqual(p.returncode, 0)
            if p.stdout.strip():
                json.loads(p.stdout)  # the process cwd holds the fabric: valid output is allowed

    def test_herd_worker_pane_is_silent_orchestrator_is_not(self):
        cache = os.path.join(self.f.home, ".cache", "herd-board")
        herd = os.path.join(self.f.tmp, "herd")
        os.makedirs(cache)
        os.makedirs(herd)
        with open(os.path.join(herd, "herd.map"), "w") as f:
            f.write("api-x=w1:p7\n")
        with open(os.path.join(cache, "w1_p1.herds"), "w") as f:
            f.write(herd + "\n")
        self.assertIsNone(self.out(self.f.gate(self.payload(), HERDR_PANE_ID="w1:p7")))
        self.assertIsNotNone(self.out(self.f.gate(self.payload(), HERDR_PANE_ID="w1:p1")))

    def test_zero_pending_is_silent(self):
        keys = [i["key"] for i in self.f.items("--open")["items"]]
        self.f.run("ack", *keys, "--action", "dropped", "--note", "test noise")
        self.assertIsNone(self.out(self.f.gate(self.payload())))

    def test_symlinked_hook_finds_engine(self):
        link_dir = os.path.join(self.f.home, ".claude", "hooks")
        os.makedirs(link_dir)
        link = os.path.join(link_dir, "m2herd-steer-gate.sh")
        os.symlink(GATE, link)
        e = self.f.env()
        p = subprocess.run(["bash", link], input=json.dumps(self.payload()).encode(), cwd=self.f.root, env=e,
                           capture_output=True, timeout=60)
        self.assertIn(b"STEER: 8 open", p.stdout)


class Selftest(unittest.TestCase):
    def test_selftest(self):
        p = subprocess.run([sys.executable, STEER_BIN, "--selftest"], capture_output=True, text=True,
                           env=dict(os.environ, PYTHONDONTWRITEBYTECODE="1"))
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)

    def test_bash_syntax(self):
        self.assertEqual(subprocess.run(["bash", "-n", GATE]).returncode, 0)


if __name__ == "__main__":
    unittest.main(verbosity=1)
