#!/usr/bin/env python3
"""Operator replies across runs (d22 batch89 AY4, review AU1 finding 5): python3 tools/stream/test_opreply_runs.py

tools/opreply.py was run with --run shift56 during shift57, so 6 records went into shift56's operator-replies.jsonl and
shift57's service, reading only its own, never linked the 06:28 replies (one threaded under the wrong line).
1. model.py reads this run's operator-replies.jsonl and the 2 runs' before it (resumed-from), a newer record over an
   older one; a third run back is not read.
2. tools/opreply.py, with the live run, finds an inbox line from the run before (NAME@HH:MM and an inbox id) and still
   writes the record to the live run; --list shows those lines too.
"""
import datetime, io, json, os, shutil, sys, tempfile
from contextlib import redirect_stdout

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path[:0] = [HERE, os.path.dirname(HERE)]
import opreply  # noqa: E402
import viewer_replies as V  # noqa: E402
from model import Model  # noqa: E402

T = 1792634899.0  # an inbox line written in shift56


def runs(root):
    for i, name in enumerate(("shift55", "shift56", "shift57", "shift58")):
        d = os.path.join(root, name)
        os.makedirs(d)
        if i:
            open(os.path.join(d, "resumed-from"), "w").write(("shift55", "shift56", "shift57")[i - 1] + "\n")
    return {n: os.path.join(root, n) for n in ("shift55", "shift56", "shift57", "shift58")}


def rec(to, name, text, parts):
    return json.dumps({"t": T + 100, "to": to, "name": name, "question": {"text": text, "t": T, "source": "site"},
                       "parts": parts}) + "\n"


def model_links(r):
    with open(os.path.join(r["shift55"], V.LINKS_NAME), "w") as f:
        f.write(rec("site:3001", "Caleb", "too old", ["@Caleb Operator: three runs back"]))
    with open(os.path.join(r["shift56"], V.LINKS_NAME), "w") as f:  # written during shift57 with --run shift56
        f.write(rec("site:4011", "Aurora", "@operator Planet buttons disappear", ["@Aurora Operator: kept per planet now"]))
        f.write(rec("site:4034", "Foobator", "the ship overview", ["@Foobator Operator: Live since 08:26"]))
    with open(os.path.join(r["shift58"], V.LINKS_NAME), "w") as f:
        f.write(rec("site:4190", "Aurora", "the review", ["@Aurora Operator: the review is in"]))
    assert V.links_files(os.path.join(r["shift58"], V.LINKS_NAME)) == [os.path.join(r[n], V.LINKS_NAME) for n in ("shift56", "shift57", "shift58")]
    m = Model({})
    m.set_reply_links(os.path.join(r["shift58"], V.LINKS_NAME))
    links = m.reply_links()
    assert links[V.norm("@Foobator Operator: Live since 08:26")]["id"] == "site:4034", links
    assert links[V.norm("@Aurora Operator: kept per planet now")]["id"] == "site:4011"
    assert links[V.norm("@Aurora Operator: the review is in")]["id"] == "site:4190"
    assert V.norm("@Caleb Operator: three runs back") not in links, "a third run back is not read"
    # a record added to this run's file later is read at the next call
    with open(os.path.join(r["shift58"], V.LINKS_NAME), "a") as f:
        f.write(rec("site:4201", "Caleb", "q", ["@Caleb Operator: later"]))
    os.utime(os.path.join(r["shift58"], V.LINKS_NAME), ns=(1, 2))
    assert m.reply_links()[V.norm("@Caleb Operator: later")]["id"] == "site:4201"


def opreply_runs(r):
    with open(os.path.join(r["shift57"], "operator-inbox.jsonl"), "w") as f:
        f.write(json.dumps({"t": T, "agent": "viewer Aurora", "text": "@operator could the map keep planets?", "viewer": True,
                            "source": "site"}) + "\n")
        f.write(json.dumps({"t": T + 60, "agent": "viewer Caleb", "text": "@operator a YouTube line", "viewer": True,
                            "source": "YouTube", "id": "yt:xyz"}) + "\n")
    open(os.path.join(r["shift58"], "operator-inbox.jsonl"), "w").close()
    hm = datetime.datetime.fromtimestamp(T).strftime("%H:%M")
    out = io.StringIO()
    with redirect_stdout(out):
        assert opreply.main(["--run", r["shift58"], "--to", "Aurora@" + hm, "--dry-run", "maps are kept per planet"]) == 0
    text = out.getvalue()
    assert "answers inbox:Aurora@" in text and "(from shift57's inbox; the record goes to shift58)" in text, text
    assert f"the record would go to {os.path.join(r['shift58'], V.LINKS_NAME)}" in text, text
    ident, name, q = opreply.resolve("yt:xyz", r["shift58"])
    assert ident == "yt:xyz" and name == "Caleb" and q["run"] == "shift57", q
    out = io.StringIO()
    with redirect_stdout(out):
        opreply.main(["--run", r["shift58"], "--list"])
    assert "--to yt:xyz" in out.getvalue() and "Aurora: @operator could the map keep planets?" in out.getvalue(), out.getvalue()
    # sent for real (send stubbed): the record lands in the live run's file, without the run it was found in
    opreply.send = lambda lines, world, port=None: None
    with redirect_stdout(io.StringIO()):
        opreply.main(["--run", r["shift58"], "--to", "yt:xyz", "it is answered"])
    row = json.loads(open(os.path.join(r["shift58"], V.LINKS_NAME)).readlines()[-1])
    assert row["to"] == "yt:xyz" and "run" not in row["question"], row
    assert not os.path.exists(os.path.join(r["shift57"], V.LINKS_NAME))


def main():
    root = tempfile.mkdtemp()
    try:
        r = runs(root)
        model_links(r)
        opreply_runs(r)
    finally:
        shutil.rmtree(root, ignore_errors=True)
    print("operator replies across runs: ok (the model reads the 2 runs before; opreply finds an older inbox line and writes to the live run)")


if __name__ == "__main__":
    main()
