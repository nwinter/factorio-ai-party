#!/usr/bin/env python3
"""Reserved viewer names and the host's lines (d16 17:12; Nick 17:11: "a host link so I can have verified comments and
disallow similar nicks"): python3 tools/stream/test_names.py

1. names.py and the Worker's reservedName (site/worker/worker.js, run under node) give the same verdict on one list of
   names: Nick's and look-alikes (case, spaces, punctuation, leetspeak, Cyrillic/Greek, zero-width), "Operator" and
   near misses, the agents, "server"; viewers' real names from the shifts pass.
2. The relay (viewers.py): a site row with host: true is "NickWinter (host)" and never dropped as impersonation or
   rate-limited; a site row under a reserved name without host (older Worker rows too) drops; on YouTube only Nick's
   channel id is the host, and any other author with a reserved name gets " (viewer)"; the game line names the host.
3. The stream's chat panel badges a host line HOST; push_live passes host on YouTube lines.
"""
import json, os, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
import names  # noqa: E402
import viewers as V  # noqa: E402

RESERVED = ["NickWinter", "nickwinter", "Nick Winter", "nick_winter", "N1ckW1nter", "Nick.W", "NickW", "nickw123",
            "N!ckWinter", "Ni ck Wi nt er", "NICKWINTER", "ΝickWinter", "Nіck Winter", "nick​winter", "NickWintr",
            "NickWlnter", "Nikwinter", "MickWinter", "Nick", "n i c k", "Winter", "W1nter", "Operator", "0perat0r",
            "Opperator", "Operat0rr", "operate", "Sol", "S0l", "SOL", "Luna", "Astra", "Opus", "Sonnet", "Haiku", "Grok",
            "Gemini", "Muse", "server", "Server", "Ѕerver", "mod", "Admin", "the nickwinter fan"]
FREE = ["Foobator", "LimeLight555", "LimeLight", "joonazan", "Enginerd", "SeniorEngineer", "craigNZ830", "awoo3391",
        "syndesis", "Alex", "rustyminer", "Nicky", "Nicolas", "Winterfell", "Solar", "Lunatic", "Grokker", "observer",
        "fan_1", "viewer"]


def verdicts():
    for n in RESERVED:
        assert names.reserved(n), n
    for n in FREE:
        assert not names.reserved(n), (n, names.reserved(n))
    assert names.normalize("Ν1ck​ W|nter!") == "nickwinter" and names.normalize("") == ""
    assert names.distance("nickwintr", "nickwinter") == 1 and names.distance("abc", "nickwinter") == 3


JS = r"""
const { normalizeName, reservedName } = await import(process.argv[2]);
const list = JSON.parse(process.argv[3]);
process.stdout.write(JSON.stringify(list.map((n) => [normalizeName(n), reservedName(n)])));
"""


def same_in_worker():
    if not shutil.which("node"):
        print("names: worker part skipped (no node)")
        return
    every = RESERVED + FREE + ["Ν1ck​ W|nter!", "", "ёлка", "ΚΑΙ", "Ｎｉｃｋ", "𝐍𝐢𝐜𝐤𝐖𝐢𝐧𝐭𝐞𝐫"]
    with tempfile.TemporaryDirectory() as d:
        js = os.path.join(d, "n.mjs")
        open(js, "w").write(JS)
        r = subprocess.run(["node", "--no-warnings", js, "file://" + os.path.join(ROOT, "site", "worker", "worker.js"),
                            json.dumps(every)], capture_output=True, text=True, timeout=30)
        assert r.returncode == 0, r.stderr
        got = json.loads(r.stdout)
    for n, (norm, why) in zip(every, got):
        assert norm == names.normalize(n), (n, norm, names.normalize(n))
        assert why == names.reserved(n), (n, why, names.reserved(n))


def relay():
    agents = ["astra", "sol", "luna"]
    now = 1000.0

    def check(m):
        return V.Filter(agents).check(dict({"author": "a", "text": "hello everyone", "t": now}, **m), now)

    # site: host true -> the host's line; without it a reserved name drops (an older Worker row has no host field)
    v, r = check({"id": "site:1", "source": "site", "name": "whatever", "host": True})
    assert r == [] and v["name"] == "NickWinter (host)" and v["host"] is True, (v, r)
    for n in ("NickWinter", "N1ck Winter", "Operator", "Sol", "0perat0r"):
        v, r = check({"id": "site:2", "source": "site", "name": n})
        assert "impersonation:name" in r, (n, r)
    v, r = check({"id": "site:3", "source": "site", "name": "Foobator"})
    assert r == [] and v["name"] == "Foobator" and "host" not in v
    # the host is not rate-limited or held as a duplicate, and "nick here" is no impersonation from Nick
    f = V.Filter(agents)
    for i in range(12):
        v, r = f.check({"id": f"site:h{i}", "source": "site", "author": "h", "name": "x", "text": "nick here, nice work",
                        "t": now + i, "host": True}, now + i)
        assert r == [], (i, r)
    # SiteChat reads host from the Worker's rows (only a real true)
    page = {"messages": [{"seq": 5, "t": 1.0, "name": "NickWinter", "text": "hi", "host": True},
                         {"seq": 6, "t": 2.0, "name": "NickWinter", "text": "hi"},
                         {"seq": 7, "t": 3.0, "name": "x", "text": "hi", "host": "yes"}], "last_seq": 7}
    sc = V.SiteChat("https://api.test", fetch=lambda u: json.dumps(page))
    sc.after = 4
    msgs, _, _ = sc.poll()
    assert [m["host"] for m in msgs] == [True, False, False], msgs
    # YouTube: Nick's channel id is the host whatever the display name; another "NickWinter" is a viewer
    def yt(channel, name):
        return {"addChatItemAction": {"item": {"liveChatTextMessageRenderer": {
            "id": "c" + channel[-4:], "authorExternalChannelId": channel, "authorName": {"simpleText": name},
            "message": {"runs": [{"text": "hello agents"}]}, "timestampUsec": "1792194914000000"}}}}
    got, _ = V.parse_actions([yt(names.HOST_YOUTUBE_CHANNEL, "NickWinter"), yt("UCxxxxxxxxxxxxxxxxxxxxxx", "NickWinter"),
                              yt("UCyyyyyyyyyyyyyyyyyyyyyy", "Nick Winter"), yt("UCzzzzzzzzzzzzzzzzzzzzzz", "Opperator")])
    assert [m["host"] for m in got] == [True, False, False, False], got
    shown = [V.Filter(agents).check(m, now) for m in got]
    assert [v["name"] for v, _ in shown] == ["NickWinter (host)", "NickWinter (viewer)", "Nick Winter (viewer)",
                                            "Opperator (viewer)"], shown
    assert all("impersonation:name" not in r for _, r in shown) and shown[0][0].get("host") is True
    # the stored hash of Nick's 16:55/16:56 messages is this channel's
    assert V.author_key("yt", names.HOST_YOUTUBE_CHANNEL) == "yt:c71bef0777f3"
    # the game line: viewer_say gets the host's label as the name
    line = V.Relay.line(dict(shown[0][0], text="hello agents"))
    assert line["name"] == "NickWinter (host)" and line["source"] == "youtube", line
    # a recorded replay row can carry host too
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "r.jsonl")
        open(path, "w").write(json.dumps({"dt": 0, "source": "site", "name": "x", "text": "hi", "host": True}) + "\n"
                              + json.dumps({"dt": 0, "source": "site", "name": "y", "text": "yo"}) + "\n")
        msgs, _, _ = V.ReplayChat(path, speed=1000.0).poll()
        assert [m["host"] for m in msgs] == [True, False], msgs


def feed_and_page():
    sys.path.insert(0, os.path.join(ROOT, "site"))
    import push_live
    rows = push_live.public_youtube([{"id": "yt:1", "source": "youtube", "name": "NickWinter (host)", "text": "hi", "t": 5.0,
                                      "host": True},
                                     {"id": "yt:2", "source": "youtube", "name": "Foo", "text": "yo", "t": 6.0}])
    assert rows[0]["host"] is True and "host" not in rows[1], rows
    if not shutil.which("node"):
        print("names: overlay part skipped (no node)")
        return
    code = open(os.path.join(HERE, "static", "overlay.js")).read()
    fn = code[code.index("  function vbadge(v) {"):code.index("  function renderCams(s)")]
    js = "const el = (tag, cls, text) => ({cls, text});\n" + fn + """
const out = [vbadge({host: true, source: 'site'}), vbadge({source: 'site'}), vbadge({source: 'youtube'}), vbadge({host: true, source: 'youtube'})];
process.stdout.write(JSON.stringify(out));"""
    r = subprocess.run(["node", "-e", js], capture_output=True, text=True, timeout=10)
    assert r.returncode == 0, r.stderr
    assert json.loads(r.stdout) == [{"cls": "vbadge host", "text": "HOST"}, {"cls": "vbadge site", "text": "SITE"},
                                    {"cls": "vbadge", "text": "YT"}, {"cls": "vbadge host", "text": "HOST"}], r.stdout


if __name__ == "__main__":
    verdicts()
    same_in_worker()
    relay()
    feed_and_page()
    print("names: ok (reserved names and look-alikes, the same in the Worker, host lines in the relay, YouTube by "
          "channel id, HOST badges)")
