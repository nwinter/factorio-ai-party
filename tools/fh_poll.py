#!/usr/bin/env python3
"""fh poll: the site's polls, for agents (bin/fh runs this file; no game call, no token, no network):

  fh poll                                                    open polls (id, question, intro, options with details,
                                                             counts: viewers, agents, together; closing time; your vote)
                                                             and the latest closed ones' results
  fh poll vote --args '{"id":1,"option":2,"comment":"..."}'  your vote (one per agent per poll; a later one replaces it)
  fh poll suggest --args '{"question":"...","options":["...","..."],"hours":12}'   a poll idea to the operator (500 bytes)

The workspace's fh passes --bot and --journal: the workspace is the journal's folder, the run its parent. Reads
RUN/polls.json, which site/polls_relay.py (the operator's, with the site's token) keeps fresh every 30 s. vote and
suggest append a request to WORKSPACE/.poll-requests.jsonl; the relay posts the vote as this agent or files the idea in
the operator inbox, and answers in WORKSPACE/.poll-replies.jsonl, which this waits for (up to 20 s).
"""
import argparse, json, os, secrets, sys, time

STALE_S = 300
SUGGEST_MAX = 500
WAIT_S = 20.0


def paths(a):
    ws = os.path.dirname(os.path.abspath(a.journal)) if a.journal else os.getcwd()
    run = a.run or os.path.dirname(ws)
    return ws, os.environ.get("FH_POLLS_FILE") or os.path.join(run, "polls.json")


def load(polls_file, now):
    try:
        with open(polls_file) as f:
            d = json.load(f)
    except (OSError, ValueError):
        return None, "polls: no poll data on this machine yet (the operator's polls relay writes it)"
    age = now - float(d.get("fetched") or 0)
    if age > STALE_S:
        return d, f"polls: the poll data is {int(age // 60)} min old (the site did not answer since); counts may have changed"
    return d, None


def left(s):
    m = max(0, round(s / 60))
    return f"{m // 60} h {m % 60:02d} min" if m >= 60 else f"{m} min"


def poll_lines(p, mine, now_site):
    out = []
    is_open = p.get("status") == "open" and p.get("closes", 0) > now_site
    head = f"poll #{p['id']} " + (f"open, closes in {left(p['closes'] - now_site)}" if is_open else "closed") + f": {p['question']}"
    out.append(head)
    if p.get("intro"):
        out.append(f"  intro: {p['intro']}")
    vc = p.get("viewer_counts") or p.get("counts") or []
    ac = p.get("agent_counts") or [0] * len(p.get("options") or [])
    details = p.get("details") or []
    top = max(p.get("counts") or [0])
    for i, o in enumerate(p.get("options") or []):
        n = (p.get("counts") or [0] * (i + 1))[i]
        mark = (" [your vote]" if mine and mine.get("option") == i else "") + (" [most votes]" if not is_open and n == top and n else "")
        out.append(f"  {i}. {o}: {n} votes (viewers {vc[i] if i < len(vc) else 0}, agents {ac[i] if i < len(ac) else 0}){mark}")
        if is_open and i < len(details) and details[i]:
            out.append(f"     details: {details[i]}")
    out.append(f"  total {p.get('total', 0)} (viewers {p.get('viewer_total', p.get('total', 0))}, agents {p.get('agent_total', 0)})")
    if is_open:
        out.append(f"  vote: ./fh poll vote --args '{{\"id\":{p['id']},\"option\":K,\"comment\":\"...\"}}'" +
                   (" (replaces your vote)" if mine else ""))
    return out


def read(a, now):
    ws, polls_file = paths(a)
    d, note = load(polls_file, now)
    if d is None:
        return {"ok": False, "text": note}
    bot = a.bot or os.path.basename(ws)
    site_now = float(d.get("now") or d.get("fetched") or now) + (now - float(d.get("fetched") or now))
    lines = [note] if note else []
    open_polls = d.get("open") or []
    votes = d.get("agent_votes") or {}
    for p in open_polls:
        lines += poll_lines(p, (votes.get(str(p["id"])) or {}).get(bot), site_now)
    if not open_polls:
        lines.append("no poll is open")
    for p in (d.get("closed") or [])[:3]:
        lines += poll_lines(p, None, site_now)
    return {"ok": True, "text": "\n".join(lines), "open": open_polls, "closed": (d.get("closed") or [])[:3]}


def file_request(ws, req, now, wait_s, sleep=time.sleep, clock=time.time):
    """Append the request; wait for the relay's answer by rid. The answer, or None after wait_s."""
    rid = secrets.token_hex(8)
    req = {"rid": rid, "t": round(now, 1), **req}
    with open(os.path.join(ws, ".poll-requests.jsonl"), "a") as f:
        f.write(json.dumps(req, ensure_ascii=False) + "\n")
    end = clock() + wait_s
    while True:
        try:
            with open(os.path.join(ws, ".poll-replies.jsonl")) as f:
                for line in f:
                    try:
                        r = json.loads(line)
                    except ValueError:
                        continue
                    if r.get("rid") == rid:
                        return r
        except OSError:
            pass
        if clock() >= end:
            return None
        sleep(0.5)


def vote(a, now, **kw):
    ws, polls_file = paths(a)
    try:
        args = json.loads(a.args or "{}")
        pid, option = int(args["id"]), int(args["option"])
        comment = str(args.get("comment") or "")
    except (ValueError, KeyError, TypeError):
        return {"ok": False, "text": "refused: --args '{\"id\":N,\"option\":K,\"comment\":\"...\"}' (comment optional); nothing filed"}
    if len(comment) > 200:
        return {"ok": False, "text": f"refused: the comment is {len(comment)} characters, over 200; nothing filed"}
    d, _ = load(polls_file, now)
    if d is not None:
        p = next((x for x in d.get("open") or [] if x.get("id") == pid), None)
        if p is None:
            return {"ok": False, "text": f"refused: poll #{pid} is not open (./fh poll lists the open ones); nothing filed"}
        if not 0 <= option < len(p.get("options") or []):
            return {"ok": False, "text": f"refused: poll #{pid} has options 0 to {len(p['options']) - 1}; nothing filed"}
    r = file_request(ws, {"kind": "vote", "id": pid, "option": option, "comment": comment}, now, kw.get("wait_s", WAIT_S),
                     **{k: v for k, v in kw.items() if k != "wait_s"})
    if r is None:
        return {"ok": True, "text": f"vote on poll #{pid} filed; no answer from the operator's polls relay within {WAIT_S:g} s "
                                    "(it counts once the relay posts it; ./fh poll shows your vote)"}
    if not r.get("ok"):
        return {"ok": False, "text": f"vote on poll #{pid} not counted: {r.get('error')}"}
    c, v, ag = r.get("counts") or [], r.get("viewer_counts") or [], r.get("agent_counts") or []
    counts = "; ".join(f"{i}: {c[i]} (viewers {v[i] if i < len(v) else 0}, agents {ag[i] if i < len(ag) else 0})" for i in range(len(c)))
    return {"ok": True, "text": f"vote on poll #{pid} counted: option {r.get('option')}" + (" (replaces your earlier vote)" if r.get("replaced") else "")
                                + (f"; counts now {counts}" if counts else "")}


def suggest(a, now, **kw):
    ws, _ = paths(a)
    raw = a.args or ""
    if len(raw.encode()) > SUGGEST_MAX:
        return {"ok": False, "text": f"refused: {len(raw.encode())} bytes, over {SUGGEST_MAX}; nothing filed"}
    try:
        args = json.loads(raw or "{}")
        q, opts = str(args["question"]).strip(), [str(o).strip() for o in args["options"] if str(o).strip()]
        hours = args.get("hours")
        hours = None if hours in (None, "") else float(hours)
    except (ValueError, KeyError, TypeError):
        return {"ok": False, "text": "refused: --args '{\"question\":\"...\",\"options\":[\"...\",\"...\"],\"hours\":N}' (hours optional); nothing filed"}
    if not q or not 2 <= len(opts) <= 6:
        return {"ok": False, "text": "refused: a question and 2 to 6 options; nothing filed"}
    req = {"kind": "suggest", "question": q, "options": opts}
    if hours:
        req["hours"] = hours
    r = file_request(ws, req, now, kw.get("wait_s", WAIT_S), **{k: v for k, v in kw.items() if k != "wait_s"})
    if r is None:
        return {"ok": True, "text": f"poll idea filed; no answer from the operator's polls relay within {WAIT_S:g} s (it reaches the operator inbox when the relay runs)"}
    if not r.get("ok"):
        return {"ok": False, "text": f"poll idea not filed: {r.get('error')}"}
    return {"ok": True, "text": "poll idea filed in the operator inbox; the operator decides whether to run it"}


def main(argv=None, now=None, **kw):
    ap = argparse.ArgumentParser(prog="fh poll", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("sub", nargs="?", choices=["vote", "suggest", "list"], default="list")
    ap.add_argument("--args")
    ap.add_argument("--format", choices=["compact", "json"], default="compact")
    ap.add_argument("--bot")
    ap.add_argument("--journal")
    ap.add_argument("--run", help="the run's folder (default: the workspace's parent)")
    a, _ = ap.parse_known_args(argv)
    now = time.time() if now is None else now
    r = vote(a, now, **kw) if a.sub == "vote" else suggest(a, now, **kw) if a.sub == "suggest" else read(a, now)
    if a.format == "json":
        print(json.dumps({"ok": r["ok"], "result": {k: v for k, v in r.items() if k != "ok"}}, ensure_ascii=False))
    else:
        print(r["text"])
    return 0 if r["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
