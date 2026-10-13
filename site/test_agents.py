#!/usr/bin/env python3
"""/agents/ and /timeline/ from a made-up long run of two shifts: python3 site/test_agents.py

- tools/agent_stats.py: game actions, talk and reads apart; built by hand, by a queue job (once, though two replies
  carry it) and by a route (a dry run builds nothing); mined; walked between move targets (a long hop left out);
  research by the queue's queued_by and finished by the score log; rockets; chat, marked aloud, viewer replies (an
  @mention of a teammate is none); tells, confessions; deaths from the director (two lines, one death; past
  midnight); lines voiced and the voice; operator requests (a viewer's line is none); the cache is reused and
  recounted when a journal grows;
- the site: cards, records (most built in a shift, longest survival), the comparison table, nav entries, the timeline
  with its filters; no log text on the pages; check.py passes.
"""
import gzip, json, subprocess, sys, tempfile, time
from pathlib import Path

SITE = Path(__file__).resolve().parent
sys.path.insert(0, str(SITE.parent / "tools"))
import agent_stats  # noqa: E402


def score(t, tick, done, rockets=0, platforms=(), planets=("nauvis",)):
    return json.dumps({"t": t, "world": "n", "score": {"tick": tick, "research_done": list(done), "rockets": rockets,
                       "produced": {"automation-science-pack": tick // 100},
                       "platforms": [{"name": p, "hub": True, "at": "nauvis"} for p in platforms],
                       "planets": list(planets)}})


class Journal:
    def __init__(self):
        self.lines, self.n = [], 0

    def call(self, at, action, args=None, ok=True, result=None):
        self.n += 1
        rid = f"r{self.n}"
        self.lines.append({"at": at, "event": "request", "request": {"id": rid, "action": action, "bot": "x", "args": args or {}}})
        resp = {"id": rid, "ok": ok, "tick": 1}
        resp.update({"result": result or {"clock": "game 1h; +1s since your last request"}} if ok else
                    {"error": {"code": "action_failed", "message": "SECRET-ERROR-TEXT"}})
        self.lines.append({"at": at, "event": "response", "response": resp})

    def text(self):
        return "".join(json.dumps(x) + "\n" for x in self.lines)


def make(root):
    a = root / "sa"
    (a / "opus").mkdir(parents=True)
    (a / "sol").mkdir()
    (a / "team.txt").write_text("opus|Claude Opus 5.5 (Claude Code)\nsol|GPT-6.1 Sol (Codex)\n")
    (a / "scores.jsonl").write_text("\n".join([
        score("2026-10-12T23:00:00", 3600, ["automation"]),
        score("2026-10-12T23:30:00", 3600 * 31, ["automation", "logistics"], rockets=1, platforms=["Kite"]),
        score("2026-10-13T00:30:00", 3600 * 91, ["automation", "logistics", "steel-processing"], rockets=3,
              platforms=["Kite"], planets=("nauvis", "vulcanus"))]) + "\n")
    j = Journal()
    j.call("2026-10-13T06:00:10Z", "observe")
    j.call("2026-10-13T06:00:20Z", "move_to", {"position": {"x": 0, "y": 0}}, result={"position": {"x": 0, "y": 0}})
    j.call("2026-10-13T06:00:30Z", "move_to", {"position": {"x": 30, "y": 40}}, result={"position": {"x": 30, "y": 40}})
    j.call("2026-10-13T06:01:30Z", "move_to", {"position": {"x": 3000, "y": 40}}, result={"position": {"x": 3000, "y": 40}})
    j.call("2026-10-13T06:02:00Z", "build", {"item": "gun-turret"}, result={"built": 2, "placed": [{}, {}]})
    j.call("2026-10-13T06:02:10Z", "build", {"item": "gun-turret"}, ok=False)
    j.call("2026-10-13T06:02:20Z", "pole_route", {}, result={"placed": 5})
    j.call("2026-10-13T06:02:30Z", "pipe_route", {}, result={"placed": 9, "dry_run": True})
    hist = [{"id": "job-1", "action": "build", "ok": True, "result": {"built": 3}},
            {"id": "job-2", "action": "mine", "ok": True, "result": {"completion": {"kind": "mine"}}}]
    j.call("2026-10-13T06:03:00Z", "queue_submit", {"steps": []}, result={"history": hist})
    j.call("2026-10-13T06:03:30Z", "queue_resume", {}, result={"history": hist})  # the same jobs again
    j.call("2026-10-13T06:04:00Z", "research", {}, result={"entries": [
        {"name": "logistics", "queued_by": "opus"}, {"name": "steel-processing", "queued_by": "sol"},
        {"name": "rocket-silo", "queued_by": "opus"}]})
    j.call("2026-10-13T06:04:10Z", "launch", {}, result={"launched": True, "to": "platform Kite"})
    j.call("2026-10-13T06:05:00Z", "say", {"text": "@Joonazan yes, the wall comes first", "aloud": True})
    j.call("2026-10-13T06:05:10Z", "say", {"text": "@sol taking the turrets"})
    j.call("2026-10-13T06:05:20Z", "tell", {"to": "sol", "text": "hi"})
    j.call("2026-10-13T06:05:30Z", "confess", {"text": "I walked into the nest. Mail me at bot@example.com"})
    j.call("2026-10-13T06:05:40Z", "confess", {"text": "Nick should SECRET-OWNER-LINE"})  # names the owner: left out
    with gzip.open(a / "opus" / "journal.jsonl.gz", "wt") as f:  # an ended shift's journal is compressed
        f.write(j.text())
    k = Journal()
    k.call("2026-10-13T06:00:15Z", "craft", {"recipe": "x"})
    (a / "sol" / "journal.jsonl").write_text(k.text())
    (a / "stream-service.log").write_text(
        "[director] 23:40:58 cam2:  zoom 1.1  <- death: Opus died\n"
        "[director] 23:41:00 ON AIR cam2: @attack  <- death: Opus died\n"
        "[director] 00:10:00 ON AIR main: @attack  <- death: Opus died\n")
    (a / "caster.log").write_text(
        "23:05:00 [caster] feed http://x\n"
        "23:05:10 [voice:Opus/el-george] (aloud) Turrets first, then the wall.\n"
        "00:20:00 [voice:Opus/el-george] (reaction) Past midnight & still here.\n"
        "23:06:10 [voice:Operator/saturn] sol Operator: hi\n")
    (a / "operator-inbox.jsonl").write_text(
        json.dumps({"t": 1, "seq": 1, "agent": "sol", "text": "SECRET-REQUEST-TEXT"}) + "\n"
        + json.dumps({"t": 1, "seq": 2, "agent": "viewer Bob", "text": "hello", "viewer": True}) + "\n")
    b = root / "sb"
    (b / "opus").mkdir(parents=True)
    (b / "resumed-from").write_text("sa\n")
    (b / "team.txt").write_text("opus|Claude Opus 5.5 (Claude Code)\n")
    (b / "scores.jsonl").write_text("\n".join([
        score("2026-10-13T02:00:00", 3600 * 92, ["automation", "logistics", "steel-processing"], rockets=3,
              platforms=["Kite"], planets=("nauvis", "vulcanus")),
        score("2026-10-13T04:00:00", 3600 * 212, ["automation", "logistics", "steel-processing", "rocket-silo"],
              rockets=4, platforms=["Kite"], planets=("nauvis", "vulcanus"))]) + "\n")
    m = Journal()
    m.call("2026-10-13T09:00:00Z", "build", {}, result={"built": 7})
    (b / "opus" / "journal.jsonl").write_text(m.text())
    (b / "stream-service.log").write_text("")
    # basemap snapshots (tools/stream/basemap_log.py): two in shift 1, one in shift 2, and a file that is none
    for d_, tick, rows in ((a, 36000, ["A."]), (a, 72000, ["AS"]), (b, 400000, ["ASM", "E.."])):
        (d_ / "basemap").mkdir(exist_ok=True)
        (d_ / "basemap" / f"{tick}.json").write_text(json.dumps({
            "tick": tick, "cell": 8, "x0": -16, "y0": -8, "w": len(rows[0]), "h": len(rows), "rows": rows,
            "core": {"cell": 2, "x0": -10, "y0": -6, "w": 3, "h": 1, "rows": ["AAS"]}}))
    (b / "basemap" / "notes.json").write_text("{}")
    # the old stream service wrote the earlier shifts' requests into each new inbox again: sol's seq 1 is shift 1's
    (b / "operator-inbox.jsonl").write_text(
        json.dumps({"t": 2, "seq": 1, "agent": "sol", "text": "SECRET-REQUEST-TEXT"}) + "\n"
        + json.dumps({"t": 3, "seq": 2, "agent": "opus", "text": "SECRET-REQUEST-TEXT"}) + "\n"
        + json.dumps({"t": 3, "seq": 2, "agent": "opus", "text": "SECRET-REQUEST-TEXT"}) + "\n")


def main():
    with tempfile.TemporaryDirectory() as d:
        root = Path(d) / "runs"
        make(root)
        c = agent_stats.compute(root / "sa", ["Opus", "Sol"])
        o, s = c["agents"]["opus"], c["agents"]["sol"]
        assert (o["requests"], o["reads"], o["talk"], o["actions"]) == (17, 2, 5, 10), o
        assert o["failed"] == 1 and o["built"] == 2 + 5 + 3 and o["mined"] == 1, o
        assert o["walked"] == 50 and o["moves"] == 3, o  # 0,0 to 30,40; the 2970-tile hop left out
        assert (o["research"], o["research_done"], s["research"], s["research_done"]) == (2, 1, 1, 1), (o, s)
        assert o["rockets"] == 1 and o["say"] == 2 and o["aloud_marked"] == 1 and o["viewer_answers"] == 1, o
        assert o["tells"] == 1 and o["confessions"] == 2 and o["voiced"] == 2 and o["voice"] == "el-george", o
        assert o["deaths"] == 2 and s["deaths"] == 0 and (o["operator"], s["operator"]) == (0, 1), (o, s)
        # deaths in game ticks from the first of the two lines (23:40:58, after the 23:30 score); 00:10 is past midnight
        assert o["death_ticks"] == [3600 * 31 + (10 * 60 + 58) * 60, 3600 * 31 + 40 * 3600], o["death_ticks"]
        assert o["active_min"] == 5 and o["minutes"] == 6 and s["actions"] == 1, o
        assert "SECRET-ERROR-TEXT" not in json.dumps(c) and "SECRET-REQUEST-TEXT" not in json.dumps(c)
        # text kept for /chat/: the voiced lines (game tick from the wall clock, past midnight too) and confessions
        assert [r[1:] for r in o["spoken_lines"]] == [["aloud", "Turrets first, then the wall."],
                                                      ["reaction", "Past midnight & still here."]], o["spoken_lines"]
        assert o["spoken_lines"][1][0] == 3600 * 31 + 50 * 3600, o["spoken_lines"]  # 00:20, 50 minutes after 23:30
        assert [t for _, t in o["confession_lines"]][0].startswith("I walked into the nest"), o["confession_lines"]
        # the cache: reused while the sources stand, recounted when one grows
        cache = Path(d) / "cache"
        c1 = agent_stats.load(root / "sa", cache)
        (cache / "sa.json").write_text((cache / "sa.json").read_text().replace('"built": 10', '"built": 999'))
        assert agent_stats.load(root / "sa", cache)["agents"]["opus"]["built"] == 999  # from the cache
        time.sleep(1.1)
        with open(root / "sa" / "sol" / "journal.jsonl", "a") as f:
            f.write("\n")
        assert agent_stats.load(root / "sa", cache)["agents"]["opus"]["built"] == 10 == c1["agents"]["opus"]["built"]

        sys.path.insert(0, str(SITE))
        import agents as agent_pages
        import longrun
        data = agent_pages.collect(longrun.load(root, start="sa"), root, ["opus", "sol"], cache)
        assert (data["totals"]["sol"]["operator"], data["totals"]["opus"]["operator"]) == (1, 1), data["totals"]
        assert [a["operator"] for _, a in data["per_shift"]["opus"]] == [0, 1], data["per_shift"]["opus"]

        out = Path(d) / "dist"
        content = json.loads((SITE / "content" / "site.json").read_text())
        content.update(archive=False, run_start="sa")
        (Path(d) / "site.json").write_text(json.dumps(content))
        subprocess.run([sys.executable, str(SITE / "build.py"), "--out", str(out), "--runs-dir", str(root),
                        "--content", str(Path(d) / "site.json"), "--stats-cache", str(cache)],
                       check=True, capture_output=True)
        r = subprocess.run([sys.executable, str(SITE / "check.py"), str(out)], capture_output=True, text=True)
        assert r.returncode == 0, r.stdout
        page = (out / "agents" / "index.html").read_text()
        assert 'id="opus"' in page and 'id="sol"' in page and 'id="astra"' not in page  # only who played
        assert "Shifts 1 to 2" in page and "Voice: el-george" in page and "Claude Opus 5.5 · Anthropic" in page
        rec = page.split("Most buildings placed in a shift</span>")[1].split("</li>")[0]
        assert '<span class="r-value">10</span>' in rec and "shift 1" in rec, rec
        surv = page.split("Longest survival (game time)</span>")[1].split("</li>")[0]
        # Opus: since its 00:10 death (tick 255600) to the end of shift 2 (tick 763200); Sol played shift 1 only (1h30m)
        assert '<span class="r-value">2h21m</span>' in surv and "Opus" in surv and "still alive" in surv, surv
        assert 'table class="compare"' in page and "data-v=" in page
        # by maker, per agent-shift: Anthropic is Opus on two shifts (10 and 7 built), OpenAI is Sol on one
        mk = page.split('<h2 id="makers">')[1].split("</table>")[0]
        anth = mk.split('<th scope="row">Anthropic</th>')[1].split("</tr>")[0]
        assert '<td data-v="2">2</td>' in anth and ">8.5<" in anth and "#opus" in anth, anth
        assert '<th scope="row">OpenAI</th>' in mk and "xAI" not in mk  # only makers that played
        assert "SECRET" not in page and "Joonazan" not in page and "Turrets first" not in page
        chat = (out / "chat" / "index.html").read_text()
        for want in ("Turrets first, then the wall.", "Past midnight &amp; still here.", "Spoken · reaction",
                     "I walked into the nest", "[email]", 'data-kind="confession"', 'data-agent="opus"',
                     'id="hl-q"', 'value="confession" checked', "Confessions (1)", "Spoken on stream (2)", 'href="/chat/"'):
            assert want in chat, want
        assert "SECRET" not in chat and "example.com" not in chat and "Nick" not in chat
        # search: the index has the agents, shifts, events and chat lines, each with a link that exists
        tl = (out / "timeline" / "index.html").read_text()
        idx = json.loads((out / "search" / "index.json").read_text())
        kinds = {e["kind"] for e in idx}
        assert kinds == {"agent", "shift", "event", "line"}, kinds
        by = {(e["kind"], e["title"]): e for e in idx}
        assert by[("agent", "Opus")]["url"] == "/agents/#opus" and "Anthropic" in by[("agent", "Opus")]["sub"]
        assert by[("shift", "Shift 2")]["url"] == "/runs/long/shift-2/"
        died = [e for e in idx if e["title"] == "Opus died"]
        assert len(died) == 2 and all(e["url"].startswith("/timeline/#e") for e in died), died
        assert all(f'id="{e["url"].split("#")[1]}"' in tl for e in idx if e["kind"] == "event")
        line = next(e for e in idx if e["kind"] == "line" and e["text"].startswith("Turrets first"))
        assert line["url"].startswith("/chat/#s1-") and f'id="{line["url"].split("#")[1]}"' in chat, line
        assert "SECRET" not in json.dumps(idx) and "example.com" not in json.dumps(idx)
        # the time-lapse: all shifts' snapshots in order, on the run page
        lapse = json.loads((out / "runs" / "long" / "timelapse.json").read_text())
        assert [(f["n"], f["tick"]) for f in lapse["frames"]] == [(1, 36000), (1, 72000), (2, 400000)], lapse["frames"]
        assert lapse["frames"][0]["game"] == "10m00s", lapse["frames"][0]  # build.py's game_time
        assert lapse["frames"][2]["core"]["rows"] == ["AAS"] and len(lapse["box"]) == 4, lapse
        run_page = (out / "runs" / "long" / "index.html").read_text()
        assert 'id="timelapse"' in run_page and 'data-src="/runs/long/timelapse.json"' in run_page
        assert '<option value="2" label="Shift 2">' in run_page and "3 snapshots" in run_page
        assert run_page.index('id="timelapse"') < run_page.index("</main>")
        sp = (out / "search" / "index.html").read_text()
        assert 'id="search-q"' in sp and "/search/index.json" in sp and 'href="/search/"' in sp
        assert chat.index('id="shift-2"') < chat.index('id="shift-1"') if 'id="shift-2"' in chat else True
        assert 'href="/agents/"' in (out / "index.html").read_text() and 'href="/timeline/"' in page
        tl = (out / "timeline" / "index.html").read_text()
        for want in ('data-kind="research"', "Logistics", "Rocket 1", "Rockets 2 to 3", "Platform Kite built",
                     "Reached Vulcanus", 'data-kind="death"', 'value="death" checked', "Deaths (2)"):
            assert want in tl, want
        assert tl.index("Logistics") < tl.index("Reached Vulcanus") < tl.index("Rocket 4")
    print("agents: ok (stats per shift, cache, cards, records, comparison, timeline, check.py)")


if __name__ == "__main__":
    main()
