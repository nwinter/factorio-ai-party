#!/usr/bin/env python3
"""Operator view of agents' harness requests (board items of kind `harness`) over RCON.

Agents never get this tool. It reads and answers the board as `operator` (dispatch requests with
`operator: true`, no player), so it needs the current runtime on the world (`fh deploy`).

  tools/harness-requests.py [--world live] list [--all]       open requests (or every one)
  tools/harness-requests.py show ID                           one request with problem, proposal, notes
  tools/harness-requests.py answer ID --note TEXT [--status doing|done|blocked|dropped|open]
                                      [--chat "harness v3: collect skips claimed chests"]
  tools/harness-requests.py board [--all]                     the whole team board (active items by default)
  tools/harness-requests.py events [--since SEQ]              board event log
  tools/harness-requests.py mentions                          unread @mentions per agent, last request time

--chat also posts the line in game chat, where agents see it as `server: ...`. Add --json for raw replies.
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


def ago(tick, now):
    m = max(0, now - tick) // 3600
    return f"{m}m ago" if m < 60 else f"{m // 60}h{m % 60:02d}m ago"


def show_item(item, now, full=False):
    owner = item.get("owner") or "-"
    print(f"#{item['id']} [{item['status']}] {item['kind']} by {item.get('requested_by')} -> {owner}, "
          f"{ago(item['created_tick'], now)}: {item['title']}")
    if full:
        for key in ("problem", "proposal", "needs", "area", "tags"):
            if item.get(key):
                print(f"  {key}: {item[key] if isinstance(item[key], str) else json.dumps(item[key])}")
    for note in item.get("notes") or []:
        print(f"  note {ago(note['tick'], now)} {note['by']}: {note['text']}")


def main():
    ap = argparse.ArgumentParser(description="List and answer agents' harness requests")
    ap.add_argument("--world", default=os.environ.get("POG_WORLD", "live"))
    ap.add_argument("--port", type=int)
    ap.add_argument("--json", action="store_true")
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("list"); p.add_argument("--all", action="store_true")
    p = sub.add_parser("show"); p.add_argument("id", type=int)
    p = sub.add_parser("answer"); p.add_argument("id", type=int); p.add_argument("--note", required=True)
    p.add_argument("--status", choices=["open", "claimed", "doing", "done", "blocked", "dropped"])
    p.add_argument("--chat", help="also post this line in game chat (agents see server: ...)")
    p = sub.add_parser("board"); p.add_argument("--all", action="store_true")
    p = sub.add_parser("events"); p.add_argument("--since", type=int, default=0)
    sub.add_parser("mentions")
    a = ap.parse_args()
    port = a.port or PORTS.get(a.world) or int(os.environ["POG_RCON_PORT"])
    pw = open(os.path.expanduser(f"~/.config/pog/rcon-{a.world}.pw")).read().strip()
    rcon = Rcon("127.0.0.1", port, pw)

    if a.cmd in ("list", "board"):
        args = {"limit": 100}
        if a.cmd == "list":
            args["kind"] = "harness"
        if not a.all:
            args["status"] = "active"
        result = dispatch(rcon, "board", args)
        if a.json:
            print(json.dumps(result)); return
        items = result["items"]
        if not items:
            print("no " + ("harness requests" if a.cmd == "list" else "board items") + (" (use --all for finished ones)" if not a.all else ""))
        for item in reversed(items):
            show_item(item, result["tick"], full=a.cmd == "list")
        if a.cmd == "board":
            print(f"open unowned requests: {result['open_unowned']}")
    elif a.cmd == "show":
        result = dispatch(rcon, "board", {"id": a.id})
        if a.json:
            print(json.dumps(result)); return
        now = dispatch(rcon, "board_events", {"since_seq": 0, "limit": 1})["tick"]
        show_item(result["item"], now, full=True)
    elif a.cmd == "answer":
        args = {"id": a.id, "note": a.note}
        if a.status:
            args["status"] = a.status
        result = dispatch(rcon, "board_update", args)
        if a.chat:
            rcon.command(a.chat.replace("\n", " "))
        if a.json:
            print(json.dumps(result)); return
        show_item(result["item"], result["item"]["updated_tick"], full=True)
        if a.chat:
            print(f"chat: server: {a.chat}")
    elif a.cmd == "mentions":
        result = dispatch(rcon, "mention_counts", {})
        if a.json:
            print(json.dumps(result)); return
        now = result["tick"]
        for row in result["agents"]:
            last = row.get("last_request_tick")
            seen = f"last request {ago(last, now)}" if last is not None else "no request yet"
            line = f"{row['name']}: {row['unread_mentions']} unread mentions ({row['at_mentions']} @, {row.get('tells') or 0} tells), "
            line += f"{row.get('unread_board') or 0} board lines, {seen}"
            if row.get("latest"):
                line += f"; latest {row['latest']}"
            print(line)
    else:
        result = dispatch(rcon, "board_events", {"since_seq": a.since, "limit": 200})
        if a.json:
            print(json.dumps(result)); return
        for e in result["events"]:
            extra = f" - {e['text']}" if e.get("text") else ""
            print(f"{e['seq']} t={e['tick']} #{e['id']} {e['kind']} {e['change']} by {e['by']}: {e['title']}{extra}")
        print(f"cursor {result['cursor']} (latest {result['latest']})")


if __name__ == "__main__":
    main()
