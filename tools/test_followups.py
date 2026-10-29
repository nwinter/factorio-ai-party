#!/usr/bin/env python3
"""Follow-ups on Updates rows of any status, and deferred ready work (d28 batch322 UL, viewer Aurora site:5411: "Could
unfinished promises remain actionable even when their parent batch is Live? ... Give remaining work a linked owner,
next action and review point. ... Within priority, revisit older ready work and record why it is deferred."):
python3 tools/test_followups.py

Checks, on a temp copy (never site/content/operator-updates.json) and with every time given (no clock):
- follow adds ID/1, ID/2 to a Live row with what, owner (batch322, operator; nick written as the stream's owner; a
  person's name or an account refused), next action and review (+2d or a date); follow-set changes and closes one
  (--done, --dropped, with a note); reviewed ID/N stamps it and sets the next review;
- due lists the open follow-ups past their review whatever the row's status (a Live row's included, a closed one or one
  not yet due left out), with the batch owner's row; then ready work (planned rows and open follow-ups) waiting longer
  than --ready-days, by priority, oldest first, with the newest deferred reason or "no reason"; defer records one, and
  refuses a Live row;
- follow-candidates lists a Live row's promise from its note and from an operator reply to its message (not the
  batch's own scope sentence), and a Live row's next review, writing nothing;
- the page: a Live row shows its open follow-ups (owner linked to the batch's row, next action, review, due at the
  build) and folds the closed ones; the backlog line counts open follow-ups; load() refuses a follow-up without a
  review, with a bad owner or state, or a repeated number.
"""
import html, json, subprocess, sys, tempfile
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

        def ok(*a):
            r = run(*a)
            assert r.returncode == 0, (a, r.stdout, r.stderr)
            return r.stdout.strip()

        def rows():
            return {u["id"]: u for u in updates.load(f)["updates"]}

        ok("add", "public-sync", "--title", "Public repo kept current", "--by", "Aurora", "--ref", "site:5293", "--status", "live",
           "--work", "batch272, batch290", "--at", "2026-10-27 21:31", "--note", "Live. An automatic ledger gets a design first.")
        ok("add", "stage-waits", "--title", "Stage waits", "--by", "Aurora", "--ref", "site:5411", "--status", "in progress",
           "--work", "batch322", "--at", "2026-10-28 16:20", "--priority", "normal")
        ok("add", "old-plan", "--title", "Old plan", "--by", "Sol", "--asked", "2026-10-20 08:00", "--at", "2026-10-20 09:00",
           "--priority", "later")
        ok("add", "urgent-plan", "--title", "Urgent plan", "--by", "Sol", "--asked", "2026-10-24 08:00", "--at", "2026-10-24 09:00",
           "--priority", "urgent")
        ok("add", "new-plan", "--title", "New plan", "--by", "Sol", "--at", "2026-10-28 09:00", "--priority", "urgent")

        out = ok("follow", "public-sync", "--what", "A design for an automatic lifecycle ledger", "--next", "batch322 stage report",
                 "--owner", "batch322", "--review", "2026-10-28 20:00", "--source", "reply site:5293", "--at", "2026-10-28 17:40")
        assert out.startswith("public-sync/1: open (live row); owner batch322; review 2026-10-28 20:00"), out
        ok("follow", "public-sync", "--what", "Check the hourly push after a gate day", "--next", "read status.json",
           "--owner", "nick", "--review", "+2d", "--at", "2026-10-25 10:00")
        ok("follow", "public-sync", "--what", "Closed later", "--next", "x", "--owner", "operator", "--review", "+1h", "--at", "2026-10-25 10:00")
        fl = rows()["public-sync"]["followups"]
        assert [x["n"] for x in fl] == [1, 2, 3] and fl[1]["owner"] == updates.STREAM_OWNER and fl[1]["review"] == "2026-10-27 10:00", fl
        assert fl[0]["source"] == "reply site:5293" and fl[0]["opened"] == "2026-10-28 17:40", fl[0]

        before = Path(f).read_text()
        for bad in (["--owner", "Nick Winter"], ["--owner", "claude-b"], ["--owner", "a@b.example"], ["--review", "soon"]):
            args = {"--owner": "operator", "--review": "+1d"}
            args[bad[0]] = bad[1]
            r = run("follow", "public-sync", "--what", "w", "--next", "n", *[x for kv in args.items() for x in kv], "--at", "2026-10-28 10:00")
            assert r.returncode != 0, (bad, r.stdout)
        assert run("follow-set", "public-sync/9", "--done").returncode != 0
        assert run("follow-set", "public-sync", "--done").returncode != 0
        assert run("follow", "no-such-row", "--what", "w", "--next", "n", "--owner", "operator", "--review", "+1d").returncode != 0
        assert Path(f).read_text() == before

        out = ok("follow-set", "public-sync/3", "--dropped", "--note", "covered by /2", "--at", "2026-10-26 10:00")
        assert "dropped 2026-10-26 10:00" in out, out
        assert run("follow-set", "public-sync/3", "--done").returncode != 0  # closed already
        ok("follow-set", "public-sync/1", "--next", "the operator reads the stage section", "--at", "2026-10-28 18:00")

        # due at 2026-10-28 21:00: /1 (review 20:00) and /2 (27 10:00) past review on a Live row; /3 dropped; oldest review first
        out = ok("due", "--now", "2026-10-28 21:00")
        lines = out.splitlines()
        i = next(i for i, x in enumerate(lines) if x.startswith("follow-ups:"))
        assert lines[i] == "follow-ups: 2 of 2 open past their review (rows of any status, Live included), oldest review first", lines[i]
        assert lines[i + 1].startswith("  public-sync/2  (live row)  owner the stream's owner  next: read status.json  review due since 2026-10-27 10:00"), lines[i + 1]
        assert lines[i + 2].startswith("  public-sync/1  (live row)  owner batch322 (row stage-waits)  next: the operator reads the stage section"), lines[i + 2]
        assert "what: A design for an automatic lifecycle ledger" in lines[i + 2]
        out = ok("due", "--now", "2026-10-28 19:00")
        assert "follow-ups: 1 of 2 open past their review" in out and "public-sync/1 " not in out, out

        # reviewed ID/N moves the review on
        out = ok("reviewed", "public-sync/2", "--next", "+3d", "--at", "2026-10-28 21:00")
        assert out == "public-sync/2: reviewed 2026-10-28 21:00; next review 2026-10-31 21:00", out
        assert run("reviewed", "public-sync/3").returncode != 0  # dropped

        # ready work: planned rows and open follow-ups waiting over 2 days, by priority then oldest
        ok("defer", "old-plan", "--reason", "waits for the multi-day rest work", "--at", "2026-10-27 09:00")
        ok("defer", "old-plan", "--reason", "behind the stage-waits batch", "--at", "2026-10-28 09:00")
        assert run("defer", "public-sync", "--reason", "x").returncode != 0  # a Live row: its follow-ups wait, not it
        ok("defer", "public-sync/2", "--reason", "needs a gate-heavy day", "--at", "2026-10-28 09:30")
        out = ok("due", "--now", "2026-10-28 21:00", "--ready-days", "2")
        lines = out.splitlines()
        i = next(i for i, x in enumerate(lines) if x.startswith("ready longer than"))
        assert lines[i] == "ready longer than 2 d: 3 of 5 (planned rows and open follow-ups), by priority, oldest first", lines[i]
        assert lines[i + 1] == "  urgent-plan  priority urgent  waiting 4 d 12 h  no reason", lines[i + 1]
        assert lines[i + 2] == "  old-plan  priority later  waiting 8 d 12 h  deferred 2026-10-28 09:00: behind the stage-waits batch", lines[i + 2]
        assert lines[i + 3] == "  public-sync/2  priority not set  waiting 3 d 11 h  deferred 2026-10-28 09:30: needs a gate-heavy day", lines[i + 3]
        assert "new-plan" not in "\n".join(lines[i:]) and "public-sync/1" not in "\n".join(lines[i:])
        assert "ready longer than 10 d: 0 of 5" in ok("due", "--now", "2026-10-28 21:00", "--ready-days", "10")

        # candidates: the note's promise and a reply's, the scope sentence left out, a Live row's next review; nothing written
        runs = Path(d) / "runs" / "shift88"
        runs.mkdir(parents=True)
        (runs / "operator-replies.jsonl").write_text("\n".join(json.dumps(r) for r in [
            {"t": 1, "to": "site:5293", "parts": ["@Aurora (2/2) Operator: Taken as batch290: the site will show the sync time. "
                                                   "An automatic ledger from requests gets a design first."]},
            {"t": 2, "to": "site:9999", "parts": ["Another row's promise will not show."]}]) + "\n")
        ok("set", "public-sync", "--next-review", "2026-10-29 12:00", "--at", "2026-10-28 21:00")
        before = Path(f).read_text()
        out = ok("follow-candidates", "--runs", str(Path(d) / "runs"))
        assert out.splitlines()[0] == "public-sync (live, batch272, batch290; open follow-ups 2)", out
        assert "  note: An automatic ledger gets a design first." in out, out
        assert "  reply site:5293: An automatic ledger from requests gets a design first." in out, out
        assert "Taken as batch290" not in out and "Another row" not in out, out
        assert "  next review 2026-10-29 12:00 (owner not set): a Live row's review, which due skips" in out, out
        assert Path(f).read_text() == before

        # the page: under the Live row, open follow-ups with the batch owner linked to its row, due at the build; closed folded
        data = updates.load(f)
        built = updates.when("2026-10-28 21:00")
        body, _ = updates.build_page(data, {}, {}, esc, built=built)
        li = updates.rows_html(data, {}, {}, esc, built)["public-sync"][1]
        assert 'data-follow="2"' in li, li
        assert '<p class="small upd-follow-head">Open follow-ups (2)</p>' in li, li
        assert '<li id="u-public-sync-f1" class="upd-f upd-f-open"><span class="upd-fwhat">A design for an automatic lifecycle ledger</span>' in li, li
        assert 'Owner <a href="#u-stage-waits">batch322</a>' in li, li
        assert "Next: the operator reads the stage section · Review Wed 28 Oct 20:00 <span class=\"upd-flag upd-due\">due</span>" in li, li
        assert "Owner the stream&#x27;s owner" in li and "Review Sat 31 Oct 21:00 · " in li, li
        assert "deferred Wed 28 Oct 09:30: needs a gate-heavy day" in li and "from reply site:5293" in li, li
        assert '<summary>Closed follow-up (1)</summary>' in li and "dropped Mon 26 Oct 10:00: covered by /2" in li, li
        assert "; 2 open follow-ups on rows of any status, 1 past their review." in body, body[:2000]
        assert "lifecycle ledger" in updates._search(rows()["public-sync"], {}), "search words"
        assert "follow" not in updates.rows_html(data, {}, {}, esc, built)["old-plan"][1], "a row without follow-ups"
        full = updates.updates_json(data, {}, {}, esc, built)
        assert "open follow-ups on rows of any status" in full["backlog"], full["backlog"]

        # load() refuses broken follow-ups
        good = json.loads(Path(f).read_text())
        for breakit in (lambda x: x.pop("review"), lambda x: x.update(owner="Nick"), lambda x: x.update(state="maybe"),
                        lambda x: x.update(n=2), lambda x: x.update(state="done"), lambda x: x.update(deferred=[{"at": "x", "reason": "r"}])):
            bad = json.loads(json.dumps(good))
            row = next(u for u in bad["updates"] if u["id"] == "public-sync")
            breakit(row["followups"][0])
            Path(d, "bad.json").write_text(json.dumps(bad))
            try:
                updates.load(Path(d, "bad.json"))
            except ValueError as e:
                assert "public-sync" in str(e), e
            else:
                raise AssertionError(row["followups"][0])
    print("ok: follow-ups on any row, due past review, ready work with deferred reasons, candidates, page")


if __name__ == "__main__":
    main()
