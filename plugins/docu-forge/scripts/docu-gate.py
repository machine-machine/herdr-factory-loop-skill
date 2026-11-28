#!/usr/bin/env python3
"""docu-gate — the cost gate. Nothing is generated until this passes and a human approves.

  docu-gate.py <project-dir>

Fails on: a scene without narration or visual, a character missing from characters.md, a
narration line citing [Sn] without a source, a source that is not in research.md, a total
runtime more than 15 % off the brief, a hook scene over 15 s, and a broken plan header.
Exit 0 clear, 1 findings, 2 bad input.
"""
import csv
import re
import sys
from pathlib import Path

HEADER = ["scene", "duration_s", "narration", "visual", "characters", "sources"]


def main(argv):
    if len(argv) < 2:
        print("usage: docu-gate.sh <project-dir>", file=sys.stderr)
        return 2
    d = Path(argv[1])
    for name in ("brief.md", "characters.md", "scene-plan.csv", "research.md"):
        if not (d / name).is_file():
            print(f"missing {d / name}", file=sys.stderr)
            return 2

    rows = list(csv.reader((d / "scene-plan.csv").open(newline="", encoding="utf-8")))
    if not rows or [c.strip() for c in rows[0]] != HEADER:
        print("scene-plan.csv must start with: " + ",".join(HEADER), file=sys.stderr)
        return 2

    chars = {
        m.group(1).strip().lower()
        for m in re.finditer(r"^##\s+(.+?)\s*$", (d / "characters.md").read_text(), re.M)
    }
    sources = {
        m.group(1)
        for m in re.finditer(r"^\[(S\d+)\]", (d / "research.md").read_text(), re.M)
    }
    brief = (d / "brief.md").read_text()
    mins = re.search(r"length[^\n]*?(\d+)", brief, re.I)
    target = int(mins.group(1)) * 60 if mins else 600

    findings, total = [], 0
    for i, row in enumerate(rows[1:], start=1):
        if not any(c.strip() for c in row):
            continue
        row += [""] * (6 - len(row))
        scene, dur, narr, visual, cast, srcs = [c.strip() for c in row[:6]]
        if not dur.isdigit():
            findings.append(f"scene {scene or i}: duration_s not an integer ('{dur}')")
            dur = "0"
        total += int(dur)
        if not narr:
            findings.append(f"scene {scene or i}: no narration")
        if not visual:
            findings.append(f"scene {scene or i}: no visual")
        if i == 1 and int(dur) > 15:
            findings.append(f"scene {scene}: hook runs {dur}s — the hook must land inside 15s")
        for c in (c.strip() for c in cast.split(",")):
            if c and c.lower() not in chars:
                findings.append(f"scene {scene}: character '{c}' not in characters.md")
        cited = set(re.findall(r"S\d+", narr))
        if cited:
            if not srcs:
                findings.append(f"scene {scene}: narration cites a source but the sources column is empty")
            for s in sorted(cited):
                if s not in sources:
                    findings.append(f"scene {scene}: {s} is not in research.md")

    lo, hi = target * 85 // 100, target * 115 // 100
    if not lo <= total <= hi:
        findings.append(f"total {total}s is outside {lo}-{hi}s (±15 % of the {target}s target)")

    for f in findings:
        print(f)
    if findings:
        print(f"GATE FAIL — {round(total / 60)} min planned, {len(findings)} finding(s). "
              "Fix the plan, then re-run.")
        return 1
    print(f"GATE PASS — ~{total}s. Now get the human's approval before generating.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))