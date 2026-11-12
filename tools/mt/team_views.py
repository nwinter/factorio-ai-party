#!/usr/bin/env python3
"""(mt277, private: part F) The operator's view of a multi-team run, one column per team: its agents (alive, where),
score (its force's: research, buildings, production), open board items, latest tells and chat, and the first
contacts. Written to runs/RUN/op/views.json and views.html (open the page in a browser; it reloads itself), never to
the launch tree, so no agent reads it.

  tools/mt/team_views.py RUN_ID [--every 60] [--once]

Reads per team: the operator requests carry the team's force as their `team` field (mt276 B), the score Lua names the
force (pog.for_force); chat and score rows come from the per-team logs start-mt.sh writes in op/TEAM/.
"""
import argparse, html, json, os, sys, time, uuid

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "tools"))
import pog  # noqa: E402

WORLD = "imac2"


def lua_long(text):
    level = 1
    while "]" + "=" * level + "]" in text:
        level += 1
    return f"[{'=' * level}[{text}]{'=' * level}]"


class Reader:
    def __init__(self, world=WORLD):
        pw = open(os.path.expanduser(f"~/.config/pog/rcon-{world}.pw")).read().strip()
        self.rcon = pog.Rcon(pog.HOSTS.get(world, "127.0.0.1"), pog.PORTS[world], pw, timeout=10)

    def op(self, action, args=None, team=None):
        req = {"id": "views-" + uuid.uuid4().hex[:12], "operator": True, "action": action, "args": args or {}}
        if team:
            req["team"] = team
        out = self.rcon.command(f'/silent-command rcon.print(remote.call("agent_harness","dispatch",{lua_long(json.dumps(req))}))')
        reply = json.loads(out)
        if not reply.get("ok"):
            raise RuntimeError(f"{action}: {(reply.get('error') or {}).get('message', out[:200])}")
        return reply.get("result") or {}

    def bots(self):
        return json.loads(self.rcon.command('/silent-command rcon.print(remote.call("agent_harness","bots"))')).get("bots") or []

    def profiles(self, agent):
        req={"id":"views-"+uuid.uuid4().hex[:12],"bot":agent,"reader":"broadcast","action":"profiles","args":{}}
        reply=json.loads(self.rcon.command(f'/silent-command rcon.print(remote.call("agent_harness","dispatch",{lua_long(json.dumps(req))}))'))
        if not reply.get('ok'):raise RuntimeError('profile read failed')
        return reply['result'].get('profiles') or []

    def score(self, force):
        lua = " ".join(l.strip() for l in pog.for_force(pog.SCORE_LUA, force).strip().splitlines())
        return json.loads(self.rcon.command("/silent-command " + lua))


def teams_of(op):
    """[(team, [names])] from op/teams.tsv (start-mt.sh's copy of the teams file), in file order: the teams this run
    launched (an op/TEAM/ folder each; POG_MT_TEAMS can leave some out)."""
    out = {}
    for line in open(os.path.join(op, "teams.tsv")):
        f = line.rstrip("\n").split("\t")
        if line.strip() and not line.startswith("#") and len(f) >= 2 and os.path.isdir(os.path.join(op, f[0])):
            out.setdefault(f[0], []).append(f[1])
    return list(out.items())


def tail_jsonl(path, n):
    try:
        lines = open(path).read().splitlines()[-n:]
    except OSError:
        return []
    out = []
    for l in lines:
        try:
            out.append(json.loads(l))
        except ValueError:
            pass
    return out


def streams(op):
    """{team: overlay URL} from op/streams.txt (start-mt.sh, POG_MT_STREAM=1)."""
    try:
        return dict(l.split(None, 1) for l in open(os.path.join(op, "streams.txt")).read().split("\n") if l.strip())
    except (OSError, ValueError):
        return {}


def refusals(op, names):
    """{agent: [count, last host]} of the network gate's refusals (op/netgate.jsonl, POG_NETGATE=1)."""
    out = {}
    try:
        for line in open(os.path.join(op, "netgate.jsonl")):
            r = json.loads(line)
            if r.get("passed") is False and r.get("agent") in names:
                c = out.setdefault(r["agent"], [0, None])
                c[0] += 1
                c[1] = r.get("host")
    except (OSError, ValueError):
        pass
    return out


def collect(r, op):
    view = {"t": time.strftime("%Y-%m-%d %H:%M:%S"), "teams": [], "errors": {}}
    labels={}
    for line in open(os.path.join(op,'teams.tsv')):
        f=line.rstrip('\n').split('\t')
        if not line.startswith('#') and len(f)>=8:labels[f[1]]=f[6]
    try:
        feed=r.op('mt_feed',{'limit':500})
        view.update(feed=feed.get('lines') or [],feed_cursor=feed.get('cursor'),feed_first_seq=feed.get('first_seq'))
    except Exception:
        view['feed']=[]
    try:
        bots = {b["name"]: b for b in r.bots()}
    except Exception as e:
        bots, view["errors"]["bots"] = {}, str(e)
    try:
        view["contacts"] = r.op("mt_contacts").get("contacts") or []
    except Exception as e:
        view["contacts"], view["errors"]["contacts"] = [], str(e)
    try:
        view["pacts"] = r.op("mt_pacts").get("pacts") or []
    except Exception:
        view["pacts"] = []
    try:
        view["diplomacy"] = r.op("mt_diplomacy").get("messages") or []
    except Exception:
        view["diplomacy"] = []
    try:
        view["freeze"] = r.op("mt_freeze")
    except Exception:
        view["freeze"] = None   # no human team (mt_humans not set up)
    for team, names in teams_of(op):
        col = {"team": team, "agents": [], "errors": {}}
        try:
            profiles={p['name']:p for p in r.profiles(names[0]) if p.get('name') in names}
        except Exception:
            profiles={}
        for n in names:
            b = bots.get(n) or {}
            p = b.get("position") or {}
            col["agents"].append({"name": n, "force": b.get("force"), "alive": b.get("alive"),
                                  "at": f"{p.get('x', 0):.0f},{p.get('y', 0):.0f}" if p else None,
                                  "model":labels.get(n),**{k:v for k,v in profiles.get(n,{}).items()
                                  if k in ('display_name','persona','color','glyph','motto','pronouns','avatar')}})
        try:
            s = r.score(team)
            col["score"] = {"tick": s.get("tick"), "research": s.get("research_done") or [],
                            "researching": s.get("current_research"), "entities": s.get("entities") or {},
                            "produced": s.get("produced") or {}, "rockets": s.get("rockets"), "platforms": len(s.get("platforms") or [])}
        except Exception as e:
            col["errors"]["score"] = str(e)
        try:
            items = r.op("board", {}, team).get("items") or []
            col["board"] = [{"id": i.get("id"), "status": i.get("status"), "kind": i.get("kind"), "owner": i.get("owner"),
                             "title": i.get("title")} for i in items if i.get("status") in ("open", "doing", "blocked")][-12:]
        except Exception as e:
            col["errors"]["board"] = str(e)
        try:
            col["tells"] = (r.op("tells", {"since": 0, "limit": 30}, team).get("tells") or [])[-8:]
        except Exception as e:
            col["errors"]["tells"] = str(e)
        col["chat"] = tail_jsonl(os.path.join(op, team, "chat.jsonl"), 8)
        col["stream"] = streams(op).get(team)
        col["refused"] = refusals(op, names)
        view["teams"].append(col)
    return view


def text_of(m):
    return str(m.get("message") or m.get("text") or m.get("summary") or "")


def page(view):
    e = html.escape
    cols = []
    for c in view["teams"]:
        s = c.get("score") or {}
        ents = ", ".join(f"{k} {v}" for k, v in sorted((s.get("entities") or {}).items(), key=lambda kv: -kv[1]) if v)[:400]
        prod = ", ".join(f"{k} {v}" for k, v in sorted((s.get("produced") or {}).items(), key=lambda kv: -kv[1]) if v)[:400]
        agents = "".join(f"<li>{e(a['name'])}: {'alive' if a['alive'] else 'dead' if a['alive'] is False else '?'}"
                         f"{' at ' + e(a['at']) if a['at'] else ''}{'' if a['force'] == c['team'] else ' <b>force ' + e(str(a['force'])) + '</b>'}</li>"
                         for a in c["agents"])
        board = "".join(f"<li>#{e(str(i['id']))} [{e(str(i['status']))}] {e(str(i['title']))}"
                        f"{' (' + e(str(i['owner'])) + ')' if i.get('owner') else ''}</li>" for i in c.get("board") or [])
        tells = "".join(f"<li>{e(str(t.get('from')))} &rarr; {e(', '.join(t.get('to') or []) if isinstance(t.get('to'), list) else str(t.get('to')))}: "
                        f"{e(text_of(t)[:200])}</li>" for t in c.get("tells") or [])
        chat = "".join(f"<li>{e(str(m.get('from') or m.get('player')))}: {e(text_of(m)[:200])}</li>" for m in c.get("chat") or [])
        errs = "".join(f"<li class=err>{e(k)}: {e(v[:200])}</li>" for k, v in c["errors"].items())
        errs += "".join(f"<li class=small>{e(a)}: {n} refused by the network gate (last {e(str(h))})</li>" for a, (n, h) in (c.get("refused") or {}).items())
        link = f" <a class=small href=\"{e(c['stream'].strip())}\">stream</a>" if c.get("stream") else ""
        cols.append(f"""<section><h2>{e(c['team'])}{link}</h2><ul>{agents}</ul>
<h3>Score</h3><p>tick {e(str(s.get('tick')))}; research {len(s.get('research') or [])}{'; researching ' + e(str(s['researching'])) if s.get('researching') else ''};
rockets {e(str(s.get('rockets') or 0))}; platforms {e(str(s.get('platforms') or 0))}</p><p class=small>{e(ents)}</p><p class=small>{e(prod)}</p>
<h3>Board (open)</h3><ul class=small>{board or '<li>none</li>'}</ul>
<h3>Tells</h3><ul class=small>{tells or '<li>none</li>'}</ul>
<h3>Chat</h3><ul class=small>{chat or '<li>none</li>'}</ul><ul>{errs}</ul></section>""")
    contacts = "".join(f"<li>{e(json.dumps(c))}</li>" for c in view.get("contacts") or []) or "<li>none yet</li>"
    for p in view.get("pacts") or []:
        contacts += (f"<li>pact #{p.get('id')} {e(str(p.get('a')))}&ndash;{e(str(p.get('b')))}: {e(str(p.get('status')))}; "
                     f"{e(str(p.get('terms')))}{'; cease-fire lifts at tick ' + str(p['lift_tick']) if p.get('lift_tick') else ''}</li>")
    fz = view.get("freeze")
    if fz:
        contacts += (f"<li>human team {e(str(fz.get('team')))}: freeze {e(str(fz.get('state')))}, {fz.get('used_h', 0):.1f} of "
                     f"{fz.get('budget_h', 0):.0f} h used today, a player online: {e(str(fz.get('online')))}</li>")
    return f"""<!doctype html><html><head><meta charset=utf-8><meta http-equiv=refresh content=60>
<meta name=viewport content="width=device-width,initial-scale=1"><title>Team views</title><style>
:root{{--bg:#fff;--fg:#1b1b1b;--muted:#666;--line:#ddd;--err:#b00020}}
@media (prefers-color-scheme: dark){{:root{{--bg:#151515;--fg:#e8e8e8;--muted:#9a9a9a;--line:#333;--err:#ff6b81}}}}
body{{background:var(--bg);color:var(--fg);font:14px/1.4 system-ui,sans-serif;margin:16px}}
main{{display:grid;grid-template-columns:repeat(auto-fit,minmax(260px,1fr));gap:16px}}
section{{border:1px solid var(--line);border-radius:6px;padding:8px 12px;min-width:0;overflow-wrap:anywhere}}
h2{{margin:4px 0}}h3{{margin:10px 0 2px;font-size:13px;color:var(--muted)}}ul{{margin:0;padding-left:18px}}
.small{{font-size:12px}}.err{{color:var(--err)}}</style></head><body>
<p>{e(view['t'])} &middot; world {WORLD} &middot; first contacts:</p><ul class=small>{contacts}</ul>
<main>{''.join(cols)}</main></body></html>"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("run")
    ap.add_argument("--every", type=float, default=60)
    ap.add_argument("--once", action="store_true")
    a = ap.parse_args()
    op = os.path.join(ROOT, "runs", a.run, "op")
    r = None
    while True:
        try:
            r = r or Reader()
            view = collect(r, op)
        except Exception as e:  # the world away (stopped, restarting): try again next round
            r, view = None, {"t": time.strftime("%Y-%m-%d %H:%M:%S"), "teams": [], "errors": {"world": str(e)}}
        json.dump(view, open(os.path.join(op, "views.json.tmp"), "w"), indent=1)
        os.replace(os.path.join(op, "views.json.tmp"), os.path.join(op, "views.json"))
        with open(os.path.join(op, "views.html.tmp"), "w") as f:
            f.write(page(view))
        os.replace(os.path.join(op, "views.html.tmp"), os.path.join(op, "views.html"))
        if a.once:
            print(f"{op}/views.html: {len(view['teams'])} teams; errors {json.dumps(view['errors'])[:300]}")
            return
        time.sleep(a.every)


if __name__ == "__main__":
    main()
