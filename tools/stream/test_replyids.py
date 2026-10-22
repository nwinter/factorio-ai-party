#!/usr/bin/env python3
"""Replies threaded by the viewer lines' own ids, one reply to several lines (d22 batch75 AK6, viewer Aurora site:4175:
"Many AI replies are unlinked. Could you preserve source message IDs through the harness and reply feed, then thread by
those IDs? Allow one answer to link to several messages."): python3 tools/stream/test_replyids.py

shift57 (chat.jsonl, the agents' journals): 101 of 180 agent lines answer a viewer; 9 carried reply_to, all Muse's; Muse's
19841 (reply_to a list of 5 viewer lines, chat.lua kept 19660) and 19844 (reply_to 19712) answered lines from shift56,
which this log does not have: the stream service classified both as no reply and the site never showed them. Here:
- the relay passes each line's id (site:4175, yt:...) to viewer_say (viewers.Relay.lines), the model keeps it
  (source_id), and a reply's answers carry it as id;
- a say's replies_to (chat.lua: each viewer line it answers {seq, name, id, source, tick, text}) links it with no
  viewer line in this log: answers, also (the others), to (every viewer), link reply_to, or name when the harness
  linked it by the name it says (linked_by);
- push_live passes answers.id and also; a reply_to with nothing kept for it is still a reply (linked to none).
"""
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(HERE)), "site"))
sys.dont_write_bytecode = True
import viewer_replies as V  # noqa: E402
from viewers import Relay  # noqa: E402
from model import Model  # noqa: E402
import push_live  # noqa: E402


def check(name, ok, detail=""):
    if not ok:
        raise SystemExit(f"FAIL {name}: {detail}")


FOO = {"seq": 19858, "tick": 46400000, "from": "viewer Foobator", "viewer": True, "source": "site", "source_id": "site:4175",
       "text": "@muse is the south wall closed?"}
AUR = {"seq": 19860, "tick": 46400600, "from": "viewer Aurora", "viewer": True, "source": "YouTube", "source_id": "yt:Ugx-1_2=",
       "text": "@muse and the west one?"}


def main():
    # the relay: each part carries the line's id; an id the harness would not keep is left out
    parts = Relay.lines({"id": "site:4175", "name": "Foobator", "text": "is the south wall closed? " * 20, "source": "site"}, "muse")
    check("every part its id", len(parts) > 1 and all(p["id"] == "site:4175" for p in parts), parts)
    check("an odd id left out", "id" not in Relay.line({"id": "site:<b>", "name": "x", "text": "hi"}), Relay.line({"id": "site:<b>", "name": "x", "text": "hi"}))

    # replies_to: several lines, one from before this log (shift57's 19841: 19660 was shift56's)
    snap = lambda v, seq=None: {"seq": seq or v["seq"], "name": V.viewer_name(v), "id": v["source_id"], "source": v["source"], "tick": v["tick"],  # noqa: E731
                                "text": V.bare(v["text"])}
    say = {"seq": 19900, "tick": 46401000, "from": "muse", "text": "@Foobator @Aurora Both walls are closed.",
           "reply_to": 19660, "replies_to": [snap(FOO, 19660), snap(AUR)]}
    r = V.classify(say, [AUR], by_seq={AUR["seq"]: AUR})
    check("several lines", r["kind"] == "reply" and r["to"] == ["Foobator", "Aurora"] and r["link"] == "reply_to", r)
    check("the old line from what the say kept", r["answers"]["seq"] == 19660 and r["answers"]["source_id"] == "site:4175"
          and V.bare(r["answers"]["text"]) == "is the south wall closed?", r["answers"])
    check("the kept line itself when here", r["also"][0] is not AUR and r["also"][0]["seq"] == AUR["seq"] and r["also"][0]["source_id"] == "yt:Ugx-1_2=", r["also"])
    row = V.row(say, r)
    check("row: ids", row["answers"]["id"] == "site:4175" and row["also"] == [{"name": "Aurora", "text": "and the west one?", "t": None,
                                                                                "tick": AUR["tick"], "source": "YouTube", "id": "yt:Ugx-1_2="}], row)
    # linked by the harness by the name it says
    named = dict(say, replies_to=[snap(FOO)], linked_by="name", reply_to=FOO["seq"], text="Foobator, it is closed.")
    r2 = V.classify(named, [FOO], by_seq={FOO["seq"]: FOO})
    check("linked by name", r2["link"] == "name" and r2["answers"]["seq"] == FOO["seq"] and r2["also"] == [], r2)
    # a runtime from before (reply_to only) to a line this log lacks: a reply linked to none, never dropped
    r3 = V.classify({"seq": 19841, "tick": 46388323, "from": "muse", "text": "(1/2) Foobator, I am back on watch.", "reply_to": 19660}, [], by_seq={})
    check("old reply_to kept as a reply", r3 == {"kind": "reply", "to": [], "answers": None, "link": "none"}, r3)
    # an Operator line (AA2) and the usual name rules are as before
    check("no replies_to: the usual rules", V.classify({"seq": 1, "tick": 46400700, "from": "muse", "text": "Foobator, yes."}, [FOO])["link"] == "only_line")

    # the model keeps the new fields from a chat read, and its viewer_replies rows carry them
    m = Model({"agents": {"muse": {}}})
    now = 1792690000.0
    m._ingest_chat(dict(FOO, t=now - 60), now - 60)
    m._ingest_chat(dict(AUR, t=now - 50), now - 50)
    m._ingest_chat(dict(say, t=now, reply_to=FOO["seq"], replies_to=[snap(FOO), snap(AUR), {"bad": 1}]), now)
    kept = [c for c in m.chat if c.get("seq") == FOO["seq"]][0]
    check("model: a viewer line's id", kept.get("source_id") == "site:4175", kept)
    line = [c for c in m.chat if c.get("seq") == 19900][0]
    check("model: replies_to kept", [x["seq"] for x in line["replies_to"]] == [FOO["seq"], AUR["seq"]], line)
    vr = m.viewer_replies[-1]
    check("model: the row", vr["answers"]["id"] == "site:4175" and vr["also"][0]["id"] == "yt:Ugx-1_2=" and vr["link"] == "reply_to", vr)

    # push_live: answers.id and also (an odd id left out; a hidden line's viewer left out of `to`)
    class Hide:
        @staticmethod
        def hides(name, text):
            return name == "Spam"
    rows = push_live.public_replies([dict(vr, t=now), dict(vr, seq=19901, t=now + 1, also=[{"name": "Spam", "text": "x"}, {"name": "Aurora", "text": "y", "id": "site:<x>"}],
                                                           to=["Foobator", "Spam", "Aurora"], link="name")], Hide())
    check("push_live: ids and also", rows[0]["answers"]["id"] == "site:4175" and rows[0]["also"][0]["id"] == "yt:Ugx-1_2=" and rows[0]["link"] == "reply_to", rows[0])
    check("push_live: hidden and odd left out", rows[1]["also"] == [{"name": "Aurora", "text": "y", "t": None, "source": None}]
          and rows[1]["to"] == ["Foobator", "Aurora"] and rows[1]["link"] == "name", rows[1])
    print("reply ids: ok (ids from the relay through the model to push_live; one reply to several lines; a line from an "
          "earlier shift linked from what the say kept; linked by name; an old reply_to still a reply)")


if __name__ == "__main__":
    main()
