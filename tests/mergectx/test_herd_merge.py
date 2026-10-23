#!/usr/bin/env python3
"""herd-merge against temp git repos and a fake gh (no network, no herdr)."""
import json
import os
import sys
import unittest

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from world import World, he  # noqa: E402

TEN = "".join(f"line {i}\n" for i in range(1, 11))


class Base(unittest.TestCase):
    def setUp(self):
        self.w = World()

    def tearDown(self):
        self.w.close()

    def merge(self, pkg, *extra, go="merge reviere"):
        args = [self.w.herd, pkg] + (["--go", go] if go is not None else []) + list(extra)
        return self.w.run("herd-merge", *args)

    def phase(self, s):
        return he.last(self.w.herd, s)["phase"]

    def pair(self, ui_extra=None):
        """reviere (api) + reviere-ui (ui), one package."""
        w = self.w
        w.repo("acme-api", {"app.py": "a\n"})
        w.repo("acme-ui", {"page.tsx": "u\n"})
        wa = w.worktree("acme-api", "reviere", "reviere-api")
        sa = w.commit(wa, {"reviere.py": "r\n"})
        wu = w.worktree("acme-ui", "reviere-ui", "reviere-ui")
        su = w.commit(wu, {"reviere.tsx": "r\n"})
        na = w.open_pr("acme-api", "reviere-api")
        nu = w.open_pr("acme-ui", "reviere-ui", **(ui_extra or {}))
        mains = [f"acme-api@{w.main_sha('acme-api')}", f"acme-ui@{w.main_sha('acme-ui')}"]
        w.slice("reviere", [("acme-api", "reviere-api", "origin/main")], {"tickets": "111"},
                prs=[f"acme-api#{na}@{sa}"], mains=mains)
        w.slice("reviere-ui", [("acme-ui", "reviere-ui", "origin/main")], {"together_with": "reviere"},
                prs=[f"acme-ui#{nu}@{su}"], mains=mains)
        return wa, wu


class Refusals(Base):
    def test_never_without_go(self):
        self.pair()
        rc, out, err = self.merge("reviere", go=None)
        self.assertEqual(rc, 2)
        self.assertIn("--go", err)
        self.assertEqual(self.w.calls(), [])
        rc, _, _ = self.merge("reviere", go="   ")
        self.assertEqual(rc, 2)

    def test_partner_not_review_ok(self):
        w = self.w
        w.repo("acme-api", {"app.py": "a\n"})
        wa = w.worktree("acme-api", "reviere", "reviere-api")
        sa = w.commit(wa, {"r.py": "r\n"})
        n = w.open_pr("acme-api", "reviere-api")
        w.slice("reviere", [("acme-api", "reviere-api", "origin/main")],
                prs=[f"acme-api#{n}@{sa}"], mains=[f"acme-api@{w.main_sha('acme-api')}"])
        w.slice("reviere-ui", [("acme-ui", "reviere-ui", "origin/main")], {"together_with": "reviere"},
                phase="accepted")
        rc, out, err = self.merge("reviere")
        self.assertEqual(rc, 1)
        self.assertIn("reviere-ui is accepted", err)
        self.assertEqual(w.calls(["pr", "merge"]), [])

    def test_pair_checked_mergeable_before_first_merge(self):
        # 23.10.: api #210 merged before its pair ui #86, which was already conflicting
        self.pair(ui_extra={"mergeable": "CONFLICTING"})
        rc, out, err = self.merge("reviere")
        self.assertEqual(rc, 1, out + err)
        self.assertIn("mergeable CONFLICTING", err)
        self.assertEqual(self.w.calls(["pr", "merge"]), [])
        self.assertEqual(self.w.pr("acme-api", 1)["state"], "OPEN")
        self.assertEqual(self.phase("reviere"), "review_ok")

    def test_stale_head(self):
        wa, _ = self.pair()
        self.w.commit(wa, {"later.py": "x\n"})
        rc, out, err = self.merge("reviere")
        self.assertEqual(rc, 1)
        self.assertIn("stale", err)
        self.assertEqual(self.w.calls(["pr", "merge"]), [])

    def test_stale_main(self):
        self.pair()
        other = self.w.worktree("acme-api", "other", "other")
        self.w.sh(other, "git", "checkout", "-q", "-B", "main", "origin/main")
        self.w.commit(other, {"elsewhere.py": "e\n"})
        rc, out, err = self.merge("reviere")
        self.assertEqual(rc, 1)
        self.assertIn("moved", err)
        self.assertEqual(self.w.calls(["pr", "merge"]), [])

    def test_base_not_main(self):
        self.pair()
        self.w.set_pr("acme-ui", 1, base="develop")
        rc, out, err = self.merge("reviere")
        self.assertEqual(rc, 1)
        self.assertIn("base develop", err)


class DryRun(Base):
    def test_plan_order_and_no_writes(self):
        self.pair()
        rc, out, err = self.merge("reviere-ui", "--dry-run", go=None)
        self.assertEqual(rc, 0, err)
        self.assertLess(out.index("acme/acme-api#1"), out.index("acme/acme-ui#1"))
        self.assertIn("gh pr merge 1 --repo acme/acme-api --squash --match-head-commit", out)
        self.assertIn("record: herd-phase merged reviere", out)
        writes = [c for c in self.w.calls() if c[:2] == ["pr", "merge"] or "-X" in c]
        self.assertEqual(writes, [])
        self.assertEqual(self.phase("reviere"), "review_ok")

    def test_merge_order_env(self):
        self.pair()
        self.w.env["HERD_MERGE_ORDER"] = "acme-ui,acme-api"
        rc, out, err = self.merge("reviere", "--dry-run")
        self.assertEqual(rc, 0, err)
        self.assertLess(out.index("acme/acme-ui#1 ("), out.index("acme/acme-api#1 ("))


class Merges(Base):
    def test_pair_merges_api_first_and_records_go(self):
        self.pair()
        go = "merge reviere — passt so"
        rc, out, err = self.merge("reviere", go=go)
        self.assertEqual(rc, 0, out + err)
        merges = [c[c.index("--repo") + 1] for c in self.w.calls(["pr", "merge"])]
        self.assertEqual(merges, ["acme/acme-api", "acme/acme-ui"])
        for s in ("reviere", "reviere-ui"):
            ev = he.last(self.w.herd, s)
            self.assertEqual(ev["phase"], "merged")
            self.assertEqual(ev["go"], go)
            self.assertEqual(ev["by"], "merge")
            self.assertRegex(ev["prs"][0], r"^acme-(api|ui)#1@[0-9a-f]{7}$")
        self.assertIsNone(self.w.sh(self.w.tmp, "git", "-C", os.path.join(self.w.tmp, "acme-api.git"),
                                    "branch", "--list", "reviere-api") or None)
        with open(os.path.join(self.w.herd, "herd-merge.log")) as f:
            log = [json.loads(x) for x in f]
        self.assertEqual(log[-1]["go"], go)
        self.assertEqual(log[-1]["outcome"], "ok")

    def test_go_is_capped(self):
        self.pair()
        rc, out, err = self.merge("reviere", go="x" * 300)
        self.assertEqual(rc, 0, err)
        self.assertEqual(len(he.last(self.w.herd, "reviere")["go"]), 120)

    def test_stops_at_first_failure_then_resumes(self):
        w = self.w
        w.repo("acme-api", {"app.py": "a\n"})
        w.repo("acme-ui", {"page.tsx": "u\n"})
        heads = {}
        for s, repo, f in (("a", "acme-api", "a.py"), ("b", "acme-api", "b.py"), ("c", "acme-ui", "c.tsx")):
            wt = w.worktree(repo, s, f"br-{s}")
            heads[s] = (repo, w.commit(wt, {f: s}), w.open_pr(repo, f"br-{s}"))
        mains = [f"acme-api@{w.main_sha('acme-api')}", f"acme-ui@{w.main_sha('acme-ui')}"]
        for s, (repo, sha, n) in heads.items():
            w.slice(s, [(repo, f"br-{s}", "origin/main")], {"together_with": "a"} if s != "a" else None,
                    prs=[f"{repo}#{n}@{sha}"], mains=mains)
        w.set_pr("acme-api", heads["b"][2], fail_merge=True)
        rc, out, err = self.merge("a")
        self.assertEqual(rc, 1, out)
        self.assertIn("STOP", err)
        self.assertEqual(self.phase("a"), "merged")
        self.assertEqual(self.phase("b"), "review_ok")
        self.assertEqual(self.phase("c"), "review_ok")
        self.assertEqual(w.pr("acme-ui", heads["c"][2])["state"], "OPEN", "never past a half-merged package")
        w.set_pr("acme-api", heads["b"][2], fail_merge=False)
        rc, out, err = self.merge("c")
        self.assertEqual(rc, 0, out + err)
        self.assertIn("already merged: a", out)
        self.assertEqual([self.phase(s) for s in "abc"], ["merged"] * 3)

    def test_slice_merged_before_the_run_is_recorded(self):
        # crash between `gh pr merge` and the merged event, or a merge by hand on GitHub
        w = self.w
        self.pair()
        sha = w.sh(w.tmp, "git", "-C", os.path.join(w.tmp, "acme-api.git"), "rev-parse", "refs/heads/reviere-api")
        w.sh(w.tmp, "gh", "pr", "merge", "1", "--repo", "acme/acme-api", "--squash", "--match-head-commit", sha)
        self.assertEqual(w.pr("acme-api", 1)["state"], "MERGED")
        rc, out, err = self.merge("reviere", go="merge reviere")
        self.assertEqual(rc, 0, out + err)
        self.assertIn("already merged as", out)
        for s in ("reviere", "reviere-ui"):
            ev = he.last(w.herd, s)
            self.assertEqual(ev["phase"], "merged", s)
            self.assertEqual(ev["go"], "merge reviere")
        self.assertEqual(he.last(w.herd, "reviere")["prs"], [f"acme-api#1@{w.pr('acme-api', 1)['merge_commit'][:7]}"])
        self.assertEqual([c[c.index("--repo") + 1] for c in w.calls(["pr", "merge"])],
                         ["acme/acme-api", "acme/acme-ui"], "the pre-merged PR is not merged again")
        rc, out, err = self.merge("reviere", go="merge reviere")
        self.assertEqual(rc, 0, out + err)
        self.assertIn("nothing left to merge", out)


class Races(Base):
    """GitHub changes between the package preflight and a merge: the re-read and --match-head-commit."""
    API_MERGED = ["pr", "merge", "1", "--repo", "acme/acme-api"]
    UI_MAIN = ["api", "repos/acme/acme-ui/git/ref/heads/main"]

    def push(self, wt, ref="reviere-ui"):
        return (f"git -C {wt} commit -q --allow-empty -m late && "
                f"git -C {wt} push -q origin HEAD:{ref}")

    def assert_ui_not_merged(self, rc, out, err):
        self.assertEqual(rc, 1, out + err)
        self.assertEqual(self.w.pr("acme-ui", 1)["state"], "OPEN")
        self.assertEqual(self.phase("reviere"), "merged")
        self.assertEqual(self.phase("reviere-ui"), "review_ok")

    def test_reread_catches_head_moved_after_preflight(self):
        _, wu = self.pair()
        self.w.after(self.API_MERGED, 1, self.push(wu))
        rc, out, err = self.merge("reviere")
        self.assert_ui_not_merged(rc, out, err)
        self.assertIn("re-read before merge failed", err)
        self.assertIn("≠ expected", err)

    def test_reread_catches_main_moved_after_preflight(self):
        self.pair()
        other = self.w.worktree("acme-ui", "other", "other")
        self.w.sh(other, "git", "checkout", "-q", "-B", "main", "origin/main")
        self.w.after(self.API_MERGED, 1, self.push(other, "main"))
        rc, out, err = self.merge("reviere")
        self.assert_ui_not_merged(rc, out, err)
        self.assertIn("re-read before merge failed", err)
        self.assertIn("moved", err)

    def test_match_head_commit_catches_head_moved_after_reread(self):
        _, wu = self.pair()
        self.w.after(self.UI_MAIN, 2, self.push(wu))  # 2nd = the re-read right before the ui merge
        rc, out, err = self.merge("reviere")
        self.assert_ui_not_merged(rc, out, err)
        self.assertIn("--match-head-commit", " ".join(self.w.calls(["pr", "merge", "1", "--repo", "acme/acme-ui"])[0]))


class Stacks(Base):
    def stack(self, child_phase="review_ok", in_package=False, change_patch=False):
        """kartenstil (api ks) <- kollision (api ko, base ks)."""
        w = self.w
        w.repo("acme-api", {"app.py": "a\n"})
        wp = w.worktree("acme-api", "kartenstil", "ks")
        p1 = w.commit(wp, {"f.txt": TEN}, "parent 1")
        wc = w.worktree("acme-api", "kollision", "ko", base="ks")
        c = w.commit(wc, {"f.txt": TEN.replace("line 5\n", "line 5 child\n")}, "child")
        ph = p1
        if change_patch:  # parent moves on after the child branched: the child's patch context changes
            self.w.sh(wp, "git", "pull", "-q", "--ff-only")
            ph = w.commit(wp, {"f.txt": TEN.replace("line 3\n", "line 3 parent\n")}, "parent 2")
        np_ = w.open_pr("acme-api", "ks")
        nc = w.open_pr("acme-api", "ko", base="ks")
        mains = [f"acme-api@{w.main_sha('acme-api')}"]
        w.slice("kartenstil", [("acme-api", "ks", "origin/main")], prs=[f"acme-api#{np_}@{ph}"], mains=mains)
        hdr = {"stacked_on": "kartenstil"}
        if in_package:
            hdr["together_with"] = "kartenstil"
        w.slice("kollision", [("acme-api", "ko", "ks")], hdr, phase=child_phase,
                prs=[f"acme-api#{nc}@{c}"], mains=mains)
        return wp, wc, np_, nc, c

    def test_child_restacked_retargeted_before_parent_branch_deleted(self):
        wp, wc, np_, nc, old = self.stack()
        rc, out, err = self.merge("kartenstil", go="merge kartenstil")
        self.assertEqual(rc, 0, out + err)
        self.assertIn("range-diff '=' only", out)
        calls = self.w.calls()
        patch = next(i for i, c in enumerate(calls) if "PATCH" in c)
        delete = next(i for i, c in enumerate(calls) if "DELETE" in c)
        self.assertLess(patch, delete, "retarget before deleting the parent branch")
        pr = self.w.pr("acme-api", nc)
        self.assertEqual((pr["state"], pr["base"]), ("OPEN", "main"))
        new = self.w.sh(wc, "git", "rev-parse", "HEAD")
        self.assertNotEqual(new, old)
        self.assertEqual(self.w.sh(wc, "git", "rev-parse", "origin/ko"), new)
        self.assertEqual(self.w.sh(wc, "git", "rev-list", "--count", "origin/main..HEAD"), "1")
        self.assertEqual(self.phase("kollision"), "review_ok")

    def test_changed_patch_stops_and_queues_fix(self):
        wp, wc, np_, nc, old = self.stack(change_patch=True)
        rc, out, err = self.merge("kartenstil", go="merge kartenstil")
        self.assertEqual(rc, 1, out + err)
        self.assertEqual(self.phase("kartenstil"), "merged")
        ev = he.last(self.w.herd, "kollision")
        self.assertEqual(ev["phase"], "fix_queued")
        self.assertTrue(os.path.exists(os.path.join(self.w.herd, ev["befunde_file"])))
        self.assertEqual(self.w.sh(wc, "git", "rev-parse", "HEAD"), old, "child reset to its old head")
        self.assertEqual(self.w.sh(wc, "git", "rev-parse", "origin/ko"), old, "nothing pushed")
        pr = self.w.pr("acme-api", nc)
        self.assertEqual((pr["state"], pr["base"]), ("OPEN", "ks"), "parent branch kept, child PR not closed")
        self.assertEqual([c for c in self.w.calls() if "DELETE" in c], [])

    def test_working_child_left_alone(self):
        wp, wc, np_, nc, old = self.stack(child_phase="working")
        rc, out, err = self.merge("kartenstil", go="merge kartenstil")
        self.assertEqual(rc, 0, out + err)
        self.assertIn("not restacked (kollision is working)", out)
        self.assertEqual(self.w.sh(wc, "git", "rev-parse", "HEAD"), old)
        pr = self.w.pr("acme-api", nc)
        self.assertEqual((pr["state"], pr["base"]), ("OPEN", "ks"))
        self.assertEqual([c for c in self.w.calls() if "DELETE" in c], [])

    def test_stack_inside_package_merges_both(self):
        wp, wc, np_, nc, old = self.stack(in_package=True)
        rc, out, err = self.merge("kollision", "--dry-run", go=None)
        self.assertEqual(rc, 0, err)
        self.assertLess(out.index(f"acme/acme-api#{np_} ("), out.index(f"acme/acme-api#{nc} ("))
        self.assertIn("rebase --onto origin/main", out)
        rc, out, err = self.merge("kollision", go="merge kartenstil kollision")
        self.assertEqual(rc, 0, out + err)
        self.assertEqual([self.phase("kartenstil"), self.phase("kollision")], ["merged", "merged"])
        self.assertEqual(self.w.pr("acme-api", nc)["state"], "MERGED")
        log = self.w.sh(self.w.tmp, "git", "-C", os.path.join(self.w.tmp, "acme-api.git"),
                        "log", "--format=%s", "main")
        self.assertEqual(log.split("\n")[:2], [f"squash #{nc}", f"squash #{np_}"])

    def test_stack_inside_package_not_on_parent_head_refuses_before_first_merge(self):
        wp, wc, np_, nc, old = self.stack(in_package=True, change_patch=True)
        rc, out, err = self.merge("kollision", go="merge beides")
        self.assertEqual(rc, 1, out + err)
        self.assertIn("not built on the parent's reviewed head", err)
        self.assertEqual(self.w.calls(["pr", "merge"]), [])
        self.assertEqual(self.phase("kartenstil"), "review_ok")

    def test_external_base_not_merged_refuses(self):
        self.stack()
        rc, out, err = self.merge("kollision", go="merge kollision")
        self.assertEqual(rc, 1)
        self.assertIn("stacked on kartenstil", err)


if __name__ == "__main__":
    r = unittest.main(exit=False, verbosity=1).result
    print(f"herd-merge tests: {r.testsRun - len(r.failures) - len(r.errors)} passed, "
          f"{len(r.failures) + len(r.errors)} failed")
    sys.exit(0 if r.wasSuccessful() else 1)
