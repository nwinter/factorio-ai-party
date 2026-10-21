#!/usr/bin/env python3
"""The site chat shows a line's receipt in the operator's inbox apart from the relay's refusals: python3 site/test_operator_delivery.py

d20 batch65 AA1 (viewer Aurora 04:06 PDT: "Could chat show confirmed Operator inbox delivery separately from game relay
rejection? The artillery report still says not relayed despite your reply, making it easy to send duplicates"). static/
live.js under node (test_sitechat.py's stub page) with the live payload's shape: a line delivered to the operator reads
"to the Operator" (with Clef's refusal as its reason), never "not relayed"; once an Operator reply answers it, "Operator
replied at HH:MM", a button to that reply (it shows the replies when they are hidden); a line to the operator and an
agent that the relay refused keeps "not relayed: why" beside the receipt; an agent's relayed line is as before.
"""
import json, os, re, shutil, subprocess, tempfile

SITE = os.path.dirname(os.path.abspath(__file__))
NOW = 1792581100.0


def driver(base, server):
    head = base.split("require(process.argv[2]);")[0]
    old = re.search(r"const server = \[.*?\];\n", head).group(0)
    return head.replace(old, "const server = " + json.dumps(server) + ";\n") + r"""
require(process.argv[2]);
const out = {};
setTimeout(() => {
  out.html = kids['#vchat'].innerHTML;
  const box = kids['#vchat-replies'];
  box.checked = false; (box.on.change || []).forEach((f) => f({}));
  out.hidden_html = kids['#vchat'].innerHTML;
  // "Operator replied": to the reply, the replies shown again
  const btn = { closest: (s) => (s === '[data-reply]' ? { getAttribute: () => '18326' } : null) };
  (kids['#vchat'].on.click || []).forEach((f) => f({ target: btn }));
  out.shown_again = kids['#vchat'].innerHTML;
  out.box = box.checked;
  const el = kids['#c-a18326'];
  out.flash = !!(el && el.classList.contains('is-flash'));
  process.stdout.write(JSON.stringify(out), () => process.exit(0));
}, 300);
"""


def items(html):
    return [(c, re.sub(r"<[^>]+>", "", body), body) for c, body in re.findall(r"<li class=\"([^\"]+)\"[^>]*>(.*?)</li>", html)]


def main():
    if not shutil.which("node"):
        print("operator delivery: skipped (no node)")
        return
    import test_sitechat
    s = json.load(open(os.path.join(SITE, "live", "state.example.json")))
    s["now"] = NOW
    for a in s["agents"]:
        if a.get("name") == "astra":
            a["display_name"] = "Astra"
    art = ("@operator Could artillery remote results use manual range? Public code creates a flare but checks automatic "
           "reach, which can wrongly report that no loaded gun can hit a target.")
    t1 = NOW - 1191.3
    server = [{"seq": 3817, "t": t1, "name": "Aurora", "text": art},
              {"seq": 3818, "t": t1 + 5, "name": "Foobator", "text": "@operator @astra stop building turrets now"},
              {"seq": 3819, "t": t1 + 42, "name": "Aurora", "text": "@Astra Could you review why reminder 97 stays unfinished?"},
              {"seq": 3824, "t": NOW - 282, "name": "Aurora", "text": "@operator Could chat show confirmed Operator inbox delivery separately?"}]
    # the live payload's shape (push_live.public_delivery, viewer_replies)
    s["viewer_delivery"] = {"3817": {"s": "operator", "op": 1, "why": "kept off the stream: clef:injection"},
                            "3818": {"s": "not_relayed", "op": 1, "why": "clef:injection"},
                            "3819": {"s": "relayed", "to": "astra"},
                            "3824": {"s": "operator", "op": 1, "why": "to the operator's inbox"}}
    s["viewer_replies"] = [{"seq": 18326, "t": NOW - 626, "by": "operator", "kind": "reply", "to": ["Aurora"], "link": "only_line",
                            "text": "@Aurora Operator: queued for an engineer: the artillery remote's reach check.",
                            "answers": {"name": "Aurora", "text": art[10:], "t": round(t1, 1), "source": "site"}},
                           # (AA2) a two-part reply sent with tools/opreply.py --to site:3817: by its id, "part k of n"
                           {"seq": 18454, "t": NOW - 1, "by": "operator", "kind": "reply", "to": ["Aurora"], "link": "reply_to", "part": [1, 2],
                            "text": "@Aurora (1/2) Operator: the reply has used manual range since Oct 18.",
                            "answers": {"name": "Aurora", "text": "a question the id overrides", "t": round(t1, 1), "source": "site", "id": "site:3817"}},
                           {"seq": 18456, "t": NOW, "by": "operator", "kind": "reply", "to": ["Aurora"], "link": "reply_to", "part": [2, 2],
                            "text": "@Aurora (2/2) Operator: checked on a copy at 559 and 561 tiles.",
                            "answers": {"name": "Aurora", "text": "a question the id overrides", "t": round(t1, 1), "source": "site", "id": "site:3817"}}]
    with tempfile.TemporaryDirectory() as d:
        js, path = os.path.join(d, "chat.js"), os.path.join(d, "state.json")
        open(js, "w").write(driver(test_sitechat.LIVE_CHAT_JS, server))
        json.dump(s, open(path, "w"))
        r = subprocess.run(["node", js, os.path.join(SITE, "static", "live.js"), path], capture_output=True, text=True, timeout=30)
        assert r.returncode == 0, r.stderr
        o = json.loads(r.stdout)
    it = items(o["html"])
    find = lambda its, text: next(x for x in its if text in x[1])  # noqa: E731
    art_line = find(it, "Could artillery remote results")
    assert "Operator replied at" in art_line[1] and "(kept off the stream: clef:injection)" in art_line[1], art_line
    assert 'data-reply="18326"' in art_line[2] and "<button" in art_line[2], art_line
    assert "not relayed" not in art_line[1] and "to the Operator" not in art_line[1], art_line
    reply = it.index(find(it, "queued for an engineer"))
    assert it[reply - 1] == art_line and "c-thread" in it[reply][0], it
    p1, p2 = it.index(find(it, "manual range since Oct 18")), it.index(find(it, "checked on a copy at 559"))
    assert p1 == reply + 1 and p2 == reply + 2 and "c-thread" in it[p1][0] and "c-thread" in it[p2][0], it
    assert "part 1 of 2" in it[p1][1] and "part 2 of 2" in it[p2][1] and "part" not in it[reply][1].split("@Aurora")[0], (it[p1], it[reply])
    both = find(it, "stop building turrets")
    assert "to the Operator" in both[1] and "not relayed: clef:injection" in both[1], both
    relayed = find(it, "reminder 97")
    assert "to Astra" in relayed[1] and "Operator" not in relayed[1], relayed
    waiting = find(it, "inbox delivery separately")
    assert "to the Operator" in waiting[1] and "not relayed" not in waiting[1] and "(to the operator" not in waiting[1], waiting
    # replies hidden: still "Operator replied"; the button shows them and flashes the reply
    hid = items(o["hidden_html"])
    assert "Operator replied at" in find(hid, "Could artillery remote results")[1] and not any("queued for an engineer" in x[1] for x in hid), hid
    assert o["box"] is True and any("queued for an engineer" in x[1] for x in items(o["shown_again"])) and o["flash"], o
    print("operator delivery: ok (to the Operator, Operator replied with a button to the reply, not relayed only for the relay's refusals)")


if __name__ == "__main__":
    main()
