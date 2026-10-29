#!/usr/bin/env python3
"""fh poll (tools/fh_poll.py) and the operator's polls relay (site/polls_relay.py) over a fake API in a temp run:
python3 tools/test_fh_poll.py

- the relay writes RUN/polls.json with the open polls' agent votes; `fh poll` prints the open poll (intro, options
  with details, counts together and apart, closing time, the vote call) and the closed one's result;
- `fh poll vote` files a request in the agent's own workspace; the relay posts it as that agent (the folder, not a
  field) with its game name and the token, answers by rid, and fh prints the counts; a later vote replaces it;
  a closed poll or a bad option is refused before anything is filed;
- `fh poll suggest` over 500 bytes is refused; one under goes to the operator inbox as one line; viewers' ideas from
  the site go there once each (the cursor beside the runs).
"""
import contextlib, io, json, os, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "site"))
import fh_poll  # noqa: E402
import polls_relay  # noqa: E402

NOW = 1792200000.0
TOK = "t" * 20


class FakeAPI:
    def __init__(self):
        self.calls = []
        self.p1 = {"id": 1, "question": "Should the AI team use blueprints made by people?", "intro": "Until today the agents designed their own builds.",
                   "options": ["No", "Ideas only", "Study, then rebuild"], "details": ["Benefits: own work.", "", "Benefits: they learn."],
                   "counts": [3, 1, 0], "total": 4, "viewer_counts": [3, 1, 0], "viewer_total": 4, "agent_counts": [0, 0, 0], "agent_total": 0,
                   "opens": NOW - 3600, "closes": NOW + 11 * 3600, "created_by": "operator", "status": "open", "left_s": 11 * 3600, "comments": []}
        self.p0 = {"id": 0, "question": "Trains or belts?", "intro": "", "options": ["Trains", "Belts"], "details": ["", ""], "counts": [5, 2],
                   "total": 7, "viewer_counts": [4, 2], "viewer_total": 6, "agent_counts": [1, 0], "agent_total": 1, "opens": NOW - 90000,
                   "closes": NOW - 3600, "status": "closed", "left_s": 0, "comments": []}
        self.agent_votes = {}
        self.ideas = [{"id": 3, "t": NOW - 50, "name": "idea fan", "question": "Trains?", "intro": "", "options": ["yes", "no"],
                       "details": ["", ""], "hours": 6}]

    def __call__(self, method, url, body=None, tok=None):
        self.calls.append((method, url, body, tok))
        if method == "GET" and url.endswith("/v1/polls"):
            return 200, {"schema": 1, "now": NOW, "open": [self.p1], "closed": [self.p0]}
        if url.endswith("/v1/polls/1/voters"):
            assert tok == TOK
            return 200, {"poll": self.p1, "votes": [{"voter": "agent:" + k, "agent": True, "current": 1, "option": v, "comment": "", "t": NOW}
                                                    for k, v in self.agent_votes.items()] + [{"voter": "ab12", "agent": False, "current": 1, "option": 0, "t": NOW}]}
        if "/suggestions?after=" in url:
            after = int(url.rsplit("=", 1)[1])
            return 200, {"ideas": [x for x in self.ideas if x["id"] > after], "last_id": 3}
        if method == "POST" and url.endswith("/v1/polls/1/vote"):
            assert tok == TOK
            replaced = body["agent"] in self.agent_votes
            if replaced:
                self.p1["agent_counts"][self.agent_votes[body["agent"]]] -= 1
            self.agent_votes[body["agent"]] = body["option"]
            self.p1["agent_counts"][body["option"]] += 1
            self.p1["counts"] = [a + b for a, b in zip(self.p1["viewer_counts"], self.p1["agent_counts"])]
            self.p1["agent_total"] = sum(self.p1["agent_counts"])
            self.p1["total"] = sum(self.p1["counts"])
            return 200, {"ok": True, "vote": {"option": body["option"]}, "replaced": replaced, "poll": self.p1}
        return 404, {"error": "not found"}


def fh(argv, ws, relay=None):
    out = io.StringIO()
    kw = {}
    if relay is not None:
        kw = {"sleep": lambda s: relay.requests(), "wait_s": 5.0}
    with contextlib.redirect_stdout(out):
        code = fh_poll.main(argv + ["--bot", os.path.basename(ws), "--journal", os.path.join(ws, "journal.jsonl")], now=NOW + 10, **kw)
    return code, out.getvalue()


def main():
    with tempfile.TemporaryDirectory() as d:
        run = os.path.join(d, "runs", "shift25")
        ws = os.path.join(run, "grok")
        os.makedirs(ws)
        api = FakeAPI()
        relay = polls_relay.Relay(run, "https://api.test", TOK, fetch=api, clock=lambda: NOW, names={"grok": "Grok"})
        # no data yet
        code, out = fh([], ws)
        assert code == 1 and "no poll data" in out, out
        relay.step()
        snap = json.load(open(os.path.join(run, "polls.json")))
        assert snap["fetched"] == NOW and [p["id"] for p in snap["open"]] == [1] and snap["agent_votes"] == {"1": {}}, snap
        # viewers' ideas: into the inbox once, the cursor beside the runs
        inbox = os.path.join(run, "operator-inbox.jsonl")
        rows = [json.loads(l) for l in open(inbox)]
        assert rows == [{"t": NOW - 50, "agent": "viewer idea fan", "text": "poll idea: Trains? | 0. yes; 1. no | 6 h", "viewer": True,
                         "source": "site", "poll_idea": True, "rid": "idea:3"}], rows  # (batch323: written once by rid)
        assert json.load(open(os.path.join(d, "runs", "poll-ideas.json"))) == {"after": 3}
        relay.next_ideas = 0
        relay.step()
        assert len(open(inbox).readlines()) == 1
        # fh poll: the open poll in full, the closed one's result
        code, out = fh([], ws)
        assert code == 0, out
        assert "poll #1 open, closes in 11 h 00 min: Should the AI team use blueprints made by people?" in out, out
        assert "intro: Until today" in out and "0. No: 3 votes (viewers 3, agents 0)" in out and "details: Benefits: own work." in out, out
        assert "vote: ./fh poll vote --args '{\"id\":1,\"option\":K,\"comment\":\"...\"}'" in out, out
        assert "poll #0 closed: Trains or belts?" in out and "0. Trains: 5 votes (viewers 4, agents 1) [most votes]" in out, out
        assert "consider" not in out.lower() and "should you" not in out.lower()
        # refusals before anything is filed
        code, out = fh(["vote", "--args", '{"id":0,"option":1}'], ws)
        assert code == 1 and "poll #0 is not open" in out, out
        code, out = fh(["vote", "--args", '{"id":1,"option":7}'], ws)
        assert code == 1 and "options 0 to 2" in out, out
        assert not os.path.exists(os.path.join(ws, ".poll-requests.jsonl"))
        # a vote: filed in the workspace, posted as the folder's agent with its game name, answered by rid
        code, out = fh(["vote", "--args", '{"id":1,"option":2,"comment":"we learn from them","agent":"astra"}'], ws, relay)
        assert code == 0 and "vote on poll #1 counted: option 2; counts now" in out and "2: 1 (viewers 0, agents 1)" in out, out
        post = [c for c in api.calls if c[0] == "POST"][-1]
        assert post[2] == {"agent": "grok", "name": "Grok", "option": 2, "comment": "we learn from them"} and post[3] == TOK, post
        code, out = fh(["vote", "--args", '{"id":1,"option":0}'], ws, relay)
        assert "(replaces your earlier vote)" in out, out
        relay.step()  # the snapshot right after a vote: the agent's own vote shows
        code, out = fh([], ws)
        assert "0. No: 4 votes (viewers 3, agents 1) [your vote]" in out and "(replaces your vote)" in out, out
        # a second pass handles nothing twice
        n = len([c for c in api.calls if c[0] == "POST"])
        relay.requests()
        assert len([c for c in api.calls if c[0] == "POST"]) == n
        # suggest: over 500 bytes refused, under filed in the inbox as one line
        big = json.dumps({"question": "x" * 480, "options": ["a", "b"]})
        code, out = fh(["suggest", "--args", big], ws, relay)
        assert code == 1 and "over 500" in out and "nothing filed" in out, out
        code, out = fh(["suggest", "--args", '{"question":"Rail or bots for ore?","options":["rail","bots"],"hours":12}'], ws, relay)
        assert code == 0 and "filed in the operator inbox" in out, out
        last = json.loads(open(inbox).readlines()[-1])
        assert {k: v for k, v in last.items() if k != "rid"} == {"t": NOW, "agent": "grok", "text": "poll idea: Rail or bots for ore? | 0. rail; 1. bots | 12 h", "poll_idea": True} \
            and last["rid"].startswith("grok:"), last
        # JSON output
        code, out = fh(["--format", "json"], ws)
        assert json.loads(out)["ok"] is True and json.loads(out)["result"]["open"][0]["id"] == 1
    print("fh poll: ok (relay snapshot with agents' votes, the read, votes filed and posted as the workspace's agent, "
          "refusals, ideas from agents and viewers into the operator inbox once)")


if __name__ == "__main__":
    main()
