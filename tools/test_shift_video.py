#!/usr/bin/env python3
"""tools/shift_video.py and tools/yt_upload.py --dry-run on a made-up pair of shifts: python3 tools/test_shift_video.py

- the box's file names are PST (UTC-8): a recording named 21-00-05 starts 22:00:05 PDT; Replay_ clips are left out;
  the other shift's recording at either edge is left out; a shift split over two files is one video, its times added up;
- a log over midnight dates its lines on the next day;
- chapters: the first at 0:00, at least three, at least 10 s apart, at most 24; rockets, a platform, research
  milestones, a death, a big fight (from where it got big), a host segment, a viewer's question an agent answered;
- the description: under 5,000 bytes, no angle brackets, no operator lines, no chat from the shift before;
- the box plan: concat list in order, Quick Sync HEVC at about 1 GB an hour, low priority;
- yt_upload --dry-run: every request printed, no sign-in, nothing written; a real run refuses a shift still on;
- (d24 batch156 PZ1) from the chronicle, weighed against the earlier shifts': the first arrival at the solar system
  edge (the Space Age victory) leads the title, the chapters and what happened; routine trips are no chapter and are
  summed by route; a far trip set out for before has no "first time"; a platform built at a place does not reach it
  "for the first time"; chapters spread to the recording's end.
- (d29 batch338 VT, Nick: shifts 91-94 all "Resolute leaves the solar system edge for the Shattered Planet") a platform
  that sets out for a far place it set out for in an earlier shift, and arrives where it arrived before, makes routine
  trips: the shift's farthest toward it (the score log's km) leads when it beats the run's record ("Resolute reaches
  38,000 km toward the Shattered Planet, its farthest yet"), and the description says the tries and the farthest; short
  of the record, the next-heaviest leads; a lead whose words (numbers aside) are the shift before's does not lead
  (research level 9 after level 8: another technology); a thousandth rocket leads only when nothing else is there.
"""
import datetime, json, os, subprocess, sys, tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import shift_video as sv  # noqa: E402

PDT = sv.PACIFIC


def score(t, tick, done, rockets=0, platforms=()):
    return json.dumps({"t": t, "world": "n", "score": {"tick": tick, "research_done": list(done), "rockets": rockets,
                       "produced": {"automation-science-pack": tick // 100}, "planets": ["nauvis"],
                       "platforms": [dict(p) for p in platforms]}})


def make(root):
    a = root / "sa"
    a.mkdir()
    (a / "stream.json").write_text(json.dumps({"shift": {"start": datetime.datetime(2026, 10, 12, 18, 0, tzinfo=PDT).timestamp()}}))
    (a / "start.log").write_text("17:58:00 quota x\n18:00:10 helper stream-service pid 1 up: x\n")
    (a / "scores.jsonl").write_text("\n".join([score("2026-10-12T18:01:00", 1000, ["automation"]),
                                               score("2026-10-12T21:55:00", 900000, ["automation", "oil-processing"])]) + "\n")
    (a / "caster.log").write_text("21:56:00 [Rook] (open, x, 1s) Bye.\n")
    (a / "chat.jsonl").write_text(json.dumps({"seq": 1, "tick": 899000, "from": "viewer Old", "viewer": True,
                                              "text": "is this the old shift?", "logged_at": "2026-10-12T21:50:00"}) + "\n"
                                  + json.dumps({"seq": 2, "tick": 899100, "from": "opus", "text": "@Old yes it is",
                                                "logged_at": "2026-10-12T21:50:30"}) + "\n")
    b = root / "sb"
    b.mkdir()
    (b / "resumed-from").write_text("sa\n")
    t0 = datetime.datetime(2026, 10, 12, 22, 0, tzinfo=PDT)
    (b / "stream.json").write_text(json.dumps({"shift": {"start": t0.timestamp(), "end": t0.timestamp() + 4 * 3600},
                                               "agents": {"opus": {"model": "Claude Opus 5.5", "harness": "Claude Code"},
                                                          "sol": {"model": "GPT-6.1 Sol", "harness": "Codex"}}}))
    (b / "start.log").write_text("21:58:30 world n: resuming\n22:00:05 helper stream-service pid 2 up: x\n")
    plat = {"name": "Starling", "at": "nauvis", "hub": True}
    rows = [("2026-10-12T22:01:00", 900500, ["automation", "oil-processing"], 0, ()),
            ("2026-10-12T22:30:00", 950000, ["automation", "oil-processing", "rocket-silo"], 0, ()),
            ("2026-10-12T23:40:00", 1100000, ["automation", "oil-processing", "rocket-silo"], 1, ()),
            ("2026-10-13T00:20:40", 1200000, ["automation", "oil-processing", "rocket-silo"], 2, (plat,)),
            ("2026-10-13T01:50:00", 1400000, ["automation", "oil-processing", "rocket-silo", "space-science-pack"], 2,
             (dict(plat, at="in transit"),))]
    (b / "scores.jsonl").write_text("\n".join(score(*r) for r in rows) + "\n")
    (b / "stream-service.log").write_text(
        "[director] 22:40:58 cam2:  zoom 1.1  <- death: Sol died\n"
        "[director] 22:41:00 ON AIR cam2: @attack  <- death: Sol died\n"
        "[director] 22:42:30 ON AIR cam2: @attack  <- loss: 1 lost near (5, 6): 1 character (by small worm turrets)\n"
        "[director] 23:10:00 ON AIR main: @attack  <- loss: 1 lost near (60, -110): 1 gun turret (by small biters)\n"
        "[director] 23:16:00 ON AIR main: @attack  <- loss: 30 lost near (40, -150): 20 stone wall, 10 gun turret (by small biters)\n"
        "[director] 23:19:00 ON AIR main: @attack  <- loss: 64 lost near (35, -160): 40 stone wall, 24 transport belt (by small biters)\n"
        "[director] 01:58:00 main: haiku zoom 0.5  <- zoom 0.5 (move_to)\n")
    (b / "caster.log").write_text(
        '23:50:00 [segment] asked for spotlight (lull): {"id": "seg-1", "title": "Spotlight: Opus", "facts": {}}\n'
        '23:55:00 [segment] asked for research (research): {"id": "seg-2", "title": "Research: Space science 3%"}\n'
        "01:59:00 [Vale] (plan, x, 1s) Last line.\n")
    chat = [{"tick": 899000, "from": "viewer Old", "viewer": True, "text": "is this the old shift?", "logged_at": "2026-10-12T22:00:05"},
            {"tick": 899100, "from": "opus", "text": "@Old yes it is", "logged_at": "2026-10-12T22:00:05"},
            {"tick": 960000, "from": "viewer Craig", "viewer": True, "text": "@opus when is the first rocket?",
             "logged_at": "2026-10-12T22:50:00"},
            {"tick": 960100, "from": "opus", "text": "@Craig soon: the silo is half built.", "logged_at": "2026-10-12T22:51:00"},
            {"tick": 960200, "from": "server", "text": "Operator here. A harness fix is live.", "logged_at": "2026-10-12T22:52:00"},
            {"tick": 960300, "from": "viewer NickWinter", "viewer": True, "text": "how is it going?", "logged_at": "2026-10-12T22:53:00"},
            {"tick": 960400, "from": "sol", "text": "@NickWinter fine", "logged_at": "2026-10-12T22:53:30"}]
    (b / "chat.jsonl").write_text("\n".join(json.dumps(c) for c in chat) + "\n")
    listing = root / "recordings.txt"
    listing.write_text("D:\\pog\\recordings\\2026-10-12 17-00-10.mkv,14100.0\n"   # shift sa: 18:00:10 to 21:55:10 PDT
                       "D:\\pog\\recordings\\Replay_2026-10-12_22-10-00.mkv,40.0\n"
                       "D:\\pog\\recordings\\2026-10-12 21-00-05.mkv,7200.0\n"    # sb: 22:00:05 to 00:00:05
                       "C:\\pog\\recordings\\2026-10-12 23-00-35.mkv,N/A\n")      # sb after the split: 00:00:35 on
    return listing


def chronicle_case(root):
    """(d24 batch155 PZ1: shift 63's video read "Kestrel IVb reaches Aquilo and Weaver leaves Nauvis", 24 chapters of
    routine arrivals in its first 47 minutes, and left out Asterion reaching the solar system edge 2h41m in.) A shift
    like it, after one whose chronicle already has Gleba, Aquilo and a departure for the edge."""
    ca, cb = root / "ca", root / "cb"
    ca.mkdir()
    cb.mkdir()
    t0 = datetime.datetime(2026, 10, 23, 8, 0, tzinfo=PDT).timestamp()

    def row(sec, kind, **k):
        return json.dumps(dict(k, kind=kind, type="event", t=t0 + sec, tick=1000 + sec * 60))
    (ca / "chronicle.jsonl").write_text("\n".join([
        row(-90000, "platform_arrived", platform="Petrel", at="gleba"),
        row(-80000, "platform_arrived", platform="Kestrel", at="aquilo"),
        row(-70000, "platform_left", platform="Kestrel", at="aquilo", to="solar-system-edge")]) + "\n")
    (cb / "resumed-from").write_text("ca\n")
    (cb / "stream.json").write_text(json.dumps({"shift": {"start": t0, "end": t0 + 4 * 3600}}))
    (cb / "start.log").write_text("07:59:00 world n: resuming\n08:00:05 helper stream-service pid 2 up: x\n")
    (cb / "scores.jsonl").write_text("\n".join([score("2026-10-23T08:01:00", 1000, ["automation"], rockets=1000),
                                                score("2026-10-23T11:59:00", 900000, ["automation"], rockets=1600)]) + "\n")
    rows = []
    for i in range(12):  # routine: Petrel between Nauvis and Gleba every 2 minutes, all in the first 47 minutes
        rows.append(row(120 + i * 240, "platform_left", platform="Petrel", at="nauvis", to="gleba"))
        rows.append(row(180 + i * 240, "platform_arrived", platform="Petrel", at="gleba"))
        rows.append(row(240 + i * 240, "platform_left", platform="Petrel", at="gleba", to="nauvis"))
        rows.append(row(300 + i * 240, "platform_arrived", platform="Petrel", at="nauvis"))
    rows += [row(1200, "platform_created", platform="Weaver", at="nauvis"),
             row(1800, "platform_left", platform="Asterion", at="aquilo", to="solar-system-edge"),
             row(2400, "platform_arrived", platform="Weaver", at="nauvis"),
             row(3600 + 1200, "platform_arrived", platform="Weaver", at="gleba"),
             row(2 * 3600 + 41 * 60, "platform_arrived", platform="Asterion", at="solar-system-edge"),
             row(3 * 3600 + 600, "research", name="mining-productivity-3"),
             row(3 * 3600 + 1800, "research", name="toolbelt-equipment")]
    rows.append(json.dumps({"type": "entry", "agent": "astra", "title": "Asterion's long watch", "t": t0 + 3 * 3600 + 3000,
                            "tick": 99}))
    (cb / "chronicle.jsonl").write_text("\n".join(rows) + "\n")


def resolute_case(root):
    """Four shifts of Resolute's trials: ra sets out once and gets 30,000 km; rb, rc and rd set out 5 times each and get
    38,200 km (a record), 37,000 and 36,000 km."""
    def score_at(t, tick, km=None, rockets=1000):
        plats = [{"name": "Resolute", "at": "in transit", "hub": True, "to": "shattered-planet",
                  "route": "solar-system-edge->shattered-planet", "km": km, "len": 4000000}] if km is not None else []
        return score(datetime.datetime.fromtimestamp(t, PDT).strftime("%Y-%m-%dT%H:%M:%S"), tick, ["automation"],
                     rockets=rockets, platforms=plats)

    def row(t, kind, **k):
        return json.dumps(dict(k, kind=kind, type="event", t=t, tick=int(t) % 10000000))
    t0 = datetime.datetime(2026, 10, 27, 8, 0, tzinfo=PDT).timestamp()
    ra = root / "ra"
    ra.mkdir()
    (ra / "stream.json").write_text(json.dumps({"shift": {"start": t0 - 4 * 3600, "end": t0}}))
    (ra / "start.log").write_text("03:59:00 world n: x\n04:00:05 helper stream-service pid 2 up: x\n")
    (ra / "chronicle.jsonl").write_text("\n".join([
        row(t0 - 6000, "platform_left", platform="Resolute", at="aquilo", to="solar-system-edge"),
        row(t0 - 3000, "platform_arrived", platform="Resolute", at="solar-system-edge"),
        row(t0 - 3000, "platform_left", platform="Resolute", at="solar-system-edge", to="shattered-planet"),
        row(t0 - 1000, "platform_arrived", platform="Resolute", at="aquilo")]) + "\n")
    (ra / "scores.jsonl").write_text("\n".join([score_at(t0 - 3 * 3600, 100), score_at(t0 - 2500, 200, km=30000),
                                                score_at(t0 - 60, 300)]) + "\n")
    prev = "ra"
    for k, (name, best, techs) in enumerate([("rb", 38200, ["toolbelt-equipment"]),
                                             ("rc", 37000, ["physical-projectile-damage-8"]),
                                             ("rd", 36000, ["physical-projectile-damage-9", "laser-weapons-damage-2"])]):
        s0 = t0 + k * 4 * 3600
        d = root / name
        d.mkdir()
        (d / "resumed-from").write_text(prev + "\n")
        prev = name
        (d / "stream.json").write_text(json.dumps({"shift": {"start": s0, "end": s0 + 4 * 3600}}))
        (d / "start.log").write_text("x world n: x\n")
        rows, scores = [], [score_at(s0 + 60, 1000 + k)]
        for i in range(5):  # out from the edge, turned back, home at Aquilo, back to the edge
            b = s0 + 600 + i * 2700
            rows += [row(b, "platform_arrived", platform="Resolute", at="solar-system-edge"),
                     row(b, "platform_left", platform="Resolute", at="solar-system-edge", to="shattered-planet"),
                     row(b + 1500, "platform_arrived", platform="Resolute", at="aquilo"),
                     row(b + 1800, "platform_left", platform="Resolute", at="aquilo", to="solar-system-edge")]
            scores.append(score_at(b + 600, 2000 + i, km=best if i == 1 else 20000 + 1000 * i))
        rows += [row(s0 + 3000 + 600 * j, "research", name=t) for j, t in enumerate(techs)]
        scores.append(score_at(s0 + 4 * 3600 - 60, 9000 + k, rockets=1600))
        (d / "chronicle.jsonl").write_text("\n".join(rows) + "\n")
        (d / "scores.jsonl").write_text("\n".join(scores) + "\n")


def main():
    with tempfile.TemporaryDirectory() as d:
        rroot = Path(d) / "res"
        rroot.mkdir()
        resolute_case(rroot)
        vb = sv.build("rb", rroot)
        assert vb["title"] == "Factorio AI Party · Shift 2: Resolute: 38,000 km toward the Shattered Planet, its farthest yet", vb["title"]
        chap = [c["title"] for c in vb["chapters"]]
        assert "Resolute: 38,000 km toward the Shattered Planet, its farthest yet" in chap, chap
        assert not any("leaves the solar system edge" in c or "reaches the solar system edge" in c for c in chap), chap
        happened = vb["description"].split("What happened\n", 1)[1].split("\n\n", 1)[0].splitlines()
        assert "• Resolute set out for the Shattered Planet again (5 times), 38,000 km at the farthest" in happened, happened
        assert "• Resolute set out for the solar system edge again (5 times)" in happened, happened
        sv.write(vb, rroot / "rb" / "video", thumb=False)
        vc = sv.build("rc", rroot)  # 37,000 km: no record, the research leads
        assert vc["title"] == "Factorio AI Party · Shift 3: Physical projectile damage 8 researched", vc["title"]
        assert any(h.endswith("37,000 km at the farthest") for h in vc["description"].splitlines()), vc["description"]
        sv.write(vc, rroot / "rc" / "video", thumb=False)
        vd = sv.build("rd", rroot)  # level 9 reads as rc's level 8: the other technology leads
        assert vd["title"] == "Factorio AI Party · Shift 4: Laser weapons damage 2 researched", vd["title"]
        assert sv.build("rd", rroot, previous="")["title"].endswith(": Physical projectile damage 9 researched")
        got = sv.retitle(2, 2, rroot)  # (no shiftN folders here: none)
        assert got == [], got
        # the rockets: a thousandth one leads only when nothing else does; a repeat leads when nothing else is left
        t = datetime.datetime(2026, 10, 27, 8, 0, tzinfo=PDT)
        rk = sv.ev(t, "rocket", "Rocket 64,000 launched", 50, first=False, count=918)
        steel = sv.ev(t, "research", "Steel axe researched", 36, tech="steel-axe", label="Steel axe")
        assert sv.highlight([rk, steel], {}, 0) == "Steel axe researched"
        assert sv.highlight([rk], {}, 0) == "918 more rockets"
        assert sv.highlight([rk], {}, 0, previous="1478 more rockets") == "918 more rockets"
        assert sv.highlight([rk, steel], {}, 0, previous="Steel axe researched") == "918 more rockets"

    with tempfile.TemporaryDirectory() as d:
        croot = Path(d) / "chron"
        croot.mkdir()
        chronicle_case(croot)
        vc = sv.build("cb", croot)
        # the title and the first line of what happened: the biggest moment, the Space Age victory
        assert vc["title"] == "Factorio AI Party · Shift 2: Asterion reaches the solar system edge: the Space Age victory", vc["title"]
        chap = {c["title"]: c["at"] for c in vc["chapters"]}
        assert abs(chap.get("Asterion reaches the solar system edge: the Space Age victory", 0) - (2 * 3600 + 41 * 60 - 5)) <= 1, vc["chapters"]
        assert not any("Petrel" in t for t in chap), vc["chapters"]  # routine trips are no chapter
        assert "Asterion leaves Aquilo for the solar system edge" in chap, vc["chapters"]  # set out for before: no "first time"
        assert "Space platform Weaver built" in chap and "Weaver reaches Gleba for the first time" in chap, vc["chapters"]
        assert not any(t.startswith("Weaver reaches Nauvis") for t in chap), vc["chapters"]  # built there
        assert max(chap.values()) > 3 * 3600 and "Toolbelt equipment researched" in chap, vc["chapters"]  # spread to the end
        assert all(b - a >= sv.MIN_GAP for a, b in zip(sorted(chap.values()), sorted(chap.values())[1:])), vc["chapters"]
        happened = vc["description"].split("What happened\n", 1)[1].split("\n\n", 1)[0].splitlines()
        assert happened[0] == "• Asterion reaches the solar system edge: the Space Age victory", happened
        assert "• 24 routine platform trips: 24 between Gleba and Nauvis (Petrel)" in happened, happened
        assert happened.index("• 24 routine platform trips: 24 between Gleba and Nauvis (Petrel)") > happened.index(
            "• Weaver reaches Gleba for the first time"), happened
        assert any("research finished: toolbelt equipment and mining productivity 3" in h for h in happened), happened
        assert "• 600 rockets launched" in happened, happened

    with tempfile.TemporaryDirectory() as d:
        root = Path(d) / "runs"
        root.mkdir()
        listing = make(root)

        # times over midnight
        lines = sv.stamped(root / "sb" / "caster.log", datetime.datetime(2026, 10, 12, 22, 0, tzinfo=PDT))
        assert lines[-1][0] == datetime.datetime(2026, 10, 13, 1, 59, tzinfo=PDT), lines[-1]

        files = sv.read_listing(listing, -8)
        assert [f[1].strftime("%H:%M:%S") for f in files] == ["18:00:10", "22:00:05", "00:00:35"], files  # no Replay_

        v = sv.build("sb", root, listing)
        assert [s["file"].split("\\")[-1] for s in v["segments"]] == ["2026-10-12 21-00-05.mkv", "2026-10-12 23-00-35.mkv"], v["segments"]
        assert v["shift"] == 2 and not v["estimated"]
        ch = v["chapters"]
        assert ch[0]["at"] == 0 and len(ch) >= 3 and len(ch) <= sv.MAX_CHAPTERS, ch
        assert all(b["at"] - a["at"] >= 10 for a, b in zip(ch, ch[1:])), ch
        titles = {c["title"]: c["at"] for c in ch}
        assert titles.get("First rocket launched") == (datetime.datetime(2026, 10, 12, 23, 5) - datetime.datetime(2026, 10, 12, 22, 0, 5)).seconds, ch
        # after the split: 7200 s of the first file, then from 00:00:35 (the platform: midway 23:40-00:20 is in the gap)
        assert titles.get("Space platform Starling built") == 7200, ch
        assert titles.get("Starling leaves Nauvis") == 7200 + (datetime.datetime(2026, 10, 13, 1, 5, 20) - datetime.datetime(2026, 10, 13, 0, 0, 35)).seconds, ch
        assert "Sol dies (small worm turrets)" in titles and "Spotlight: Opus" in titles, ch

        # two milestones a minute apart share a chapter; a lesser event that close is dropped
        t0 = datetime.datetime(2026, 10, 12, 22, 0, tzinfo=PDT)
        segs = [{"start": t0, "end": t0 + datetime.timedelta(hours=2)}]
        evs = [sv.ev(t0 + datetime.timedelta(seconds=s), k, title, w) for s, k, title, w in
               [(1000, "rocket", "First rocket launched", 92), (1050, "platform", "Space platform Starling built", 90),
                (1060, "research", "Steel researched", 40), (3000, "depart", "Starling leaves Nauvis", 88),
                (3040, "research", "Vulcanus discovered", 72)]]
        got = [c["title"] for c in sv.pick_chapters(evs, segs, "Start", 7200)]
        assert got == ["Start", "First rocket launched; space platform Starling built", "Starling leaves Nauvis", "Hour 2"], got  # 3000 s to the end: an hour mark
        fight = [t for t in titles if t.startswith("Biters break in: 64 lost")]
        assert fight and titles[fight[0]] == (datetime.datetime(2026, 10, 12, 23, 16) - datetime.datetime(2026, 10, 12, 22, 0, 5)).seconds, ch
        assert "Craig asks: when is the first rocket?" in titles, ch
        assert not any("Research:" in t for t in titles), ch  # research cards repeat the research chapters

        assert v["title"].startswith("Factorio AI Party · Shift 2: ") and len(v["title"]) <= 100, v["title"]
        # the heaviest two: the first rockets (92) and the platform built (90), ahead of its departure (88)
        assert v["title"].endswith(": The first 2 rockets and space platform Starling built"), v["title"]
        desc = v["description"]
        assert len(desc.encode()) < 5000 and "<" not in desc and ">" not in desc
        assert "Craig asked" in desc and "Opus answered" in desc and "the silo is half built" in desc
        assert "Operator" not in desc and "harness" not in desc and "old shift" not in desc and "NickWinter" not in desc
        assert "Streamed live Oct 12, 2026, 10:00 p.m. to" in desc, desc
        assert "\nChapters\n0:00 " in desc and all(f"{c['time']} {c['title']}" in desc for c in ch)
        assert "Deaths: 1;" in desc and "64 buildings" in desc, desc

        concat = v["box"]["concat"].splitlines()
        assert concat[1] == "file 'D:/pog/recordings/2026-10-12 21-00-05.mkv'" and concat[2].startswith("file 'C:/"), concat
        cmd = v["box"]["encode_cmd"]
        assert "hevc_qsv" in cmd and "-b:v 2000k" in cmd and 'start "" /low' in cmd and "\r\n" in cmd
        assert 0.9 < v["size_gb"] / (v["duration"] / 3600) < 1.0, v

        # the earlier shift: its own file only; without a list, an estimate from start.log
        va = sv.build("sa", root, listing)
        assert len(va["segments"]) == 1 and va["segments"][0]["file"].endswith("17-00-10.mkv"), va["segments"]
        assert va["title"].startswith("Factorio AI Party · Shift 1: ") and "Nine AIs" in va["chapters"][0]["title"]
        ve = sv.build("sb", root)
        assert ve["estimated"] and ve["segments"][0]["file"].endswith("2026-10-12 21-00-05.mkv"), ve["segments"]

        # files written, then the uploader's dry run reads them
        out = Path(d) / "video"
        v["_runs_dir"] = str(root)
        sv.write(v, out, thumb=False)
        assert json.loads((out / "video.json").read_text())["title"] == v["title"]
        conf = Path(d) / "conf"
        env = dict(os.environ, POG_YT_CONF=str(conf))
        r = subprocess.run([sys.executable, str(HERE / "yt_upload.py"), "sb", "--video-dir", str(out), "--dry-run",
                            "--videos-json", str(Path(d) / "videos.json")], capture_output=True, text=True, env=env)
        assert r.returncode == 0, r.stderr
        for want in ("uploadType=resumable", "thumbnails" if (out / "thumb.png").exists() else "playlists?part=snippet",
                     "playlistItems", '"privacyStatus": "public"', "1 upload of the 100 a day"):
            assert want in r.stdout, (want, r.stdout[-2000:])
        assert not conf.exists() and not (Path(d) / "videos.json").exists() and not (out / "upload.json").exists()
        # the refusals come before sign-in; "running" is set here, since build() reads the clock
        vj = json.loads((out / "video.json").read_text())
        for flags, want in (({"running": True}, "while the shift was on"),
                            ({"running": False, "estimated": True}, "without the box's recording list"),
                            ({"running": False, "estimated": False}, "not signed in")):
            (out / "video.json").write_text(json.dumps(dict(vj, **flags)))
            r = subprocess.run([sys.executable, str(HERE / "yt_upload.py"), "sb", "--video-dir", str(out), "--file",
                                __file__], capture_output=True, text=True, env=env)
            assert r.returncode != 0 and want in r.stderr, (flags, r.stderr)
        assert not conf.exists() and not (out / "upload.json").exists()
    print("shift videos: ok (box clock, split files, edges, midnight, chapter rules and picks, description, box plan, "
          "upload dry run, repeated far trials and records, titles unlike the shift before's)")


if __name__ == "__main__":
    main()
