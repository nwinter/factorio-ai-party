#!/usr/bin/env python3
"""A viewer's reply and its Updates row in one call (d24 batch180 QW1, viewer Aurora 17:32, site:4789: "Could chat
acknowledgements and Updates share one batch record? Show accepted work as Planned, then In progress when started.").
No game, no network: python3 tools/test_opreply_updates.py

- tools/opreply.py --update ID: the reply is sent and the row added (planned, dated, the viewer and site:N as who asked)
  in one call; moved to in progress with --work; refused before anything is sent when it would go backwards, when a
  status past planned has no work, or when a new row has no title.
- tools/operator_updates.py add --ref '#NNNN' with no --by: the asker from the board.
- /updates/: accepted work (in progress, planned) in a section apart from live rows, with its dates.
"""
import datetime, html, json, os, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "stream"))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "site"))
sys.dont_write_bytecode = True
import opreply  # noqa: E402
import operator_updates as ou  # noqa: E402
import updates  # noqa: E402

T_ASKED = 1792888320.0  # 2026-10-24 17:32 Pacific: site:4789


def refused(fn, text):
    try:
        fn()
    except SystemExit as e:
        assert text in str(e), str(e)
        return str(e)
    raise AssertionError(f"not refused: {text}")


def upsert_tests():
    data = {"updates": [], "notices": []}
    refused(lambda: ou.upsert(data, "one-step", "planned"), "one-step: no such update yet: give --title")
    refused(lambda: ou.upsert(data, "one-step", "planned", title="x", area="moon"), "area 'moon' is not one of harness, stream, site")
    refused(lambda: ou.upsert(data, "one-step", "in progress", title="x"), "one-step: in progress needs --work")
    said = ou.upsert(data, "one-step", "planned", title="Replies and Updates in one step", area="site", name="Aurora",
                     ref="site:4789", asked="2026-10-24 17:32", at="2026-10-24 17:55")
    assert said == "one-step: added one-step: planned 2026-10-24 17:55; asked by Aurora (site:4789)", said
    u = data["updates"][0]
    assert u["status"] == "planned" and u["dates"] == {"asked": "2026-10-24 17:32", "planned": "2026-10-24 17:55"}, u
    assert u["requested_by"] == [{"name": "Aurora", "ref": "site:4789"}] and "work" not in u, u
    # a second asker on the same row: added once; the status kept
    said = ou.upsert(data, "one-step", "planned", name="Foobator", ref="site:4791", at="2026-10-24 18:00")
    assert said == "one-step: still planned; asked by Foobator (site:4791)", said
    ou.upsert(data, "one-step", "planned", name="Foobator", ref="site:4791", at="2026-10-24 18:01")
    assert len(u["requested_by"]) == 2 and u["dates"]["planned"] == "2026-10-24 17:55", u
    # started: in progress with the batch, dated; then back to planned is refused
    said = ou.upsert(data, "one-step", "in progress", work="batch180 QW1", at="2026-10-24 18:10")
    assert said == "one-step: work batch180 QW1; planned -> in progress 2026-10-24 18:10", said
    assert u["dates"]["in progress"] == "2026-10-24 18:10" and u["work"] == "batch180 QW1", u
    refused(lambda: ou.upsert(data, "one-step", "planned"), "one-step is in progress (since 2026-10-24 18:10): planned would go backwards")
    return data


def opreply_tests():
    run = tempfile.mkdtemp()
    open(os.path.join(run, "chat.jsonl"), "w").close()
    upath = os.path.join(run, "operator-updates.json")
    ou.write(upath, {"updates": [{"id": "old", "title": "Old", "status": "live", "work": "batch1", "dates": {"live": "2026-10-23 10:00"}}],
                     "notices": []})
    sent = []
    opreply.site_line = lambda seq, api=None, fetch=None: {"name": "Aurora", "text": "Could chat acknowledgements and Updates share one batch record?", "t": T_ASKED}
    opreply.send = lambda lines, world, port=None: sent.extend(lines)
    replies = os.path.join(run, "operator-replies.jsonl")

    def call(*extra):
        return opreply.main(["--run", run, "--updates-file", upath, "--to", "site:4789", *extra])

    def rows():
        return {u["id"]: u for u in updates.load(upath)["updates"]}
    # refused before anything goes: no title for a new row; in progress with no work; nothing sent, nothing written
    before = open(upath).read()
    refused(lambda: call("--update", "one-step", "accepted"), "one-step: no such update yet: give --title")
    refused(lambda: call("--update", "one-step", "--title", "T", "--status", "in progress", "accepted"), "in progress needs --work")
    assert not sent and not os.path.exists(replies) and open(upath).read() == before
    # accepted: the reply sent, the record written, the row planned with the viewer and site:4789, asked at the line's time
    assert call("--update", "one-step", "--title", "Replies and Updates in one step", "--area", "site",
                "accepted: one record for a reply and its Updates row") == 0
    assert sent == ["@Aurora Operator: accepted: one record for a reply and its Updates row"], sent
    rec = [json.loads(x) for x in open(replies)]
    assert len(rec) == 1 and rec[0]["to"] == "site:4789", rec
    u = rows()["one-step"]
    assert u["status"] == "planned" and u["requested_by"] == [{"name": "Aurora", "ref": "site:4789"}], u
    assert u["dates"]["asked"] == "2026-10-24 17:32" and updates.when(u["dates"]["planned"]), u
    # started, in the same kind of call; a dry run writes nothing
    sent.clear()
    assert call("--update", "one-step", "--status", "in progress", "--work", "batch180", "--dry-run", "started") == 0
    assert not sent and rows()["one-step"]["status"] == "planned"
    assert call("--update", "one-step", "--status", "in progress", "--work", "batch180", "started: batch180") == 0
    u = rows()["one-step"]
    assert u["status"] == "in progress" and u["work"] == "batch180" and updates.when(u["dates"]["in progress"]), u
    # backwards: refused, nothing sent
    sent.clear()
    refused(lambda: call("--update", "one-step", "planned again"), "planned would go backwards")
    refused(lambda: call("--update", "old", "x"), "old is live (since 2026-10-23 10:00): planned would go backwards")
    assert not sent and len(open(replies).read().splitlines()) == 2
    # the flags go with --update only
    refused(lambda: opreply.main(["--run", run, "--to", "site:4789", "--title", "T", "x"]), "2")
    return upath


def board_tests():
    item = {"item": {"id": 2241, "requested_by": "astra", "owner": "operator"}}
    calls = []
    assert ou.board_asker("#2241", dispatch=lambda a, x: calls.append((a, x)) or item) == "astra" and calls == [("board", {"id": 2241})]
    assert ou.board_asker("#7", dispatch=lambda a, x: {"item": {"id": 7, "owner": "sol"}}) == "sol"
    refused(lambda: ou.board_asker("#8", dispatch=lambda a, x: {"item": {"id": 8}}), "--ref #8: the board read gave no requested_by or owner")
    f = os.path.join(tempfile.mkdtemp(), "u.json")
    ou.write(f, {"updates": [], "notices": []})
    real = ou.board_asker
    ou.board_asker = lambda ref, world=None, dispatch=None: {"#2241": "astra"}[ref]
    try:
        ou.main(["--file", f, "add", "ammo-scope", "--title", "Scoped ammo guard", "--ref", "#2241"])
        refused(lambda: ou.main(["--file", f, "add", "x", "--title", "X", "--ref", "site:1"]), "--ref site:1 needs its --by")
        ou.main(["--file", f, "add", "two", "--title", "Two", "--by", "Aurora", "--ref", "site:4789", "--ref", "#2241"])
    finally:
        ou.board_asker = real
    got = {u["id"]: u for u in updates.load(f)["updates"]}
    assert got["ammo-scope"]["requested_by"] == [{"name": "astra", "ref": "#2241"}], got
    assert got["two"]["requested_by"] == [{"name": "Aurora", "ref": "site:4789"}, {"name": "astra", "ref": "#2241"}], got


def page_tests(upath):
    data = updates.load(upath)
    esc = lambda s: html.escape(str(s), quote=True)  # noqa: E731
    data["updates"].append({"id": "queued", "title": "Queued", "status": "planned", "dates": {"planned": "2026-10-24 18:20"}})
    body, _ = updates.build_page(data, {}, {}, esc)
    at = [body.index(x) for x in ('<h2 id="open">Accepted: planned and in progress</h2>', '<h3 id="in-progress"', 'id="u-one-step"',
                                  '<h3 id="planned"', 'id="u-queued"', '<h2 id="live-unverified">Live, not verified yet</h2>',
                                  '<h3 id="live"', 'id="u-old"', '<h2 id="verified"')]
    assert at == sorted(at), at
    one = body[body.index('id="u-one-step"'):body.index("</li>", body.index('id="u-one-step"'))]
    # planned and in progress carry the day the test runs (operator_updates.now_text); the gate failed on 25 Oct with them fixed at 24 Oct
    today = datetime.datetime.now(updates.PACIFIC).strftime("%a %d %b")
    assert f"asked Sat 24 Oct 17:32 · planned {today}" in one and f"in progress {today}" in one and "batch180" in one, one
    q = body[body.index('id="u-queued"'):body.index("</li>", body.index('id="u-queued"'))]
    assert "planned Sat 24 Oct 18:20" in q, q
    assert 'id="upd-none-open" hidden' in body and 'id="upd-none-live" hidden' in body, body
    # nothing accepted: said in its section; the live section still lists the live row
    data["updates"] = [u for u in data["updates"] if u["status"] == "live"]
    body, _ = updates.build_page(data, {}, {}, esc)
    assert '<p class="muted" id="upd-none-open">Nothing accepted waits.</p>' in body and 'id="upd-none-live" hidden' in body, body


def main():
    upsert_tests()
    upath = opreply_tests()
    board_tests()
    page_tests(upath)
    print("opreply updates: ok (one call answers and adds or moves the row; refusals send nothing; the board's asker; "
          "accepted work apart from live on /updates/)")


if __name__ == "__main__":
    main()
