#!/usr/bin/env python3
"""Exercise the live API (state push, chat, rate limits, moderation). Run against `wrangler dev`:

    npx wrangler dev --config site/worker/wrangler.toml --port 8790 --ip 127.0.0.1   # reads site/worker/.dev.vars
    python3 site/worker/test_api.py http://127.0.0.1:8790

Posts test chat messages, so don't point it at the deployed Worker during a stream.
"""
import json, sys, urllib.error, urllib.request
from pathlib import Path

BASE = (sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:8790").rstrip("/")
TOKEN = json.loads((Path(__file__).parent / ".secrets.json").read_text())["PUBLISH_TOKEN"]
ORIGIN = "http://127.0.0.1:8765"
fails = []


def call(method, path, body=None, auth=False, ip="203.0.113.7", origin=ORIGIN):
    h = {"Content-Type": "application/json", "CF-Connecting-IP": ip}
    if origin:
        h["Origin"] = origin
    if auth:
        h["Authorization"] = "Bearer " + (TOKEN if auth is True else auth)
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(BASE + path, data=data, method=method, headers=h)
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return r.status, json.loads(r.read() or b"null"), dict(r.headers)
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"null"), dict(e.headers)


def check(name, cond, detail=""):
    print(("ok   " if cond else "FAIL ") + name + (f"  ({detail})" if detail and not cond else ""))
    if not cond:
        fails.append(name)


st, body, h = call("GET", "/v1/state")
check("state GET public", st == 200 and body["schema"] == 1, body)
check("noindex header", h.get("X-Robots-Tag") == "noindex, nofollow", h)
check("CORS for allowed origin", h.get("Access-Control-Allow-Origin") == ORIGIN, h)
st, _, h = call("GET", "/v1/state", origin="https://evil.example")
check("no CORS for other origin", "Access-Control-Allow-Origin" not in h, h)

st, body, _ = call("POST", "/v1/state", {"tick": 1, "game_time": "0h00m", "agents": []})
check("state POST needs token", st == 401, st)
st, body, _ = call("POST", "/v1/state", {"tick": 1}, auth="x" * 43)
check("state POST rejects wrong token", st == 401, st)
st, body, _ = call("POST", "/v1/state", {"tick": 144720, "game_time": "0h40m", "agents": []}, auth=True)
check("state POST with token", st == 200 and body.get("ok"), body)
st, body, _ = call("GET", "/v1/state?fresh=1")
check("state round trip", st == 200 and body["state"]["tick"] == 144720 and body["age_s"] is not None, body)

st, body, _ = call("POST", "/v1/chat", {"name": "tester", "text": "hello factory"}, ip="198.51.100.1")
check("chat post", st == 200 and body["message"]["text"] == "hello factory", body)
seq = body.get("message", {}).get("seq")
st, body, _ = call("POST", "/v1/chat", {"name": "tester", "text": "again"}, ip="198.51.100.1")
check("chat min gap", st == 429 and body.get("retry_after_s"), body)
st, body, _ = call("POST", "/v1/chat", {"name": "Opus", "text": "I am the real Opus"}, ip="198.51.100.2")
check("reserved name", st == 400, body)
st, body, _ = call("POST", "/v1/chat", {"name": "spam", "text": "visit https://x.example"}, ip="198.51.100.3")
check("no links", st == 400, body)
st, body, _ = call("POST", "/v1/chat", {"name": "long", "text": "x" * 201}, ip="198.51.100.4")
check("max length", st == 400, body)
st, body, _ = call("POST", "/v1/chat", {"name": "bidi", "text": "a‮b​c  d"}, ip="198.51.100.5")
check("control chars stripped", st == 200 and body["message"]["text"] == "a b c d", body)
st, body, _ = call("POST", "/v1/chat", {"name": "x", "text": "hi"}, origin="https://evil.example", ip="198.51.100.6")
check("chat POST blocked from other origins", st == 403, body)

st, body, _ = call("GET", f"/v1/chat?after={seq - 1}")
check("chat GET after", st == 200 and body["messages"][0]["seq"] == seq and "who" not in body["messages"][0], body)
st, body, _ = call("POST", "/v1/mod", {"action": "hide", "seq": seq})
check("mod needs token", st == 401, body)
st, body, _ = call("POST", "/v1/mod", {"action": "ban", "seq": seq}, auth=True)
check("mod ban", st == 200, body)
st, body, _ = call("GET", f"/v1/chat?after={seq - 1}&n=2")
check("banned message hidden", seq in body["hidden"] and all(m["seq"] != seq for m in body["messages"]), body)
st, body, _ = call("POST", "/v1/chat", {"name": "tester", "text": "back again"}, ip="198.51.100.1")
check("banned client can't post", st == 403, body)
call("POST", "/v1/mod", {"action": "unban", "seq": seq}, auth=True)

# Site viewers: one id per open page, at most 4 per address, other origins refused, bad ids refused
st, body, _ = call("GET", "/v1/state?w=0")
base = body.get("site_watching")
check("state GET has site_watching", isinstance(base, int), body)
for i in range(6):
    st, body, _ = call("POST", "/v1/here", {"id": f"{i:02x}" * 12}, ip="198.51.100.20")
check("here POST", st == 200 and body == {"ok": True}, body)
call("POST", "/v1/here", {"id": "ab" * 12}, ip="198.51.100.21")
call("POST", "/v1/here", {"id": "ab" * 12}, ip="198.51.100.21")  # the same page again
st, body, _ = call("GET", "/v1/state?w=1")
check("site_watching counts pages, 4 per address", body.get("site_watching") == base + 5, body.get("site_watching"))
st, body, _ = call("POST", "/v1/here", {"id": "not-hex"})
check("here POST bad id", st == 400, body)
st, body, _ = call("POST", "/v1/here", {"id": "cd" * 12}, origin="https://evil.example")
check("here POST blocked from other origins", st == 403, body)

print("all passed" if not fails else f"{len(fails)} failed")
sys.exit(1 if fails else 0)
