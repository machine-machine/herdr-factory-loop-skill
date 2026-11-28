#!/usr/bin/env python3
"""m2herd prompt — the optimiser's routing and audit, against a synthetic fabric (offline).

  python3 tests/prompt/test_prompt.py

The property under test is the one the whole feature exists for: a followup fact must land
as CONTEXT and stay verbatim, an intent must land as an INTENT, a correction must strike the
intent it replaces, and `audit` must refuse a prompt that cannot be graded.
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
ENGINE = os.path.join(REPO, "scripts", "m2herd.sh")
HOOK = os.path.join(REPO, "hooks", "m2herd-prompt-intent.sh")


def run(args, cwd):
    return subprocess.run(["bash", ENGINE] + args, cwd=cwd,
                          capture_output=True, text=True)


class PromptForge(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="m2prompt-")
        subprocess.run(["bash", ENGINE, "init", "--dir", self.dir],
                       capture_output=True, text=True)
        self.prompt = os.path.join(self.dir, ".m2herd", "prompt", "prompt.md")

    def tearDown(self):
        shutil.rmtree(self.dir, ignore_errors=True)

    def new(self, text="mach die app schneller"):
        r = run(["prompt", "new", "--dir", self.dir, text], self.dir)
        self.assertEqual(r.returncode, 0, r.stderr)

    def add(self, text, *flags):
        return run(["prompt", "add", "--dir", self.dir] + list(flags) + [text], self.dir)

    def body(self):
        with open(self.prompt) as f:
            return f.read()

    def section(self, name):
        out, on = [], False
        for line in self.body().splitlines():
            if line.startswith("## "):
                on = line == "## " + name
                continue
            if on:
                out.append(line)
        return "\n".join(out)

    # --- routing -----------------------------------------------------------
    def test_followup_with_path_is_context_and_kept_verbatim(self):
        self.new()
        text = "die datei liegt jetzt in src/perf.ts"
        self.assertEqual(self.add(text).returncode, 0)
        self.assertIn(text, self.section("Context"), "fact must be filed verbatim")
        self.assertNotIn(text, self.section("Intents"))

    def test_version_mention_is_context(self):
        self.new()
        r = self.add("der kunde hat v2.3 freigegeben")
        self.assertEqual(r.returncode, 0)
        self.assertIn("v2.3", self.section("Context"))

    def test_imperative_is_intent(self):
        self.new()
        self.add("baue eine messstation fuer die ladezeit ein")
        self.assertIn("messstation", self.section("Intents"))

    def test_imperative_with_path_stays_intent(self):
        self.new()
        self.add("src/perf.ts: mach das lazy")
        self.assertIn("lazy", self.section("Intents"))

    def test_boundary_is_constraint_not_work(self):
        self.new()
        self.add("darf nicht ueber 4 MB gehen")
        self.assertIn("4 MB", self.section("Constraints"))
        self.assertNotIn("4 MB", self.section("Intents"))

    def test_correction_strikes_the_previous_intent(self):
        self.new()
        self.add("optimiere den renderer")
        self.add("nein, stattdessen erst profilen")
        intents = self.section("Intents")
        self.assertIn("~~- [ ] optimiere den renderer~~ (superseded)", intents)
        self.assertIn("CORRECTION: nein, stattdessen erst profilen", intents)

    def test_explicit_as_beats_the_heuristic(self):
        self.new()
        self.add("die datei liegt in src/perf.ts", "--as", "intent")
        self.assertIn("die datei liegt in src/perf.ts", self.section("Intents"))

    def test_duplicate_line_is_not_filed_twice(self):
        self.new()
        self.add("die datei liegt in src/perf.ts")
        self.add("die datei liegt in src/perf.ts")
        self.assertEqual(self.section("Context").count("src/perf.ts"), 1)

    def test_every_decision_lands_in_the_ledger(self):
        self.new()
        self.add("die datei liegt in src/perf.ts")
        self.add("baue eine messstation ein")
        with open(os.path.join(self.dir, ".m2herd", "prompt", "ledger.jsonl")) as f:
            kinds = [line.split("\t")[1] for line in f if line.strip()]
        self.assertEqual(kinds, ["new", "add", "add"])

    # --- audit (the external check) ---------------------------------------
    def test_audit_fails_a_bare_prompt_and_names_the_rules(self):
        self.new("Du bist ein erfahrener Performance-Experte und machst das so schnell wie moeglich")
        r = run(["prompt", "audit", "--dir", self.dir], self.dir)
        self.assertEqual(r.returncode, 1)
        for rule in ("R1", "R2", "R3", "R4"):
            self.assertIn(rule, r.stdout)

    def test_audit_passes_a_gradeable_prompt(self):
        self.new()
        with open(self.prompt) as f:
            doc = f.read()
        doc = doc.replace("## Done when\n",
                          "## Done when\n- first paint under 200 ms, bundle <= 4 MB\n")
        doc = doc.replace("```bash\n# the command", "```bash\nnpm run perf:check\n")
        with open(self.prompt, "w") as f:
            f.write(doc)
        r = run(["prompt", "audit", "--dir", self.dir], self.dir)
        self.assertEqual(r.returncode, 0, r.stdout)

    # --- hook --------------------------------------------------------------
    def hook(self, prompt):
        env = dict(os.environ, M2HERD_DIR=self.dir)
        return subprocess.run(["bash", HOOK], cwd=self.dir, env=env,
                              input=json.dumps({"prompt": prompt}),
                              capture_output=True, text=True).stdout

    def test_hook_routes_a_context_turn(self):
        self.new()
        out = self.hook("uebrigens die datei liegt in src/perf.ts")
        self.assertIn("FOLLOWUP INFORMATION", out)
        self.assertIn("do not turn it into a task", out)

    def test_hook_routes_an_intent_turn(self):
        self.new()
        self.assertIn("INTENT", self.hook("bitte baue eine messstation ein"))

    def test_hook_is_silent_on_chatter(self):
        self.new()
        self.assertEqual(self.hook("ok danke").strip(), "")

    def test_hook_is_silent_without_a_prompt(self):
        self.assertEqual(self.hook("bitte baue eine messstation ein").strip(), "")


if __name__ == "__main__":
    unittest.main(verbosity=2)