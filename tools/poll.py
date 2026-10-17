#!/usr/bin/env python3
"""The operator's polls on the site (Nick, d16 17:15; docs/LIVE-API.md "Polls"):

  python3 tools/poll.py create --question Q --option A --option B ... [--intro TEXT] [--hours 12]
  python3 tools/poll.py create --file POLL.json        {question, intro?, hours?, options: [label | {label, details}]}
  python3 tools/poll.py list                           open and closed polls with counts (viewers / agents)
  python3 tools/poll.py close ID                       close early
  python3 tools/poll.py voters ID                      the voter log: every vote, name, choice, time
  python3 tools/poll.py ideas [--after ID]             viewers' poll ideas (also filed into the operator inbox)
  python3 tools/poll.py hide-comment VOTE_ID           hide a comment (the vote still counts)

The API comes from site/config.json (live_api_url), the publish token from $POG_LIVE_TOKEN or site/worker/.secrets.json.
"""
import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SITE = os.path.join(REPO, "site")


def api_url():
    with open(os.path.join(SITE, "config.json")) as f:
        return json.load(f)["live_api_url"].rstrip("/")


def token():
    t = os.environ.get("POG_LIVE_TOKEN")
    if t:
        return t
    try:
        with open(os.path.join(SITE, "worker", ".secrets.json")) as f:
            return json.load(f)["PUBLISH_TOKEN"]
    except (OSError, KeyError, ValueError):
        sys.exit("no token: set POG_LIVE_TOKEN or create site/worker/.secrets.json (see site/README.md)")


def http(method, url, body=None, tok=None, timeout=15):
    """(status, parsed JSON body)."""
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Content-Type", "application/json")
    req.add_header("User-Agent", "pog-poll/1")
    if tok:
        req.add_header("Authorization", "Bearer " + tok)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read() or b"{}")
        except ValueError:
            return e.code, {"error": f"HTTP {e.code}"}


def poll_body(a):
    """The create request from --file or the flags (flags given beside --file override it)."""
    body = {}
    if a.file:
        with open(a.file) as f:
            body = json.load(f)
    if a.question:
        body["question"] = a.question
    if a.option:
        body["options"] = a.option
    if a.intro is not None:
        body["intro"] = a.intro
    if a.hours is not None:
        body["hours"] = a.hours
    body.setdefault("hours", 12)
    if not body.get("question") or len(body.get("options") or []) < 2:
        sys.exit("a question and at least two options (--question, --option ..., or --file)")
    return body


def left(s):
    m = max(0, round(s / 60))
    return f"{m // 60} h {m % 60:02d} min left" if m >= 60 else f"{m} min left"


def when(t):
    return time.strftime("%m-%d %H:%M", time.localtime(t))


def show(p, out=print):
    head = f"#{p['id']} [{p['status']}" + (f", {left(p['left_s'])}" if p["status"] == "open" else f", closed {when(p['closes'])}") + "]"
    out(f"{head} {p['question']}")
    vc, ac = p.get("viewer_counts") or p["counts"], p.get("agent_counts") or [0] * len(p["counts"])
    for i, o in enumerate(p["options"]):
        out(f"  {i}. {o}: {p['counts'][i]} (viewers {vc[i]}, agents {ac[i]})")
    out(f"  {p['total']} votes ({p.get('viewer_total', p['total'])} viewers, {p.get('agent_total', 0)} agents), "
        f"{len(p['comments'])} comments")


def main(argv=None, fetch=http):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--api", help="live API base URL (default from site/config.json)")
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("create")
    c.add_argument("--file", help="POLL.json: {question, intro?, hours?, options: [label | {label, details}]}")
    c.add_argument("--question")
    c.add_argument("--option", action="append", help="an option (2 to 6; repeat the flag)")
    c.add_argument("--intro")
    c.add_argument("--hours", type=float)
    sub.add_parser("list")
    for name in ("close", "voters"):
        sub.add_parser(name).add_argument("id", type=int)
    i = sub.add_parser("ideas")
    i.add_argument("--after", type=int, default=0)
    sub.add_parser("hide-comment").add_argument("id", type=int, help="the vote's id (voters shows it)")
    a = ap.parse_args(argv)
    api = (a.api or api_url()).rstrip("/")

    def need(status, body):
        if status != 200:
            sys.exit(f"{status}: {body.get('error', body)}")
        return body

    if a.cmd == "create":
        p = need(*fetch("POST", api + "/v1/polls", poll_body(a), token()))["poll"]
        print("opened:")
        show(p)
    elif a.cmd == "list":
        d = need(*fetch("GET", api + "/v1/polls"))
        for p in d["open"] + d["closed"]:
            show(p)
        if not d["open"] and not d["closed"]:
            print("no polls yet")
    elif a.cmd == "close":
        show(need(*fetch("POST", f"{api}/v1/polls/{a.id}/close", {}, token()))["poll"])
    elif a.cmd == "voters":
        d = need(*fetch("GET", f"{api}/v1/polls/{a.id}/voters", None, token()))
        show(d["poll"])
        for v in d["votes"]:
            flags = ("" if v["current"] else " (replaced)") + (" (comment hidden)" if v["hidden"] else "")
            who = ("AI " if v.get("agent") else "") + v["name"]
            out = f"  vote {v['id']} {when(v['t'])} {who} [{v['voter']}]: {v['option']}. {v['choice']}{flags}"
            print(out + (f" | {v['comment']}" if v["comment"] else ""))
    elif a.cmd == "ideas":
        d = need(*fetch("GET", f"{api}/v1/polls/suggestions?after={a.after}", None, token()))
        for x in d["ideas"]:
            print(f"idea {x['id']} {when(x['t'])} {x['name']}: {x['question']} | " + " / ".join(x["options"]) +
                  (f" | {x['hours']:g} h" if x.get("hours") else ""))
        if not d["ideas"]:
            print("no ideas after", a.after)
    elif a.cmd == "hide-comment":
        need(*fetch("POST", api + "/v1/mod", {"action": "hide_comment", "id": a.id}, token()))
        print("hidden")


if __name__ == "__main__":
    main()
