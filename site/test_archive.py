#!/usr/bin/env python3
"""The site starts from the run at run_start when the archive switch is off: python3 site/test_archive.py

With site.json "archive": false and "run_start" set (here on a made-up runs folder: shake3 -> shake4 -> pub1 -> pub2,
run_start pub1):
- no /experiments/, /studies/, /agents/ or /runs/<id>/ pages, and no links to them; the nav is Live, The run, About;
- no run or study id from before run_start anywhere in the output (site.json's runs and studies, shakeN, smoke-...,
  the chain's earlier shifts), and no agent of the earlier runs (Fable);
- the run page counts from run_start: shift 1 is pub1, game time and technologies start from the save it resumed;
- status.json's last run survives only when it is a shift of the run, without its id;
- check.py passes. With the switch back on, the experiments, studies, run and agent pages return.
"""
import json, re, subprocess, sys, tempfile
from pathlib import Path

SITE = Path(__file__).resolve().parent
sys.path.insert(0, str(SITE))
import longrun  # noqa: E402
from test_longrun import score  # noqa: E402


def make(root):
    def shift(name, frm, lines):
        d = root / name
        d.mkdir()
        if frm:
            (d / "resumed-from").write_text(frm + "\n")
        (d / "scores.jsonl").write_text("\n".join(lines) + "\n")
    shift("shake3", None, [score("2026-10-11T01:00:00", 3600, ["automation"], 0)])
    shift("shake4", "shake3", [score("2026-10-11T02:00:00", 3600 * 2, ["automation"], 10),
                               score("2026-10-11T03:00:00", 3600 * 62, ["automation", "oil-processing"], 610,
                                     rockets=1, platforms=["Oldship"])])
    shift("pub1", "shake4", [score("2026-10-12T10:00:00", 3600 * 63, ["automation", "oil-processing"], 620,
                                   rockets=1, platforms=["Oldship"]),
                             score("2026-10-12T11:00:00", 3600 * 123, ["automation", "oil-processing", "steel-processing"],
                                   1220, rockets=2, platforms=["Oldship"])])
    shift("pub2", "pub1", [score("2026-10-12T14:00:00", 3600 * 124, ["automation", "oil-processing", "steel-processing"], 1230,
                                 rockets=2, platforms=["Oldship"]),
                           score("2026-10-12T15:00:00", 3600 * 184, ["automation", "oil-processing", "steel-processing",
                                                                     "rocket-silo"], 2430, rockets=3,
                                 platforms=["Oldship", "Dawn"])])
    (root / "smoke-x1").mkdir()


def build(d, content, runs):
    path = Path(d) / f"site-{content['archive']}.json"
    path.write_text(json.dumps(content))
    out = Path(d) / f"dist-{content['archive']}"
    r = subprocess.run([sys.executable, str(SITE / "build.py"), "--out", str(out), "--runs-dir", str(runs),
                        "--content", str(path)], capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    r = subprocess.run([sys.executable, str(SITE / "check.py"), str(out)], capture_output=True, text=True)
    assert r.returncode == 0, r.stdout
    return out


def text_files(out):
    for p in out.rglob("*"):
        if p.is_file() and p.suffix in (".html", ".json", ".js", ".css", ".txt", ".svg", ""):
            yield p, p.read_text()


def main():
    content = json.loads((SITE / "content" / "site.json").read_text())
    with tempfile.TemporaryDirectory() as d:
        runs = Path(d) / "runs"
        runs.mkdir()
        make(runs)

        lr = longrun.load(runs, start="pub1")
        assert [s["id"] for s in lr["shifts"]] == ["pub1", "pub2"], lr["shifts"]
        p1, p2 = lr["shifts"]
        assert (p1["n"], p1["game0"], p1["game1"], p1["research"], p1["research_new"]) == (1, "0h01m", "1h01m", 1, 1), p1
        assert (p1["rockets"], p1["platforms"]) == (1, []), p1  # the save's rocket and platform are not counted
        assert (p2["n"], p2["game1"], p2["research"], p2["rockets"], p2["platforms"]) == (2, "2h02m", 2, 2, ["Dawn"]), p2
        assert lr["research"][0] == (1.0, 0), lr["research"]
        assert longrun.load(runs, start="nope") is None

        out = build(d, dict(content, archive=False, run_start="pub1"), runs)
        pages = sorted(str(p.relative_to(out)) for p in out.rglob("*.html"))
        assert pages == ["404.html", "about/index.html", "agents/index.html", "chat/index.html", "chronicle/index.html",
                         "how/agents/index.html", "how/compare/index.html", "how/harness/index.html", "how/index.html",
                         "how/lessons/index.html", "how/operations/index.html", "how/setup/index.html",
                         "index.html", "live/index.html", "polls/index.html", "privacy/index.html",
                         "runs/long/index.html", "runs/long/shift-1/index.html", "runs/long/shift-2/index.html",
                         "search/index.html", "terms/index.html", "timeline/index.html", "updates/index.html"], pages
        before = set(content["runs"]) | set(content["studies"]) | {"shake3", "shake4", "smoke-x1"}
        ids = re.compile(r"(?<![\w-])(?:" + "|".join(map(re.escape, sorted(before))) + r"|shake\d+|smoke-[\w-]+|Fable)(?![\w-])")
        for p, t in text_files(out):
            m = ids.search(t)
            assert not m, f"{p.relative_to(out)}: {t[max(0, m.start() - 60):m.end() + 20]!r}"
            for href in re.findall(r'(?:href|src)="(/[^"]*)"', t):
                assert not href.startswith(("/experiments/", "/studies/")), (p, href)
                # the long run's /agents/ (and its #cards); the test runs' agent pages /agents/KEY/ are archive only
                assert not href.startswith("/agents/") or href.split("#")[0] == "/agents/", (p, href)
                assert not href.startswith("/runs/") or href.startswith("/runs/long/"), (p, href)
        home = (out / "index.html").read_text()
        nav = re.search(r'<nav class="site-nav".*?</nav>', home, re.S).group(0)
        assert re.findall(r">([^<]+)</a>", nav) == ["Live", "Polls", "The run", "Agents", "Timeline", "Chronicle", "Chat", "Search", "Updates", "How it was made", "About", "GitHub"], nav
        page = (out / "runs" / "long" / "index.html").read_text()
        assert "0h01m to 1h01m" in page and "Rocket silo" in page and "Dawn" in page and "Oldship" not in page
        about = (out / "about" / "index.html").read_text()
        assert "Shattered Planet" in about and 'id="talk"' in about and "Results so far" not in about

        import build as site_build  # status.json: the last run only when it is a shift of the run, without its id
        site_build.CONTENT = dict(content, archive=False)
        site_build.LONG = lr
        st = {"schema": 1, "live": False, "last_run": {"id": "shake4", "title": "Shift 9 of the long run", "url": "/runs/long/"}}
        assert json.loads(site_build.public_status(st))["last_run"] is None
        st["last_run"]["id"] = "pub2"
        assert json.loads(site_build.public_status(st))["last_run"] == {"title": "Shift 9 of the long run", "url": "/runs/long/"}

        out = build(d, dict(content, archive=True, run_start="pub1"), runs)
        for rel in ["experiments/index.html", "runs/index.html", "runs/shake1/index.html", "studies/index.html",
                    "studies/shake1/index.html", "agents/fable/index.html"]:
            assert (out / rel).exists(), rel
        assert 'href="/experiments/"' in (out / "index.html").read_text()
        assert "pub1" in (out / "runs" / "long" / "index.html").read_text()  # run ids are shown with the archive
    print("archive switch: ok (off: no experiments, studies, agent or earlier run pages, links or ids; the run counts "
          "from run_start; on: all back)")


if __name__ == "__main__":
    main()
