#!/usr/bin/env python3
"""The replies made before the stream service kept them (d28 batch309): each run's chat.jsonl, read with its operator
inbox and the Operator's reply records (viewer_replies.replies, as site/longrun.py reads a shift), added to the live run's
viewer-replies.jsonl for the game seqs it lacks. The stream service reads them at its next start; push_live sends them.

    python3 tools/stream/replies_backfill.py runs/shift92 --dry-run   # what it would add, from shift92 and 6 runs before
    python3 tools/stream/replies_backfill.py runs/shift92
"""
import argparse, json, os, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import model  # noqa: E402
import viewer_replies as V  # noqa: E402


def read_chat(path):
    out = []
    try:
        with open(path) as f:
            for raw in f:
                try:
                    r = json.loads(raw)
                except ValueError:
                    continue
                if isinstance(r, dict) and isinstance(r.get("seq"), int):
                    out.append(r)
    except OSError:
        pass
    return out


def rows_for(run, back=model.REPLY_RUNS_BACK):
    """Reply rows of `run` and the `back` runs it resumed from, oldest first, one per game seq, each with its time
    (chat.jsonl's logged_at)."""
    store = os.path.join(run, V.ROWS_NAME)
    out = {}
    for p in V.links_files(store, back):
        d = os.path.dirname(p)
        links = {}
        for lp in V.links_files(os.path.join(d, V.LINKS_NAME)):  # the records the stream service read for that run
            links.update(V.read_links(lp))
        for line, r in V.replies(read_chat(os.path.join(d, "chat.jsonl")), inbox=V.read_inbox(os.path.join(d, "operator-inbox.jsonl")),
                                 links=links):
            t = V.wall_t(line)
            if t is None or line["seq"] in out:
                continue
            out[line["seq"]] = V.row(dict(line, t=t), r)
    return sorted(out.values(), key=lambda r: r["t"])


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("run", help="the live run folder (runs/shiftN)")
    ap.add_argument("--dry-run", action="store_true", help="print what it would add; write nothing")
    a = ap.parse_args(argv)
    store = os.path.join(a.run, V.ROWS_NAME)
    have = {r["seq"] for p in V.links_files(store, model.REPLY_RUNS_BACK) for r in V.read_rows(p)}
    add = [r for r in rows_for(a.run) if r["seq"] not in have]
    for r in add:
        print(f"{r['seq']} {r['by']}: {r['text'][:90]}" + (f"  (answers {r['answers'].get('id') or r['answers']['name']})" if r.get("answers") else ""))
    if a.dry_run:
        print(f"dry run: {len(add)} rows would go to {store}")
        return 0
    with open(store, "a") as f:
        for r in add:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
    print(f"added {len(add)} rows to {store} (the stream service reads them at its next start)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
