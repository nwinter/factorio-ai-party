#!/usr/bin/env python3
"""Replay recorded viewer lines through the content router (router.py) and compare its picks with the relay's.

  python3 tools/stream/route_replay.py --state STATE.json --chat runs/shift36/chat.jsonl LOG.jsonl [LOG.jsonl ...] [--clef]

d17 batch35 D4 (Nick 14:10: replay recorded lines before switching it on). LOG: viewers.py verdict logs
(tools/stream/logs/viewers-*.jsonl): each line that passed, with its text as the viewer wrote it. --chat: the game chat
records (runs/RUN/chat.jsonl) where the relay posted it, with the "@name " it put in front: the agent it went to. STATE:
the live state (the site's /v1/state body, or serve.py's snapshot): the team as it is now (each agent's where and job,
the board items agents hold, the platforms), used for every line. Only lines the relay sends by rotation are routed
(no agent named, no @, no staff, not to the operator or Nick, not chatter). Without --clef only the claims' places are
routed; with --clef the rest go to the real clef-flash, 24 routing questions a call (tools/stream/cfai.py credentials,
a fraction of a cent). Prints one line a message (id, name, today's agent, the new route and why, text) and a summary.
"""
import argparse, json, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import router as R  # noqa: E402
import viewers as V  # noqa: E402


def load_state(path):
    s = json.load(open(path))
    return s.get("state") or s


def items_of(state):
    """The board items the public state lists (claims, the doing items, projects); serve.py has them all."""
    b = state.get("board") or {}
    out = [dict(c, kind="claim", status="claimed") for c in b.get("claims") or []]
    out += list(b.get("doing_items") or [])
    out += [dict(p, kind="project") for p in (b.get("projects") or []) + (b.get("projects_more") or [])]
    return out


def posted(chat_paths):
    """[(viewer name, game text)] of the viewer lines the relay posted."""
    out = []
    for p in chat_paths:
        for line in open(p):
            try:
                r = json.loads(line)
            except ValueError:
                continue
            if r.get("viewer") and str(r.get("from", "")).startswith("viewer "):
                out.append((r["from"][7:], r.get("text") or ""))
    return out


def today(row, games):
    """The agents the relay put in front of this line in the game ("@sol @opus ..."), or None (not posted)."""
    head = row["text"][:40]
    for name, text in games:
        if name == row["name"] and head and head in text:
            return re.findall(r"@([\w-]+)", text[:text.index(head)]) or ["(as written)"]
    return None


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("logs", nargs="+")
    ap.add_argument("--state", required=True)
    ap.add_argument("--chat", action="append", default=[])
    ap.add_argument("--clef", action="store_true")
    ap.add_argument("--unsure", action="store_true", help="ask with an unsure label too (on the first replay Clef chose it for nearly every line)")
    a = ap.parse_args(argv)
    state = load_state(a.state)
    team = R.Team.from_snapshot(state, items_of(state))
    relay = V.Relay(None, None, roster=[(n, team.display[n]) for n in team.names])
    games = posted(a.chat)
    rows, seen = [], set()
    for path in a.logs:
        for line in open(path):
            r = json.loads(line)
            if not r.get("pass") or r["id"] in seen or r.get("source") not in ("site", "youtube"):
                continue
            seen.add(r["id"])
            t = r["text"]
            if V.to_operator(t) or V.is_chatter(t) or not relay.unaddressed({"text": t}):
                continue
            rows.append(r)
    # the agent each viewer's last posted line went to within the ask window, as the relay saw it (the "same" label)
    last, prev = {}, {}
    for r in rows:
        p = last.get(r["name"])
        if p and r["t"] - p[1] < V.Relay.ASK_WINDOW:
            prev[r["id"]] = p[0]
        was = today(r, games)
        if was and was[0] in team.display:
            last[r["name"]] = (was[0], r["t"])
    picks, ask = {}, []
    for r in rows:
        hit = team.place_owners(r["text"])
        if hit:
            picks[r["id"]] = ("agents", hit[1], f"about {hit[0]} (claims)")
        else:
            ask.append(r)
    if a.clef and ask:
        from cfai import WorkersAI
        ai = WorkersAI()
        for k in range(0, len(ask), 24):
            part = ask[k:k + 24]
            qs = {f"r{i}": team.question(m, prev.get(m["id"]), unsure=a.unsure) for i, m in enumerate(part)}
            out = ai.run("@cf/cloudflare/clef-flash", {"model": "clef-flash", "state": "Live chat on a stream where AI agents play Factorio together.",
                                                        "questions": qs})
            ans = (out or {}).get("answers") or {}
            for i, m in enumerate(part):
                got = team.pick(ans.get(f"r{i}"), prev.get(m["id"]))
                top = ans.get(f"r{i}") or {}
                picks[m["id"]] = got or (None, [], f"unsure (top {top.get('choice')} {max((top.get('probabilities') or {'': 0}).values()):.2f})")
                if got and got[0] == "viewers" or (top.get("choice") == "viewers"):
                    picks[m["id"]] = picks[m["id"]][:2] + (picks[m["id"]][2] + f" [viewers {(top.get('probabilities') or {}).get('viewers', 0):.2f}]",)
    same = diff = 0
    kinds = {}
    for r in rows:
        was = today(r, games)
        kind, to, why = picks.get(r["id"], (None, [], "not asked (no --clef)"))
        new = ",".join(to) if kind == "agents" else (kind or "rotation")
        old = ",".join(was) if was else "not posted"
        kinds[kind or "rotation"] = kinds.get(kind or "rotation", 0) + 1
        if was and kind == "agents":
            same += set(was) == set(to)
            diff += set(was) != set(to)
        print(f"{r['id']}\t{r['name']}\ttoday {old}\tnew {new}: {why}\t{r['text'][:100]}"
              + (f"\t(last line to {prev[r['id']]})" if r["id"] in prev else ""))
    print(f"\n{len(rows)} lines the relay sent by rotation (of {len(seen)} passed); routed: " + ", ".join(f"{k} {n}" for k, n in sorted(kinds.items()))
          + f"; of those posted and routed to agents: {same} to the same agent(s) as today, {diff} to others")


if __name__ == "__main__":
    main()
