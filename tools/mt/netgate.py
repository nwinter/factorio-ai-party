#!/usr/bin/env python3
"""(mt284, private) A local proxy for a run's agent shells: each agent gets its own port on 127.0.0.1, which passes
only that agent's allowlist (its CLI's own API and auth hosts) and refuses everything else with a short error.

  tools/mt/netgate.py CONFIG.json LOG.jsonl        serve until killed
  tools/mt/netgate.py --learn PORT LOG.jsonl       one port that passes everything and logs each host (to find a CLI's)

CONFIG: {"agents": {"NAME": {"port": 18101, "allow": ["api.x.ai", "*.x.ai"]}}}. An allow entry is a host, or
"*.domain" for the domain and its subdomains.
Each request is a line in LOG (time, agent, method, host, port, passed or refused, and the User-Agent the request
carried: a CONNECT's own header when it sends one; an https request's inner headers are encrypted and not seen).
It is only an environment setting (HTTP_PROXY, HTTPS_PROXY, ALL_PROXY in the agents' launch): a process that ignores
those variables (curl --noproxy '*', raw sockets, a client that reads no proxy setting) goes around it.
"""
import asyncio, json, sys, time

REFUSED = b"HTTP/1.1 403 Forbidden\r\nContent-Type: text/plain\r\nConnection: close\r\nContent-Length: %d\r\n\r\n%s"


def allowed(host, allow):
    host = host.lower().rstrip(".")
    for a in allow:
        a = a.lower()
        if a == "*" or host == a or (a.startswith("*.") and (host == a[2:] or host.endswith(a[1:]))):
            return True
    return False


class Gate:
    def __init__(self, log_path):
        self.log = open(log_path, "a", buffering=1)

    def note(self, **rec):
        rec["t"] = time.strftime("%Y-%m-%dT%H:%M:%S")
        self.log.write(json.dumps(rec) + "\n")

    async def pipe(self, r, w):
        try:
            while True:
                data = await r.read(65536)
                if not data:
                    break
                w.write(data)
                await w.drain()
        except (ConnectionError, OSError):
            pass
        finally:
            try:
                w.close()
            except Exception:
                pass

    def handler(self, agent, allow):
        async def handle(reader, writer):
            try:
                head = await asyncio.wait_for(reader.readuntil(b"\r\n\r\n"), 30)
            except Exception:
                writer.close()
                return
            lines = head.decode("latin-1").split("\r\n")
            parts = lines[0].split(" ")
            if len(parts) < 2:
                writer.close()
                return
            method, target = parts[0], parts[1]
            headers = {}
            for l in lines[1:]:
                if ":" in l:
                    k, v = l.split(":", 1)
                    headers[k.strip().lower()] = v.strip()
            ua = headers.get("user-agent")
            if method == "CONNECT":
                host, _, port = target.rpartition(":")
                port = int(port or 443)
            else:
                # an absolute URI: http://host[:port]/path
                rest = target.split("://", 1)[-1]
                hostport = rest.split("/", 1)[0]
                host, _, port = hostport.partition(":")
                port = int(port or 80)
            host = host.strip("[]")
            ok = allowed(host, allow)
            self.note(agent=agent, method=method, host=host, port=port, passed=ok, user_agent=ua)
            if not ok:
                body = f"refused by the run's network gate: {host} is not on this agent's list\n".encode()
                writer.write(REFUSED % (len(body), body))
                await writer.drain()
                writer.close()
                return
            try:
                ur, uw = await asyncio.wait_for(asyncio.open_connection(host, port), 20)
            except Exception as e:
                body = f"network gate: {host}:{port} unreachable ({type(e).__name__})\n".encode()
                writer.write(b"HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\nContent-Length: %d\r\n\r\n%s" % (len(body), body))
                await writer.drain()
                writer.close()
                return
            if method == "CONNECT":
                writer.write(b"HTTP/1.1 200 Connection Established\r\n\r\n")
                await writer.drain()
            else:
                # forward the request as is, the path made relative
                path = "/" + target.split("://", 1)[-1].split("/", 1)[1] if "/" in target.split("://", 1)[-1] else "/"
                first = f"{method} {path} {parts[2] if len(parts) > 2 else 'HTTP/1.1'}\r\n".encode()
                uw.write(first + head.split(b"\r\n", 1)[1])
                await uw.drain()
            await asyncio.gather(self.pipe(reader, uw), self.pipe(ur, writer))
        return handle


async def main():
    if sys.argv[1] == "--learn":
        port, log = int(sys.argv[2]), sys.argv[3]
        agents = {"learn": {"port": port, "allow": ["*"]}}
    else:
        agents, log = json.load(open(sys.argv[1]))["agents"], sys.argv[2]
    gate = Gate(log)
    servers = []
    for name, a in agents.items():
        servers.append(await asyncio.start_server(gate.handler(name, a["allow"]), "127.0.0.1", a["port"]))
        gate.note(agent=name, event="listening", port=a["port"], allow=a["allow"])
    await asyncio.gather(*(s.serve_forever() for s in servers))


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
