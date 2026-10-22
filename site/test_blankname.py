#!/usr/bin/env python3
"""A blank name, all the way through delivery (d22 batch75 AK12, viewer Aurora site:4296: "The site defaults blank names to
viewer, but the relay rejects viewer as impersonation:name. Please align the name rules and test blank-name posting all
the way through delivery."): python3 site/test_blankname.py

The Worker gave a blank name "viewer"; the relay (tools/stream/viewers.py RESERVED) drops "viewer" as
impersonation:name, so a blank-name line reached the site and no agent. Now:
1. the Worker (worker.js under node:sqlite): a blank name is "Guest" and four hex digits of the poster's client hash, the
   same for that poster each time and another for another poster, said back as guest_name; a typed name the relay
   would drop ("viewer", "Team", "v1ewer") is refused when posted; worker.js RELAY_RESERVED is viewers.RESERVED;
2. the relay: its own site read (SiteChat.poll on the Worker's GET) and its filter take the guest lines with no drop
   reason; a row the old Worker stored as "viewer" (or with no name) is relayed as "Guest", not dropped; the game line
   (Relay.lines) keeps the name and the line's id;
3. the game chat: audience.lua viewer_say posts it as "viewer Guest abcd" with its id (under lua);
4. the reply link: an agent's say that names "Guest abcd" is linked to that line, by its id.
"""
import json, os, re, shutil, subprocess, sys, tempfile

SITE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(SITE)
sys.path.insert(0, os.path.join(ROOT, "tools", "stream"))
sys.dont_write_bytecode = True
import viewers as V  # noqa: E402
import viewer_replies as VR  # noqa: E402

WORKER_JS = r"""
const { DatabaseSync } = require('node:sqlite');
const db = new DatabaseSync(':memory:');
const sql = { exec(q, ...params) {
  const st = db.prepare(q);
  let rows;
  try { rows = st.all(...params); } catch (e) { if (/does not return data|returns no data/i.test(String(e.message))) { st.run(...params); rows = []; } else throw e; }
  return { toArray: () => rows };
} };
let clock = 1792700000000;
Date.now = () => clock;
(async () => {
  const W = await import(process.argv[2]);
  const ctx = { storage: { sql }, blockConcurrencyWhile: async (f) => f() };
  const live = new W.Live(ctx, { PUBLISH_TOKEN: 'x'.repeat(20) });
  await new Promise((r) => setTimeout(r, 10));
  const post = async (body, ip) => {
    clock += 30000;  // past every per-client gap
    const r = await live.fetch(new Request('https://api.test/v1/chat', { method: 'POST', body: JSON.stringify(body), headers: { 'x-client-ip': ip } }));
    return { status: r.status, body: await r.json() };
  };
  const out = { reserved: W.RELAY_RESERVED };
  out.a1 = await post({ name: '', text: '@muse is the south wall closed?', cid: 'a'.repeat(24) }, '192.0.2.1');
  out.a2 = await post({ name: '   ', text: '@muse and the west one?' }, '192.0.2.1');
  out.b1 = await post({ text: '@muse hello from b' }, '192.0.2.2');
  out.typed = await post({ name: 'Aurora', text: 'a named line' }, '192.0.2.3');
  out.refused = {};
  for (const n of ['viewer', 'Viewers', 'Team', 'v1ewer', 'Host']) out.refused[n] = (await post({ name: n, text: 'x ' + n }, '192.0.2.4')).body.error || null;
  out.relayGet = await (await live.fetch(new Request('https://api.test/v1/chat?after=0&limit=100'))).json();
  process.stdout.write(JSON.stringify(out));
})().catch((e) => { console.error(e); process.exit(1); });
"""

LUA = r"""
package.path = 'mod/agent-harness_0.1.0/?.lua;' .. package.path
local printed = {}
game = {tick = 100000, print = function(m) printed[#printed + 1] = m end}
local s = {}
local chat = dofile('mod/agent-harness_0.1.0/chat.lua'){state = function() return s end, on_message = function() end}
local aud = dofile('mod/agent-harness_0.1.0/audience.lua'){state = function() return s end, post_viewer = function(n, t, o) return chat.viewer(n, t, o) end}
local r = aud.operator.viewer_say({name = NAME, text = TEXT, source = 'site', id = ID})
local last = s.chat and s.chat.lines and s.chat.lines[#s.chat.lines] or (s.chat and s.chat.log and s.chat.log[#s.chat.log]) or {}
io.write(tostring(r.posted), '\t', tostring(r.from), '\t', tostring(printed[#printed]), '\n')
"""


def check(name, ok, detail=""):
    if not ok:
        raise SystemExit(f"FAIL {name}: {detail}")


def lua_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def main():
    probe = shutil.which("node") and subprocess.run(["node", "-e", "require('node:sqlite')"], capture_output=True).returncode == 0
    if not probe:
        print("blank name: skipped (node without node:sqlite)")
        return
    with tempfile.TemporaryDirectory() as d:
        js = os.path.join(d, "w.js")
        open(js, "w").write(WORKER_JS)
        r = subprocess.run(["node", js, os.path.join(SITE, "worker", "worker.js")], capture_output=True, text=True, timeout=60)
    check("worker", r.returncode == 0, r.stderr[-2000:])
    o = json.loads(r.stdout)
    # 1. the Worker
    g1, g2, gb = o["a1"]["body"]["message"]["name"], o["a2"]["body"]["message"]["name"], o["b1"]["body"]["message"]["name"]
    check("a blank name: Guest and 4 hex digits", re.fullmatch(r"Guest [0-9a-f]{4}", g1) is not None, g1)
    check("the same poster, the same guest name; another poster another", g1 == g2 and gb != g1 and re.fullmatch(r"Guest [0-9a-f]{4}", gb), (g1, g2, gb))
    check("said back", o["a1"]["body"].get("guest_name") == g1 and "guest_name" not in o["typed"]["body"], (o["a1"]["body"], o["typed"]["body"]))
    check("a typed name as typed", o["typed"]["body"]["message"]["name"] == "Aurora", o["typed"])
    check("the relay's words refused when posted", all(v == "that name is reserved" for v in o["refused"].values()), o["refused"])
    check("the same list as the relay's", set(o["reserved"]) == V.RESERVED, set(o["reserved"]) ^ V.RESERVED)

    # 2. the relay: its own read of the Worker's GET, its filter
    page = o["relayGet"]
    page["messages"] = page["messages"] + [{"seq": 900, "t": 1792700500, "name": "viewer", "text": "@muse an old line", "channel": "game"},
                                           {"seq": 901, "t": 1792700510, "name": "", "text": "@muse no name at all", "channel": "game"}]
    sc = V.SiteChat(base="https://api.test", fetch=lambda url: json.dumps(page), resume=0)
    msgs = sc.poll()[0]
    by_text = {m["text"]: m for m in msgs}
    f = V.Filter(["muse", "astra", "sol"])
    now = 1792700600
    verdicts = {}
    for m in msgs:
        out, reasons = f.check(m, now)
        verdicts[m["text"]] = (out["name"], reasons)
    check("guest lines: no drop reason", verdicts["@muse is the south wall closed?"] == (g1, []) and verdicts["@muse hello from b"] == (gb, []), verdicts)
    check("the old Worker's 'viewer' and a nameless row: Guest, not impersonation", verdicts["@muse an old line"] == ("Guest", [])
          and verdicts["@muse no name at all"] == ("Guest", []), verdicts)
    check("posters apart for the limits", by_text["@muse is the south wall closed?"]["author"] != by_text["@muse hello from b"]["author"])
    m1 = dict(by_text["@muse is the south wall closed?"], name=g1)
    line = V.Relay.line(m1)  # the line @-mentions muse already
    check("the game line", line["name"] == g1 and line["id"] == "site:" + str(o["a1"]["body"]["message"]["seq"]) and line["source"] == "site", line)

    # 3. the game chat (audience.lua viewer_say under lua)
    if shutil.which("lua"):
        code = LUA.replace("NAME", lua_str(line["name"])).replace("TEXT", lua_str(line["text"])).replace("ID", lua_str(line["id"]))
        with tempfile.NamedTemporaryFile("w", suffix=".lua", delete=False) as fh:
            fh.write(code)
        try:
            lr = subprocess.run(["lua", fh.name], capture_output=True, text=True, timeout=30, cwd=os.path.join(ROOT, "vendor", "factorio-harness"))
        finally:
            os.unlink(fh.name)
        check("viewer_say", lr.returncode == 0, lr.stderr[-1500:])
        posted, frm, printed = lr.stdout.rstrip("\n").split("\t")
        check("posted in the game chat", posted == "true" and frm == "viewer " + g1 and ("viewer " + g1 + " (site):") in printed, lr.stdout)

    # 4. the reply link: a say naming the guest, linked to that line by its id
    seq = o["a1"]["body"]["message"]["seq"]
    viewer_line = {"seq": 50, "tick": 1000, "from": "viewer " + g1, "viewer": True, "source": "site", "source_id": f"site:{seq}",
                   "text": "@muse is the south wall closed?"}
    say = {"seq": 51, "tick": 1600, "from": "muse", "text": f"{g1}, the south wall is closed."}
    rr = VR.classify(say, [viewer_line], by_seq={50: viewer_line})
    check("the reply linked to the guest's line", rr["kind"] == "reply" and rr["to"] == [g1] and rr["answers"]["source_id"] == f"site:{seq}", rr)
    print(f"blank name: ok (a blank name is '{g1}' for that poster, '{gb}' for another; the relay's words refused on the "
          "site; the relay's read and filter take the guest lines, an old 'viewer' row too; viewer_say posts it; a reply "
          "naming the guest links to its line by id)")


if __name__ == "__main__":
    main()
