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
import json, os, re, subprocess, sys, tempfile
from pathlib import Path

SITE = Path(__file__).resolve().parent
sys.path.insert(0, str(SITE))
import longrun  # noqa: E402


def score(t, tick, done, science, rockets=0, platforms=(), planets=("nauvis",), space=None, at=None, used=None, iron=999):
    produced = {"automation-science-pack": science, "iron-plate": iron}
    if space is not None:
        produced["space-science-pack"] = space
    return json.dumps({"t": t, "world": "n", "score": {"tick": tick, "research_done": list(done), "rockets": rockets,
                       "produced": produced, "planets": list(planets), **({"consumed": used} if used else {}),
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
    # the labs' use (consumed): 400 red sets each 20 minutes; the agricultural count runs ahead (it spoils)
    use = lambda k: {"automation-science-pack": 300 + 400 * k, "agricultural-science-pack": 1000 * k}  # noqa: E731
    shift("s3", "s2", [score("2026-10-11T05:00:00", 3600 * 62, ["automation", "oil-processing"], 610, used=use(0), iron=1000),
                       score("2026-10-11T05:20:00", 3600 * 82, ["automation", "oil-processing"], 1010, space=100,
                             platforms=["Solstice"], at="nauvis", used=use(1)),
                       score("2026-10-11T05:40:00", 3600 * 102, ["automation", "oil-processing", "rocket-silo"], 1410,
                             space=40, rockets=1, platforms=["Solstice"], at="in transit", used=use(2)),
                       score("2026-10-11T06:00:00", 3600 * 122, ["automation", "oil-processing", "rocket-silo"], 1810,
                             rockets=2, platforms=["Solstice"], at="vulcanus", planets=("nauvis", "vulcanus"), space=60,
                             used=use(3), iron=1600)],
          caster="05:30:00 [Vale] (space_moment, or:x, 1s) Platform's named. Solstice.\n"
                 "05:31:00 [Rook] (camera, or:x, 1s) Nothing to see.\n")
    # the run's chronicle s3 left (tools/stream/chronicle_log.py; viewers Alex and syndesis 22:24): an agent's entry,
    # one naming the owner (left out by keep), and the harness's record: a platform built and lost with where it flew,
    # what destroyed it and its cargo, a rocket
    rows = [{"type": "entry", "seq": 1, "tick": 3600 * 90, "game_time": "1h30m", "agent": "sonnet", "title": "The silo rises",
             "text": "We poured the silo's foundation under a red sky.", "planet": "nauvis",
             "refs": [{"id": 1, "kind": "research", "tick": 3600 * 88, "line": "research finished: rocket-silo"}]},
            {"type": "entry", "seq": 2, "tick": 3600 * 91, "agent": "opus", "text": "nick said hi", "planet": "nauvis"},
            {"type": "event", "id": 2, "kind": "platform_created", "tick": 3600 * 95, "platform": "Comet", "at": "nauvis", "by": "luna"},
            {"type": "event", "id": 3, "kind": "rocket", "tick": 3600 * 101, "surface": "nauvis", "to": "platform Comet", "cargo": "empty"},
            {"type": "event", "id": 4, "kind": "platform_lost", "tick": 3600 * 110, "platform": "Comet",
             "where": "flying nauvis->vulcanus 40%", "by": "medium-metallic-asteroid",
             "hit_by": [{"name": "medium-metallic-asteroid", "count": 40}], "cargo": [{"name": "iron-plate", "count": 450}],
             "cargo_items": 450, "cargo_kinds": 1},
            {"type": "event", "id": 5, "kind": "research", "tick": 3600 * 88, "name": "rocket-silo"}]
    (root / "s3" / "chronicle.jsonl").write_text("".join(json.dumps(r) + "\n" for r in rows))
    shift("old", None, [score("2026-10-09T01:00:00", 100, [], 0)])  # an unrelated run: not in the chain
    (root / "s1-retry").mkdir()
    (root / "s1-retry" / "resumed-from").write_text("s1\n")  # a shorter branch: the longest chain wins


def platform_table_details():
    """The long-run page's platform table gives a lost platform's details when the chronicle has them."""
    sys.path.insert(0, str(SITE))
    import build
    rows = [{"name": "Comet", "built": "2026-10-11T05:00:00", "built_tick": 3600 * 95, "built_shift": 2, "places": ["nauvis"],
             "lost": "2026-10-11T05:30:00", "lost_tick": 3600 * 110, "lost_shift": 2, "at": None}]
    html = build.platforms_table(rows, {"Comet": "Platform Comet lost flying nauvis->vulcanus 40%, destroyed by x; cargo lost: 450 iron plate"})
    assert "Platform Comet lost flying nauvis-&gt;vulcanus 40%, destroyed by x; cargo lost: 450 iron plate" in html, html
    assert "the cargo lost as the harness read them" in html and 'href="/chronicle/"' in html, html
    assert "450 iron plate" not in build.platforms_table(rows), "no details without the chronicle"


def main():
    platform_table_details()
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
        # SPM: research units a minute from the labs' use; a log without it has none; packs made a minute apart
        assert s1["spm"] is None and s1["made_per_min"] == 10.0, s1
        assert s1["research_new"] == 1 and s1["moments"] == ["researched oil processing"], s1
        assert s3["research_new"] == 1 and s3["rockets_new"] == 2 and s3["made_per_min"] == 22.0, s3  # (1200 red + 120 space: 100, a fall to 40 as 0, 20) / 60
        assert s3["spm"] == 20.0, s3  # 1200 red sets in 60 min; agricultural's 50 a minute left out
        assert s3["output_per_min"] == {"plates": 10.0, "circuits": 0.0}, s3  # 600 iron plates in 60 min
        assert lr["spm"] == [(82.0, 20.0), (102.0, 20.0), (122.0, 20.0)], lr["spm"]  # s3's 20-minute windows only
        assert [v for _, v in lr["spm_packs"]["agricultural-science-pack"]] == [50.0, 50.0, 50.0], lr["spm_packs"]
        assert min(v for _, v in lr["made_spm"]) >= 0 and all(v >= 0 for pts in lr["spm_packs"].values() for _, v in pts)
        assert lr["made"] == {"automation-science-pack": 1810, "space-science-pack": 120}, lr["made"]
        assert s3["moments"] == ["researched the rocket silo", "first rocket launched", "platform Solstice built",
                                 "reached Vulcanus", "Platform's named. Solstice."], s3["moments"]
        plat = lr["platforms"]  # every platform row by row: where it stopped, still active (never gone from the list)
        assert [(p["name"], p["built_shift"], p["places"], p["lost"], p["at"]) for p in plat] == [
            ("Solstice", 2, ["nauvis", "vulcanus"], None, "vulcanus")], plat
        assert s3["platforms_built"] == ["Solstice"] and s3["platforms_lost"] == []
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
        home = (out / "index.html").read_text()  # the run so far, which live.js moves under the heading between shifts
        assert 'id="run-summary"' in home and "Latest milestones" in home and 'href="/runs/long/shift-2/"' in home
        assert "placeSummary" in (out / "static" / "live.js").read_text()
        assert 'href="/runs/long/"' in (out / "runs" / "index.html").read_text()
        assert len(page) < 80000, len(page)
        assert "Shift videos" not in page and "youtube" not in (out / "runs" / "long" / "shift-1" / "index.html").read_text()
        sp = (out / "runs" / "long" / "shift-1" / "index.html").read_text()  # every shift has a page, video or not
        assert "fan_1" in sp and "two turrets going up now" in sp and "owner line" not in sp and "nick" not in sp.lower().replace("nickwinter.net", "")
        assert 'href="/runs/long/shift-2/"' in sp and "Milestones" in sp
        assert "First rocket launched" in page and "Records" in page and 'class="mark"' in page
        assert "1 built" in page and "0 lost · 1 active (Solstice)" in page and "Space platforms" in page
        assert [(t["label"], t["tick"]) for t in s3["techs"]] == [("Rocket silo", 3600 * 102)], s3["techs"]
        assert "Technologies researched (1)" in (out / "runs" / "long" / "shift-2" / "index.html").read_text()
        # key times (game time, hours on stream, Pacific), the kind filter, the live banner (hidden until site.js)
        assert 'id="key-times"' in page and "First rocket" in page and "1h42m" in page, "first rocket at game 102 min"
        assert 'class="kind-filter"' in page and 'data-kind="space"' in page and '<tr data-kind="research">' in page
        assert 'class="live-banner"' in page and " hidden>" in page.split('class="live-banner"')[1][:200]
        assert '">on now</span>' not in page  # no "on now" chip from the build: a built page goes stale
        sp2 = (out / "runs" / "long" / "shift-2" / "index.html").read_text()
        assert 'content="Shift 2: Oct 11, 05:00 to 06:00 Pacific · +1 technologies · +2 rockets' in sp2
        # the Chronicle (viewers Alex and syndesis): shift 2's entry with its title, where and what it is filed beside; the
        # harness's record beside it (Comet built, a rocket, Comet lost with where, what destroyed it and its cargo); the
        # owner's line and research left out; linked from the nav and the shift page; on the timeline with details
        ch = (out / "chronicle" / "index.html").read_text()
        assert "<h1>Chronicle</h1>" in ch and 'id="shift-2"' in ch and 'id="shift-1"' not in ch, ch[:500]
        assert "The silo rises" in ch and "We poured the silo&#x27;s foundation under a red sky." in ch and "Beside: research finished: rocket-silo" in ch, ch
        assert "nick said hi" not in ch and "Platform Comet built at Nauvis by luna" in ch and "Rocket launched from Nauvis to platform Comet" in ch, ch
        assert ("Platform Comet lost flying nauvis-&gt;vulcanus 40%, destroyed by medium metallic asteroid; hit most by medium metallic "
                "asteroid; cargo lost: 450 iron plate") in ch, ch
        assert ch.index("The silo rises") < ch.index("Platform Comet built") < ch.index("Platform Comet lost"), "game-time order"
        assert "The agents' entries (1)" in ch and "The harness's record (3)" in ch, ch
        assert 'href="/chronicle/"' in page  # the long run's platform table links it (the nav does outside the archive)
        sp2c = (out / "runs" / "long" / "shift-2" / "index.html").read_text()
        assert 'href="/chronicle/#shift-2"' in sp2c and 'href="/chronicle/#shift-' not in sp, "only a shift with a chronicle links it"
        tl = (out / "timeline" / "index.html").read_text()
        assert "Platform Comet built at Nauvis by luna" in tl and "Platform Comet lost flying nauvis-&gt;vulcanus 40%" in tl, tl
        assert "Platform Solstice built" in tl, "a platform the chronicle does not cover: from the score rows"
        # a line that ends at 0 (space science on shift 1's page: none made yet) has no end label
        assert not re.search(r'class="dlabel"[^>]*>[^<]*<tspan class="dval">0</tspan>', page + sp)
        # a shift's own link-preview card: og_card.py --shifts writes its HTML (no browser here); the build uses a
        # rendered card only when its key matches the shift's facts
        og = Path(d) / "og"
        env = dict(os.environ, POG_OG_SHIFTS=str(og), POG_SITE_CONTENT=str(Path(d) / "site.json"))
        subprocess.run([sys.executable, str(SITE / "og_card.py"), "--shifts", "--runs-dir", str(root), "--html-only"],
                       check=True, capture_output=True, env=env)
        card = (og / "shift-2.html").read_text()
        assert "Shift 2" in card and "+2" in card and "First rocket launched" in card and "Oct 11, 05:00 to 06:00" in card
        import build as site_build
        (og / "shift-2.png").write_bytes(b"\x89PNG fake")
        (og / "shift-2.key").write_text(site_build.shift_card_key(site_build.shift_card_facts(s3, lr)) + "\n")
        (og / "shift-1.png").write_bytes(b"\x89PNG old")
        (og / "shift-1.key").write_text("stale\n")  # drawn for other numbers: not used
        subprocess.run([sys.executable, str(SITE / "build.py"), "--out", str(out), "--runs-dir", str(root),
                        "--content", str(Path(d) / "site.json")], check=True, capture_output=True, env=env)
        sp2 = (out / "runs" / "long" / "shift-2" / "index.html").read_text()
        assert "/static/og/shift-2.png?v=" in sp2 and (out / "static" / "og" / "shift-2.png").exists()
        assert "/static/og.png?v=" in (out / "runs" / "long" / "shift-1" / "index.html").read_text()
        assert not (out / "static" / "og" / "shift-1.png").exists()
        # a shift with a YouTube video: its row links its page, the run page embeds it, the page has the chapters
        videos = Path(d) / "videos.json"
        videos.write_text(json.dumps({
            "s3": {"id": "AbC_12-xyz9", "shift": 2, "title": "Factorio AI Party · Shift 2: The first 2 rockets",
                   "description": "Shift 2 of the Factorio AI Party.\n\nWhat happened\n• 2 rockets launched\n\n"
                                  "Chapters\n0:00 Start\n1:00:05 First rocket launched",
                   "chapters": [{"at": 0, "time": "0:00", "title": "Start"},
                                {"at": 3605, "time": "1:00:05", "title": "First rocket launched"}],
                   "playlist": "PLx", "timeline": [["2026-10-11T04:58:00-07:00", "2026-10-11T05:30:00-07:00"],
                                                    ["2026-10-11T05:35:00-07:00", "2026-10-11T06:01:00-07:00"]]},
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
        # milestones link their moment in the video: the first rocket's row (05:40) is 32 min of the first recording
        # plus 5 min into the second, less 2 minutes (score-log times run up to 2 minutes late)
        assert "watch?v=AbC_12-xyz9&amp;t=2100s" in sp and "watch?v=AbC_12-xyz9&amp;t=2100s" in page
    print("long run: ok (chain, failed start, per-shift numbers, no start.log text, links, check.py, shift videos)")


if __name__ == "__main__":
    main()
