#!/usr/bin/env python3
"""The Operator's replies keep the line they answer, no network: python3 tools/stream/test_opreply.py

d20 batch65 AA2 (viewer Aurora 04:28: "Could replies keep the original question ID through delivery, split parts and
history? Some clear replies say 'not linked', and artillery answers appeared under a different question"). shift50:
the Operator's 04:20 artillery answer (chat 18454 and 18456) named no time, so by name it linked to her only inbox line
in the 15 minutes before, the 04:06 one; read again after a restart it stayed there. Checks: tools/opreply.py's parts
(500 bytes, numbered, cut at sentence ends), its --to forms, the record written before the lines go out, --sent;
viewer_replies' links (each part answers the named line, part k of n, at a restart too; a reply with no record is
matched as before); push_live keeps the id and the part; bare() drops every leading @name; live.js finds a line by id.
"""
import datetime, json, os, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path[:0] = [HERE, os.path.dirname(HERE), os.path.join(ROOT, "site")]
import opreply  # noqa: E402
import viewer_replies as V  # noqa: E402

ART = ("@operator Could artillery remote results use manual range? Public code creates a flare but checks automatic "
       "reach, which can wrongly report that no loaded gun can hit a target.")
CHAT = "@operator Could chat show confirmed Operator inbox delivery separately from game relay rejection?"
T_ART, T_CHAT = 1792579908.7, 1792580817.9
P1 = ("@Aurora Operator: the artillery remote's reply has used manual range since Oct 18: a loaded turret or wagon counts "
      "as in reach within 224 x 2.5 = 560 tiles (728 with +30% range research), not inside 32.")
P2 = ("@Aurora Operator: checked on a copy: a turret fired at flares at 300 and 559 tiles, not at 561; with +30% at 726, "
      "not 730; not at 20.")


def parts_tests():
    one = opreply.parts("Aurora", "@Aurora Operator: queued for an engineer.")
    assert one == ["@Aurora Operator: queued for an engineer."], one
    long = " ".join(f"Sentence {i} says what the artillery remote checks against manual range, in tiles." for i in range(9))
    ps = opreply.parts("Aurora", long)
    assert len(ps) == 2 and all(len(p.encode()) <= 500 for p in ps), [len(p.encode()) for p in ps]
    assert ps[0].startswith("@Aurora (1/2) Operator: Sentence 0") and ps[1].startswith("@Aurora (2/2) Operator: Sentence"), ps
    assert all(p.endswith("tiles.") for p in ps), ps  # cut at sentence ends
    assert [V.part_of(p) for p in ps] == [(1, 2), (2, 2)], ps
    word = opreply.parts("Aurora", "x" * 1200)
    assert all(len(p.encode()) <= 500 for p in word) and "".join(p.split(": ", 1)[1] for p in word) == "x" * 1200, word


def run_dir():
    d = tempfile.mkdtemp()
    with open(os.path.join(d, "operator-inbox.jsonl"), "w") as f:
        for t, text, extra in ((T_ART, ART, {"dropped": "clef:injection"}), (T_CHAT, CHAT, {}),
                               (T_ART - 4000, "@operator a YouTube line", {"id": "yt:abc", "source": "YouTube"})):
            f.write(json.dumps(dict({"t": t, "agent": "viewer Aurora", "text": text, "viewer": True, "source": "site"}, **extra)) + "\n")
        f.write(json.dumps({"t": T_CHAT, "seq": 9, "agent": "astra", "text": "an agent's request"}) + "\n")
    with open(os.path.join(d, "chat.jsonl"), "w") as f:
        for seq, text in ((18454, P1), (18456, P2)):
            f.write(json.dumps({"seq": seq, "tick": 41111361, "from": "server", "text": text, "logged_at": "2026-10-21T04:20:12"}) + "\n")
    return d


def resolve_tests(d):
    fetch = lambda url: {"messages": [{"seq": 3817, "t": 1792579908.741, "name": "Aurora", "text": ART}]}  # noqa: E731
    assert opreply.resolve("site:3817", d, fetch=fetch) == ("site:3817", "Aurora", {"text": ART, "t": 1792579908.741, "source": "site"})
    hm = datetime.datetime.fromtimestamp(T_ART).strftime("%H:%M")  # local time, as the tool reads it
    ident, name, q = opreply.resolve("Aurora@" + hm, d)
    assert name == "Aurora" and q["text"] == ART and ident == f"inbox:Aurora@{T_ART}", (ident, q)
    assert opreply.resolve("yt:abc", d)[0] == "yt:abc"


def main_tests(d):
    links = os.path.join(d, V.LINKS_NAME)
    sent = []
    opreply.resolve = (lambda real: lambda to, run, fetch=None: real(to, run, fetch=lambda url: {
        "messages": [{"seq": 3817, "t": 1792579908.741, "name": "Aurora", "text": ART}]}))(opreply.resolve)
    opreply.main(["--run", d, "--to", "site:3817", "--dry-run", "the artillery remote uses manual range."])
    assert not os.path.exists(links), "a dry run writes nothing"

    def fake_send(lines, world, port=None):
        assert os.path.exists(links) and json.loads(open(links).readlines()[-1])["parts"] == lines, "the record goes first"
        sent.append((lines, world))
    opreply.send = fake_send
    opreply.main(["--run", d, "--to", "site:3817", "--world", "n", "the artillery remote uses manual range."])
    assert sent == [(["@Aurora Operator: the artillery remote uses manual range."], "n")], sent
    # lines already sent, linked by their chat seqs (today's two-line answer)
    opreply.main(["--run", d, "--to", "site:3817", "--sent", "18454", "18456"])
    rec = json.loads(open(links).readlines()[-1])
    assert rec["to"] == "site:3817" and rec["parts"] == [P1, P2] and rec["sent"] == [18454, 18456] and len(sent) == 1, rec
    return links


def model_tests(d, links):
    """model.py as serve.py runs it, and again as a restart reads the chat: each part answers site:3817."""
    import model
    def run(with_links, restored):
        m = model.Model({"agents": {n: {} for n in ("luna", "astra")}})
        m.set_inbox(os.path.join(d, "operator-inbox.jsonl"))
        if with_links:
            m.set_reply_links(links)
        m.tick = 41111400
        for seq, text in ((18454, P1), (18456, P2)):
            m._ingest_chat({"seq": seq, "tick": 41111361, "from": "server", "text": text, "t": T_CHAT + 783}, T_CHAT + 783, restored=restored)
        return [r for r in m.viewer_replies if r["by"] == "operator"]
    old = run(False, False)
    assert [r["answers"]["text"] for r in old] == [V.bare(CHAT)] * 2 and [r["link"] for r in old] == ["only_line"] * 2, old
    for restored in (False, True):
        rows = run(True, restored)
        assert [r["answers"]["id"] for r in rows] == ["site:3817"] * 2 and [r["link"] for r in rows] == ["reply_to"] * 2, rows
        assert [r["part"] for r in rows] == [[1, 2], [2, 2]] and rows[0]["answers"]["text"] == V.bare(ART), rows
    # the archived shift pages' path (longrun.py): replies() with the run's links
    out = V.replies([{"seq": 18454, "from": "server", "text": P1, "t": T_CHAT + 783}], inbox=V.read_inbox(os.path.join(d, "operator-inbox.jsonl")),
                    links=V.read_links(links))
    assert out[0][1]["answers"]["id"] == "site:3817", out
    import push_live
    pub = push_live.public_replies(rows)
    assert pub[0]["answers"]["id"] == "site:3817" and pub[0]["part"] == [1, 2] and pub[1]["part"] == [2, 2], pub
    # an fh say's numbered parts show their part too; a lone line none
    r = V.row({"seq": 1, "t": 1, "from": "luna", "text": "@Aurora (2/3) more"}, {"kind": "reply", "to": ["Aurora"], "answers": None})
    assert r["part"] == [2, 3] and "part" not in V.row({"seq": 2, "t": 1, "from": "luna", "text": "@Aurora ok"}, {"kind": "reply", "to": []}), r
    return pub[0]


def bare_and_page_tests(reply_row):
    assert V.bare("@Muse @Luna Could defense lessons use live turret stats?") == "Could defense lessons use live turret stats?"
    if not shutil.which("node"):
        print("opreply: live.js part skipped (no node)")
        return
    code = open(os.path.join(ROOT, "site", "static", "live.js")).read()
    fn = code[code.index("  function bareText(s)"):code.index("  function joinedChat()")]
    lst = [{"src": "site", "seq": 3817, "name": "Aurora", "text": ART, "t": T_ART},
           {"src": "site", "seq": 3824, "name": "Aurora", "text": CHAT, "t": T_CHAT},
           {"src": "site", "seq": 3831, "name": "Aurora", "text": "@Muse @Luna Could defense lessons use live turret stats?", "t": T_CHAT + 870}]
    luna = {"t": T_CHAT + 900, "answers": {"name": "Aurora", "text": "@Luna Could defense lessons use live turret stats?"}}
    js = fn + "\nprocess.stdout.write(JSON.stringify([answered(" + json.dumps(lst) + ", " + json.dumps(reply_row) + "), answered(" + \
        json.dumps(lst) + ", " + json.dumps(dict(reply_row, answers=dict(reply_row["answers"], text=CHAT))) + "), answered(" + \
        json.dumps(lst) + ", " + json.dumps(luna) + ")]));"
    r = subprocess.run(["node", "-e", js], capture_output=True, text=True, timeout=10)
    assert r.returncode == 0, r.stderr
    # by id (also when its text would name another line); "@Muse @Luna ..." found from the relay's "@Luna ..."
    assert json.loads(r.stdout) == [0, 0, 2], r.stdout


def main():
    parts_tests()
    d = run_dir()
    resolve_tests(d)
    links = main_tests(d)
    bare_and_page_tests(model_tests(d, links))
    print("opreply: ok (parts at 500 bytes, --to forms, the record before the send, --sent; each part answers the named line, "
          "at a restart too, with part k of n; the payload and the site keep the id)")


if __name__ == "__main__":
    main()
