#!/usr/bin/env python3
"""herd-context, herd-clash and register-excerpt.py against temp repos (offline, sealed PATH)."""
import json
import os
import sys
import unittest

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from world import World, he  # noqa: E402


class Ctx(unittest.TestCase):
    def setUp(self):
        w = self.w = World()
        # the herd lives inside a project repo that carries the register and the rules
        self.project = os.path.join(w.tmp, "project")
        os.makedirs(os.path.join(self.project, ".m2herd", "rules"))
        w.sh(self.project, "git", "init", "-q")
        w.herd = os.path.join(self.project, ".m2herd", "herden", "herde-2310")
        os.makedirs(w.herd)
        with open(os.path.join(self.project, "decisions-questions.json"), "w") as f:
            json.dump({"open_questions": [{"id": "q-reviere-rollen", "question": "Wer darf Reviere sehen?",
                                           "context": "Ticket 10000000001"}],
                       "decisions": [{"id": "d-reviere-api", "date": "2026-10-20", "decision": "Reviere als API",
                                      "refs": ["acme-api src/reviere.py"]},
                                     {"id": "d-unrelated", "date": "2026-10-20", "decision": "Fotos"}]}, f)
        for role in ("WORKER", "REVIEWER", "FIXER"):
            with open(os.path.join(self.project, ".m2herd", "rules", f"{role}.md"), "w") as f:
                f.write(f"{role} rules for {{{{slice}}}} in {{{{herd}}}}; report to {{{{orchestrator}}}} "
                        f"on port {{{{api_port}}}}; status {{{{status}}}}; {{{{nope}}}}\n")
        with open(os.path.join(w.herd, "ctx.env"), "w") as f:
            f.write("# per-herd values\nAPI_PORT=8010\n")
        self.mem = os.path.join(w.tmp, "memory")
        os.makedirs(self.mem)
        with open(os.path.join(self.mem, "stacked-pr-merge.md"), "w") as f:
            f.write("Merge bottom-up; retarget the child before deleting the parent.\n")
        w.env.update(HERD_MEMORY_DIR=self.mem, HERD_ORCH_NAME="workspace-6f")
        w.fake_tool("lage", 'echo "lage-hit for: $3 $4 $5"\n')
        w.repo("acme-api", {"src/reviere.py": "a\n", "src/shared.py": "s\n", "tests/test_r.py": "t\n"})
        wa = w.worktree("acme-api", "reviere", "reviere-api")
        self.head = w.commit(wa, {"src/reviere.py": "b\n", "src/shared.py": "r\n", "tests/test_r.py": "r\n"})
        wb = w.worktree("acme-api", "kollision", "ko")
        w.commit(wb, {"src/shared.py": "k\n", "tests/test_r.py": "k\n"})
        w.slice("reviere", [("acme-api", "reviere-api", "origin/main")],
                {"tickets": "10000000001", "needs_memory": "stacked-pr-merge.md, missing-one.md"},
                phase="working")
        w.slice("kollision", [("acme-api", "ko", "origin/main")], phase="working")

    def tearDown(self):
        self.w.close()

    def ctx(self, role, slice_name="reviere", *extra):
        rc, out, err = self.w.run("herd-context", role, self.w.herd, slice_name, *extra)
        self.assertEqual(rc, 0, err)
        path = os.path.join(self.w.herd, f"{slice_name}.ctx.{role}.md")
        self.assertEqual(out.strip(), path)
        with open(path) as f:
            return f.read()

    def test_worker_all_sections(self):
        t = self.ctx("worker")
        self.assertIn(f"head {self.head[:12]}", t)
        self.assertIn("WORKER rules for reviere in", t)
        self.assertIn("report to workspace-6f on port 8010", t)
        self.assertIn("unfilled placeholders: nope", t)
        self.assertIn("## Task", t)
        self.assertIn("Do the reviere thing.", t)
        self.assertNotIn("## Report", t)
        self.assertIn("reviere ⇄ kollision", t.replace("kollision ⇄ reviere", "reviere ⇄ kollision"))
        self.assertIn("src/shared.py", t)
        self.assertNotIn("tests/test_r.py", t.split("## Clash")[1].split("## Memory")[0])
        self.assertIn("Merge bottom-up", t)
        self.assertIn("missing-one.md", t)
        self.assertIn("q-reviere-rollen", t)
        self.assertIn("d-reviere-api", t, "touched file src/reviere.py selects the decision")
        self.assertNotIn("d-unrelated", t)
        self.assertIn("lage-hit for:", t)
        for title in ("Rules", "Task", "Clash", "Memory", "Register", "Lage"):
            block = t.split(f"## {title}")[1].split("\n", 1)[1]
            self.assertTrue(block.lstrip().startswith(("> source: `", "_skipped:")), title)

    def test_fixer_gets_report_and_befunde(self):
        w = self.w
        with open(os.path.join(w.herd, "reviere.out.md"), "w") as f:
            f.write("REPORT: done\n")
        with open(os.path.join(w.herd, "reviere.befunde-abc1234.md"), "w") as f:
            f.write("BEFUND: off by one\n")
        for ph, fields in (("accepted", {"prs": ["acme-api#1@abc1234"], "checks": []}),
                           ("review_running", {"run_id": "r", "round": 1}),
                           ("review_befund", {"prs": [], "run_id": "r", "befunde_file": "reviere.befunde-abc1234.md"}),
                           ("fix_queued", {"befunde_file": "reviere.befunde-abc1234.md"})):
            he.append(w.herd, "reviere", ph, **fields)
        t = self.ctx("fixer")
        self.assertIn("FIXER rules", t)
        self.assertIn("REPORT: done", t)
        self.assertIn("BEFUND: off by one", t)
        t = self.ctx("worker")
        self.assertIn("(fix round)", t)
        self.assertIn("BEFUND: off by one", t, "a worker in a fix round sees the befunde")

    def test_reviewer_pinned_heads(self):
        he.append(self.w.herd, "reviere", "accepted", prs=["acme-api#1@abc1234"], checks=[])
        t = self.ctx("reviewer")
        self.assertIn("review pinned to the accepted heads: acme-api#1@abc1234", t)
        self.assertIn("## Report", t)

    def test_every_source_absent_is_a_note(self):
        w = self.w
        os.remove(os.path.join(w.bin, "lage"))
        os.remove(os.path.join(self.project, "decisions-questions.json"))
        for role in ("WORKER", "REVIEWER", "FIXER"):
            os.remove(os.path.join(self.project, ".m2herd", "rules", f"{role}.md"))
        w.env["HERD_MEMORY_DIR"] = os.path.join(w.tmp, "nowhere")
        w.env["HERD_RULES_DIR"] = os.path.join(w.tmp, "nowhere")
        t = self.ctx("worker")
        self.assertIn("_skipped: lage not on PATH_", t)
        self.assertIn("_skipped: no register at", t)
        self.assertIn("_skipped: memory dir", t)
        # the skill's own templates/herd/rules may or may not exist in this checkout; both are fine
        self.assertTrue("## Rules (WORKER.md)\n\n> source:" in t or "_skipped: no rules file" in t)

    def test_register_env_wins(self):
        other = os.path.join(self.w.tmp, "reg.json")
        with open(other, "w") as f:
            json.dump({"decisions": [{"id": "d-from-env", "decision": "x", "refs": ["10000000001"]}]}, f)
        self.w.env["HERD_REGISTER"] = other
        t = self.ctx("worker")
        self.assertIn("d-from-env", t)
        self.assertNotIn("q-reviere-rollen", t)

    def test_print_and_bad_role(self):
        rc, out, err = self.w.run("herd-context", "worker", self.w.herd, "reviere", "--print")
        self.assertEqual(rc, 0, err)
        self.assertTrue(out.startswith("# Context worker — reviere"))
        rc, out, err = self.w.run("herd-context", "boss", self.w.herd, "reviere")
        self.assertEqual(rc, 2)


class Clash(unittest.TestCase):
    def setUp(self):
        w = self.w = World()
        w.repo("acme-api", {"src/a.py": "a\n", "src/b.py": "b\n", "tests/test_a.py": "t\n"})
        w.repo("acme-ui", {"lib/a.ts": "a\n"})
        for s, repo, files in (("one", "acme-api", {"src/a.py": "1\n", "tests/test_a.py": "1\n"}),
                               ("two", "acme-api", {"src/a.py": "2\n", "src/b.py": "2\n", "tests/test_a.py": "2\n"}),
                               ("three", "acme-api", {"src/b.py": "3\n"}),
                               ("four", "acme-ui", {"lib/a.ts": "4\n"})):
            wt = w.worktree(repo, s, f"br-{s}")
            w.commit(wt, files)
            w.slice(s, [(repo, f"br-{s}", "origin/main")], phase="working")
        w.slice("gone", [("acme-api", "br-gone", "origin/main")], phase="parked")

    def tearDown(self):
        self.w.close()

    def test_json_pairs(self):
        rc, out, err = self.w.run("herd-clash", self.w.herd, "--json")
        self.assertEqual(rc, 0, err)
        res = json.loads(out)
        pairs = {(p["repo"], tuple(p["slices"])): p["files"] for p in res["pairs"]}
        self.assertEqual(pairs, {("acme-api", ("one", "two")): ["src/a.py"],
                                 ("acme-api", ("three", "two")): ["src/b.py"]})
        self.assertEqual(sorted(o["other"] for o in res["by_slice"]["two"]), ["one", "three"])
        self.assertNotIn("four", res["by_slice"])

    def test_text_and_slice_filter(self):
        rc, out, err = self.w.run("herd-clash", self.w.herd, "--slice", "one")
        self.assertEqual(rc, 0, err)
        self.assertEqual(out.strip(), "acme-api: one ⇄ two: src/a.py")

    def test_wt_from_working_event(self):
        # a worktree outside HERD_WT_ROOT, named in the working event, is found
        w = self.w
        wt = w.worktree("acme-ui", "elsewhere-tmp", "br-five")
        w.commit(wt, {"lib/a.ts": "5\n"})
        moved = os.path.join(w.tmp, "custom", "acme-ui-five")
        os.makedirs(os.path.dirname(moved))
        os.rename(wt, moved)
        with open(os.path.join(w.herd, "five.repos"), "w") as f:
            f.write("acme-ui br-five origin/main\n")
        he.append(w.herd, "five", "working", wt=[moved])
        rc, out, err = w.run("herd-clash", w.herd, "--json")
        res = json.loads(out)
        self.assertIn(("acme-ui", ["five", "four"]), [(p["repo"], p["slices"]) for p in res["pairs"]])

    def test_selftests(self):
        for script in ("herd-clash", "register-excerpt.py"):
            rc, out, err = self.w.run(script, "--selftest")
            self.assertEqual(rc, 0, out + err)
            self.assertIn("0 failed", out)


if __name__ == "__main__":
    r = unittest.main(exit=False, verbosity=1).result
    print(f"herd-context/clash tests: {r.testsRun - len(r.failures) - len(r.errors)} passed, "
          f"{len(r.failures) + len(r.errors)} failed")
    sys.exit(0 if r.wasSuccessful() else 1)
