local function snapshot(c)
  local f=game.forces[c.force]
  local inv=c.lab.get_inventory(defines.inventory.lab_input)
  local packs={}
  for i=1,#inv do
    local s=inv[i]
    if s.valid_for_read then packs[s.name]={count=s.count,durability=s.durability,spoil_percent=s.spoil_percent} end
  end
  return {tick=game.tick,elapsed=game.tick-c.start_tick,spoil=c.spoil,quality=c.quality,initial_durability=c.initial_durability,progress=f.research_progress,units=f.research_progress*f.current_research.research_unit_count,packs=packs,energy=c.lab.energy,status=c.lab.status,speed=f.laboratory_speed_modifier,productivity=f.laboratory_productivity_bonus}
end
remote.add_interface('science_value_probe',{
  setup=function(options)
    options=options or {}
    local surface=game.surfaces['science-value-probe'] or game.create_surface('science-value-probe',{width=320,height=96,autoplace_controls={}})
    surface.request_to_generate_chunks({0,0},5);surface.force_generate_chunk_requests()
    for _,e in pairs(surface.find_entities()) do if e.valid then e.destroy() end end
    local tiles={};for x=-150,150 do for y=-40,40 do tiles[#tiles+1]={name='lab-dark-1',position={x,y}} end end;surface.set_tiles(tiles)
    storage.cases={}
    for i,p in ipairs(options.levels or {0,.25,.5,.75,.9}) do
      local f=game.forces['science-value-'..i] or game.create_force('science-value-'..i)
      local tech=f.technologies['stack-inserter']
      local function unlock(t) for _,v in pairs(t.prerequisites) do if not v.researched then unlock(v);v.researched=true end end end
      unlock(tech)
      f.laboratory_speed_modifier=99;f.laboratory_productivity_bonus=0;f.research_queue={'stack-inserter'};f.research_progress=0
      local x=(i-3)*40
      local lab=surface.create_entity{name='lab',position={x,0},force=f}
      surface.create_entity{name='electric-energy-interface',position={x-6,0},force=f}
      surface.create_entity{name='medium-electric-pole',position={x-3,0},force=f}
      local inv=lab.get_inventory(defines.inventory.lab_input)
      for _,ingredient in pairs(tech.research_unit_ingredients) do inv.insert{name=ingredient.name,count=ingredient.name=='agricultural-science-pack' and (options.count or 20) or 200,quality=ingredient.name=='agricultural-science-pack' and (options.quality or 'normal') or 'normal'} end
      local agri=inv.find_item_stack{name='agricultural-science-pack',quality=options.quality or 'normal'};agri.spoil_percent=p;if options.durability then agri.durability=options.durability end
      storage.cases[i]={force=f.name,lab=lab,spoil=p,start_tick=game.tick,natural=options.natural,quality=options.quality or 'normal',initial_durability=agri.durability}
    end
    return {tick=game.tick}
  end,
  results=function() local out={};for i,c in ipairs(storage.cases or {}) do out[i]=c.result or snapshot(c) end;return out end
})
script.on_event(defines.events.on_tick,function()
  for _,c in ipairs(storage.cases or {}) do
    if not c.result then
      local inv=c.lab.get_inventory(defines.inventory.lab_input)
      local agri=inv.find_item_stack{name='agricultural-science-pack',quality=c.quality}
      if not agri or game.tick-c.start_tick>=7200 then c.result=snapshot(c);c.lab.active=false
      elseif not c.natural then agri.spoil_percent=c.spoil end
    end
  end
end)
