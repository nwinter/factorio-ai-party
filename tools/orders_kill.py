#!/usr/bin/env python3
"""Operator kill switch for standing orders (orders.lua orders_kill) over RCON.

Agents never get this tool. `on` stops every agent's running order and starts none, triggers included, until `off`;
agents' replies say `orders: paused by the operator`. `off` lets orders start again after each agent's hold (20 s
by default). `status` shows the switch. Needs the eng/standing runtime on the world (`fh deploy`).

  tools/orders_kill.py [--world live] on|off|status
"""
import argparse, json, os, sys, uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pog import PORTS, Rcon  # noqa: E402


def dispatch(rcon, action, args):
    payload = json.dumps({"id": "op-" + uuid.uuid4().hex, "action": action, "operator": True, "args": args})
    level = 1
    while "]" + "=" * level + "]" in payload:
        level += 1
    eq = "=" * level
    out = rcon.command(f'/silent-command rcon.print(remote.call("agent_harness","dispatch",[{eq}[{payload}]{eq}]))')
    try:
        reply = json.loads(out)
    except ValueError:
        raise SystemExit(f"unexpected reply (is agent-harness running and current? run fh deploy): {out[:300]}")
    if not reply.get("ok"):
        raise SystemExit("error: " + json.dumps(reply.get("error")))
    return reply["result"]


def main():
    ap = argparse.ArgumentParser(description="Stop or allow every agent's standing orders")
    ap.add_argument("--world", default=os.environ.get("POG_WORLD", "live"))
    ap.add_argument("--port", type=int)
    ap.add_argument("--json", action="store_true")
    ap.add_argument("switch", choices=["on", "off", "status"])
    a = ap.parse_args()
    port = a.port or PORTS.get(a.world) or int(os.environ["POG_RCON_PORT"])
    pw = open(os.path.expanduser(f"~/.config/pog/rcon-{a.world}.pw")).read().strip()
    args = {} if a.switch == "status" else {"on": a.switch == "on"}
    r = dispatch(Rcon("127.0.0.1", port, pw), "orders_kill", args)
    if a.json:
        print(json.dumps(r)); return
    state = f"on since tick {r['since_tick']} (orders paused by the operator)" if r["on"] else "off (orders run)"
    print(f"kill switch {state}; {r['agents_with_orders']} agents with orders; tick {r['tick']}")
    if r["stopped"]:
        print("stopped: " + ", ".join(r["stopped"]))


if __name__ == "__main__":
    main()
