#!/usr/bin/env python3
"""(d28 batch317) Turn progressive disclosure on or off in a world and save the team's open set for the briefs.

    python3 tools/disclosure/set.py --world W --mode filter|observe|off [--stream] [--humans] [--team] [--refuse|--allow]
                                    [--reset] [--open FILE]
    python3 tools/disclosure/set.py --world W --read          # the operator read: each force's open counts, newest
                                                              # unlocks and next thresholds

--open FILE saves the player force's open set (actions, reference entry ids, brief item ids) for tools/brief.py write
(POG_DISCLOSURE_OPEN=FILE; tools/start-team.sh with POG_DISCLOSURE=1). The mode lives in the save: a world keeps it
across shifts until set again. Design: docs/DISCLOSURE.md.
"""
import argparse, json, os, sys, uuid

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
import pog  # noqa: E402
from stream.harness import lua_string  # noqa: E402


def operator(world, action, args):
    req = {"id": "disclosure-" + uuid.uuid4().hex[:12], "action": action, "args": args, "operator": True}
    pw = open(os.path.expanduser(f"~/.config/pog/rcon-{world}.pw")).read().strip()
    rcon = pog.Rcon(pog.HOSTS.get(world, "127.0.0.1"), pog.PORTS.get(world) or int(os.environ["POG_RCON_PORT"]), pw, timeout=20)
    raw = rcon.command(f'/silent-command rcon.print(remote.call("agent_harness", "dispatch", {lua_string(json.dumps(req))}))')
    reply = json.loads(raw)
    if not reply.get("ok"):
        raise SystemExit(f"{action}: {reply.get('error', {}).get('message', raw)}")
    return reply.get("result", {})


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--world", default="n")
    ap.add_argument("--mode", choices=["filter", "observe", "off", "1", "0"])
    ap.add_argument("--stream", action="store_true", help="the run is streamed (profiles, polls, viewer chat)")
    ap.add_argument("--humans", action="store_true", help="human players may join")
    ap.add_argument("--team", action="store_true", help="more than one agent plays in the team (else: its bots counted)")
    ap.add_argument("--refuse", action="store_true", help="a call to a unit not open is refused naming its condition")
    ap.add_argument("--allow", action="store_true", help="a call to a unit not open runs, undocumented")
    ap.add_argument("--reset", action="store_true", help="forget every force's met atoms and counts")
    ap.add_argument("--open", help="save the player force's open set here")
    ap.add_argument("--read", action="store_true")
    a = ap.parse_args(argv)
    if a.mode:
        world = {"stream": a.stream, "humans": a.humans}
        if a.team:
            world["team"] = True
        args = {"mode": {"1": "filter", "0": "off"}.get(a.mode, a.mode), "world": world}
        if a.refuse or a.allow:
            args["refuse"] = a.refuse
        if a.reset:
            args["reset"] = True
        print(json.dumps(operator(a.world, "disclosure_set", args)))
    if a.open or a.read:
        r = operator(a.world, "disclosure", {"ids": bool(a.open)})
        if a.open:
            ids = ((r.get("forces") or {}).get("player") or {}).get("ids") or {"mode": r.get("mode")}
            with open(a.open, "w") as f:
                json.dump(ids, f)
            print(f"open set: {a.open} ({len(ids.get('actions') or [])} actions, {len(ids.get('docs') or [])} entries)")
        if a.read:
            for name, f in (r.get("forces") or {}).items():
                print(f.get("line"))
                for e in f.get("newest") or []:
                    print(f"  rev {e['rev']} tick {e['tick']} by {e['by']}: {', '.join(e.get('actions') or [])}"
                          f" (+{e.get('args', 0)} arguments, +{e.get('docs', 0)} entries)")
                print("  next: " + "; ".join(f.get("next") or []))
    return 0


if __name__ == "__main__":
    sys.exit(main())
