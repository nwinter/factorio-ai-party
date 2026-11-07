#!/usr/bin/env python3
"""Opt-in, destructive fixture on the held iMac private copy; no world-n access."""
import argparse
import json
import math
import uuid
from pathlib import Path
from pog import Rcon


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--imac', action='store_true')
    ap.add_argument('--output', type=Path)
    args = ap.parse_args()
    if not args.imac:
        print('SKIP: batch448 engine test requires --imac on a held private copy')
        return
    r = Rcon('imac.local', 27400, (Path.home()/'.config/pog/rcon-imac.pw').read_text().strip(), timeout=60)
    rows = []

    def lua(source):
        out = r.command('/silent-command ' + ' '.join(source.splitlines()))
        try:
            return json.loads(out)
        except ValueError:
            raise AssertionError(out)

    def call(action, options, rejected=False):
        request = dict(id='b448-'+uuid.uuid4().hex, bot='astra', action=action, args=options)
        out = lua('rcon.print(remote.call("agent_harness","dispatch",' + json.dumps(json.dumps(request)) + '))')
        if rejected:
            if out['ok']:
                assert out['result']['placed'] == 0 and 'is built facing' in out['result']['failed'][0]['error'], out
            else:
                assert 'is built facing' in out['error']['message'], out
            return out
        assert out['ok'], out
        return out['result']

    base = 'local s=game.surfaces["platform-1"]; '
    area = '{{994,994},{1007,1007}}'
    reset = base + f'''for _,e in pairs(s.find_entities_filtered{{area={area}}}) do e.destroy() end;
      local ts={{}}; for x=994,1006 do for y=994,1006 do ts[#ts+1]={{name="empty-space",position={{x,y}}}} end end;
      s.set_tiles(ts,false,false,false,false); '''
    try:
        lua('game.tick_paused=true; rcon.print(true)')
        for d in range(16):
            lua(reset + 'rcon.print(true)')
            engine = lua(base + f'''
              local full={{}}; for x=996,1004 do for y=996,1004 do full[#full+1]={{name='space-platform-foundation',position={{x,y}}}} end end;
              s.set_tiles(full,false,false,false,false);
              local spec={{name='railgun-turret',position={{1000.5,1000.5}},direction={d},force='player',build_check_type=defines.build_check_type.ghost_revive}};
              assert(s.can_place_entity(spec)); local need={{}};
              for _,t in ipairs(full) do
                s.set_tiles({{{{name='empty-space',position=t.position}}}},false,false,false,false);
                if not s.can_place_entity(spec) then need[#need+1]=t.position end;
                s.set_tiles({{t}},false,false,false,false)
              end; rcon.print(helpers.table_to_json(need))''')
            native = {tuple(p) for p in engine}
            lua(reset + 'rcon.print(true)')
            spec = dict(name='railgun-turret', position=dict(x=1000.5, y=1000.5), direction=d)
            options = dict(surface='platform-1', entities=[spec])
            if d % 2:
                call('place_ghosts', dict(options, dry_run=True), rejected=True)
                call('place_ghosts', options, rejected=True)
                spec['direction'] = d-1
            dry = call('place_ghosts', dict(options, dry_run=True))
            predicted = {(math.floor(p['x']), math.floor(p['y'])) for p in dry['tiles']['positions']}
            assert predicted == native, (d, 'dry vs native', predicted-native, native-predicted)
            untouched = lua(base + f'''rcon.print(helpers.table_to_json({{entities=s.count_entities_filtered{{area={area}}},
              floor=s.count_tiles_filtered{{area={area},name='space-platform-foundation'}}}}))''')
            assert untouched == dict(entities=0, floor=0), untouched
            placed = call('place_ghosts', options)
            actual = lua(base + f'''local tiles={{}}; for _,g in pairs(s.find_entities_filtered{{area={area},type='tile-ghost'}}) do
              tiles[#tiles+1]={{math.floor(g.position.x),math.floor(g.position.y)}} end; rcon.print(helpers.table_to_json(tiles))''')
            assert {tuple(p) for p in actual} == native, (d, placed, actual, native)
            ghosts = call('ghosts', dict(surface='platform-1', position=dict(x=1000.5,y=1000.5), radius=8, name='railgun-turret'))
            ghost = ghosts['ghosts'][0]
            assert ghost.get('foundation_ghosts') == len(native) and not ghost.get('no_foundation'), (d, ghost)
            result = lua(base + f'''
              local floor={{}}; for _,g in pairs(s.find_entities_filtered{{area={area},type='tile-ghost'}}) do
                floor[#floor+1]={{name='space-platform-foundation',position=g.position}}; g.destroy() end;
              s.set_tiles(floor,false,false,false,false);
              local g=s.find_entities_filtered{{area={area},type='entity-ghost'}}[1]; assert(g);
              local dir=g.direction; local _,e=g.revive(); assert(e and e.valid);
              rcon.print(helpers.table_to_json({{direction=dir,revived=e.name}}))''')
            assert result['direction'] == d//2*2, result
            rows.append(dict(asked=d, engine_direction=result['direction'], required=engine, dry_tiles=len(predicted), revived=result['revived']))
            print(f'direction {d}: {len(native)} exact tiles; dry run unchanged, live ghosts match, native revival passed', flush=True)
    finally:
        lua(reset + 'game.tick_paused=true; rcon.print(true)')
        r.sock.close()
        if args.output:
            args.output.write_text(json.dumps(rows, indent=2)+'\n')


if __name__ == '__main__':
    main()
