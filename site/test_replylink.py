#!/usr/bin/env python3
"""The site chat says how a reply found its viewer line (d20 batch57 S1, viewer Aurora 15:24): python3 site/test_replylink.py

static/live.js under node (test_sitechat.py's stub page): state.viewer_replies rows carry `link`
(tools/stream/viewer_replies.py). reply_to: threaded under its line, nothing added; only_line / only_to: threaded and
"matched by name: NAME's only recent line (to AGENT)"; time: "matched by the time it names"; none: in time order, "not
linked to a question"; a linked line the list does not show (Muse's reply_to a line 90 minutes old) is quoted after "re".
"""
import json, os, re, shutil, subprocess, tempfile

SITE = os.path.dirname(os.path.abspath(__file__))


def main():
    if not shutil.which("node"):
        print("reply link: skipped (no node)")
        return
    import test_sitechat
    s = json.load(open(os.path.join(SITE, "live", "state.example.json")))
    now = 1792070000.0
    s["now"] = now
    for a in s["agents"]:
        if a.get("name") == "haiku":
            a["display_name"] = "Haiku"
    s["youtube_chat"] = [{"id": "y1", "name": "Foobator", "text": "@grok why is steel stopped?", "t": now - 100},
                         {"id": "y2", "name": "joonazan", "text": "@haiku nice base", "t": now - 90}]
    ans = lambda name, text, t: {"name": name, "text": text, "t": t, "source": "YouTube"}  # noqa: E731
    s["viewer_replies"] = [
        {"seq": 10, "t": now - 40, "by": "grok", "text": "Foobator, the steel line is stopped.", "kind": "reply", "to": ["Foobator"],
         "link": "reply_to", "answers": ans("Foobator", "why is steel stopped?", now - 100)},
        {"seq": 11, "t": now - 35, "by": "grok", "text": "Foobator, iron is back.", "kind": "reply", "to": ["Foobator"],
         "link": "only_line", "answers": ans("Foobator", "why is steel stopped?", now - 100)},
        {"seq": 12, "t": now - 30, "by": "haiku", "text": "joonazan, thanks.", "kind": "reply", "to": ["joonazan"],
         "link": "only_to", "answers": ans("joonazan", "nice base", now - 90)},
        {"seq": 13, "t": now - 25, "by": "muse", "text": "Aurora, fair point and I agree.", "kind": "reply", "to": ["Aurora"],
         "link": "reply_to", "answers": ans("Aurora", "Could the 508 hand-fed findings be checked in smaller areas before planning upgrades?", now - 5400)},
        {"seq": 14, "t": now - 20, "by": "sol", "text": "Foobator, I will take those gaps.", "kind": "reply", "to": ["Foobator"], "link": "none"},
        {"seq": 15, "t": now - 15, "by": "operator", "text": "@Aurora Operator: live since 15:27 (your 13:59).", "kind": "reply",
         "to": ["Aurora"], "link": "time", "answers": ans("Aurora", "Could factory snapshots retain their capture time?", now - 5000)}]
    with tempfile.TemporaryDirectory() as d:
        js, path = os.path.join(d, "chat.js"), os.path.join(d, "state.json")
        open(js, "w").write(test_sitechat.LIVE_CHAT_JS)
        json.dump(s, open(path, "w"))
        r = subprocess.run(["node", js, os.path.join(SITE, "static", "live.js"), path], capture_output=True, text=True, timeout=30)
        assert r.returncode == 0, r.stderr
        html = json.loads(r.stdout)["html"]
    items = [(c, re.sub(r"<[^>]+>", "", body)) for c, body in re.findall(r"<li class=\"([^\"]+)\"[^>]*>(.*?)</li>", html)]
    find = lambda text: next(i for i, (_, t) in enumerate(items) if text in t)  # noqa: E731
    q, a10, a11 = find("why is steel stopped?"), find("the steel line is stopped"), find("iron is back")
    assert a10 == q + 1 and a11 == q + 2 and "c-thread" in items[a11][0], items
    assert "matched" not in items[a10][1] and "not linked" not in items[a10][1], items[a10]
    assert "matched by name: Foobator's only recent line" in items[a11][1], items[a11]
    a12 = find("joonazan, thanks.")
    assert a12 == find("nice base") + 1 and "matched by name: joonazan's only recent line to Haiku" in items[a12][1], items[a12]
    a13 = items[find("fair point and I agree")]
    assert "c-thread" not in a13[0] and "↪ Aurora: “Could the 508 hand-fed findings be checked in smaller areas before pl…”" in a13[1], a13
    a14 = items[find("I will take those gaps")]
    assert "c-thread" not in a14[0] and "not linked to a question" in a14[1] and "matched" not in a14[1], a14
    a15 = items[find("live since 15:27")]
    assert "matched by the time it names" in a15[1] and "↪ " in a15[1] and "“Could factory snapshots" in a15[1], a15
    print("reply link: ok (the site chat says how each reply found its line, quotes a line it does not show, and says when "
          "a reply is linked to none)")


if __name__ == "__main__":
    main()
