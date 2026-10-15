#!/usr/bin/env python3
"""Engine checks on a disposable Factorio 2.0.77 Space Age server with this runtime deployed.

Uses a real harness bot and bin/fh without --wait. Creates a test surface, inventories,
and entities; never run against a live game. See usage.md for the private-server setup.
The existing world's production continues during the checks. No visibility overrides.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import time
import uuid

from pog import PORTS, Rcon

ROOT = Path(__file__).resolve().parents[1]
CASES = [
    ('transfer', 'iron-chest', {'item': 'iron-plate', 'count': 5, 'direction': 'to_entity'}, '',
     'e.get_inventory(defines.inventory.chest).get_item_count("iron-plate")==5'),
    ('collect', 'iron-chest', {'item': 'iron-plate', 'count': 5}, 'e.insert{name="iron-plate",count=5}',
     'e.get_inventory(defines.inventory.chest).is_empty()'),
    ('feed', 'assembling-machine-2', {'items': ['iron-plate'], 'count': 5}, 'e.set_recipe("iron-gear-wheel")',
     'e.get_inventory(defines.inventory.assembling_machine_input).get_item_count("iron-plate")==5'),
    ('rearm', 'gun-turret', {'count': 5}, '', 'e.get_inventory(defines.inventory.turret_ammo).get_item_count()==5'),
    ('refuel', 'stone-furnace', {'count': 5}, '', 'e.get_fuel_inventory().get_item_count("coal")==5'),
    ('mine', 'iron-chest', {'ticks': 120}, '', 'not e.valid'),
    ('rotate', 'transport-belt', {'direction': 'east'}, '', 'e.direction==defines.direction.east'),
    ('configure', 'assembling-machine-2', {'recipe': 'iron-stick'},
     'e.set_recipe("iron-gear-wheel"); e.insert{name="iron-plate",count=5}', 'e.get_recipe().name=="iron-stick"'),
    ('build', 'iron-chest', {'item': 'iron-chest'}, 'e.destroy()', 's.find_entity("iron-chest",t.target)~=nil'),
]


class Check:
    def __init__(self, args):
        self.args = args
        self.password = args.password_file.read_text().strip()
        self.name = 'awc-' + uuid.uuid4().hex[:8]
        self.rows = []
        self.env = {**os.environ, 'POG_WORLD': self.name, 'POG_RCON_PORT': str(args.port),
                    'POG_RCON_PASSWORD_FILE': str(args.password_file.resolve()), 'FH_BOT': self.name}
        for key in ('POG_FH_SOCKET', 'FH_SOCKET', 'FACTORIO_RCON_PASSWORD'):
            self.env.pop(key, None)

    def lua(self, source):
        assert '--' not in source, 'RCON Lua is one line'
        r = Rcon('127.0.0.1', self.args.port, self.password, timeout=60)
        try:
            out = r.command('/silent-command ' + ' '.join(source.splitlines())).strip()
            try:
                return json.loads(out)
            except ValueError:
                raise AssertionError(out) from None
        finally:
            r.sock.close()

    def call(self, action, args=None):
        started = time.monotonic()
        p = subprocess.run([str(ROOT / 'bin/fh'), 'call', action, '--args', json.dumps(args or {}),
                            '--format', 'json'], env=self.env, text=True, capture_output=True, timeout=120)
        reply = json.loads(p.stdout)
        return reply, p.returncode, round(time.monotonic() - started, 3)

    def record(self, label, reply, code, elapsed):
        result = reply.get('result', {})
        row = {'case': label, 'exit': code, 'wall_seconds': elapsed, 'error': reply.get('error'),
               'accepted': result.get('accepted'), 'last': result.get('completion', {}).get('last')}
        self.rows.append(row)
        print(json.dumps(row), flush=True)

    def done(self, label, action, args, effect=None):
        reply, code, elapsed = self.call(action, args)
        self.record(label, reply, code, elapsed)
        assert code == 0 and reply['ok'], reply
        result = reply['result']
        assert result['accepted']['walking'], result
        completion = result['completion']
        assert not completion['active'], completion
        assert completion['last']['outcome'] in ('done', 'target_mined', 'duration_elapsed', 'transferred', 'collected', 'topped_up'), completion
        if effect:
            self.lua('local t=storage.autowalk_check; local s=t.s; local e=t.e; assert(' + effect + '); rcon.print(true)')
        return completion['last']

    def fixture(self, name, distance=20, extra=''):
        assert self.call('stop')[0]['ok']
        return self.lua(f'''local t=storage.autowalk_check; local s=t.s; local c=t.c;
          c.teleport({{0.5,0.5}},s);
          for _,e in pairs(s.find_entities_filtered{{area={{{{-80,-40}},{{80,40}}}}}}) do if e~=c then e.destroy() end end;
          local tiles={{}}; for _,x in ipairs({{-20,20,30,40}}) do tiles[#tiles+1]={{name="grass-1",position={{x,0}}}} end; s.set_tiles(tiles);
          local e=s.create_entity{{name="{name}",position={{{distance+.5},0.5}},force="player"}};
          t.e=e; t.target=e.position; {extra}; game.forces.player.chart(s,{{{{-90,-50}},{{90,50}}}});
          rcon.print(helpers.table_to_json(t.target))''')

    @staticmethod
    def target_args(action, args, position):
        return {**args, **({'positions': [position]} if action in ('feed', 'rearm', 'refuel') else {'position': position})}

    def run(self):
        bot = self.lua(f'rcon.print(remote.call("agent_harness","bot_create","{self.name}"))')
        assert bot['ok'], bot
        try:
            self.lua(f'''local s=game.create_surface("{self.name}",{{width=256,height=256,autoplace_settings={{
              entity={{treat_missing_as_default=false}},tile={{treat_missing_as_default=false}},decorative={{treat_missing_as_default=false}}}}}});
              s.request_to_generate_chunks({{0,0}},3); s.force_generate_chunk_requests();
              local tiles={{}}; for x=-90,90 do for y=-50,50 do tiles[#tiles+1]={{name="grass-1",position={{x,y}}}} end end; s.set_tiles(tiles);
              local c=game.get_entity_by_unit_number({bot['bot']['unit_number']}); c.teleport({{0.5,0.5}},s);
              for n,k in pairs({{["iron-chest"]=100,["iron-plate"]=1000,coal=300,["firearm-magazine"]=300,["speed-module"]=10}}) do c.insert{{name=n,count=k}} end;
              storage.autowalk_check={{s=s,c=c}}; game.tick_paused=false; rcon.print(true)''')
            for distance in (12, 31, 40):
                for action, name, args, extra, effect in CASES:
                    target = self.fixture(name, distance, extra)
                    time.sleep(.15)  # charting is asynchronous in the engine
                    given = self.target_args(action, args, target)
                    if distance < 32:
                        self.done(f'{action}-{distance}', action, given, effect)
                    else:
                        reply, code, elapsed = self.call(action, given)
                        self.record(f'{action}-40-refused', reply, code, elapsed)
                        message = reply.get('error', {}).get('message', '')
                        assert code == 1 and 'past the 32' in message and action + ' {' in message and '"walk":true' in message, reply
                        self.lua('local c=storage.autowalk_check.c; assert(c.position.x==0.5 and c.position.y==0.5); rcon.print(true)')
            target = self.fixture('iron-chest', 32, 'e.destroy()')
            self.done('build-32', 'build', {'item': 'iron-chest', 'position': target}, 's.find_entity("iron-chest",t.target)~=nil')
            self.fixture('iron-chest', extra='e.destroy()')
            self.done('build-batch-30', 'build', {'item': 'iron-chest', 'builds': [
                {'position': {'x': x, 'y': .5}} for x in (-14.5, -4.5, 5.5, 15.5)]},
                's.count_entities_filtered{name="iron-chest"}==4')
            self.fixture('iron-chest', extra='e.destroy()')
            reply, code, _ = self.call('queue_submit', {'steps': [
                {'action': 'build', 'args': {'item': 'iron-chest', 'position': {'x': 20.5, 'y': .5}}},
                {'action': 'transfer', 'args': {'position': {'x': 20.5, 'y': .5}, 'item': 'iron-plate', 'count': 7, 'direction': 'to_entity'}}]})
            assert code == 0, reply
            deadline = time.monotonic() + 30
            while True:
                q = self.call('queue_status', {'history': 'all'})[0]['result']
                if q['plan']['done'] == 2 or time.monotonic() > deadline:
                    break
                time.sleep(.25)
            assert q['plan']['ok'] == 2 and q['plan']['failed'] == 0, q
            history = q['history']
            assert history[0]['finished_tick'] > history[0]['started_tick'], history
            assert history[1]['started_tick'] >= history[0]['finished_tick'], history
            self.lua('local s=storage.autowalk_check.s; assert(s.find_entity("iron-chest",{20.5,0.5}).get_inventory(defines.inventory.chest).get_item_count("iron-plate")==7); rcon.print(true)')
            print('queue: both steps completed in order', flush=True)
            for action, name in [('rearm', 'gun-turret'), ('refuel', 'stone-furnace')]:
                self.fixture(name, extra='e.destroy()')
                positions = self.lua(f'''local s=storage.autowalk_check.s; local a={{}};
                  for _,x in ipairs({{-20,12,30}}) do local e=s.create_entity{{name="{name}",position={{x,0}},force="player"}}; a[#a+1]=e.position end;
                  rcon.print(helpers.table_to_json(a))''')
                last = self.done(action + '-tour', action, {'positions': positions, 'count': 7})
                assert last['visited'] == 3 and last['given'] == 21, last
                inventory = 'defines.inventory.turret_ammo' if action == 'rearm' else 'defines.inventory.fuel'
                self.lua(f'for _,e in ipairs(storage.autowalk_check.s.find_entities_filtered{{name="{name}"}}) do assert(e.get_inventory({inventory}).get_item_count()==7) end; rcon.print(true)')
            self.fixture('iron-chest', extra='e.destroy()')
            self.lua('local s=storage.autowalk_check.s; for _,x in ipairs({-20,20,30}) do s.set_tiles({{name="stone-path",position={x,0}}}) end; rcon.print(true)')
            last = self.done('mine-tiles', 'mine', {'tiles': True, 'positions': [{'x': x, 'y': 0} for x in (-20, 20, 30)]})
            assert last['mined'] == 3 and last['items']['stone-brick'] == 3, last
            self.lua('for _,x in ipairs({-20,20,30}) do assert(storage.autowalk_check.s.get_tile(x,0).name=="grass-1") end; rcon.print(true)')
            for name in ('tree-01', 'iron-ore'):
                target = self.fixture(name)
                last = self.done('mine-' + name, 'mine', {'position': target, 'ticks': 180})
                assert last['moved'] > 0, last
            target = self.fixture('assembling-machine-2', extra='e.set_recipe("iron-gear-wheel")')
            self.done('configure-modules', 'configure', {'position': target, 'modules': ['speed-module'], 'by': 'hand'},
                      'e.get_module_inventory().get_item_count("speed-module")==1')
            self.worms()
            print(f'PASS: {len(self.rows)} calls plus queue and engine-state assertions', flush=True)
        finally:
            self.lua(f'rcon.print(remote.call("agent_harness","bot_remove","{self.name}"))')
            self.lua(f'if game.surfaces["{self.name}"] then game.delete_surface("{self.name}") end; storage.autowalk_check=nil; rcon.print(true)')

    def worms(self):
        source = self.lua('local e=game.surfaces.nauvis.find_entities_filtered{type="turret",force="enemy",limit=1}[1]; assert(e,"copy needs a worm"); rcon.print(helpers.table_to_json{name=e.name,position=e.position,range=e.prototype.attack_parameters.range})')
        print('worm found on copy: ' + json.dumps(source), flush=True)
        for action, name, args, extra, _ in CASES:
            target = self.fixture(name)
            self.lua(f'''local t=storage.autowalk_check; local e=t.e; {extra};
              local w=t.s.create_entity{{name="{source['name']}",position={{40.5,0.5}},force="enemy"}};
              game.forces.player.chart(t.s,{{{{-10,-40}},{{80,40}}}}); rcon.print(true)''')
            time.sleep(.15)
            reply, code, elapsed = self.call(action, self.target_args(action, args, target))
            self.record('worm-' + action, reply, code, elapsed)
            assert code == 1 and 'inside ' + source['name'] in reply.get('error', {}).get('message', ''), reply
            self.lua('local c=storage.autowalk_check.c; assert(c.position.x==0.5 and c.position.y==0.5); rcon.print(true)')


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--port', type=int, help='localhost RCON port of a disposable copy; omitted: skip')
    ap.add_argument('--password-file', type=Path)
    args = ap.parse_args()
    if args.port is None:
        print('SKIP: autowalk private-server check requires --port and --password-file')
        return
    if args.port in PORTS.values():
        ap.error('use a separate private server port, not one assigned to a pog world')
    if args.password_file is None:
        ap.error('--password-file is required with --port')
    Check(args).run()


if __name__ == '__main__':
    main()
