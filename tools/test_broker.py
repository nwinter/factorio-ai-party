#!/usr/bin/env python3
"""Offline checks for the RCON broker (POG_BROKER=1): python3 tools/test_broker.py

- check(): only a harness request for the socket's bot passes, rebuilt from its JSON; console commands, other Lua,
  deploys, code after the request, another bot, a player and extra fields are refused;
- end to end with a fake RCON server: bin/fh through the broker's socket works for its bot; another bot, a deploy
  and a raw console command are refused, logged, and never reach the server; the password never reaches fh;
- new-run.sh with POG_BROKER=1 writes no key and points fh and shot at the bot's socket; without it, as before.
Needs the harness built (cd vendor/factorio-harness && npm run build) for the end-to-end part.
"""
import json, os, re, shutil, socket, struct, subprocess, sys, tempfile, threading, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))
import fh_broker as fb  # noqa: E402


def request(req, eq=""):
    body = json.dumps(req)
    return f'/silent-command rcon.print(remote.call("agent_harness", "dispatch", [{eq}[\n{body}]{eq}]))'


def refused(command, bot="haiku"):
    try:
        fb.check(command, bot)
    except fb.Refused as e:
        return str(e)
    raise AssertionError(f"not refused: {command[:120]}")


def check():
    ok = fb.check(request({"id": "a1", "action": "status", "bot": "haiku", "args": {"peek": True}}), "haiku")
    assert ok == '/silent-command rcon.print(remote.call("agent_harness", "dispatch", [[\n{"id":"a1","action":"status","bot":"haiku","args":{"peek":true}}]]))', ok
    # A say text with "]]" in it arrives with a level-1 long string and is rebuilt the same way.
    ok = fb.check(request({"id": "a2", "action": "say", "bot": "haiku", "args": {"text": "x]] y"}}, "="), "haiku")
    assert '[=[\n{"id":"a2"' in ok and ok.endswith(']=]))'), ok
    assert "only harness requests" in refused("/c game.speed=10")
    assert "only harness requests" in refused("/silent-command game.forces.player.research_all_technologies()")
    assert "only harness requests" in refused('/silent-command rcon.print(remote.call("agent_harness", "install", [[\nreturn {}]]))')
    assert "only harness requests" in refused('/silent-command rcon.print(remote.call("agent_harness","bot_create","haiku"))')
    sneak = request({"id": "a3", "action": "status", "bot": "haiku"}) + ' game.speed=10 rcon.print(remote.call("agent_harness", "dispatch", [[\n{}]]))'
    assert "closes early" in refused(sneak) or "only harness" in refused(sneak)
    assert "not sol" in refused(request({"id": "a4", "action": "walk", "bot": "sol"}))
    assert "only id, action, args and bot" in refused(request({"id": "a5", "action": "walk", "player": 1}))
    assert "not a player" in refused(request({"id": "a5", "action": "walk"}))
    assert "only id, action, args and bot" in refused(request({"id": "a6", "action": "walk", "bot": "haiku", "x": 1}))
    assert "not JSON" in refused('/silent-command rcon.print(remote.call("agent_harness", "dispatch", [[\nnot json]]))')
    assert "action name" in refused(request({"id": "a7", "action": "walk; game", "bot": "haiku"}))
    assert "command must be a string" in refused(None)
    print("check: ok")


class FakeRcon(threading.Thread):
    """Speaks RCON on localhost: answers harness dispatches with the request's id, bot and action."""

    def __init__(self, password):
        super().__init__(daemon=True)
        self.password, self.received = password, []
        self.sock = socket.socket()
        self.sock.bind(("127.0.0.1", 0))
        self.sock.listen()
        self.port = self.sock.getsockname()[1]

    def run(self):
        while True:
            conn, _ = self.sock.accept()
            threading.Thread(target=self.serve, args=(conn,), daemon=True).start()

    def serve(self, conn):
        def send(rid, kind, body):
            data = body.encode()
            conn.sendall(struct.pack("<iii", len(data) + 10, rid, kind) + data + b"\0\0")
        try:
            while True:
                head = conn.recv(4, socket.MSG_WAITALL)
                if len(head) < 4:
                    return
                size = struct.unpack("<i", head)[0]
                payload = conn.recv(size, socket.MSG_WAITALL)
                rid, kind = struct.unpack("<ii", payload[:8])
                body = payload[8:-2].decode()
                if kind == 3:
                    send(rid, 0, "")
                    send(rid if body == self.password else -1, 2, "")
                    continue
                self.received.append(body)
                m = fb.HARNESS.fullmatch(body)
                req = json.loads(m.group(2)) if m else {}
                send(rid, 0, json.dumps({"id": req.get("id"), "ok": True, "tick": 60,
                                         "result": {"bot": req.get("bot"), "action": req.get("action"), "clock": "day 1"}}))
        except OSError:
            return


def handler():
    """The broker's connection handler over a socket pair (no socket file), against the fake RCON server."""
    fake = FakeRcon("s3cret")
    fake.start()
    tmp = tempfile.mkdtemp()
    log = os.path.join(tmp, "broker.log")
    broker = fb.Broker(fake.port, "s3cret", log)
    ours, theirs = socket.socketpair()
    t = threading.Thread(target=broker.handler("haiku"), args=(theirs, "pair", None), daemon=True)
    t.start()
    f = ours.makefile("rw")

    def send(command):
        f.write(json.dumps({"command": command}) + "\n")
        f.flush()
        return json.loads(f.readline())

    r = send(request({"id": "h1", "action": "status", "bot": "haiku"}))
    assert r["ok"] and json.loads(r["text"])["result"]["bot"] == "haiku", r
    r = send(request({"id": "h2", "action": "walk", "bot": "sol"}))
    assert not r["ok"] and r["refused"] and "not sol" in r["error"], r
    r = send("/sc game.speed=10")
    assert not r["ok"] and r["refused"], r
    f.write("not json\n")
    f.flush()
    assert json.loads(f.readline())["refused"]
    r = send(request({"id": "h3", "action": "observe", "bot": "haiku"}))
    assert r["ok"], r
    ours.close()
    t.join(5)
    assert len(fake.received) == 2 and all(fb.HARNESS.fullmatch(b) for b in fake.received), fake.received
    refusals = [json.loads(l) for l in open(log)]
    assert [e["event"] for e in refusals] == ["refused"] * 3 and refusals[1]["command"] == "/sc game.speed=10", refusals
    assert broker.counts["haiku"] == {"forwarded": 2, "refused": 3, "rcon_errors": 0}, broker.counts
    broker.stop()
    lines = fb.summary(log)
    assert lines[0] == "broker: haiku 2 forwarded, 3 refused; 3 refusals logged", lines
    assert "this socket acts for bot haiku, not sol" in lines[1] and "/sc game.speed=10" in lines[2], lines
    # Agents as their own users (--uid BOT=UID): another user's connection is refused before any command; ours passes.
    for uid, ok in ((os.getuid() + 1, False), (os.getuid(), True)):
        b = fb.Broker(fake.port, "s3cret", log, uids={"haiku": uid})
        ours, theirs = socket.socketpair()
        threading.Thread(target=b.handler("haiku"), args=(theirs, "pair", None), daemon=True).start()
        f = ours.makefile("rw")
        f.write(json.dumps({"command": request({"id": f"u{uid}", "action": "status", "bot": "haiku"})}) + "\n")
        f.flush()
        r = json.loads(f.readline())
        assert r["ok"] is ok and (ok or "haiku's user" in r["error"]), (uid, r)
        ours.close()
    # A wrong password: the reply says the outcome is unknown, and the broker keeps serving.
    bad = fb.Broker(fake.port, "wrong", log)
    ours, theirs = socket.socketpair()
    threading.Thread(target=bad.handler("haiku"), args=(theirs, "pair", None), daemon=True).start()
    f = ours.makefile("rw")
    f.write(json.dumps({"command": request({"id": "h4", "action": "status", "bot": "haiku"})}) + "\n")
    f.flush()
    r = json.loads(f.readline())
    assert not r["ok"] and r["unknown"] and "auth" in r["error"], r
    ours.close()
    shutil.rmtree(tmp)
    print("broker handler: ok")


def end_to_end():
    cli = os.path.join(ROOT, "vendor", "factorio-harness", "dist", "host", "cli.js")
    if not os.path.exists(cli):
        print("end to end: SKIPPED (build the harness: cd vendor/factorio-harness && npm run build)")
        return
    tmp = tempfile.mkdtemp(prefix="brk", dir=os.environ.get("TMPDIR", "/tmp"))
    try:
        fake = FakeRcon("s3cret")
        fake.start()
        log = os.path.join(tmp, "broker.log")
        broker = fb.Broker(fake.port, "s3cret", log)
        sock_dir = os.path.join(tmp, ".sock")
        try:
            broker.serve(sock_dir, ["haiku", "sol"])
        except PermissionError:
            print("end to end: SKIPPED (this sandbox refuses Unix sockets; run it outside the engineer sandbox)")
            return
        assert oct(os.stat(sock_dir).st_mode & 0o777) == "0o700"
        env = dict(os.environ, POG_FH_SOCKET=os.path.join(sock_dir, "haiku.sock"), POG_RCON_PASSWORD_FILE="/nonexistent")
        fh = os.path.join(ROOT, "bin", "fh")

        def run(*args):
            return subprocess.run([fh, *args], env=env, capture_output=True, text=True, timeout=30)

        r = run("call", "status", "--bot", "haiku", "--format", "json")
        assert r.returncode == 0, (r.stdout, r.stderr)
        reply = json.loads(r.stdout)
        assert reply["result"]["bot"] == "haiku" and reply["result"]["action"] == "status", reply
        r = run("call", "walk", "--bot", "sol", "--args", '{"direction":"east","ticks":60}')
        assert r.returncode != 0 and "refused" in (r.stdout + r.stderr) and "not sol" in (r.stdout + r.stderr), (r.stdout, r.stderr)
        r = run("deploy", "--bot", "haiku")
        assert r.returncode != 0 and "not available through the RCON broker" in r.stderr, r.stderr
        r = run("call", "status", "--player", "1")
        assert r.returncode != 0 and "--player is not available" in r.stderr, r.stderr
        # A raw client on the socket: a console command is refused and never reaches the server.
        c = socket.socket(socket.AF_UNIX)
        c.connect(os.path.join(sock_dir, "haiku.sock"))
        c.sendall(b'{"command": "/c game.speed=10"}\n')
        answer = json.loads(c.makefile().readline())
        c.close()
        assert answer["ok"] is False and answer["refused"], answer
        time.sleep(0.2)
        assert all("game.speed" not in b for b in fake.received), fake.received
        assert all(fb.HARNESS.fullmatch(b) for b in fake.received), fake.received
        events = [json.loads(l) for l in open(log)]
        refusals = [e for e in events if e["event"] == "refused"]
        assert len(refusals) == 2 and refusals[1]["command"] == "/c game.speed=10", refusals
        assert all(isinstance(e.get("pid"), int) for e in refusals), refusals
        broker.stop()
        assert not os.path.exists(os.path.join(sock_dir, "haiku.sock"))
        stopped = json.loads(open(log).read().splitlines()[-1])
        assert stopped["counts"]["haiku"]["forwarded"] == 1 and stopped["counts"]["haiku"]["refused"] == 2, stopped
        print("end to end: ok")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def new_run():
    tmp = tempfile.mkdtemp()
    try:
        for d in ("tools", "agent"):
            os.makedirs(os.path.join(tmp, d))
        shutil.copy(os.path.join(ROOT, "tools", "new-run.sh"), os.path.join(tmp, "tools"))
        for f in os.listdir(os.path.join(ROOT, "agent")):
            if f.endswith(".md"):
                shutil.copy(os.path.join(ROOT, "agent", f), os.path.join(tmp, "agent"))
        base = dict(os.environ, POG_WS="haiku", POG_BOT="haiku")
        out = subprocess.run(["bash", os.path.join(tmp, "tools", "new-run.sh"), "brk", "n", "haiku", "10"],
                             env=dict(base, POG_BROKER="1"), capture_output=True, text=True, check=True).stdout.strip()
        fh, shot = open(os.path.join(out, "fh")).read(), open(os.path.join(out, "shot")).read()
        sock = os.path.join(tmp, "runs", "brk", ".sock", "haiku.sock")
        assert f'POG_FH_SOCKET="{sock}"' in fh and f'POG_FH_SOCKET="{sock}"' in shot, fh
        assert "RCON_PASSWORD" not in fh + shot and ".keys" not in fh + shot, fh
        assert not os.path.exists(os.path.join(tmp, "runs", "brk", ".keys")), "a broker run has no keys directory"
        subprocess.run(["bash", "-n", os.path.join(out, "fh")], check=True)
        subprocess.run(["bash", "-n", os.path.join(out, "shot")], check=True)
        out = subprocess.run(["bash", os.path.join(tmp, "tools", "new-run.sh"), "plain", "n", "haiku", "10"],
                             env=base, capture_output=True, text=True, check=True).stdout.strip()
        fh = open(os.path.join(out, "fh")).read()
        assert re.search(r'POG_RCON_PASSWORD_FILE=".*/runs/plain/\.keys/rcon-n\.pw"', fh) and "POG_FH_SOCKET" not in fh, fh
    finally:
        shutil.rmtree(tmp)
    print("new-run: ok")


def claude_settings():
    """launch-agent.sh's claude_settings: earlier runs' keys denied; with the broker, its own too, and its socket allowed."""
    text = open(os.path.join(ROOT, "tools", "launch-agent.sh")).read()
    start = text.index("claude_settings() {")
    end = text.index("\nEOS\n}\n", start) + len("\nEOS\n}\n")
    body = text[start:end]
    tmp = tempfile.mkdtemp()
    try:
        for r in ("shake6", "now"):
            os.makedirs(os.path.join(tmp, "runs", r, ".keys"))
        ws = os.path.join(tmp, "runs", "now", "haiku")
        os.makedirs(ws)
        for broker in ("0", "1"):
            script = f'root={tmp!r} run=now dir={ws!r} allow=\'"Read"\'\n{body}\nclaude_settings\n'
            subprocess.run(["bash", "-c", script], env=dict(os.environ, POG_BROKER=broker, POG_BOT="haiku"), check=True)
            cfg = json.load(open(os.path.join(ws, ".claude", "settings.json")))
            deny_read, deny = cfg["sandbox"]["filesystem"]["denyRead"], cfg["permissions"]["deny"]
            old, own = os.path.join(tmp, "runs", "shake6", ".keys"), os.path.join(tmp, "runs", "now", ".keys")
            assert old in deny_read and f"Read(/{old}/**)" in deny and f"Read({old}/**)" in deny, cfg
            assert (own in deny_read) == (broker == "1"), (broker, deny_read)
            sockets = cfg["sandbox"]["network"].get("allowUnixSockets")
            assert sockets == ([os.path.join(tmp, "runs", "now", ".sock", "haiku.sock")] if broker == "1" else None), sockets
    finally:
        shutil.rmtree(tmp)
    print("claude settings: ok")


if __name__ == "__main__":
    check()
    new_run()
    claude_settings()
    handler()
    end_to_end()
