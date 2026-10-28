#!/usr/bin/env python3
"""Operation stories on a run's real logs (d28 batch312 B): each agent's flight watches as its journal's flight_watch
replies show them (the watches it set; waiting for its departure: armed; watching: running; watched ... ended: done,
then read), run through
stories.py on model.py with the board as given, and the story beats it raises printed with their times.

    python3 tools/stream/stories_replay.py runs/shift92 [--agents astra,sol] [--board board.json] [--since HH:MM]

The card rows are rebuilt from the replies: a watch appears when a reply first shows it, is done when a reply says it
ended, and leaves the card at the agent's read of its end (a done watch stops counting once read). Losses come from the
reads' lost_count only (the stream's loss alerts are not in the journals).
"""
import argparse, datetime, json, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from model import Model  # noqa: E402
from work import WATCH_LINE  # noqa: E402

ENDED = re.compile(r"ended: (.*?)(?:;|$)")


def epoch(at):
    try:
        t = datetime.datetime.fromisoformat(str(at).replace("Z", "+00:00"))
    except ValueError:
        return None
    if t.tzinfo is None:  # the journals' times are UTC
        t = t.replace(tzinfo=datetime.timezone.utc)
    return t.timestamp()


def events(run, agent):
    """[(t, row)] of an agent's flight_watch replies: row {id, platform, state, why, line, lost_count, ended_by}."""
    out, pending, own, seen = [], {}, set(), set()
    try:
        f = open(os.path.join(run, agent, "journal.jsonl"))
    except OSError:
        return out
    with f:
        for raw in f:
            try:
                r = json.loads(raw)
            except ValueError:
                continue
            if r.get("event") == "request" and (r.get("request") or {}).get("action") == "flight_watch":
                args = r["request"].get("args") if isinstance(r["request"].get("args"), dict) else {}
                pending[r["request"].get("id")] = "set" if args.get("platform") and not args.get("read") and not args.get("id") \
                    and not args.get("clear") else "read"
            elif r.get("event") == "response":
                resp = r.get("response") or {}
                kind = pending.pop(resp.get("id"), None)
                if not kind or not resp.get("ok"):
                    continue
                res = resp.get("result") if isinstance(resp.get("result"), dict) else {}
                w = res.get("watch") if isinstance(res.get("watch"), dict) else res
                line = str(w.get("line") or res.get("line") or "")
                m = WATCH_LINE.match(line)
                t = epoch(r.get("at"))
                if not m or t is None:
                    continue
                wid = f"flight#{m.group(1)}"
                sa = re.search(r"\(set (\d+)s ago\)", line)
                if kind == "set" or (sa and int(sa.group(1)) <= 60 and wid not in seen):
                    own.add(wid)  # the card lists only the watches the agent set (flightwatch.card); a queue's set is read at once
                seen.add(wid)
                if wid not in own:
                    continue
                e = ENDED.search(line)
                state = "done" if e else "armed" if "waiting for its next departure" in line or "begins at its next departure" in line else "running"
                out.append((t, {"id": wid, "platform": m.group(2).strip(), "state": state,
                                "why": e.group(1).strip() if e else None, "line": line, "lost_count": w.get("lost_count"),
                                "ended_by": w.get("ended_by")}))
    return out


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("run")
    ap.add_argument("--agents", default=None)
    ap.add_argument("--board", default=None, help="a board document (serve.py /board.json): the questions and handoffs")
    ap.add_argument("--since", default=None, help="HH:MM local: beats from then")
    a = ap.parse_args(argv)
    names = a.agents.split(",") if a.agents else sorted(d for d in os.listdir(a.run) if os.path.isfile(os.path.join(a.run, d, "journal.jsonl")))
    m = Model({"agents": {n: {} for n in names}})
    if a.board:
        doc = json.load(open(a.board))
        m.board["items"] = {it["id"]: it for it in (doc.get("items") or []) + (doc.get("projects") or []) if isinstance(it, dict) and "id" in it}
    evs = sorted(((t, n, row) for n in names for t, row in events(a.run, n)), key=lambda x: x[0])
    cards = {n: {} for n in names}
    for t, n, row in evs:
        card = cards[n]
        if row["state"] == "done":
            m.stories.on_read({"agent": n, "id": row["id"], "platform": row["platform"], "ended_by": row["ended_by"] or row["why"],
                               "lost_count": row["lost_count"], "line": row["line"]}, t)
            card[row["id"]] = {"id": row["id"], "kind": "flight_watch", "scope": row["platform"], "state": "done",
                               "line": f"flight watch #{row['id'][7:]} on {row['platform']}: ended ({row['why']}), its result not read yet"}
            m.agents[n].watches = list(card.values())
            m.stories.update(m, t)
            card.pop(row["id"], None)  # read: off the card
        else:
            card[row["id"]] = {"id": row["id"], "kind": "flight_watch", "scope": row["platform"], "state": row["state"],
                               "line": row["line"]}
        m.agents[n].watches = list(card.values())
        m.stories.update(m, t + 0.5)
    since = a.since
    beats = []
    for s in sorted(m.stories.stories.values(), key=lambda s: s["opened_t"]):
        for b in ("open", "result"):
            if b in s["beats"]:
                beats.append((s["beats"][b]["t"], s, b))
    for t, s, b in sorted(beats, key=lambda x: x[0]):
        hm = datetime.datetime.fromtimestamp(t).strftime("%H:%M:%S")
        if since and hm[:5] < since:
            continue
        print(f"{hm} {b:6} {s['beats'][b].get('caption')}")
        if b == "result":
            print(f"         watches {', '.join(s.get('watches') or [])}; verdict {s['verdict']}; ended {s.get('ended_by')}")
    quiet = sum(1 for s in m.stories.stories.values() if s.get("quiet"))
    print(f"{len(m.stories.stories)} stories, {quiet} quiet (a platform's next within {int(__import__('stories').REPEAT_S / 60)} min), "
          f"{sum(1 for s in m.stories.stories.values() if s.get('late'))} late")
    return 0


if __name__ == "__main__":
    sys.exit(main())
