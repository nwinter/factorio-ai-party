#!/usr/bin/env python3
"""Optional engine checks; a disposable 2.0.77 Space Age server only.

Requires this branch's runtime deployed. Creates a bot and private test entities.
No arguments skip cleanly for the merge gate. Never use an assigned pog world.
"""
import argparse
import json
import subprocess
import time
from pathlib import Path

from pog import PORTS, Rcon
from test_autowalk_private import Check, ROOT


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', type=int)
    parser.add_argument('--password-file', type=Path)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    if args.port is None:
        print('SKIP: round0320b2 engine check needs --port and --password-file')
        return 0
    if args.port in PORTS.values() or args.password_file is None:
        parser.error('a disposable localhost port and --password-file are required; assigned pog ports refused')
    c = Check(args)
    rows = []

    def call(action, options=None, wait=False):
        cmd = [str(ROOT / 'bin/fh'), 'call', action, '--args', json.dumps(options or {}), '--format', 'json']
        if wait:
            cmd.append('--wait')
        proc = subprocess.run(cmd, env=c.env, text=True, capture_output=True, timeout=120)
        reply = json.loads(proc.stdout)
        assert proc.returncode == 0 and reply['ok'], reply
        return reply['result']

    def record(name, result):
        rows.append({'case': name, 'result': result})
        print(name, 'ok', flush=True)

    def profile(label, action, options, stop=False):
        request = json.dumps({'action': action, 'args': options, 'bot': c.name})
        stop_request = json.dumps({'action': 'stop', 'bot': c.name})
        source = 'local req=helpers.json_to_table(' + json.dumps(request) + ');for i=1,3 do req.id="private-profile-"..game.tick.."-"..i;local p=helpers.create_profiler();local reply=remote.call("agent_harness","dispatch",helpers.table_to_json(req));p.stop();assert(helpers.json_to_table(reply).ok,reply);rcon.print({"","' + label + ': ",p});'
        if stop:
            source += 'remote.call("agent_harness","dispatch",' + json.dumps(stop_request) + ');'
        source += 'end'
        rcon = Rcon('127.0.0.1', args.port, c.password, timeout=60)
        try:
            timing = rcon.command('/silent-command ' + source).strip()
        finally:
            rcon.sock.close()
        assert 'Error' not in timing and 'ms' in timing, timing
        rows.append({'case': label, 'profiler': timing})
        print(timing, flush=True)

    bot = c.lua(f'rcon.print(remote.call("agent_harness","bot_create","{c.name}"))')
    assert bot['ok'], bot
    try:
        c.lua(f'''local s=game.create_surface("{c.name}",{{width=256,height=128,autoplace_settings={{
          entity={{treat_missing_as_default=false}},tile={{treat_missing_as_default=false}},decorative={{treat_missing_as_default=false}}}}}});
          s.request_to_generate_chunks({{0,0}},3);s.force_generate_chunk_requests();
          local tiles={{}};for x=-80,80 do for y=-40,40 do tiles[#tiles+1]={{name='lab-dark-1',position={{x,y}}}} end end;s.set_tiles(tiles);
          local ch=game.get_entity_by_unit_number({bot['bot']['unit_number']});ch.teleport({{.5,.5}},s);
          s.create_entity{{name='electric-energy-interface',position={{-5,-8}},force='player'}};
          s.create_entity{{name='substation',position={{-2,-8}},force='player'}};s.create_entity{{name='radar',position={{2,-8}},force='player'}};
          local chest=s.create_entity{{name='iron-chest',position={{-20.5,.5}},force='player'}};chest.insert{{name='coal',count=200}};
          local a=s.create_entity{{name='stone-furnace',position={{20,0}},force='player'}};
          local b=s.create_entity{{name='boiler',position={{30,.5}},force='player'}};
          storage.round0320b2={{s=s,c=ch,chest=chest,a=a,b=b}};game.forces.player.chart(s,{{{{-64,-32}},{{64,32}}}});game.tick_paused=false;rcon.print(true)''')
        time.sleep(1)
        r = call('refuel', {'area': {'left_top': {'x': 10, 'y': -4}, 'right_bottom': {'x': 45, 'y': 4}},
                            'from': 'nearest', 'fuel': 'coal', 'count': 10}, wait=True)
        last = r.get('completion', r).get('last', {})
        assert last.get('outcome') == 'topped_up', r
        effect = c.lua('local t=storage.round0320b2;rcon.print(helpers.table_to_json({a=t.a.get_fuel_inventory().get_item_count("coal"),b=t.b.get_fuel_inventory().get_item_count("coal"),source=t.chest.get_inventory(defines.inventory.chest).get_item_count("coal")}))')
        assert effect == {'a': 10, 'b': 10, 'source': 180}, effect
        record('chest walk and mixed burner tour', {'last': last, 'effect': effect})
        c.lua('local t=storage.round0320b2;t.c.teleport({.5,.5},t.s);t.a.get_fuel_inventory().clear();t.b.get_fuel_inventory().clear();t.c.get_main_inventory().clear();t.chest.get_inventory(defines.inventory.chest).clear();t.belt=t.s.create_entity{name="transport-belt",position={-15.5,.5},direction=defines.direction.east,force="player"};t.belt.active=false;for line=1,2 do for i=0,3 do assert(t.belt.get_transport_line(line).insert_at(i/4,{name="coal",count=1})) end end;rcon.print(true)')
        r = call('refuel', {'radius': 32, 'from': 'nearest', 'count': 4}, wait=True)
        last = r.get('completion', r).get('last', {})
        assert last.get('outcome') == 'topped_up', r
        assert c.lua('rcon.print(storage.round0320b2.a.get_fuel_inventory().get_item_count("coal"))') == 4
        record('belt pickup reach and refuel', last)
        c.lua('local t=storage.round0320b2;t.c.teleport({.5,.5},t.s);t.a.get_fuel_inventory().clear();t.chest.insert{name="coal",count=8};t.extra=t.s.create_entity{name="iron-chest",position={-5.5,.5},force="player"};t.extra.insert{name="coal",count=2};rcon.print(true)')
        r = call('refuel', {'area': {'left_top': {'x': 15, 'y': -4}, 'right_bottom': {'x': 23, 'y': 4}}, 'from': 'nearest', 'count': 10}, wait=True)
        last = r.get('completion', r).get('last', {})
        assert last.get('outcome') == 'topped_up' and last.get('given') == 10, r
        assert c.lua('rcon.print(storage.round0320b2.a.get_fuel_inventory().get_item_count("coal"))') == 10
        assert len(last['sources']) == 2, last
        record('partial source refills the same burner', last)
        c.lua('local t=storage.round0320b2;t.c.teleport({.5,.5},t.s);t.a.get_fuel_inventory().clear();t.chest.insert{name="coal",count=20};rcon.print(true)')
        call('queue_submit', {'steps': [{'action': 'refuel', 'args': {'radius': 32, 'from': {'x': -20.5, 'y': .5}, 'count': 8}},
                                     {'action': 'wait_ticks', 'args': {'ticks': 2}}]})
        deadline = time.monotonic() + 40
        while True:
            q = call('queue_status', {'history': 'all'})
            if q['plan']['done'] >= 2 or q.get('last_failure') or time.monotonic() > deadline:
                break
            time.sleep(.25)
        assert q['plan']['ok'] == 2 and q['plan']['failed'] == 0, q
        record('named chest queue continues', q['plan'])
        c.lua('local t=storage.round0320b2;for x=0,3 do if x~=1 then t.s.create_entity{name=x==2 and "entity-ghost" or "transport-belt",inner_name=x==2 and "transport-belt" or nil,position={x+.5,10.5},force="player",direction=defines.direction.east} end end;rcon.print(true)')
        c.lua('local t=storage.round0320b2;t.c.teleport({16,16},t.s);rcon.print(true)')
        r = call('belt_gaps', {'from': {'x': .5, 'y': 10.5}, 'to': {'x': 3.5, 'y': 10.5}})
        assert len(r['missing']) == 1 and len(r['ghosts']) == 1 and r['belts'] == 2, r
        record('belt gap and ghost', r)
        profile('belt_gaps four-tile read', 'belt_gaps', {'from': {'x': .5, 'y': 10.5}, 'to': {'x': 3.5, 'y': 10.5}})
        c.lua('local t=storage.round0320b2;t.c.teleport({.5,.5},t.s);t.c.get_main_inventory().clear();t.chest.get_inventory(defines.inventory.chest).clear();t.chest.insert{name="coal",count=700};t.furnaces={};for x=0,9 do for y=0,5 do local e=t.s.create_entity{name="stone-furnace",position={-18+x*3,13+y*3},force="player"};t.furnaces[#t.furnaces+1]=e end end;rcon.print(true)')
        fuel_args = {'area': {'left_top': {'x': -21, 'y': 11}, 'right_bottom': {'x': 12, 'y': 31}}, 'from': 'nearest', 'count': 10}
        profile('refuel 60-burner start', 'refuel', fuel_args, stop=True)
        r = call('refuel', fuel_args, wait=True)
        last = r.get('completion', r).get('last', {})
        assert last.get('outcome') == 'topped_up' and last.get('given') == 600, r
        assert c.lua('local n=0;for _,e in ipairs(storage.round0320b2.furnaces) do if e.get_fuel_inventory().get_item_count("coal")==10 then n=n+1 end end;rcon.print(n)') == 60
        record('sixty furnaces in one round', last)
        c.lua('local t=storage.round0320b2;local s=game.planets.aquilo.create_surface();s.request_to_generate_chunks({0,0},1);s.force_generate_chunk_requests();local tiles={};for x=-12,12 do for y=-12,12 do tiles[#tiles+1]={name="foundation",position={x,y}} end end;s.set_tiles(tiles);for _,e in pairs(s.find_entities_filtered{area={{-5,-5},{5,5}}}) do e.destroy() end;t.c.teleport({.5,8.5},s);game.forces.player.chart(s,{{-16,-16},{16,16}});t.assembler=s.create_entity{name="assembling-machine-2",position={.5,.5},force="player"};t.pipe=s.create_entity{name="heat-pipe",position={2.5,2.5},force="player"};t.pipe.temperature=100;rcon.print(true)')
        time.sleep(.2)
        r = call('inspect', {'position': {'x': .5, 'y': .5}})
        assert r['heating']['frozen'] is False and r['heating']['demand_kw'] == 100, r
        assert r['heating']['heaters'][0]['name'] == 'heat-pipe' and not r['heating']['heat_neighbours'], r
        record('heated diagonal assembler', r['heating'])
        c.lua('storage.round0320b2.pipe.temperature=29;rcon.print(true)')
        time.sleep(.2)
        r = call('inspect', {'position': {'x': .5, 'y': .5}})
        assert r['heating']['frozen'] is True and 'below 30' in r['heating']['reason'], r
        record('cold pipe freezes assembler', r['heating'])
        profile('inspect frozen assembler', 'inspect', {'position': {'x': .5, 'y': .5}})
        r = call('build', {'dry_run': True, 'builds': [{'item': 'assembling-machine-2', 'position': {'x': -5.5, 'y': .5}},
                                                   {'item': 'heat-pipe', 'position': {'x': -3.5, 'y': .5}}]})
        assert r['heating'][0]['demand_kw'] == 100 and r['heating'][0]['heaters'][0]['planned_index'] == 2, r
        assert 'frozen' not in r['heating'][0], r
        record('planned heater and thermal mass', r['heating'])
        profile('build heating preview', 'build', {'dry_run': True, 'item': 'assembling-machine-2', 'position': {'x': -5.5, 'y': .5}})
        if args.output:
            args.output.write_text(json.dumps(rows, indent=2) + '\n')
    finally:
        c.lua(f'rcon.print(remote.call("agent_harness","bot_remove","{c.name}"))')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
