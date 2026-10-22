#!/usr/bin/env python3
"""Replies on the site chat by their source lines' ids, with a quote and a reply count (d22 batch75 AK6, viewer Aurora
site:4175: "preserve source message IDs ... then thread by those IDs? Allow one answer to link to several messages."
and site:4176: "Could replies show a short clickable quote of the source message, with a reply count on the original?
Keep new replies easy to spot without scattering unrelated conversations."): python3 site/test_replythreads.py

static/live.js under node (test_sitechat.py's stub page and worker, with these site lines):
- a reply finds each line it answers by its id (site:N among the site lines, yt:ID among the YouTube lines) before the
  viewer's name and words: a reply whose quoted words differ still finds its line by id;
- over a reply, a short quote of each line it answers (one reply, three lines), a button to that line (data-jump),
  or the quote alone for a line the list does not show;
- on each line answered, its reply count, a button to the first reply;
- a reply threads under its first line when that line is at most 20 minutes older; a reply to an older line stays in
  time order at the bottom with its quote (no conversation pulled apart);
- a reply from the last ten minutes is marked new; an older one is not.
"""
import json, os, re, shutil, subprocess, tempfile, time

SITE = os.path.dirname(os.path.abspath(__file__))


def check(name, ok, detail=""):
    if not ok:
        raise SystemExit(f"FAIL {name}: {detail}")


def main():
    if not shutil.which("node"):
        print("reply threads: skipped (no node)")
        return
    import test_sitechat
    js_src = test_sitechat.LIVE_CHAT_JS
    old = "const server = [{ seq: 1, t: state.now - 120, name: 'Foobator', text: 'hello from the site' }];"
    check("the stub's worker", old in js_src)
    js_src = js_src.replace(old, "const server = state.__site;")
    s = json.load(open(os.path.join(SITE, "live", "state.example.json")))
    now = time.time()
    s["now"] = now
    s["__site"] = [{"seq": 1, "t": now - 3000, "name": "Caleb", "text": "@astra how is the rail network?"},
                   {"seq": 2, "t": now - 960, "name": "Kai", "text": "@opus hi"},
                   {"seq": 3, "t": now - 300, "name": "Foobator", "text": "@muse is the south wall closed?"},
                   {"seq": 4, "t": now - 280, "name": "Aurora", "text": "@muse and the west one?"}]
    s["youtube_chat"] = [{"id": "yt:Ugx1", "name": "Aurora", "text": "@muse the north?", "t": now - 200}]
    a = lambda name, text, i=None: dict({"name": name, "text": text, "source": "site"}, **({"id": i} if i else {}))  # noqa: E731
    s["viewer_replies"] = [
        {"seq": 20, "t": now - 900, "by": "opus", "text": "Kai, hello.", "kind": "reply", "to": ["Kai"], "link": "only_line", "answers": a("Kai", "hi", "site:2")},
        {"seq": 21, "t": now - 100, "by": "muse", "text": "Both walls and the north gate are closed.", "kind": "reply", "to": ["Foobator", "Aurora"],
         "link": "reply_to", "answers": a("Foobator", "is the south wall closed?", "site:3"),
         "also": [a("Aurora", "and the west one?", "site:4"), a("Aurora", "the north?", "yt:Ugx1")]},
        {"seq": 22, "t": now - 50, "by": "sol", "text": "Foobator, I checked it too.", "kind": "reply", "to": ["Foobator"], "link": "name",
         "answers": a("Foobator", "IS THE SOUTH... (other words)", "site:3")},
        {"seq": 23, "t": now - 20, "by": "astra", "text": "Caleb, the rail network is whole.", "kind": "reply", "to": ["Caleb"], "link": "reply_to",
         "answers": a("Caleb", "how is the rail network?", "site:1")},
        {"seq": 24, "t": now - 10, "by": "haiku", "text": "Lee, done.", "kind": "reply", "to": ["Lee"], "link": "reply_to",
         "answers": a("Lee", "is the mall stocked?", "site:999")}]
    with tempfile.TemporaryDirectory() as d:
        js, path = os.path.join(d, "chat.js"), os.path.join(d, "state.json")
        open(js, "w").write(js_src)
        json.dump(s, open(path, "w"))
        r = subprocess.run(["node", js, os.path.join(SITE, "static", "live.js"), path], capture_output=True, text=True, timeout=30)
    check("node", r.returncode == 0, r.stderr[-2000:])
    html = json.loads(r.stdout)["html"]
    items = re.findall(r'<li class="([^"]+)" id="([^"]+)"[^>]*>(.*?)</li>', html)
    ids = [i for _, i, _ in items]
    at = lambda i: ids.index(i)  # noqa: E731
    body = {i: b for _, i, b in items}
    cls = {i: c for c, i, _ in items}
    text = lambda i: re.sub(r"<[^>]+>", "", body[i])  # noqa: E731
    # threading: muse's and sol's replies under Foobator's line (a quote's other lines do not move them)
    check("threaded under its first line", at("c-a21") == at("c-s3") + 1 and at("c-a22") == at("c-a21") + 1 and "c-thread" in cls["c-a21"], ids)
    check("conversations kept together", at("c-s4") == at("c-a22") + 1 and at("c-yyt:Ugx1") > at("c-s4"), ids)
    # an old line's reply stays at the bottom, in time order
    check("a reply to an old line: in time order", at("c-a23") > at("c-yyt:Ugx1") and "c-thread" not in cls["c-a23"], ids)
    # quotes: one button per line answered, to its key
    q = re.findall(r'<button type="button" class="c-quote" data-jump="([^"]+)"[^>]*>([^<]*)</button>', body["c-a21"])
    check("three quotes, each a jump", [k for k, _ in q] == ["s3", "s4", "yyt:Ugx1"], q)
    check("quote text", q[0][1] == "↪ Foobator: “is the south wall closed?”" and q[2][1] == "↪ Aurora: “the north?”", q)
    check("found by id, other words", re.search(r'data-jump="s3"', body["c-a22"]), body["c-a22"])
    check("a line not shown: the quote alone", 'class="c-quote c-quote-away' in body["c-a24"] and "data-jump" not in body["c-a24"]
          and "↪ Lee: “is the mall stocked?”" in text("c-a24"), body["c-a24"])
    # counts on the lines answered, each a button to the first reply
    cnt = lambda i: re.findall(r'<button type="button" class="c-replies" data-jump="([^"]+)">([^<]+)</button>', body[i])  # noqa: E731
    check("Foobator's: 2 replies", cnt("c-s3") == [("a21", "2 replies")], cnt("c-s3"))
    check("Aurora's site line: 1", cnt("c-s4") == [("a21", "1 reply")] and cnt("c-yyt:Ugx1") == [("a21", "1 reply")], (cnt("c-s4"), cnt("c-yyt:Ugx1")))
    check("Caleb's old line: 1", cnt("c-s1") == [("a23", "1 reply")], cnt("c-s1"))
    # new replies marked
    check("new", "c-new" in cls["c-a21"] and ">new<" in body["c-a21"] and "c-new" not in cls["c-a20"], (cls["c-a21"], cls["c-a20"]))
    check("linked by name", "linked by name: Foobator's open line to" in text("c-a22"), text("c-a22"))
    print("reply threads: ok (lines found by id; quotes that jump; reply counts; recent exchanges threaded, older replies in "
          "time order; new replies marked)")


if __name__ == "__main__":
    main()
