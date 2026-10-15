local factory=require('__agent-harness__/drill_sites')
remote.add_interface('drill_sites_probe',{
  setup=function(options)
    local s=game.surfaces['drill-sites-probe'] or game.create_surface('drill-sites-probe',{width=128,height=128,autoplace_controls={}})
    s.request_to_generate_chunks({0,0},3);s.force_generate_chunk_requests()
    for _,e in pairs(s.find_entities()) do if e.valid then e.destroy() end end
    local tiles={};for x=-63,63 do for y=-63,63 do tiles[#tiles+1]={name='lab-dark-1',position={x,y}} end end;s.set_tiles(tiles)
    local f=game.forces['drill-sites-probe'] or game.create_force('drill-sites-probe')
    local d=s.create_entity{name=options.drill,position={.5,.5},direction=defines.direction.east,force=f,quality=options.quality or 'normal'}
    if d.burner then d.get_fuel_inventory().insert{name='coal',count=50} end
    s.create_entity{name='electric-energy-interface',position={-8,-8},force=f}
    s.create_entity{name='substation',position={-5,-5},force=f}
    local radar=s.create_entity{name='radar',position={-4,4},force=f};radar.energy=1000000
    for x=8,28 do for y=-12,12 do s.create_entity{name='coal',amount=100+x+y,position={x+.5,y+.5}} end end
    -- A solid building and water exclude otherwise resource-bearing centres.
    s.create_entity{name='steel-chest',position={10.5,.5},force=f}
    s.set_tiles{{name='water',position={x=12,y=1}}}
    f.chart(s,{{-64,-64},{64,64}})
    storage.drill=d;storage.memory={push_drills={[f.name]={[d.unit_number]='coal'}}}
    return {tick=game.tick,drill=d.name,status=d.status,radius=d.prototype.mining_drill_radius,position=d.position}
  end,
  run=function()
    local e=storage.drill
    -- A headless force with no players leaves chart requests pending. Visibility
    -- is a test fixture here; engine resources, quality, sizes and collision
    -- checks are real. The regular suite separately checks fog exclusion.
    local force={name=e.force.name,is_chunk_visible=function() return true end}
    local surface=setmetatable({can_place_entity=function(a) a.force=e.force;return e.surface.can_place_entity(a) end},{__index=e.surface})
    local drill=setmetatable({force=force},{__index=e})
    local D=factory{state=function() return storage.memory end,entity=function() return drill end,
      integer=function(v,d) return v or d end}
    local p={force=force,surface=surface}
    local profiler=game.create_profiler()
    local out=D.read(p,{position=e.position,radius=24,limit=8})
    profiler.stop()
    rcon.print{'','drill_sites: ',profiler}
    assert(#out.sites>0,helpers.table_to_json(out))
    for _,c in ipairs(out.sites) do
      assert(e.surface.can_place_entity{name=e.name,position=c.position,direction=e.direction,quality=e.quality,force=e.force,build_check_type=defines.build_check_type.manual})
      local radius=e.prototype.mining_drill_radius
      local n,total=0,0
      for _,o in pairs(e.surface.find_entities_filtered{type='resource',name='coal',area={{c.position.x-radius,c.position.y-radius},{c.position.x+radius,c.position.y+radius}}}) do
        n=n+1;total=total+o.amount
      end
      assert(c.tiles==n and c.amount==total,'mining area totals differ from the engine')
    end
    return {view=out,visibility='test fixture (no connected players)',status=e.status,version=script.active_mods.base}
  end
})
