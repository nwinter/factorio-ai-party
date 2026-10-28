#!/usr/bin/env python3
"""The replies made before the stream service kept them (d28 batch309): python3 tools/stream/test_replies_backfill.py

Two made-up runs (shift91 resumed from shift90), each with its chat.jsonl (chat-log.py's rows) and the Operator's reply
records: replies_backfill.py adds every reply of both once, each part of a split reply and a late answer (shift91's record
to a shift90 line), with chat.jsonl's times; a row the store has already is not added; run again, it
adds nothing; model.py reads them back at a start.
"""
import contextlib, datetime, io, json, os, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path[:0] = [HERE, os.path.dirname(HERE)]
import replies_backfill as B  # noqa: E402
import viewer_replies as V  # noqa: E402
from model import Model  # noqa: E402

T0 = 1793150000.0


def line(seq, t, **kw):
    return dict(kw, seq=seq, tick=76000000 + int((t - T0) * 60), logged_at=datetime.datetime.fromtimestamp(t).isoformat())


def main():
    with tempfile.TemporaryDirectory() as d:
        r90, r91 = os.path.join(d, "shift90"), os.path.join(d, "shift91")
        os.makedirs(r90)
        os.makedirs(r91)
        open(os.path.join(r91, "resumed-from"), "w").write("shift90\n")
        q = {"seq": 100, "name": "Aurora", "id": "site:5001", "source": "site", "text": "could the belt be checked?"}
        c90 = [line(100, T0, **{"from": "viewer Aurora", "viewer": True, "source": "site", "source_id": "site:5001", "text": "@sol could the belt be checked?"}),
               line(101, T0 + 60, **{"from": "sol", "text": "@Aurora it is checked.", "replies_to": [dict(q, tick=76000000)]}),
               line(102, T0 + 90, **{"from": "server", "text": "@Aurora (1/2) Operator: first part."}),
               line(103, T0 + 90, **{"from": "server", "text": "@Aurora (2/2) Operator: second part."}),
               line(104, T0 + 95, **{"from": "astra", "text": "building the wall now"})]
        c91 = [line(200, T0 + 9 * 3600, **{"from": "server", "text": "@Aurora Operator: a late answer."})]
        rec = lambda parts, t: json.dumps({"t": t, "to": "site:5001", "name": "Aurora", "question": {"text": q["text"], "t": T0, "source": "site"}, "parts": parts}) + "\n"  # noqa: E731
        open(os.path.join(r90, V.LINKS_NAME), "w").write(rec(["@Aurora (1/2) Operator: first part.", "@Aurora (2/2) Operator: second part."], T0 + 89))
        open(os.path.join(r91, V.LINKS_NAME), "w").write(rec(["@Aurora Operator: a late answer."], T0 + 9 * 3600 - 1))
        for r, c in ((r90, c90), (r91, c91)):
            with open(os.path.join(r, "chat.jsonl"), "w") as f:
                f.writelines(json.dumps(x) + "\n" for x in c)
        # the store already has Sol's (the live service kept it)
        open(os.path.join(r90, V.ROWS_NAME), "w").write(json.dumps({"seq": 101, "t": T0 + 60, "by": "sol", "text": "@Aurora it is checked.", "kind": "reply", "to": ["Aurora"]}) + "\n")
        with contextlib.redirect_stdout(io.StringIO()) as out:
            B.main([r91])
        assert "added 3 rows" in out.getvalue(), out.getvalue()
        rows = V.read_rows(os.path.join(r91, V.ROWS_NAME))
        assert [r["seq"] for r in rows] == [102, 103, 200], rows
        assert [r.get("part") for r in rows] == [[1, 2], [2, 2], None], rows
        assert all(r["answers"]["id"] == "site:5001" and r["link"] == "reply_to" for r in rows), rows
        assert abs(rows[0]["t"] - (T0 + 90)) < 1 and abs(rows[2]["t"] - (T0 + 9 * 3600)) < 1, rows
        with contextlib.redirect_stdout(io.StringIO()) as out:
            B.main([r91])
        assert "added 0 rows" in out.getvalue(), out.getvalue()
        m = Model({"agents": {"sol": {}}})
        m.set_reply_store(os.path.join(r91, V.ROWS_NAME))
        assert [r["seq"] for r in m.replies_all()] == [101, 102, 103, 200], m.replies_all()
    print("replies backfill: ok (each reply of the run chain once, every part, a late answer, with its time; again adds nothing)")


if __name__ == "__main__":
    main()
