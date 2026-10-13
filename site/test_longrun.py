#!/usr/bin/env python3
"""The long run page from a made-up runs folder: python3 site/test_longrun.py

- the chain follows resumed-from (the longest one; a failed start in the middle is listed, unnumbered);
- per shift: game time, research (+new), science per minute, rockets, platforms, deaths and loss alerts the director
  cut to (a loss alert repeated is counted per alert, not per building), milestone moments;
- science packs made from each counter's rises (a falling counter never gives a negative rate);
- firsts in order (packs, technologies, rockets, platform departures and arrivals, planets, the first death, the
  first viewer line); the viewer Q&A (a resend once, the agents' answers that name the viewer, the hosts' answers,
  the owner's lines left out); every shift has its own page;
- start.log gives only times: its account and quota lines never reach the page;
- with the archive on, build.py --runs-dir writes /runs/long/ and links it from the homepage and the Runs list; check.py passes.
"""
import json, os, subprocess, sys, tempfile
from pathlib import Path

SITE = Path(__file__).resolve().parent
sys.path.insert(0, str(SITE))
import longrun  # noqa: E402


def score(t, tick, done, science, rockets=0, platforms=(), planets=("nauvis",), space=None, at=None):
    produced = {"automation-science-pack": science, "iron-plate": 999}
    if space is not None:
        produced["space-science-pack"] = space
    return json.dumps({"t": t, "world": "n", "score": {"tick": tick, "research_done": list(done), "rockets": rockets,
                       "produced": produced, "planets": list(planets),
                       "platforms": [{"name": p, "hub": True, **({"at": at} if at else {})} for p in platforms]}})


def make(root):
    def shift(name, frm, lines, service="", caster="", start="12:00:00 quota claude_account_b (opus) Weekly: 4% used\n",
              chat=()):
        d = root / name
        d.mkdir()
        if frm:
            (d / "resumed-from").write_text(frm + "\n")
        (d / "scores.jsonl").write_text("\n".join(lines) + ("\n" if lines else ""))
        (d / "start.log").write_text(start)
        (d / "stream-service.log").write_text(service)
        (d / "caster.log").write_text(caster + "".join([
            "02:21:00 [Rook] (viewer_reply, or:x, 1s) fan_1 wants turrets. Sonnet is on it.\n"] if chat else []))
        (d / "chat.jsonl").write_text("".join(json.dumps(c) + "\n" for c in chat))
    shift("s1", None, [score("2026-10-11T02:00:00", 3600, ["automation"], 0),
                       score("2026-10-11T03:00:00", 3600 * 61, ["automation", "oil-processing"], 600)],
          chat=[{"seq": 1, "tick": 3600 * 20, "from": "viewer fan_1", "text": "@sonnet build turrets?", "viewer": True},
                {"seq": 2, "tick": 3600 * 20 + 60, "from": "viewer fan_1", "text": "@sonnet build turrets?", "viewer": True},
                {"seq": 3, "tick": 3600 * 21, "from": "sonnet", "text": "@fan_1 two turrets going up now"},
                {"seq": 4, "tick": 3600 * 22, "from": "viewer NickWinter", "text": "owner line"},
                {"seq": 5, "tick": 3600 * 23, "from": "viewer other", "text": "great stuff nick"},
                {"seq": 6, "tick": 3600 * 24, "from": "opus", "text": "unrelated line"}],
          service="[director] 02:30:00 main:  zoom 1.1  <- attack: Sonnet died\n"
                  "[director] 02:31:00 main:  zoom 0.8  <- attack: 3 lost near (1, 2): 3 gun turret\n"
                  "[director] 02:33:00 main:  zoom 0.8  <- attack: 3 lost near (1, 2): 3 gun turret\n"
                  # since shift01: death: / loss:, one alert on its zoom line and its cut line
                  "[director] 02:40:58 cam2:  zoom 1.1  <- death: Opus died\n"
                  "[director] 02:41:00 ON AIR cam2: @attack  <- death: Opus died\n"
                  "[director] 02:44:59 cam2:  zoom 0.99  <- loss: 9 lost near (5, 6): 9 pipe (by small biters)\n"
                  "[director] 02:45:01 ON AIR cam2: @attack  <- loss: 9 lost near (5, 6): 9 pipe (by small biters)\n")
    shift("s2", "s1", [], start="18:40:48 quota codex_account_b (astra) Weekly\n18:43:16 bot opus kept\n")
    # s3: a platform leaves Nauvis and reaches Vulcanus; its space science counter falls (the platform's counts went
    # with a lost one): never a negative rate
    shift("s3", "s2", [score("2026-10-11T05:00:00", 3600 * 62, ["automation", "oil-processing"], 610),
                       score("2026-10-11T05:20:00", 3600 * 82, ["automation", "oil-processing"], 1010, space=100,
                             platforms=["Solstice"], at="nauvis"),
                       score("2026-10-11T05:40:00", 3600 * 102, ["automation", "oil-processing", "rocket-silo"], 1410,
                             space=40, rockets=1, platforms=["Solstice"], at="in transit"),
                       score("2026-10-11T06:00:00", 3600 * 122, ["automation", "oil-processing", "rocket-silo"], 1810,
                             rockets=2, platforms=["Solstice"], at="vulcanus", planets=("nauvis", "vulcanus"), space=60)],
          caster="05:30:00 [Vale] (space_moment, or:x, 1s) Platform's named. Solstice.\n"
                 "05:31:00 [Rook] (camera, or:x, 1s) Nothing to see.\n")
    shift("old", None, [score("2026-10-09T01:00:00", 100, [], 0)])  # an unrelated run: not in the chain
    (root / "s1-retry").mkdir()
    (root / "s1-retry" / "resumed-from").write_text("s1\n")  # a shorter branch: the longest chain wins


def main():
    with tempfile.TemporaryDirectory() as d:
        root = Path(d) / "runs"
        root.mkdir()
        make(root)
        lr = longrun.load(root, agents=["sonnet", "opus"], keep=lambda t: "nick" not in t.lower())
        ids = [s["id"] for s in lr["shifts"]]
        assert ids == ["s1", "s2", "s3"], ids
        s1, s2, s3 = lr["shifts"]
        assert (s1["n"], s2["n"], s3["n"]) == (1, None, 2) and s2.get("empty") and s2["resumed_as"] == "s3"
        assert (s1["deaths"], s1["losses"]) == (2, 3), s1  # three loss alerts, not fifteen buildings or four lines
        assert s1["spm"] == 10.0 and s1["research_new"] == 1 and s1["moments"] == ["researched oil processing"], s1
        assert s3["research_new"] == 1 and s3["rockets_new"] == 2 and s3["spm"] == 22.0, s3  # (1200 red + 120 space: 100, a fall to 40 as 0, 20) / 60
        assert min(v for _, v in lr["spm"]) >= 0 and all(v >= 0 for pts in lr["spm_packs"].values() for _, v in pts)
        assert lr["made"] == {"automation-science-pack": 1810, "space-science-pack": 120}, lr["made"]
        assert s3["moments"] == ["researched the rocket silo", "first rocket launched", "platform Solstice built",
                                 "reached Vulcanus", "Platform's named. Solstice."], s3["moments"]
        firsts = {f["key"]: f for f in lr["firsts"]}
        assert firsts["rockets:1"]["tick"] == 3600 * 102 and firsts["rockets:1"]["shift"] == 2, firsts["rockets:1"]
        assert firsts["depart:nauvis"]["label"] == "First platform departure from Nauvis (Solstice)"
        assert firsts["arrive:vulcanus"]["tick"] == firsts["planet:vulcanus"]["tick"] == 3600 * 122
        assert firsts["pack:space-science-pack"]["tick"] == 3600 * 82 and firsts["tech:rocket-silo"]["shift"] == 2
        assert firsts["death"]["label"] == "First agent death (Sonnet)" and firsts["death"]["t"] == "2026-10-11T02:30:00"
        assert [f["tick"] for f in lr["firsts"]] == sorted(f["tick"] for f in lr["firsts"])
        qa = s1["qa"]  # the viewer once (the resend dropped), the agent's answer naming them, the host's answer
        assert [(q["kind"], q["who"]) for q in qa] == [("viewer", "fan_1"), ("agent", "sonnet"), ("host", "Rook")], qa
        assert s1["viewer_lines"] == 1 and firsts["viewer"]["tick"] == 3600 * 20  # owner lines left out
        assert lr["research"][0] == (1.0, 1) and lr["research"][-1] == (122.0, 3), lr["research"]
        out = Path(d) / "dist"
        # with the archive (run ids shown, the Runs list) and no run_start: the longest chain
        content = json.loads((SITE / "content" / "site.json").read_text())
        content.update(archive=True)
        content.pop("run_start", None)
        (Path(d) / "site.json").write_text(json.dumps(content))
        subprocess.run([sys.executable, str(SITE / "build.py"), "--out", str(out), "--runs-dir", str(root),
                        "--content", str(Path(d) / "site.json")], check=True, capture_output=True)
        r = subprocess.run([sys.executable, str(SITE / "check.py"), str(out)], capture_output=True, text=True)
        assert r.returncode == 0, r.stdout
        page = (out / "runs" / "long" / "index.html").read_text()
        assert "The long run" in page and "did not start" in page and "resumed as s3" in page and "Solstice" in page
        assert "quota" not in page and "Weekly" not in page and "codex" not in page  # start.log's text never shows
        assert 'href="/runs/long/"' in (out / "index.html").read_text()
        assert 'href="/runs/long/"' in (out / "runs" / "index.html").read_text()
        assert len(page) < 80000, len(page)
        assert "Shift videos" not in page and "youtube" not in (out / "runs" / "long" / "shift-1" / "index.html").read_text()
        sp = (out / "runs" / "long" / "shift-1" / "index.html").read_text()  # every shift has a page, video or not
        assert "fan_1" in sp and "two turrets going up now" in sp and "owner line" not in sp and "nick" not in sp.lower().replace("nickwinter.net", "")
        assert 'href="/runs/long/shift-2/"' in sp and "Milestones" in sp
        assert "First rocket launched" in page and "Records" in page and 'class="mark"' in page
        # a shift with a YouTube video: its row links its page, the run page embeds it, the page has the chapters
        videos = Path(d) / "videos.json"
        videos.write_text(json.dumps({
            "s3": {"id": "AbC_12-xyz9", "shift": 2, "title": "Factorio AI Party · Shift 2: The first 2 rockets",
                   "description": "Shift 2 of the Factorio AI Party.\n\nWhat happened\n• 2 rockets launched\n\n"
                                  "Chapters\n0:00 Start\n1:00:05 First rocket launched",
                   "chapters": [{"at": 0, "time": "0:00", "title": "Start"},
                                {"at": 3605, "time": "1:00:05", "title": "First rocket launched"}],
                   "playlist": "PLx"},
            "s1": {"id": "bad id <script>"}}))  # not a video id: ignored
        subprocess.run([sys.executable, str(SITE / "build.py"), "--out", str(out), "--runs-dir", str(root),
                        "--content", str(Path(d) / "site.json"), "--videos", str(videos)], check=True, capture_output=True)
        r = subprocess.run([sys.executable, str(SITE / "check.py"), str(out)], capture_output=True, text=True)
        assert r.returncode == 0, r.stdout
        page = (out / "runs" / "long" / "index.html").read_text()
        assert "Shift videos" in page and "youtube-nocookie.com/embed/AbC_12-xyz9" in page and 'href="/runs/long/shift-2/"' in page
        assert "bad id" not in page and "youtube" not in (out / "runs" / "long" / "shift-1" / "index.html").read_text()
        sp = (out / "runs" / "long" / "shift-2" / "index.html").read_text()
        assert "embed/AbC_12-xyz9" in sp and "watch?v=AbC_12-xyz9&amp;t=3605s" in sp and "First rocket launched" in sp
        assert "<li>2 rockets launched</li>" in sp and "list=PLx" in sp and sp.count("1:00:05") == 1  # chapters once
    print("long run: ok (chain, failed start, per-shift numbers, no start.log text, links, check.py, shift videos)")


if __name__ == "__main__":
    main()
