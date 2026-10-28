#!/usr/bin/env python3
"""(d28 batch299 IC, viewer Aurora site 00:47: "could batch228's 31+ test use the actual Lua reader through inbox
persistence? Public code takes the newest 30 then advances the cursor, which can skip older requests.")
python3 tools/stream/test_operator_inbox_paging.py

The runtime's tells.lua runs in a real `lua` process with the save's state kept there across reads (the game's storage);
agents file through its `operator` handler (its rate limits, a game minute apart) and live.py's poll reads them through
`operator_requests` into runs/RUN/operator-inbox.jsonl (operator_inbox.py), restarting from the file's last seq as the
service does. On main the read returned the newest 30 after the cursor and live.py moved past them: with 45 waiting,
1-15 never reached the file (as in shift13 16:55:36, seqs 173-187).

- 45 filed while the service is down: a restarted service writes 1-45, in order, once each.
- 31 more during one poll gap, then the service restarts again mid-way: 46-76 once each, nothing twice.
- the kept log (200) trimmed past the cursor: the read says how many left it (an error line), the rest is written.
- one page alone: the oldest 30 and `more` 15.
"""
import json, os, shutil, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.dont_write_bytecode = True
import live  # noqa: E402
import operator_inbox  # noqa: E402

MOD = os.path.join(os.path.dirname(os.path.dirname(HERE)), "vendor", "factorio-harness", "mod", "agent-harness_0.1.0")

# The game side: tells.lua with the runtime's api parts the handler and the read use; storage lives in this process.
DRIVER = r"""
game = {tick = 1000}
local S = {}
local T = dofile(MOD .. '/tells.lua'){state = function() return S end, who = function(p) return p.name end}
local function enc(v)
  local k = type(v)
  if k == 'number' then return string.format('%d', v) end
  if k == 'string' then return '"' .. v:gsub('[%c"\\]', function(c) return string.format('\\u%04x', c:byte()) end) .. '"' end
  if k == 'boolean' then return tostring(v) end
  if k == 'nil' then return 'null' end
  if #v > 0 then
    local o = {}
    for i = 1, #v do o[i] = enc(v[i]) end
    return '[' .. table.concat(o, ',') .. ']'
  end
  local o = {}
  for key, x in pairs(v) do o[#o + 1] = enc(tostring(key)) .. ':' .. enc(x) end
  return '{' .. table.concat(o, ',') .. '}'
end
for line in io.lines() do
  local cmd, a, b = line:match('^(%a+)\t([^\t]*)\t?(.*)$')
  local ok, res = pcall(function()
    if cmd == 'tick' then game.tick = game.tick + tonumber(a); return {tick = game.tick} end
    if cmd == 'file' then return T.handlers.operator({name = a}, {text = b}) end
    if cmd == 'read' then return T.operator.operator_requests({since = tonumber(a), limit = tonumber(b)}) end
    if cmd == 'trim' then local r = S.operator_requests; while #r.log > tonumber(a) do table.remove(r.log, 1) end; return {kept = #r.log} end
    error('unknown ' .. tostring(cmd))
  end)
  io.write(enc(ok and {ok = true, result = res} or {ok = false, error = tostring(res)}), '\n')
  io.flush()
end
"""

AGENTS = ["astra", "sol", "luna", "muse", "grok", "haiku", "gemini", "codex", "nova"]


class LuaGame:
    def __init__(self):
        self.dir = tempfile.mkdtemp()
        script = os.path.join(self.dir, "driver.lua")
        with open(script, "w") as f:
            f.write(f"MOD = {json.dumps(MOD)}\n" + DRIVER)
        self.p = subprocess.Popen(["lua", script], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        self.filed = 0
        self.calls = []

    def cmd(self, *parts):
        self.p.stdin.write("\t".join(str(x) for x in parts) + "\n")
        self.p.stdin.flush()
        reply = json.loads(self.p.stdout.readline())
        if not reply["ok"]:
            raise RuntimeError(reply["error"])
        return reply["result"]

    def file(self, n):
        """n requests through the handler, the agents in turn, 61 game seconds apart (one a minute each, 10 an hour)."""
        seqs = []
        for _ in range(n):
            self.cmd("tick", 61 * 60)
            who = AGENTS[self.filed % len(AGENTS)]
            self.filed += 1
            seqs.append(self.cmd("file", who, f"request {self.filed} from {who}")["seq"])
        return seqs

    # live.py's harness: the operator read goes to the game
    def operator_read(self, action, args=None):
        self.calls.append((action, dict(args or {})))
        assert action == "operator_requests", action
        return self.cmd("read", args.get("since", ""), args.get("limit", "")), None

    def close(self):
        self.p.stdin.close()
        self.p.wait(timeout=10)


def service(game, path):
    """live.py's LiveSource as a (re)started stream service: the cursor from the inbox file."""
    src = live.LiveSource.__new__(live.LiveSource)
    src.h = game
    src.caps = {"harness": True}
    src.has_board, src.next_board_probe = False, time.time() + 999
    for k in ("has_groups", "has_hauling", "has_loadout", "has_clouds", "has_chronicle", "has_library_areas", "has_net_map"):
        setattr(src, k, False)
    src.has_confess, src.has_tells, src.has_operator = False, False, True
    src.inbox_path = path
    src.operator_seq = operator_inbox.start_seq(path)  # as live.py's __init__
    return src


def poll(src):
    obs, errors = {}, {}
    # only the operator read: the other feeds are off (has_* False and probed later)
    live.LiveSource.observe_board(src, obs, errors)
    return obs, errors


def file_seqs(path):
    return [json.loads(l)["seq"] for l in open(path)] if os.path.exists(path) else []


fails = []


def check(name, ok, detail=""):
    print(("ok   " if ok else "FAIL ") + name + ("" if ok else f": {detail}"))
    if not ok:
        fails.append(name)


def main():
    if not shutil.which("lua"):
        print("operator inbox paging: skipped (no lua)")
        return 0
    g = LuaGame()
    run = tempfile.mkdtemp()
    path = operator_inbox.path_for(run)
    try:
        # 45 filed while the service is down
        filed = g.file(45)
        check("45 filed through the handler, seqs 1-45", filed == list(range(1, 46)), filed)
        page = g.cmd("read", 0, 30)
        check("one page: the oldest 30 and 15 more", [r["seq"] for r in page["requests"]] == list(range(1, 31))
              and page["more"] == 15 and page["cursor"] == 45 and "trimmed" not in page, page)
        src = service(g, path)
        obs, errors = poll(src)
        check("a started service writes 1-45 in order, once each", file_seqs(path) == list(range(1, 46)), file_seqs(path))
        check("its poll paged: since 0 then 30", [c[1]["since"] for c in g.calls] == [0, 30], g.calls)
        check("the poll's rows are the 45, the cursor at 45", [r["seq"] for r in obs["operator_requests"]] ==
              list(range(1, 46)) and src.operator_seq == 45 and not errors, (src.operator_seq, errors))
        rows = [json.loads(l) for l in open(path)]
        check("rows keep the agent and the text", len(rows) == 45 and rows[0]["agent"] == "astra" and rows[0]["text"] == "request 1 from astra"
              and rows[44]["text"] == "request 45 from nova", rows[-1:])
        g.calls.clear()
        obs, errors = poll(src)
        check("caught up: one read, nothing new", obs["operator_requests"] == [] and len(g.calls) == 1, g.calls)

        # 31 more in one poll gap; the service restarts mid-way (the file's last seq, 60, is its cursor)
        g.file(15)
        poll(src)
        g.file(16)
        src = service(g, path)
        check("a restarted service resumes after the file's last seq", src.operator_seq == 60, src.operator_seq)
        poll(src)
        check("31 more: 46-76 once each, nothing twice", file_seqs(path) == list(range(1, 77)), file_seqs(path)[40:])

        # 260 filed while down: the save keeps 200 (OP_LOG); 60 left the log before the read, the rest is written once
        g.file(260)
        src = service(g, path)
        g.calls.clear()
        obs, errors = poll(src)
        check("the kept 200 in 7 pages of one poll", len(g.calls) == 7, g.calls)
        obs2, errors2 = poll(src)
        seqs = file_seqs(path)
        check("the kept 200 written once, in order", seqs == list(range(1, 77)) + list(range(137, 337)), seqs[70:80])
        check("the trimmed count named once", "60 requests after seq 76 left" in errors.get("operator_requests_trimmed", "")
              and "operator_requests_trimmed" not in errors2, (errors, errors2))

        # a fresh world counts from 1 again: the cursor follows it down (unchanged)
        g2 = LuaGame()
        try:
            g2.file(2)
            src2 = service(g2, path)
            check("a fresh world's cursor below the file's", src2.operator_seq == 336, src2.operator_seq)
            poll(src2)
            check("the cursor follows it down", src2.operator_seq == 2, src2.operator_seq)
            g2.file(1)
            poll(src2)
            check("then its next request is written", file_seqs(path)[-1] == 3, file_seqs(path)[-3:])
        finally:
            g2.close()
    finally:
        g.close()
    print(f"\n{'all ok' if not fails else str(len(fails)) + ' failed: ' + '; '.join(fails)}")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
