#!/usr/bin/env python3
"""Backlog reviews on the Updates page (d26 batch235 UR, viewer Aurora site:5022: "Could accepted work get regular
backlog reviews after recovery and long jobs? Keep its original ID, priority, owner and next review so older requests
need no repeat viewer nudge."): python3 tools/test_backlog_review.py

Checks, on a temp copy (never site/content/operator-updates.json) and with every time given (no clock):
- add and set take --priority, --owner (a role; a person's name or an account refused) and --next-review (+4h, a date);
  set --owner keeps the owner it replaces in owner_history; a re-plan keeps the first planned date (replanned); the id,
  the asked date and who asked stay;
- due --now lists the open rows whose next review passed or that have none, oldest asked first, each with its id, who
  asked, priority, owner, status and how long since it changed; not a live row, not one reviewed for later;
- reviewed stamps the row and the file's backlog_reviewed and sets the next review (--next, else by priority); a live
  row is refused;
- the page: each open row's priority, owner (and before), next review (due at the build), last review; the backlog line
  at the top and in updates.json; an old row without the fields renders; load() refuses a bad priority, owner or time;
  the owner check refuses every name build.py's _BLOCKED keeps off the site.
"""
import html, json, re, subprocess, sys, tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "site"))
import updates  # noqa: E402

TOOL = REPO / "tools" / "operator_updates.py"


def esc(s):
    return html.escape(str(s), quote=True)


def main():
    with tempfile.TemporaryDirectory() as d:
        f = str(Path(d) / "u.json")
        assert Path(f).resolve() != (REPO / "site" / "content" / "operator-updates.json").resolve()

        def run(*a):
            return subprocess.run([sys.executable, str(TOOL), "--file", f, *a], capture_output=True, text=True)

        def rows():
            return {u["id"]: u for u in updates.load(f)["updates"]}

        def ok(*a):
            r = run(*a)
            assert r.returncode == 0, (a, r.stdout, r.stderr)
            return r.stdout.strip()

        ok("add", "old-ask", "--title", "Old ask", "--by", "Aurora", "--ref", "site:4400", "--asked", "2026-10-23 08:00",
           "--at", "2026-10-23 09:00", "--priority", "urgent", "--owner", "engineer batch228", "--next-review", "+4h")
        ok("add", "new-ask", "--title", "New ask", "--by", "Sol", "--ref", "#2400", "--asked", "2026-10-25 08:00", "--at", "2026-10-25 09:00")
        ok("add", "later-ask", "--title", "Later ask", "--by", "Aurora", "--ref", "site:4500", "--asked", "2026-10-24 08:00",
           "--at", "2026-10-24 09:00", "--priority", "later", "--next-review", "2026-10-30 12:00")
        ok("add", "done-ask", "--title", "Done ask", "--by", "Aurora", "--status", "live", "--work", "batch200", "--at", "2026-10-24 10:00")
        u = rows()["old-ask"]
        assert (u["priority"], u["owner"], u["next_review"]) == ("urgent", "engineer batch228", "2026-10-23 13:00"), u
        # refused, the file unchanged: a person's name or an account as owner, an unknown priority, a bad next review
        before = Path(f).read_text()
        for bad in (["--owner", "Nick"], ["--owner", "nick winter"], ["--owner", "claude-b session"], ["--owner", "a@b.example"],
                    ["--owner", "x" * 81], ["--owner", " "], ["--priority", "high"], ["--next-review", "tomorrow"], ["--next-review", "+4w"]):
            r = run("set", "old-ask", *bad, "--at", "2026-10-25 10:00")
            assert r.returncode != 0, (bad, r.stdout)
        assert Path(f).read_text() == before
        # the work changes hands and is re-planned: the id, the asked date and who asked stay; the first planned date too
        out = ok("set", "old-ask", "--status", "in progress", "--work", "batch228 W1", "--at", "2026-10-24 09:00")
        out = ok("set", "old-ask", "--owner", "engineer batch233", "--priority", "normal", "--at", "2026-10-25 11:00")
        assert out == "old-ask: priority normal; owner engineer batch233", out
        out = ok("set", "old-ask", "--status", "planned", "--at", "2026-10-25 12:00")
        assert out == "old-ask: planned again 2026-10-25 12:00 (first planned 2026-10-23 09:00)", out
        u = rows()["old-ask"]
        assert u["id"] == "old-ask" and u["requested_by"] == [{"name": "Aurora", "ref": "site:4400"}], u
        assert u["dates"] == {"asked": "2026-10-23 08:00", "planned": "2026-10-23 09:00", "in progress": "2026-10-24 09:00",
                              "replanned": "2026-10-25 12:00"}, u["dates"]
        assert u["owner_history"] == [{"owner": "engineer batch228", "until": "2026-10-25 11:00"}] and u["owner"] == "engineer batch233", u
        assert updates.stage(u) == updates.when("2026-10-25 12:00")
        # due: open rows past their review or with none, oldest asked first; not live, not the one reviewed for the 30th
        lines = ok("due", "--now", "2026-10-26 10:30").splitlines()
        assert lines[0] == "due: 2 of 3 open rows at 2026-10-26 10:30 (next review passed or none), oldest asked first", lines
        assert lines[1].split()[0] == "old-ask" and lines[2].split()[0] == "new-ask", lines
        assert ("[Aurora site:4400]  priority normal  owner engineer batch233  planned  changed 22 h 30 min ago"
                "  review due since 2026-10-23 13:00  asked 2026-10-23 08:00") in lines[1], lines[1]
        assert "[Sol #2400]  priority not set  owner not set  planned  changed 1 d 1 h ago  review never set" in lines[2], lines[2]
        assert not any("later-ask" in x or "done-ask" in x for x in lines), lines
        assert ok("due", "--now", "2026-10-30 12:00").startswith("due: 3 of 3 open rows")
        # reviewed: the next review from --next, else by priority (normal 24 h, later 72 h); a note goes in as usual
        out = ok("reviewed", "old-ask", "--next", "+4h", "--note", "Waits for batch233.", "--at", "2026-10-26 10:40")
        assert out == "old-ask: reviewed 2026-10-26 10:40; next review 2026-10-26 14:40; note set", out
        ok("reviewed", "new-ask", "--at", "2026-10-26 10:41")
        ok("reviewed", "later-ask", "--at", "2026-10-26 10:42")
        ok("reviewed", "later-ask", "--next", "2026-10-28 09:00", "--at", "2026-10-26 10:43")
        r = rows()
        assert (r["old-ask"]["reviewed"], r["old-ask"]["next_review"], r["old-ask"]["note"]) == ("2026-10-26 10:40", "2026-10-26 14:40", "Waits for batch233."), r["old-ask"]
        assert r["new-ask"]["next_review"] == "2026-10-27 10:41" and r["later-ask"]["next_review"] == "2026-10-28 09:00", r
        assert updates.load(f)["backlog_reviewed"] == "2026-10-26 10:43"
        assert run("reviewed", "done-ask", "--at", "2026-10-26 10:44").returncode != 0
        assert run("reviewed", "nope", "--at", "2026-10-26 10:44").returncode != 0
        assert ok("due", "--now", "2026-10-26 11:00").startswith("due: 0 of 3 open rows")
        assert ok("due", "--now", "2026-10-26 15:00").splitlines()[1].split()[0] == "old-ask"
        # the page: an open row's review line, the backlog line; a live row has none; an old row without the fields renders
        data = updates.load(f)
        data["updates"].append({"id": "bare", "title": "Bare", "status": "in progress", "work": "batch100", "dates": {"in progress": "2026-10-20 10:00"}})
        built = updates.when("2026-10-26 15:00")
        body, _ = updates.build_page(data, {}, {}, esc, built=built)
        li = {m.group(1): m.group(0) for m in re.finditer(r'<li class="upd" [^>]*id="u-([^"]+)".*?</li>', body, re.S)}
        assert ('<p class="small upd-review"><span class="fx-chip fx-chip--blue upd-priority">normal</span> · Owner engineer batch233'
                ' <span class="muted">(before: engineer batch228)</span> · Next review Mon 26 Oct 14:40 <span class="upd-flag upd-due">due</span>'
                ' · <span class="muted">last reviewed Mon 26 Oct 10:40</span></p>') in li["old-ask"], li["old-ask"]
        assert "planned again Sun 25 Oct 12:00" in li["old-ask"], li["old-ask"]
        assert "Next review Wed 28 Oct 09:00 · " in li["later-ask"] and "upd-due" not in li["later-ask"], li["later-ask"]
        assert "upd-review" not in li["done-ask"], li["done-ask"]
        assert ('<span class="muted">no priority set</span> · <span class="muted">no owner set</span> · <span class="muted">no review set</span>'
                in li["bare"]), li["bare"]
        line = "Backlog last reviewed Mon 26 Oct 10:43; 4 rows open (planned or in progress), 2 due for review at this build."
        assert f'<p class="small upd-backlog" id="upd-backlog">{line}</p>' in body, body[:1500]
        assert updates.updates_json(data, {}, {}, esc, built=built)["backlog"] == line
        assert updates.build_page(data, {}, {}, esc)[0].count("upd-due") == 0  # no build time: nothing said due
        # load() refuses what the tool would
        for k, v in (("priority", "high"), ("owner", "Nick"), ("next_review", "soon"), ("reviewed", "26 Oct"),
                     ("owner_history", [{"owner": "operator"}])):
            bad = json.loads(Path(f).read_text())
            bad["updates"][0][k] = v
            g = Path(d) / "bad.json"
            g.write_text(json.dumps(bad))
            try:
                updates.load(g)
                raise AssertionError(f"load took {k}={v!r}")
            except ValueError:
                pass
        bad = json.loads(Path(f).read_text())
        bad["backlog_reviewed"] = "today"
        g.write_text(json.dumps(bad))
        try:
            updates.load(g)
            raise AssertionError("load took backlog_reviewed=today")
        except ValueError:
            pass
    # the owner check refuses every name the build keeps off the site (build.py _BLOCKED), and takes roles
    src = (REPO / "site" / "build.py").read_text()
    pat = re.search(r'_BLOCKED = re\.compile\(r"(.*?)"\)', src).group(1)
    names = re.findall(r"[A-Za-z][A-Za-z-]+", pat.replace("(?i:", "").replace("\\b", " "))
    assert len(names) >= 7, names  # the account and tool names (the owner's name left the list d27)
    for n in names:
        assert not updates.owner_ok(f"engineer {n}") and not updates.owner_ok(f"engineer {n.lower()}"), n
    for role in ("operator", "engineer batch233", "analyst", "the stream's owner"):
        assert updates.owner_ok(role), role
    print("backlog review: ok (priority, owner and next review on add and set, owner history and re-plans keep the first "
          "dates, due oldest asked first, reviewed sets the next one, the page's review lines and backlog line, roles only)")


if __name__ == "__main__":
    main()
