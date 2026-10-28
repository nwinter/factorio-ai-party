#!/usr/bin/env python3
"""The Operator's reply to one viewer line, linked to that line on the stream's site (d20 batch65 AA2, viewer Aurora
04:28: "Could replies keep the original question ID through delivery, split parts and history? Some clear replies say
'not linked', and artillery answers appeared under a different question").

    python3 tools/opreply.py --to site:3817 "the artillery remote's reply has used manual range since Oct 18 ..."
    python3 tools/opreply.py --to Aurora@03:51 "..."      # the inbox line Aurora wrote at 03:51 (local time)
    python3 tools/opreply.py --list [Aurora]               # recent inbox lines with the ids --to takes
    python3 tools/opreply.py --to site:3817 --dry-run "..."   # the parts and the record; sends and writes nothing
    python3 tools/opreply.py --to site:3817 --sent 18454 18456   # link lines already sent (RUN/chat.jsonl seqs), in order
    python3 tools/opreply.py --to site:4789 --update reply-updates-one-step --title "..." --area site "accepted: ..."
    python3 tools/opreply.py --to site:4790 --update reply-updates-one-step --status "in progress" --work batch180 "started"

It names the viewer ("@Aurora Operator: ..."), cuts a reply over 500 bytes into parts at sentence ends ("@Aurora (1/2)
Operator: ...", "@Aurora (2/2) Operator: ..."), writes RUN/operator-replies.jsonl first ({t, to, name, question {text,
t, source}, parts}), then posts each part to the game chat over RCON as the operator does with tools/pog.py rcon. The
stream service (model.py) reads that file: every part threads under the named line, at any age and after a restart,
and the site shows "part 1 of 2". A reply sent without this tool is matched by name as before (viewer_replies.py).

(d24 batch180 QW1, viewer Aurora 17:32, site:4789: "Could chat acknowledgements and Updates share one batch record? Show
accepted work as Planned, then In progress when started.") --update ID [--title T --area A --work W --status planned|in
progress] also adds or moves that row of the Updates page (site/content/operator-updates.json, tools/operator_updates.py
upsert) in the same call: the viewer and the line answered (--to's id, site:N) as who asked, the line's time as asked,
the status's date; the reply shows under the row (the build finds it by that ref). The change is checked before the
reply goes: a row that would go backwards, a status past planned with no --work (the row's or this one), or a new row
with no --title refuses the whole call and sends nothing. The file is written under its lock after the reply is sent.

(d28 batch323 DR, viewer Aurora 16:19, site:5413: "Could delivery receipts require a successful durable inbox write? ...
The reply helper also sends before saving an optional ledger update. Keep request IDs through durable pending delivery
and safe retries") Each reply has a request id (`rid`: its line and parts, so the same reply run again is the same
request). The order is: the record with its rid, flushed and fsynced (pending); the Updates row (--update), written
under its lock; the lines sent; then RUN/operator-replies-sent.jsonl gets {rid, t} (sent). A crash or a failed send
leaves the record pending: the next opreply call in that run (or --resume) sends it, once: a part the game chat
already has after the record (RUN/chat.jsonl, newer than its `chat_seq`) is not sent again, and one already marked
sent is never sent again (the same reply run again says so and sends nothing; --again sends it as a new request).
The Updates page shows a reply once it is marked sent (records from before have no rid and count as sent).

--world: POG_WORLD, else n. --run: the run folder (default: the runs/shift* folder whose chat.jsonl changed last, the
live one); an inbox line from the 2 runs before it is found too, and the record still goes to this run (d22 batch89 AY4).
"""
import argparse, datetime, fcntl, glob, hashlib, json, os, re, sys, time, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "stream"))
import operator_inbox  # noqa: E402
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


SENT_NAME = "operator-replies-sent.jsonl"  # (batch323) {rid, t}: the replies whose lines all went to the game chat
CHAT_SETTLE_S = 20.0  # (batch323) a pending reply is judged only this long after its record: chat-log.py reads every 5 s


def rid_of(rec):
    """(batch323) A reply's request id: the line it answers and its parts (and `again`'s time when given)."""
    return "op-" + hashlib.sha1(json.dumps([rec.get("to"), rec.get("parts"), rec.get("again")]).encode()).hexdigest()[:16]


def chat_rows(run):
    out = []
    try:
        with open(os.path.join(run, "chat.jsonl"), errors="replace") as f:
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


def chat_seq(run):
    return max((r["seq"] for r in chat_rows(run)), default=0)


def ledger(run):
    """(batch323) ({rid: record} of RUN/operator-replies.jsonl, {rids marked sent})."""
    recs = {}
    for r in read_rows(os.path.join(run, viewer_replies.LINKS_NAME)):
        if r.get("rid"):
            recs.setdefault(r["rid"], r)
    return recs, operator_inbox.values_in(os.path.join(run, SENT_NAME), "rid")


def read_rows(path):
    out = []
    try:
        with open(path, errors="replace") as f:
            for raw in f:
                try:
                    r = json.loads(raw)
                except ValueError:
                    continue
                if isinstance(r, dict):
                    out.append(r)
    except OSError:
        pass
    return out


def to_send(run, rec):
    """(batch323) The parts of a pending record not yet in the game chat after its chat_seq, in order (a part sent
    before a crash is not sent again)."""
    have = [str(r.get("text")) for r in chat_rows(run) if r["seq"] > int(rec.get("chat_seq") or 0) and r.get("from") == "server"]
    out = []
    for p in rec.get("parts") or []:
        if p in have:
            have.remove(p)
        else:
            out.append(p)
    return out


def finish(run, rec, world, port, clock=time.time, wait=time.sleep):
    """(batch323) Send what a pending record still lacks, then mark it sent. Waits until CHAT_SETTLE_S after the record
    so the chat log holds whatever went out before a crash."""
    left = rec.get("t", 0) + CHAT_SETTLE_S - clock()
    if left > 0 and rec.get("resumed"):
        wait(left)
    lines = to_send(run, rec)
    if lines:
        send(lines, world, port)
    operator_inbox.write_rows(os.path.join(run, SENT_NAME), [{"rid": rec["rid"], "t": round(clock(), 1),
                                                              "sent": len(lines), "parts": len(rec.get("parts") or [])}])
    return lines


def resume(run, world, port=None, clock=time.time, wait=time.sleep, skip=None):
    """(batch323) Every pending reply of this run (a record with a rid and no sent mark), oldest first: sent once."""
    recs, sent = ledger(run)
    done = []
    for rid, rec in sorted(recs.items(), key=lambda kv: kv[1].get("t", 0)):
        if rid in sent or rid == skip:
            continue
        lines = finish(run, dict(rec, resumed=True), rec.get("world") or world, port, clock, wait)
        print(f"resumed {rid} ({rec.get('to')}): sent {len(lines)} of {len(rec.get('parts') or [])} part(s), the rest "
              f"were in the game chat already")
        done.append(rid)
    return done


class locked:
    """(batch323) One opreply at a time per run (RUN/.opreply.lock)."""
    def __init__(self, run):
        self.path = os.path.join(run, ".opreply.lock")

    def __enter__(self):
        self.f = open(self.path, "a")
        fcntl.flock(self.f, fcntl.LOCK_EX)
        return self

    def __exit__(self, *exc):
        fcntl.flock(self.f, fcntl.LOCK_UN)
        self.f.close()


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
    ap.add_argument("--update", metavar="ID", help="also add or move this Updates row (site/content/operator-updates.json)")
    ap.add_argument("--title", help="--update: the row's title (needed for a new row)")
    ap.add_argument("--area", help="--update: harness, stream or site")
    ap.add_argument("--work", help="--update: the batch doing it (needed past planned)")
    ap.add_argument("--status", default="planned", choices=("planned", "in progress"), help="--update: planned (default) or in progress")
    ap.add_argument("--updates-file", help=argparse.SUPPRESS)  # tests: another JSON
    ap.add_argument("--resume", action="store_true", help="(batch323) send this run's pending replies (a crash or failed "
                    "send left them), each once, and nothing else")
    ap.add_argument("--again", action="store_true", help="(batch323) send a reply already sent, as a new request")
    a = ap.parse_args(argv)
    if (a.title or a.area or a.work or a.status != "planned") and not a.update:
        ap.error("--title, --area, --work and --status go with --update ID")
    run = a.run or latest_run(os.path.join(os.path.dirname(HERE), "runs"))
    if a.resume:
        if not run:
            sys.exit("opreply: no run folder (--run)")
        with locked(run):
            done = resume(run, a.world, a.port)
        print(f"{len(done)} pending repl{'y' if len(done) == 1 else 'ies'} sent" if done else "nothing pending")
        return 0
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
    if a.again:
        rec["again"] = rec["t"]
    path = os.path.join(run, viewer_replies.LINKS_NAME) if run else None
    print(f"answers {ident} ({name}, {hm(question['t']) if isinstance(question.get('t'), (int, float)) else '?'}): {str(question.get('text'))[:100]}"
          + (f" (from {found_in}'s inbox; the record goes to {os.path.basename(run)})" if found_in and found_in != os.path.basename(run) else ""))
    for line in lines:
        print("  " + line)
    if a.sent:
        rec["sent"] = [int(x) for x in a.sent]
    if not a.update:
        return deliver(a, rec, lines, path)
    # (d24 batch180) the Updates row in the same call: checked first, under its lock, written after the reply went
    import operator_updates as ou
    upath = a.updates_file or str(ou.DEFAULT)
    asked = (datetime.datetime.fromtimestamp(question["t"], ou.updates.PACIFIC).strftime(ou.updates.FMT)
             if isinstance(question.get("t"), (int, float)) else None)
    with ou.locked(upath):
        data = ou.read(upath)
        said = ou.upsert(data, a.update, a.status, title=a.title, area=a.area, work=a.work, name=name, ref=ident, asked=asked)
        if a.dry_run:
            print(f"update (not written): {said}")
            return deliver(a, rec, lines, path)
        # (batch323) the Updates row is saved after the pending record and before the send, so a reply never goes
        # out without its row; the row shows the reply once it is marked sent
        code = deliver(a, rec, lines, path, before_send=lambda: ou.write(upath, data))
    print(f"update {said} (the reply shows under it once the site is rebuilt)")
    return code


def deliver(a, rec, lines, path, before_send=None):
    """The record first (the stream service links each part as it arrives), then the lines to the game chat.
    (batch323) The record is the pending request, durable before anything is sent; the sent mark comes after."""
    if a.dry_run:
        print(f"dry run: nothing sent; the record would go to {path}")
        return 0
    if not path:
        sys.exit("opreply: no run folder (--run)")
    run = os.path.dirname(path)
    with locked(run):
        rec["rid"] = rid = rid_of(rec)
        if not a.sent:
            resume(run, a.world, a.port, skip=rid)  # older pending replies first, each once
        recs, sent = ledger(run)
        if rid in sent:
            if before_send:
                before_send()
            print(f"already sent as {rid} ({os.path.basename(run)}): nothing sent again (--again sends it anew)")
            return 0
        if rid in recs:
            rec = dict(recs[rid], resumed=True)  # pending from an earlier call: finished now, once
        else:
            rec["chat_seq"] = chat_seq(run)
            operator_inbox.write_rows(path, [rec])
        if before_send:
            before_send()
        if a.sent:
            operator_inbox.write_rows(os.path.join(run, SENT_NAME), [{"rid": rid, "t": round(time.time(), 1), "sent": 0,
                                                                      "parts": len(lines), "linked": True}])
            print(f"linked {len(lines)} sent line{'s' if len(lines) > 1 else ''} in {path} (the stream service reads them at its next chat read)")
            return 0
        out = finish(run, rec, a.world, a.port)
    print(f"sent {len(out)} line{'s' if len(out) != 1 else ''} to world {a.world}; linked in {path} as {rid}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
