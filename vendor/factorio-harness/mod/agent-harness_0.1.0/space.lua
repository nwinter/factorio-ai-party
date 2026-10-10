-- Space Age logistics through the same GUIs a player has: logistic request
-- slots (character, chests, landing pads, platform hubs), the space platform
-- list (create, schedule, pause), and the rocket silo launch button. Platforms
-- are always shown in remote view, so none of this needs the character there.
return function(api)
  local M={}
  local function invert(t) local out={} for k,v in pairs(t or {}) do out[v]=k end return out end
  local platform_states=invert(defines.space_platform_state)
  local silo_states=invert(defines.rocket_silo_status)
  local function item_name(v)
    assert(type(v)=='string' and prototypes.item[v],'unknown item: '..tostring(v))
    return v
  end
  -- A force platform by name (or index).
  function M.platform(p,name)
    assert(type(name)=='string' or type(name)=='number','platform requires a platform name')
    for _,pl in pairs(p.force.platforms) do
      if pl.valid and (pl.name==name or pl.index==name) then return pl end
    end
    local names={}
    for _,pl in pairs(p.force.platforms) do if pl.valid then names[#names+1]=pl.name end end
    error('no platform named '..tostring(name)..(#names>0 and '; platforms: '..table.concat(names,', ') or '; create one with platform_create'),0)
  end
  local function location(pl)
    if pl.space_location then return pl.space_location.name end
    local c=pl.space_connection
    if c then return string.format('%s->%s %d%%',c.from.name,c.to.name,math.floor((pl.distance or 0)*100+0.5)) end
  end
  -- Requests ------------------------------------------------------------------
  local function sections_of(p,a)
    if a.target=='character' or (a.target==nil and a.position==nil and a.platform==nil) then
      local secs=p.character and p.character.get_logistic_sections()
      assert(secs,'the character has no logistic requests yet (research logistic robotics)')
      return 'character',secs
    end
    if a.platform~=nil then
      local pl=M.platform(p,a.platform)
      assert(pl.hub and pl.hub.valid,'platform '..pl.name..' has no hub yet (waiting for its starter pack)')
      return 'platform '..pl.name,pl.hub.get_logistic_sections()
    end
    local e=api.remote_entity(p,a)
    local secs=e.get_logistic_sections and e.get_logistic_sections()
    assert(secs,e.name..' has no logistic requests')
    return e.name..' at '..string.format('(%g,%g)',e.position.x,e.position.y),secs
  end
  local function filter_text(f,hub)
    local v=f.value
    if not v then return nil end
    local name=type(v)=='table' and v.name or v
    local quality=type(v)=='table' and v.quality or nil
    local text=name..(quality and quality~='normal' and '@'..quality or '')
    if f.max and f.max==f.min then return text..'='..f.min end
    text=text..' '..(f.min or 0)..'..'..(f.max and tostring(f.max) or 'inf')
    local from=hub and f.import_from and (type(f.import_from)=='string' and f.import_from or f.import_from.name)
    return from and text..' from '..from or text
  end
  local function list_sections(secs,hub)
    local out={}
    for i=1,secs.sections_count do
      local sec=secs.get_section(i)
      local rows={}
      for _,f in ipairs(sec.filters or {}) do local t=filter_text(f,hub); if t then rows[#rows+1]=t end end
      out[#out+1]={index=i,group=sec.group~='' and sec.group or nil,active=sec.active==false and false or nil,
        controlled=not sec.is_manual or nil,requests=rows}
    end
    return out
  end
  local function slot_of(sec,name,quality)
    local free
    for i=1,sec.filters_count+1 do
      local f=sec.get_slot(i)
      local v=f and f.value
      if v then
        local n,q=type(v)=='table' and v.name or v,type(v)=='table' and v.quality or 'normal'
        if n==name and (q or 'normal')==quality then return i,true end
      elseif not free then free=i end
    end
    return free or sec.filters_count+1,false
  end
  function M.requests(p,a)
    local label,secs=sections_of(p,a)
    local changing=a.set~=nil or a.clear~=nil or a.clear_all~=nil
    if changing then
      local sec
      if a.section~=nil then
        sec=secs.get_section(api.integer(a.section,1,1,100,'section'))
        assert(sec,'section '..a.section..' does not exist (sections_count '..secs.sections_count..')')
      else
        for i=1,secs.sections_count do local s=secs.get_section(i); if s.is_manual and s.group=='' then sec=s; break end end
        sec=sec or secs.add_section()
        assert(sec,'no manual logistic section could be added')
      end
      assert(sec.is_manual,'section '..sec.index..' is controlled by the game')
      if a.clear_all then sec.filters={} end
      for _,name in ipairs(a.clear or {}) do
        local i,found=slot_of(sec,item_name(name),'normal')
        if found then sec.clear_slot(i) end
      end
      assert(a.set==nil or (type(a.set)=='table' and #a.set<=100),'set requires an array of {item,min,max?,quality?,from?}')
      for _,r in ipairs(a.set or {}) do
        assert(type(r)=='table','each request is {item,min,max?,quality?,from?}')
        local name,quality=item_name(r.item),r.quality or 'normal'
        local min=api.integer(r.min,0,0,1000000000,'min')
        assert(r.max==nil or (type(r.max)=='number' and r.max>=min),'max must be at least min')
        local i=slot_of(sec,name,quality)
        sec.set_slot(i,{value={type='item',name=name,quality=quality,comparator='='},min=min,max=r.max,import_from=r.from})
      end
    end
    return {target=label,sections=list_sections(secs,a.platform~=nil)}
  end
  -- Platforms -----------------------------------------------------------------
  local function top_items(inv,limit)
    local list=inv and inv.get_contents() or {}
    table.sort(list,function(x,y) return x.count>y.count end)
    if #list==0 then return nil end
    local out={}
    for i=1,math.min(#list,limit) do local s=list[i]; out[i]=s.name..(s.quality and s.quality~='normal' and '@'..s.quality or '')..'*'..s.count end
    return #list>limit and table.concat(out,' ')..string.format(' +%d more',#list-limit) or table.concat(out,' ')
  end
  local function schedule_text(pl)
    local sch=pl.schedule
    if not (sch and sch.records and #sch.records>0) then return nil end
    local parts={}
    for i,r in ipairs(sch.records) do
      local waits={}
      for _,w in ipairs(r.wait_conditions or {}) do waits[#waits+1]=w.type..(w.ticks and ' '..math.floor(w.ticks/60)..'s' or '') end
      parts[i]=(i==sch.current and '>' or '')..(r.station or '?')..(#waits>0 and ' ('..table.concat(waits,', ')..')' or '')
    end
    return table.concat(parts,' | ')
  end
  function M.platforms(p,a)
    local out={platforms={}}
    for _,pl in pairs(p.force.platforms) do
      if pl.valid and (a.platform==nil or pl.name==a.platform) then
        local row={name=pl.name,state=platform_states[pl.state],at=location(pl),paused=pl.paused or nil,
          schedule=schedule_text(pl),deleting=pl.scheduled_for_deletion and pl.scheduled_for_deletion>0 or nil,
          weight=pl.weight and math.floor(pl.weight/1000) or nil}
        local hub=pl.hub
        if hub and hub.valid then
          row.hub=hub.position
          row.hub_items=top_items(hub.get_inventory(defines.inventory.hub_main),a.platform and 64 or 12)
          local secs=hub.get_logistic_sections()
          if secs then
            local req={}
            for _,s in ipairs(list_sections(secs,true)) do for _,r in ipairs(s.requests) do req[#req+1]=r end end
            row.requests=#req>0 and req or nil
          end
          row.leave_ok=pl.can_leave_current_location and pl.can_leave_current_location() or nil
        end
        out.platforms[#out.platforms+1]=row
      end
    end
    -- Silos on the character's surface: what the launch button would send.
    local silos={}
    for _,e in pairs(p.surface.find_entities_filtered{type='rocket-silo',force=p.force,limit=16}) do
      local cargo=e.get_inventory(defines.inventory.rocket_silo_rocket)
      silos[#silos+1]={position=e.position,status=silo_states[e.rocket_silo_status],
        parts=e.rocket_parts..'/'..e.prototype.rocket_parts_required,cargo=cargo and top_items(cargo,8) or nil,
        auto_requests=e.use_transitional_requests or nil}
    end
    out.silos=#silos>0 and silos or nil
    out.planet=p.surface.planet and p.surface.planet.name or nil
    return out
  end
  function M.platform_create(p,a)
    local pack=a.starter_pack or 'space-platform-starter-pack'
    assert(prototypes.item[pack],'unknown starter pack item '..tostring(pack))
    local recipe=p.force.recipes[pack]
    assert(not recipe or recipe.enabled,pack..' is not unlocked yet (research space-platform)')
    local planet=a.planet or (p.surface.planet and p.surface.planet.name)
    assert(planet,'planet is required off a planet surface')
    assert(a.name==nil or (type(a.name)=='string' and #a.name>=1 and #a.name<=64),'name must be 1..64 characters')
    local pl=p.force.create_space_platform{name=a.name,planet=planet,starter_pack=pack}
    assert(pl,'the game refused to create a platform')
    return {name=pl.name,state=platform_states[pl.state],planet=planet,
      next='a rocket silo on '..planet..' with a '..pack..' in its rocket cargo (transfer item='..pack..', inventory rocket_silo_rocket) launches it on its own once the rocket is ready'}
  end
  -- Records: {station=planet, wait={{type,ticks?,compare?}}}; the game's
  -- wait types include all_requests_satisfied, any_request_zero,
  -- any_request_not_satisfied, time, inactivity, item_count, circuit.
  function M.platform_schedule(p,a)
    local pl=M.platform(p,a.platform)
    if a.stops~=nil then
      assert(type(a.stops)=='table' and #a.stops<=32,'stops requires 0..32 {station,wait?}')
      local records={}
      for i,stop in ipairs(a.stops) do
        assert(type(stop)=='table' and type(stop.station)=='string' and prototypes.space_location[stop.station],'stop '..i..': station must be a planet or space location name')
        local waits={}
        for j,w in ipairs(stop.wait or {}) do
          assert(type(w)=='table' and type(w.type)=='string','stop '..i..' wait '..j..' needs a type')
          waits[j]={type=w.type,ticks=w.ticks,compare_type=j>1 and (w.compare or 'and') or nil,condition=w.condition}
        end
        records[i]={station=stop.station,wait_conditions=#waits>0 and waits or nil}
      end
      pl.schedule=#records>0 and {current=api.integer(a.current,1,1,math.max(1,#records),'current'),records=records} or nil
    end
    if a.paused~=nil then assert(type(a.paused)=='boolean','paused must be boolean'); pl.paused=a.paused end
    return {name=pl.name,state=platform_states[pl.state],at=location(pl),paused=pl.paused or nil,schedule=schedule_text(pl)}
  end
  function M.launch(p,a)
    local silo=api.remote_entity(p,{position=a.position,name=a.name,unit_number=a.unit_number})
    assert(silo.type=='rocket-silo','not a rocket silo')
    -- The silo GUI checkbox: launch on its own for platforms' requests.
    if a.auto_requests~=nil then
      assert(type(a.auto_requests)=='boolean','auto_requests must be boolean')
      silo.use_transitional_requests=a.auto_requests
      if a.platform==nil and a.orbit==nil then return {auto_requests=silo.use_transitional_requests} end
    end
    assert(silo.rocket_silo_status==defines.rocket_silo_status.rocket_ready,'rocket is not ready: '..tostring(silo_states[silo.rocket_silo_status])..', parts '..silo.rocket_parts..'/'..silo.prototype.rocket_parts_required)
    local cargo=top_items(silo.get_inventory(defines.inventory.rocket_silo_rocket),8)
    -- Riding: the character climbs into the rocket, as a player does
    -- standing at the silo, and arrives in the platform hub.
    local rider
    if a.ride then
      assert(a.ride==true,'ride must be true')
      assert(a.platform~=nil,'ride needs platform=<name>')
      assert(p.can_reach_entity(silo),'stand within reach of the silo to board its rocket')
      rider=p.character
    end
    local destination,to
    if a.platform~=nil then
      local pl=M.platform(p,a.platform)
      local here=p.surface.planet and p.surface.planet.name
      assert(pl.surface and pl.hub and pl.hub.valid,'platform '..pl.name..' has no hub yet')
      assert(pl.space_location and pl.space_location.name==here,'platform '..pl.name..' is not in orbit of '..tostring(here)..' (at '..tostring(location(pl))..')')
      destination={type=defines.cargo_destination.surface,surface=pl.surface}; to='platform '..pl.name
    else
      assert(a.orbit==true,'give platform=<name>, or orbit=true to launch into orbit with no platform (cargo is lost unless it has launch products)')
      destination={type=defines.cargo_destination.orbit}; to='orbit'
    end
    if rider then api.stop(p) end
    assert(silo.launch_rocket(destination,rider),'the game refused the launch')
    return {launched=true,to=to,cargo=cargo or 'empty',riding=rider and 'the character rides along (~40 s); actions fail until it sits in the hub: poll status (platform, riding)' or nil}
  end
  -- The hub's "drop to planet": the character descends in a cargo pod to the
  -- planet the platform is stopped at (a landing pad if there is one).
  function M.land(p,a)
    local pl=p.surface.platform
    assert(pl and pl.force==p.force,'the character is not on a space platform')
    assert(pl.space_location and pl.space_location.type=='planet','platform '..pl.name..' is not stopped at a planet (at '..tostring(location(pl))..')')
    api.stop(p)
    assert(api.real(p).land_on_planet(),'the game refused the landing')
    return {landing=pl.space_location.name,note='the cargo pod takes ~20 s; actions fail until the character stands on the planet: poll status'}
  end
  M.schema={
    requests={target='character (default when no position/platform)',position='{x,y} of a requester/buffer chest, landing pad or other requester in a visible chunk (remote view; no reach needed)',platform='platform name: its hub requests (what the planet in orbit sends up)',
      set='array of {item,min,max?,quality?,from? (planet to import from, platform hubs)}; replaces that item\'s slot',clear='array of item names to remove',clear_all='boolean: empty the section first',section='1-based section index (default the first manual ungrouped section, created if none)',
      returns='target, sections [{index, group, controlled (set by the game, not editable), requests ["item min..max from planet"]}]; call with no set/clear to just read'},
    platforms={platform='optional name: only this one, with its full hub inventory',returns='platforms [{name, state, at (location or from->to %), schedule, hub, hub_items, requests, leave_ok}], silos on this surface {position, status, parts, cargo}, planet'},
    platform_create={name='optional platform name',planet='default the character\'s planet',starter_pack='default space-platform-starter-pack',note='like the platform GUI: the platform waits for its starter pack; a silo holding one in its rocket cargo launches it on its own'},
    platform_schedule={platform='name',stops='array of {station=planet, wait=[{type=all_requests_satisfied|any_request_zero|time|inactivity|..., ticks?, compare=and|or}]}; [] clears',current='1-based stop to head for (default 1)',paused='boolean: pause/unpause thrust and the schedule'},
    land={note='from a platform stopped at a planet: drop to that planet in a cargo pod (to a landing pad if any)',returns='landing'},
    launch={position='rocket silo {x,y} in a visible chunk',ride='true: the character boards the rocket (stand within reach of the silo) and arrives in the platform hub; needs platform',platform='send the rocket cargo to this platform in orbit of this planet',orbit='true: launch with no platform (cargo lost unless it has launch products)',auto_requests='boolean: the silo GUI setting to fill and launch rockets on its own for platforms\' requests in orbit (alone: only sets it)',returns='launched, to, cargo'},
  }
  return M
end
