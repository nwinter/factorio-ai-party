#!/usr/bin/env python3
"""/agents/ and /timeline/ from a made-up long run of two shifts: python3 site/test_agents.py

- tools/agent_stats.py: game actions, talk and reads apart; built by hand, by a queue job (once, though two replies
  carry it) and by a route (a dry run builds nothing); mined; walked between move targets (a long hop left out);
  research by the queue's queued_by and finished by the score log; rockets; chat, marked aloud, viewer replies (an
  @mention of a teammate is none); tells, confessions; deaths from the director (two lines, one death; past
  midnight); lines voiced and the voice; operator requests (a viewer's line is none); the cache is reused and
  recounted when a journal grows; hand hauling from the journal's direct moves (items, calls, carry legs, top
  repeated haul; a walking collect's reply holds no count) or, where the stream kept them, the game's counters;
- the site: cards, records (most built in a shift, longest survival), the comparison table, nav entries, the timeline
  with its filters; no log text on the pages; check.py passes;
- tokens (tools/stream/tokens.py, its own test: tools/stream/test_tokens.py): the agents' CLI session logs by shift, a
  table for the run with bars by shift, the latest ended shift's context sizes and compactions, each card's tokens and
  tokens per game action.
"""
import gzip, json, os, subprocess, sys, tempfile, time
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
    # hand hauling, direct: a take, a put 30 tiles on, a feed of two furnaces 4 and 8 tiles past it, a walking collect
    # (its reply holds no count), a take from one machine, a put 31 tiles away
    j.call("2026-10-13T06:02:35Z", "observe", {}, result={"player": {"surface": "nauvis"}})
    j.call("2026-10-13T06:02:36Z", "transfer", {"position": {"x": 10, "y": 0}, "item": "iron-plate", "direction": "to_player"},
           result={"transferred": 50})
    j.call("2026-10-13T06:02:37Z", "transfer", {"position": {"x": 40, "y": 0}, "item": "iron-plate"},
           result={"transferred": 40, "direction": "to_entity"})
    j.call("2026-10-13T06:02:38Z", "feed", {"positions": [{"x": 40, "y": 4}, {"x": 40, "y": 8}]},
           result={"transferred": 10, "items": {"iron-plate": 10}, "entities": [
               {"position": {"x": 40, "y": 4}, "gave": {"iron-plate": 5}}, {"position": {"x": 40, "y": 8}, "gave": {"iron-plate": 5}}]})
    j.call("2026-10-13T06:02:39Z", "collect", {"radius": 20}, result={"stock": 30, "places": 2, "until_tick": 99})
    j.call("2026-10-13T06:02:40Z", "collect", {"positions": [{"x": 10, "y": 0}]},
           result={"transferred": 7, "items": [{"name": "iron-plate", "count": 7}],
                   "entities": [{"position": {"x": 10, "y": 0}, "transferred": 7}]})
    j.call("2026-10-13T06:02:41Z", "transfer", {"position": {"x": 41, "y": 1}, "item": "iron-plate", "direction": "to_entity"},
           result={"transferred": 7})
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
        "[director] 00:10:00 ON AIR main: @attack  <- death: Opus died\n"
        "[director] 00:10:33 main:  zoom 1.1  <- death: Opus died\n"
        "[director] 00:10:35 ON AIR main: @attack  <- death: Opus died\n")
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
    m.call("2026-10-13T09:00:05Z", "transfer", {"position": {"x": 1, "y": 1}, "item": "coal", "direction": "to_entity"},
           result={"transferred": 9999})  # the game's counters below win over the journal
    (b / "opus" / "journal.jsonl").write_text(m.text())
    # the stream's reads of the game's hand hauling counters (tools/stream/hauling.py): the shift is last less first
    def haul_row(t, items, calls, direct, queue, order, carry, hauls):
        return {"t": t, "tick": 1, "agents": [{"name": "opus", "items": items, "calls": calls, "direct_items": direct,
                                               "direct_calls": calls // 2, "queue_items": queue, "queue_calls": 8,
                                               "order_items": order, "order_calls": 2, "carry_tiles": carry,
                                               "hauls": hauls}, {"name": "nick", "items": 5, "calls": 1}]}
    coal = {"item": "coal", "surface": "nauvis", "from": {"x": 9, "y": 38}, "to": {"x": 0, "y": 42}, "to_name": "boiler"}
    (b / "hauling.jsonl").write_text(
        json.dumps(haul_row(1, 100, 10, 100, 0, 0, 40, [dict(coal, times=2, items=20)])) + "\n"
        + json.dumps(haul_row(2, 400, 30, 250, 120, 30, 540, [dict(coal, times=14, items=140)])) + "\n")
    # the stream's reads of the game's machine credit (tools/stream/efficiency.py): the shift's last read counts
    (b / "efficiency.jsonl").write_text(json.dumps({"t": 1, "tick": 1, "team": {"items_shift": 10}, "agents": []}) + "\n" + json.dumps({
        "t": 2, "tick": 2, "team": {"items_shift": 5000, "machine_share_pct": 94, "machines": 40, "running": 30, "ore_shift_about": 900},
        "agents": [{"name": "opus", "items_shift": 4700, "machine_share_pct": 94, "machines": 12, "running": 9, "ore_shift_about": 300},
                   {"name": "built before the count", "before": True, "items_shift": 300, "machines": 28}]}) + "\n")
    (b / "stream-service.log").write_text("")
    # basemap snapshots (tools/stream/basemap_log.py): two in shift 1, one in shift 2, and a file that is none
    for d_, tick, rows in ((a, 36000, ["A."]), (a, 72000, ["AS"]), (b, 400000, ["ASM", "E.."])):
        (d_ / "basemap").mkdir(exist_ok=True)
        (d_ / "basemap" / f"{tick}.json").write_text(json.dumps({
            "tick": tick, "cell": 8, "x0": -16, "y0": -8, "w": len(rows[0]), "h": len(rows), "rows": rows,
            "core": {"cell": 2, "x0": -10, "y0": -6, "w": 3, "h": 1, "rows": ["AAS"]},
            **({"nests": [[90, 10, "s"]], "turrets": [[4, 4, 18]]} if tick == 400000 else {})}))
    (b / "basemap" / "notes.json").write_text("{}")
    # a terrain frame (tools/stream/mapframes.py) in shift 2, between its snapshots' ticks
    (b / "mapframes").mkdir(exist_ok=True)
    (b / "mapframes" / "0_0.webp").write_bytes(b"RIFF....WEBP")
    (b / "mapframes" / "0_0.json").write_text(json.dumps({"tick": 390000, "surface": "nauvis", "box": [-40, -30, 160, 90],
                                                          "px": [1600, 900], "area": "0_0"}))
    # the old stream service wrote the earlier shifts' requests into each new inbox again: sol's seq 1 is shift 1's
    (b / "operator-inbox.jsonl").write_text(
        json.dumps({"t": 2, "seq": 1, "agent": "sol", "text": "SECRET-REQUEST-TEXT"}) + "\n"
        + json.dumps({"t": 3, "seq": 2, "agent": "opus", "text": "SECRET-REQUEST-TEXT"}) + "\n"
        + json.dumps({"t": 3, "seq": 2, "agent": "opus", "text": "SECRET-REQUEST-TEXT"}) + "\n")


def iso(day_hm):
    return day_hm + ":00.000Z"


def token_logs(root, homes):
    """Opus's Claude Code sessions in both shifts (one compaction in the second), Sol's Codex rollout in the first."""
    import re
    def claude_dir(run):
        return homes["claude"] / "projects" / re.sub(r"[^A-Za-z0-9]", "-", str((root / run / "opus").resolve()))
    def msg(mid, at, cr, out):
        return json.dumps({"type": "assistant", "timestamp": at, "message": {"id": mid, "model": "claude-opus-5-5", "usage": {
            "input_tokens": 10, "cache_creation_input_tokens": 0, "cache_read_input_tokens": cr, "output_tokens": out}}})
    for run, lines in (("sa", [msg("a1", iso("2026-10-13T06:00"), 90_000, 1_000), msg("a2", iso("2026-10-13T06:05"), 140_000, 2_000)]),
                       ("sb", [msg("b1", iso("2026-10-13T09:00"), 40_000, 500),
                               json.dumps({"type": "system", "subtype": "compact_boundary", "timestamp": iso("2026-10-13T09:01")})])):
        claude_dir(run).mkdir(parents=True)
        (claude_dir(run) / "s.jsonl").write_text("\n".join(lines) + "\n")
    rollout = homes["codex"] / "sessions" / "2026" / "10" / "12" / "rollout-x.jsonl"
    rollout.parent.mkdir(parents=True)
    rollout.write_text(json.dumps({"timestamp": iso("2026-10-13T06:00"), "type": "session_meta",
                                   "payload": {"cwd": str((root / "sa" / "sol").resolve())}}) + "\n" +
                       json.dumps({"timestamp": iso("2026-10-13T06:00"), "type": "token_usage_record", "payload": {
                           "response_id": "r1", "usage": {"input_tokens": 5_000_000, "cached_input_tokens": 4_000_000,
                                                          "output_tokens": 20_000}}}) + "\n")


def main():
    with tempfile.TemporaryDirectory() as d:
        root = Path(d) / "runs"
        make(root)
        homes = {k: Path(d) / "home" / k for k in ("claude", "codex", "grok", "agy", "muse")}
        for h in homes.values():
            h.mkdir(parents=True)
        os.environ["POG_TOKEN_ROOTS"] = json.dumps({k: [str(v)] for k, v in homes.items()})  # build.py's too
        token_logs(root, homes)
        c = agent_stats.compute(root / "sa", ["Opus", "Sol"])
        o, s = c["agents"]["opus"], c["agents"]["sol"]
        assert (o["requests"], o["reads"], o["talk"], o["actions"]) == (24, 3, 5, 16), o
        # hand hauling from the journal: direct moves whose reply says what moved; carry 30 + 4 + 4 + 31
        assert (o["haul_items"], o["haul_calls"], o["haul_direct_items"], o["haul_carry"]) == (114, 5, 114, 69), o
        assert o["haul_queue_items"] is None and o["haul_order_items"] is None and o["haul_from"] == "journal", o
        assert o["haul_top"] == {"item": "iron-plate", "surface": "nauvis", "times": 4, "items": 57,
                                 "from": {"x": 10, "y": 0}, "to": {"x": 40, "y": 0}}, o["haul_top"]
        assert s["haul_items"] == 0 and s["haul_top"] is None, s
        # from the game's counters (shift 2): queue and standing order steps too; the journal's direct move ignored
        g = agent_stats.compute(root / "sb", ["Opus"])["agents"]["opus"]
        assert (g["haul_items"], g["haul_calls"], g["haul_direct_items"], g["haul_queue_items"], g["haul_order_items"],
                g["haul_carry"], g["haul_from"]) == (300, 20, 150, 120, 30, 500, "game"), g
        assert g["haul_top"]["item"] == "coal" and g["haul_top"]["times"] == 12 and g["haul_top"]["items"] == 120, g
        # machines opus built (efficiency.jsonl, shift 2's last read); shift 1 has no reads
        assert (g["made_items"], g["made_share_pct"], g["machines"], g["machines_working"]) == (4700, 94, 12, 9), g
        assert o.get("made_items") is None and c["machines_team"] is None, o
        assert agent_stats.compute(root / "sb", ["Opus"])["machines_team"]["made_items"] == 5000
        assert o["failed"] == 1 and o["built"] == 2 + 5 + 3 and o["mined"] == 1, o
        assert o["walked"] == 50 and o["moves"] == 3, o  # 0,0 to 30,40; the 2970-tile hop left out
        assert (o["research"], o["research_done"], s["research"], s["research_done"]) == (2, 1, 1, 1), (o, s)
        assert o["rockets"] == 1 and o["say"] == 2 and o["aloud_marked"] == 1 and o["viewer_answers"] == 1, o
        assert o["tells"] == 1 and o["confessions"] == 2 and o["voiced"] == 2 and o["voice"] == "el-george", o
        assert o["deaths"] == 3 and s["deaths"] == 0 and (o["operator"], s["operator"]) == (0, 1), (o, s)
        # deaths in game ticks from the first of the two lines (23:40:58, after the 23:30 score); 00:10 is past midnight;
        # a second death 33 s later counts
        assert o["death_ticks"] == [3600 * 31 + (10 * 60 + 58) * 60, 3600 * 31 + 40 * 3600,
                                    3600 * 31 + 40 * 3600 + 33 * 60], o["death_ticks"]
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
        # tokens: opus in both shifts (a compaction in the second), sol in the first; per game action over the same shifts
        tk = data["tokens"]
        to, ts = tk["totals"]["opus"], tk["totals"]["sol"]
        assert (to["total"], to["calls"], to["shifts"], to["resets"], to["context_max"]) == (273_530, 3, 2, 1, 140_010), to
        assert to["actions"] == data["totals"]["opus"]["actions"] and to["per_action"] == to["total"] / to["actions"], to
        assert (ts["total"], ts["cached"], ts["shifts"]) == (5_020_000, 80.0, 1), ts
        assert [n for n, _ in tk["per_shift"]["opus"]] == [1, 2] and tk["last"][0] == 1  # the latest ended shift

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
        assert '<span class="r-value">2h20m</span>' in surv and "Opus" in surv and "still alive" in surv, surv
        assert 'table class="compare"' in page and "data-v=" in page
        tok = page.split('<h2 id="tokens">Tokens</h2>')[1].split("<h2 ")[0]
        assert "shifts 1 to 2" in tok and tok.index('href="#sol"') < tok.index('href="#opus"'), tok  # most tokens first
        orow = tok.split('href="#opus"')[1].split("</tr>")[0]
        assert 'data-v="273530" title="273,530">274K<' in orow and orow.count('<span style="height:') == 2, orow
        assert 'data-v="1">1<' in orow  # one context reset
        srow = tok.split('href="#sol"')[1].split("</tr>")[0]
        assert ">5.0M<" in srow and ">80%<" in srow and srow.count('<span style="height:') == 1, srow
        assert 'id="context">Context size through shift 1</h3>' in tok and "peak 140K" in tok and "<polyline" in tok, tok
        card = page.split('<article class="agent-card" id="opus"')[1].split("</article>")[0]
        assert "<dt>Tokens</dt><dd>274K</dd>" in card and "<dt>Tokens per game action</dt>" in card, card
        assert "Context resets" in page.split('id="notes"')[1]
        # hand hauling: the run by agent (shift 1's journal, shift 2's game counters), items by shift, the note
        hl = page.split('<h2 id="hauling">Hand hauling</h2>')[1].split('<h2 ')[0]
        assert "Queue and standing order steps counted in shift 2; other shifts count direct moves only." in hl, hl
        orow = hl.split('href="#opus"')[1].split("</tr>")[0]
        for want in ('data-v="414">414<', 'data-v="25">25<', 'data-v="264">264<', 'data-v="120">120<',
                     'data-v="30">30<', 'data-v="569">569<', "coal ×12: (9, 38) → (0, 42), Nauvis", "shift 2"):
            assert want in orow, (want, orow)
        srow = hl.split('class="compare hauling"')[1].split('href="#sol"')[1].split("</tr>")[0]
        assert '<td data-v="">–' in srow and "data-v=\"0\">0<" in srow, srow  # no queue counts on its shift: a dash
        by_shift = hl.split('id="hauling-shifts"')[1]
        assert 'title="5 calls">114<' in by_shift and 'title="20 calls">300<' in by_shift, by_shift
        hrec = page.split("Most items hauled by hand in a shift</span>")[1].split("</li>")[0]
        assert '<span class="r-value">300</span>' in hrec and "shift 2" in hrec, hrec
        assert "Tiles carried" in page.split('id="notes"')[1]
        # machines built: opus's row (4700 made; 300 hauled in shift 2: 94%), the team by shift (shift 2 only)
        mc = page.split('<h2 id="machines">Machines built</h2>')[1].split('<h2 ')[0]
        mrow = mc.split('href="#opus"')[1].split("</tr>")[0]
        for want in ('data-v="4700">4,700<', ">94%<", 'data-v="12">12<', 'data-v="9">9<'):
            assert want in mrow, (want, mrow)
        assert 'href="#sol"' not in mc.split('class="compare machines"')[1].split("</table>")[0], mc  # no reads: no row
        team_rows = mc.split('id="machines-shifts"')[1]
        assert '<th scope="row">2</th><td data-v="5000">5,000</td><td data-v="94">94%</td>' in team_rows, team_rows
        assert "Moved by machines" in page.split('id="notes"')[1]
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
        # the highlights (site/content/moments.json, the agent-minds study) above the lines
        n_moments = len(json.loads((SITE / "content" / "moments.json").read_text()))
        assert f'id="highlights"><h2>Highlights<span class="h-sub">{n_moments} moments</span>' in chat
        assert chat.index('id="highlights"') < chat.index('class="hl-shift"') and 'id="m5"' in chat and "Seen: <span" in chat
        assert 'id="m3"' not in chat and 'class="private"' not in chat  # private moments stay in the study
        # search: the index has the agents, shifts, events and chat lines, each with a link that exists
        tl = (out / "timeline" / "index.html").read_text()
        idx = json.loads((out / "search" / "index.json").read_text())
        kinds = {e["kind"] for e in idx}
        assert kinds == {"agent", "shift", "event", "line"}, kinds
        by = {(e["kind"], e["title"]): e for e in idx}
        assert by[("agent", "Opus")]["url"] == "/agents/#opus" and "Anthropic" in by[("agent", "Opus")]["sub"]
        assert by[("shift", "Shift 2")]["url"] == "/runs/long/shift-2/"
        died = [e for e in idx if e["title"] == "Opus died"]
        assert len(died) == 3 and all(e["url"].startswith("/timeline/#e") for e in died), died
        assert all(f'id="{e["url"].split("#")[1]}"' in tl for e in idx if e["kind"] == "event")
        line = next(e for e in idx if e["kind"] == "line" and e["text"].startswith("Turrets first"))
        assert line["url"].startswith("/chat/#s1-") and f'id="{line["url"].split("#")[1]}"' in chat, line
        assert "SECRET" not in json.dumps(idx) and "example.com" not in json.dumps(idx)
        # the time-lapse: all shifts' snapshots in order, on the run page
        lapse = json.loads((out / "runs" / "long" / "timelapse.json").read_text())
        assert [(f["n"], f["tick"]) for f in lapse["frames"]] == [(1, 36000), (1, 72000), (2, 400000)], lapse["frames"]
        assert lapse["frames"][0]["game"] == "10m00s", lapse["frames"][0]  # build.py's game_time
        assert lapse["frames"][2]["core"]["rows"] == ["AAS"] and len(lapse["box"]) == 4, lapse
        # the viewer's nests and turret-range layers, from the snapshots that have them; the page loads the viewer
        assert lapse["frames"][2]["nests"] == [[90, 10, "s"]] and lapse["frames"][2]["turrets"] == [[4, 4, 18]], lapse["frames"][2]
        assert "nests" not in lapse["frames"][0]
        # the terrain frames (site/terrain.py) go with the time-lapse, published beside the live map's
        ter = lapse.get("terrain") or [{}]
        assert len(ter) == 1 and ter[0]["src"].startswith("/live/terrain/") and ter[0]["src"].endswith("-0_0-390000.webp"), ter
        assert {k: ter[0][k] for k in ("x0", "y0", "x1", "y1", "tick", "w", "h")} == {"x0": -40, "y0": -30, "x1": 120, "y1": 60,
                                                                                    "tick": 390000, "w": 1600, "h": 900}, ter
        assert (out / lapse["terrain"][0]["src"].lstrip("/")).is_file()
        run_page = (out / "runs" / "long" / "index.html").read_text()
        assert 'id="timelapse"' in run_page and 'data-src="/runs/long/timelapse.json"' in run_page and '<script src="/static/mapview.js">' in run_page
        assert '<option value="2" label="Shift 2">' in run_page and "3 snapshots" in run_page
        assert run_page.index('id="timelapse"') < run_page.index("</main>")
        sp = (out / "search" / "index.html").read_text()
        assert 'id="search-q"' in sp and "/search/index.json" in sp and 'href="/search/"' in sp
        assert chat.index('id="shift-2"') < chat.index('id="shift-1"') if 'id="shift-2"' in chat else True
        assert 'href="/agents/"' in (out / "index.html").read_text() and 'href="/timeline/"' in page
        tl = (out / "timeline" / "index.html").read_text()
        for want in ('data-kind="research"', "Logistics", "Rocket 1", "Rockets 2 to 3", "Platform Kite built",
                     "Reached Vulcanus", 'data-kind="death"', 'value="death" checked', "Deaths (3)"):
            assert want in tl, want
        assert tl.index("Logistics") < tl.index("Reached Vulcanus") < tl.index("Rocket 4")
    print("agents: ok (stats per shift, cache, cards, records, comparison, timeline, tokens, check.py)")


if __name__ == "__main__":
    main()
