#!/usr/bin/env python3
"""The long run's new statistics: python3 site/test_runstats.py

batch314 C (viewer Aurora 11:38: completed repeatable-research levels; science made beside the recorded consumption per
pack; "Unique technologies"; what SPM measures). A made-up run of 3 shifts:
- repeatable levels from the score's `infinite` (levels done past each infinite technology's own first level): per row,
  per shift (+new and by technology), over the run by technology with its first completed level and next level; never
  in the unique technologies count;
- packs made and consumed over the same row pairs (both rows carrying consumption; the first row has none, so its
  packs are left out of this table only), counted as rises; a fall is named with its shift and not subtracted;
- the page: "unique technologies" everywhere the count shows, the repeatable levels tile, record, shift column and
  chart, the made/consumed and repeatable tables with their sources, and SPM labelled as pack use, not research
  progress; a shift page's own made/consumed and levels; check.py passes.
"""
import json, re, subprocess, sys, tempfile
from pathlib import Path

SITE = Path(__file__).resolve().parent
sys.path.insert(0, str(SITE))
import longrun  # noqa: E402

MIN = 3600


def row(t, minute, red, space, used=None, infinite=None, done=("automation",)):
    sc = {"tick": minute * MIN, "research_done": list(done), "rockets": 0, "planets": ["nauvis"], "platforms": [],
          "produced": {"automation-science-pack": red, "space-science-pack": space}}
    if used is not None:
        sc["consumed"] = used
    if infinite:
        sc["infinite"] = infinite
    return json.dumps({"t": t, "world": "n", "score": sc})


def make(root):
    shifts = [
        # shift 1: no consumption in its first row; mining productivity's first level at minute 20
        [row("2026-10-01T00:00:00", 0, 100, 0),
         row("2026-10-01T00:10:00", 10, 200, 0, {"automation-science-pack": 150}),
         row("2026-10-01T00:20:00", 20, 300, 50, {"automation-science-pack": 240, "space-science-pack": 10}, {"mining-productivity-3": 1})],
        # shift 2: the space counter falls by 30 (a platform lost), then rises again; two more levels
        [row("2026-10-01T02:00:00", 20, 300, 50, {"automation-science-pack": 240, "space-science-pack": 10}, {"mining-productivity-3": 1}),
         row("2026-10-01T02:10:00", 30, 400, 20, {"automation-science-pack": 330, "space-science-pack": 15}, {"mining-productivity-3": 2}),
         row("2026-10-01T02:20:00", 40, 500, 60, {"automation-science-pack": 420, "space-science-pack": 25},
             {"mining-productivity-3": 2, "physical-projectile-damage-7": 1}, done=("automation", "electronics"))],
        # shift 3: one more level of each
        [row("2026-10-01T04:00:00", 40, 500, 60, {"automation-science-pack": 420, "space-science-pack": 25},
             {"mining-productivity-3": 2, "physical-projectile-damage-7": 1}, done=("automation", "electronics")),
         row("2026-10-01T04:10:00", 50, 600, 70, {"automation-science-pack": 510, "space-science-pack": 30},
             {"mining-productivity-3": 3, "physical-projectile-damage-7": 2}, done=("automation", "electronics"))]]
    for k, lines in enumerate(shifts, 1):
        d = root / f"rs{k}"
        d.mkdir(parents=True)
        if k > 1:
            (d / "resumed-from").write_text(f"rs{k - 1}\n")
        (d / "scores.jsonl").write_text("\n".join(lines) + "\n")
        (d / "start.log").write_text("00:00:00 start\n")


def check(name, cond, info=""):
    assert cond, f"{name}: {info}"


def text(html_):
    return re.sub(r"\s+", " ", re.sub(r"<[^>]+>", " ", html_)).replace("&amp;", "&")


def main():
    with tempfile.TemporaryDirectory() as d:
        root, out = Path(d) / "runs", Path(d) / "dist"
        make(root)
        lr = longrun.load(root, start="rs1")
        s1, s2, s3 = [s for s in lr["shifts"] if not s.get("empty")]
        check("levels by shift", [(s["levels"], s["levels_new"]) for s in (s1, s2, s3)] == [(1, 1), (3, 2), (5, 2)],
              [(s["levels"], s["levels_new"]) for s in (s1, s2, s3)])
        check("levels by technology", s2["level_techs"] == {"mining-productivity-3": 1, "physical-projectile-damage-7": 1}, s2["level_techs"])
        check("not in unique technologies", s3["research"] == 2, s3["research"])
        rep = {r["name"]: r for r in lr["repeatable"]}
        check("repeatable", rep["mining-productivity-3"]["levels"] == 3 and rep["mining-productivity-3"]["under_way"] == "Mining productivity 6"
              and rep["mining-productivity-3"]["first"]["shift"] == 1 and rep["physical-projectile-damage-7"]["first"]["shift"] == 2, lr["repeatable"])
        check("levels series", lr["levels"][-1] == (50.0, 5), lr["levels"][-1])
        # made and consumed over matched pairs: from the second row (the first has no consumption)
        f = lr["flow"]
        check("red matched", (f["made"]["automation-science-pack"], f["used"]["automation-science-pack"]) == (400, 360), f)
        check("space matched", (f["made"]["space-science-pack"], f["used"]["space-science-pack"]) == (50 + 40 + 10, 30), f)
        check("made total", lr["made"]["automation-science-pack"] == 600, lr["made"])  # every row, the first included
        check("fall", lr["falls"]["made"]["space-science-pack"] == {"times": 1, "total": 30, "shifts": [2], "by_shift": {2: 30}}, lr["falls"])
        check("from", lr["flow_from"]["x"] == 10.0 and lr["flow_from"]["shift"] == 1, lr["flow_from"])
        check("shift flow", s2["flow"]["made"]["space-science-pack"] == 40 and s2["flow"]["used"]["space-science-pack"] == 15, s2["flow"])

        content = json.loads((SITE / "content" / "site.json").read_text())
        content.update(run_start="rs1", archive=False)
        (Path(d) / "site.json").write_text(json.dumps(content))
        subprocess.run([sys.executable, str(SITE / "build.py"), "--out", str(out), "--runs-dir", str(root),
                        "--content", str(Path(d) / "site.json"), "--stats-cache", str(Path(d) / "cache")], check=True, capture_output=True)
        r = subprocess.run([sys.executable, str(SITE / "check.py"), str(out)], capture_output=True, text=True)
        check("check.py", r.returncode == 0, r.stdout)
        page = (out / "runs" / "long" / "index.html").read_text()
        t = text(page)
        check("unique technologies tile", "2 unique technologies" in t, re.findall(r"\d+ unique technologies", t))
        check("repeatable tile", "5 repeatable levels 2 infinite technologies" in t)
        check("no bare technologies tile", 'class="stat-label"><img class="gi" src="/static/game/item/lab.webp" width="28" height="28" alt="" loading="lazy" decoding="async"><span>technologies<' not in page)
        check("record", "Most repeatable levels in a shift" in t and "Most unique technologies in a shift" in t)
        check("shift column", "<th scope=\"col\">Unique technologies</th><th scope=\"col\">Repeatable levels</th>" in page)
        check("chart", "Repeatable research levels completed" in t and "Unique technologies researched" in t)
        check("SPM label", "Science per minute (SPM): pack use" in t and "It is not research progress" in t, "")
        flow = re.search(r'<h2 id="packs-flow">.*?</p>', page, re.S).group(0)
        ft = text(flow)
        check("flow rows", "Red 400 360 40 90.0%" in ft and "Space 100 30 70 30.0%" in ft, ft[:400])
        check("flow source", "score log (scores.jsonl): produced and consumed, the player force's production statistics summed over every surface" in ft, ft)
        check("flow window", "Consumption is in every score row from game time 0h10m (shift 1); packs made before that row are left out of this table only." in ft, ft)
        check("flow falls", "Falls: Space made: fell 1 time by 30 in all (shift 2)." in ft, ft)
        reps = text(re.search(r'<h2 id="repeatable">.*?</p>', page, re.S).group(0))
        check("repeatable table", "Mining productivity levels 3 and up 3 Mining productivity 6 0h20m · shift 1" in reps
              and "Physical projectile damage levels 7 and up 2 Physical projectile damage 9 0h40m · shift 2" in reps, reps)
        check("repeatable source", "`infinite`, each infinite technology's levels done past its own first level" in reps, reps)
        check("jump links", '<a href="#packs-flow">Made and consumed</a><a href="#repeatable">Repeatable research</a>' in page)
        sp = (out / "runs" / "long" / "shift-2" / "index.html").read_text()
        st = text(sp)
        check("shift tiles", "3 unique technologies" not in st and "2 unique technologies +1" in st and "3 repeatable levels +2 in this shift" in st, re.findall(r"\d+ (?:unique technologies|repeatable levels)[^.]{0,30}", st))
        check("shift flow table", "Science packs made and consumed in this shift" in st and "Space 40 15 25 37.5%" in st
              and "Space made: fell by 30 in this shift" in st, st[st.find("made and consumed in this shift"):][:600])
        check("shift levels table", "Repeatable research levels completed in this shift" in st and "Mining productivity levels 3 and up 1" in st)
        check("SPM tile", "pack use: research units a minute, shift average" in st)
    print("test_runstats: ok (repeatable levels, made vs consumed per pack, falls, unique technologies, SPM label)")


if __name__ == "__main__":
    main()
