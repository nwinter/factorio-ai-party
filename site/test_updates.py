#!/usr/bin/env python3
"""Operator updates (d23 batch119 CB4, viewer Aurora site:4349: "an Operator updates section with a permanent history of
harness and site changes, their current status, and links to the original messages"; site:4350: "distinguish planned,
in progress, live and verified updates, keep unresolved items visible, and separate automatic status notices from
change announcements"): python3 site/test_updates.py

Checks: site/content/operator-updates.json loads; load() refuses a row without a status, a repeated id, an unknown date
key or a badly written date, and a notice without a kind; messages() quotes each site:NNNN message from the operator
inbox (the first copy, redacted, hidden viewers and the owner's lines left out) and the operator's replies to it,
oldest first; the page puts the counts first, then what is not verified (in progress, planned, live), then the
verified ones newest first, then the notices on their own; tools/operator_updates.py adds rows, moves them on with
their dates and adds notices (times given, no clock), and refuses what the build would; build.py writes /updates/ and
links it in the nav. (d23, viewer Aurora 18:46: "Could superseded queue notes become dated history, so each card's
current status and note agree?") set --note keeps the note it replaces as dated history, folded under the current
note; a note written under another status says so; a status past planned needs work: the tool refuses one without it,
problems() and the page flag one already in the data.
"""
import html, json, os, re, subprocess, sys, tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import updates  # noqa: E402
import moderation  # noqa: E402

REPO = HERE.parent
TOOL = REPO / "tools" / "operator_updates.py"


def esc(s):
    return html.escape(str(s), quote=True)


def clean(t):
    return re.sub(r"[\w.+-]+@[\w-]+\.[\w.-]+", "[email]", t)


def keep(t):
    return not re.search(r"(?i)\bnick\b", t)


def repo_data():
    d = updates.load(HERE / "content" / "operator-updates.json")
    assert len(d["updates"]) >= 20 and d["notices"], d
    statuses = {u["status"] for u in d["updates"]}
    # (d23 14:25) the live data, not a fixture: the operator moves rows on, so a status may have none (the empty
    # section is a plain chip, batch119b); every row's status must still be a known one
    assert statuses <= set(updates.STATUSES), statuses
    assert "site:4349" in updates.refs(d["updates"]) and "site:4407" in updates.refs(d["updates"])


def refusals():
    bad = [
        {"updates": [{"id": "a", "title": "x"}]},
        {"updates": [{"id": "a", "title": "x", "status": "live"}, {"id": "a", "title": "y", "status": "live"}]},
        {"updates": [{"id": "a", "title": "x", "status": "live", "dates": {"deployed": "2026-10-22 20:18"}}]},
        {"updates": [{"id": "a", "title": "x", "status": "live", "dates": {"live": "22 Oct 20:18"}}]},
        {"updates": [{"id": "a", "title": "x", "status": "live", "area": "game"}]},
        {"updates": [], "notices": [{"t": "2026-10-22 20:18", "text": "deployed"}]},
        {"updates": [{"id": "a", "title": "x", "status": "live", "history": [{"note": "old"}]}]},
        {"updates": [{"id": "a", "title": "x", "status": "live", "history": [{"until": "2026-10-23 18:52", "note": ""}]}]},
        {"updates": [{"id": "a", "title": "x", "status": "live", "history": [{"until": "2026-10-23 18:52", "note": "o", "status": "done"}]}]},
        {"updates": [{"id": "a", "title": "x", "status": "live", "history": "old"}]},
        {"updates": [{"id": "a", "title": "x", "status": "live", "note_at": "18:52"}]},
        {"updates": [{"id": "a", "title": "x", "status": "live", "note_status": "queued"}]},
    ]
    with tempfile.TemporaryDirectory() as d:
        for i, data in enumerate(bad):
            p = Path(d) / f"{i}.json"
            p.write_text(json.dumps(data))
            try:
                updates.load(p)
            except ValueError:
                continue
            raise AssertionError(f"accepted {data}")


def fixture_runs(d):
    for run, inbox, replies in (
            ("shift61", [{"t": 1792737530.6, "agent": "viewer Aurora", "id": "site:4347", "source": "site",
                          "text": "@Operator Could the board separate owner activity? mail me at a@b.example"},
                         {"t": 1792737600.0, "agent": "viewer Troll", "id": "site:4348", "text": "hidden line"},
                         {"t": 1792737700.0, "agent": "viewer Pat", "id": "site:4349", "text": "Nick should look"}],
             [{"t": 1792766000.0, "to": "site:4347", "parts": ["@Aurora (1/2) Operator: in progress.", "@Aurora (2/2) Operator: soon."]}]),
            ("shift62", [{"t": 1792737530.6, "agent": "viewer Aurora", "id": "site:4347", "text": "a later copy"}],
             [{"t": 1792700000.0, "to": "site:4347", "parts": ["@Aurora Operator: an earlier reply."]},
              {"t": 1792700000.0, "to": "site:9999", "parts": ["not asked for"]}])):
        p = Path(d) / run
        p.mkdir()
        (p / "operator-inbox.jsonl").write_text("".join(json.dumps(r) + "\n" for r in inbox) + "not json\n")
        (p / "operator-replies.jsonl").write_text("".join(json.dumps(r) + "\n" for r in replies))
    hidden = moderation.Hidden()
    hidden.add_text("Troll", "hidden line")
    return hidden


def messages():
    with tempfile.TemporaryDirectory() as d:
        hidden = fixture_runs(d)
        asks, replies = updates.messages(d, {"site:4347", "site:4348", "site:4349"}, clean, keep, hidden)
    assert set(asks) == {"site:4347"}, asks  # a hidden viewer's line and the owner's name left out
    a = asks["site:4347"]
    assert a["name"] == "Aurora" and a["text"].endswith("mail me at [email]") and a["at"].strftime("%H:%M") == "23:38", a
    assert [r["text"] for r in replies["site:4347"]] == ["@Aurora Operator: an earlier reply.",
                                                        "@Aurora (1/2) Operator: in progress. @Aurora (2/2) Operator: soon."], replies
    assert "site:9999" not in replies
    return asks, replies


def page(asks, replies):
    data = {"updates": [
        {"id": "old-verified", "title": "Old one", "status": "verified", "dates": {"live": "2026-10-21 10:00", "verified": "2026-10-21 11:00"}},
        {"id": "new-verified", "title": "New one", "status": "verified", "dates": {"verified": "2026-10-22 11:00"}},
        {"id": "owner-activity", "title": "Owner activity apart", "area": "site", "status": "in progress", "work": "batch119 CB3",
         "requested_by": [{"name": "Aurora", "ref": "site:4347"}], "dates": {"in progress": "2026-10-23 07:45"}, "note": "A <note>."},
        {"id": "plan-a", "title": "Planned A", "status": "planned", "requested_by": [{"name": "Sol", "ref": "#1925"}]},
        {"id": "live-a", "title": "Live A", "status": "live", "dates": {"live": "2026-10-22 20:18"}}],
        "notices": [{"t": "2026-10-22 20:18", "kind": "deploy", "text": "Runtime deployed."},
                    {"t": "2026-10-22 23:40", "kind": "outage", "text": "Operator offline."}]}
    body, _ = updates.build_page(data, asks, replies, esc)
    order = [body.index(x) for x in ('class="upd-counts"', '<h2 id="open">', '<h3 id="in-progress"', '<h3 id="planned"',
                                      '<h3 id="live"', '<h2 id="verified"', 'id="u-new-verified"', 'id="u-old-verified"',
                                      '<h2 id="notices">')]
    assert order == sorted(order), order
    assert ">planned: 1</a>" in body and ">in progress: 1</a>" in body and ">live: 1</a>" in body and ">verified: 2</a>" in body
    row = body.split('id="u-owner-activity"', 1)[1].split("</li>", 1)[0]
    assert '<span class="fx-chip fx-chip--orange upd-status">in progress</span> <span class="fx-chip fx-chip--grey upd-area">site</span>' in row, row
    assert 'Asked by Aurora <span class="muted">(site:4347)</span> · batch119 CB3' in row and "A &lt;note&gt;." in row, row
    assert "asked Thu 22 Oct 23:38 · in progress Fri 23 Oct 07:45" in row, row
    assert "<summary>The original message and the operator&#x27;s replies</summary>" in row, row
    assert "mail me at [email]" in row and row.count('class="upd-reply"') == 2, row
    plan = body.split('id="u-plan-a"', 1)[1].split("</li>", 1)[0]
    assert "Asked by Sol" in plan and "<details" not in plan, plan  # a board item: no message to quote
    notices = body.split('<h2 id="notices">', 1)[1]
    assert notices.index("Operator offline.") < notices.index("Runtime deployed.") and "upd-list" not in notices, notices
    assert "Operator offline." not in body.split('<h2 id="notices">', 1)[0]
    # every in-page link has its anchor; a status with no rows is a plain chip, not a link to a section left out
    # (the 09:18 site refresh failed check.py on #planned once every planned row had moved to in progress)
    for d in ({"updates": [u for u in data["updates"] if u["status"] != "planned"], "notices": []},
              {"updates": [u for u in data["updates"] if u["status"] == "verified"], "notices": []},
              {"updates": [], "notices": []}):
        b, _ = updates.build_page(d, asks, replies, esc)
        ids = set(re.findall(r'id="([^"]+)"', b))
        missing = [h for h in re.findall(r'href="#([^"]+)"', b) if h not in ids]
        assert not missing, (missing, b)
    b, _ = updates.build_page({"updates": [u for u in data["updates"] if u["status"] != "planned"], "notices": []}, asks, replies, esc)
    assert '<span class="fx-chip fx-chip--grey upd-count">planned: 0</span>' in b and 'id="planned"' not in b, b
    # past planned with no work: flagged on the page and by problems(), built anyway; planned needs none
    live = body.split('id="u-live-a"', 1)[1].split("</li>", 1)[0]
    assert '<span class="upd-flag">no batch recorded</span>' in live, live
    assert "upd-flag" not in plan and "upd-flag" not in row, (plan, row)
    assert sorted(updates.problems(data)) == sorted(["operator update old-verified: verified with no work (batch)",
                                                     "operator update new-verified: verified with no work (batch)",
                                                     "operator update live-a: live with no work (batch)"]), updates.problems(data)
    # the current note with its date; one written under another status says which; earlier notes folded, newest first
    hist = {"updates": [
        {"id": "scan-labels", "title": "Scans", "status": "live", "work": "batch121", "note": "Counts apart.",
         "note_at": "2026-10-23 18:52", "note_status": "live",
         "history": [{"until": "2026-10-23 08:16", "note": "Queued.", "status": "planned"},
                     {"from": "2026-10-23 08:16", "until": "2026-10-23 18:52", "note": "Received; not yet given to an engineer.", "status": "in progress"}]},
        {"id": "stale", "title": "Stale", "status": "live", "work": "batch1", "note": "Being worked on.", "note_at": "2026-10-23 09:00", "note_status": "in progress"},
        {"id": "legacy", "title": "Legacy", "status": "live", "work": "batch2", "note": "Old style."}], "notices": []}
    b, _ = updates.build_page(hist, {}, {}, esc)
    r1 = b.split('id="u-scan-labels"', 1)[1].split("</li>\n", 1)[0].split('<li class="upd"', 1)[0]
    assert '<p class="small upd-note">Counts apart. <span class="muted">(Fri 23 Oct 18:52)</span></p>' in r1, r1
    assert '<details class="upd-history"><summary>Earlier notes (2)</summary>' in r1, r1
    assert r1.index("Fri 23 Oct 08:16 to Fri 23 Oct 18:52, while in progress:") < r1.index("until Fri 23 Oct 08:16, while planned:"), r1
    assert "Received; not yet given to an engineer." in r1 and r1.index("upd-note") < r1.index("upd-history"), r1
    r2 = b.split('id="u-stale"', 1)[1].split('<li class="upd"', 1)[0]
    assert '<span class="muted">Note from when it was in progress, Fri 23 Oct 09:00:</span> Being worked on.</p>' in r2, r2
    r3 = b.split('id="u-legacy"', 1)[1].split('<li class="upd"', 1)[0]
    assert '<p class="small upd-note">Old style.</p>' in r3 and "upd-history" not in r3, r3
    assert updates.problems(hist) == []


def tool():
    with tempfile.TemporaryDirectory() as d:
        f = str(Path(d) / "u.json")
        run = lambda *a: subprocess.run([sys.executable, str(TOOL), "--file", f, *a], capture_output=True, text=True)  # noqa: E731
        r = run("add", "scan-labels", "--title", "Scans label slots apart", "--by", "Aurora", "--ref", "site:4362",
                "--area", "harness", "--asked", "2026-10-23 01:45")
        assert r.returncode == 0, r.stderr
        r = run("set", "scan-labels", "--status", "in progress", "--work", "batch121 CC1", "--at", "2026-10-23 09:00")
        assert r.returncode == 0 and "in progress 2026-10-23 09:00" in r.stdout, r
        r = run("set", "scan-labels", "--status", "live", "--reply", "site:4500", "--at", "2026-10-23 12:00")
        assert r.returncode == 0, r.stderr
        assert run("notice", "--kind", "deploy", "--text", "Runtime deployed.", "--at", "2026-10-23 12:00").returncode == 0
        d1 = updates.load(f)
        u = d1["updates"][0]
        assert u == {"id": "scan-labels", "title": "Scans label slots apart", "area": "harness",
                     "requested_by": [{"name": "Aurora", "ref": "site:4362"}], "status": "live", "replies": ["site:4500"],
                     "dates": {"asked": "2026-10-23 01:45", "in progress": "2026-10-23 09:00", "live": "2026-10-23 12:00"},
                     "work": "batch121 CC1"}, u
        assert d1["notices"] == [{"t": "2026-10-23 12:00", "kind": "deploy", "text": "Runtime deployed."}]
        assert "live         scan-labels" in run("list").stdout
        # refused: a second add of the id, a bad time, an unknown status; the file stays as it was
        before = Path(f).read_text()
        assert run("add", "scan-labels", "--title", "again", "--by", "x").returncode != 0
        assert run("set", "scan-labels", "--status", "verified", "--at", "noon").returncode != 0
        assert run("set", "scan-labels", "--status", "deployed").returncode != 0
        assert run("set", "nope", "--status", "live", "--at", "2026-10-23 12:00").returncode != 0
        assert Path(f).read_text() == before
        assert Path(f).read_text().count("\n") == 9, Path(f).read_text()  # one row a line, and notices_checked
        # a status past planned needs work: refused without it when the row has none
        assert run("add", "nobatch", "--title", "x", "--by", "Aurora", "--status", "live").returncode != 0
        assert Path(f).read_text() == before
        assert run("add", "queued", "--title", "Queued one", "--by", "Aurora", "--note", "Queued, unassigned.",
                   "--at", "2026-10-23 08:16").returncode == 0
        r = run("set", "queued", "--status", "in progress", "--at", "2026-10-23 09:00")
        assert r.returncode != 0 and "in progress needs --work" in r.stderr, r
        # set --note: the note it replaces goes into history, dated, with its status then
        r = run("set", "queued", "--status", "in progress", "--work", "batch130 CL1", "--note", "With an engineer.", "--at", "2026-10-23 09:00")
        assert r.returncode == 0 and r.stdout.strip() == "queued: in progress 2026-10-23 09:00; note set; the one it replaced is in history (1)", r
        r = run("set", "queued", "--status", "live", "--at", "2026-10-23 12:00")
        assert r.returncode == 0 and r.stdout.strip() == "queued: live 2026-10-23 12:00; note kept, written while in progress", r
        r = run("set", "queued", "--note", "Live: scans count slots.", "--at", "2026-10-23 12:05")  # a note alone
        assert r.returncode == 0, r
        assert run("set", "queued", "--note", "Live: scans count slots.", "--at", "2026-10-23 12:06").stdout.strip() == "queued: updated"
        assert run("set", "queued").returncode != 0
        q = next(u for u in updates.load(f)["updates"] if u["id"] == "queued")
        assert q["status"] == "live" and q["dates"] == {"planned": "2026-10-23 08:16", "in progress": "2026-10-23 09:00", "live": "2026-10-23 12:00"}, q
        assert (q["note"], q["note_at"], q["note_status"]) == ("Live: scans count slots.", "2026-10-23 12:05", "live"), q
        assert q["history"] == [
            {"until": "2026-10-23 09:00", "note": "Queued, unassigned.", "status": "planned", "from": "2026-10-23 08:16"},
            {"until": "2026-10-23 12:05", "note": "With an engineer.", "status": "in progress", "from": "2026-10-23 09:00"}], q
        # a row with no work already: list marks it
        data = json.loads(Path(f).read_text())
        data["updates"].append({"id": "old-live", "title": "Old live", "status": "live"})
        Path(f).write_text(json.dumps(data))
        assert "old-live" in run("list").stdout and run("list").stdout.count("(no work)") == 1, run("list").stdout


def build():
    with tempfile.TemporaryDirectory() as d:
        runs = Path(d) / "runs"
        runs.mkdir()
        out = Path(d) / "dist"
        r = subprocess.run([sys.executable, str(HERE / "build.py"), "--out", str(out), "--runs-dir", str(runs)],
                           capture_output=True, text=True, timeout=120)
        assert r.returncode == 0, r.stderr[-2000:]
        page_html = (out / "updates" / "index.html").read_text()
        assert "<h1>Operator updates</h1>" in page_html and 'id="u-operator-updates"' in page_html
        assert 'href="/updates/"' in (out / "index.html").read_text()
        r = subprocess.run([sys.executable, str(HERE / "check.py"), str(out)], capture_output=True, text=True, timeout=120)
        assert r.returncode == 0, r.stdout[-2000:] + r.stderr[-2000:]


def main():
    repo_data()
    refusals()
    asks, replies = messages()
    page(asks, replies)
    tool()
    build()
    print("operator updates: ok (the JSON checked, asks and replies quoted from the run folders, open before verified "
          "before notices, the tool's add/set/notice, notes kept as dated history, no work flagged or refused, /updates/ built "
          "and in the nav)")


if __name__ == "__main__":
    main()
