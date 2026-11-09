#!/usr/bin/env python3
"""Opt-in private-copy checks for atomic platform deconstruction preflight."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import time
import uuid
from pog import Rcon


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--imac', action='store_true')
    ap.add_argument('--output', type=Path)
    args = ap.parse_args()
    if not args.imac:
        print('SKIP: batch464 preflight requires --imac on a held private copy')
        return
    r = Rcon('imac.local', 27400, (Path.home()/'.config/pog/rcon-imac.pw').read_text().strip(), timeout=60)
    rows = []

    def lua(src):
        out = r.command('/silent-command '+' '.join(src.splitlines()))
        try:
            return json.loads(out)
        except ValueError:
            raise AssertionError(out)

    def call(options):
        req = dict(id='b464-preflight-'+uuid.uuid4().hex, bot='sol', action='deconstruct', args=options)
        return lua('rcon.print(remote.call("agent_harness","dispatch",'+json.dumps(json.dumps(req))+'))')

    def step(n=120):
        tick = lua(f'game.ticks_to_run={n}; rcon.print(game.tick)')
        for _ in range(600):
            if lua('rcon.print(game.tick)') >= tick+n:
                return
            time.sleep(.1)
        raise AssertionError('ticks did not advance')

    platform = 'B464 preflight '+uuid.uuid4().hex[:8]
    surface = lua("game.tick_paused=true; local p=game.forces.player.create_space_platform{name="+json.dumps(platform)+",planet='nauvis',starter_pack={name='space-platform-starter-pack'}}; p.apply_starter_pack(); p.paused=true; rcon.print(helpers.table_to_json({surface=p.surface.name}))")['surface']
    base = 'local s=game.surfaces['+json.dumps(surface)+']; local hub=s.platform.hub.get_inventory(1); '
    lua(base+"for _,pad in pairs(game.surfaces.nauvis.find_entities_filtered{type='cargo-landing-pad'}) do pad.force='neutral' end; local ts={}; for x=-8,105 do for y=-8,35 do ts[#ts+1]={name='space-platform-foundation',position={x,y}} end end; s.set_tiles(ts); rcon.print(true)")
    reset = base+"for _,e in pairs(s.find_entities_filtered{area={{8,8},{100,32}}}) do e.destroy() end; hub.clear(); storage.b464_preflight_entities={}; "
    snapshot = base+'''local es={}; for _,e in ipairs(storage.b464_preflight_entities) do
      local row={valid=e.valid}; if e.valid then row.name=e.name; row.marked=e.to_be_deconstructed('player'); row.inventories={};
      for i=1,e.get_max_inventory_index() do local inv=e.get_inventory(i); if inv then row.inventories[tostring(i)]=inv.get_contents() end end;
      if e.type=='inserter' and e.held_stack.valid_for_read then row.hand={name=e.held_stack.name,count=e.held_stack.count,quality=e.held_stack.quality.name} end;
      local ok,max=pcall(e.get_max_transport_line_index); if ok then row.lines={}; for i=1,max do local line=e.get_transport_line(i); if line and line.valid then row.lines[tostring(i)]=line.get_contents() end end end end;
      es[#es+1]=row end; rcon.print(helpers.table_to_json({entities=es,hub=hub.get_contents(),ground_marked=storage.b464_preflight_ground and storage.b464_preflight_ground.valid and storage.b464_preflight_ground.to_be_deconstructed('player') or false}))'''
    try:
        positions = lua(reset+'''local positions={}; local function make(name,x)
          local e=s.create_entity{name=name,position={x,20.5},quality='rare',force='player'}; e.active=false;
          storage.b464_preflight_entities[#storage.b464_preflight_entities+1]=e; positions[#positions+1]=e.position; return e end;
          make('steel-chest',10.5);
          local ghost=s.create_entity{name='entity-ghost',inner_name='transport-belt',position={15.5,20.5},force='player'};
          storage.b464_preflight_entities[#storage.b464_preflight_entities+1]=ghost; positions[#positions+1]=ghost.position;
          local e=make('fusion-reactor',25); e.get_inventory(1).insert{name='fusion-power-cell',count=28};
          e=make('nuclear-reactor',35); e.get_inventory(6).insert{name='depleted-uranium-fuel-cell',quality='rare',count=4};
          e=make('gun-turret',45); e.get_inventory(1).insert{name='firearm-magazine',quality='epic',count=3,ammo=3};
          e=make('crusher',55); e.set_recipe('carbonic-asteroid-crushing'); e.get_inventory(2).insert{name='carbonic-asteroid-chunk',count=2}; e.get_inventory(3).insert{name='carbon',count=3}; e.get_inventory(4).insert{name='speed-module',count=1};
          e=make('stack-inserter',65.5); e.held_stack.set_stack{name='iron-plate',quality='legendary',count=16};
          e=make('transport-belt',75.5); e.get_transport_line(1).insert_at(.25,{name='fusion-power-cell',quality='rare',count=4},4);
          e=make('steel-chest',85.5); e.get_inventory(1).insert{name='raw-fish',quality='uncommon',count=2,spoil_percent=.4};
          storage.b464_preflight_ground=s.create_entity{name='item-on-ground',position={92.5,25.5},stack={name='iron-plate',count=1}};
          for i=1,#hub do hub[i].set_stack{name='copper-cable',count=200} end;
          rcon.print(helpers.table_to_json(positions))''')
        options = dict(platform=platform, positions=positions)
        before = lua(snapshot)
        preview = call(dict(options, dry_run=True))
        assert preview['ok'], preview
        result = preview['result']
        assert result['would_refuse'] and result['would_mark'] == 0 and not result['platform_returns']['safe'], result
        text = '\n'.join(result['platform_return_lines'])
        for expected in ['28 normal fusion-power-cell','4 rare depleted-uranium-fuel-cell','3 epic firearm-magazine','2 normal carbonic-asteroid-chunk','3 normal carbon','1 normal speed-module','16 legendary iron-plate','4 rare fusion-power-cell','2 uncommon raw-fish']:
            assert expected in text, (expected, text)
        assert lua(snapshot) == before
        refused = call(options)
        assert not refused['ok'] and 'nothing marked' in json.dumps(refused), refused
        assert lua(snapshot) == before
        rows.append(dict(case='full hub: all inventory kinds; empty target and ghost first', preview=result, refusal=refused, intact=True))
        client = subprocess.run(['bin/fh','--bot','sol','call','deconstruct','--args',json.dumps(dict(options,dry_run=True))], env=dict(os.environ,POG_WORLD='imac'), capture_output=True, text=True)
        assert client.returncode == 0 and 'fusion-power-cell' in client.stdout and 'would_refuse' in client.stdout, client.stdout+client.stderr
        if args.output:
            args.output.with_suffix('.client.txt').write_text(client.stdout)
        lua(base+'hub[1].clear(); rcon.print(true)')
        before = lua(snapshot)
        refused = call(options)
        assert not refused['ok'] and lua(snapshot) == before
        rows.append(dict(case='one free slot still refuses entire batch', intact=True))
        refused = call(dict(platform=platform,area=dict(left_top=dict(x=8,y=8),right_bottom=dict(x=100,y=32)),items_on_ground=True,entity_types=['fusion-reactor','assembling-machine']))
        assert not refused['ok'] and lua(snapshot) == before
        rows.append(dict(case='mixed ground and entity batch refuses before ground marks', intact=True))
        # Each reactor fits alone in two slots; both together require three slots.
        positions = lua(reset+'''local ps={}; for _,x in ipairs{25,35} do local e=s.create_entity{name='fusion-reactor',position={x,20},force='player'}; e.active=false; e.get_inventory(1).insert{name='fusion-power-cell',count=28}; storage.b464_preflight_entities[#storage.b464_preflight_entities+1]=e; ps[#ps+1]=e.position end;
          for i=3,#hub do hub[i].set_stack{name='copper-cable',count=200} end; rcon.print(helpers.table_to_json(ps))''')
        for position in positions:
            result = call(dict(platform=platform,positions=[position],dry_run=True))
            assert result['ok'] and result['result']['platform_returns']['safe'], result
        before = lua(snapshot)
        result = call(dict(platform=platform,positions=positions,dry_run=True))
        assert result['ok'] and result['result']['would_refuse'], result
        refused = call(dict(platform=platform,positions=positions))
        assert not refused['ok'] and lua(snapshot)==before
        rows.append(dict(case='shared batch capacity, not independent per-entity checks', intact=True))
        # Existing partial stacks count as capacity; exact fit is accepted.
        lua(base+"hub[2].set_stack{name='fusion-power-cell',count=22}; rcon.print(true)")
        result = call(dict(platform=platform,positions=[positions[0]]))
        assert result['ok'] and result['result']['changed']==1, result
        step()
        actual = lua(base+"rcon.print(hub.get_item_count{name='fusion-power-cell',quality='normal'})")
        assert actual == 50, actual
        rows.append(dict(case='existing partial stack exact fit accepted', cells=actual))
        # A connectable type outside the preservation handler fails closed.
        positions = lua(reset+'''local ps={}; local empty=s.create_entity{name='steel-chest',position={10.5,20.5},force='player'}; storage.b464_preflight_entities[1]=empty; ps[1]=empty.position;
          local e=s.create_entity{name='loader',position={25,20},type='output',force='player'}; assert(e); assert(e.get_transport_line(1).insert_at(.25,{name='fusion-power-cell',quality='legendary',count=1})); storage.b464_preflight_entities[2]=e; ps[2]=e.position; rcon.print(helpers.table_to_json(ps))''')
        before=lua(snapshot)
        preview=call(dict(platform=platform,positions=positions,dry_run=True))
        assert preview['ok'] and preview['result']['would_refuse'] and 'uncovered' in preview['result']['reason'],preview
        refused=call(dict(platform=platform,positions=positions))
        assert not refused['ok'] and lua(snapshot)==before
        rows.append(dict(case='uncovered loader contents refuse whole batch', preview=preview['result'], intact=True))
        print(json.dumps(rows,indent=2))
    finally:
        lua('game.tick_paused=true; rcon.print(true)')
        r.sock.close()
        if args.output:
            args.output.write_text(json.dumps(rows,indent=2)+'\n')


if __name__ == '__main__':
    main()
