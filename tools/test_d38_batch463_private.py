#!/usr/bin/env python3
"""Opt-in destructive platform mining fixtures; only the engineer's held iMac copy."""
import argparse
import json
import time
import uuid
from pathlib import Path
from pog import Rcon


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--imac', action='store_true')
    ap.add_argument('--output', type=Path)
    args = ap.parse_args()
    if not args.imac:
        print('SKIP: batch463 requires --imac on a held private copy')
        return
    r = Rcon('imac.local', 27400, (Path.home()/'.config/pog/rcon-imac.pw').read_text().strip(), timeout=60)
    rows = []

    def lua(source):
        out = r.command('/silent-command ' + ' '.join(source.splitlines()))
        try:
            return json.loads(out)
        except ValueError:
            raise AssertionError(out)

    def call(action, options):
        request = dict(id='b463-'+uuid.uuid4().hex, bot='sol', action=action, args=options)
        out = lua('rcon.print(remote.call("agent_harness","dispatch",' + json.dumps(json.dumps(request)) + '))')
        assert out['ok'], out
        return out['result']

    def step(n=120):
        tick = lua(f'game.ticks_to_run={n}; rcon.print(game.tick)')
        for _ in range(100):
            now = lua('rcon.print(game.tick)')
            if now >= tick+n:
                return
            time.sleep(.1)
        raise AssertionError('ticks did not advance')

    platform_name = 'B463 mining fixture '+uuid.uuid4().hex[:8]
    fixture_surface = lua("game.tick_paused=true; local p=game.forces.player.create_space_platform{name=" + json.dumps(platform_name) + ",planet='nauvis',starter_pack={name='space-platform-starter-pack'}}; p.apply_starter_pack(); rcon.print(helpers.table_to_json({surface=p.surface.name}))")["surface"]
    rows.append(dict(fixture_platform=platform_name, fixture_surface=fixture_surface))
    base = 'local s=game.surfaces['+json.dumps(fixture_surface)+']; local hub=s.platform.hub.get_inventory(defines.inventory.hub_main); '

    reset = base + '''for _,e in pairs(s.find_entities_filtered{area={{990,990},{1040,1010}}}) do e.destroy() end;
      hub.clear(); local ts={}; for x=990,1040 do for y=990,1010 do ts[#ts+1]={name='space-platform-foundation',position={x,y}} end end;
      s.set_tiles(ts); '''
    try:
        lua(base + "game.tick_paused=true; for _,e in pairs(s.find_entities_filtered{type='inserter',area={{-8,-8},{8,8}}}) do e.active=false end; rcon.print(true)")
        for kind in ['transport-belt', 'underground-belt', 'splitter']:
            for full in [False, True]:
                before = lua(reset + f'''
                  local e=s.create_entity{{name='{kind}',position={{1000.5,1000.5}},direction=defines.direction.south,force='player'}};
                  local counts={{}};
                  for i=1,e.get_max_transport_line_index() do local line=e.get_transport_line(i);
                    if line and line.valid then
                      for j=0,1 do local q=j==0 and 'normal' or 'rare';
                        if line.insert_at(j*.25,{{name='fusion-power-cell',quality=q,count=1}}) then counts[q]=(counts[q] or 0)+1 end
                      end
                    end
                  end;
                  if {str(full).lower()} then for i=1,#hub do hub[i].set_stack{{name='copper-cable',count=200}} end end;
                  rcon.print(helpers.table_to_json({{expected=counts,slots=#hub,free=hub.count_empty_stacks()}}))''')
                assert sum(before['expected'].values()) > 0, before
                dry = call('deconstruct', dict(platform=platform_name, positions=[dict(x=1000.5,y=1000.5)], entity_names=[kind], dry_run=True))
                if full:
                    assert dry['would_refuse'] and dry['would_mark'] == 0, dry
                    request = dict(id='b463-full-'+uuid.uuid4().hex, bot='sol', action='deconstruct', args=dict(platform=platform_name, positions=[dict(x=1000.5,y=1000.5)], entity_names=[kind]))
                    refused = lua('rcon.print(remote.call("agent_harness","dispatch",'+json.dumps(json.dumps(request))+'))')
                    assert not refused['ok'], refused
                    lua(base + "local e=s.find_entities_filtered{position={1000.5,1000.5},name='"+kind+"'}[1]; assert(e and not e.to_be_deconstructed('player')); assert(e.order_deconstruction('player')); rcon.print(true)")
                else:
                    assert dry['would_mark'] == 1, dry
                    marked = call('deconstruct', dict(platform=platform_name, positions=[dict(x=1000.5,y=1000.5)], entity_names=[kind]))
                    assert marked['changed'] == 1, marked
                step()
                after = lua(base + '''local cells={}; for _,v in ipairs(hub.get_contents()) do if v.name=='fusion-power-cell' then cells[v.quality]=v.count end end;
                  rcon.print(helpers.table_to_json({cells=cells,belt=s.count_entities_filtered{area={{999,999},{1002,1002}},type={'transport-belt','underground-belt','splitter'}},slots=#hub}))''')
                rows.append(dict(kind=kind, full=full, before=before, after=after))
                print(json.dumps(rows[-1]), flush=True)
                if full:
                    assert after['belt'] == 1 and not after['cells'], rows[-1]
                    # With just one free slot the belt fits; native overflow must retain every cell on the floor.
                    lua(base + 'hub[1].clear(); rcon.print(true)')
                    step()
                    overflow = lua(base + """local cells={}; for _,e in pairs(s.find_entities_filtered{type='item-entity',area={{995,995},{1006,1006}}}) do
                      if e.stack.name=='fusion-power-cell' then cells[e.stack.quality.name]=(cells[e.stack.quality.name] or 0)+e.stack.count;
                        assert(e.to_be_deconstructed('player')) end end; rcon.print(helpers.table_to_json(cells))""")
                    assert overflow == before['expected'], overflow
                    rows[-1]['overflow'] = overflow
                    lua(base + 'for i=1,5 do hub[i].clear() end; rcon.print(true)')
                    step(300)
                    after = lua(base + """local cells={}; for _,v in ipairs(hub.get_contents()) do if v.name=='fusion-power-cell' then cells[v.quality]=v.count end end;
                      rcon.print(helpers.table_to_json({cells=cells,belt=s.count_entities_filtered{area={{999,999},{1002,1002}},type={'transport-belt','underground-belt','splitter'}}}))""")
                    rows[-1]['after_space_freed'] = after
                assert after['cells'] == before['expected'], rows[-1]
                assert after['belt'] == 0, rows[-1]
                receipt = call('where_is', dict(item='fusion-power-cell', surface=fixture_surface))
                assert any('native mining return' in line and 'rare fusion-power-cell' in line for line in receipt['deconstructed']), receipt
        # The reported 12 x 4 case, isolated so no producer or consumer changes the total.
        lua(reset + '''for j=0,11 do local e=s.create_entity{name='transport-belt',position={1000.5+j*3,1000.5},force='player'};
          for i=0,3 do assert(e.get_transport_line(1).insert_at(i*.25,{name='fusion-power-cell',count=1})) end end; rcon.print(true)''')
        result = call('deconstruct', dict(platform=platform_name, area=dict(left_top=dict(x=999,y=999),right_bottom=dict(x=1035,y=1002)),entity_names=['transport-belt']))
        assert result['changed'] == 12, result
        step()
        totals = lua(base + '''rcon.print(helpers.table_to_json({cells=hub.get_item_count('fusion-power-cell'),belts=hub.get_item_count('transport-belt')}))''')
        assert totals == dict(cells=48,belts=12), totals
        rows.append(dict(twelve_belts=totals))
        print('12 belts: all 48 fusion cells and 12 belt items returned', flush=True)
        # Native planner orders bypass dispatch, paired undergrounds must not duplicate shared-span items.
        paired = lua(reset + """local total=0; for j=0,1 do
          local e=s.create_entity{name='underground-belt',position={1000.5,1000.5+j*4},direction=defines.direction.south,type=j==0 and 'input' or 'output',force='player'};
          for i=1,e.get_max_transport_line_index() do local l=e.get_transport_line(i); if l and l.valid and l.insert_at(.25,{name='fusion-power-cell',quality='legendary',count=1}) then total=total+1 end end;
          e.order_deconstruction('player') end; rcon.print(total)""")
        step()
        paired_after = lua(base + "rcon.print(hub.get_item_count({name='fusion-power-cell',quality='legendary'}))")
        assert paired_after == paired, (paired, paired_after)
        rows.append(dict(paired_underground_cells=paired_after))
        meta = lua(reset + """local e=s.create_entity{name='transport-belt',quality='rare',position={1000.5,1000.5},force='player'};
          local l=e.get_transport_line(1); assert(l.insert_at(.25,{name='raw-fish',count=1,spoil_percent=.4}));
          assert(l.insert_at(.5,{name='firearm-magazine',count=1,ammo=3}));
          local out={}; for i=1,#l do local st=l[i]; out[st.name]=st.name=='raw-fish' and {spoil_tick=st.spoil_tick} or {ammo=st.ammo} end;
          e.order_deconstruction('player'); rcon.print(helpers.table_to_json(out))""")
        step()
        meta_after = lua(base + """local out={}; for i=1,#hub do local st=hub[i]; if st.valid_for_read and (st.name=='raw-fish' or st.name=='firearm-magazine') then
          out[st.name]=st.name=='raw-fish' and {spoil_tick=st.spoil_tick} or {ammo=st.ammo} end end;
          assert(hub.get_item_count({name='transport-belt',quality='rare'})==1); rcon.print(helpers.table_to_json(out))""")
        assert meta == meta_after, (meta,meta_after)
        rows.append(dict(stack_metadata=meta_after, rare_belt_returned=True))
        print('paired undergrounds, native planner orders, rare belt, spoil tick and partial magazine preserved', flush=True)

    finally:
        lua('game.tick_paused=true; rcon.print(true)')
        r.sock.close()
        if args.output:
            args.output.write_text(json.dumps(rows,indent=2)+'\n')


if __name__ == '__main__':
    main()
