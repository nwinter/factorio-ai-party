#!/usr/bin/env python3
"""Routing unaddressed viewer lines by content, no network: python3 tools/stream/test_viewer_routing.py

d17 batch35 D4 (Nick 14:10): a line that names no agent went to the viewer's last agent within 5 min, else round robin,
whatever it was about. Checks: a place the line names goes to its claims' owners (one or two) without Clef; the rest get
a second choice question in the same Clef call (the agent the viewer was talking to, an agent by its work, two agents,
the operator, other viewers); unsure is the rotation; the route and its reason reach the delivery; off by default.
"""
import json, os, re, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import router as R  # noqa: E402
import viewers as V  # noqa: E402

failures = 0


def check(name, ok, detail=""):
    global failures
    if ok:
        print(f"ok   {name}")
    else:
        failures += 1
        print(f"FAIL {name}  {detail}")


V.log = lambda msg: None
AGENTS = [{"name": "sol", "display_name": "Sol", "where": "Fulgora", "job": "Wayfarer ammo and railguns"},
          {"name": "opus", "display_name": "Opus", "where": "Nauvis", "job": "steel and rails"},
          {"name": "muse", "display_name": "Muse", "where": "Fulgora", "job": "holmium plates"},
          {"name": "astra", "display_name": "Astra", "where": "Nauvis"}, {"name": "luna", "display_name": "Luna", "where": "Gleba"}]
CLAIMS = [{"title": "Wayfarer: ammo run to Aquilo", "owner": "sol"}, {"title": "Fulgora scrap recycling", "owner": "sol"},
          {"title": "Fulgora holmium", "owner": "muse"}, {"title": "Nauvis steel", "owner": "opus"},
          {"title": "Nauvis walls", "owner": "astra"}, {"title": "nauvis oil", "owner": "luna"},
          {"title": "Gleba eggs", "owner": "luna"}, {"title": "someone's", "owner": "nobody"}]
team = R.Team(AGENTS, CLAIMS, ["Wayfarer", "Kestrel II"])

# ---- Team: lines and places ------------------------------------------------------------------------------------------
check("an agent's line: where, doing, claims", team.lines["sol"].startswith("Fulgora, doing Wayfarer ammo and railguns, claims Wayfarer"), team.lines["sol"])
check("no work shown", R.Team([{"name": "x"}]).lines["x"] == "no work shown")
check("a platform named: its claim's owner", team.place_owners("the wayfarer needs more rockets") == ("Wayfarer", ["sol"]))
check("a planet two agents claim: both", team.place_owners("fulgora is out of holmium") == ("fulgora", ["sol", "muse"]))
check("a planet three claim: no owner from claims", team.place_owners("nauvis needs walls") is None)
check("a place nobody claims: none", team.place_owners("kestrel ii has no ammo") is None)
check("word bounded", team.place_owners("gleban stuff") is None and team.place_owners("gleba is green") == ("gleba", ["luna"]))
check("held: open claims, and tasks, requests and projects claimed, doing or blocked", [it["title"] for it in R.held([
    {"kind": "claim", "status": "open", "title": "a", "owner": "sol"}, {"kind": "task", "status": "open", "title": "b", "owner": "sol"},
    {"kind": "task", "status": "doing", "title": "c", "owner": "sol"}, {"kind": "project", "status": "blocked", "title": "d", "owner": "opus"},
    {"kind": "request", "status": "done", "title": "e", "owner": "opus"}, {"kind": "task", "status": "doing", "title": "f"}])] == ["a", "c", "d"])
check("from the snapshot: offline agents and claims done left out",
      R.Team.from_snapshot({"agents": [dict(AGENTS[0]), dict(AGENTS[1], activity="offline")], "space": {"platforms": [{"name": "Wayfarer"}]}},
                           [{"kind": "claim", "status": "doing", "title": "Wayfarer", "owner": "sol"}, {"kind": "task", "status": "doing", "title": "Petrel courier", "owner": "sol"},
                            {"kind": "claim", "status": "done", "title": "Wayfarer old", "owner": "opus"}]).names == ["sol"])
q = team.question({"name": "ann", "text": "the steel line is starving"}, prev="opus")
check("the question: each agent by its work, the viewer's last agent, operator, viewers (no unsure label)",
      set(q["criteria"]) == {"sol", "opus", "muse", "astra", "luna", "same", "operator", "viewers"}
      and q["criteria"]["opus"] == "about Opus's work: Nauvis, doing steel and rails, claims Nauvis steel"
      and "went to Opus" in q["criteria"]["same"] and '"text": "the steel line is starving"' in q["instructions"], q)
check("no prev: no 'same' label", "same" not in team.question({"name": "a", "text": "x"})["criteria"])
chars = len(json.dumps(team.question({"name": "ann", "text": "x" * 120}, prev="opus")))
check("a routing question stays small (5 agents)", chars < 1100, chars)

# ---- Team.pick ------------------------------------------------------------------------------------------------------
p = lambda **probs: {"choice": max(probs, key=probs.get), "probabilities": probs}  # noqa: E731
check("an agent at ROUTE_SURE: it", team.pick(p(opus=0.7, sol=0.1, unsure=0.2))[:2] == ("agents", ["opus"]))
check("two agents each at ROUTE_TWO: both", team.pick(p(opus=0.4, sol=0.35, unsure=0.25))[:2] == ("agents", ["opus", "sol"]))
check("under ROUTE_SURE: unsure (rotation)", team.pick(p(opus=0.45, sol=0.2, unsure=0.35)) is None)
check("unsure label: rotation", team.pick(p(unsure=0.8, opus=0.2)) is None)
check("same: the viewer's last agent", team.pick(p(same=0.9, opus=0.1), prev="luna") == ("agents", ["luna"], "a follow-up to this viewer's last line"))
check("operator", team.pick(p(operator=0.8, sol=0.2))[0] == "operator")
check("viewers", team.pick(p(viewers=0.9, sol=0.1))[0] == "viewers")
check("viewers under VIEWERS_SURE: rotation (it would drop the line)", team.pick(p(viewers=0.7, sol=0.3)) is None)
check("a choice with no probabilities", team.pick({"choice": "sol"})[:2] == ("agents", ["sol"]))
check("no answer: rotation", team.pick(None) is None)

# ---- in the feed: one Clef call, routes onto the delivery -------------------------------------------------------------


class Harness:
    def __init__(self):
        self.says = []

    def command(self, cmd):
        req = json.loads(re.search(r"\[(=*)\[(.*)\]\1\]", cmd).group(2))
        if req["action"] == "votes":
            return json.dumps({"ok": True, "result": {"muted": [], "open": []}})
        self.says.append(req["args"])
        return json.dumps({"ok": True, "result": {"posted": True, "seq": len(self.says)}})


class AI:
    """Clef: fine for every moderation question; routing answers by a word in the line."""
    ROUTES = {"steel": {"opus": 0.8, "unsure": 0.2}, "website": {"operator": 0.9, "sol": 0.1},
              "anyone else": {"viewers": 0.85, "sol": 0.15}, "base": {"unsure": 0.6, "opus": 0.4},
              "trains": {"opus": 0.4, "astra": 0.4, "unsure": 0.2}}

    def __init__(self):
        self.calls, self.qs = 0, []

    def run(self, model, body):
        self.calls += 1
        self.qs.append(body["questions"])
        out = {}
        for k, q in body["questions"].items():
            if k.startswith("v"):
                out[k] = {"choice": "fine"}
            else:
                probs = next((v for w, v in self.ROUTES.items() if w in q["instructions"]), {"unsure": 1.0})
                out[k] = {"choice": max(probs, key=probs.get), "probabilities": probs}
        return {"answers": out}


NOW = 1792353000.0
tmp = tempfile.mkdtemp()
switch = os.path.join(tmp, "relay.on")
open(switch, "w").close()
roster = [(a["name"], a["display_name"]) for a in AGENTS]


def setup():
    h = Harness()
    relay = V.Relay(h, switch, gap=0, author_gap=0, roster=roster)
    relay.set_team(team)
    ai = AI()
    feed = V.Feed({}, V.Filter([a["name"] for a in AGENTS]), V.Clef(ai), relay=relay, inbox=os.path.join(tmp, "inbox.jsonl"))
    return h, relay, ai, feed


def line(i, name, text, t):
    return {"id": f"site:{i}", "source": "site", "author": "site:" + name, "name": name, "text": text, "t": t}


h, relay, ai, feed = setup()
feed.ingest([line(1, "ann", "the steel furnaces are starving again", NOW)], [], now=NOW)
check("off by default: no routing question", ai.calls == 1 and not [k for k in ai.qs[0] if k.startswith("r")], ai.qs)
relay.step(NOW + 1)
d = {r["id"]: r for r in feed.lane()[1]["delivery"]}
check("off: the rotation, no route reason", d["site:1"]["status"] == "relayed" and d["site:1"]["why"] is None, d["site:1"])

open(os.path.join(tmp, R.ROUTE_SWITCH), "w").close()
h, relay, ai, feed = setup()
check("on with the switch file and a team", relay.routing())
batch = [line(10, "ann", "the steel furnaces are starving again", NOW), line(11, "bo", "the wayfarer needs more rockets", NOW),
         line(12, "cy", "the website chat is lagging for me", NOW), line(13, "di", "did anyone else see that explosion", NOW),
         line(14, "ed", "the base looks great", NOW), line(15, "fu", "the trains keep stopping at the junction", NOW),
         line(16, "gi", "sol, check the rails", NOW)]
feed.ingest(batch, [], now=NOW)
# (d27 batch264 CC) one Clef call a line (a line's verdict depends on the lines asked with it), its routing question in
# the same call
check("one Clef call a line, both questions in it", ai.calls == 7 and all(sorted(q) in (["v0"], ["r0", "v0"]) for q in ai.qs), ai.qs)
asked = sorted(m["text"] for m in batch for q in ai.qs if "r0" in q and json.dumps(m["text"]) in q["v0"]["instructions"])
check("routing questions only for unaddressed lines without a claimed place",
      asked == sorted(batch[i]["text"] for i in (0, 2, 3, 4, 5)), asked)
for k in range(8):
    relay.step(NOW + 1 + k)
d = {r["id"]: r for r in feed.lane()[1]["delivery"]}
check("a place by its claim: to Sol, about Wayfarer", d["site:11"]["status"] == "relayed" and d["site:11"]["to"] == "sol" and d["site:11"]["why"] == "about Wayfarer", d["site:11"])
check("Clef's pick by work: to Opus, with why", d["site:10"]["to"] == "opus" and d["site:10"]["why"].startswith("about its work (Nauvis, doing steel and rails"), d["site:10"])
check("about the site: the operator's inbox, no agent", d["site:12"]["status"] == "operator" and "site" in d["site:12"]["why"]
      and any(json.loads(r)["text"] == "the website chat is lagging for me" for r in open(os.path.join(tmp, "inbox.jsonl"))), d["site:12"])
check("to other viewers: shown, not relayed", d["site:13"]["status"] == "not_relayed" and d["site:13"]["why"].startswith("to other viewers"), d["site:13"])
check("unsure: the rotation, said", d["site:14"]["status"] == "relayed" and d["site:14"]["why"] == "in turn (Clef unsure)", d["site:14"])
sent = {s["text"]: s for s in h.says}
check("two agents: both @-named", "@opus @astra the trains keep stopping at the junction" in sent, list(sent))
check("a named agent: as before, no routing", d["site:16"]["to"] == "sol" and d["site:16"]["why"] is None, d["site:16"])
check("the viewer's game line names whom (@sol for the claim route)", "@sol the wayfarer needs more rockets" in sent, list(sent))
os.remove(os.path.join(tmp, R.ROUTE_SWITCH))
print()
print("all passed" if failures == 0 else f"{failures} failed")
sys.exit(1 if failures else 0)
