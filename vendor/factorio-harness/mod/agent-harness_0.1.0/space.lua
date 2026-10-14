-- Space Age logistics through the same GUIs a player has: logistic request
-- slots (character, chests, landing pads, platform hubs), the space platform
-- list (create, schedule, pause), and the rocket silo launch button. Platforms
-- are always shown in remote view, so none of this needs the character there.
return function(api)
  local M={}
  local function invert(t) local out={} for k,v in pairs(t or {}) do out[v]=k end return out end
  -- Riding a rocket and dropping from the hub are LuaPlayer moves; a bot (no
  -- player to sit in the hub) travels through bots.lua instead: same payload
  -- rule, the rocket's and the hub's own cargo pods, its body made again on
  -- landing (api.bot: the bot record behind a bot proxy, nil for players).
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
    -- By remote view on another surface (surface=, Astra 02:20): the reply names it.
    local remote=type(p)=='table' and rawget(p,'__remote')
    return e.name..' at '..string.format('(%g,%g)',e.position.x,e.position.y)..(remote and ' on '..e.surface.name or ''),secs,e
  end
  -- One request as the GUI shows it: name, min..max (or =n), and on a hub
  -- the planet it imports from (exact requests too: Astra's `calcite=500`
  -- hid `from vulcanus`, 02:00).
  local function filter_text(f,hub)
    local v=f.value
    if not v then return nil end
    local name=type(v)=='table' and v.name or v
    local quality=type(v)=='table' and v.quality or nil
    local text=name..(quality and quality~='normal' and '@'..quality or '')
    if f.max and f.max==f.min then text=text..'='..f.min
    else text=text..' '..(f.min or 0)..'..'..(f.max and tostring(f.max) or 'inf') end
    local from=hub and f.import_from and (type(f.import_from)=='string' and f.import_from or f.import_from.name)
    return from and text..' from '..from or text
  end
  local function list_sections(secs,hub)
    local out={}
    for i=1,secs.sections_count do
      local sec=secs.get_section(i)
      local rows={}
      for _,f in ipairs(sec.filters or {}) do local t=filter_text(f,hub); if t then rows[#rows+1]=t end end
      -- A section switched off requests nothing (the GUI's checkbox). Said
      -- as off=true: false values drop out of the compact reply.
      out[#out+1]={index=i,group=sec.group~='' and sec.group or nil,off=sec.active==false or nil,
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
    local label,secs,chest=sections_of(p,a)
    -- A requester chest's "request from buffer chests" switch.
    local buffers
    if a.from_buffers~=nil then
      assert(type(a.from_buffers)=='boolean','from_buffers must be boolean')
      assert(chest and chest.type=='logistic-container','from_buffers is a requester chest setting')
      local ok,err=pcall(function() chest.request_from_buffers=a.from_buffers end)
      assert(ok,'the game refused from_buffers: '..tostring(err))
    end
    if chest then pcall(function() buffers=chest.request_from_buffers end) end
    assert(a.active==nil or type(a.active)=='boolean','active must be true or false: switch the section on or off')
    local changing=a.set~=nil or a.clear~=nil or a.clear_all~=nil or a.active~=nil
    local touched
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
      touched=sec
      if a.active~=nil then sec.active=a.active end
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
    local out={target=label,sections=list_sections(secs,a.platform~=nil or (chest and chest.type=='space-platform-hub')),from_buffers=buffers}
    -- Requests set into a section that is off are not made: say so.
    local off={}
    for _,row in ipairs(out.sections) do if row.off and #row.requests>0 then off[#off+1]=row.index end end
    if #off>0 then
      out.note=string.format('section%s %s %s switched off: %s requests are not made (requests {section, active: true} switches one on)',
        #off>1 and 's' or '',table.concat(off,', '),#off>1 and 'are' or 'is',#off>1 and 'their' or 'its')
    end
    out.changed_section=touched and touched.index or nil
    return out
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
  -- One platform in full: what remote view shows of its flight, damage,
  -- asteroid chunks in reach, thruster tanks and unbuilt ghosts. Each read is
  -- guarded so a missing field never hides the rest.
  local function try(fn) local ok,v=pcall(fn); if ok then return v end end
  -- Flight as the hub's GUI and the space map show it: speed in km/s (the
  -- game's speed is km per tick), the leg flown now (a space connection: its
  -- length, the end headed for, the km left to it), minutes to that end at the
  -- current speed, and the schedule's next stop. A connection is measured from
  -- its `from` end whichever way it is flown: the end headed for is the
  -- schedule's stop when it is one of the two ends, else the end the platform
  -- did not come from (last visited).
  function M.flight(pl)
    local out={}
    local speed=try(function() return pl.speed end)
    if type(speed)=='number' then out.speed_kms=math.floor(speed*600+0.5)/10 end
    local sch=try(function() return pl.schedule end)
    local records=sch and sch.records or {}
    local cur=sch and sch.current or 1
    local stop=records[cur] and records[cur].station
    local here=try(function() return pl.space_location.name end)
    -- Waiting at the current stop: the next one is the stop after it.
    if here and stop==here and #records>0 then out.next_stop=records[cur%#records+1].station else out.next_stop=stop end
    local c=try(function() return pl.space_connection end)
    if c then
      local from,to=c.from.name,c.to.name
      local d=try(function() return pl.distance end) or 0
      local last=try(function() return pl.last_visited_space_location.name end)
      local back
      if stop==from or stop==to then back=stop==from else back=last==to end
      local left=(back and d or 1-d)*c.length
      -- The leg in the way it is flown (at keeps the connection's own order).
      out.leg=back and to..'->'..from or from..'->'..to
      out.heading_to=back and from or to
      out.leg_km=c.length
      out.leg_left_km=math.floor(left+0.5)
      if type(speed)=='number' and speed>0 then out.eta_min=math.floor(left/(speed*60)/6+0.5)/10 end
    end
    return next(out) and out or nil
  end
  -- The game repairs a platform's entities itself, one at a time, with repair
  -- packs from the hub (no robots in space; remote view cannot repair).
  M.REPAIR_NOTE='the game repairs platform entities itself with repair packs from the hub, one entity at a time (no robots in space, and remote view cannot repair); put repair packs in the hub (hub requests or a rocket) and read platforms {platform} for damaged and repair_packs'
  -- What is damaged (most damaged first) and the repair packs in the hub.
  function M.repair_view(pl)
    local out={}
    local hub=pl.hub
    local inv=hub and hub.valid and try(function() return hub.get_inventory(defines.inventory.hub_main) end)
    local packs={}
    for _,st in ipairs(inv and try(function() return inv.get_contents() end) or {}) do
      if try(function() return prototypes.item[st.name].type end)=='repair-tool' then packs[#packs+1]=st.name..'*'..st.count end
    end
    out.repair_packs=#packs>0 and table.concat(packs,' ') or 'none'
    local list={}
    try(function()
      for _,e in ipairs(pl.surface.find_entities_filtered{force=pl.force,limit=5000}) do
        local h,m=e.health,e.max_health
        if h and m and m>0 and h<m then list[#list+1]={e=e,h=h,m=m} end
      end
    end)
    table.sort(list,function(x,y) return x.h/x.m<y.h/y.m end)
    local rows={}
    for i=1,math.min(#list,10) do
      local d=list[i]
      rows[i]=string.format('%s (%g,%g) %d/%d',d.e.name,d.e.position.x,d.e.position.y,math.floor(d.h),math.floor(d.m))
    end
    out.damaged=#rows>0 and rows or nil
    out.damaged_count=#list>10 and #list or nil
    return out
  end
  local function detail(pl,row)
    -- The game's own value, km per tick (the stream tools read it; speed_kms is on every row).
    row.speed=try(function() return pl.speed and math.floor(pl.speed*1000+0.5)/1000 end)
    local damaged=try(function() return #pl.damaged_tiles end)
    row.damaged_tiles=damaged and damaged>0 and damaged or nil
    local chunks=try(function() return pl.find_asteroid_chunks_filtered{} end)
    if chunks and #chunks>0 then
      local by={}
      for _,c in ipairs(chunks) do local n=type(c.name)=='string' and c.name or (c.name and c.name.name) or '?'; by[n]=(by[n] or 0)+1 end
      local parts={}
      for n,count in pairs(by) do parts[#parts+1]=n..'*'..count end
      table.sort(parts)
      row.asteroid_chunks=table.concat(parts,' ')
    end
    local s=try(function() return pl.surface end)
    if s then
      local thrusters=try(function() return s.find_entities_filtered{type='thruster'} end) or {}
      if #thrusters>0 then
        local low=1
        for _,t in ipairs(thrusters) do
          for i=1,2 do
            local f=try(function() return t.fluidbox[i] end)
            -- the thruster's own tank, not a connected segment's capacity
            local cap=try(function() return t.prototype.fluidbox_prototypes[i].volume end) or try(function() return t.fluidbox.get_capacity(i) end)
            low=math.min(low,f and cap and cap>0 and f.amount/cap or 0)
          end
        end
        row.thrusters=string.format('%d, lowest tank %d%%',#thrusters,math.floor(low*100))
      end
      local ghosts=try(function() return s.count_entities_filtered{type={'entity-ghost','tile-ghost'}} end)
      row.unbuilt_ghosts=ghosts and ghosts>0 and ghosts or nil
      -- Inserters taking from the hub with nothing to drop into: they put
      -- the hub's items on the tile at their drop point (empty space: thrown
      -- overboard).
      local hub=pl.hub
      local drains={}
      for _,i in ipairs(try(function() return s.find_entities_filtered{type='inserter',limit=500} end) or {}) do
        if hub and try(function() return i.pickup_target==hub and not i.drop_target end) then
          local d=i.drop_position
          local tile=try(function() return s.get_tile(math.floor(d.x),math.floor(d.y)).name end) or '?'
          drains[#drains+1]=string.format('(%g,%g) drops onto %s',i.position.x,i.position.y,tile)
        end
      end
      row.hub_inserters_without_target=#drains>0 and drains or nil
      -- The game's item statistics for this platform's surface, last 10 minutes.
      local stats=try(function() return pl.force.get_item_production_statistics(s) end)
      if stats then
        for _,c in ipairs({{'output','consumed_10min'},{'input','produced_10min'}}) do
          local list={}
          for name in pairs(try(function() return c[1]=='output' and stats.output_counts or stats.input_counts end) or {}) do
            local n=try(function() return stats.get_flow_count{name=name,category=c[1],precision_index=defines.flow_precision_index.ten_minutes,count=true} end)
            if n and n>=0.5 then list[#list+1]={name=name,n=math.floor(n+0.5)} end
          end
          table.sort(list,function(x,y) if x.n~=y.n then return x.n>y.n end return x.name<y.name end)
          local parts={}
          for i=1,math.min(12,#list) do parts[i]=list[i].name..'*'..list[i].n end
          row[c[2]]=#parts>0 and table.concat(parts,' ')..(#list>12 and string.format(' +%d more',#list-12) or '') or nil
        end
      end
    end
    -- Items thrown overboard, while the game still tracks them.
    local ejected=try(function() return pl.ejected_items end)
    if ejected and #ejected>0 then
      local by,names={},{}
      for _,e in ipairs(ejected) do
        local n=try(function() local it=e.item; local nm=it.name; return type(nm)=='string' and nm or nm.name end) or '?'
        if not by[n] then by[n]=0; names[#names+1]=n end
        by[n]=by[n]+1
      end
      table.sort(names)
      local parts={}
      for i,n in ipairs(names) do parts[i]=n..'*'..by[n] end
      row.thrown_overboard=table.concat(parts,' ')
    end
  end
  -- Hub storage use: free slots of all.
  function M.hub_slots(hub)
    local inv=try(function() return hub.get_inventory(defines.inventory.hub_main) end)
    local free=inv and try(function() return inv.count_empty_stacks() end)
    return free and string.format('%d of %d free',free,#inv) or nil
  end
  -- Why the hub cannot build or deconstruct now: no free slot for what
  -- deconstruction removes, ghosts whose items the hub lacks (one scan of the
  -- platform's ghosts, at most 500, when asked), tile ghosts the foundation
  -- rules hold back (tilecheck.lua).
  local tiles=require('tilecheck')()
  function M.blockers(pl)
    local hub=pl.hub
    if not (hub and hub.valid) then return nil end
    local inv=hub.get_inventory(defines.inventory.hub_main)
    local s=pl.surface
    local out={}
    local free=try(function() return inv.count_empty_stacks() end)
    if free==0 then
      local marked=try(function() return s.count_entities_filtered{to_be_deconstructed=true} end) or 0
      out[#out+1]=string.format('hub full: 0 of %d slots free',#inv)..(marked>0 and string.format('; %d marked for deconstruction wait for room (removed entities and their contents go to the hub)',marked) or '')
    end
    -- Items by name and the ghost's quality: the hub builds a ghost only from
    -- items of that quality.
    local need,order={},{}
    for _,g in ipairs(try(function() return s.find_entities_filtered{type={'entity-ghost','tile-ghost'},limit=500} end) or {}) do
      local it=try(function() return g.ghost_prototype.items_to_place_this[1] end)
      local n=it and (type(it.name)=='string' and it.name or it.name and it.name.name)
      if n then
        local q=tiles.quality_of(g)
        local k=n..'@'..q
        if not need[k] then need[k]={name=n,quality=q,count=0}; order[#order+1]=k end
        need[k].count=need[k].count+(it.count or 1)
      end
    end
    local missing={}
    for _,k in ipairs(order) do
      local w=need[k]
      local have=inv.get_item_count{name=w.name,quality=w.quality}
      local label=w.name..(w.quality~='normal' and '@'..w.quality or '')
      if have<w.count then missing[#missing+1]=string.format('%s (ghosts need %d, hub has %d)',label,w.count,have) end
    end
    if #missing>0 then out[#out+1]='ghosts wait for items the hub lacks: '..table.concat(missing,', ') end
    -- Tile ghosts the foundation rules hold back.
    for _,line in ipairs(try(function() return tiles.stalled(pl) end) or {}) do out[#out+1]=line end
    return #out>0 and out or nil
  end
  function M.platforms(p,a)
    local out={platforms={}}
    for _,pl in pairs(p.force.platforms) do
      if pl.valid and (a.platform==nil or pl.name==a.platform) then
        local row={name=pl.name,state=platform_states[pl.state],at=location(pl),paused=pl.paused or nil,
          schedule=schedule_text(pl),deleting=pl.scheduled_for_deletion and pl.scheduled_for_deletion>0 or nil,
          weight=pl.weight and math.floor(pl.weight/1000) or nil}
        for k,v in pairs(M.flight(pl) or {}) do row[k]=v end
        local hub=pl.hub
        if hub and hub.valid then
          row.hub=hub.position
          row.hub_items=top_items(hub.get_inventory(defines.inventory.hub_main),a.platform and 64 or 12)
          row.hub_slots=M.hub_slots(hub)
          local trash=defines.inventory.hub_trash and try(function() return hub.get_inventory(defines.inventory.hub_trash) end)
          row.hub_trash=trash and top_items(trash,12) or nil
          local secs=hub.get_logistic_sections()
          if secs then
            local req,off={},{}
            for _,s in ipairs(list_sections(secs,true)) do
              for _,r in ipairs(s.requests) do if s.off then off[#off+1]=r else req[#req+1]=r end end
            end
            row.requests=#req>0 and req or nil
            -- In a section switched off: not requested.
            row.requests_off=#off>0 and off or nil
          end
          row.leave_ok=pl.can_leave_current_location and pl.can_leave_current_location() or nil
          -- Hub health, turrets, turret ammo against the hub's, repair packs.
          row.defense=api.defense and try(function() return api.defense(pl) end) or nil
        end
        -- Damaged entities, most damaged first (10 with platform=, else 3)
        -- with damaged_count, and the hub's repair packs.
        if pl.surface then
          local repair=M.repair_view(pl)
          local list=repair.damaged or {}
          local count=repair.damaged_count or #list
          if not a.platform and #list>3 then list={list[1],list[2],list[3]} end
          row.repair_packs,row.damaged=repair.repair_packs,#list>0 and list or nil
          row.damaged_count=count>#list and count or nil
        end
        if a.platform then detail(pl,row); row.construction_blocked=try(function() return M.blockers(pl) end) end
        out.platforms[#out.platforms+1]=row
      end
    end
    -- Silos on the character's surface: what the launch button would send.
    local silos={}
    for _,e in pairs(p.surface.find_entities_filtered{type='rocket-silo',force=p.force,limit=16}) do
      local cargo=e.get_inventory(defines.inventory.rocket_silo_rocket)
      local trash=defines.inventory.rocket_silo_trash and e.get_inventory(defines.inventory.rocket_silo_trash)
      silos[#silos+1]={position=e.position,status=silo_states[e.rocket_silo_status],
        parts=e.rocket_parts..'/'..e.prototype.rocket_parts_required,cargo=cargo and top_items(cargo,8) or nil,
        trash=trash and top_items(trash,8) or nil,auto_requests=e.use_transitional_requests or nil,
        weight=cargo and M.rocket_weight(e) or nil}
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
    -- Paused on a route it stops thrusting but stays on the route, among its
    -- asteroids, drifting back (shift04: Skylark paused at 48%, drifted to
    -- 43% and was lost there).
    local note
    if a.paused==true and pl.paused and pl.space_connection then
      note='paused on the route: the platform stays among the route\'s asteroids and drifts back the way it came (Skylark: 48% to 43%); it reaches no orbit until unpaused'
    elseif a.paused==true and pl.paused then
      note='paused in orbit: the platform stays where it is, among that orbit\'s asteroids'
    end
    return {name=pl.name,state=platform_states[pl.state],at=location(pl),paused=pl.paused or nil,schedule=schedule_text(pl),note=note}
  end
  -- Rocket cargo weight against the lift, in grams as the game counts them
  -- (item prototype weight; rocket_lift_weight 1000000 = 1000 kg). The game
  -- takes cargo past the lift by script and then refuses the launch.
  local function kg(g) return string.format('%g',math.floor(g/100+0.5)/10) end
  function M.rocket_load(silo)
    local inv=silo.get_inventory(defines.inventory.rocket_silo_rocket)
    local w,items=0,{}
    for _,s in ipairs(inv and try(function() return inv.get_contents() end) or {}) do
      local each=try(function() return prototypes.item[s.name].weight end) or 0
      w=w+each*s.count; items[#items+1]={name=s.name,count=s.count,each=each}
    end
    table.sort(items,function(x,y) local wx,wy=x.each*x.count,y.each*y.count; if wx~=wy then return wx>wy end return x.name<y.name end)
    return w,try(function() return prototypes.utility_constants.rocket_lift_weight end) or 1000000,items
  end
  function M.rocket_weight(silo) local w,lift=M.rocket_load(silo); return kg(w)..'/'..kg(lift)..' kg' end
  -- How many of an item still fit under the lift, and the load it joins.
  function M.rocket_room(silo,item)
    local w,lift=M.rocket_load(silo)
    local each=try(function() return prototypes.item[item].weight end) or 0
    local room=each>0 and math.max(0,math.floor((lift-w)/each)) or math.huge
    return room,{weight=M.rocket_weight(silo),each=kg(each)..' kg',room=room~=math.huge and room or nil}
  end
  local function overweight(silo)
    local w,lift,items=M.rocket_load(silo)
    if w<=lift then return nil end
    local parts={}
    for i=1,math.min(#items,8) do local s=items[i]; parts[i]=s.name..'*'..s.count..' at '..kg(s.each)..' kg' end
    return 'overweight by '..kg(w-lift)..' kg: the rocket holds '..kg(w)..' kg and lifts '..kg(lift)..' kg; take cargo out with transfer {position, direction=to_player, inventory=rocket_silo_rocket, item, count} (cargo: '..table.concat(parts,', ')..')'
  end
  -- launch_rocket returned false: the game gives no reason (the API documents
  -- false as the silo not ready), so name what it may check, the conditions
  -- out of the ordinary first. Weight is not among them: launch refuses an
  -- overweight rocket before asking the game; the cargo kg is in what it saw.
  local function refused(silo,pl,destination)
    local odd,seen={},{}
    local entity_states=invert(defines.entity_status)
    seen[#seen+1]='silo '..tostring(silo_states[silo.rocket_silo_status])..'/'..tostring(try(function() return entity_states[silo.status] end))
    local rocket=try(function() local r=silo.rocket; return r and r.valid end)
    if not rocket then odd[#odd+1]='the silo holds no rocket entity' end
    local weight=try(function() return M.rocket_weight(silo) end)
    if weight then seen[#seen+1]='cargo '..weight end
    if silo.use_transitional_requests then odd[#odd+1]='automatic requests are on (the silo fills and sends rockets for platforms\' requests itself)' end
    if pl then
      local state=platform_states[pl.state]
      local paused=pl.paused or state=='paused'
      seen[#seen+1]='platform '..pl.name..' '..tostring(state)..(paused and state~='paused' and ' (paused)' or '')..' at '..tostring(location(pl))
      if paused then odd[#odd+1]='platform '..pl.name..' is paused (platform_schedule paused=false unpauses it)' end
      if destination.station and not destination.station.valid then odd[#odd+1]='the hub is gone' end
    end
    seen[#seen+1]='destination '..tostring(invert(defines.cargo_destination)[destination.type])
    return 'the game refused the launch (launch_rocket returned false)'..(#odd>0 and ': '..table.concat(odd,'; ') or '')..' ['..table.concat(seen,', ')..']'
  end
  function M.launch(p,a)
    local silo=api.remote_entity(p,{position=a.position,name=a.name,unit_number=a.unit_number})
    assert(silo.type=='rocket-silo','not a rocket silo')
    -- The silo GUI checkbox: launch on its own for platforms' requests.
    -- Switching them on with cargo loaded by hand: the game moves that cargo
    -- to the silo's trash slots (rocket_silo_trash), which never launch.
    local switched
    if a.auto_requests~=nil then
      assert(type(a.auto_requests)=='boolean','auto_requests must be boolean')
      local loaded=a.auto_requests and not silo.use_transitional_requests and top_items(silo.get_inventory(defines.inventory.rocket_silo_rocket),8)
      silo.use_transitional_requests=a.auto_requests
      switched={auto_requests=silo.use_transitional_requests}
      if loaded then
        switched.cargo_to_trash=loaded
        switched.note='automatic requests are on with cargo loaded by hand: the game moves that cargo out of the rocket into the silo\'s trash slots, which never launch; take it back with transfer {position, direction=to_player, inventory=rocket_silo_trash} (item= for one kind); inspect and platforms list it as trash'
      end
      local trash=defines.inventory.rocket_silo_trash and silo.get_inventory(defines.inventory.rocket_silo_trash)
      switched.trash=trash and top_items(trash,8) or nil
      if a.platform==nil and a.orbit==nil then return switched end
    end
    assert(silo.rocket_silo_status==defines.rocket_silo_status.rocket_ready,'rocket is not ready: '..tostring(silo_states[silo.rocket_silo_status])..', parts '..silo.rocket_parts..'/'..silo.prototype.rocket_parts_required)
    local cargo=top_items(silo.get_inventory(defines.inventory.rocket_silo_rocket),8)
    local heavy=overweight(silo)
    if heavy then error('launch refused, '..heavy,0) end
    -- Riding: the character climbs into the rocket, as a player does
    -- standing at the silo, and arrives in the platform hub.
    local rider,bot
    if a.ride then
      assert(a.ride==true,'ride must be true')
      bot=api.real(p)==nil and api.bot and api.bot(p) or nil
      assert(api.real(p)~=nil or bot,'only a player or a bot can ride')
      assert(a.platform~=nil,'ride needs platform=<name>')
      assert(p.can_reach_entity(silo),'stand within reach of the silo to board its rocket')
      rider=p.character
      assert(rider,'the player has no character here to board the rocket')
      -- The silo's "Travel to platform": the rider is the only payload, and
      -- only worn armor (with its equipment) and guns go along; ammo and the
      -- rest of the inventory must be shipped as cargo first.
      assert(cargo==nil,'a rider is the only payload: unload the rocket cargo first (holds '..tostring(cargo)..')')
      for _,inv in ipairs({'character_main','character_ammo','character_trash'}) do
        local items=defines.inventory[inv] and rider.get_inventory(defines.inventory[inv])
        assert(not items or items.is_empty(),'only armor and guns travel with the rider: put down everything in '..inv..' first (ship it as rocket cargo)')
      end
    end
    local destination,to,pl
    if a.platform~=nil then
      pl=M.platform(p,a.platform)
      local here=p.surface.planet and p.surface.planet.name
      assert(pl.space_location and pl.space_location.name==here,'platform '..pl.name..' is not in orbit of '..tostring(here)..' (at '..tostring(location(pl))..')')
      -- Cargo for a platform lands in its hub (a station); the space_platform
      -- destination only takes the starter pack a new platform waits for.
      if pl.state==defines.space_platform_state.waiting_for_starter_pack then
        destination={type=defines.cargo_destination.space_platform,space_platform=pl}
      else
        assert(pl.surface and pl.hub and pl.hub.valid,'platform '..pl.name..' has no hub yet')
        destination={type=defines.cargo_destination.station,station=pl.hub}
      end
      to='platform '..pl.name
    else
      assert(a.orbit==true,'give platform=<name>, or orbit=true to launch into orbit with no platform (cargo is lost unless it has launch products)')
      destination={type=defines.cargo_destination.orbit}; to='orbit'
    end
    if bot then
      -- The rocket flies with its own cargo pod; the bot rides it (bots.lua).
      api.bots.can_board(bot)
      local pod=try(function() local r=silo.rocket; return r and r.valid and r.attached_cargo_pod or nil end)
      if not silo.launch_rocket(destination) then error(refused(silo,pl,destination),0) end
      api.bots.board(bot,pl,pod)
      return {launched=true,to=to,cargo='empty',riding='the bot rides the rocket\'s cargo pod (~40 s), then is aboard '..a.platform..' with remote view only: poll status (travel)'}
    end
    if rider then api.stop(p) end
    if not silo.launch_rocket(destination,rider) then error(refused(silo,pl,destination),0) end
    return {launched=true,to=to,cargo=cargo or 'empty',riding=rider and 'the character rides along (~40 s); actions fail until it sits in the hub: poll status (platform, riding)' or nil,
      auto_requests=switched and switched.auto_requests,cargo_to_trash=switched and switched.cargo_to_trash,note=switched and switched.note}
  end
  -- The hub's drop slots: items from the hub inventory go down to the planet
  -- below a stopped platform in a cargo pod, to the force's landing pad there,
  -- else near position (default: a bot's last spot there, else the spawn
  -- point), where the pod lands as a temporary container to empty by hand.
  function M.drop(p,a)
    local own=p.surface and p.surface.platform
    local pl=M.platform(p,a.platform or (own and own.name))
    assert(pl.hub and pl.hub.valid,'platform '..pl.name..' has no hub yet')
    local loc=pl.space_location
    assert(loc and loc.type=='planet','platform '..pl.name..' is not stopped at a planet (at '..tostring(location(pl))..')')
    assert(type(a.items)=='table' and #a.items>=1 and #a.items<=20,'items requires 1..20 {item,count,quality?}')
    local to=api.drops and api.drops.recipients(a.to) or {}
    local hub_inv=pl.hub.get_inventory(defines.inventory.hub_main)
    -- Repeated entries add up; the hub must hold the total.
    local want,by={},{}
    for i,r in ipairs(a.items) do
      assert(type(r)=='table','items['..i..'] is {item,count,quality?}')
      local name,quality=item_name(r.item),r.quality or 'normal'
      local count=api.integer(r.count,1,1,100000,'count')
      local key=name..'@'..quality
      if by[key] then by[key].count=by[key].count+count
      else by[key]={name=name,quality=quality,count=count}; want[#want+1]=by[key] end
    end
    for _,w in ipairs(want) do
      local have=hub_inv.get_item_count{name=w.name,quality=w.quality}
      assert(have>=w.count,'the hub of '..pl.name..' holds '..have..' '..w.name..(w.quality~='normal' and '@'..w.quality or '')..', not '..w.count)
    end
    local planet=game.planets[loc.name]
    local surface=planet.surface or planet.create_surface()
    local pod=try(function() return pl.hub.create_cargo_pod() end)
    assert(pod and pod.valid,'the hub has no free cargo hatch right now; try again shortly')
    local cargo=pod.get_inventory(defines.inventory.cargo_unit)
    -- The hub's own stacks move (freshness, grids and other item data go
    -- along): whole stacks by transfer_stack, the last part of one as a copy
    -- with its spoil progress, taken off the hub stack.
    local sent,left={},{}
    for _,w in ipairs(want) do
      local need=w.count
      for i=1,#hub_inv do
        if need<=0 then break end
        local st=hub_inv[i]
        if st.valid_for_read and st.name==w.name and (st.quality and st.quality.name or 'normal')==w.quality then
          if st.count<=need then
            local n=st.count
            local slot=cargo.find_empty_stack()
            if slot and slot.transfer_stack(st) then need=need-n end
          else
            local def={name=w.name,quality=w.quality,count=need}
            local spoil=try(function() return st.spoil_percent end)
            if spoil and spoil>0 then def.spoil_percent=spoil end
            local moved=cargo.insert(def)
            if moved>0 then st.count=st.count-moved; need=need-moved end
          end
        end
      end
      local moved=w.count-need
      sent[#sent+1]=w.name..(w.quality~='normal' and '@'..w.quality or '')..'*'..moved
      if need>0 then left[#left+1]=w.name..'*'..need end
    end
    if cargo.is_empty() then pod.destroy(); error('nothing fit in the cargo pod',0) end
    local pad=surface.find_entities_filtered{type='cargo-landing-pad',force=p.force,limit=1}[1]
    local dest={type=defines.cargo_destination.surface,surface=surface}
    if not pad then
      local b=api.bot and api.bot(p)
      dest.position=a.position~=nil and api.position(a.position) or (b and b.spots and b.spots[surface.name]) or p.force.get_spawn_position(surface)
    end
    -- A refused destination puts the items back in the hub, never strands
    -- them; what the hub cannot take back stays in the pod, which is kept.
    if not pcall(function() pod.cargo_pod_destination=dest end) then
      local kept={}
      for i=1,#cargo do
        local st=cargo[i]
        if st.valid_for_read then
          local n=hub_inv.insert(st)
          if n>=st.count then st.clear() else st.count=st.count-n; kept[#kept+1]=st.name..'*'..st.count end
        end
      end
      if #kept==0 then pod.destroy() end
      error('the game refused the cargo pod destination '..surface.name..(#kept==0 and '; the items stay in the hub'
        or '; the hub took back all but '..table.concat(kept,' ')..', which stay in the cargo pod on the hub'),0)
    end
    -- Followed until it lands (drops.lua): where it came down goes to the
    -- sender's and the `to` teammates' team block.
    local id=api.drops and api.drops.record(p,{pod=pod,platform=pl.name,surface=surface.name,pad=pad and pad.position or nil,
      near=dest.position,sent=sent,to=to})
    return {drop=id,dropped=sent,not_sent=#left>0 and left or nil,to=surface.name,pad=pad and pad.position or nil,near=dest.position,
      tell=#to>0 and to or nil,
      note=pad and 'lands in the landing pad in ~20 s' or 'lands in ~20 s as a cargo pod container, often 10-20 tiles from that spot (pods scatter): your next reply\'s team block says where (drops lists them); take the items with transfer (it vanishes when empty)'}
  end
  -- The hub's "drop to planet": the character descends in a cargo pod to the
  -- planet the platform is stopped at (a landing pad if there is one).
  function M.land(p,a)
    local bot=api.real(p)==nil and api.bot and api.bot(p) or nil
    if bot then
      local out=api.bots.land(bot)
      out.note='the cargo pod comes down by itself (~20 s); actions fail until the bot stands on '..out.landing..': poll status'
      return out
    end
    local pl=p.surface.platform
    assert(pl and pl.force==p.force,'the character is not on a space platform')
    assert(pl.space_location and pl.space_location.type=='planet','platform '..pl.name..' is not stopped at a planet (at '..tostring(location(pl))..')')
    api.stop(p)
    assert(api.real(p).land_on_planet(),'the game refused the landing')
    return {landing=pl.space_location.name,note='the cargo pod takes ~20 s; actions fail until the character stands on the planet: poll status'}
  end
  M.schema={
    requests={surface='optional planet name, with position: a requester or buffer chest or landing pad there by remote view, where our force sees the chunk (the reply\'s target says on which surface)',target='character (default when no position/platform)',from_buffers='requester chest: boolean, the "request from buffer chests" switch (the reply says its state)',position='{x,y} of a requester/buffer chest, landing pad or other requester in a visible chunk (remote view; no reach needed)',platform='platform name: its hub requests (what the planet in orbit sends up)',
      set='array of {item,min,max?,quality?,from? (planet to import from, platform hubs)}; replaces that item\'s slot',clear='array of item names to remove',clear_all='boolean: empty the section first',section='1-based section index (default the first manual ungrouped section, created if none)',
      active='boolean: switch the section on or off (the GUI\'s checkbox; a section that is off requests nothing)',
      returns='target, sections [{index, group, off (switched off: its requests are not made), controlled (set by the game, not editable), requests ["item min..max from planet", "item=n from planet"]}], changed_section, note (sections that are off but hold requests); call with no set/clear/active to just read'},
    platforms={platform='optional name: only this one, with its full hub inventory, speed (the game\'s value, km per tick), damaged up to 10 (the game repairs platform entities itself with the hub\'s repair packs, one at a time), damaged_tiles, asteroid_chunks on the platform surface by type, thrusters (count, lowest fuel/oxidizer tank), unbuilt_ghosts, construction_blocked (why the hub cannot build or deconstruct now: hub full, ghosts whose items the hub lacks), hub_inserters_without_target (inserters taking from the hub with nothing to drop into, and the tile they drop onto), thrown_overboard (items in flight off the platform), consumed_10min and produced_10min (the game\'s item statistics for the platform surface)',returns='platforms [{name, state, at (location or from->to %), speed_kms, next_stop (the stop it flies to; waiting at a stop, the one after), on a route leg (as flown), heading_to, leg_km, leg_left_km, eta_min (at the current speed), schedule, hub, hub_items, hub_slots (free of all), hub_trash, requests, requests_off (in hub sections switched off: not requested), leave_ok, defense {hub_health, turrets (count: empty, low under 10 rounds), ammo (rounds the turrets hold against the ammo in the hub)}, repair_packs, damaged (most damaged first: 3, or 10 with platform; damaged_count when more)}], silos on this surface {position, status, parts, cargo}, planet'},
    platform_create={name='optional platform name',planet='default the character\'s planet',starter_pack='default space-platform-starter-pack',note='like the platform GUI: the platform waits for its starter pack; a silo holding one in its rocket cargo launches it on its own'},
    platform_schedule={platform='name',stops='array of {station=planet, wait=[{type=all_requests_satisfied|any_request_zero|time|inactivity|..., ticks?, compare=and|or}]}; [] clears',current='1-based stop to head for (default 1)',paused='boolean: pause/unpause thrust and the schedule (paused on a route, the platform stays among its asteroids and drifts back; the reply\'s note says so)'},
    drop={platform='platform name (default: the one you are aboard)',items='array of 1..20 {item,count,quality?} from the hub inventory',position='optional {x,y} to land near when the planet has no landing pad of ours (default: a bot\'s last spot there, else the spawn point)',to='optional teammate name or list: told where it landed too, in their team block',
      note='the hub\'s drop slots, from remote view: a cargo pod takes the items to the planet below a stopped platform (the landing pad if any, else a temporary container on the ground)',returns='drop (its number), dropped, not_sent, to, pad, near, tell; where it lands comes in the team block (drop #N landed at (x,y) on PLANET: cargo-pod-container with ...), and the drops read lists recent drops'},
    land={note='from a platform stopped at a planet: drop to that planet in a cargo pod (to a landing pad if any). A bot lands where it last stood on that planet, else at its spawn point, wearing the armor and guns it rode up with',returns='landing (and for a bot: at, pad)'},
    launch={position='rocket silo {x,y} in a visible chunk (any tile of it)',surface='optional planet name: the silo there by remote view, where our force sees the chunk (e.g. vulcanus from a platform above it); platform stays the destination',ride='true: the character boards the rocket (stand within reach of the silo) and arrives in the platform hub; needs platform; the rocket must hold no cargo and the character nothing but worn armor and guns (ship the rest as cargo first). Bots ride too: aboard they have no body and act by remote view (platforms, platform_schedule, requests, ghost tools with platform=, research, chat) until they land',platform='send the rocket cargo to this platform in orbit of this planet',orbit='true: launch with no platform (cargo lost unless it has launch products)',auto_requests='boolean: the silo GUI setting to fill and launch rockets on its own for platforms\' requests in orbit (alone: only sets it; switched on with cargo loaded by hand, the game moves that cargo to the silo\'s trash slots: cargo_to_trash, note, trash)',returns='launched, to, cargo; settings {silo, auto_requests, send_to_orbit_automatically, requesting_for, rocket, parts}: the silo\'s switches after the call',refused='overweight by N kg (a rocket lifts 1000 kg; the cargo listed by weight) before the game is asked; when the game refuses, what it may check'},
  }
  return M
end
