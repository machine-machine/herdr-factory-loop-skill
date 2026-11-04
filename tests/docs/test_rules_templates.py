#!/usr/bin/env python3
"""The rules templates render through herd-context, stay project-neutral, and agree with the scripts.

  python3 tests/docs/test_rules_templates.py

Offline: a temp herd with one slice, a ctx.env with every documented key, PATH holding only git and
python3 plus fake herdr/gh/lage that record any call (none is expected to matter for the rules).
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.realpath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", ".."))
RULES = os.path.join(REPO, "templates", "herd", "rules")
FACTORY = os.path.join(REPO, "templates", "factory")
FACTORY_TEMPLATES = ("concepts_brief.md", "spec-additions.md", "plan-additions.md", "REPORT.md")
LENSES = ("Domain", "Architecture", "Scope", "Comprehension")
CTX = os.path.join(REPO, "scripts", "herd-context")
sys.path.insert(0, os.path.join(REPO, "scripts"))
import herd_events as he  # noqa: E402

ok = fail = 0


def check(name, cond, detail=""):
    global ok, fail
    if cond:
        ok += 1
    else:
        fail += 1
        print(f"FAIL {name}\n{detail[-2500:]}")


# words of the fabric a team generalised its rules from: set HERD_LEAK_WORDS="word1,word2" locally so
# none of them survives in the templates; the generic part (orchestrator names, herd dirs) always runs
_LOCAL = [re.escape(w.strip()) for w in os.environ.get("HERD_LEAK_WORDS", "").split(",") if w.strip()]
PROJECT_WORDS = re.compile("|".join([r"workspace-\d", r"herde-\d"] + _LOCAL), re.I)


def _read(*parts):
    with open(os.path.join(REPO, *parts), encoding="utf-8") as f:
        return f.read()


def _section(text, heading, level="## "):
    """The body of `<level><heading>` up to the next heading of the same level ("" when absent)."""
    marker = f"\n{level}{heading}"
    if marker not in text:
        return ""
    body = text.split(marker, 1)[1].split("\n", 1)[1]
    return body.split(f"\n{level}", 1)[0]


PATH_TOKEN = re.compile(r"`([^`\s]*/[^`\s]*)`")


def check_full_track():
    """G1-LENSES.md: four lens sections, no placeholders, each lens names only the paths of its own
    reading list (spec FT-05 AC2); the lens list has one home (docs/factory-v3.md §4); the factory
    templates carry the sections and columns the full track relies on."""
    lenses = _read("templates", "herd", "rules", "G1-LENSES.md")
    check("G1-LENSES has no {{placeholders}}", "{{" not in lenses)
    for name in LENSES:
        sec = _section(lenses, name)
        check(f"G1-LENSES section {name}", bool(sec))
        for part in ("**Question.**", "**Reads**", "**Never reads**", "**Checks**", "**Agent type.**"):
            check(f"G1-LENSES {name} has {part}", part in sec)
        # every path a lens section names must stand in its Reads or Never-reads list
        listed = set()
        for label in ("**Reads**", "**Never reads**"):
            block = sec.split(label, 1)[1].split("\n**", 1)[0] if label in sec else ""
            listed |= set(PATH_TOKEN.findall(block))
        stray = sorted(set(PATH_TOKEN.findall(sec)) - listed)
        check(f"G1-LENSES {name} names only its reading list", not stray, ", ".join(stray))
    reads_shell = _section(lenses, "Domain") + _section(lenses, "Architecture")
    check("G1-LENSES domain + architecture run with a shell", reads_shell.count("General subagent with a shell") == 2)
    check("G1-LENSES architecture never reads the working tree", "working tree" in _section(lenses, "Architecture")
          and "git -C <repo> show <sha>:<path>" in _section(lenses, "Architecture"))
    check("G1-LENSES domain reads the copied sources", "`specs/<feature>/sources/`" in _section(lenses, "Domain"))
    check("G1-LENSES finding format is REVIEWER.md + lens name", "`REVIEWER.md`" in lenses and "lens: <name>" in lenses)

    # one home for the lens list: the factory-v3 §4 table; the other mentions point there
    v3 = _section(_read("docs", "factory-v3.md"), "4. G1")
    for name in LENSES:
        check(f"factory-v3 §4 lists lens {name.lower()}", f"\n| {name.lower()} |" in v3)
    for rel in ("templates/herd/rules/ORCHESTRATOR.md", "skill/SKILL.md"):
        text = _read(*rel.split("/"))
        check(f"{rel} points to factory-v3 §4 instead of listing lenses",
              "docs/factory-v3.md` §4" in text and not re.search(r"product, architecture, UX", text))
    orch = _section(_read("templates", "herd", "rules", "ORCHESTRATOR.md"), "0. Gates", "### ")
    for need in ("Pin the base", "Copy the sources", "never a team ticket", "subagent per lens", "at most 40 lines",
                 "one recommendation", "operator minutes", "provisional decision", "held: <slices>", "--open <k>"):
        check(f"ORCHESTRATOR step 0 says: {need}", need.lower() in orch.lower())

    brief = _read("templates", "factory", "concepts_brief.md")
    check("concepts_brief ≤ 60 lines", brief.count("\n") <= 60, str(brief.count("\n")))
    for h in ("## Who uses it and where", "## The problem reproduced", "## Open questions"):
        check(f"concepts_brief has {h}", f"\n{h}\n" in brief)
    check("concepts_brief has exactly three sections", brief.count("\n## ") == 3)
    spec = _read("templates", "factory", "spec-additions.md")
    check("spec-additions has a glossary", "\n## Glossary\n" in spec)
    for col in ("Rule", "Scope (Bundesland or federal)", "Source", "Locator", "Quoted passage", "Provisional"):
        check(f"spec-additions rules table has column {col}", f"| {col}" in spec)
    check("spec-additions links the contract section in plan-additions", "templates/factory/plan-additions.md" in spec
          and "## Contract section" not in spec)
    plan = _read("templates", "factory", "plan-additions.md")
    check("plan-additions readers table", "| Concept | Readers" in plan and "| Command used | Owner slice |" in plan)
    check("plan-additions has the contract section", "\n## Contract section\n" in plan and "one page" in plan)
    check("plan-additions has reserved resources", "\n## Reserved resources\n" in plan)
    report = _read("templates", "factory", "REPORT.md")
    check("REPORT has the cause column", "| Cause |" in report and "spec / cut / domain / code / integration" in report)
    check("REPORT counts questions at G1 vs after start", "found at g1" in report.lower() and "after start" in report.lower())


def main():
    files = ["WORKER.md", "REVIEWER.md", "FIXER.md", "MODELS.md", "ORCHESTRATOR.md", "HERD-CUT.md", "STEER.md", "GOLDFISH.md",
             "G1-LENSES.md"]
    for n in files:
        check(f"{n} exists", os.path.isfile(os.path.join(RULES, n)))
    extra = [os.path.join(REPO, "templates", "herd", n) for n in ("COMMON.md", "task.md.example")]
    for n in FACTORY_TEMPLATES:
        check(f"templates/factory/{n} exists", os.path.isfile(os.path.join(FACTORY, n)))
    extra += [os.path.join(FACTORY, n) for n in FACTORY_TEMPLATES]
    for p in [os.path.join(RULES, n) for n in files] + extra:
        with open(p, encoding="utf-8") as f:
            text = f.read()
        hits = sorted({m.group(0) for m in PROJECT_WORDS.finditer(text)})
        check(f"{os.path.basename(p)} is project-neutral", not hits, ", ".join(hits))

    # the ctx.env keys documented in COMMON.md are exactly the placeholders the role files use
    with open(os.path.join(REPO, "templates", "herd", "COMMON.md"), encoding="utf-8") as f:
        common = f.read()
    documented = {k.lower() for k in re.findall(r"^\s{4}([A-Z_]+)=", common, re.M)}
    builtin = {"herd", "slice", "role", "report", "status", "worktrees", "base_shas", "orch_pane"}
    used = set()
    for n in ("WORKER.md", "REVIEWER.md", "FIXER.md"):
        with open(os.path.join(RULES, n), encoding="utf-8") as f:
            used |= set(re.findall(r"\{\{\s*([a-z_]+)\s*\}\}", f.read()))
    check("every placeholder is built in or documented", used <= builtin | documented,
          f"undocumented: {sorted(used - builtin - documented)}")
    check("every documented key is used", documented <= used, f"unused: {sorted(documented - used)}")

    # the example task header parses with the event core
    tmp = tempfile.mkdtemp(prefix="rules-templates-test-")
    try:
        herd = os.path.join(tmp, "herd")
        os.makedirs(herd)
        shutil.copy(os.path.join(REPO, "templates", "herd", "task.md.example"), os.path.join(herd, "invoice-export.task.md"))
        hdr = he.task_header(herd, "invoice-export")
        check("example header parses", hdr.get("tickets") == ["1111111111", "2222222222"]
              and hdr.get("together_with") == ["invoice-export-ui"] and hdr.get("stacked_on") == "pdf-layout"
              and hdr.get("model") == "claude-opus-5-5" and hdr.get("effort") == "high"
              and len(hdr.get("needs_memory") or []) == 2 and hdr.get("keywords"), repr(hdr))
        with open(os.path.join(herd, "invoice-export.repos"), "w") as f:
            f.write("acme-api feat/invoice-export origin/main\n")
        with open(os.path.join(herd, "ctx.env"), "w") as f:
            for k in sorted(documented):
                f.write(f"{k.upper()}=value-of-{k}\n")
        fake = os.path.join(tmp, "bin")
        os.makedirs(fake)
        log = os.path.join(tmp, "calls.log")
        for b in ("git", "python3"):
            w = shutil.which(b)
            if w:
                os.symlink(w, os.path.join(fake, b))
        for b in ("herdr", "gh", "lage"):
            with open(os.path.join(fake, b), "w") as f:
                f.write(f"#!/bin/sh\necho \"{b} $*\" >> {log}\nexit 1\n")
            os.chmod(os.path.join(fake, b), 0o755)
        env = {k: v for k, v in os.environ.items() if not k.startswith("HERD_")}
        env.update(PATH=fake, HOME=os.path.join(tmp, "home"), HERD_MEMORY_DIR=os.path.join(tmp, "mem"),
                   HERD_ORCH_PANE="p1")
        for role in ("worker", "reviewer", "fixer"):
            p = subprocess.run([sys.executable, CTX, role, herd, "invoice-export", "--print"],
                               capture_output=True, text=True, env=env, cwd=tmp)
            check(f"herd-context {role} exit 0", p.returncode == 0, p.stdout + p.stderr)
            out = p.stdout
            check(f"{role} rules section present", f"## Rules ({role.upper()}.md)" in out
                  and os.path.join(RULES, f"{role.upper()}.md") in out, out[:1500])
            check(f"{role} no unfilled placeholders", "unfilled placeholders" not in out
                  and not re.search(r"\{\{\s*[a-z_]+\s*\}\}", out), out[:1500])
            check(f"{role} values filled", "value-of-" in out and herd in out, out[:1500])
        # an unset key is reported, not silently dropped
        os.remove(os.path.join(herd, "ctx.env"))
        p = subprocess.run([sys.executable, CTX, "worker", herd, "invoice-export", "--print"],
                           capture_output=True, text=True, env=env, cwd=tmp)
        check("missing values listed in the head", "unfilled placeholders:" in p.stdout
              and "orchestrator" in p.stdout.split("unfilled placeholders:")[1].splitlines()[0], p.stdout[:1500])
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    # MODELS.md carries the spec table (docs/herd-flow-v2.md §6) row for row, plus a reason column
    with open(os.path.join(REPO, "docs", "herd-flow-v2.md"), encoding="utf-8") as f:
        spec = f.read()
    sec = spec.split("## 6.", 1)[1].split("\n## ", 1)[0]
    spec_rows = [r for r in sec.splitlines() if r.startswith("| ") and not r.startswith("| Task") and "---" not in r]
    with open(os.path.join(RULES, "MODELS.md"), encoding="utf-8") as f:
        models = f.read()
    for r in spec_rows:
        cells = [c.strip() for c in r.strip("|").split("|")]
        check(f"MODELS row: {cells[0][:40]}", any(ln.startswith(f"| {cells[0]} | {cells[1]} | {cells[2]} | ")
                                                  for ln in models.splitlines()), r)
    check("MODELS has a Why column", "| Task | Model | Effort | Why |" in models)

    # SKILL.md frontmatter description stays under the 1024-char cap and the version matches CHANGELOG
    with open(os.path.join(REPO, "skill", "SKILL.md"), encoding="utf-8") as f:
        skill = f.read()
    m = re.search(r"^description:\s*'(.*)'\s*$", skill, re.M)
    check("SKILL description < 1024 chars", m and len(m.group(1)) < 1024, str(len(m.group(1)) if m else None))
    ver = re.search(r"^version:\s*(\S+)", skill, re.M).group(1)
    with open(os.path.join(REPO, "CHANGELOG.md"), encoding="utf-8") as f:
        latest = re.search(r"^## \[(\d+\.\d+\.\d+(?:-[0-9A-Za-z.]+)?)\]", f.read(), re.M).group(1)
    check("SKILL version == CHANGELOG latest", ver == latest, f"{ver} {latest}")

    # the published docs carry examples, never the source fabric's ticket ids or memory file names
    leaks = re.compile("|".join([r"\b\d{11}\b"] + _LOCAL), re.I)
    for rel in ("docs/herd-flow-v2.md", "README.md", "CHANGELOG.md", "skill/SKILL.md", "templates/herd/workflows/README.md",
                "docs/factory-v3.md", "templates/herd/rules/G1-LENSES.md") + tuple(f"templates/factory/{n}" for n in FACTORY_TEMPLATES):
        with open(os.path.join(REPO, rel), encoding="utf-8") as f:
            hits = sorted({m.group(0) for m in leaks.finditer(f.read())})
        check(f"{rel} carries no project ids", not hits, ", ".join(hits))

    check_full_track()

    print(f"test_rules_templates: {ok} passed, {fail} failed")
    return 0 if fail == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
