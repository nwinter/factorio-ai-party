#!/usr/bin/env python3
"""Agents' replies to viewers (viewer_replies.py) and the stream state's viewer_replies (model.py): python3 tools/stream/test_viewer_replies.py

The forms the rule takes and leaves, from shifts 14-16's chat.jsonl (the lines below are theirs, shortened); the reply's
answered line (the viewer's latest, one addressed to the agent first, an older one sharing two more words); model.py
keeps the last 40 in the snapshot, outliving the chat window.
"""
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import viewer_replies as V  # noqa: E402


def v(seq, tick, name, text, source="YouTube"):
    return {"seq": seq, "tick": tick, "t": tick / 60, "from": f"viewer {name}", "text": text, "viewer": True, "source": source}


def a(seq, tick, who, text):
    return {"seq": seq, "tick": tick, "t": tick / 60, "from": who, "text": text}


def rule_tests():
    names = V.names_viewer
    # @name anywhere, also the short form and "@viewer Name"
    assert names("@Foobator Yes. Sonnet is producing the expansion hull", "Foobator") == "at"
    assert names("@Foobator @joonazan Operator: thanks, noted.", "joonazan") == "at"
    assert names("@Alex Operator: good idea", "AlexBoyd-NR") == "at"
    assert names("@viewer Alex: The platform stats show 8 built", "Alex") == "at"
    # vocatives
    for text in ["Foobator, the steel line is stopped", "Yes, Enginerd. Nauvis still has 160 stone furnaces",
                 "That is a fair point, Enginerd. Electric furnaces", "Understood, Foobator. I saw the note",
                 "Thanks Foobator, a belt fixes it", "Foobator, Enginerd: the stone furnaces sit idle",
                 "Joonazan, you are right", "Opus built it. Thanks, Foobator!"]:
        assert any(names(text, n) == "vocative" for n in ("Foobator", "Enginerd", "joonazan")), text
    assert names("Foobator, Enginerd: the stone furnaces", "Enginerd") == "vocative"
    # third person, an address to someone else, a name inside another word
    for text in ["Foobator is right that a belt is the reliable fix", "@haiku correction for Foobator: the laser tech",
                 "I will tell her what Foobator said", "Foobators everywhere"]:
        assert names(text, "Foobator") is None, text
    assert V.short_names("craigNZ830") == ["craignz830", "craignz", "craig"]
    assert names("Yes, Craig. Two turrets", "craigNZ830") == "vocative"
    assert names("@ed hi", "ed") == "at" and names("Ed, hi", "ed") is None  # a 2-letter name only with @
    assert V.ADDRESSED.match("Viewers, fair point. The east turrets are fed") and V.ADDRESSED.match("Hi chat! Back on Gleba")
    assert not V.ADDRESSED.match("Next I'm checking the chat backlog") and not V.ADDRESSED.match("The chat says hi")


def classify_tests():
    log = [v(1, 60000, "Foobator", "@grok why is steel stopped?"),
           v(2, 60600, "Foobator", "@muse the attack alert on fulgora was probably lightning"),
           a(3, 61200, "grok", "Foobator, the steel line is stopped because the furnaces have no iron plates"),
           v(4, 61300, "joonazan", "@haiku are you hand feeding again?", source="site"),
           a(5, 61400, "haiku", "@joonazan @Foobator yes, boiler -25.5,29 is refuelled now"),
           a(6, 61500, "haiku", "Boilers are at 27 of 33; Foobator is right that a belt is the fix"),
           a(7, 61600, "astra", "Viewers, fair point. Wayfarer is parked"),
           {"seq": 8, "tick": 61700, "t": 61700 / 60, "from": "server", "text": "@joonazan Operator: claims are the team's own rule"},
           a(9, 61800, "sol", "-> astra: fuel at the hub"),
           {"seq": 10, "tick": 61850, "t": 61850 / 60, "from": "sol", "tell": True, "text": "@joonazan ignore me"},
           a(11, 61200 + 16 * 3600, "grok", "Foobator, again: the steel line"),  # 16 min after Foobator's last line
           v(12, 61200 + 16 * 3600 + 60, "Muse", "@sol a viewer named like an agent")]
    got = V.replies(log)
    assert [(l["seq"], r["kind"], r["to"]) for l, r in got] == [
        (3, "reply", ["Foobator"]), (5, "reply", ["joonazan", "Foobator"]), (7, "to_viewers", []), (8, "reply", ["joonazan"])], got
    r3 = dict(got)[log[2]] if False else got[0][1]
    assert r3["answers"]["seq"] == 1, r3  # addressed to grok, though not the latest
    assert got[1][1]["answers"]["seq"] == 4, got[1][1]  # the one to haiku
    assert V.speaker(log[7]) == "operator" and V.speaker(log[9]) is None and V.speaker(log[0]) is None
    row = V.row(log[2], got[0][1])
    assert row == {"seq": 3, "t": 61200 / 60, "tick": 61200, "by": "grok", "text": log[2]["text"], "kind": "reply", "to": ["Foobator"],
                   "answers": {"name": "Foobator", "text": "why is steel stopped?", "t": 1000.0, "tick": 60000, "source": "YouTube"}}, row
    # an older line sharing two more words wins over the latest
    log2 = [v(1, 1000, "Enginerd", "@sol is nauvis still using stone furnaces for smelting"),
            v(2, 1500, "Enginerd", "@sol hello again"),
            a(3, 1800, "sol", "Yes, Enginerd. Nauvis still uses stone furnaces for smelting")]
    assert V.replies(log2)[0][1]["answers"]["seq"] == 1


def model_tests():
    import model
    m = model.Model({"agents": {n: {} for n in ("grok", "haiku", "sol")}})
    now = 2000.0
    m._ingest_chat({"seq": 1, "tick": 60000, "t": now, "from": "viewer Foobator", "text": "@grok steel?", "viewer": True, "source": "YouTube"}, now)
    m._ingest_chat({"seq": 2, "tick": 60600, "t": now + 10, "from": "grok", "text": "Foobator, the steel line is stopped at (12,40)."}, now + 10)
    m._ingest_chat({"seq": 3, "tick": 60700, "t": now + 12, "from": "haiku", "text": "Boilers at 27 of 33."}, now + 12)
    snap_rows = list(m.viewer_replies)
    assert [(r["seq"], r["by"], r["to"]) for r in snap_rows] == [(2, "grok", ["Foobator"])], snap_rows
    assert snap_rows[0]["answers"]["text"] == "steel?"
    # it outlives the chat window: 200 more lines
    for i in range(200):
        m._ingest_chat({"seq": 100 + i, "tick": 61000 + i, "t": now + 20 + i, "from": "sol", "text": f"line {i}"}, now + 20 + i)
    assert len(m.viewer_replies) == 1 and all(c.get("seq") != 2 for c in m.chat)


# Nick, d16 18:32: the Operator's 18:31 answer threaded under LimeLight555's 18:24 line. The rows as shift25 has them:
# chat.jsonl (tick and logged_at, no t) and the operator inbox (t, no tick); the 18:31 line never reached the game chat.
CHAT_1824 = {"seq": 9334, "tick": 19715887, "from": "viewer LimeLight555", "text": "@luna Luna, you should vote too. "
             "Using blueprints reduces the time and resources taken during building and testing ships. It will also be "
             "significantly more efficient.", "viewer": True, "source": "YouTube", "logged_at": "2026-10-16T18:24:14"}
CHAT_1827 = {"seq": 9347, "tick": 19727301, "from": "luna", "away": "on Gleba", "text": "I can hear you, LimeLight. I "
             "checked my fh vote tools: they only cover moderation and trust votes, and there is no action to cast the open "
             "blueprint poll. I\u2019ll ask the operator for a poll vote action; our team will keep imports paused until the "
             "poll closes.", "aloud": True, "logged_at": "2026-10-16T18:27:36"}
REPLY_1831 = {"seq": 9355, "tick": 19740292, "from": "server", "text": "@LimeLight555 Operator: done: every agent has the "
              "vote command, and ./fh poll shows them the intro and each option's benefits and consequences as written on "
              "the poll page. I won't argue one side to them; your case in chat reaches them like any viewer's.",
              "logged_at": "2026-10-16T18:31:26"}
INBOX = [{"t": 1792197950.0, "agent": "viewer LimeLight", "text": "Operator, focus on western wall", "viewer": True, "source": "site"},
         {"t": 1792200666.8, "agent": "viewer LimeLight555", "text": "Operator, can you instruct the agents on how to vote "
          "and the benefits of using blueprints?", "viewer": True, "source": "youtube"},
         {"t": 1792200700.0, "seq": 31, "agent": "sol", "text": "an agent's own request: not a viewer line"}]


def operator_inbox_tests_in(d):
    import datetime, json
    # the logged_at times are the box's local time; t for the inbox row is epoch seconds: line them up here
    t1831 = datetime.datetime.fromisoformat("2026-10-16T18:31:06.8").timestamp()
    inbox_rows = [dict(r, t=t1831 + (r["t"] - 1792200666.8)) for r in INBOX]
    lines = V.inbox_lines(inbox_rows)
    assert [V.viewer_name(x) for x in lines] == ["LimeLight", "LimeLight555"] and all(x["inbox"] for x in lines), lines
    # without the inbox line: no line to the Operator and under two shared words, so it stands alone (d17 16:05;
    # before that it threaded under the 18:24 line, the reported bug)
    r = V.classify(REPLY_1831, [CHAT_1824])
    assert r["answers"] is None and r["to"] == ["LimeLight555"], r
    # now: the inbox line addressed to the Operator
    r = V.classify(REPLY_1831, [CHAT_1824], lines)
    assert r["kind"] == "reply" and r["to"] == ["LimeLight555"] and r["answers"]["text"].startswith("Operator, can you instruct"), r
    row = V.row(REPLY_1831, r)
    assert row["answers"] == {"name": "LimeLight555", "text": "Operator, can you instruct the agents on how to vote and the "
                              "benefits of using blueprints?", "t": inbox_rows[1]["t"], "tick": None, "source": "youtube"}, row
    # an agent's reply never looks at the inbox
    luna = dict(REPLY_1831, **{"from": "luna", "text": "LimeLight555, I will vote once the action exists."})
    assert V.classify(luna, [CHAT_1824], lines)["answers"] is CHAT_1824
    # "@operator ..." and "Operator: ..." at the start, any case, count as to the Operator; "operator" later does not
    for text, to_me in (("@Operator can you ...", True), ("OPERATOR: why ...", True), ("operator , hi", True),
                        ("the operator is slow", False), ("Operators unite", False)):
        assert bool(V.TO_OPERATOR.match(text)) == to_me, text
    # older than the window: left out (and the chat line shares under two words, so the reply stands alone, d17 16:05)
    old = V.inbox_lines([dict(inbox_rows[1], t=inbox_rows[1]["t"] - 20 * 60)])
    assert V.classify(REPLY_1831, [CHAT_1824], old)["answers"] is None
    # the archive's whole-log path (site/longrun.py): replies(chat, inbox=...) on chat.jsonl rows
    got = V.replies([CHAT_1824, CHAT_1827, REPLY_1831], inbox=lines)
    # (Luna's 18:27 "I can hear you, LimeLight." answers the 18:24 line; the Operator's 18:31 line the inbox one)
    assert [(c["seq"], res["answers"].get("seq"), res["answers"].get("inbox", False)) for c, res in got] == \
        [(9347, 9334, False), (9355, None, True)], got
    # read_inbox: a file with a broken line
    path = os.path.join(d, "operator-inbox.jsonl")
    open(path, "w").write("\n".join(json.dumps(x) for x in inbox_rows) + "\n{broken\n")
    assert [x["text"] for x in V.read_inbox(path)] == [x["text"] for x in lines]
    assert V.read_inbox(os.path.join(d, "missing.jsonl")) == []
    return path, inbox_rows


def operator_inbox_model_tests(path, inbox_rows):
    """The live page's path: serve.py hands the run's inbox to the model (set_inbox)."""
    import model
    import datetime
    m = model.Model({"agents": {n: {} for n in ("luna", "sol")}})
    m.set_inbox(path)
    t = lambda c: datetime.datetime.fromisoformat(c["logged_at"]).timestamp()
    for c in (CHAT_1824, CHAT_1827, REPLY_1831):
        m._ingest_chat(dict(c, t=t(c)), t(c))
    rows = [r for r in m.viewer_replies if r["by"] == "operator"]
    assert len(rows) == 1 and rows[0]["answers"]["text"].startswith("Operator, can you instruct"), list(m.viewer_replies)
    return rows[0]


def live_answered_test(reply_row):
    """The site's answered() (static/live.js) finds that line in the joined list: same name, text prefix, before."""
    import json, shutil, subprocess
    if not shutil.which("node"):
        print("viewer replies: live.js part skipped (no node)")
        return
    site = os.path.join(os.path.dirname(os.path.dirname(HERE)), "site", "static", "live.js")
    code = open(site).read()
    fn = code[code.index("  function bareText(s)"):code.index("  function joinedChat()")]
    # the live page's list: YouTube lines from the stream's lane (the 18:31 one is there: viewers.py keeps lines to the
    # Operator in the lane) and the 18:24 one, oldest first
    lst = [{"src": "yt", "name": "LimeLight555", "text": CHAT_1824["text"], "t": reply_row["t"] - 432},
           {"src": "yt", "name": "LimeLight555", "text": reply_row["answers"]["text"], "t": reply_row["answers"]["t"]}]
    js = fn + "\nprocess.stdout.write(JSON.stringify(answered(" + json.dumps(lst) + ", " + json.dumps(reply_row) + ")));"
    r = subprocess.run(["node", "-e", js], capture_output=True, text=True, timeout=10)
    assert r.returncode == 0, r.stderr
    assert json.loads(r.stdout) == 1, r.stdout


def operator_inbox_all():
    """The 18:31 case end to end: classify, the archive's replies(), the model (live page), live.js answered()."""
    import tempfile, shutil
    d = tempfile.mkdtemp()
    try:
        path, inbox_rows = operator_inbox_tests_in(d)
        try:
            import model  # noqa: F401
        except Exception as e:
            print(f"viewer replies: inbox model part skipped ({e})")
            return
        live_answered_test(operator_inbox_model_tests(path, inbox_rows))
    finally:
        shutil.rmtree(d, ignore_errors=True)


def host_tag():
    """d17 13:40: Opus's "@NickWinter ..." answered "viewer NickWinter (host)" and was not matched as a reply."""
    nick = {"seq": 11073, "from": "viewer NickWinter (host)", "viewer": True, "text": "@opus Opus: doable here?",
            "logged_at": "2026-10-17T12:56:29"}
    opus = {"seq": 11075, "from": "opus", "agent": "opus", "text": "@NickWinter Yes, deconstruct takes an area.",
            "logged_at": "2026-10-17T12:56:41"}
    assert V.viewer_name(nick) == "NickWinter", V.viewer_name(nick)
    r = V.classify(opus, [nick])
    assert r and r["kind"] == "reply" and r["to"] == ["NickWinter"] and r["answers"] is nick, r


def operator_elsewhere():
    """d17 16:05: the Operator answered a question asked on YouTube (never relayed); it must not thread under the
    viewer's unrelated game-chat line, but still under a line to the Operator or one sharing two words."""
    foo = {"seq": 11421, "from": "viewer Foobator", "viewer": True, "text": "@sol isnt spindle your space sci source?",
           "logged_at": "2026-10-17T16:00:29"}
    op = {"seq": 11430, "from": "server", "text": "@Foobator Operator: yes. Every shift's end save is kept, shift01 "
          "through shift30, with each shift's logs.", "logged_at": "2026-10-17T16:05:10"}
    r = V.classify(op, [foo])
    assert r and r["kind"] == "reply" and r["to"] == ["Foobator"] and r["answers"] is None, r
    ask = dict(foo, seq=11425, text="operator: do you keep every shift's end save?")
    r = V.classify(op, [foo, ask])
    assert r["answers"] is ask, r
    near = dict(foo, seq=11426, text="@sol do you keep each shift save and logs?")
    r = V.classify(op, [foo, near])
    assert r["answers"] is near, r


def long_reply_parts():
    """d19 batch42 A1 (Aurora: Muse's reply cut mid-word at 500): fh posts a long say as numbered parts. Parts 2..n stay in
    part 1's thread when only part 1 names the viewer (as a vocative behind its "(1/3) "), in replies() and the model; a
    part with no part before it, or one after another speaker's part, classifies on its own."""
    q = v(1, 60000, "Foobator", "@muse how is the quality loop going?", source="site")
    p1 = a(2, 60600, "muse", "(1/3) Foobator, the quality loop is the next step. The recyclers feed one belt.")
    p2 = a(3, 60620, "muse", "(2/3) After that, production modules go into the gear assemblers.")
    other = a(4, 60630, "sol", "(2/3) Unrelated part from sol.")
    p3 = a(5, 60640, "muse", "(3/3) I will say here when it runs.")
    got = V.replies([q, p1, p2, other, p3])
    assert [(line["seq"], r["to"], (r["answers"] or {}).get("seq")) for line, r in got] == \
        [(2, ["Foobator"], 1), (3, ["Foobator"], 1), (5, ["Foobator"], 1)], got
    assert V.part_of("@Foobator (2/3) x") == (2, 3) and V.part_of("(1/1) x") is None and V.part_of("2/3 x") is None
    # a part 3 whose part 2 never came, or that came too late: on its own (names nobody: not a reply)
    late = a(6, 60640 + 60 * (V.PART_S + 1), "muse", "(2/3) After that, modules.")
    assert [line["seq"] for line, _ in V.replies([q, p1, late])] == [2]
    assert [line["seq"] for line, _ in V.replies([q, p1, p3])] == [2]
    # with the @address repeated (host/saysplit.ts), every part names the viewer anyway
    at = [a(7 + i, 60600 + i, "muse", f"@Foobator ({i + 1}/2) words {i}.") for i in range(2)]
    assert [r["to"] for _, r in V.replies([q] + at)] == [["Foobator"], ["Foobator"]]
    try:
        import model
    except Exception:
        return
    m = model.Model({"agents": {n: {} for n in ("muse", "sol")}})
    for line in (q, p1, p2, p3):
        m._ingest_chat(dict(line, t=2000.0 + line["tick"] / 60), 2000.0 + line["tick"] / 60)
    assert [(r["seq"], r["to"], r["answers"]["text"]) for r in m.viewer_replies] == \
        [(s, ["Foobator"], "how is the quality loop going?") for s in (2, 3, 5)], list(m.viewer_replies)


def restored_chat():
    """d19 batch42 A5 (Aurora: "old chat restored after a restart ... earlier defense replies now look new"): the first
    chat read after a stream restart is the game's backlog. Its lines keep chat.jsonl's logged_at time (else the ticks
    since them) and are marked history, on the reply rows too; lines read after that are new as before."""
    import datetime, json, tempfile
    try:
        import model
    except Exception:
        return
    q = v(100, 600000, "Aurora", "@astra is the west wall holding?", source="site")
    ans = a(101, 600600, "astra", "Aurora, the west wall holds: 12 turrets with ammo.")
    logged = datetime.datetime(2026, 10, 19, 9, 0, 0)
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "chat.jsonl")
        with open(path, "w") as f:
            for line, dt in ((q, 0), (ans, 10)):
                row = {k: line[k] for k in ("seq", "tick", "from", "text")}
                row["logged_at"] = (logged + datetime.timedelta(seconds=dt)).isoformat()
                f.write(json.dumps(row) + "\n")
        m = model.Model({"agents": {"astra": {}}})
        m.set_chat_log(path)
        now = logged.timestamp() + 3600
        backlog = [{k: x[k] for k in x if k != "t"} for x in (q, ans)]
        backlog.append({"seq": 102, "tick": 600000 + 3600 * 60, "from": "astra", "text": "Aurora, fresh line."})
        m.ingest({"tick": 600000 + 3600 * 60, "chat": backlog}, now)
        rows = list(m.viewer_replies)
        assert len(rows) == 1 and rows[0]["t"] == logged.timestamp() + 10 and rows[0]["history"], rows
        assert m.chat[-1]["t"] == now and "history" not in m.chat[-1], m.chat[-1]  # said just now
        assert m.chat[0]["history"] and m.chat[0]["t"] == logged.timestamp()
        # without chat.jsonl: the ticks since it
        m2 = model.Model({"agents": {"astra": {}}})
        m2.ingest({"tick": 600600 + 600 * 60, "chat": [{k: ans[k] for k in ans if k != "t"}]}, now)
        assert m2.chat[0]["t"] == now - 600 and m2.chat[0]["history"], m2.chat[0]
        # a later read is new
        m2.ingest({"tick": 600600 + 700 * 60, "chat": [{"seq": 200, "tick": 600600, "from": "astra", "text": "late"}]}, now + 100)
        assert "history" not in m2.chat[-1] and m2.chat[-1]["t"] == now + 100


def main():
    host_tag()
    operator_elsewhere()
    rule_tests()
    classify_tests()
    try:
        import model  # noqa: F401
    except Exception as e:  # the stream model needs its own imports; the rule tests stand alone
        print(f"viewer replies: model part skipped ({e})")
    else:
        model_tests()
    operator_inbox_all()
    long_reply_parts()
    restored_chat()
    print("viewer replies: ok (restored chat keeps its time as history, a long reply's numbered parts in one thread, @name, vocatives, viewer-addressed lines, third person left out, the answered line, model snapshot, "
          "the Operator's answer to an inbox line (d16 18:31) in classify, the archive, the model and live.js)")


if __name__ == "__main__":
    main()
