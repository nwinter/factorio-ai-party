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
  {"command": "..."}  ->  {"ok": true, "text": "<RCON reply>"} | {"ok": false, "error": "...", "refused"|"unknown": true}
Each client connection gets its own RCON connection, as a direct fh call would.
Limits: agents run as the owner's user, so socket permissions do not keep one agent off a teammate's socket
(docs/LAUNCH-NOTES.md, "What still leaks with the broker on"); the peer's pid is logged with each refusal.
"""
import argparse, json, os, re, signal, socket, socketserver, struct, sys, threading, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pog  # noqa: E402

HARNESS = re.compile(r'/silent-command rcon\.print\(remote\.call\("agent_harness", "dispatch", \[(=*)\[\n(.*)\]\1\]\)\)', re.S)
ACTION = re.compile(r"^[a-z][a-z0-9_]{0,63}$")
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
    payload = json.dumps(req, ensure_ascii=False, separators=(",", ":"))
    return f'/silent-command rcon.print(remote.call("agent_harness", "dispatch", {lua_string(payload)}))'


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
    def __init__(self, port, password, log_path=None, host="127.0.0.1", rcon_timeout=60, group=None, uids=None):
        self.port, self.password, self.host, self.rcon_timeout = port, password, host, rcon_timeout
        self.log_path, self.lock = log_path, threading.Lock()
        # Agents as other macOS users (docs/LAUNCH-NOTES.md): the sockets' group, and each bot's own uid if known.
        self.group, self.uids = group, uids or {}
        self.counts = {}
        self.servers = []

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
                            out = check(command, bot)
                        except Refused as e:
                            broker.count(bot, "refused")
                            broker.log(event="refused", bot=bot, pid=pid, uid=uid, reason=str(e), command=str(command)[:300])
                            self.reply({"ok": False, "refused": True, "error": f"refused: {e}"})
                            continue
                        try:
                            if rcon is None:
                                rcon = Rcon(broker.host, broker.port, broker.password, timeout=broker.rcon_timeout)
                            text = rcon.command(out)
                        except (OSError, ConnectionError, struct.error) as e:
                            rcon = None
                            broker.count(bot, "rcon_errors")
                            broker.log(event="rcon_error", bot=bot, pid=pid, error=str(e))
                            self.reply({"ok": False, "unknown": True, "error": f"rcon: {e}"})
                            continue
                        broker.count(bot, "forwarded")
                        self.reply({"ok": True, "text": text})
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
        gid = None
        if self.group:
            import grp
            gid = grp.getgrnam(self.group).gr_gid
            os.chown(directory, -1, gid)
        os.chmod(directory, 0o750 if gid is not None else 0o700)
        for bot in bots:
            path = os.path.join(directory, f"{bot}.sock")
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
        if not re.fullmatch(r"[a-z][a-z0-9_-]{0,15}", b):
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
