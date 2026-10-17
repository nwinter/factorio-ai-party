#!/usr/bin/env python3
"""The site's polls on the Mac (d16 17:15; docs/LIVE-API.md "Polls"): the one process that holds the publish token for
them. start-team.sh runs it beside push_live.py:

  python3 site/polls_relay.py runs/shift25                # every 5 s
  python3 site/polls_relay.py runs/shift25 --once

- RUN/polls.json: GET /v1/polls every 30 s (and right after an agent's vote), with each open poll's agent votes from the
  voter log ({poll id: {agent: {option, comment, t}}}). `./fh poll` (tools/fh_poll.py), the agents' team-block line
  (factorio-harness host/polls.ts), the stream's poll strip and the casters read this file; nothing else calls the API.
- Agents' requests: `./fh poll vote|suggest` appends {rid, kind, ...} to the agent's own workspace,
  RUN/AGENT/.poll-requests.jsonl (an agent's sandbox writes only there; the agent is the folder, never a field). A vote
  is posted as that agent (voter agent:NAME, its game name); an idea becomes one line in RUN/operator-inbox.jsonl.
  The answer goes to RUN/AGENT/.poll-replies.jsonl by rid, where fh waits for it. RUN/.poll-relay.json keeps how many
  lines of each file were handled.
- Viewers' ideas (POST /v1/polls/suggest on the site): GET /v1/polls/suggestions every 60 s, one inbox line each, as
  the relay files @operator lines (agent "viewer NAME", viewer: true, source "site", poll_idea: true). The cursor is
  runs/poll-ideas.json, so a new shift files only new ones.
"""
import argparse, json, os, sys, time, urllib.error, urllib.request
from pathlib import Path

SITE = Path(__file__).resolve().parent
REQUESTS, REPLIES = ".poll-requests.jsonl", ".poll-replies.jsonl"
SNAPSHOT_S, IDEAS_S = 30.0, 60.0
SUGGEST_MAX = 500


def api_url():
    return json.loads((SITE / "config.json").read_text())["live_api_url"].rstrip("/")


def token():
    if os.environ.get("POG_LIVE_TOKEN"):
        return os.environ["POG_LIVE_TOKEN"]
    return json.loads((SITE / "worker" / ".secrets.json").read_text())["PUBLISH_TOKEN"]


def agent_names():
    """{key: game name} from site.json (Grok, Astra, ...)."""
    try:
        return {k: v.get("name") or k for k, v in json.loads((SITE / "content" / "site.json").read_text())["agents"].items()}
    except (OSError, ValueError, KeyError):
        return {}


def http(method, url, body=None, tok=None, timeout=15):
    """(status, parsed body); a network failure raises OSError."""
    req = urllib.request.Request(url, data=None if body is None else json.dumps(body).encode(), method=method)
    req.add_header("Content-Type", "application/json")
    req.add_header("User-Agent", "pog-polls-relay/1")
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


def write_json(path, data):
    tmp = Path(str(path) + ".tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False) + "\n")
    os.replace(tmp, path)


def read_json(path, default):
    try:
        return json.loads(Path(path).read_text())
    except (OSError, ValueError):
        return default


def idea_text(q):
    """One inbox line for a poll idea: question | 0. A; 1. B | 6 h (details and intro after, when given)."""
    opts = q.get("options") or []
    labels = [o.get("label") if isinstance(o, dict) else o for o in opts]
    details = [(o.get("details") if isinstance(o, dict) else "") or "" for o in opts]
    if not any(details) and isinstance(q.get("details"), list):  # a viewer's idea from the Worker: details beside
        details = [str(d or "") for d in q["details"]]
    text = f"poll idea: {q.get('question', '')} | " + "; ".join(f"{i}. {l}" for i, l in enumerate(labels))
    if q.get("hours"):
        text += f" | {q['hours']:g} h"
    if q.get("intro"):
        text += f" | intro: {q['intro']}"
    if any(details):
        text += " | details: " + "; ".join(f"{i}. {d}" for i, d in enumerate(details) if d)
    return text


class Relay:
    def __init__(self, run_dir, api, tok, fetch=http, clock=time.time, names=None):
        self.run = Path(run_dir)
        self.api, self.tok, self.fetch, self.clock = api.rstrip("/"), tok, fetch, clock
        self.names = names if names is not None else agent_names()
        self.inbox = self.run / "operator-inbox.jsonl"
        self.state_path = self.run / ".poll-relay.json"
        self.ideas_path = self.run.parent / "poll-ideas.json"
        self.next_snapshot = self.next_ideas = 0.0

    def to_inbox(self, row):
        with open(self.inbox, "a") as f:
            f.write(json.dumps(row, ensure_ascii=False) + "\n")

    def snapshot(self):
        """RUN/polls.json from GET /v1/polls and the open polls' agent votes. False when the API did not answer."""
        try:
            st, d = self.fetch("GET", self.api + "/v1/polls")
            if st != 200:
                return False
            votes = {}
            for p in d.get("open") or []:
                st, v = self.fetch("GET", f"{self.api}/v1/polls/{p['id']}/voters", None, self.tok)
                if st == 200:
                    votes[str(p["id"])] = {x["voter"][6:]: {"option": x["option"], "comment": x.get("comment") or "", "t": x["t"]}
                                           for x in v.get("votes") or [] if x.get("agent") and x.get("current")
                                           and str(x.get("voter", "")).startswith("agent:")}
        except OSError as e:
            print(f"polls: {e}", file=sys.stderr)
            return False
        write_json(self.run / "polls.json", {"fetched": round(self.clock(), 1), "now": d.get("now"), "open": d.get("open") or [],
                                            "closed": d.get("closed") or [], "agent_votes": votes})
        return True

    def ideas(self):
        cur = read_json(self.ideas_path, {"after": 0})
        try:
            st, d = self.fetch("GET", f"{self.api}/v1/polls/suggestions?after={int(cur.get('after') or 0)}", None, self.tok)
        except OSError as e:
            print(f"poll ideas: {e}", file=sys.stderr)
            return 0
        if st != 200:
            return 0
        n = 0
        for x in d.get("ideas") or []:
            self.to_inbox({"t": round(x.get("t") or self.clock(), 1), "agent": f"viewer {x.get('name', '')}", "text": idea_text(x),
                           "viewer": True, "source": "site", "poll_idea": True})
            cur["after"] = max(int(cur.get("after") or 0), int(x["id"]))
            n += 1
        if n:
            write_json(self.ideas_path, cur)
        return n

    def requests(self):
        """Each agent workspace's new request lines: handled once, answered by rid."""
        state = read_json(self.state_path, {})
        voted = False
        for req_file in sorted(self.run.glob("*/" + REQUESTS)):
            agent = req_file.parent.name
            try:
                lines = req_file.read_text().splitlines()
            except OSError:
                continue
            done = int(state.get(agent) or 0)
            for line in lines[done:]:
                reply = self.handle(agent, line)
                voted = voted or (reply.get("ok") and reply.get("kind") == "vote")
                with open(req_file.parent / REPLIES, "a") as f:
                    f.write(json.dumps(reply, ensure_ascii=False) + "\n")
            if len(lines) > done:
                state[agent] = len(lines)
                write_json(self.state_path, state)
        if voted:
            self.next_snapshot = 0.0  # the new counts in polls.json on the next step
        return voted

    def handle(self, agent, line):
        try:
            r = json.loads(line)
            assert isinstance(r, dict)
        except (ValueError, AssertionError):
            return {"rid": None, "ok": False, "error": "not a JSON request"}
        rid, kind = r.get("rid"), r.get("kind")
        out = {"rid": rid, "kind": kind, "t": round(self.clock(), 1)}
        if kind == "suggest":
            if len(line.encode()) > SUGGEST_MAX + 200:
                return {**out, "ok": False, "error": f"over {SUGGEST_MAX} bytes"}
            self.to_inbox({"t": out["t"], "agent": agent, "text": idea_text(r), "poll_idea": True})
            return {**out, "ok": True}
        if kind == "vote":
            body = {"agent": agent, "name": self.names.get(agent, agent), "option": r.get("option"), "comment": r.get("comment") or ""}
            try:
                st, d = self.fetch("POST", f"{self.api}/v1/polls/{int(r.get('id'))}/vote", body, self.tok)
            except (OSError, TypeError, ValueError) as e:
                return {**out, "ok": False, "error": f"the site did not answer ({type(e).__name__}); nothing counted, try again"}
            if st != 200:
                return {**out, "ok": False, "error": d.get("error", f"HTTP {st}")}
            p = d.get("poll") or {}
            return {**out, "ok": True, "id": p.get("id"), "option": (d.get("vote") or {}).get("option"),
                    "replaced": bool(d.get("replaced")), "counts": p.get("counts"), "viewer_counts": p.get("viewer_counts"),
                    "agent_counts": p.get("agent_counts")}
        return {**out, "ok": False, "error": "kind must be vote or suggest"}

    def step(self):
        now = self.clock()
        self.requests()
        if now >= self.next_snapshot:
            self.snapshot()
            self.next_snapshot = now + SNAPSHOT_S
        if now >= self.next_ideas:
            self.ideas()
            self.next_ideas = now + IDEAS_S


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("run", help="the shift's folder, runs/RUN")
    ap.add_argument("--api", default=None, help="live API base URL (default from site/config.json)")
    ap.add_argument("--interval", type=float, default=5.0)
    ap.add_argument("--once", action="store_true")
    a = ap.parse_args()
    relay = Relay(a.run, a.api or api_url(), token())
    while True:
        try:
            relay.step()
        except Exception as e:  # keep running through one bad pass
            print(f"polls relay: {type(e).__name__}: {e}", file=sys.stderr)
        if a.once:
            break
        time.sleep(a.interval)


if __name__ == "__main__":
    main()
