#!/usr/bin/env python3
"""Optional checks on a disposable local Factorio 2.0.77 Space Age copy only."""
import argparse
import json
import time
from pathlib import Path
from pog import PORTS, Rcon
from test_autowalk_private import Check


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', type=int)
    parser.add_argument('--password-file', type=Path)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    if args.port is None:
        print('SKIP: d15-0450a private engine check needs --port and --password-file')
        return 0
    if args.port in PORTS.values() or args.password_file is None:
        parser.error('disposable localhost port and --password-file required; assigned pog ports refused')
    c = Check(args)
    rows = []

    def call(action, options=None):
        reply, code, elapsed = c.call(action, options)
        assert code == 0 and reply['ok'], reply
        return reply['result']

    def record(name, value):
        rows.append({'case': name, 'result': value})
        print(name, 'ok', flush=True)

    def profile(action, options, label=None):
        req = json.dumps({'bot': c.name, 'action': action, 'args': options})
        source = 'local req=helpers.json_to_table(' + json.dumps(req) + ');for i=1,3 do req.id="d15-prof-"..game.tick.."-"..i;local p=helpers.create_profiler();local out=remote.call("agent_harness","dispatch",helpers.table_to_json(req));p.stop();assert(helpers.json_to_table(out).ok,out);rcon.print({"","' + action + ': ",p});end'
        r = Rcon('127.0.0.1', args.port, c.password, timeout=60)
        try:
            timing = r.command('/silent-command ' + source).strip()
        finally:
            r.sock.close()
        assert 'Error' not in timing and 'ms' in timing, timing
        rows.append({'case': (label or action) + ' profiler', 'timing': timing})
        print(timing, flush=True)

    bot = c.lua(f'rcon.print(remote.call("agent_harness","bot_create","{c.name}"))')
    try:
        c.lua('rcon.print(remote.call("agent_harness","profile_ticks",{seconds=60}))')
        c.lua(f'''local s=game.create_surface("{c.name}",{{width=512,height=128,autoplace_settings={{entity={{treat_missing_as_default=false}},tile={{treat_missing_as_default=false}},decorative={{treat_missing_as_default=false}}}}}});
          s.request_to_generate_chunks({{0,0}},4);s.force_generate_chunk_requests();
          local tiles={{}};for x=-90,90 do for y=-40,40 do tiles[#tiles+1]={{name='lab-dark-1',position={{x,y}}}} end end;s.set_tiles(tiles);
          local ch=game.get_entity_by_unit_number({bot['bot']['unit_number']});ch.teleport({{16,16}},s);
          local belts={{}};for x=0,30 do local e=s.create_entity{{name='transport-belt',position={{x+.5,8.5}},direction=defines.direction.east,force='player'}};e.active=false;e.get_transport_line(1).insert_at_back{{name='iron-ore',count=1}};belts[#belts+1]=e end;
          local chest=s.create_entity{{name='iron-chest',position={{5.5,4.5}},force='player'}};chest.insert{{name='coal',count=50}};
          s.create_entity{{name='electric-energy-interface',position={{-5,-8}},force='player'}};s.create_entity{{name='substation',position={{-2,-8}},force='player'}};
          local radar=s.create_entity{{name='radar',position={{2,-8}},force='player'}};game.forces.player.chart(s,{{{{-64,-32}},{{64,32}}}});
          storage.d15check={{s=s,c=ch,belts=belts,chest=chest,radar=radar}};game.tick_paused=false;rcon.print(true)''')
        time.sleep(1)
        line = {'from': {'x': .5, 'y': 8.5}, 'to': {'x': 30.5, 'y': 8.5}}
        r = call('belt_gaps', line)
        assert r['belts'] == 31, r
        call('inspect', {'position': {'x': 5.5, 'y': 4.5}})
        call('trace', {'position': {'x': .5, 'y': 8.5}, 'forward': True})
        c.lua('local t=storage.d15check;t.belts[15].destroy();t.belts[16].destroy();rcon.print(true)')
        call('belt_gaps', line)
        r = call('game_alerts', {'kind': 'belt_cut', 'surface': c.name})
        assert len(r['groups']) == 1 and r['groups'][0]['count'] == 2, r
        record('two observed belt cuts', r)
        c.lua('local t=storage.d15check;for _,x in ipairs{14,15} do t.s.create_entity{name="transport-belt",position={x+.5,8.5},force="player",direction=defines.direction.east} end;rcon.print(true)')
        call('belt_gaps', line)
        r = call('game_alerts', {'kind': 'belt_cut', 'surface': c.name})
        assert not r['groups'], r
        record('rebuild clears belt cuts', r)
        profile('belt_gaps', line)
        r = call('order_set', {'name': 'private-wide', 'when': {'until': 'ammo_below', 'count': 10, 'radius': 256}, 'steps': [{'action': 'wait_ticks', 'args': {'ticks': 60}}]})
        assert r['order']['max_ticks'] >= 14400, r
        call('order_remove', {'name': 'private-wide'})
        record('256-tile standing order budget', r)
        r = call('order_set', {'name': 'private-area', 'when': {'until': 'fuel_below', 'count': 10, 'area': [[-128, -128], [128, 128]]}, 'steps': [{'action': 'wait_ticks', 'args': {'ticks': 60}}]})
        call('order_remove', {'name': 'private-area'})
        record('256-square fuel trigger', r)
        c.lua('local t=storage.d15check;t.chest.clear_items_inside();t.radar.destroy();t.c.teleport({200,0},t.s);game.forces.player.clear_chart(t.s);rcon.print(true)')
        time.sleep(1)
        r = call('inspect', {'position': {'x': 5.5, 'y': 4.5}})
        assert r['by'] == 'last seen memory' and r['current'] is False and 'coal' in json.dumps(r), r
        record('hidden inspect preserves prior contents', r)
        r = call('trace', {'position': {'x': .5, 'y': 8.5}, 'forward': True})
        assert r['by'] == 'last seen memory' and r['current'] is False, r
        record('hidden trace returns dated snapshot', r)
        profile('inspect', {'position': {'x': 5.5, 'y': 4.5}})
        profile('trace', {'position': {'x': .5, 'y': 8.5}, 'forward': True})
        c.lua('local t=storage.d15check;t.c.teleport({16,16},t.s);t.s.create_entity{name="radar",position={2,-8},force="player"};game.forces.player.chart(t.s,{{-64,-32},{64,32}});local d=t.s.create_entity{name="electric-mining-drill",position={-8.5,.5},force="player"};for x=-18,-14 do t.s.create_entity{name="coal",position={x+.5,.5},amount=1000} end;rcon.print(true)')
        time.sleep(1)
        options = {'position': {'x': -8.5, 'y': .5}, 'resource': 'coal', 'radius': 24, 'limit': 1}
        r = call('drill_sites', options)
        assert r['sites'] and r['resource'] == 'coal', r
        record('same-resource drill placement in engine', r)
        profile('drill_sites', options, 'drill_sites sparse')
        c.lua('local t=storage.d15check;for x=-32,16 do for y=-24,24 do if math.abs(x+9)>=3 or math.abs(y)>=3 then if not t.s.find_entity("coal",{x+.5,y+.5}) then t.s.create_entity{name="coal",position={x+.5,y+.5},amount=1000} end end end end;rcon.print(true)')
        r = call('drill_sites', options)
        assert r['radius_reduced'] and r['searched_radius'] < 24, r
        record('dense drill lookup shrinks its search', r)
        profile('drill_sites', options, 'drill_sites dense')
        c.lua('local t=storage.d15check;for x=64,95 do for y=0,31 do local e=t.s.create_entity{name="transport-belt",position={x+.5,y+.5},direction=defines.direction.east,force="player"};e.active=false;e.get_transport_line(1).insert_at_back{name="iron-ore",count=1} end end;game.forces.player.chart(t.s,{{64,0},{96,32}});rcon.print(true)')
        time.sleep(1)
        dense_line = {'from': {'x': 64.5, 'y': .5}, 'to': {'x': 95.5, 'y': .5}}
        for _ in range(10):
            r = call('belt_gaps', dense_line)
            if r['belts'] == 32:
                break
        assert r['belts'] == 32, r
        record('full 1024-belt chunk', r)
        profile('belt_gaps', dense_line, 'belt_gaps 1024-belt chunk')
    finally:
        c.lua('rcon.print(remote.call("agent_harness","profile_ticks",{stop=true}))')
        c.lua(f'rcon.print(remote.call("agent_harness","bot_remove","{c.name}"))')
        if args.output:
            args.output.write_text(json.dumps(rows, indent=2) + '\n')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
