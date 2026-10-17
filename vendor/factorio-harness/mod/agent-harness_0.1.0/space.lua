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
  -- Where a platform is, by freight.lua's rule (the platform_arrived wait reads the same): a stop, a location while
  -- still on its path, or the leg in the way it is flown with the share flown (Luna, shift12: `nauvis->gleba 27%`
  -- was the connection's own order while Sunward flew gleba->nauvis, 73% of the way).
  local freight=api.freight or require('freight')(api)
  local function location(pl)
    local w=freight.where(pl)
    if w.at then return w.stopped and w.at or w.at..' (on its path, not stopped)' end
    if w.leg then return string.format('%s->%s %d%%',w.leg.from,w.leg.to,math.floor(w.leg.flown*100+0.5)) end
  end
  local top_items,try
  -- Hub trash (operator 09:04, Astra: Sunward's 50 processing units and 50 low
  -- density structures, request max 0, left its trash on arrival at Gleba,
  -- which has no landing pad; on world n they lay in a cargo-pod container at
  -- (-10.5,-5.5)). On a 2.0.77 copy: in flight, items over a max moved from
  -- the hub to its trash within 30 ticks and the trash stayed aboard for all
  -- 24,800 ticks; 30 ticks after the stop at Gleba one pod took it down and
  -- landed as a cargo-pod container 14 tiles from (0,0). Parked, what was put
  -- in the trash went down within 20 ticks (Nauvis: to the landing pad), but
  -- 12 processing units over a max of 0 stayed in the hub for 3500 ticks.
  -- over: the call set a max under what the hub holds.
  function M.trash_note(pl,over)
    local loc=pl.space_location
    local planet=loc and (loc.type=='planet' or try(function() return prototypes.space_location[loc.name].type end)=='planet')
    local where='to its landing pad, or, with none there, as cargo-pod containers on the ground near (0,0) (where_is lists them)'
    if planet then
      return (over and 'while the platform is stopped the game leaves what is over a max in the hub; once it flies, the game moves that to the trash, which goes down at the next stop. ' or '')
        ..'the game sends the hub\'s trash down to '..loc.name..' in cargo pods while the platform is stopped there: '..where
    elseif pl.space_connection then
      return (over and 'in flight the game moves what is over a max to the hub\'s trash within a second. ' or '')
        ..'the hub keeps its trash while flying; when the platform stops at a planet, the game sends it down in cargo pods: '..where
    end
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
    text=from and text..' from '..from or text
    -- The GUI's custom minimum payload per request (LogisticFilter minimum_delivery_count; Astra 03:59).
    if hub and f.minimum_delivery_count then text=text..' min payload '..f.minimum_delivery_count end
    return text
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
  -- A max: a whole number at least min, or "inf" (also "infinity", "none") for none. Returns max, inf.
  local function max_arg(v,min)
    if v==nil then return nil,false end
    local w=type(v)=='string' and v:lower() or nil
    if w=='inf' or w=='infinity' or w=='none' then return nil,true end
    assert(type(v)=='number' and v==math.floor(v) and v>=min,
      string.format('max must be at least min (%d) and a whole number, or "inf" for none: %s is not',min,type(v)=='string' and '"'..v..'"' or tostring(v)))
    return v,false
  end
  M.max_arg=max_arg
  -- Every argument of a requests call, checked before anything changes (Sol, d15 04:16: max "inf" on Starling's
  -- magazines set the slot, then failed with "attempt to compare string with number"). Returns the set entries
  -- read: {name, quality, min, max (nil: not named or "inf"), inf, from}.
  function M.check_requests(p,a,label,chest,secs)
    assert(a.from_buffers==nil or type(a.from_buffers)=='boolean','from_buffers must be boolean')
    assert(a.from_buffers==nil or (chest and chest.type=='logistic-container'),'from_buffers is a requester chest setting')
    if a.construction_requests~=nil then
      assert(type(a.construction_requests)=='boolean','construction_requests must be true or false (the hub\'s Request missing construction materials)')
      local hub=a.platform~=nil and M.platform(p,a.platform).hub or (chest and chest.type=='space-platform-hub' and chest) or nil
      assert(hub and hub.valid,'construction_requests is a platform hub setting (Request missing construction materials)')
      assert(api.keep and api.keep(),'construction_requests is not available in this runtime')
    end
    assert(a.active==nil or type(a.active)=='boolean','active must be true or false: switch the section on or off')
    assert(a.clear_all==nil or type(a.clear_all)=='boolean','clear_all must be true or false')
    local changing=a.set~=nil or a.clear~=nil or a.clear_all~=nil or a.active~=nil
    if changing and a.section~=nil then
      local sec=secs.get_section(api.integer(a.section,1,1,100,'section'))
      assert(sec,'section '..a.section..' does not exist (sections_count '..secs.sections_count..')')
      assert(sec.is_manual,'section '..sec.index..' is controlled by the game')
    end
    assert(a.clear==nil or type(a.clear)=='table','clear is a list of item names: ["coal"]')
    for _,name in ipairs(a.clear or {}) do item_name(name) end
    local listed=type(a.set)=='table'
    if listed then local n=0; for _ in pairs(a.set) do n=n+1 end; listed=n==#a.set end
    assert(a.set==nil or (listed and #a.set<=100),'set requires an array of {item,min,max?,quality?,from?}: [{"item":"iron-plate","min":100}]')
    local entries={}
    for k,r in ipairs(a.set or {}) do
      assert(type(r)=='table','each request is {item,min,max?,quality?,from?}')
      -- {name, count} (Luna, shift11: "unknown item: nil", 4 times): the entry as it is written.
      if r.item==nil and (r.name~=nil or r.count~=nil) then
        error(string.format('each set entry is {item, min, max?, quality?, from?}: {"item":"%s","min":%s} for {name, count}',
          tostring(r.name or 'ITEM'),tostring(r.count or r.min or 0)),0)
      end
      local name,quality=item_name(r.item),r.quality or 'normal'
      assert(type(quality)=='string' and (quality=='normal' or (prototypes.quality and prototypes.quality[quality])),'unknown quality: '..tostring(r.quality))
      local min=api.integer(r.min,0,0,1000000000,'min')
      local max,inf=max_arg(r.max,min)
      -- A personal max under what the character holds (Opus, d15 09:20: max 0 to clear a request sent 6 pumpjacks and
      -- 30 steel to the trash, and robots carried them off): the game moves what is over a max to the trash. Refused
      -- unless force.
      if label=='character' and max and not a.force then
        local held=try(function() return p.get_main_inventory().get_item_count{name=name,quality=quality} end)
          or try(function() return p.get_item_count(name) end) or 0
        if held>max then
          error(string.format('%s max %d: you hold %d; the game moves what you hold over a personal max to your trash, and robots take it to storage. clear (or remove): ["%s"] deletes the request and keeps what you hold; force: true sets the max anyway',
            name,max,held,name),0)
        end
      end
      -- The import planet named.
      local from=r.from
      if from~=nil then
        local names={}
        for n in pairs(prototypes.space_location or {}) do names[#names+1]=n end
        table.sort(names)
        assert(type(from)=='string' and prototypes.space_location[from],
          'from is the planet a platform hub imports the item from, a space location ('..table.concat(names,', ')..'): '..tostring(from)..' is not one')
      end
      -- min_payload (Astra 03:59, Sonnet): the GUI's custom minimum payload for this request on a platform hub
      -- (minimum_delivery_count): automatic silos send a rocket for it once that much of it is ready; false or 0 clears it.
      local mp=r.min_payload
      if mp==nil then mp=r.minimum_delivery_count end
      if mp~=nil then
        local is_hub=a.platform~=nil or (chest and chest.type=='space-platform-hub')
        assert(is_hub,'min_payload is a platform hub request setting (the GUI\'s custom minimum payload)')
        assert(mp==false or (type(mp)=='number' and mp==math.floor(mp) and mp>=0 and mp<=1000000),'min_payload must be 1..1000000 items, or false (or 0) to clear it')
        if mp==0 then mp=false end
      end
      entries[k]={name=name,quality=quality,min=min,max=max,inf=inf,from=from,min_payload=mp}
    end
    return entries
  end
  function M.requests(p,a)
    -- remove: the same as clear (Opus, d15 09:20: max 0 was his way to clear a request, and it sent what he held to
    -- the trash).
    if a.remove~=nil then
      assert(type(a.remove)=='table','remove is a list of item names, as clear')
      local b={}
      for k,v in pairs(a) do b[k]=v end
      local list={}
      for _,n in ipairs(a.clear or {}) do list[#list+1]=n end
      for _,n in ipairs(a.remove) do list[#list+1]=n end
      b.clear=list; b.remove=nil; a=b
    end
    assert(a.force==nil or type(a.force)=='boolean','force must be true or false')
    local label,secs,chest=sections_of(p,a)
    local entries=M.check_requests(p,a,label,chest,secs)
    -- A requester chest's "request from buffer chests" switch.
    local buffers
    if a.from_buffers~=nil then
      local ok,err=pcall(function() chest.request_from_buffers=a.from_buffers end)
      assert(ok,'the game refused from_buffers: '..tostring(err))
    end
    if chest then pcall(function() buffers=chest.request_from_buffers end) end
    -- A hub's Request missing construction materials (Astra, shift12 19:16: a paste switched Starling's off and its
    -- construction requests vanished): switched as the GUI's checkbox does (keep.lua).
    local hub=a.platform~=nil and M.platform(p,a.platform).hub or (chest and chest.type=='space-platform-hub' and chest) or nil
    local keep=api.keep and api.keep()
    local switched
    if a.construction_requests~=nil then
      local on=keep.set_construction(hub,a.construction_requests)
      assert(on==a.construction_requests,'the game kept Request missing construction materials '..(on and 'on' or 'off'))
      switched=true
    end
    local changing=a.set~=nil or a.clear~=nil or a.clear_all~=nil or a.active~=nil
    -- changed: a slot set or cleared, or the section switched (friction2: a set the call read as nothing still said
    -- changed_section).
    local touched,stored,changed
    local others={}
    if changing then
      local sec
      -- The section a set or clear of one item goes to without section (Grok, d15 06:20: a hub's set added a new
      -- section and the hub requested the sum, underground-belt 2 plus 4): the manual section that already requests
      -- it (the first; any others are named), else the default one below.
      local function holding(name,quality)
        local first,rest=nil,{}
        if a.section~=nil then return nil,rest end
        for i=1,secs.sections_count do
          local s_=secs.get_section(i)
          if s_.is_manual then
            local _,found=slot_of(s_,name,quality)
            if found then if first then rest[#rest+1]=s_.index else first=s_ end end
          end
        end
        return first,rest
      end
      local default
      local function default_section()
        if default then return default end
        if a.section~=nil then
          default=secs.get_section(api.integer(a.section,1,1,100,'section'))
          assert(default,'section '..a.section..' does not exist (sections_count '..secs.sections_count..')')
        else
          for i=1,secs.sections_count do local s_=secs.get_section(i); if s_.is_manual and s_.group=='' then default=s_; break end end
          default=default or secs.add_section()
          assert(default,'no manual logistic section could be added')
        end
        assert(default.is_manual,'section '..default.index..' is controlled by the game')
        return default
      end
      local function for_item(name,quality)
        local found,rest=holding(name,quality)
        local target=found or default_section()
        if #rest>0 then others[#others+1]=string.format('%s is requested in section%s %s too (the hub requests the sum; requests {section, clear} removes one)',
          name,#rest>1 and 's' or '',table.concat(rest,', ')) end
        if target.group~='' then others[#others+1]=string.format('%s: section %d is the logistic group "%s": every entity in the group gets the change, as in the GUI',name,target.index,target.group) end
        return target
      end
      sec=(a.active~=nil or a.clear_all) and default_section() or nil
      touched=sec
      if a.active~=nil then sec.active=a.active; changed=true end
      if a.clear_all then changed=changed or (sec.filters_count or 0)>0; sec.filters={} end
      local sections_touched,seen_sec={},{}
      local function touch(s_) touched=touched or s_; if not seen_sec[s_.index] then seen_sec[s_.index]=true; sections_touched[#sections_touched+1]=s_.index end end
      if sec then touch(sec) end
      -- What is stored for each item touched, read back from its slot (Luna, shift12 12:47): `processing-unit 0..400
      -- from vulcanus (was 0..200 from vulcanus)`, `coal: cleared (was coal=500 from vulcanus)`.
      local is_hub=hub~=nil
      stored={}
      for _,name in ipairs(a.clear or {}) do
        local csec=sec or for_item(item_name(name),'normal')
        touch(csec)
        local i,found=slot_of(csec,item_name(name),'normal')
        if found then
          local was=filter_text(csec.get_slot(i),is_hub)
          csec.clear_slot(i); changed=true
          stored[#stored+1]=name..': cleared'..(was and ' (was '..was..')' or '')
        else stored[#stored+1]=name..': no request to clear in section '..csec.index end
      end
      for k in ipairs(a.set or {}) do
        local e=entries[k]
        local name,quality,min=e.name,e.quality,e.min
        local ssec=sec or for_item(name,quality)
        touch(ssec)
        local i,found=slot_of(ssec,name,quality)
        local old=found and ssec.get_slot(i) or nil
        -- The max: the one named ("inf" for none), else the one the slot already has while it is at least min, as the
        -- GUI keeps it when only min is edited (friction3: Grok's map sets turned copper-cable 200..400 into 40..inf).
        local max,max_note=e.max,''
        if e.inf then max=nil
        elseif max==nil and old and type(old.max)=='number' then
          if old.max>=min then max=old.max; max_note=' (max kept: not named in this edit)'
          else max_note=string.format(' (max %d dropped: under min %d)',old.max,min) end
        end
        -- The import planet: the one named, else the one the slot already has (Luna, shift12 19:30: an edit of min
        -- and max without from turned three requests from vulcanus into from nauvis).
        local from,kept=e.from,false
        if from==nil and old and old.import_from then
          from=type(old.import_from)=='string' and old.import_from or try(function() return old.import_from.name end)
          kept=from~=nil
        end
        -- The minimum payload: the one named (false clears it), else the slot's, as for the import planet.
        local mp,mp_kept=e.min_payload,false
        if mp==nil and old and old.minimum_delivery_count then mp=old.minimum_delivery_count; mp_kept=true end
        local was=old and filter_text(old,is_hub)
        ssec.set_slot(i,{value={type='item',name=name,quality=quality,comparator='='},min=min,max=max,import_from=from,minimum_delivery_count=mp or nil}); changed=true
        local now=filter_text(ssec.get_slot(i),is_hub) or name
        stored[#stored+1]=now..max_note..(kept and is_hub and ' (import planet kept: not named in this edit)' or '')
          ..(mp_kept and ' (min payload kept: not named in this edit)' or '')..(was and was~=now and ' (was '..was..')' or '')
      end
      if not touched then touch(default_section()) end
      if #sections_touched>1 then table.sort(sections_touched); others[#others+1]='sections changed: '..table.concat(sections_touched,', ') end
    end
    local out={target=label,sections=list_sections(secs,a.platform~=nil or (chest and chest.type=='space-platform-hub')),from_buffers=buffers}
    -- The character's requests not filled, each with why (personal.lua; Haiku, d15: 10 repair packs never came).
    if label=='character' and api.personal then
      local rows=try(function() return api.personal().unfilled(p) end)
      if rows and #rows>0 then
        local lines={}
        for i,r in ipairs(rows) do if i<=12 then lines[i]=r.line end end
        out.unfilled=lines
      end
    end
    -- Requests set into a section that is off are not made: say so.
    local off={}
    for _,row in ipairs(out.sections) do if row.off and #row.requests>0 then off[#off+1]=row.index end end
    if #off>0 then
      out.note=string.format('section%s %s %s switched off: %s requests are not made (requests {section, active: true} switches one on)',
        #off>1 and 's' or '',table.concat(off,', '),#off>1 and 'are' or 'is',#off>1 and 'their' or 'its')
    end
    out.changed_section=changed and touched and touched.index or nil
    out.sections_note=#others>0 and others or nil
    if changing and not changed then out.unchanged='this call set, cleared and switched nothing in section '..(touched and touched.index or '?') end
    out.stored=stored and #stored>0 and stored or nil
    if hub and hub.valid and keep then
      local c=keep.construction(hub)
      out.construction_requests=c and (switched and 'on (switched on now: the game fills its section from the platform\'s ghosts within a second)' or 'on')
        or (switched and 'off (switched off now)' or 'off')
      -- Items a manual section requests too (Astra restored Starling's construction requests by hand): the hub
      -- requests the sum (checked on 2.0.77: crusher 3 in each made 6).
      local theirs,both={},{}
      for _,f in ipairs(c and c.filters or {}) do
        local v=f.value
        if v and v.name then theirs[v.name..'@'..(v.quality or 'normal')]=f.min or 0 end
      end
      for i=1,c and secs.sections_count or 0 do
        local s=secs.get_section(i)
        if s.is_manual and s.active~=false then
          for _,f in ipairs(s.filters or {}) do
            local v=f.value
            local k=v and v.name and v.name..'@'..(v.quality or 'normal')
            if k and theirs[k] and (f.min or 0)>0 and #both<8 then both[#both+1]=string.format('%s %d+%d',v.name,theirs[k],f.min) end
          end
        end
      end
      if #both>0 then out.construction_overlap='manual sections request these too, and the hub requests the sum: '..table.concat(both,', ') end
    end
    -- A hub: what is over a max goes to its trash, and where the trash goes.
    if a.platform~=nil or (chest and chest.type=='space-platform-hub') then
      local pl=a.platform~=nil and M.platform(p,a.platform) or chest.surface.platform
      local hub=pl and pl.hub
      if hub and hub.valid then
        local over={}
        local main=try(function() return hub.get_inventory(defines.inventory.hub_main) end)
        for _,e in ipairs(entries) do
          local held=e.max and main and try(function() return main.get_item_count({name=e.name,quality=e.quality}) end) or 0
          if e.max and held>e.max then over[#over+1]=string.format('%s: the hub holds %d, %d over the max %d',e.name,held,held-e.max,e.max) end
        end
        local trash=defines.inventory.hub_trash and try(function() return hub.get_inventory(defines.inventory.hub_trash) end)
        out.hub_trash=trash and top_items(trash,12) or nil
        out.over_max=#over>0 and over or nil
        if out.hub_trash or out.over_max then out.trash_note=M.trash_note(pl,out.over_max~=nil) end
      end
    end
    return out
  end
  -- Platforms -----------------------------------------------------------------
  top_items=function(inv,limit)
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
  try=function(fn) local ok,v=pcall(fn); if ok then return v end end
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
    local l=freight.leg(pl)
    if l then
      -- The leg in the way it is flown (at says the same, with the share flown).
      out.leg=l.from..'->'..l.to
      out.heading_to=l.to
      out.leg_km=l.length
      out.leg_left_km=math.floor(l.left_km+0.5)
      if l.eta_ticks then out.eta_min=math.floor(l.eta_ticks/60/6+0.5)/10 end
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
        -- What they lack and the chain behind it (thrust.lua): a line per input under half full.
        local t=api.thrust and try(function() return api.thrust(pl) end)
        row.thrust_inputs=t and #t.lines>0 and t.lines or nil
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
  -- Hub slots asteroid chunks take, one a slot (Astra, shift14 22:50: a chunk backlog hid in raw stock; 2.0.77: a chunk
  -- stacks to 1, 9 of Sunward's 99 slots on a copy of world n): 'asteroid chunks take 9 of 99 slots (metallic 5, carbonic 4)'.
  function M.hub_chunks(hub)
    local inv=try(function() return hub.get_inventory(defines.inventory.hub_main) end)
    if not inv then return nil end
    local by,n={},0
    for i=1,#inv do
      local st=inv[i]
      if st.valid_for_read and st.name:find('asteroid%-chunk$') then n=n+1; by[st.name]=(by[st.name] or 0)+1 end
    end
    if n==0 then return nil end
    local parts={}
    for name,k in pairs(by) do parts[#parts+1]={name=name:gsub('%-asteroid%-chunk$',''),n=k} end
    table.sort(parts,function(x,y) return x.n>y.n or (x.n==y.n and x.name<y.name) end)
    local words={}
    for i,x in ipairs(parts) do words[i]=x.name..' '..x.n end
    return string.format('asteroid chunks take %d of %d slots (%s)',n,#inv,table.concat(words,', '))
  end
  -- Why the hub cannot build or deconstruct now: no free slot for what
  -- deconstruction removes, ghosts whose items the hub lacks (one scan of the
  -- platform's ghosts, at most 500, when asked), tile ghosts the foundation
  -- rules hold back (tilecheck.lua).
  local tiles=require('tilecheck')()
  -- On world n 327 ghosts on Aegis took 1.3 ms to count (about 4 us each): 4000 stay under 20 ms.
  M.GHOST_CAP={['entity-ghost']=1000,['tile-ghost']=3000}
  local DEFENSE={['ammo-turret']=true,['electric-turret']=true,['fluid-turret']=true,['artillery-turret']=true}
  function M.defense_waits(pl,ghosts,tile_ghosts,inv)
    local s=pl.surface
    local planned={}
    for _,g in ipairs(tile_ghosts) do
      local pos=g.position
      if try(function() return g.ghost_name end)=='space-platform-foundation' then planned[math.floor(pos.x)..','..math.floor(pos.y)]=true end
    end
    local rows,empty,planned_n,seen={},{},0,{}
    local turrets_need={}
    for _,g in ipairs(ghosts) do
      local gtype=try(function() return g.ghost_type end)
      if DEFENSE[gtype] then
        local b=g.bounding_box
        local holes={}
        for x=math.floor(b.left_top.x+0.01),math.ceil(b.right_bottom.x-0.01)-1 do
          for y=math.floor(b.left_top.y+0.01),math.ceil(b.right_bottom.y-0.01)-1 do
            local tile=try(function() return s.get_tile(x,y).name end)
            if tile=='empty-space' then
              local k=x..','..y
              holes[#holes+1]=string.format('(%d,%d)%s',x,y,planned[k] and '*' or '')
              if not seen[k] then seen[k]=true; empty[#empty+1]=k; if planned[k] then planned_n=planned_n+1 end end
            end
          end
        end
        if #holes>0 then
          local gname=try(function() return g.ghost_name end) or '?'
          turrets_need[gname]=(turrets_need[gname] or 0)+1
          if #rows<8 then rows[#rows+1]=string.format('%s ghost (%g,%g) on %d empty tile%s %s',gname,g.position.x,g.position.y,#holes,#holes==1 and '' or 's',table.concat(holes,' ',1,math.min(6,#holes))) end
        end
      end
    end
    if #empty==0 then return nil end
    local held=inv and (try(function() return inv.get_item_count('space-platform-foundation') end) or 0) or 0
    local short=math.max(0,#empty-held)
    local items={}
    for gname,n in pairs(turrets_need) do
      local it=try(function() return prototypes.entity[gname].items_to_place_this[1].name end) or gname
      local have=inv and (try(function() return inv.get_item_count(it) end) or 0) or 0
      if have<n then items[#items+1]=string.format('%d %s (hub has %d)',n-have,it,have) end
    end
    table.sort(items)
    return string.format('defense ghosts wait on foundation: %s; their footprints take %d foundation tiles (* marks the %d with a foundation ghost planned), the hub holds %d space-platform-foundation: the least to bring %s%s',
      table.concat(rows,'; '),#empty,planned_n,held,short>0 and short..' space-platform-foundation' or 'no more foundation',#items>0 and ', '..table.concat(items,', ') or '')
  end
  function M.blockers(pl)
    local hub=pl.hub
    if not (hub and hub.valid) then return nil end
    local inv=hub.get_inventory(defines.inventory.hub_main)
    local s=pl.surface
    local out={}
    local free=try(function() return inv.count_empty_stacks() end)
    if free==0 then
      -- Ours only, by name; items on the ground marked for pickup apart (Sol, d15: "198 marked" read as the ship being
      -- taken apart, while 12 entities had been marked; the count was every marked entity of every force).
      local by,marked={},0
      for _,e in ipairs(try(function() return s.find_entities_filtered{to_be_deconstructed=true,force=pl.force,limit=2000} end) or {}) do
        if e.valid and e.type~='item-entity' then marked=marked+1; by[e.name]=(by[e.name] or 0)+1 end
      end
      local ground=try(function() return s.count_entities_filtered{to_be_deconstructed=true,type='item-entity'} end) or 0
      local names={}
      for n,c in pairs(by) do names[#names+1]={n,c} end
      table.sort(names,function(x,y) return x[2]>y[2] or x[2]==y[2] and x[1]<y[1] end)
      for i,v in ipairs(names) do names[i]=v[2]..' '..v[1] end
      out[#out+1]=string.format('hub full: 0 of %d slots free',#inv)
        ..(marked>0 and string.format('; %d of our entities marked for deconstruction wait for room (%s; removed entities and their contents go to the hub)',marked,
          table.concat(names,', ',1,math.min(6,#names))..(#names>6 and ', ...' or '')) or '')
        ..(ground>0 and string.format('; %d items on the ground marked for pickup wait for room too',ground) or '')
    end
    -- Items by name and the ghost's quality: the hub builds a ghost only from
    -- items of that quality.
    -- Every ghost is counted up to GHOST_CAP of each kind (Astra, d15 15:11: one search capped at 500 for both kinds
    -- said Aegis's tile ghosts needed 466 foundation while 924 stood); past a cap the line says so, from the game's
    -- count. The item a ghost takes is read once per ghost name.
    local need,order={},{}
    local items_of,short={},{}
    local lists={}
    for _,kind in ipairs({'entity-ghost','tile-ghost'}) do
      local cap=M.GHOST_CAP[kind]
      local list=try(function() return s.find_entities_filtered{type=kind,limit=cap} end) or {}
      lists[kind]=list
      if #list>=cap then
        local total=try(function() return s.count_entities_filtered{type=kind} end) or #list
        if total>#list then short[#short+1]=string.format('the first %d of %d %ss counted',#list,total,kind) end
      end
      for _,g in ipairs(list) do
        local gname=try(function() return g.ghost_name end) or '?'
        local key=kind..'|'..gname
        local it=items_of[key]
        if it==nil then
          local first=try(function() return g.ghost_prototype.items_to_place_this[1] end)
          local n=first and (type(first.name)=='string' and first.name or first.name and first.name.name)
          it=n and {name=n,count=first.count or 1} or false
          items_of[key]=it
        end
        if it then
          local q=tiles.quality_of(g)
          local k=it.name..'@'..q
          if not need[k] then need[k]={name=it.name,quality=q,count=0}; order[#order+1]=k end
          need[k].count=need[k].count+it.count
        end
      end
    end
    table.sort(order)
    local missing,counted={},{}
    for _,k in ipairs(order) do
      local w=need[k]
      local have=inv.get_item_count{name=w.name,quality=w.quality}
      local label=w.name..(w.quality~='normal' and '@'..w.quality or '')
      if have<w.count then missing[#missing+1]=string.format('%s (ghosts need %s%d, hub has %d)',label,#short>0 and 'at least ' or '',w.count,have) end
      counted[#counted+1]=string.format('%s at least %d, hub has %d',label,w.count,have)
    end
    if #missing>0 then out[#out+1]='ghosts wait for items the hub lacks: '..table.concat(missing,', ')..(#short>0 and ' ('..table.concat(short,'; ')..')' or '') end
    -- Past a cap the hub may hold enough for the ghosts counted and not for the rest: what the counted ones need.
    if #short>0 then out[#out+1]='ghost count capped ('..table.concat(short,'; ')..'): the counted ghosts need '..(#counted>0 and table.concat(counted,', ') or 'nothing') end
    -- Defense ghosts waiting on foundation (Sol 00:21: 173 foundation missing; a spare rocket turret in the hub could not
    -- build): each turret ghost with tiles of empty space under it, those tiles, whether foundation ghosts are planned
    -- there, and the least foundation the hub needs for all of them.
    local line=try(function() return M.defense_waits(pl,lists['entity-ghost'] or {},lists['tile-ghost'] or {},inv) end)
    if line then out[#out+1]=line end
    -- Tile ghosts the foundation rules hold back.
    for _,line2 in ipairs(try(function() return tiles.stalled(pl) end) or {}) do out[#out+1]=line2 end
    return #out>0 and out or nil
  end
  -- Marked foundation tiles: which the hub removes, in turn, and which wait, and why (tilecheck.lua, platformtiles2).
  function M.tile_removals(pl) return tiles.removals(pl) end
  -- inspect of a marked tile or a tile ghost: what holds it.
  function M.tile_note(pl,e) return tiles.note(pl,e) end
  -- When each platform stopped where it is (operator 10:53, Gemini: each stop's
  -- wait with time left): polled once a second from the harness tick and kept
  -- in storage; a stop already under way when the harness first looked has no
  -- arrival tick.
  function M.watch_stops(tick)
    local st=api.state and api.state()
    if not st then return end
    st.platform_stops=st.platform_stops or {}
    local seen={}
    for _,f in pairs(game.forces) do
      for _,pl in pairs(try(function() return f.platforms end) or {}) do
        if pl.valid then
          seen[pl.index]=true
          local here=pl.state==defines.space_platform_state.waiting_at_station and try(function() return pl.space_location.name end) or false
          local r=st.platform_stops[pl.index]
          if not r then st.platform_stops[pl.index]={at=here,first=tick}
          elseif r.at~=here then st.platform_stops[pl.index]={at=here,tick=tick} end
        end
      end
    end
    for index in pairs(st.platform_stops) do if not seen[index] then st.platform_stops[index]=nil end end
  end
  local function secs(t) t=math.max(0,math.floor(t/60+0.5)); return t>=120 and string.format('%dm%02ds',math.floor(t/60),t%60) or t..'s' end
  local function cond_text(c)
    if type(c)~='table' then return '' end
    local first=c.first_signal and c.first_signal.name or '?'
    local right=c.second_signal and c.second_signal.name or tostring(c.constant or 0)
    local cmp=({['≥']='>=',['≤']='<=',['≠']='!='})[c.comparator] or c.comparator or '<'
    return first..' '..cmp..' '..right
  end
  local function compare(a,cmp,b)
    if cmp=='<' then return a<b elseif cmp=='>' then return a>b elseif cmp=='=' then return a==b
    elseif cmp=='>=' or cmp=='≥' then return a>=b elseif cmp=='<=' or cmp=='≤' then return a<=b else return a~=b end
  end
  -- The hub's requests it does not hold yet: "iron-plate 420/1000", most short first.
  local function unmet(pl)
    local hub=pl.hub
    local inv=hub and hub.valid and try(function() return hub.get_inventory(defines.inventory.hub_main) end)
    local secs_=hub and hub.valid and try(function() return hub.get_logistic_sections() end)
    local rows,total={},0
    for i=1,(secs_ and secs_.sections_count or 0) do
      local sec=secs_.get_section(i)
      if sec.active~=false then
        for _,f in ipairs(sec.filters or {}) do
          local v=f.value
          local name=type(v)=='table' and v.name or v
          if name and (f.min or 0)>0 then
            total=total+1
            local n=inv and try(function() return inv.get_item_count({name=name,quality=type(v)=='table' and v.quality or 'normal'}) end) or 0
            if n<f.min then rows[#rows+1]={name=name,n=n,min=f.min} end
          end
        end
      end
    end
    table.sort(rows,function(x,y) return x.min-x.n>y.min-y.n end)
    return rows,total
  end
  -- One wait condition in words; at the stop where the platform waits, how far it is.
  local function wait_text(pl,w,here,arrived)
    local t=w.type or '?'
    local text=t
    if w.ticks then text=t..' '..(w.ticks>=2147483647 and 'the maximum (about 414 days)' or secs(w.ticks)) end
    if w.condition and (t=='item_count' or t=='circuit' or t=='fluid_count') then text=t..' '..cond_text(w.condition) end
    if not here then return text end
    if t=='time' and w.ticks and w.ticks<2147483647 then
      if arrived.tick then text=text..': '..secs(w.ticks-(game.tick-arrived.tick))..' left'
      else text=text..string.format(': waited at least %s (stopped before the harness looked)',secs(game.tick-(arrived.first or game.tick))) end
    elseif t=='inactivity' and w.ticks then
      local last=try(function() return pl.get_schedule().tick_of_last_activity end) or 0
      local since=game.tick-math.max(last,arrived.tick or arrived.first or 0)
      text=text..string.format(': %s without activity, %s left',secs(since),secs(w.ticks-since))
    elseif t=='item_count' and w.condition and w.condition.first_signal and not w.condition.second_signal then
      local c=w.condition
      local hub=pl.hub
      local inv=hub and hub.valid and try(function() return hub.get_inventory(defines.inventory.hub_main) end)
      local n=inv and try(function() return inv.get_item_count({name=c.first_signal.name,quality=c.first_signal.quality or 'normal'}) end) or 0
      local goal=c.constant or 0
      local met=compare(n,c.comparator or '<',goal)
      text=text..string.format(': the hub holds %d%s',n,met and ' (met)' or ((c.comparator=='>=' or c.comparator=='≥' or c.comparator=='>') and string.format(', %d to go',goal-n+((c.comparator=='>') and 1 or 0)) or ''))
    elseif t=='all_requests_satisfied' or t=='any_request_satisfied' or t=='any_request_not_satisfied' or t=='request_satisfied' or t=='request_not_satisfied' then
      local rows,total=unmet(pl)
      local parts={}
      for i=1,math.min(4,#rows) do parts[i]=string.format('%s %d/%d',rows[i].name,rows[i].n,rows[i].min) end
      text=text..string.format(': %d of %d requests unmet%s',#rows,total,#parts>0 and ' ('..table.concat(parts,', ')..(#rows>4 and ', ...' or '')..')' or '')
    end
    return text
  end
  -- Each stop of the schedule: its wait conditions, where the platform waits
  -- (with how far each condition is) or which stop it flies to, and the next one.
  function M.stops(pl)
    local sch=try(function() return pl.schedule end)
    local records=sch and sch.records or {}
    if #records==0 then return nil end
    local cur=sch.current or 1
    local here=try(function() return pl.space_location.name end)
    local waiting=pl.state==defines.space_platform_state.waiting_at_station and records[cur] and records[cur].station==here
    local st=api.state and api.state()
    local arrived=st and st.platform_stops and st.platform_stops[pl.index] or {}
    if arrived.at~=here then arrived={} end
    local nxt=waiting and cur%#records+1 or cur
    local out={}
    for i,rec in ipairs(records) do
      local ws={}
      for k,w in ipairs(rec.wait_conditions or {}) do
        local text=wait_text(pl,w,waiting and i==cur,arrived)
        ws[#ws+1]=(k>1 and (w.compare_type=='or' and 'or ' or 'and ') or '')..text
      end
      local tag=waiting and i==cur and 'waiting here' or (i==nxt and (waiting and 'next' or 'flying to it')) or nil
      out[i]=string.format('%d %s%s: %s',i,rec.station or '?',tag and ' ('..tag..')' or '',#ws>0 and table.concat(ws,' ') or 'no wait condition')
    end
    return out
  end
  -- platforms {compact: true} (Astra 13:50: the full read is long): a line a platform: where, ammunition aboard (hub
  -- and turrets), thruster fuel and its 10-minute trend, the ghosts' missing items in all, and only the blockers this
  -- agent was not shown in its last compact read.
  function M.platforms_compact(p,a)
    local st=api.state and api.state()
    local seen_all=st and st.platforms_compact_seen or {}
    if st then st.platforms_compact_seen=seen_all end
    local mine=seen_all[p.index] or {}
    seen_all[p.index]=mine
    local P=defines.flow_precision_index or {}
    local lines={}
    for _,pl in pairs(p.force.platforms) do
      if pl.valid and (a.platform==nil or pl.name==a.platform) and pl.surface then
        local parts={string.format('%s: %s',pl.name,location(pl) or platform_states[pl.state] or '?')}
        local ammo={}
        local hub=pl.hub
        local inv=hub and hub.valid and try(function() return hub.get_inventory(defines.inventory.hub_main) end)
        for _,s2 in ipairs(inv and try(function() return inv.get_contents() end) or {}) do
          if try(function() return prototypes.item[s2.name].type end)=='ammo' then ammo[s2.name]=(ammo[s2.name] or 0)+s2.count end
        end
        for _,t in ipairs(try(function() return pl.surface.find_entities_filtered{type='ammo-turret',force=pl.force} end) or {}) do
          local ti=try(function() return t.get_inventory(defines.inventory.turret_ammo) end)
          for _,s2 in ipairs(ti and try(function() return ti.get_contents() end) or {}) do ammo[s2.name]=(ammo[s2.name] or 0)+s2.count end
        end
        local al={}
        for n,c in pairs(ammo) do al[#al+1]=n..' '..c end
        table.sort(al)
        parts[#parts+1]='ammo '..(#al>0 and table.concat(al,', ') or 'none')
        local fuel=0
        for _,e in ipairs(try(function() return pl.surface.find_entities_filtered{type={'thruster','storage-tank'},force=pl.force} end) or {}) do
          for i=1,try(function() return #e.fluidbox end) or 0 do
            local f=try(function() return e.fluidbox[i] end)
            if f and f.name=='thruster-fuel' then fuel=fuel+f.amount end
          end
        end
        local fs=try(function() return pl.force.get_fluid_production_statistics(pl.surface) end)
        local function per(cat) return fs and P.ten_minutes and (try(function() return fs.get_flow_count{name='thruster-fuel',category=cat,precision_index=P.ten_minutes,count=true} end) or 0)/10 or 0 end
        local net=per('input')-per('output')
        parts[#parts+1]=string.format('thruster fuel %d units (%s%d/min over 10 min)',math.floor(fuel+0.5),net>=0 and '+' or '',math.floor(net+0.5))
        local blk=try(function() return M.blockers(pl) end) or {}
        local missing=0
        for _,b in ipairs(blk) do
          for need,have in b:gmatch('ghosts need [^%d]*(%d+), hub has (%d+)') do missing=missing+math.max(0,tonumber(need)-tonumber(have)) end
        end
        parts[#parts+1]=missing>0 and string.format('ghosts lack %d items in all',missing) or 'ghosts lack nothing'
        local dep=api.departure and try(function() return api.departure(pl.name) end)
        if dep then parts[#parts+1]='also sent on by '..table.concat(dep,' | ') end
        local was=mine[pl.name] or {}
        local now,new={},{}
        for _,b in ipairs(blk) do now[b]=true; if not was[b] then new[#new+1]=b end end
        mine[pl.name]=now
        local same=#blk-#new
        if #new>0 then parts[#parts+1]='new blockers: '..table.concat(new,' | ') end
        if same>0 then parts[#parts+1]=string.format('%d blocker%s as in your last compact read',same,same==1 and '' or 's') end
        lines[#lines+1]=table.concat(parts,'; ')
      end
    end
    return {compact=true,lines=lines}
  end
  function M.platforms(p,a)
    if a.compact==true then return M.platforms_compact(p,a) end
    local out={platforms={}}
    for _,pl in pairs(p.force.platforms) do
      if pl.valid and (a.platform==nil or pl.name==a.platform) then
        local row={name=pl.name,state=platform_states[pl.state],at=location(pl),paused=pl.paused or nil,
          schedule=schedule_text(pl),stops=try(function() return M.stops(pl) end),departure=api.departure and try(function() return api.departure(pl.name) end) or nil,deleting=pl.scheduled_for_deletion and pl.scheduled_for_deletion>0 or nil,
          weight=pl.weight and math.floor(pl.weight/1000) or nil}
        for k,v in pairs(M.flight(pl) or {}) do row[k]=v end
        local hub=pl.hub
        if hub and hub.valid then
          row.hub=hub.position
          row.hub_items=top_items(hub.get_inventory(defines.inventory.hub_main),a.platform and 64 or 12)
          row.hub_slots=M.hub_slots(hub)
          -- Each spoilable item's spread in the hub and, for a pack the running research takes, how many a unit it
          -- takes and its units left (Sol, 22:52: 1960 agricultural packs aboard Sunward, judged before departure).
          local trash=defines.inventory.hub_trash and try(function() return hub.get_inventory(defines.inventory.hub_trash) end)
          local leg=freight.leg(pl)
          row.freshness=api.fresh_inv and try(function() return api.fresh_inv(pl.force,hub.get_inventory(defines.inventory.hub_main),nil,leg and leg.eta_ticks,trash) end) or nil
          row.hub_chunks=try(function() return M.hub_chunks(hub) end)
          row.hub_trash=trash and top_items(trash,12) or nil
          row.hub_trash_note=row.hub_trash and M.trash_note(pl) or nil
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
        if a.platform then
          detail(pl,row); row.construction_blocked=try(function() return M.blockers(pl) end)
          row.tile_removals=try(function() return M.tile_removals(pl) end)
          -- Its last stops and legs (expected, left, came aboard, spoiled, rockets) and its spoilable items now
          -- against the arrival (Luna, shift12 12:47).
          local fr=try(function() return freight.read(pl) end)
          if fr then row.freight={}; for i,s in ipairs(fr) do row.freight[i]=s.line end end
          row.spoiling=try(function() return freight.freshness(pl) end)
          -- Per ammo type over the last leg, and rockets on their way up to it (freight.lua; Astra, 22:50).
          row.ammo_rates=try(function() return freight.ammo(pl) end)
          local inc=try(function() return freight.incoming(pl) end)
          if inc then row.incoming=inc.lines; row.incoming_cargo=string.format('%d rocket%s on the way: %s',inc.rockets,inc.rockets==1 and '' or 's',inc.cargo) end
          -- Its flight over the last 60 and 180 s (engine.lua; Astra, 21:20).
          local en=api.engine and try(function() return api.engine(pl) end)
          row.engine=en and en.lines or nil
          -- What its thrusters keep burning when their pumps stop, and the thruster's burn as the game runs it
          -- (thrust.lua; Grok, shift17 20:40: a pump cut at V >= 15 and the leg peaked at 51 km/s).
          local ap=api.thrust_after and try(function() return api.thrust_after(pl) end)
          if ap then row.after_pumps=ap.lines; row.thruster_burn=ap.rule end
        end
        out.platforms[#out.platforms+1]=row
      end
    end
    -- Silos on the character's surface: what the launch button would send.
    local silos={}
    for _,e in pairs(p.surface.find_entities_filtered{type='rocket-silo',force=p.force,limit=16}) do
      local cargo=e.get_inventory(defines.inventory.rocket_silo_rocket)
      local trash=defines.inventory.rocket_silo_trash and e.get_inventory(defines.inventory.rocket_silo_trash)
      -- rocket_ready beside parts, and the rocket in words (silo.lua M.rocket; Astra 10:50)
      local okr,rk=pcall(function() return api.rocket and api.rocket(e) end)
      silos[#silos+1]={position=e.position,status=silo_states[e.rocket_silo_status],
        parts=not (okr and rk and rk.next_parts) and e.rocket_parts..'/'..e.prototype.rocket_parts_required or nil,
        built_parts=okr and rk and rk.built_parts or nil,next_parts=okr and rk and rk.next_parts or nil,
        rocket_ready=e.rocket_silo_status==defines.rocket_silo_status.rocket_ready,rocket=okr and rk and rk.rocket or nil,
        cargo=cargo and top_items(cargo,8) or nil,
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
    if api.chronicle_created then pcall(api.chronicle_created,pl,p.name) end  -- who made it (chronicle.lua)
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
  local EMPTY_LOOK=32   -- tiles around a silo searched for science when a launch with no cargo is refused
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
    -- Not ready: the rocket in words (silo.lua M.rocket), so a rising rocket's count reads as the rocket after it's
    -- (shift14 21:20: Grok); a rocket being built names its parts.
    if silo.rocket_silo_status~=defines.rocket_silo_status.rocket_ready then
      local okr,rk=pcall(function() return api.rocket and api.rocket(silo) end)
      error('rocket is not ready: '..tostring(silo_states[silo.rocket_silo_status])..', '..(okr and rk and rk.rocket_now
        or 'parts '..silo.rocket_parts..'/'..silo.prototype.rocket_parts_required)
        ..'; launch {wait_ready: true} waits for it (a queue step too), as does a wait_until {until: "rocket_ready", position} step before it',0)
    end
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
        if items and not items.is_empty() then
          local held={}
          for _,c in ipairs(try(function() return items.get_contents() end) or {}) do if #held<6 then held[#held+1]=tostring(c.name)..'*'..tostring(c.count) end end
          -- Ammo in the ammo slots (Grok, d15: a ride refused, and nothing said how to clear them).
          local how=inv=='character_ammo' and 'equip {slot: "ammo", unequip: true} moves them to your main inventory; a transfer {position, direction: "to_entity", item} into a chest takes from the ammo slots too'
            or 'ship it as rocket cargo, or put it in a chest'
          error(string.format('only armor and guns travel with the rider: %s holds %s; %s',inv,table.concat(held,' '),how),0)
        end
      end
    end
    local destination,to,pl
    if a.platform~=nil then
      pl=M.platform(p,a.platform)
      local here=p.surface.planet and p.surface.planet.name
      assert(pl.space_location and pl.space_location.name==here,'platform '..pl.name..' is not in orbit of '..tostring(here)..' (at '..tostring(location(pl))..'); launch {wait_platform: true} waits for it and launches then')
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
    -- An empty rocket spends its parts for nothing (Sol, 06:29: Luna launched empty at 36h46 while bio science sat in
    -- a chest nearby): refused unless allow_empty is true or a rider is the payload; the refusal names the science
    -- packs in chests within EMPTY_LOOK tiles of the silo.
    assert(a.allow_empty==nil or type(a.allow_empty)=='boolean','allow_empty must be boolean')
    if cargo==nil and not a.ride and a.allow_empty~=true then
      local near={}
      for _,c in ipairs(try(function() return silo.surface.find_entities_filtered{position=silo.position,radius=EMPTY_LOOK,type={'container','logistic-container'},force=silo.force,limit=64} end) or {}) do
        local inv=c.valid and try(function() return c.get_inventory(defines.inventory.chest) end)
        for _,s in ipairs(inv and try(function() return inv.get_contents() end) or {}) do
          if try(function() return prototypes.item[s.name].type end)=='tool' and #near<6 then
            near[#near+1]=string.format('%s (%g,%g) %s*%d',c.name,c.position.x,c.position.y,s.name,s.count)
          end
        end
      end
      error('launch refused: the rocket holds nothing, and launching spends its parts; load cargo with transfer {position, direction=to_entity, inventory=rocket_silo_rocket, item, count}, or allow_empty=true to launch it empty'
        ..'; science in chests within '..EMPTY_LOOK..' tiles: '..(#near>0 and table.concat(near,', ') or 'none'),0)
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
    -- The cargo's spread, read before it goes (Sol, 22:52).
    local fresh=api.fresh_inv and try(function() return api.fresh_inv(p.force,silo.get_inventory(defines.inventory.rocket_silo_rocket)) end) or nil
    -- spoiled_percent (A11, Grok): each spoilable item's spoiled share by count, at the top of the reply
    local spoiled,went_up
    if api.fresh_percent then pcall(function() spoiled,went_up=api.fresh_percent(silo.get_inventory(defines.inventory.rocket_silo_rocket)) end) end
    if not silo.launch_rocket(destination,rider) then error(refused(silo,pl,destination),0) end
    return {launched=true,to=to,cargo=cargo or 'empty',spoiled_percent=spoiled,went_up=went_up,freshness=fresh,riding=rider and 'the character rides along (~40 s); actions fail until it sits in the hub: poll status (platform, riding)' or nil,
      auto_requests=switched and switched.auto_requests,cargo_to_trash=switched and switched.cargo_to_trash,note=switched and switched.note}
  end
  -- The hub's drop slots: items from the hub inventory go down to the planet
  -- below a stopped platform in cargo pods, to the force's landing pad there,
  -- else near position (default: a bot's last spot there, else the spawn
  -- point), where a pod lands as a temporary container to empty by hand.
  -- Checked on 2.0.77: a pod holds 10 slots and no weight limit (the
  -- cargo-pod prototype's inventory_size; the prototype API does not give
  -- it), and the hub sends one pod per output hatch (3 on a hub), each hatch
  -- free again 120 ticks after its pod. The list splits into pods in its own
  -- order (cargo.lua pods): without full the first pod goes and the reply says
  -- what stays in the hub (short); full=true sends every pod, the ones waiting
  -- for a free hatch as a timed action (Astra, shift09: a Gleba kit took three
  -- calls, and the first partial drop read as complete).
  local POD_SLOTS,HATCH_TICKS=10,120
  local function drop_args(p,a)
    local own=p.surface and p.surface.platform
    local pl=M.platform(p,a.platform or (own and own.name))
    assert(pl.hub and pl.hub.valid,'platform '..pl.name..' has no hub yet')
    local loc=pl.space_location
    assert(loc and loc.type=='planet','platform '..pl.name..' is not stopped at a planet (at '..tostring(location(pl))..')')
    assert(type(a.items)=='table' and #a.items>=1 and #a.items<=20,'items requires 1..20 {item,count,quality?}')
    assert(a.full==nil or type(a.full)=='boolean','full must be true or false')
    assert(a.dry_run==nil or type(a.dry_run)=='boolean','dry_run must be true or false')
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
    return pl,loc,want
  end
  local function label(name,quality) return name..(quality and quality~='normal' and '@'..quality or '') end
  local function items_text(list)
    local parts={}
    for _,w in ipairs(list) do if w.count>0 then parts[#parts+1]=label(w.name,w.quality)..'*'..w.count end end
    return table.concat(parts,' ')
  end
  local function output_hatches(hub)
    local n=0
    for _,h in ipairs(try(function() return hub.cargo_hatches end) or {}) do
      if try(function() return h.is_output_compatible end) then n=n+1 end
    end
    return n
  end
  -- Up to n of an item from the hub's stacks into a pod's cargo, the hub's
  -- own stacks: a whole stack by transfer_stack (into a part stack of the
  -- same item first, then an empty slot), the last part of one as a copy
  -- with its spoil progress, taken off the hub stack. Returns the count moved.
  local function fill(hub_inv,cargo,name,quality,n)
    local need=n
    local function same(st) return st.valid_for_read and st.name==name and (st.quality and st.quality.name or 'normal')==quality end
    for i=1,#hub_inv do
      if need<=0 then break end
      local st=hub_inv[i]
      if same(st) then
        if st.count<=need then
          local before=st.count
          for j=1,#cargo do
            if not st.valid_for_read then break end
            local c=cargo[j]
            if same(c) and c.count<c.prototype.stack_size then c.transfer_stack(st) end
          end
          if st.valid_for_read then
            local slot=cargo.find_empty_stack()
            if slot then slot.transfer_stack(st) end
          end
          local after=st.valid_for_read and st.count or 0
          need=need-(before-after)
          if after>0 then break end
        else
          local def={name=name,quality=quality,count=need}
          local spoil=try(function() return st.spoil_percent end)
          if spoil and spoil>0 then def.spoil_percent=spoil end
          local moved=cargo.insert(def)
          if moved>0 then st.count=st.count-moved; need=need-moved end
          if moved<def.count then break end
        end
      end
    end
    return n-need
  end
  -- Sends the job's next pods while the hub has a free hatch (at most limit).
  -- Items the hub no longer holds go to job.short; what did not fit in its
  -- pod goes on to the next one.
  local function send(p,job,limit)
    local pl=job.platform
    local hub=pl.hub
    local hub_inv=hub.get_inventory(defines.inventory.hub_main)
    local n=0
    while #job.pods>0 and (not limit or n<limit) do
      -- What the hub still holds of the next pod's items (inserters and
      -- construction take from the hub meanwhile).
      local takes,any={},false
      for i,w in ipairs(job.pods[1].items) do
        local have=hub_inv.get_item_count{name=w.name,quality=w.quality}
        takes[i]=math.min(have,w.count)
        any=any or takes[i]>0
      end
      local pod=any and try(function() return hub.create_cargo_pod() end)
      if any and not (pod and pod.valid) then break end
      local plan=table.remove(job.pods,1)
      local cargo=pod and pod.get_inventory(defines.inventory.cargo_unit)
      local sent,carry={},{}
      for i,w in ipairs(plan.items) do
        if takes[i]<w.count then job.short[#job.short+1]={name=w.name,quality=w.quality,count=w.count-takes[i]} end
        local moved=takes[i]>0 and fill(hub_inv,cargo,w.name,w.quality,takes[i]) or 0
        if moved>0 then sent[#sent+1]={name=w.name,quality=w.quality,count=moved} end
        if moved<takes[i] then carry[#carry+1]={name=w.name,quality=w.quality,count=takes[i]-moved} end
      end
      if #carry>0 then table.insert(job.pods,1,{items=carry}) end
      if pod and cargo.is_empty() then pod.destroy(); error('nothing fit in the cargo pod',0) end
      if pod then
        -- A refused destination puts the items back in the hub, never strands
        -- them; what the hub cannot take back stays in the pod, which is kept.
        if not pcall(function() pod.cargo_pod_destination=job.dest end) then
          local kept={}
          for i=1,#cargo do
            local st=cargo[i]
            if st.valid_for_read then
              local back=hub_inv.insert(st)
              if back>=st.count then st.clear() else st.count=st.count-back; kept[#kept+1]=st.name..'*'..st.count end
            end
          end
          if #kept==0 then pod.destroy() end
          error('the game refused the cargo pod destination '..job.surface..(#kept==0 and '; the items stay in the hub'
            or '; the hub took back all but '..table.concat(kept,' ')..', which stay in the cargo pod on the hub'),0)
        end
        -- Followed until it lands (drops.lua): where it came down goes to the
        -- sender's and the `to` teammates' team block.
        local text={}
        for _,w in ipairs(sent) do text[#text+1]=label(w.name,w.quality)..'*'..w.count end
        local used=0
        for i=1,#cargo do if cargo[i].valid_for_read then used=used+1 end end
        local id=api.drops and api.drops.record(p,{pod=pod,platform=pl.name,surface=job.surface,pad=job.pad,near=job.dest.position,sent=text,to=job.to})
        job.sent[#job.sent+1]={pod=#job.sent+1,drop=id,items=table.concat(text,' '),slots=used}
        for _,w in ipairs(sent) do
          local k=w.name..'@'..w.quality
          job.moved[k]=(job.moved[k] or 0)+w.count
        end
        n=n+1
      end
    end
    return n
  end
  local function landing(p,a,surface)
    local pad=surface.find_entities_filtered{type='cargo-landing-pad',force=p.force,limit=1}[1]
    local dest={type=defines.cargo_destination.surface,surface=surface}
    if not pad then
      local b=api.bot and api.bot(p)
      dest.position=a.position~=nil and api.position(a.position) or (b and b.spots and b.spots[surface.name]) or p.force.get_spawn_position(surface)
    end
    return pad,dest
  end
  local function moved_list(job,want)
    local out={}
    for _,w in ipairs(want) do
      local n=job.moved[w.name..'@'..w.quality] or 0
      if n>0 then out[#out+1]=label(w.name,w.quality)..'*'..n end
    end
    return out
  end
  local function short_text(job)
    if #job.short==0 then return nil end
    return 'the hub held less than asked: '..items_text(job.short)..' not sent'
  end
  -- A landing pad's room for what a drop sends (Astra, shift12 13:50: 773 electromagnetic science packs spilled once;
  -- 43 asteroid chunks had taken 43 slots): its slots up to the red-X limit, the free ones, what takes the others, and
  -- what of items would not fit (each item into partial stacks of its own first, then into free slots, in order) and
  -- so lands on the ground around the pad. nil without a pad inventory.
  function M.pad_room(pad,items)
    local ok,inv=pcall(function() return pad.get_inventory(defines.inventory.cargo_landing_pad_main) end)
    if not (ok and inv) then return nil end
    local slots=#inv
    local usable=slots
    local okb,bar=pcall(function() return inv.supports_bar() and inv.get_bar() end)
    if okb and type(bar)=='number' and bar<=slots then usable=bar-1 end
    local by,order,room,free={},{},{},0
    local function size(name) local it=prototypes.item[name]; return it and it.stack_size or 1 end
    for i=1,usable do
      local s=inv[i]
      if s.valid_for_read then
        local q=s.quality and s.quality.name or 'normal'
        local key=s.name..'@'..q
        local b=by[key]
        if not b then b={name=s.name,quality=q,slots=0,count=0}; by[key]=b; order[#order+1]=b end
        b.slots=b.slots+1; b.count=b.count+s.count
        room[key]=(room[key] or 0)+math.max(0,size(s.name)-s.count)
      else free=free+1 end
    end
    table.sort(order,function(x,y) return x.slots>y.slots or (x.slots==y.slots and x.name<y.name) end)
    local taken={}
    for i,b in ipairs(order) do
      if i<=6 then taken[i]=string.format('%s %d slot%s (%d)',label(b.name,b.quality),b.slots,b.slots==1 and '' or 's',b.count) end
    end
    if #order>6 then taken[#taken+1]=string.format('+%d more items',#order-6) end
    -- The drop's items, the same item in several pods counted once.
    local merged,korder={},{}
    for _,w in ipairs(items) do
      local key=w.name..'@'..(w.quality or 'normal')
      if not merged[key] then merged[key]={name=w.name,quality=w.quality or 'normal',count=0}; korder[#korder+1]=key end
      merged[key].count=merged[key].count+w.count
    end
    local left,need,spill,spills=free,0,0,{}
    for _,key in ipairs(korder) do
      local w=merged[key]
      local n=w.count
      local r=math.min(n,room[key] or 0); n=n-r
      local stacks=math.ceil(n/size(w.name))
      need=need+stacks
      local fit=math.min(stacks,left)
      left=left-fit
      local over=math.max(0,n-fit*size(w.name))
      if over>0 then spill=spill+over; spills[#spills+1]=label(w.name,w.quality)..'*'..over end
    end
    local head=string.format('landing pad (%g,%g): %d of %d slots free%s',pad.position.x,pad.position.y,free,usable,
      #taken>0 and ' (taken: '..table.concat(taken,', ')..')' or '')
    local slots_word=need==1 and 'slot' or 'slots'
    local tail=spill>0 and string.format('this drop needs %d new %s: %s would not fit and land on the ground around the pad',need,slots_word,table.concat(spills,' '))
      or string.format('this drop needs %d new %s: it fits, %d free after',need,slots_word,left)
    return {slots=usable,free=free,taken=taken,needs=need,spill=spill,spills=#spills>0 and spills or nil,line=head..'; '..tail}
  end
  local LANDS_NOTE='lands in ~20 s as a cargo pod container, often 10-20 tiles from that spot (pods scatter): your next reply\'s team block says where (drops lists them); take the items with transfer (it vanishes when empty)'
  function M.drop(p,a)
    local pl,loc,want=drop_args(p,a)
    -- up_to (Astra, twice: automatic pad requests emptied the hub just before a queued drop, which failed and paused the
    -- route): drop what the hub holds now of each, up to its count; holding none of any, the drop is done with nothing sent.
    assert(a.up_to==nil or type(a.up_to)=='boolean','up_to must be true or false')
    local up_to_note
    if a.up_to then
      local hub_inv=pl.hub.get_inventory(defines.inventory.hub_main)
      local kept,cut={},{}
      for _,w in ipairs(want) do
        local have=hub_inv.get_item_count{name=w.name,quality=w.quality}
        if have<w.count then cut[#cut+1]=string.format('%s %d of %d',label(w.name,w.quality),have,w.count) end
        if have>0 then kept[#kept+1]={name=w.name,quality=w.quality,count=math.min(w.count,have)} end
      end
      up_to_note=#cut>0 and 'up_to: the hub held '..table.concat(cut,', ') or nil
      if #kept==0 then
        return {dropped={},nothing_to_drop=true,dry_run=a.dry_run or nil,platform=pl.name,to=loc.name,up_to=up_to_note,
          note='the hub holds none of the items now (up_to): nothing sent; the drop is done'}
      end
      want=kept
    end
    local pending=a.full and not a.dry_run and api.pending and api.pending(p)
    assert(not pending,pending and string.format('your last full drop from %s still has %d pod%s waiting for a hatch (status drop_pending); it ends by itself',
      pending.platform.valid and pending.platform.name or '?',#pending.pods,#pending.pods==1 and '' or 's'))
    local hub_inv=pl.hub.get_inventory(defines.inventory.hub_main)
    local split=api.cargo.pods(want,POD_SLOTS)
    local planet=game.planets[loc.name]
    if a.dry_run then
      local held={}
      for _,w in ipairs(want) do
        local have=hub_inv.get_item_count{name=w.name,quality=w.quality}
        if have<w.count then held[#held+1]=string.format('%s: the hub holds %d of %d',label(w.name,w.quality),have,w.count) end
      end
      local surface=planet.surface
      local pad=surface and surface.find_entities_filtered{type='cargo-landing-pad',force=p.force,limit=1}[1]
      local rows={}
      for i,pod in ipairs(split.pods) do rows[i]=string.format('pod %d (%d slots): %s',i,pod.slots,pod.text) end
      local hatches=output_hatches(pl.hub)
      -- The pad's room for what would go (pod 1, or every pod with full; what the hub holds of each).
      local list,has={},{}
      for _,pod in ipairs(a.full and split.pods or {split.pods[1]}) do
        for _,w in ipairs(pod.items) do
          local key=w.name..'@'..w.quality
          has[key]=has[key] or hub_inv.get_item_count{name=w.name,quality=w.quality}
          local n=math.min(w.count,has[key])
          has[key]=has[key]-n
          if n>0 then list[#list+1]={name=w.name,quality=w.quality,count=n} end
        end
      end
      local room=pad and M.pad_room(pad,list)
      -- The hub's stacks of the items to drop: their spread (the drop takes stacks in the hub's order).
      local names={}
      for _,w in ipairs(want) do names[w.name]=true end
      local fresh=api.fresh_inv and try(function() return api.fresh_inv(pl.force,hub_inv,names) end) or nil
      return {dry_run=true,note='nothing was sent',platform=pl.name,to=loc.name,pad=pad and pad.position or nil,freshness=fresh,
        pad_room=room and room.line or (not pad and 'no landing pad of ours on '..loc.name..': the pods land as cargo pod containers' or nil),
        pad_free=room and room.free or nil,spill=room and room.spill>0 and room.spill or nil,
        pods=rows,pod_slots=string.format('a cargo pod holds %d slots (no weight limit); the list takes %d stacks',POD_SLOTS,split.stacks),
        hatches=hatches>0 and string.format('%d output hatches: up to %d pods leave at once, each hatch sends its next %d s after its last',hatches,hatches,HATCH_TICKS/60) or nil,
        sends=#split.pods>1 and string.format('without full only pod 1 goes (the rest stay in the hub); full: true sends all %d pods',#split.pods) or nil,
        short=#held>0 and held or nil}
    end
    for _,w in ipairs(want) do
      local have=hub_inv.get_item_count{name=w.name,quality=w.quality}
      assert(have>=w.count,'the hub of '..pl.name..' holds '..have..' '..label(w.name,w.quality)..', not '..w.count)
    end
    local to=api.drops and api.drops.recipients(a.to) or {}
    local surface=planet.surface or planet.create_surface()
    local pad,dest=landing(p,a,surface)
    -- The pad's room, read before anything is sent (the dry run says the same).
    local room
    if pad then
      local list={}
      for _,pod in ipairs(a.full and split.pods or {split.pods[1]}) do for _,w in ipairs(pod.items) do list[#list+1]=w end end
      local ok,r=pcall(M.pad_room,pad,list)
      room=ok and r or nil
    end
    local total=#split.pods
    local job={kind='drop',platform=pl,planet=loc.name,surface=surface.name,pad=pad and pad.position or nil,dest=dest,to=to,
      pods=split.pods,sent={},short={},moved={},want=want,full=a.full==true}
    send(p,job,not job.full and 1 or nil)
    if #job.sent==0 and not job.full then
      assert(#job.pods==0,'the hub has no free cargo hatch right now (each sends one pod every '..(HATCH_TICKS/60)..' s); full: true waits for one')
      error('nothing fit in the cargo pod',0)
    end
    local out={drop=job.sent[1] and job.sent[1].drop or nil,dropped=moved_list(job,want),to=surface.name,pad=job.pad,near=dest.position,
      tell=#to>0 and to or nil,note=pad and 'lands in the landing pad in ~20 s' or LANDS_NOTE,pad_room=room and room.line or nil,
      spill=room and room.spill>0 and room.spill or nil}
    if job.full or #job.sent>1 then out.pods=job.sent end
    local left={}
    for _,pod in ipairs(job.pods) do for _,w in ipairs(pod.items) do left[#left+1]=w end end
    if not job.full and #left>0 then
      out.short=string.format('not sent, still in the hub: %s (a cargo pod holds %d slots and the list takes %d pods; full: true sends them all)',
        items_text(left),POD_SLOTS,total)
    elseif #left>0 then
      -- full: the rest go as hatches free up (runtime drop_jobs_tick).
      job.until_tick=game.tick+HATCH_TICKS*(#job.pods+1)+600
      api.start(p,job)
      out.pods_waiting=string.format('%d more pod%s wait for a free hatch (each sends one every %d s): %s; your character and queue go on; status drop_pending shows them, --wait waits for them',
        #job.pods,#job.pods==1 and '' or 's',HATCH_TICKS/60,items_text(left))
      out.until_tick=job.until_tick
    end
    out.short=out.short or short_text(job)
    out.up_to=up_to_note
    return out
  end
  -- A full drop's pods that wait for a hatch (runtime drop_jobs_tick, every
  -- 10 ticks): nil while some wait; dropped | short | failed when done.
  function M.drop_tick(p,job)
    local pl=job.platform
    if not (pl and pl.valid and pl.hub and pl.hub.valid) then job.why='the platform or its hub is gone'; return 'failed' end
    local loc=pl.space_location
    if not (loc and loc.name==job.planet) then
      job.why='platform '..pl.name..' left '..job.planet..' (at '..tostring(location(pl))..')'
      return 'failed'
    end
    local ok,err=pcall(send,p,job)
    if not ok then job.why=tostring(err); return 'failed' end
    if #job.pods>0 then return nil end
    job.why=short_text(job)
    return #job.short>0 and 'short' or 'dropped'
  end
  -- What a finished drop reports (runtime finish): each pod's contents, what
  -- went, what was not sent and why.
  function M.drop_result(job,outcome)
    local left={}
    for _,pod in ipairs(job.pods or {}) do for _,w in ipairs(pod.items) do left[#left+1]=w end end
    local why=job.why
    if not why and #left>0 then
      why=string.format('%d pod%s not sent (%s): %s',#job.pods,#job.pods==1 and '' or 's',outcome,items_text(left))
    end
    return {pods=job.sent,dropped=moved_list(job,job.want or {}),not_sent=#left>0 and items_text(left) or nil,short=short_text(job),to=job.surface},why
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
      set='array of {item,min,max? (omitted: the slot\'s max is kept while at least min; "inf": none),quality?,from? (planet to import from, platform hubs; omitted: the planet the slot already has is kept),min_payload? (platform hubs: the GUI\'s custom minimum payload for the request, minimum_delivery_count; omitted: the slot\'s is kept; false clears it). Seen on 2.0.77 above Fulgora: with min_payload 10 and min 50, automatic silos sent rockets of 28, 10 and 12 stone, 50 in all; with none, one full rocket (100 concrete for a min of 50). min is how much the hub asks for; min_payload how little a rocket may carry for it} (a map {item: min} runs as that list); replaces that item\'s slot',clear='array of item names whose request slot is deleted (what is held stays)',remove='the same as clear',force='true: set a personal max under what you hold (the game moves the rest to your trash); without it such a set is refused',clear_all='boolean: empty the section first',section='1-based section index (default the first manual ungrouped section, created if none)',
      active='boolean: switch the section on or off (the GUI\'s checkbox; a section that is off requests nothing)',
      construction_requests='platform hub: boolean, the hub\'s Request missing construction materials (on: the game keeps a section requesting what the platform\'s ghosts need; a paste of a hub blueprint that has it off switches it off, and paste switches it back on)',
      returns='target, sections [{index, group, off (switched off: its requests are not made), controlled (set by the game, not editable), requests ["item min..max from planet", "item=n from planet"]}], changed_section (only when a slot was set or cleared or the section switched; else unchanged), stored (each item this call set or cleared, as read back from its slot: "processing-unit 0..400 from vulcanus (import planet kept: not named in this edit) (was 0..200 from vulcanus)", "coal: cleared (was coal=500 from vulcanus)"), note (sections that are off but hold requests); on a platform hub: construction_requests (on: its controlled section lists what the ghosts need), construction_overlap (items a manual section requests too: the hub requests the sum), over_max (a max set in this call under what the hub holds), hub_trash, trash_note (where the game sends the trash); call with no set/clear/active to just read'},
    platform={platform='optional platform name (or name): the platforms read of that one (as platforms {platform}); none: every platform',name='the same as platform',compact='as platforms',returns='as platforms'},
    platforms={eta_to='optional planet name: each platform\'s ETA to it through its schedule (the leg it flies at its cruise speed, its stops\' waits and what an agent\'s queue or order sends it on with, the legs between), or why there is none (no schedule, paused, it does not go there); eta_to lines and on each row {planet, eta_s, line}',departure='returned on each platform: the agents\' queue steps and standing orders that set its schedule (platform_schedule), each with the wait before it, beside the schedule\'s own waits (stops)',compact='true: a line a platform: where it is, ammunition aboard (hub and turrets), thruster fuel and its net trend over 10 min, how many items its ghosts lack in all, and only the blockers you were not shown in your last compact read (the rest counted)',platform='optional name: only this one, with its full hub inventory, speed (the game\'s value, km per tick), damaged up to 10 (the game repairs platform entities itself with the hub\'s repair packs, one at a time), damaged_tiles, asteroid_chunks on the platform surface by type, thrusters (count, lowest fuel/oxidizer tank), thrust_inputs (a line per thruster input under half full: the pumps, tanks and machines behind it and why they stop, down to the hub\'s asteroid chunks), unbuilt_ghosts, construction_blocked (why the hub cannot build or deconstruct now: hub full, ghosts whose items the hub lacks, tile ghosts the foundation rules hold back: one that would split the empty space beside it (the hub looks at a tile\'s 8 neighbours), with the hole on one side that has no ghosts, or one with no foundation among the 8 tiles round it), tile_removals (the marked foundation tiles: marked, go (those the hub removes, one at a time, in order), waiting (each with why, as deconstruct says it)), hub_inserters_without_target (inserters taking from the hub with nothing to drop into, and the tile they drop onto), thrown_overboard (items in flight off the platform), consumed_10min and produced_10min (the game\'s item statistics for the platform surface), freight (its last 6 stops and legs, newest first: per stop what the planet\'s landing pads asked of the hub on arrival (expected down), what the hub asks from that planet (expected up), what left the hub and came aboard (net over the stop), what spoiled aboard, rockets launched to it with their cargo, the cargo pods sent down with what each landing pad received, those that landed with no pad, and those still in flight (unit numbers, cargo); per leg the spoilable items aboard at departure, spoiled on the way and at arrival), spoiling (the hub\'s spoilable items: the first stack to spoil and its share; in flight how many spoil before the arrival and when the next spoils after it; spoilable science effective research units now and at the current-speed leg ETA, before lab bonuses), freshness (on every row: spoilable science effective research units now and, when the leg ETA is known, at arrival (before lab bonuses); the hub\'s spoilable items, each one\'s spread as inspect gives it, and for a pack the running research takes how many a unit the running research takes and its units left), engine (the last 60 and 180 s, sampled each second: speed mean, lowest, highest, first and last; each thruster fluid used and made by the surface\'s fluid statistics and in the thrusters\' tanks at start and end; the pumps\' share of time working), ammo_rates (per ammo type held or made or used: made and used a minute over the last leg from the surface\'s item statistics (used: turret shots and ammo crafted into other items), the hub\'s main inventory and the turrets now; in flight the reserve at the arrival at that rate, or when it runs out first; a leg begun before the runtime counted: the last 10 min), incoming (rockets launched to its hub whose cargo pod has not arrived: from, how long ago, cargo, rising or coming down) and incoming_cargo',returns='platforms [{name, state, at (the location where it is stopped; a location it is still on its path at says so; in flight the leg as flown, from->to with the share flown), speed_kms, next_stop (the stop it flies to; waiting at a stop, the one after), on a route leg (as flown), heading_to, leg_km, leg_left_km, eta_min (at the current speed), schedule, stops (each stop with its wait conditions: waiting here with how far each is (time left, inactivity, the hub\'s count for item_count, unmet requests), flying to it, next), hub, hub_items, hub_slots (free of all), hub_chunks (hub slots asteroid chunks take, one a slot), hub_trash, hub_trash_note (where the game sends the trash: kept in flight; at a planet stop down in cargo pods to its landing pad, or with none as cargo-pod containers near (0,0)), requests, requests_off (in hub sections switched off: not requested), leave_ok, defense {hub_health, turrets (count: empty, low under 10 rounds), ammo (rounds the turrets hold against the ammo in the hub)}, repair_packs, damaged (most damaged first: 3, or 10 with platform; damaged_count when more)}], silos on this surface {position, status, parts, cargo}, planet'},
    platform_create={name='optional platform name',planet='default the character\'s planet',starter_pack='default space-platform-starter-pack',note='like the platform GUI: the platform waits for its starter pack; a silo holding one in its rocket cargo launches it on its own'},
    platform_schedule={platform='name',stops='array of {station=planet, wait=[{type=all_requests_satisfied|any_request_zero|time|inactivity|..., ticks?, compare=and|or}]}; [] clears',current='1-based stop to head for (default 1)',paused='boolean: pause/unpause thrust and the schedule (paused on a route, the platform stays among its asteroids and drifts back; the reply\'s note says so)'},
    drop={up_to='optional true: drop what the hub holds now of each item, up to its count (up_to says what it held); holding none of any, the drop is done with nothing sent (nothing_to_drop), a queue step too',platform='platform name (default: the one you are aboard)',items='array of 1..20 {item,count,quality?} from the hub inventory',position='optional {x,y} to land near when the planet has no landing pad of ours (default: a bot\'s last spot there, else the spawn point)',to='optional teammate name or list: told where it landed too, in their team block',
      full='true: send every pod the list takes (a pod holds 10 slots); pods beyond the free hatches go as each hatch frees up (one every 2 s) while your character and queue go on (status drop_pending, then last_drop: outcome dropped | short | failed | timed_out; --wait waits for them). Without it only the first pod goes and short says what stays in the hub',
      dry_run='true: send nothing; the pod split (each pod\'s items, in the list\'s order), freshness (the hub\'s stacks of those items: their spread, and how many a unit the running research takes and its units left), the hatches, what the hub holds less of, and the landing pad\'s room for what would go (pod 1, or every pod with full): pad_room (its free slots of its slots up to the red-X limit, what takes the others, the new slots the drop needs, and what would not fit and land on the ground around the pad), pad_free, spill (items); a real drop reports pad_room and spill too, read before it sends',
      note='the hub\'s drop slots, from remote view: cargo pods take the items to the planet below a stopped platform (the landing pad if any, else a temporary container on the ground)',returns='drop (the first pod\'s number), dropped, pods [{pod, drop, items, slots}] (full, or more than one), short (what stays in the hub), pods_waiting and until_tick (full: pods waiting for a hatch), to, pad, near, tell; where each pod lands comes in the team block (drop #N landed at (x,y) on PLANET: cargo-pod-container with ...), and the drops read lists recent drops'},
    land={note='from a platform stopped at a planet: drop to that planet in a cargo pod (to a landing pad if any). A bot lands where it last stood on that planet, else at its spawn point, wearing the armor and guns it rode up with',returns='landing (and for a bot: at, pad)'},
    launch={wait_ready='optional true (Muse: queued launches failed at 45/50 parts): a rocket not ready yet is waited for (a timed wait, rocket_ready at the silo, as wait_until; a queue step holds there) and launched in the tick it is ready; last.launch holds the launch reply (launch_failed and last.launch_error when the launch is then refused); timeout: 1..54000 ticks (default 36000). Ready already: it launches at once. As a direct call it refuses while an action runs',
      timeout='with wait_ready or wait_platform: 1..54000 ticks to wait (default 36000)',
      cargo_for='"any": launch even when the cargo aboard was loaded (load_silo) for another platform; without it such a launch is refused, naming both',
      wait_platform='optional true (the default with wait_ready and platform; false: the rocket alone), with platform (B2, Grok: a sleep chained into launch ended on a tell and the launch failed): the platform is waited for until it is stopped in orbit of the silo\'s planet (as platform_arrived reads it), and with wait_ready the rocket too, both in one timed wait (until all); then it launches in that tick. A tell does not end it (one with wake: true and an urgent alert do: then nothing launches, outcome not_launched). Already there (and ready): it launches at once',
      position='rocket silo {x,y} in a visible chunk (any tile of it)',surface='optional planet name: the silo there by remote view, where our force sees the chunk (e.g. vulcanus from a platform above it); platform stays the destination',ride='true: the character boards the rocket (stand within reach of the silo) and arrives in the platform hub; needs platform; the rocket must hold no cargo and the character nothing but worn armor and guns (ship the rest as cargo first). Bots ride too: aboard they have no body and act by remote view (platforms, platform_schedule, requests, ghost tools with platform=, research, chat) until they land',platform='send the rocket cargo to this platform in orbit of this planet',orbit='true: launch with no platform (cargo lost unless it has launch products)',allow_empty='true: launch a rocket with no cargo; without it an empty rocket is refused (launching spends its parts), the refusal naming science packs in chests within 32 tiles of the silo',
      min_cargo='optional {"item-name": count} or [{"item", "count", "quality"}]: launch only when the rocket holds at least these, read in the tick it launches (a queue step\'s launch runs whole in its tick); else refused, nothing launched, naming what is short and what the rocket holds (checked {tick, lines} in the reply)',
      arrived='optional true, with platform: launch only when the platform is stopped at this planet (not on its path), by the platform_arrived rule, read in the tick it launches; else refused, nothing launched',auto_requests='boolean: the silo GUI setting to fill and launch rockets on its own for platforms\' requests in orbit (alone: only sets it; switched on with cargo loaded by hand, the game moves that cargo to the silo\'s trash slots: cargo_to_trash, note, trash)',returns='launched, to, cargo, spoiled_percent {item: its spoiled share by count} and went_up (a line: each spoilable item, its count and share), freshness (the cargo\'s spoilable items, each one\'s spread and how many a unit the running research takes and its units left, read before it goes); checked {tick, lines} (min_cargo, arrived); settings {silo, auto_requests, send_to_orbit_automatically, requesting_for, rocket, parts}: the silo\'s switches after the call',refused='overweight by N kg (a rocket lifts 1000 kg; the cargo listed by weight) before the game is asked; when the game refuses, what it may check'},
  }
  return M
end
