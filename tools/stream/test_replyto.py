#!/usr/bin/env python3
"""A say with reply_to a viewer line threads under it (d20 batch50 C1): python3 tools/stream/test_replyto.py

shift45 seq 16942-16943: NickWinter asked "@muse Muse: How could we end the biter problem on Nauvis once and for all?";
Muse's "Good question. The permanent fix is ..." named no one, so viewer_replies did not count it and the site showed
no answer under his line. chat.lua now keeps a say's reply_to (a viewer line's seq) on the line and puts "@Name " in
front when the text names them nowhere; viewer_replies.classify takes reply_to first, also over a vocative to someone
else, and model.py keeps it from the chat read.
"""
import os, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import viewer_replies as V  # noqa: E402

ASK = {"seq": 16942, "tick": 36980026, "from": "viewer NickWinter (host)", "viewer": True, "source": "site",
       "text": "@muse Muse: How could we end the biter problem on Nauvis once and for all?"}
SONNET = {"seq": 16941, "tick": 36977409, "from": "viewer NickWinter (host)", "viewer": True, "source": "site",
          "text": "@sonnet Sonnet: did we stop making metallurgic science? How can we get that going again?"}
OLD = {"seq": 16943, "tick": 36981049, "from": "muse", "text": "Good question. The permanent fix is killing the spawners inside our "
       "pollution cloud, not the biters at the walls."}


def classify():
    assert V.classify(OLD, [SONNET, ASK]) is None  # as it was: no thread
    new = dict(OLD, text="@NickWinter " + OLD["text"], reply_to=16942)
    r = V.classify(new, [SONNET, ASK])
    assert r["kind"] == "reply" and r["to"] == ["NickWinter"] and r["answers"] is ASK, r
    # reply_to wins over the latest line of the named viewer (his Sonnet question came first here, the reply_to names it)
    r = V.classify(dict(OLD, reply_to=16941), [SONNET, ASK])
    assert r["answers"] is SONNET and r["to"] == ["NickWinter"], r
    # a seq this log has no viewer line for: chat.lua keeps reply_to only for viewer lines, so a line from before this log
    # (d22 batch75 AK6, shift57: Muse's 19841 to shift56's 19660 vanished from the site): a reply linked to none
    r = V.classify(dict(OLD, reply_to=16940), [SONNET, ASK])
    assert r == {"kind": "reply", "to": [], "answers": None, "link": "none"}, r
    assert V.classify(dict(OLD, reply_to=True), [SONNET, ASK]) is None
    # the archived pages' pass over a log
    rows = V.replies([SONNET, ASK, dict(OLD, text="@NickWinter " + OLD["text"], reply_to=16942)])
    assert len(rows) == 1 and rows[0][1]["answers"]["seq"] == 16942, rows
    row = V.row(rows[0][0], rows[0][1])
    assert row["answers"]["name"] == "NickWinter" and row["answers"]["text"].startswith("Muse: How could"), row


def model_keeps():
    import model
    m = model.Model({"agents": {n: {} for n in ("muse", "sonnet")}})
    now = time.time()
    m._ingest_chat(dict(ASK, t=now), now)
    m._ingest_chat(dict(OLD, t=now + 17, text="@NickWinter " + OLD["text"], reply_to=16942), now + 17)
    line = [c for c in m.chat if c.get("seq") == 16943][0]
    assert line["reply_to"] == 16942, line
    vr = list(m.viewer_replies)
    assert vr and vr[-1]["answers"]["name"] == "NickWinter" and vr[-1]["by"] == "muse", vr


def main():
    classify()
    model_keeps()
    print("reply_to: ok (a say with reply_to a viewer line threads under that line)")


if __name__ == "__main__":
    main()
