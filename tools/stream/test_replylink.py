#!/usr/bin/env python3
"""A reply links only to the viewer line it answers (d20 batch57 S1, viewer Aurora, shift47 inbox 15:24: "Could replies
link to and close only the question they answer? Muse's answers appeared under unrelated questions"):
python3 tools/stream/test_replylink.py

shift47 chat.jsonl 17556-17557: Muse said reply_to 17423 (Aurora, 13:09) and reply_to 17458 (Enginerd, 13:31) at 14:58;
viewer_replies kept only the last 15 minutes of viewer lines, did not find either, and threaded them by name under
Aurora's 17536 and Enginerd's 17553. Now a reply_to finds its line at any age (Threads.see); a reply without one links to
the named viewer's only line in the window, else their only one addressed to the replier, else to none (link "none",
the site says it is not linked); the Operator's "your HH:MM" names the line written at that minute.
"""
import datetime, os, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(HERE)), "site"))
import viewer_replies as V  # noqa: E402


def v(seq, tick, name, text):
    return {"seq": seq, "tick": tick, "from": "viewer " + name, "viewer": True, "source": "site", "text": text}


def a(seq, tick, who, text, **kw):
    return dict({"seq": seq, "tick": tick, "from": who, "text": text}, **kw)


M = 60 * 60  # ticks a minute
AURORA_1309 = v(17423, 1000 * M, "Aurora", "@muse @opus Could the 508 hand-fed findings be checked in smaller areas?")
ENGINERD_1331 = v(17458, 1022 * M, "Enginerd", "@muse Spark Consider where your flamethrower turrets are in general.")
AURORA_1451 = v(17536, 1102 * M, "Aurora", "@astra Could #1391 make each import cutover depend on sustained local output?")
ENGINERD_1456 = v(17553, 1107 * M, "Enginerd", "@opus did you know that bots can rebuild buildings for you automatically?")
MUSE_1 = a(17556, 1109 * M, "muse", "Aurora, fair point and I agree. Spot checks show small areas give exact answers.", reply_to=17423)
MUSE_2 = a(17557, 1109 * M + 10, "muse", "Enginerd, agreed. Flamers go at the front with only walls ahead.", reply_to=17458)


def muse_case():
    log = [AURORA_1309, ENGINERD_1331, AURORA_1451, ENGINERD_1456, MUSE_1, MUSE_2]
    got = {line["seq"]: r for line, r in V.replies(log)}
    assert got[17556]["answers"] is AURORA_1309 and got[17556]["link"] == "reply_to", got[17556]
    assert got[17557]["answers"] is ENGINERD_1331 and got[17557]["link"] == "reply_to", got[17557]
    # the live page's model: the lines left its chat window long ago
    import model
    m = model.Model({"agents": {n: {} for n in ("muse", "astra", "opus")}})
    now = time.time()
    for i, line in enumerate([AURORA_1309, ENGINERD_1331] + [a(30000 + k, 1001 * M + k, "astra", "filler %d" % k) for k in range(250)]
                             + [AURORA_1451, ENGINERD_1456, MUSE_1, MUSE_2]):
        m._ingest_chat(dict(line, t=now + i), now + i)
    assert all(c.get("seq") != 17423 for c in m.chat)  # gone from the model's chat
    rows = {r["seq"]: r for r in m.viewer_replies}
    assert "Could the 508" in rows[17556]["answers"]["text"] and rows[17556]["link"] == "reply_to", rows[17556]
    assert "Spark Consider" in rows[17557]["answers"]["text"] and rows[17557]["link"] == "reply_to", rows[17557]
    # a reply_to the log does not have: no line by name either
    r = V.classify(a(9, 1103 * M, "astra", "Aurora, yes.", reply_to=12), [AURORA_1451])
    assert r["answers"] is None and r["link"] == "none" and r["to"] == ["Aurora"], r


def by_name():
    q1 = v(1, 100 * M, "Foobator", "@grok @sol grok: are you wearing belt immunity?")
    q2 = v(2, 105 * M, "Foobator", "@muse @sol muse: could you send defence wall gaps to sol?")
    q3 = v(3, 108 * M, "Foobator", "@muse muse: is arty auto?")
    # one line in the window: that one
    r = V.classify(a(10, 101 * M, "grok", "Foobator, I am not wearing belt immunity."), [q1])
    assert r["answers"] is q1 and r["link"] == "only_line", r
    # several: the only one addressed to the replier (the relay's "@muse @sol ..." counts for each)
    r = V.classify(a(11, 109 * M, "grok", "Foobator, I stepped off the belt."), [q1, q2, q3])
    assert r["answers"] is q1 and r["link"] == "only_to", r
    # two to muse: none, however many words it shares with either (shift46 17037: "that's a great tip" under the question)
    r = V.classify(a(12, 109 * M, "muse", "Foobator, artillery is auto; the defence wall gaps are posted for sol."), [q1, q2, q3])
    assert r["answers"] is None and r["link"] == "none" and r["to"] == ["Foobator"], r
    # none addressed to the replier, several lines: none (Luna answering lines to Haiku and Astra)
    r = V.classify(a(13, 109 * M, "luna", "@Foobator Haiku has the drill marked."), [q2, q3])
    assert r["answers"] is None and r["link"] == "none", r
    # outside the window: not counted
    r = V.classify(a(14, 116 * M, "grok", "Foobator, again."), [q1, q3])  # q1 16 min old
    assert r["answers"] is q3 and r["link"] == "only_line", r
    row = V.row(a(10, 101 * M, "grok", "Foobator, x"), {"kind": "reply", "to": ["Foobator"], "answers": None, "link": "none"})
    assert row["link"] == "none" and "answers" not in row, row


def operator_time():
    t = lambda hm: datetime.datetime(2026, 10, 20, int(hm[:2]), int(hm[3:])).timestamp()  # noqa: E731
    rows = [{"t": t("13:59"), "agent": "viewer Aurora", "text": "@operator Could factory snapshots retain their capture time?",
             "viewer": True, "source": "site"},
            {"t": t("15:23"), "agent": "viewer Aurora", "text": "@operator Could platform queue guards detect loss?", "viewer": True},
            {"t": t("15:24"), "agent": "viewer Aurora", "text": "@operator Could replies link to the question they answer?", "viewer": True}]
    inbox = V.inbox_lines(rows)
    op = {"seq": 17600, "t": t("15:30"), "from": "server", "text": "@Aurora Operator: live since 15:27. Snapshots (your 13:59): six reads."}
    r = V.classify(op, [], inbox)
    assert r["link"] == "time" and r["answers"]["text"].startswith("@operator Could factory snapshots"), r
    # no time named, two lines to the Operator in the window: none (shift47 17600 threaded under the 15:24 line)
    r = V.classify(dict(op, text="@Aurora Operator: live since 15:27."), [], inbox)
    assert r["answers"] is None and r["link"] == "none", r


def site_payload():
    import push_live
    out = push_live.public_replies([{"seq": 1, "t": 5.0, "by": "sol", "text": "Aurora, x", "kind": "reply", "to": ["Aurora"], "link": "none"},
                                    {"seq": 2, "t": 6.0, "by": "sol", "text": "Aurora, y", "kind": "reply", "to": ["Aurora"], "link": "bogus"}])
    assert out[0]["link"] == "none" and "link" not in out[1], out


def overlay_pins():
    """The stream's pins (static/chatfeed.js questionFor): a reply_to pins its line, or nothing when the snapshot lacks it."""
    import shutil
    if not shutil.which("node"):
        print("reply link: overlay part skipped (no node)")
        return
    from test_viewer_pins import js
    T = 5000.0
    copy = lambda c, dt: dict(c, t=T + dt, lane="viewer")  # noqa: E731
    lane = [{"id": "s1", "source": "site", "name": "Enginerd", "t": T, "text": "Spark Consider where your flamethrower turrets are in general."},
            {"id": "s2", "source": "site", "name": "Enginerd", "t": T + 300, "text": "did you know that bots can rebuild buildings for you automatically?"}]
    muse = dict(MUSE_2, agent="muse", lane="talk", t=T + 310)
    snap = {"now": T + 312, "chat": [copy(ENGINERD_1331, 0), copy(ENGINERD_1456, 300), muse], "viewers": lane}
    p = js("c.viewerPins(d)", snap)
    qa = [x for x in p if x["kind"] == "qa"]
    assert len(qa) == 1 and qa[0]["v"]["id"] == "s1", p
    snap["chat"] = [copy(ENGINERD_1456, 300), muse]  # its line is not in the snapshot: no pin under the other line
    assert not [x for x in js("c.viewerPins(d)", snap) if x["kind"] == "qa"], snap


def main():
    overlay_pins()
    muse_case()
    by_name()
    operator_time()
    site_payload()
    print("reply link: ok (reply_to at any age; by name only to the viewer's one line, or one line to the replier; "
          "the Operator's \"your HH:MM\"; else not linked)")


if __name__ == "__main__":
    main()
