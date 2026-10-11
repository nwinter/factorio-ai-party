#!/usr/bin/env python3
"""Offline checks for the console audit: python3 tools/test_console_audit.py

- the mod's shape key (control.lua, run under `lua` with stubs) equals tools/console_audit.py's;
- our own tools' Lua is labelled operator; a deploy, Lua typed around fh and a harness form with code after it are not;
- the report lists what to read; an older world without console_log says so;
- stop-team.sh runs the audit before the save.
"""
import json, os, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))
import console_audit as ca  # noqa: E402
import pog  # noqa: E402

DRIVER = r"""
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
log=function() end
storage={}; game={tick=7,get_player=function(i) return {name='p'..i} end}
defines={events={on_tick=1,on_console_command=9}}
helpers={table_to_json=function(v) return v end,json_to_table=function(v) return v end}
local console
script={on_init=function() end,on_load=function() end,on_configuration_changed=function() end,
  on_event=function(id,fn) if id==9 then console=fn end end}
remote={add_interface=function() end}
package.loaded.runtime={dispatch=function() end,tick=function() end,stop_all=function() end}
dofile('mod/agent-harness_0.1.0/control.lua')
for line in io.lines(arg[1]) do
  local name,text=line:match('^(%S+) (.*)$')
  console{command=name,parameters=text:gsub('\\n','\n')}
end
for key,e in pairs(storage.console_audit.shapes) do io.write(key:gsub('\n','\\n'),'\n') end
io.write('harness ',storage.console_audit.harness,'\n')
"""

SCORE = "silent-command " + " ".join(l.strip() for l in pog.SCORE_LUA.strip().splitlines())
SAMPLES = [
    SCORE,
    "silent-command game.tick_paused = true rcon.print('paused at ' .. game.tick)",
    'silent-command rcon.print(remote.call("agent_harness","bots"))',
    'silent-command rcon.print(remote.call("agent_harness","bot_create","luna"))',
    "silent-command local i = remote.interfaces.agent_harness if not (i and i.camera) then rcon.print('{\"ok\":false,\"stub\":true}') return end "
    'local r = remote.call("agent_harness", "camera", [[{"follow":"sol","zoom":0.6}]]) rcon.print(type(r) == "string" and r or helpers.table_to_json({ok = true, result = r}))',
    "server-save ",
    'silent-command rcon.print(remote.call("agent_harness", "install", [[return {}]]))',
    'c game.player.insert{name="iron-plate", count=100}',
    'silent-command rcon.print(remote.call("agent_harness", "dispatch", [[\\n{}]])) game.speed=10 rcon.print(1)',
    'silent-command rcon.print(remote.call("agent_harness", "dispatch", [[\\n{"id":"x","action":"status","bot":"sol"}]]))',
]


def shapes():
    """The mod and the reader give the same shape for each sample, and the harness request is only counted."""
    tmp = tempfile.mkdtemp()
    src, drv = os.path.join(tmp, "in.txt"), os.path.join(tmp, "drv.lua")
    open(src, "w").write("\n".join(SAMPLES) + "\n")
    open(drv, "w").write(DRIVER)
    out = subprocess.run(["lua", drv, src], cwd=os.path.join(ROOT, "vendor", "factorio-harness"),
                         capture_output=True, text=True, check=True).stdout.splitlines()
    assert out[-1] == "harness 1", out[-1]
    lua = set(out[:-1])
    py = set()
    for s in SAMPLES[:-1]:
        name, text = s.split(" ", 1)
        py.add(ca.shape(name, text.replace("\\n", "\n")).replace("\n", "\\n"))
    assert lua == py, (lua ^ py)
    print("shapes (lua = python): ok")


def labels():
    known = ca.operator_shapes()
    got = []
    for s in SAMPLES[:-1]:
        name, text = s.split(" ", 1)
        got.append(ca.label({"command": name, "first_text": text, "shape": ca.shape(name, text)}, known))
    want = ["operator", "operator", "operator", "operator", "operator", "server", "deploy", "UNKNOWN", "UNKNOWN"]
    assert got == want, got
    # The stream service's flow Lua with an item list, and the analyst's snapshot with its surface, are operator too.
    sys.path.insert(0, os.path.join(ROOT, "tools", "stream"))
    import ast
    tree = ast.parse(open(os.path.join(ROOT, "tools", "stream", "harness.py")).read())
    flow = next(n.value.value for n in ast.walk(tree) if isinstance(n, ast.Assign)
                and any(getattr(t, "id", "") == "FLOW_LUA" for t in n.targets))
    text = ca.one_line(flow.replace("ITEMS", '{"iron-plate","copper-plate","electronic-circuit"}'))
    assert ca.label({"command": "silent-command", "shape": ca.shape("silent-command", text)}, known) == "operator"
    tree = ast.parse(open(os.path.join(ROOT, "tools", "analyst", "game.py")).read())
    snap = next(n.value.value for n in ast.walk(tree) if isinstance(n, ast.Assign)
                and any(getattr(t, "id", "") == "SNAPSHOT_LUA" for t in n.targets))
    text = ca.one_line(snap.replace("SURFACE", json.dumps("nauvis")))
    assert ca.label({"command": "silent-command", "shape": ca.shape("silent-command", text)}, known) == "operator"
    # tools/players.py's /kick and /ban for a carried vote: moderation, listed one by one.
    assert ca.label({"command": "kick", "first_text": "nick mined the bus"}, known) == "moderation"
    assert ca.label({"command": "ban", "first_text": "nick x"}, known) == "moderation"
    lines, unknown = ca.report({"ok": True, "tick": 9, "harness": 1, "other": 1, "entries": [
        {"seq": 1, "command": "kick", "first_text": "nick mined the bus", "count": 1, "first_tick": 5, "last_tick": 5, "players": ["rcon"]}]})
    assert "moderation: 1 shapes, 1 commands" in lines and "  tick 5-5 x1 by rcon: /kick nick mined the bus" in lines and not unknown, lines
    print("labels: ok")


def report():
    log = {"ok": True, "tick": 900, "seq": 3, "harness": 5000, "other": 103, "dropped": 0, "entries": [
        {"seq": 1, "command": "silent-command", "count": 100, "first_tick": 10, "last_tick": 800, "players": ["rcon"],
         "first_text": SCORE.split(" ", 1)[1][:600], "shape": ca.shape("silent-command", SCORE.split(" ", 1)[1])},
        {"seq": 2, "command": "c", "count": 2, "first_tick": 500, "last_tick": 520, "players": ["rcon"],
         "first_text": "game.forces.player.research_all_technologies()", "last_text": "game.forces.player.research_all_technologies()"},
        {"seq": 3, "command": "server-save", "count": 1, "first_tick": 899, "last_tick": 899, "players": ["rcon"], "first_text": ""}]}
    lines, unknown = ca.report(log, "n")
    text = "\n".join(lines)
    assert lines[0].startswith("console audit, world n at tick 900: 5000 harness requests, 103 other commands in 3 shapes"), lines[0]
    assert "operator: 1 shapes, 100 commands" in text and "deploy: none" in text, text
    assert "UNKNOWN: 1 shapes, 2 commands" in text and "tick 500-520 x2 by rcon: /c game.forces.player.research_all" in text, text
    assert len(unknown) == 1
    lines, _ = ca.report({"ok": False, "error": "this world's agent-harness mod has no console_log: deploy the current mod"}, "n")
    assert "unavailable" in lines[0] and "deploy the current mod" in lines[0], lines
    # --file and --strict: exit 2 when something is unknown.
    path = os.path.join(tempfile.mkdtemp(), "log.json")
    json.dump(log, open(path, "w"))
    r = subprocess.run([sys.executable, os.path.join(ROOT, "tools", "console_audit.py"), "--file", path, "--strict"],
                       capture_output=True, text=True)
    assert r.returncode == 2 and "UNKNOWN: 1" in r.stdout, (r.returncode, r.stdout, r.stderr)
    print("report: ok")


def stop_team():
    text = open(os.path.join(ROOT, "tools", "stop-team.sh")).read()
    audit, save = text.find("console_audit.py"), text.find("pog.py --world \"$world\" save")
    assert 0 < audit < save, "stop-team.sh runs the audit before the save"
    subprocess.run(["bash", "-n", os.path.join(ROOT, "tools", "stop-team.sh")], check=True)
    print("stop-team: ok")


if __name__ == "__main__":
    shapes()
    labels()
    report()
    stop_team()
