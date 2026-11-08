#!/usr/bin/env python3
"""Opt-in inventory mining fixtures on the engineer's held private iMac copy."""
import argparse
import json
import time
import uuid
from pathlib import Path
from pog import Rcon

CASES = [
    ('fusion-reactor', None, [('fuel', 'fusion-power-cell', 28)]),
    ('nuclear-reactor', None, [('fuel', 'uranium-fuel-cell', 3), ('burnt_result', 'depleted-uranium-fuel-cell', 4)]),
    ('burner-inserter', None, [('fuel', 'coal', 7), ('hand', 'iron-plate', 1)]),
    ('assembling-machine-2', 'iron-gear-wheel', [('assembling_machine_input', 'iron-plate', 7), ('assembling_machine_output', 'iron-gear-wheel', 3), ('assembling_machine_modules', 'speed-module', 1)]),
    ('assembling-machine-3', 'iron-gear-wheel', [('assembling_machine_input', 'iron-plate', 7), ('assembling_machine_output', 'iron-gear-wheel', 3), ('assembling_machine_modules', 'speed-module', 1)]),
    ('crusher', 'carbonic-asteroid-crushing', [('assembling_machine_input', 'carbonic-asteroid-chunk', 2), ('assembling_machine_output', 'carbon', 3), ('assembling_machine_modules', 'speed-module', 1)]),
    ('chemical-plant', 'sulfur', [('assembling_machine_output', 'sulfur', 3), ('assembling_machine_modules', 'speed-module', 1)]),
    ('cryogenic-plant', 'explosives', [('assembling_machine_input', 'coal', 7), ('assembling_machine_output', 'explosives', 3), ('assembling_machine_modules', 'speed-module', 1)]),
    ('foundry', 'casting-iron', [('assembling_machine_output', 'iron-plate', 3), ('assembling_machine_modules', 'speed-module', 1)]),
    ('gun-turret', None, [('turret_ammo', 'firearm-magazine', 3)]),
    ('rocket-turret', None, [('turret_ammo', 'rocket', 3)]),
    ('railgun-turret', None, [('turret_ammo', 'railgun-ammo', 3)]),
    ('steel-chest', None, [('chest', 'raw-fish', 3), ('chest', 'firearm-magazine', 1)]),
    ('beacon', None, [('beacon_modules', 'speed-module', 1)]),
    ('beacon', None, [('beacon_modules', 'speed-module', 1), ('beacon_modules', 'efficiency-module', 1)]),
    ('steel-chest', None, [('chest', 'iron-plate', 7), ('chest', 'copper-plate', 9), ('chest', 'coal', 11)]),
    ('asteroid-collector', None, [('asteroid_collector_output', 'carbonic-asteroid-chunk', 3)]),
    *[(name, None, [('hand', 'iron-plate', 1)]) for name in ['long-handed-inserter', 'fast-inserter', 'bulk-inserter', 'stack-inserter']],
]


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--imac', action='store_true')
    ap.add_argument('--native', action='store_true', help='Measure baseline with batch463 belt-only runtime')
    ap.add_argument('--output', type=Path)
    args = ap.parse_args()
    if not args.imac:
        print('SKIP: batch464 requires --imac on a held private copy')
        return
    r = Rcon('imac.local', 27400, (Path.home()/'.config/pog/rcon-imac.pw').read_text().strip(), timeout=60)
    rows = []

    def lua(source):
        out = r.command('/silent-command ' + ' '.join(source.splitlines()))
        try:
            return json.loads(out)
        except ValueError:
            raise AssertionError(out)

    def step(n=60):
        tick = lua(f'game.ticks_to_run={n}; rcon.print(game.tick)')
        for _ in range(600):
            if lua('rcon.print(game.tick)') >= tick+n:
                return
            time.sleep(.1)
        raise AssertionError('ticks did not advance')

    name = 'B464 inventory fixture '+uuid.uuid4().hex[:8]
    surface = lua("game.tick_paused=true; local p=game.forces.player.create_space_platform{name=" + json.dumps(name) + ",planet='nauvis',starter_pack={name='space-platform-starter-pack'}}; p.apply_starter_pack(); rcon.print(helpers.table_to_json({surface=p.surface.name}))")['surface']
    rows.append(dict(platform=name, surface=surface, location='nauvis; landing pads assigned neutral on private copy', native=args.native))
    base = 'local s=game.surfaces['+json.dumps(surface)+']; local hub=s.platform.hub.get_inventory(defines.inventory.hub_main); '
    lua(base + "s.platform.paused=true; for _,pad in pairs(game.surfaces.nauvis.find_entities_filtered{type='cargo-landing-pad'}) do pad.force='neutral' end; for _,e in pairs(s.find_entities_filtered{type='inserter',area={{-8,-8},{8,8}}}) do e.active=false end; local ts={}; for x=-8,40 do for y=-8,40 do ts[#ts+1]={name='space-platform-foundation',position={x,y}} end end; s.set_tiles(ts); rcon.print(true)")
    reset = base + "for _,e in pairs(s.find_entities_filtered{area={{10,10},{40,40}}}) do e.destroy() end; hub.clear(); "
    snapshot = base + '''assert(s.platform.space_location.name=='nauvis'); assert(s.get_tile(20,20).name=='space-platform-foundation'); assert(s.count_entities_filtered{type='cargo-pod'}==0); local items={}; local ground={}; local metadata={};
      for i=1,#hub do local st=hub[i]; if st.valid_for_read and st.name~='copper-cable' then
        local k=st.name..'@'..st.quality.name; items[k]=(items[k] or 0)+st.count;
        if st.name=='raw-fish' then metadata[k]={spoil_tick=st.spoil_tick} elseif st.name=='firearm-magazine' then metadata[k]={ammo=st.ammo} end end end;
      for _,e in pairs(s.find_entities_filtered{type='item-entity'}) do local st=e.stack; local k=st.name..'@'..st.quality.name; ground[k]=(ground[k] or 0)+st.count; assert(e.to_be_deconstructed('player')) end;
      local ejected={}; for _,v in pairs(s.platform.ejected_items) do ejected[#ejected+1]=v end;
      rcon.print(helpers.table_to_json({items=items,ground=ground,metadata=metadata,ejected=ejected,exists=storage.b464_entity.valid}))'''
    try:
        for entity, recipe, inventories in CASES:
            for quality, full in [(q, False) for q in ['normal','uncommon','rare','epic','legendary']] + ([] if args.native else [('rare', True)]):
                seed = reset + "local e=s.create_entity{name="+json.dumps(entity)+",position={20.5,20.5},quality='rare',force='player'}; assert(e); e.active=false; storage.b464_entity=e; "
                if recipe:
                    seed += "e.set_recipe("+json.dumps(recipe)+","+json.dumps(quality)+"); "
                seed += 'local metadata={}; local sources={}; '
                for inv, item, count in inventories:
                    extra = ',spoil_percent=.4' if item == 'raw-fish' else ',ammo=3' if item == 'firearm-magazine' else ''
                    stack_lua = "{name="+json.dumps(item)+",quality="+json.dumps(quality)+",count="+str(count)+extra+"}"
                    if inv == 'hand':
                        seed += 'assert(e.held_stack.set_stack('+stack_lua+')); '
                    else:
                        seed += 'assert(e.get_inventory(defines.inventory.'+inv+').insert('+stack_lua+')=='+str(count)+'); '
                    seed += 'sources[#sources+1]={inventory='+json.dumps(inv)+',item='+json.dumps(item)+',count='+str(count)+'}; '
                seed += '''for i=1,e.get_max_inventory_index() do local inv=e.get_inventory(i); if inv then for j=1,#inv do local st=inv[j]; if st.valid_for_read then local k=st.name..'@'..st.quality.name;
                  if st.name=='raw-fish' then metadata[k]={spoil_tick=st.spoil_tick} elseif st.name=='firearm-magazine' then metadata[k]={ammo=st.ammo} end end end end end; '''
                if full:
                    seed += "for i=1,#hub do hub[i].set_stack{name='copper-cable',count=200} end; "
                seed += "assert(e.order_deconstruction('player')); rcon.print(helpers.table_to_json({sources=sources,metadata=metadata}))"
                before = lua(seed)
                step()
                after = lua(snapshot)
                expected = {entity+'@rare': 1}
                for _, item, count in inventories:
                    expected[item+'@'+quality] = expected.get(item+'@'+quality, 0)+count
                row = dict(entity=entity, quality=quality, full=full, before=before, expected=expected, after=after)
                rows.append(row)
                if full:
                    assert after['exists'] and not after['items'] and not after['ground'], row
                    lua(base + 'hub[1].clear(); rcon.print(true)')
                    step()
                    overflow = lua(snapshot)
                    row['overflow'] = overflow
                    assert not overflow['exists'], row
                    total = dict(overflow['items'])
                    for key, n in overflow['ground'].items():
                        total[key] = total.get(key, 0)+n
                    assert total == expected and not overflow['ejected'], row
                    lua(base + "for i=1,20 do if hub[i].valid_for_read and hub[i].name=='copper-cable' then hub[i].clear() end end; rcon.print(true)")
                    step(180)
                    after = lua(snapshot)
                    row['after_space_freed'] = after
                if args.native:
                    assert not after['exists'] and not after['ground'] and not after['ejected'], row
                else:
                    assert after['items'] == expected and not after['exists'] and not after['ground'] and not after['ejected'], row
                    assert after['metadata'] == before['metadata'], row
                    req = dict(id='b464-'+uuid.uuid4().hex, bot='sol', action='where_is', args=dict(item=inventories[0][1], surface=surface))
                    receipt = lua('rcon.print(remote.call("agent_harness","dispatch",'+json.dumps(json.dumps(req))+'))')
                    assert receipt['ok'], receipt
                    lines = receipt['result']['deconstructed']
                    assert any(line.startswith(entity+' (') and all(str(count)+' '+quality+' '+item in line for _,item,count in inventories) for line in lines), lines
                print(json.dumps(row), flush=True)
    finally:
        lua('game.tick_paused=true; rcon.print(true)')
        r.sock.close()
        if args.output:
            args.output.write_text(json.dumps(rows, indent=2)+'\n')


if __name__ == '__main__':
    main()
