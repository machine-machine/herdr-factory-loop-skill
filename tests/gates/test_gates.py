#!/usr/bin/env python3
"""Gate transitions and the G0 rule table (docs/factory-v3.md §2–§3). Offline, temp dirs only.

  python3 tests/gates/test_gates.py [-v]
"""
import importlib.machinery
import importlib.util
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "scripts"))
import herd_events as he  # noqa: E402

_loader = importlib.machinery.SourceFileLoader("m2herd_gate", os.path.join(ROOT, "scripts", "m2herd-gate"))
_spec = importlib.util.spec_from_loader("m2herd_gate", _loader)
gate = importlib.util.module_from_spec(_spec)
_loader.exec_module(gate)


def cli(base, *argv):
    out, err = io.StringIO(), io.StringIO()
    with redirect_stdout(out), redirect_stderr(err):
        rc = gate.main(["--dir", base, *argv])
    return rc, out.getvalue(), err.getvalue()


class Transitions(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.run = os.path.join(self.tmp.name, "run")

    def tearDown(self):
        self.tmp.cleanup()

    def test_first_event_must_be_triaged(self):
        with self.assertRaises(he.TransitionError):
            he.append_gate(self.run, "design_review", evidence="g1.md", open=0)

    def test_standard_path_to_design_ok(self):
        he.append_gate(self.run, "triaged", track="standard", tier="medium")
        he.append_gate(self.run, "design_review", evidence="g1-1.md", open=3)
        with self.assertRaisesRegex(he.TransitionError, "3 open"):
            he.append_gate(self.run, "design_ok", by="human", word="go")
        he.append_gate(self.run, "design_review", evidence="g1-2.md", open=0, round=2)
        ev = he.append_gate(self.run, "design_ok", by="human", word="ja, passt")
        self.assertEqual((ev["gate"], ev["word"]), ("G1", "ja, passt"))
        st = he.gate_state(self.run)
        self.assertEqual((st["track"], st["last"]["event"]), ("standard", "design_ok"))
        self.assertEqual([e["event"] for e in he.read_gates(self.run)],
                         ["triaged", "design_review", "design_review", "design_ok"])

    def test_design_ok_is_the_humans_and_needs_words(self):
        he.append_gate(self.run, "triaged", track="standard", tier="low")
        he.append_gate(self.run, "design_review", evidence="g1.md", open=0)
        with self.assertRaisesRegex(ValueError, "by=human"):
            he.append_gate(self.run, "design_ok", by="orchestrator", word="go")
        with self.assertRaisesRegex(ValueError, "verbatim"):
            he.append_gate(self.run, "design_ok", by="human", word="  ")

    def test_quick_run_has_no_g1(self):
        he.append_gate(self.run, "triaged", track="quick", tier="low")
        with self.assertRaisesRegex(he.TransitionError, "quick run has no G1"):
            he.append_gate(self.run, "design_review", evidence="g1.md", open=0)
        he.append_gate(self.run, "triaged", track="standard", tier="low")   # raising is fine
        he.append_gate(self.run, "design_review", evidence="g1.md", open=0)

    def test_retriage_never_lowers_without_force(self):
        he.append_gate(self.run, "triaged", track="full", tier="high")
        with self.assertRaisesRegex(he.TransitionError, "never lower"):
            he.append_gate(self.run, "triaged", track="standard", tier="high")
        with self.assertRaisesRegex(he.TransitionError, "never lower"):
            he.append_gate(self.run, "triaged", track="full", tier="medium")
        with self.assertRaisesRegex(ValueError, "note"):
            he.append_gate(self.run, "triaged", track="standard", tier="medium", force=True)
        ev = he.append_gate(self.run, "triaged", track="standard", tier="medium", force=True, note="false alarm")
        self.assertEqual(ev["forced_from"], "triaged")

    def test_gate_lines_are_invisible_to_phase_reader(self):
        he.append_gate(self.run, "triaged", track="quick", tier="low")
        he.append(self.run, "s1", "queued")
        with open(he.gates_path(self.run), "a") as f:
            f.write('{"torn": \n')
        self.assertEqual(list(he.state(self.run)), ["s1"])
        self.assertEqual(len(he.read_gates(self.run)), 1)

    def test_validation(self):
        with self.assertRaises(ValueError):
            he.append_gate(self.run, "triaged", track="huge", tier="low")
        with self.assertRaises(ValueError):
            he.append_gate(self.run, "nope")
        with self.assertRaises(ValueError):
            he.append_gate(self.run, "triaged", by="worker", track="quick", tier="low")


class Triage(unittest.TestCase):
    def check(self, intent, files, track, tier, sure=True):
        d = gate.triage(intent, files)
        self.assertEqual((d["track"], d["tier"], d["sure"]), (track, tier, sure), (intent, d))
        return d

    def test_rule_table(self):
        self.check("fix typo in README", ["README.md"], "quick", "low")
        self.check("bump the timeout config", ["src/api/settings.py"], "quick", "medium")
        self.check("rename a variable", [], "quick", "medium", sure=False)
        self.check("add OAuth login", [], "full", "high")
        self.check("write the Postgres migration for invoices", ["db/m.sql"], "full", "high")
        self.check("build a new service for exports", [], "full", "medium")
        self.check("show totals on the dashboard", ["src/api/x.py", "src/ui/y.tsx"], "standard", "medium")
        self.check("show totals on the dashboard", [], "standard", "medium", sure=False)
        self.check("rename the docs index", ["docs/a.md", "docs/b.md"], "quick", "low")
        # two areas beat a quick word
        self.check("rename field in api and ui", ["api/a.py", "ui/b.ts"], "standard", "medium")

    def test_word_boundaries(self):
        self.assertEqual(gate.hits("high", "the author field"), [])        # auth* must not match inside a word
        self.assertEqual(gate.hits("high", "auth flow"), ["auth"])
        self.assertEqual(gate.hits("high", "Authorization header"), ["authorization"])
        self.assertEqual(gate.hits("high", "Migrations folder"), ["migrations"])
        self.assertEqual(gate.hits("quick", "pre-format"), [])

    def test_areas(self):
        self.assertEqual(gate.areas(["src/api/a.py", "src/api/b/c.py", "./README.md", "src/x.py"]),
                         ["README.md", "src", "src/api"])   # a file right under src/ is area src


class Cli(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.base = self.tmp.name

    def tearDown(self):
        self.tmp.cleanup()

    def test_triage_records_and_status_says_who_acts(self):
        rc, out, _ = cli(self.base, "triage", "show totals on the dashboard", "--files", "api/a.py,ui/b.ts")
        self.assertEqual(rc, 0)
        self.assertIn("track: standard (tier medium)", out)
        rid = "show-totals-on-the-dashboard"
        evs = he.read_gates(os.path.join(self.base, ".m2herd", "factory", rid))
        self.assertEqual((evs[0]["event"], evs[0]["areas"]), ("triaged", ["api", "ui"]))
        cli(self.base, "record", rid, "design_review", "--evidence", "specs/001/reviews/g1-1.md", "--open", "0")
        rc, out, _ = cli(self.base, "status", "--json")
        st = json.loads(out)[rid]
        self.assertTrue(st["waiting_on"].startswith("human:"), st["waiting_on"])
        self.assertIn(f"m2herd gate approve {rid} G1", st["waiting_on"])
        rc, out, _ = cli(self.base, "approve", rid, "G1", "--word", "go")
        self.assertEqual(rc, 0)
        _, out, _ = cli(self.base, "status", rid)
        self.assertIn("cut (G2)", out)

    def test_track_override_and_high_tier_guard(self):
        rc, out, _ = cli(self.base, "triage", "show totals", "--track", "quick", "--id", "t1", "--json")
        ev = json.loads(out)
        self.assertEqual((rc, ev["track"], ev["sure"]), (0, "quick", True))
        self.assertIn("by --track", ev["reasons"][-1])
        rc, _, err = cli(self.base, "triage", "fix the auth typo", "--track", "quick", "--id", "t2")
        self.assertEqual(rc, 2)
        self.assertIn("needs the full track", err)
        rc, _, _ = cli(self.base, "triage", "fix the auth typo", "--track", "quick", "--id", "t2",
                       "--force", "--note", "docs only")
        self.assertEqual(rc, 0)

    def test_tier_only_raises_and_chat_high_needs_approval(self):
        _, out, _ = cli(self.base, "triage", "fix typo", "--files", "docs/a.md", "--tier", "medium", "--json",
                        "--dry-run")
        self.assertEqual(json.loads(out)["tier"], "medium")
        _, out, _ = cli(self.base, "triage", "add payment page", "--tier", "low", "--json", "--dry-run")
        self.assertEqual(json.loads(out)["tier"], "high")
        self.assertFalse(os.path.exists(os.path.join(self.base, ".m2herd")), "dry run wrote nothing")
        _, out, _ = cli(self.base, "triage", "add payment page", "--source", "chat", "--id", "pay")
        self.assertIn("STEER inbox", out)

    def test_bad_run_id_and_missing_run(self):
        rc, _, err = cli(self.base, "triage", "x", "--id", "../evil")
        self.assertEqual(rc, 2)
        rc, _, err = cli(self.base, "status", "nothing-here")
        self.assertEqual(rc, 2)

    def test_m2herd_wrapper_passes_through(self):
        env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1")
        subprocess.run(["git", "init", "-q", self.base], check=True)
        subprocess.run(["bash", os.path.join(ROOT, "scripts", "m2herd.sh"), "init", "--dir", self.base, "--goal", "t"],
                       check=True, stdout=subprocess.DEVNULL, env=env)
        r = subprocess.run(["bash", os.path.join(ROOT, "scripts", "m2herd.sh"), "triage", "fix typo in README",
                            "--files", "README.md", "--dir", self.base, "--json"],
                           capture_output=True, text=True, env=env)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(json.loads(r.stdout)["track"], "quick")
        r = subprocess.run(["bash", os.path.join(ROOT, "scripts", "m2herd.sh"), "gate", "status", "--dir", self.base],
                           capture_output=True, text=True, env=env)
        self.assertIn("fix-typo-in-readme", r.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2 if "-v" in sys.argv else 1, argv=[sys.argv[0]])
