#!/usr/bin/env python3
"""The Operator's reply to one viewer line, linked to that line on the stream's site (d20 batch65 AA2, viewer Aurora
04:28: "Could replies keep the original question ID through delivery, split parts and history? Some clear replies say
'not linked', and artillery answers appeared under a different question").

    python3 tools/opreply.py --to site:3817 "the artillery remote's reply has used manual range since Oct 18 ..."
    python3 tools/opreply.py --to Aurora@03:51 "..."      # the inbox line Aurora wrote at 03:51 (local time)
    python3 tools/opreply.py --list [Aurora]               # recent inbox lines with the ids --to takes
    python3 tools/opreply.py --to site:3817 --dry-run "..."   # the parts and the record; sends and writes nothing
    python3 tools/opreply.py --to site:3817 --sent 18454 18456   # link lines already sent (RUN/chat.jsonl seqs), in order

It names the viewer ("@Aurora Operator: ..."), cuts a reply over 500 bytes into parts at sentence ends ("@Aurora (1/2)
Operator: ...", "@Aurora (2/2) Operator: ..."), writes RUN/operator-replies.jsonl first ({t, to, name, question {text,
t, source}, parts}), then posts each part to the game chat over RCON as the operator does with tools/pog.py rcon. The
stream service (model.py) reads that file: every part threads under the named line, at any age and after a restart,
and the site shows "part 1 of 2". A reply sent without this tool is matched by name as before (viewer_replies.py).

--world: POG_WORLD, else n. --run: the run folder (default: the runs/shift* folder whose chat.jsonl changed last, the
live one); an inbox line from the 2 runs before it is found too, and the record still goes to this run (d22 batch89 AY4).
"""
import argparse, datetime, glob, json, os, re, sys, time, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "stream"))
import viewer_replies  # noqa: E402

SITE_API = "https://player-of-games-live.your-subdomain.workers.dev"
MAX_BYTES = 500  # one game-chat line (fh say's parts are cut at the same size)


def latest_run(root):
    runs = [d for d in glob.glob(os.path.join(root, "shift*")) if os.path.isdir(d)]
    runs.sort(key=lambda d: os.path.getmtime(os.path.join(d, "chat.jsonl")) if os.path.exists(os.path.join(d, "chat.jsonl")) else 0)
    return runs[-1] if runs else None


def inbox_rows(run, back=viewer_replies.LINKS_BACK):
    """The viewer rows of RUN/operator-inbox.jsonl and of the `back` runs it resumed from, oldest first, each with
    "_run" (its run folder's name). (d22 batch89 AY4) a line from an earlier shift is answered from the live run:
    with --run shift56 during shift57 the record went into shift56's file, which shift57's service did not read."""
    rows = []
    for path in viewer_replies.links_files(os.path.join(run, "operator-inbox.jsonl"), back):
        try:
            with open(path) as f:
                for raw in f:
                    try:
                        r = json.loads(raw)
                    except ValueError:
                        continue
                    if isinstance(r, dict) and r.get("viewer") and str(r.get("agent") or "").startswith("viewer "):
                        rows.append(dict(r, _run=os.path.basename(os.path.dirname(path))))
        except OSError:
            pass
    return rows


def hm(t):
    return datetime.datetime.fromtimestamp(t).strftime("%H:%M")


def site_line(seq, api=SITE_API, fetch=None):
    """The site's chat line `seq`: {name, text, t}, or None."""
    url = f"{api}/v1/chat?after={seq - 1}&limit=1&channels=all"
    try:
        # the site's host answers urllib's own User-Agent with 403 (push_live.py)
        body = fetch(url) if fetch else json.load(urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "pog-opreply/1"}), timeout=10))
    except Exception as e:  # noqa: BLE001
        sys.exit(f"opreply: the site's chat did not answer ({type(e).__name__}: {e})")
    for m in body.get("messages") or []:
        if m.get("seq") == seq:
            return {"name": m.get("name"), "text": m.get("text"), "t": m.get("t")}
    return None


def resolve(to, run, fetch=None):
    """--to -> (id, name, question {text, t, source}). site:N (the site's chat), an id in the inbox (yt:...), or
    NAME@HH:MM (that viewer's inbox line written at that minute, the latest)."""
    rows = inbox_rows(run) if run else []
    m = re.fullmatch(r"site:(\d+)", to)
    if m:
        got = site_line(int(m.group(1)), fetch=fetch)
        if not got or not got.get("name"):
            sys.exit(f"opreply: no site line {to}")
        return to, got["name"], {"text": got["text"], "t": got["t"], "source": "site"}
    for r in reversed(rows):
        if r.get("id") == to:
            return to, r["agent"][7:], {"text": r.get("text"), "t": r.get("t"), "source": r.get("source"), "run": r["_run"]}
    m = re.fullmatch(r"(.+)@(\d{1,2}):(\d{2})", to)
    if m:
        name, at = m.group(1).lstrip("@"), "%02d:%s" % (int(m.group(2)), m.group(3))
        hits = [r for r in rows if r["agent"][7:].lower() == name.lower() and isinstance(r.get("t"), (int, float)) and hm(r["t"]) == at]
        if not hits:
            sys.exit(f"opreply: no inbox line from {name} at {at} in {run}")
        r = hits[-1]
        ident = r.get("id") or f"inbox:{r['agent'][7:]}@{r['t']}"
        return ident, r["agent"][7:], {"text": r.get("text"), "t": r.get("t"), "source": r.get("source"), "run": r["_run"]}
    sys.exit(f"opreply: --to is site:N, an inbox id or NAME@HH:MM, not {to!r}")


def parts(name, text, max_bytes=MAX_BYTES):
    """The game-chat lines for a reply: "@NAME Operator: ...", or numbered parts cut at sentence ends (then words)."""
    body = re.sub(r"\s+", " ", text).strip()
    body = re.sub(r"^@" + re.escape(name) + r"\b[,:]?\s*", "", body, flags=re.I)
    body = re.sub(r"^operator\s*:\s*", "", body, flags=re.I)
    one = f"@{name} Operator: {body}"
    if len(one.encode()) <= max_bytes:
        return [one]
    room = max_bytes - len(f"@{name} (99/99) Operator: ".encode())
    chunks, cur = [], ""
    for piece in re.split(r"(?<=[.!?;])\s+", body):
        words = [piece] if len(piece.encode()) <= room else piece.split(" ")
        for w in words:
            joined = (cur + " " + w).strip() if cur else w
            if len(joined.encode()) <= room:
                cur = joined
            else:
                if cur:
                    chunks.append(cur)
                while len(w.encode()) > room:  # one word longer than a part
                    cut = w.encode()[:room].decode(errors="ignore")
                    chunks.append(cut)
                    w = w[len(cut):]
                cur = w
    if cur:
        chunks.append(cur)
    n = len(chunks)
    return [f"@{name} ({k}/{n}) Operator: {c}" for k, c in enumerate(chunks, 1)]


def sent_lines(run, seqs):
    """The texts of the Operator's game-chat lines `seqs` in RUN/chat.jsonl, in that order."""
    want, got = [int(s) for s in seqs], {}
    try:
        with open(os.path.join(run, "chat.jsonl")) as f:
            for raw in f:
                try:
                    r = json.loads(raw)
                except ValueError:
                    continue
                if isinstance(r, dict) and r.get("seq") in want and r.get("from") == "server":
                    got[r["seq"]] = r.get("text")
    except OSError:
        pass
    missing = [s for s in want if s not in got]
    if missing:
        sys.exit(f"opreply: no Operator line {', '.join(map(str, missing))} in {run}/chat.jsonl")
    return [got[s] for s in want]


def send(lines, world, port=None):
    import pog
    port = port or (int(os.environ["POG_RCON_PORT"]) if os.environ.get("POG_RCON_PORT") else pog.PORTS.get(world))
    pw_file = os.environ.get("POG_RCON_PASSWORD_FILE") or os.path.expanduser(f"~/.config/pog/rcon-{world}.pw")
    r = pog.Rcon("127.0.0.1", port, open(pw_file).read().strip())
    for i, line in enumerate(lines):
        if i:
            time.sleep(0.3)  # in order, a moment apart
        r.command(line)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("text", nargs="?", help="the reply (leading @NAME and Operator: are added)")
    ap.add_argument("--to", help="the line it answers: site:N, an inbox id (yt:...), or NAME@HH:MM")
    ap.add_argument("--list", nargs="?", const="", metavar="NAME", help="recent inbox lines from viewers (or NAME) with their ids")
    ap.add_argument("--world", default=os.environ.get("POG_WORLD", "n"))
    ap.add_argument("--port", type=int)
    ap.add_argument("--run", help="the run folder the record goes to (default: the live one, the runs/shift* whose chat.jsonl "
                    "changed last); --to finds inbox lines there and in the 2 runs it resumed from")
    ap.add_argument("--dry-run", action="store_true", help="print the parts and the record; send and write nothing")
    ap.add_argument("--sent", nargs="+", metavar="SEQ", help="link Operator lines already in the game chat (RUN/chat.jsonl seqs, in order); sends nothing")
    a = ap.parse_args(argv)
    run = a.run or latest_run(os.path.join(os.path.dirname(HERE), "runs"))
    if a.list is not None:
        rows = [r for r in inbox_rows(run) if not a.list or r["agent"][7:].lower() == a.list.lower()][-12:]
        for r in rows:
            who = r["agent"][7:]
            ident = r.get("id") or (f"{who}@{hm(r['t'])}" if isinstance(r.get("t"), (int, float)) else "?")
            print(f"{hm(r['t']) if isinstance(r.get('t'), (int, float)) else '--:--'}  --to {ident}  {who}: {str(r.get('text'))[:100]}")
        return 0
    if not a.to or not (a.text or a.sent) or (a.text and a.sent):
        ap.error("--to and the reply text (or --sent SEQ ...) are needed, or --list")
    ident, name, question = resolve(a.to, run)
    found_in = question.pop("run", None)
    lines = sent_lines(run, a.sent) if a.sent else parts(name, a.text)
    rec = {"t": round(time.time(), 1), "to": ident, "name": name, "question": question, "parts": lines, "world": a.world}
    path = os.path.join(run, viewer_replies.LINKS_NAME) if run else None
    print(f"answers {ident} ({name}, {hm(question['t']) if isinstance(question.get('t'), (int, float)) else '?'}): {str(question.get('text'))[:100]}"
          + (f" (from {found_in}'s inbox; the record goes to {os.path.basename(run)})" if found_in and found_in != os.path.basename(run) else ""))
    for line in lines:
        print("  " + line)
    if a.sent:
        rec["sent"] = [int(x) for x in a.sent]
    if a.dry_run:
        print(f"dry run: nothing sent; the record would go to {path}")
        return 0
    if not path:
        sys.exit("opreply: no run folder (--run)")
    with open(path, "a") as f:  # first: the stream service links each part as it arrives
        f.write(json.dumps(rec, ensure_ascii=False) + "\n")
    if a.sent:
        print(f"linked {len(lines)} sent line{'s' if len(lines) > 1 else ''} in {path} (the stream service reads them at its next chat read)")
        return 0
    send(lines, a.world, a.port)
    print(f"sent {len(lines)} line{'s' if len(lines) > 1 else ''} to world {a.world}; linked in {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
