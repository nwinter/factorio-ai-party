#!/usr/bin/env python3
"""RCON broker: holds a world's RCON password so agents never see it.
  python3 tools/fh_broker.py --world n --dir runs/RUN/.sock --log runs/RUN/broker.log BOT [BOT ...]
  python3 tools/fh_broker.py summary runs/RUN/broker.log

The operator starts it (tools/start-team.sh and tools/smoke-launch.sh with POG_BROKER=1). It listens on one Unix
socket per bot, DIR/BOT.sock, and forwards only harness requests for that bot: the RCON command must be exactly the
one bin/fh sends (`/silent-command rcon.print(remote.call("agent_harness", "dispatch", <long string>))`) with a JSON
request whose bot is the socket's bot, and the broker rebuilds the command from the parsed JSON before sending it.
Everything else (console commands, other Lua, deploys, another bot, a player) is refused and logged.
Wire format, JSON lines (factorio-harness host/broker.ts, `fh --socket`):
  {"command": "..."}  ->  {"ok": true, "text": "<RCON reply>"} | {"ok": false, "error": "...", "refused"|"unknown"|"unavailable": true}
unavailable: the RCON connection or its login failed, so nothing was sent (with since when the game is unreachable);
unknown: the request went out and the connection dropped before the answer. A retried request id is answered from
the broker's record when it was answered, and one that got no answer is checked against the game's tick (parse, MAX_IDS).
Each client connection gets its own RCON connection, as a direct fh call would.
Limits: agents run as the owner's user, so socket permissions do not keep one agent off a teammate's socket
(docs/LAUNCH-NOTES.md, "What still leaks with the broker on"); the peer's pid is logged with each refusal.
"""
import argparse, json, os, re, signal, socket, socketserver, struct, sys, threading, time, uuid
from collections import OrderedDict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pog  # noqa: E402
import toolcall  # noqa: E402

HARNESS = re.compile(r'/silent-command rcon\.print\(remote\.call\("agent_harness", "dispatch", \[(=*)\[\n(.*)\]\1\]\)\)', re.S)
ACTION = re.compile(r"^[a-z][a-z0-9_]{0,63}$")
BOT = re.compile(r"[a-z][a-z0-9_-]{0,15}")
MAX_REQUEST = 1048576


class Refused(Exception):
    pass


def lua_string(text):
    eq = ""
    while f"]{eq}]" in text or text.endswith(f"]{eq}"):
        eq += "="
    return f"[{eq}[\n{text}]{eq}]"


def check(command, bot):
    """The RCON command to send for `command` from `bot`'s socket, or Refused with the reason."""
    return parse(command, bot)[0]


def parse(command, bot):
    """(the RCON command to send, the request) for `command` from `bot`'s socket, or Refused with the reason."""
    if not isinstance(command, str):
        raise Refused("command must be a string")
    m = HARNESS.fullmatch(command)
    if not m:
        raise Refused("only harness requests (fh call ...) go through the broker")
    eq, body = m.group(1), m.group(2)
    if f"]{eq}]" in body:
        raise Refused("the request's long string closes early")
    if len(body.encode()) > MAX_REQUEST:
        raise Refused("request exceeds 1 MiB")
    try:
        req = json.loads(body)
    except ValueError:
        raise Refused("the request is not JSON")
    if not isinstance(req, dict) or set(req) - {"id", "action", "args", "bot"}:
        raise Refused("a request has only id, action, args and bot")
    if req.get("bot") != bot:
        raise Refused(f"this socket acts for bot {bot}, not {req.get('bot') or 'a player'}")
    if not isinstance(req.get("id"), str) or not 1 <= len(req["id"]) <= 128:
        raise Refused("id must be a 1..128 character string")
    if not isinstance(req.get("action"), str) or not ACTION.match(req["action"]):
        raise Refused("action must be an action name")
    if "args" in req and not isinstance(req["args"], dict):
        raise Refused("args must be an object")
    return dispatch(req), req


def dispatch(req):
    payload = json.dumps(req, ensure_ascii=False, separators=(",", ":"))
    return f'/silent-command rcon.print(remote.call("agent_harness", "dispatch", {lua_string(payload)}))'


# Request ids (Luna, shift12 13:41: exact-ID retries during the outage all read outcome_unknown): per bot the last
# MAX_IDS ids, each sent (no answer: the connection dropped after it went out) or answered (with the reply, up to
# MAX_KEPT bytes). A retried id that was answered is answered from this record and not sent again; one that got no
# answer is checked against the game's tick when it is sent again: the game answers an id it applied from its own
# record (the old tick), and runs one it never got.
MAX_IDS, MAX_KEPT, ROLLBACK = 512, 262144, 600


def tick_of(text):
    try:
        t = json.loads(text).get("tick")
        return t if isinstance(t, int) else None
    except (ValueError, AttributeError):
        return None


def with_note(text, note):
    """The reply with `note` as result.broker (or broker_note when it has no result object)."""
    try:
        obj = json.loads(text)
    except ValueError:
        return text
    if not isinstance(obj, dict):
        return text
    if isinstance(obj.get("result"), dict):
        obj["result"]["broker"] = note
    else:
        obj["broker_note"] = note
    return json.dumps(obj, ensure_ascii=False)


def with_tool_calls(text, req, run_dir, now=None):
    """(d26 batch238 BT) a tell's reply with in_tool_call: one line for each addressee whose model has been inside one
    tool call a minute or more (tools/toolcall.py, from its CLI's tool hooks). batch234: Astra's three tells to Opus each
    read "waking them if asleep" while Opus's model sat 15-19 min in one Bash call that acked them unread."""
    if req.get("action") != "tell" or not run_dir:
        return text
    try:
        obj = json.loads(text)
    except ValueError:
        return text
    result = obj.get("result") if isinstance(obj, dict) and obj.get("ok") else None
    names = result.get("to") if isinstance(result, dict) else None
    if not isinstance(names, list):
        return text
    facts = [f for n in names if isinstance(n, str) and BOT.fullmatch(n)
             for f in [toolcall.fact(n, os.path.join(run_dir, n), now)] if f]
    if not facts:
        return text
    result["in_tool_call"] = facts
    return json.dumps(obj, ensure_ascii=False)


def hms(t):
    return time.strftime("%H:%M:%S", time.localtime(t))


class Rcon(pog.Rcon):
    """pog.Rcon with a strict login: Factorio answers auth with an empty response first, then the auth response."""

    def __init__(self, host, port, password, timeout=15):
        self.sock = socket.create_connection((host, port), timeout=timeout)
        self.next_id = 1
        rid = self._send(3, password)
        while True:
            got, kind, _ = self._read()
            if kind == 2:
                if got == -1 or got != rid:
                    self.sock.close()
                    raise ConnectionError("RCON authentication rejected")
                return


def peer(conn):
    """(pid, uid) of the process on the other end of a Unix socket, None where unknown (a socket pair)."""
    try:
        if sys.platform == "darwin":
            pid = conn.getsockopt(0, 2)  # SOL_LOCAL, LOCAL_PEERPID
            uid = struct.unpack_from("<II", conn.getsockopt(0, 1, 76))[1]  # LOCAL_PEERCRED: struct xucred
            return pid, uid
        pid, uid, _ = struct.unpack("3i", conn.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))
        return pid, uid
    except OSError:
        return None, None


class Broker:
    def __init__(self, port, password, log_path=None, host="127.0.0.1", rcon_timeout=60, group=None, uids=None, run_dir=None):
        self.port, self.password, self.host, self.rcon_timeout = port, password, host, rcon_timeout
        self.run_dir = run_dir        # runs/RUN: the agents' workspaces (serve: the socket folder's parent)
        self.log_path, self.lock = log_path, threading.Lock()
        # Agents as other macOS users (docs/LAUNCH-NOTES.md): the sockets' group, and each bot's own uid if known.
        self.group, self.uids = group, uids or {}
        self.counts = {}
        self.servers = []
        self.ids = {}                 # bot -> OrderedDict id -> {state, at, tick?, text?}
        self.down_since = None        # the first failed RCON connection of an outage in course
        self.last_tick = None         # the newest reply's tick (a later lower one is a rollback)

    def seen(self, bot, rid):
        with self.lock:
            entry = self.ids.get(bot, {}).get(rid)
            return dict(entry) if entry else None

    def remember(self, bot, rid, **entry):
        with self.lock:
            ids = self.ids.setdefault(bot, OrderedDict())
            ids[rid] = {**ids.get(rid, {}), **entry}
            ids.move_to_end(rid)
            while len(ids) > MAX_IDS:
                ids.popitem(last=False)

    def down(self, error):
        with self.lock:
            if self.down_since is None:
                self.down_since = time.time()
            since = self.down_since
        return f"game unreachable since {hms(since)} ({int(time.time() - since)}s)"

    def up(self, tick):
        with self.lock:
            self.down_since = None
            if tick is not None:
                self.last_tick = tick

    def log(self, **entry):
        line = json.dumps({"at": time.strftime("%Y-%m-%dT%H:%M:%S"), **entry})
        with self.lock:
            if self.log_path:
                with open(self.log_path, "a") as f:
                    f.write(line + "\n")
            else:
                print(line, flush=True)

    def count(self, bot, key):
        with self.lock:
            c = self.counts.setdefault(bot, {"forwarded": 0, "refused": 0, "rcon_errors": 0})
            c[key] += 1

    def handler(self, bot):
        broker = self

        class Handler(socketserver.StreamRequestHandler):
            def handle(self):
                rcon, (pid, uid) = None, peer(self.request)
                if bot in broker.uids and uid != broker.uids[bot]:
                    broker.count(bot, "refused")
                    broker.log(event="refused", bot=bot, pid=pid, uid=uid, reason=f"uid {uid} is not {bot}'s user", command="")
                    self.reply({"ok": False, "refused": True, "error": f"refused: this socket is for {bot}'s user"})
                    return
                try:
                    for raw in self.rfile:
                        try:
                            command = json.loads(raw).get("command")
                        except (ValueError, AttributeError):
                            command = None
                        try:
                            out, req = parse(command, bot)
                        except Refused as e:
                            broker.count(bot, "refused")
                            broker.log(event="refused", bot=bot, pid=pid, uid=uid, reason=str(e), command=str(command)[:300])
                            self.reply({"ok": False, "refused": True, "error": f"refused: {e}"})
                            continue
                        rid, before = req["id"], broker.seen(bot, req["id"])
                        # An id answered before: from the record, not sent again.
                        if before and before.get("state") == "answered" and before.get("text") is not None:
                            note = f"answered from the broker's record: request {rid} was answered at {hms(before['at'])}"
                            if before.get("tick") is not None:
                                note += f" (tick {before['tick']})"
                                if broker.last_tick is not None and broker.last_tick < before["tick"] - ROLLBACK:
                                    note += (f"; the game has since rolled back to tick {broker.last_tick}, before that answer: what it did is "
                                             "not in the game now (send it again with a new id)")
                            note += "; it was not sent again"
                            broker.log(event="replayed", bot=bot, pid=pid, id=rid)
                            self.reply({"ok": True, "text": with_note(before["text"], note)})
                            continue
                        try:
                            if rcon is None:
                                rcon = Rcon(broker.host, broker.port, broker.password, timeout=broker.rcon_timeout)
                            # An id sent before with no answer: the game's tick now, so its answer tells applied from new.
                            now_tick = None
                            if before and before.get("state") == "sent":
                                probe = {"id": f"broker-{uuid.uuid4().hex[:16]}", "action": "status", "args": {"peek": True, "brief": True}, "bot": bot, "reader": "broker"}
                                now_tick = tick_of(rcon.command(dispatch(probe)))
                        except (OSError, ConnectionError, struct.error) as e:
                            # Nothing went out: the connection (or its login) failed (Luna, 13:41: these read outcome_unknown).
                            rcon = None
                            since = broker.down(str(e))
                            broker.count(bot, "rcon_errors")
                            broker.log(event="rcon_unreachable", bot=bot, pid=pid, error=str(e))
                            unsure = (f"; request {rid} was sent at {hms(before['at'])} and got no answer, so whether it was applied is "
                                      "not known until the game answers: retry this id then") if before and before.get("state") == "sent" else ""
                            self.reply({"ok": False, "unavailable": True, "error": f"{since}: rcon: {e}; this request was not sent{unsure}"})
                            continue
                        broker.remember(bot, rid, state="sent", at=before["at"] if before else time.time())
                        try:
                            text = rcon.command(out)
                        except (OSError, ConnectionError, struct.error) as e:
                            rcon = None
                            broker.down(str(e))
                            broker.count(bot, "rcon_errors")
                            broker.log(event="rcon_error", bot=bot, pid=pid, error=str(e))
                            self.reply({"ok": False, "unknown": True, "error": f"rcon: {e}"})
                            continue
                        tick = tick_of(text)
                        broker.up(tick)
                        broker.remember(bot, rid, state="answered", at=time.time(), tick=tick, text=text if len(text) <= MAX_KEPT else None)
                        if before and before.get("state") == "sent" and now_tick is not None and tick is not None:
                            sent = hms(before["at"])
                            text = with_note(text, f"an earlier send of request {rid} at {sent} got no answer (the connection dropped); "
                                             + (f"the game answered it from its own record (tick {tick}, now {now_tick}): it was applied then and not again now"
                                                if tick < now_tick else "the game had no record of it (never applied, or applied and then rolled back): it ran now"))
                        broker.count(bot, "forwarded")
                        self.reply({"ok": True, "text": with_tool_calls(text, req, broker.run_dir)})
                finally:
                    if rcon is not None:
                        try:
                            rcon.sock.close()
                        except OSError:
                            pass

            def reply(self, obj):
                self.wfile.write((json.dumps(obj, ensure_ascii=False) + "\n").encode())
                self.wfile.flush()

        return Handler

    def serve(self, directory, bots):
        os.makedirs(directory, exist_ok=True)
        if self.run_dir is None:
            self.run_dir = os.path.dirname(os.path.abspath(directory))
        gid = None
        if self.group:
            import grp
            gid = grp.getgrnam(self.group).gr_gid
            os.chown(directory, -1, gid)
        os.chmod(directory, 0o750 if gid is not None else 0o700)
        for bot in bots:
            path = os.path.join(directory, f"{bot}.sock")
            # macOS caps a Unix socket path at 104 bytes (103 and the terminator); bind fails with a bare error.
            if len(os.fsencode(path)) > 103:
                raise ValueError(f"socket path is longer than the 103 bytes a Unix socket allows ({len(os.fsencode(path))}): "
                                 f"{path}; use a checkout with a shorter path")
            if os.path.exists(path):
                os.remove(path)
            server = socketserver.ThreadingUnixStreamServer(path, self.handler(bot))
            server.daemon_threads = True
            if gid is not None:
                os.chown(path, -1, gid)
            os.chmod(path, 0o660 if gid is not None else 0o600)
            self.servers.append((bot, path, server))
            threading.Thread(target=server.serve_forever, daemon=True).start()
            self.log(event="listening", bot=bot, socket=path)

    def stop(self):
        for bot, path, server in self.servers:
            server.shutdown()
            server.server_close()
            try:
                os.remove(path)
            except OSError:
                pass
        self.log(event="stopped", counts=self.counts)


def summary(path):
    """Lines for a broker log: requests per bot, and each refusal (tools/stop-team.sh, tools/smoke-launch.sh)."""
    events = []
    for line in open(path):
        try:
            events.append(json.loads(line))
        except ValueError:
            pass
    counts = next((e["counts"] for e in reversed(events) if e.get("event") == "stopped"), None)
    refusals = [e for e in events if e.get("event") == "refused"]
    out = ["broker: " + (", ".join(f"{b} {c['forwarded']} forwarded, {c['refused']} refused" for b, c in sorted(counts.items()))
                         if counts else "still running or stopped without counts")
           + f"; {len(refusals)} refusals logged"]
    for e in refusals[:20]:
        out.append(f"  {e['at']} {e['bot']} (pid {e.get('pid')}): {e['reason']}: {e['command'][:150]}")
    return out


def main():
    if sys.argv[1:2] == ["summary"]:
        print("\n".join(summary(sys.argv[2])))
        return
    ap = argparse.ArgumentParser()
    ap.add_argument("--world", required=True)
    ap.add_argument("--port", type=int)
    ap.add_argument("--password-file", help="default ~/.config/pog/rcon-WORLD.pw")
    ap.add_argument("--dir", required=True, help="socket directory, e.g. runs/RUN/.sock")
    ap.add_argument("--log", help="JSON-lines log (default stdout)")
    ap.add_argument("--group", default=os.environ.get("POG_AGENT_GROUP"),
                    help="agents run as another user in this group: sockets 660 and their folder 750 in this group")
    ap.add_argument("--uid", action="append", default=[], metavar="BOT=UID",
                    help="this bot's socket accepts only this user (agents as one macOS user each)")
    ap.add_argument("bots", nargs="+")
    a = ap.parse_args()
    for b in a.bots:
        if not BOT.fullmatch(b):
            raise SystemExit(f"not a bot name: {b}")
    uids = {k: int(v) for k, v in (u.split("=", 1) for u in a.uid)}
    port = a.port or pog.PORTS.get(a.world) or int(os.environ["POG_RCON_PORT"])
    pw = open(a.password_file or os.path.expanduser(f"~/.config/pog/rcon-{a.world}.pw")).read().strip()
    broker = Broker(port, pw, a.log, group=a.group, uids=uids)
    broker.serve(a.dir, a.bots)
    done = threading.Event()
    signal.signal(signal.SIGTERM, lambda *_: done.set())
    signal.signal(signal.SIGINT, lambda *_: done.set())
    done.wait()
    broker.stop()


if __name__ == "__main__":
    main()
