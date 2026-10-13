#!/usr/bin/env python3
"""YouTube deletions are kept for the site: python3 tools/stream/test_viewer_deletions.py

- a deletion by message id writes one row to runs/RUN/viewer-deletions.jsonl with the message's name and text;
- a deletion by author writes the author's name and every line seen from them, and drops their later messages;
- after a restart, the verdict log (with its author keys) still names what a deletion removes;
- an unknown id still gets a row (no name, no text), and the lane and relay queue lose the deleted lines as before.
"""
import json, os, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.dont_write_bytecode = True
import viewers as V  # noqa: E402

FAILS = []


def check(name, ok, detail=""):
    print(("ok   " if ok else "FAIL ") + name + ("" if ok else f"  {detail}"))
    if not ok:
        FAILS.append(name)


NOW = time.time()


def msg(i, author, name, text, dt=0):
    return {"id": f"yt:{i}", "source": "youtube", "author": V.author_key("yt", author), "name": name, "text": text,
            "t": NOW + dt, "staff": None}


def rows(path):
    return [json.loads(l) for l in open(path)] if os.path.exists(path) else []


with tempfile.TemporaryDirectory() as d:
    path = os.path.join(d, "viewer-deletions.jsonl")
    logs = os.path.join(d, "logs")
    os.makedirs(logs)
    feed = V.Feed({}, V.Filter(["astra", "sol"], lane_gap=0), log_path=os.path.join(logs, "viewers-1.jsonl"), deletions=path)
    feed.ingest([msg("a1", "UCaaa", "factoryfan", "how many rockets so far?"),
                 msg("b1", "UCbbb", "rudebob", "@astra your belts are a mess", 1),
                 msg("b2", "UCbbb", "rudebob", "second line from bob", 2)], [], now=NOW + 3)
    lane = [m["id"] for m in feed.lane()[0]]
    check("three lines in the lane", lane == ["yt:a1", "yt:b1", "yt:b2"], lane)

    feed.ingest([], [("id", "yt:a1")], now=NOW + 4)
    r = rows(path)
    check("a deletion by id: one row with name and text",
          len(r) == 1 and r[0]["kind"] == "id" and r[0]["ident"] == "yt:a1" and r[0]["name"] == "factoryfan"
          and r[0]["texts"] == ["how many rockets so far?"] and r[0]["source"] == "youtube" and r[0]["t"], r)
    check("the deleted line leaves the lane", "yt:a1" not in [m["id"] for m in feed.lane()[0]])

    bob = V.author_key("yt", "UCbbb")
    feed.ingest([], [("author", bob)], now=NOW + 5)
    r = rows(path)
    check("a deletion by author: the author's name and every line",
          len(r) == 2 and r[1]["kind"] == "author" and r[1]["ident"] == bob and r[1]["name"] == "rudebob"
          and r[1]["texts"] == ["@astra your belts are a mess", "second line from bob"], r[1:])
    feed.ingest([msg("b3", "UCbbb", "rudebob", "I am back", 6)], [], now=NOW + 7)
    check("a deleted author's later messages are dropped", [m["id"] for m in feed.lane()[0]] == [], feed.lane()[0])

    feed.ingest([], [("id", "yt:nope")], now=NOW + 8)
    r = rows(path)
    check("an unknown id still gets a row", r[-1]["ident"] == "yt:nope" and r[-1]["name"] is None and r[-1]["texts"] == [])

    # a restart: a new feed finds earlier messages in the verdict log (with their author keys)
    feed.log_f.close()
    again = V.Feed({}, V.Filter(["astra"]), deletions=path)
    again.preload(logs)
    again.delete("id", "yt:a1")
    again.delete("author", V.author_key("yt", "UCaaa"))
    r = rows(path)
    check("after a restart, a deletion by id is still named from the verdict log",
          r[-2]["name"] == "factoryfan" and r[-2]["texts"] == ["how many rockets so far?"], r[-2])
    check("after a restart, a deletion by author is still named from the verdict log",
          r[-1]["name"] == "factoryfan" and r[-1]["texts"] == ["how many rockets so far?"], r[-1])

    off = V.Feed({}, V.Filter(["astra"]))  # no deletions file (the mock): nothing written, nothing breaks
    off.ingest([msg("c1", "UCccc", "x1", "hello there")], [("id", "yt:c1")], now=NOW + 9)
    check("without a deletions file the lane still loses the line", off.lane()[0] == [])

print("all passed" if not FAILS else f"{len(FAILS)} failed")
sys.exit(1 if FAILS else 0)
