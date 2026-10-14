#!/usr/bin/env python3
"""Token use per agent (operator 08:55, from Nick): python3 tools/stream/test_tokens.py

1. tokens.py reads each CLI's own session logs, placed by the agent's workspace (runs/RUN/AGENT): Claude Code (a
   message's usage once however many content blocks repeat it, no synthetic replies, compact_boundary, subagent
   files), Codex (session_meta cwd, forked subagents, one token_usage_record per response, compacted), Grok (the
   workspace's own unified.jsonl, compactions from its session's updates.jsonl), agy (a conversation belongs to the
   run its opening names most; one more conversation each fresh start), Muse (cwd in the head, subagent files, the
   summarizer's tokens on a compaction); other workspaces' and other runs' files count nothing.
2. Files are read on from where the last read stopped: an appended record counts once, a half-written line waits for
   its newline, a young agy conversation is placed once it names its run, a replaced (shorter) file is counted again
   from its start.
3. load(): the shift's numbers cached as runs/RUN/tokens.json; an ended shift's cache is used while its files are
   unchanged, a live one's is recounted; a cache whose files are gone stays.
4. TokenFeed: game actions from the journals (not reads, not talk), rows most tokens first; brief() leaves out the
   per-minute series.
5. The stream: the "tokens" card is due 15 minutes after the start, then every 30 minutes, at a free slot; unavailable
   while nothing is counted; its facts (all agents, cached %, turns, per game action, the team's total); the hosts'
   neutral call; the model hands the cards their figure; the overlay draws both.
"""
import datetime, json, os, sys, tempfile, time
from urllib.parse import quote

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import caster  # noqa: E402
import model  # noqa: E402
import tokens  # noqa: E402
from segments import Segments  # noqa: E402

START = datetime.datetime(2026, 10, 14, 3, 30).timestamp()  # local time, as the CLIs' date folders


def iso(t):
    return datetime.datetime.fromtimestamp(t, datetime.timezone.utc).isoformat().replace("+00:00", "Z")


def write(path, lines, mode="w"):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, mode) as f:
        for x in lines:
            f.write((x if isinstance(x, str) else json.dumps(x, separators=(",", ":"))) + "\n")


def day(t=START):
    return datetime.date.fromtimestamp(t).strftime("%Y/%m/%d")


class World:
    """A run folder and one home per CLI, under a temporary directory."""

    def __init__(self, tmp, run="shift20"):
        self.tmp = os.path.realpath(tmp)
        self.run_dir = os.path.join(self.tmp, "runs", run)
        self.run = run
        self.homes = {k: os.path.join(self.tmp, "home", k) for k in ("claude", "codex", "grok", "agy", "muse")}
        for h in self.homes.values():
            os.makedirs(h, exist_ok=True)
        os.makedirs(self.run_dir, exist_ok=True)
        with open(os.path.join(self.run_dir, "team.txt"), "w") as f:
            f.write("opus|Claude Opus 5.5 (Claude Code)\nastra|GPT-6 Astra (Codex)\ngrok|Grok 4.7 (Grok Build)\n"
                    "gemini|Gemini 3.8 Flash (Antigravity)\nmuse|Muse Spark 1.3 (Muse Code)\n")
        with open(os.path.join(self.run_dir, "stream.json"), "w") as f:
            json.dump({"shift": {"start": START, "end": START + 4 * 3600}, "agents": {}}, f)
        os.environ["POG_TOKEN_ROOTS"] = json.dumps({k: [v] for k, v in self.homes.items()})
        tokens._roots = None
        tokens._placed.clear()

    def ws(self, agent, run=None):
        return os.path.join(self.tmp, "runs", run or self.run, agent)

    def claude_dir(self, agent, run=None):
        import re
        return os.path.join(self.homes["claude"], "projects", re.sub(r"[^A-Za-z0-9]", "-", self.ws(agent, run)))


def claude_msg(mid, t, inp, cw, cr, out, think=0, model_name="claude-opus-5-5"):
    return {"type": "assistant", "timestamp": iso(t), "message": {"id": mid, "model": model_name, "usage": {
        "input_tokens": inp, "cache_creation_input_tokens": cw, "cache_read_input_tokens": cr, "output_tokens": out,
        "output_tokens_details": {"thinking_tokens": think}}}}


def codex_meta(cwd, forked=False):
    p = {"id": "s1", "cwd": cwd}
    if forked:
        p["forked_from_id"] = "s0"
    return {"timestamp": iso(START), "type": "session_meta", "payload": p}


def codex_rec(rid, t, inp, cached, out, reasoning=0):
    return {"timestamp": iso(t), "type": "token_usage_record", "payload": {"response_id": rid, "usage": {
        "input_tokens": inp, "cached_input_tokens": cached, "cache_write_input_tokens": 0, "output_tokens": out,
        "reasoning_output_tokens": reasoning, "total_tokens": inp + out}}}


def build(w):
    """Every CLI's files for the run (and some for others)."""
    t = START + 600
    # Claude Code: opus, one message on two content-block lines, a synthetic reply, a compaction, a subagent file
    d = w.claude_dir("opus")
    write(os.path.join(d, "sid.jsonl"), [
        {"type": "user", "timestamp": iso(t)},
        claude_msg("m1", t, 2, 100, 1000, 50, 10), claude_msg("m1", t, 2, 100, 1000, 50, 10),
        claude_msg("m2", t + 90, 3, 0, 1200, 20),
        claude_msg("m3", t + 95, 0, 0, 0, 0, model_name="<synthetic>"),
        {"type": "system", "subtype": "compact_boundary", "timestamp": iso(t + 100), "compactMetadata": {"preTokens": 1300}},
    ])
    write(os.path.join(d, "sid", "subagents", "agent-1.jsonl"), [claude_msg("s1", t + 30, 5, 0, 0, 5)])
    write(os.path.join(w.claude_dir("opus", "shift19"), "old.jsonl"), [claude_msg("x", t, 999, 0, 0, 999)])
    # Codex: astra's rollout and a forked subagent; a duplicate record; a compaction; another workspace's rollout
    cd = os.path.join(w.homes["codex"], "sessions", day())
    write(os.path.join(cd, "rollout-a.jsonl"), [
        codex_meta(w.ws("astra")), codex_rec("r1", t, 1000, 800, 40, 10), codex_rec("r1", t, 1000, 800, 40, 10),
        {"timestamp": iso(t + 60), "type": "compacted", "payload": {"replacement_history": []}},
        codex_rec("r2", t + 120, 500, 0, 10)])
    write(os.path.join(cd, "rollout-b.jsonl"), [codex_meta(w.ws("astra"), forked=True), codex_rec("r3", t + 30, 200, 100, 5)])
    write(os.path.join(cd, "rollout-c.jsonl"), [codex_meta(w.ws("astra", "shift19")), codex_rec("r9", t, 7777, 0, 7)])
    # Grok: the workspace's own home log; its session's compactions
    write(os.path.join(w.ws("grok"), ".grok-home", "logs", "unified.jsonl"), [
        {"ts": iso(t), "msg": "shell.turn.inference_start"},
        {"ts": iso(t), "msg": "shell.turn.inference_done", "ctx": {"prompt_tokens": 3000, "cached_prompt_tokens": 2500,
                                                                  "completion_tokens": 30, "reasoning_tokens": 8}},
        {"ts": iso(t + 60), "msg": "shell.turn.inference_done", "ctx": {"prompt_tokens": 3100, "cached_prompt_tokens": 3000,
                                                                       "completion_tokens": 20, "reasoning_tokens": 0}}])
    write(os.path.join(w.homes["grok"], "sessions", quote(w.ws("grok"), safe=""), "g1", "updates.jsonl"), [
        {"timestamp": t + 30, "method": "_x.ai/session/update", "params": {"update": {"sessionUpdate": "auto_compact_completed",
                                                                                      "tokens_before": 150000}}},
        {"timestamp": t + 31, "method": "_x.ai/session/update", "params": {"update": {"sessionUpdate": "agent_message_chunk"}}}])
    # agy: two conversations of this run (one fresh start), one of another run, one written long before the shift
    for conv, run, rows in (("c1", w.run, [(100, 900, 10)]), ("c2", w.run, [(50, 1000, 5), (60, 1100, 6)]),
                            ("c3", "shift19", [(9999, 0, 9)]), ("c4", w.run, [(4444, 0, 4)])):
        p = os.path.join(w.homes["agy"], "brain", conv, ".system_generated", "logs", "transcript.jsonl")
        opening = {"type": "SYSTEM_MESSAGE", "text": f"workspace {w.ws('gemini', run)}; runs/{run}/gemini/notes.md; "
                                                    f"runs/shift19/gemini/notes.md read once" if run == w.run else
                   f"workspace {w.ws('gemini', run)} runs/{run}/gemini"}
        write(p, [opening] + [{"type": "PLANNER_RESPONSE", "source": "MODEL", "created_at": iso(t + i * 60),
                               "input_tokens": a, "cache_read_tokens": b, "output_tokens": c}
                              for i, (a, b, c) in enumerate(rows)])
        if conv == "c4":
            os.utime(p, (START - 3 * 86400, START - 3 * 86400))
    # Muse: the session (cwd on its third line), a subagent, a compaction with the summarizer's tokens
    md = os.path.join(w.homes["muse"], "sessions", day(), "m1")
    write(os.path.join(md, "session.jsonl"), [
        {"sequence": 1, "payload_type": "runtime.session"}, {"sequence": 2},
        {"sequence": 3, "payload": {"kind": "route_facts", "cwd": w.ws("muse")}},
        {"sequence": 4, "recorded_at": int(t * 1e6), "payload": {"kind": "run", "event": {"kind": "model_completed", "usage": {
            "input_tokens": 4000, "output_tokens": 40, "cached_tokens": 3000, "cache_write_tokens": 0,
            "cache_read_tokens": 3000, "reasoning_tokens": 4}}}},
        {"sequence": 5, "recorded_at": int((t + 60) * 1e6), "payload": {"kind": "run", "event": {
            "kind": "context_compaction_installed", "summarizer_usage": {"input_tokens": 2000, "output_tokens": 100}}}}])
    write(os.path.join(md, "subagent", "x", "session.jsonl"), [
        {"sequence": 1, "recorded_at": int((t + 65) * 1e6), "payload": {"kind": "run", "event": {"kind": "model_completed",
                                                                                               "usage": {"input_tokens": 300, "output_tokens": 3}}}}])
    # the journals: a game action, a read, talk, a bare research (a read), a reply
    for a in ("opus", "astra", "grok", "gemini", "muse"):
        write(os.path.join(w.ws(a), "journal.jsonl"), [
            {"at": iso(t), "event": "request", "request": {"id": "1", "action": "build", "args": {}}},
            {"at": iso(t), "event": "response", "response": {"id": "1", "ok": True, "result": {"note": '"event":"request"'}}},
            {"at": iso(t), "event": "request", "request": {"id": "2", "action": "observe", "args": {}}},
            {"at": iso(t), "event": "request", "request": {"id": "3", "action": "say", "args": {"text": "hi"}}},
            {"at": iso(t), "event": "request", "request": {"id": "4", "action": "research", "args": {}}},
            {"at": iso(t), "event": "request", "request": {"id": "5", "action": "research", "args": {"technology": "x"}}}])


def check_parsers(tmp):
    w = World(tmp)
    build(w)
    s = tokens.Shift(w.run_dir)
    s.poll()
    st = s.stats()
    o = st["opus"]
    # m1 once (2+100+1000 in, 50 out), m2, the subagent's call; the synthetic reply is none; one compaction
    assert (o["input"], o["output"], o["cache_read"], o["cache_write"], o["calls"]) == (1102 + 1203 + 5, 75, 2200, 100, 3), o
    assert o["reasoning"] == 10 and o["compactions"] == 1 and o["context_max"] == 1203 and o["context"] == 1203, o
    assert o["conversations"] is None and o["total"] == o["input"] + o["output"]
    a = st["astra"]
    assert (a["input"], a["output"], a["cache_read"], a["calls"], a["compactions"], a["reasoning"]) == (1700, 55, 900, 3, 1, 10), a
    g = st["grok"]
    assert (g["input"], g["cache_read"], g["output"], g["reasoning"], g["calls"], g["compactions"]) == (6100, 5500, 50, 8, 2, 1), g
    gm = st["gemini"]
    # c1 and c2 (two conversations: one fresh start), not c3 (shift19's) nor c4 (written days before the shift)
    assert (gm["input"], gm["cache_read"], gm["output"], gm["calls"], gm["conversations"]) == (3210, 3000, 21, 3, 2), gm
    m = st["muse"]
    # the call, the subagent's, and the summarizer's tokens (not a turn); one compaction
    assert (m["input"], m["output"], m["cache_read"], m["calls"], m["compactions"]) == (6300, 143, 3000, 2, 1), m
    assert m["context_max"] == 4000 and len(m["context_minutes"]) == 2, m
    files = s.sources()
    assert not any("shift19" in p or "rollout-c" in p or "/c3/" in p or "/c4/" in p for p in files), files
    return w


def check_incremental(tmp):
    w = World(tmp)
    build(w)
    s = tokens.Shift(w.run_dir)
    s.poll()
    before = s.stats()["astra"]["total"]
    rollout = os.path.join(w.homes["codex"], "sessions", day(), "rollout-a.jsonl")
    line = json.dumps(codex_rec("r4", START + 900, 100, 0, 1), separators=(",", ":"))
    with open(rollout, "a") as f:
        f.write(line[:30])  # half a record: not counted until its newline
    s.poll()
    assert s.stats()["astra"]["total"] == before
    with open(rollout, "a") as f:
        f.write(line[30:] + "\n")
    s.poll()
    s.poll()
    assert s.stats()["astra"]["total"] == before + 101 and s.stats()["astra"]["calls"] == 4
    # a young agy conversation that names its run only with its first reply: found on the poll after
    young = os.path.join(w.homes["agy"], "brain", "c5", ".system_generated", "logs", "transcript.jsonl")
    write(young, [{"type": "SYSTEM_MESSAGE", "text": "starting"}])
    s.poll()
    assert s.stats()["gemini"]["conversations"] == 2
    write(young, [{"type": "PLANNER_RESPONSE", "source": "MODEL", "created_at": iso(START + 1200), "input_tokens": 7,
                   "cache_read_tokens": 0, "output_tokens": 1, "tool_calls": [{"cwd": w.ws("gemini")}]}], mode="a")
    s.poll()
    gm = s.stats()["gemini"]
    assert gm["conversations"] == 3 and gm["input"] == 3210 + 7, gm
    # a replaced (shorter) file: counted again from its start, its old numbers dropped
    write(rollout, [codex_meta(w.ws("astra")), codex_rec("r1", START + 600, 10, 0, 1)])
    s.poll()
    a = s.stats()["astra"]
    assert a["total"] == 11 + 205 and a["calls"] == 2, a  # the new file, and the forked subagent's 205


def check_load(tmp):
    w = World(tmp)
    build(w)
    c = tokens.load(w.run_dir, final=True)
    path = os.path.join(w.run_dir, tokens.FILE)
    assert os.path.exists(path) and c["final"] and c["agents"]["opus"]["calls"] == 3
    # an ended shift's cache is used while its files are unchanged (no new search)
    stamp = os.path.getmtime(path)
    time.sleep(0.01)
    assert tokens.load(w.run_dir, final=True)["agents"]["opus"]["calls"] == 3 and os.path.getmtime(path) == stamp
    # a file grew: counted again
    write(os.path.join(w.claude_dir("opus"), "sid.jsonl"), [claude_msg("m9", START + 2000, 1, 0, 0, 1)], mode="a")
    assert tokens.load(w.run_dir, final=True)["agents"]["opus"]["calls"] == 4
    # the CLIs pruned every file: the cache stays
    import shutil
    for h in w.homes.values():
        shutil.rmtree(h)
    shutil.rmtree(os.path.join(w.ws("grok"), ".grok-home"))
    c2 = tokens.load(w.run_dir, final=False)
    assert c2["agents"]["opus"]["calls"] == 4 and c2["sources"], c2["agents"]["opus"]
    # a live shift's cache is counted again, but one that finds no file at all keeps the cache
    c2["final"] = False
    with open(path, "w") as f:
        json.dump(c2, f)
    assert tokens.load(w.run_dir, final=False)["agents"]["opus"]["calls"] == 4


def check_feed(tmp):
    w = World(tmp)
    build(w)
    f = tokens.TokenFeed(w.run_dir, every=3600)
    assert f.snapshot() is None
    snap = f.poll(pause=0)
    rows = snap["rows"]
    assert [r["total"] for r in rows] == sorted((r["total"] for r in rows), reverse=True)
    assert all(r["actions"] == 2 for r in rows), rows  # build and research with a technology
    b = tokens.brief(snap)
    assert set(b["rows"][0]) == set(tokens.ROW_KEYS) and "context_minutes" not in b["rows"][0]
    # the journal grows: one more action, read once
    write(os.path.join(w.ws("opus"), "journal.jsonl"),
          [{"at": iso(START + 700), "event": "request", "request": {"id": "6", "action": "transfer", "args": {}}}], mode="a")
    f.poll(pause=0)
    f.poll(pause=0)
    assert next(r for r in f.snapshot()["rows"] if r["name"] == "opus")["actions"] == 3
    assert tokens.short(42_891_228) == "42.9M" and tokens.short(142_891_228) == "143M" and tokens.short(1_234_567_890) == "1.2B"
    assert tokens.short(45_600) == "45.6K" and tokens.short(950) == "950" and tokens.short(None) == "0"
    assert tokens.card_line(rows, 2).startswith("Tokens this shift: 1. ")


def snap_with(rows, now):
    return {"agents": [{"name": "gemini", "display_name": "Gemini", "alive": True, "position": {"x": 0, "y": 0}},
                       {"name": "grok", "display_name": "Grok", "alive": True, "position": {"x": 1, "y": 0}}],
            "tokens": {"rows": rows, "since": now - 1800, "t": now} if rows is not None else None}


def row(name, total, cache_read, calls, actions):
    return {"name": name, "total": total, "input": total - 100, "cache_read": cache_read, "output": 100,
            "calls": calls, "actions": actions}


def check_segment():
    now = 10_000.0
    seg = Segments(recap_every=10**9, lull_after=10**9, hauling_every=10**9)
    seg.last_recap = seg.last_end = now - 100
    seg.last_start = now - 1000
    seg.last_tokens = now - 900  # as at the service start: the first card 15 minutes in
    rows = [row("gemini", 41_400_100, 39_000_000, 468, 56), row("grok", 12_300_100, 11_900_000, 124, 0)]
    snap = snap_with(rows, now)
    seg.step(snap, now)
    assert seg.public() is None  # not due yet
    # unavailable while nothing is counted; the next one is due 30 minutes on
    seg.step(snap_with([row("grok", 0, 0, 0, 0)], now + 900), now + 900)
    assert seg.public() is None and seg.queue is None and seg.last_tokens == now + 900
    code, reply = seg.request({"type": "tokens"}, now + 901)
    assert code == 409 and reply["why"] == "no tokens counted this shift yet", reply
    t = now + 900 + 1800
    seg.step(snap, t)
    assert seg.queue and seg.queue["type"] == "tokens"
    out = seg.step(snap, t + 1)
    assert out and out["type"] == "tokens" and out["by"] == "director" and out["title"] == "Tokens this shift", out
    f = out["facts"]
    assert f["rows"][0] == {"rank": 1, "agent": "Gemini", "tokens": 41_400_100, "cached_pct": 94, "output": 100,
                            "turns": 468, "per_action": 739_288}, f["rows"][0]
    assert f["rows"][1]["per_action"] is None and f["team_tokens"] == 53_700_200 and f["team_text"] == "53.7M", f
    assert f["line"] == "Tokens this shift: 1. Gemini 41.4M, 2. Grok 12.3M" and f["minutes"] == 30, f
    assert seg.last_tokens == t
    called = caster.card_facts(dict(out, started=t, ends=t + 15))
    assert called["on_screen_now"]["line"] == f["line"] and "no verdict" in called["how_to_call_it"], called
    # a fresh director's first token card comes 15 minutes in, between its hauling cards
    s2 = Segments()
    assert abs((time.time() - s2.last_tokens) - 900) < 5 and abs(time.time() - s2.last_hauling) < 5


def check_model():
    m = model.Model({"agents": {"grok": {}, "gemini": {}}})
    m.ingest({"agents": [{"name": "grok", "alive": True}, {"name": "gemini", "alive": True}]})
    feed = {"t": 5, "since": 1, "rows": [dict(row("grok", 5000, 4000, 3, 1), context_minutes=[[60, 10]])]}
    m.set_tokens(feed)
    snap = m.snapshot(time.time())
    assert snap["tokens"]["rows"][0]["total"] == 5000 and "context_minutes" not in snap["tokens"]["rows"][0]
    by = {a["name"]: a for a in snap["agents"]}
    assert by["grok"]["tokens"] == 5000 and by["gemini"]["tokens"] is None
    m.set_tokens(feed)  # the same result again: kept as it was
    assert m.snapshot(time.time())["tokens"]["rows"][0]["total"] == 5000


def check_overlay():
    js = open(os.path.join(HERE, "static", "overlay.js")).read()
    assert 'seg.type === "tokens"' in js and 'shortNum(a.tokens) + " tok"' in js and '"per action"' in js
    css = open(os.path.join(HERE, "static", "overlay.css")).read()
    assert ".card .tok" in css and "seg-tokens" in css


def main():
    saved = os.environ.get("POG_TOKEN_ROOTS")
    try:
        for check in (check_parsers, check_incremental, check_load, check_feed):
            with tempfile.TemporaryDirectory() as tmp:
                check(tmp)
    finally:
        if saved is None:
            os.environ.pop("POG_TOKEN_ROOTS", None)
        else:
            os.environ["POG_TOKEN_ROOTS"] = saved
        tokens._roots = None
    check_segment()
    check_model()
    check_overlay()
    print("tokens: ok (five CLIs' logs by workspace, read on from where they stopped, the shift cache, the feed's game "
          "actions, the 30-min card, the cards' figure)")


if __name__ == "__main__":
    main()
