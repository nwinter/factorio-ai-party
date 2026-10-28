-- Space Age logistics through the same GUIs a player has: logistic request
-- slots (character, chests, landing pads, platform hubs), the space platform
-- list (create, schedule, pause), and the rocket silo launch button. Platforms
-- are always shown in remote view, so none of this needs the character there.
local qflow=require('qflow')   -- (d24 batch152 PX1) statistics read at every quality
return function(api)
  local M={}
  -- (d25 batch208 QU1) the most a call takes, also a queue step's check (runtime.lua step_lengths)
  M.KEEP_MAX,M.SET_MAX,M.NAME_MAX,M.STOPS_MAX,M.DROP_ITEMS=50,100,64,32,20
  -- a signal's name, with @quality when not normal (d22 batch87 AW1: an uncommon signal read as the normal one)
  local function sigtext(s) local q=s.quality; if q and type(q)~='string' then q=q.name end; return q and q~='normal' and s.name..'@'..q or s.name end
  M.waitgroups=require('waitgroups')()  -- (d18 batch36 A3) the waits' and/or chain: groups, the mixed refusal, the readback
  M.reqgroups=require('reqgroups')()  -- (d20 batch53 L3, L4) sections added and removed, named logistic groups
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
    -- (d23 batch131 CN1) turned back mid-connection: back to the end it left, the km left (its far end never reached)
    if w.leg and w.leg.turned_back then return string.format('back to %s, %d km left (turned back on %s->%s)',w.leg.to,math.floor(w.leg.left_km+0.5),w.leg.to,w.leg.from) end
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
  -- (d25 batch199 QL3, Sol #2298: Kestrel IVb, stopped at Fulgora with barrel 0..0 from fulgora, sent 66 barrels
  -- down unasked.) On a copy of world n (2.0.77): stopped at a planet, what is over the max of a request importing from
  -- that planet went to the trash within 8 ticks and down in one cargo pod within 276 ticks (20 barrels, Limestone at
  -- Nauvis, request from nauvis; Anvil at Fulgora, from fulgora); over the max of a request from another planet it
  -- stayed in the hub (Limestone, from fulgora, 600 ticks; Anvil, from vulcanus). In flight (Kestrel II,
  -- gleba->aquilo, a request from vulcanus) it went to the trash within 72 ticks.
  -- over: what the call set a max under, {name, from}: from the planet its request imports from.
  function M.trash_note(pl,over)
    local loc=pl.space_location
    local planet=loc and (loc.type=='planet' or try(function() return prototypes.space_location[loc.name].type end)=='planet')
    local where='to its landing pad, or, with none there, as cargo-pod containers on the ground near (0,0) (where_is lists them)'
    if planet then
      local here,later={},{}
      for _,o in ipairs(type(over)=='table' and over or {}) do
        if o.from==loc.name then here[#here+1]=o.name else later[#later+1]=o.name..(o.from and ' (from '..o.from..')' or '') end
      end
      return (#here>0 and 'stopped at '..loc.name..', the game moves what is over the max of a request from '..loc.name..' to the trash within a few ticks and sends it down in a cargo pod within about 5 s: '
          ..table.concat(here,', ')..' goes down now. ' or '')
        ..((#later>0 or over==true) and 'what is over the max of a request from another planet stays in the hub while the platform is stopped here'
          ..(#later>0 and ' ('..table.concat(later,', ')..')' or '')..'; once it flies, the game moves that to the trash, which goes down at the next stop. ' or '')
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
    if not secs and a.trash_unrequested~=nil then
      local mode=try(function() return e.prototype.logistic_mode end)
      error(e.name..' has no trash-unrequested switch (a requester or buffer chest, a hub and your own logistics have one)'
        ..((mode=='passive-provider' or mode=='storage' or mode=='active-provider') and ('; robots take spoilage from a '..mode..' chest only to a requester or buffer chest that requests spoilage, '
          ..'and an inserter filtered to spoilage moves it into the chest it drops into (an active provider chest: robots take its contents to storage)') or ''),0)
    end
    assert(secs,(e.type=='entity-ghost' and 'the ghost of '..e.ghost_name or e.name)..' has no logistic requests')
    -- By remote view on another surface (surface=, Astra 02:20): the reply names it.
    local remote=type(p)=='table' and rawget(p,'__remote')
    return e.name..' at '..string.format('(%g,%g)',e.position.x,e.position.y)..(remote and ' on '..e.surface.name or ''),secs,e
  end
  -- One request as the GUI shows it: name, min..max (or =n), and on a hub
  -- the planet it imports from (exact requests too: Astra's `calcite=500`
  -- hid `from vulcanus`, 02:00).
  -- (d20 batch55 P6, Grok #1413) what rockets launched to a hub carry to it now: its requester point's deliveries on the
  -- way, the hub GUI's in-transit count, by name@quality (silo.lua on_the_way reads the same).
  local function on_the_way(hub_e)
    local out={}
    local pt=defines.logistic_member_index and defines.logistic_member_index.space_platform_hub_requester
      and try(function() return hub_e.get_logistic_point(defines.logistic_member_index.space_platform_hub_requester) end)
    for _,it in ipairs(pt and try(function() return pt.targeted_items_deliver end) or {}) do
      local q=type(it.quality)=='string' and it.quality or try(function() return it.quality.name end) or 'normal'
      out[it.name..'@'..q]=(out[it.name..'@'..q] or 0)+(it.count or 0)
    end
    return out
  end
  M.on_the_way=on_the_way
  -- counts (a hub's request read): {hub=entity, way=on_the_way(hub)}: an import request says what the hub holds, what is
  -- on the way to it and what it lacks, as the hub GUI's request slot does.
  -- (d22 batch96 BF1) a number as the text .. gives, fast for integers (numtext.lua's num, inlined: some suites load
  -- this file with no package.path): in the game's Lua .. or tostring of a number costs about 8 us, string.format('%d')
  -- 0.3; a hub's requests made two or three a request (1.4 ms of a platform's full row on a copy of world n)
  local function num(x)
    if type(x)=='number' and x~=0 and x>-1e15 and x<1e15 and x==math.floor(x) then return string.format('%d',x) end
    return tostring(x)
  end
  local function filter_text(f,hub,counts)
    local v=f.value
    if not v then return nil end
    local name=type(v)=='table' and v.name or v
    local quality=type(v)=='table' and v.quality or nil
    local text=name..(quality and quality~='normal' and '@'..quality or '')
    if f.max and f.max==f.min then text=text..'='..num(f.min)
    else text=text..' '..num(f.min or 0)..'..'..(f.max and num(f.max) or 'inf') end
    local from=hub and f.import_from and (type(f.import_from)=='string' and f.import_from or f.import_from.name)
    text=from and text..' from '..from or text
    -- The GUI's custom minimum payload per request (LogisticFilter minimum_delivery_count; Astra 03:59).
    if hub and f.minimum_delivery_count then text=text..' min payload '..num(f.minimum_delivery_count) end
    if counts and from and (f.min or 0)>0 then
      local held=try(function() return counts.hub.get_item_count({name=name,quality=quality or 'normal'}) end) or try(function() return counts.hub.get_item_count(name) end) or 0
      local way=counts.way[name..'@'..(quality or 'normal')] or 0
      counts.out[#counts.out+1]=string.format('%s from %s: asks %d, holds %d, %d on the way, lacks %d',name..(quality and quality~='normal' and '@'..quality or ''),from,f.min,held,way,math.max(0,f.min-held-way))
    end
    return text
  end
  -- (d22 batch103 BM1, Astra #1920: K2's section 1 refused with "section 1 is controlled by the game", read as set
  -- in a batch of three calls, and found missing 13 minutes later) what controls a section the game controls, from
  -- LuaLogisticSection.type (2.0.77: manual 0, circuit_controlled 1, transitional_request_controlled 2: a silo's
  -- automatic requests, request_missing_materials_controlled 3: a hub's construction requests); nil for a manual one.
  local function controlled_by(sec)
    if try(function() return sec.is_manual end)~=false then return nil end
    local T=defines.logistic_section_type or {}
    local t=try(function() return sec.type end)
    if t~=nil and t==T.request_missing_materials_controlled then
      return 'the hub\'s construction requests (Request missing construction materials): the game writes what the platform\'s ghosts need'
    elseif t~=nil and t==T.transitional_request_controlled then
      return 'the silo\'s automatic requests: the game writes what the platforms in orbit ask this planet for'
    elseif t~=nil and t==T.circuit_controlled then
      return 'the circuit network (Set requests): its requests are the signals on the wires'
    end
    return 'the game'
  end
  M.controlled_by=controlled_by
  -- A call's arguments as JSON, for the call a refusal names (helpers.table_to_json in the game).
  local function call_text(t)
    local ok,j=pcall(function() return helpers.table_to_json(t) end)
    if ok and type(j)=='string' then return j end
    local function enc(v)
      if type(v)=='string' then return string.format('%q',v) end
      if type(v)~='table' then return tostring(v) end
      if v[1]~=nil then local o={} for i,x in ipairs(v) do o[i]=enc(x) end return '['..table.concat(o,',')..']' end
      local keys={} for k in pairs(v) do keys[#keys+1]=tostring(k) end
      table.sort(keys)
      local o={} for _,k in ipairs(keys) do o[#o+1]=string.format('%q',k)..':'..enc(v[k]) end
      return '{'..table.concat(o,',')..'}'
    end
    return enc(t)
  end
  -- A write to a section the game controls: the game refuses it (2.0.77: "trying to change logistic section that is not
  -- manual") and writes its own requests there. The refusal says what controls it and, for a set or clear, the call that
  -- puts the same requests in a new manual section.
  local function refuse_controlled(sec,a,removing)
    local alt
    if not removing then
      local c={}
      for k,v in pairs(a) do if k~='section' and k~='dry_run' then c[k]=v end end
      c.add_section=true
      alt=call_text(c)
    end
    error(string.format('section %d is controlled by the game: %s; the game refuses a script\'s write to it and writes its own requests there, so a manual request there does not last%s',
      sec.index,controlled_by(sec) or 'the game',removing and '; only the game removes it' or '; a new manual section keeps these requests: requests '..alt),0)
  end
  -- (d19 batch41 B1) uid: the requester's unit number: each section's last edit (editlog.lua), who, when, old and new.
  local function list_sections(secs,hub,uid,hub_e)
    local out={}
    local way=hub_e and hub_e.valid and on_the_way(hub_e) or nil
    for i=1,secs.sections_count do
      local sec=secs.get_section(i)
      local rows={}
      local counts=way and sec.active~=false and {hub=hub_e,way=way,out={}} or nil
      for _,f in ipairs(sec.filters or {}) do local t=filter_text(f,hub,counts); if t then rows[#rows+1]=t end end
      -- A section switched off requests nothing (the GUI's checkbox). Said
      -- as off=true: false values drop out of the compact reply. active says on or off for every section (batch29 A3,
      -- Luna 04:45 read sections 5-6 as unchanged), a word so it shows there too.
      out[#out+1]={index=i,group=sec.group~='' and sec.group or nil,active=sec.active==false and 'off' or 'on',off=sec.active==false or nil,
        controlled=not sec.is_manual,controlled_by=controlled_by(sec),requests=rows,imports=counts and #counts.out>0 and counts.out or nil,
        last_edit=uid and api.editlog and api.editlog.text(api.editlog.last('req:'..uid,i)) or nil}
    end
    return out
  end
  -- (d19 batch41 B1) each section as one text, for the edit log: on or off, its group, its requests.
  local function section_texts(secs,hub)
    local out={}
    for i=1,secs.sections_count do
      local sec=secs.get_section(i)
      local rows={}
      for _,f in ipairs(try(function() return sec.filters end) or {}) do local t=filter_text(f,hub); if t then rows[#rows+1]=t end end
      out[i]=(sec.active==false and 'off' or 'on')..(sec.group~='' and ' "'..sec.group..'"' or '')..': '..(#rows>0 and table.concat(rows,', ') or 'no request')
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
    -- (d20 batch53 L3, L4) a section added (the GUI's Add section) or removed, and a section's group
    assert(a.add_section==nil or a.add_section==true,'add_section is true: a new manual section (the GUI\'s Add section); with group it joins that group; set, clear and active go to it')
    if a.add_section then assert(a.section==nil,'add_section makes a new section: give it without section') end
    if a.remove_section~=nil then
      local sec=secs.get_section(api.integer(a.remove_section,1,1,100,'remove_section'))
      assert(sec,'section '..a.remove_section..' does not exist (sections_count '..secs.sections_count..')')
      if not sec.is_manual then refuse_controlled(sec,a,true) end
      assert(not changing and a.add_section==nil and a.group==nil and a.keep==nil,'remove_section goes alone (or with dry_run)')
    end
    if a.group~=nil then
      if a.group~=false then M.reqgroups.check_name(a.group) end
      assert(a.add_section or a.section~=nil,'group goes with section (that section joins the group, or leaves it with false) or with add_section')
      assert(a.group~=false or not a.add_section,'a new section is in no group: group false goes with section')
    end
    if (changing or a.group~=nil) and a.section~=nil then
      local sec=secs.get_section(api.integer(a.section,1,1,100,'section'))
      assert(sec,'section '..a.section..' does not exist (sections_count '..secs.sections_count..')')
      if not sec.is_manual then refuse_controlled(sec,a) end
    end
    assert(a.clear==nil or type(a.clear)=='table','clear is a list of item names: ["coal"]')
    for _,name in ipairs(a.clear or {}) do item_name(name) end
    -- (d17 batch29 C4) keep: items the change leaves requested at what the hub holds; dry_run: the change read, then undone
    assert(a.dry_run==nil or type(a.dry_run)=='boolean','dry_run must be true or false')
    assert(not a.dry_run or (a.from_buffers==nil and a.trash_unrequested==nil and a.construction_requests==nil),
      'dry_run reads set, clear, clear_all, active and keep; from_buffers, trash_unrequested and construction_requests switch at once')
    if a.keep~=nil then
      assert(type(a.keep)=='table' and #a.keep>=1 and #a.keep<=M.KEEP_MAX,'keep is a list of item names or item@quality: ["firearm-magazine", "asteroid-collector@legendary"]')
      for _,name in ipairs(a.keep) do
        local kq=type(name)=='string' and name:match('@([^@]+)$')
        item_name(kq and name:sub(1,-#kq-2) or name)
        assert(not kq or prototypes.quality[kq],'unknown quality: '..tostring(kq))
      end
      assert(a.platform~=nil or (chest and chest.type=='space-platform-hub'),'keep is for a platform hub: what the change leaves unrequested of these stays requested at the count the hub holds')
      assert(changing,'keep goes with a change: set, clear, clear_all or active')
    end
    local listed=type(a.set)=='table'
    if listed then local n=0; for _ in pairs(a.set) do n=n+1 end; listed=n==#a.set end
    assert(a.set==nil or (listed and #a.set<=M.SET_MAX),'set requires an array of {item,min,max?,quality?,from?}: [{"item":"iron-plate","min":100}]')
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
      -- (d17 batch31 C3, Astra) false (or ""): no import planet named, the slot's own dropped too; the game then stores
      -- nauvis (16 new hub slots set with none read back "from nauvis", Wren, Kestrel II, Meridian and Aegis stopped at
      -- Fulgora among them)
      if from==false or from=='' then from=false
      elseif from~=nil then
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
        -- (batch28 A3, Sol: a railgun turret min 4 silently stopped construction) heavier than a rocket lifts: refused
        if type(mp)=='number' then
          local w=try(function() return prototypes.item[name].weight end)
          local lift=try(function() return prototypes.utility_constants.rocket_lift_weight end) or 1000000
          if w and w>0 and mp*w>lift then
            error(string.format('min_payload %s %d: %d weigh %g kg, a rocket lifts %g kg: at most %d fit%s (min_payload %d)',name,mp,mp,mp*w/1000,lift/1000,
              math.floor(lift/w),math.floor(lift/w)==1 and 's' or '',math.floor(lift/w)),0)
          end
        end
      end
      entries[k]={name=name,quality=quality,min=min,max=max,inf=inf,from=from,min_payload=mp}
    end
    return entries
  end
  -- (d17 batch29 C4, Astra twice: clearing a hub section made the ammo it held surplus, and the game sent it down to the
  -- planet) what a hub keeps of each item: the sum of the mins its sections that are on request.
  -- (d25 batch198 QK1, after Sol #2264) a slot's key: "name@quality", or "name@>=quality" with a quality comparator
  -- other than = (what such a slot keeps is not forecast: freight.lua hub_keeps_at)
  local function slot_key(f)
    local v=f.value
    local n=v and (type(v.name)=='string' and v.name or try(function() return v.name.name end))
    if not n then return nil end
    local q=v.quality
    if type(q)~='string' then q=q and try(function() return q.name end) end
    local cmp=v.comparator or '='
    return n..'@'..(cmp=='=' and '' or cmp)..(q or 'normal')
  end
  local function key_parts(key) local n,q=key:match('^(.*)@([^@]*)$'); return n or key,q or 'normal' end
  local function key_label(key) local n,q=key_parts(key); return q=='normal' and n or n..'@'..q end
  M.slot_key,M.key_label=slot_key,key_label
  -- what e holds of name@q (the name alone counts normal only on 2.0.77)
  local function held_q(e,name,q) return try(function() return e.get_item_count(q=='normal' and name or {name=name,quality=q}) end) or 0 end
  function M.hub_keep(secs)
    local keep={}
    for i=1,secs.sections_count or 0 do
      local s_=secs.get_section(i)
      if s_ and s_.active~=false then
        for _,f in pairs(try(function() return s_.filters end) or {}) do
          local k=slot_key(f)
          if k and (f.min or 0)>0 then keep[k]=(keep[k] or 0)+f.min end
        end
      end
    end
    return keep
  end
  -- (d17 batch31 B6) what a hub keeps by the import planet of its requests: {planet={key=sum of maxes}}, the sections
  -- that are on; (QK1) by slot_key: a slot's max is for its own quality (freight.lua hub_keeps_at).
  function M.hub_keep_at(secs)
    local keep={}
    for i=1,secs.sections_count or 0 do
      local s_=secs.get_section(i)
      if s_ and s_.active~=false then
        for _,f in pairs(try(function() return s_.filters end) or {}) do
          local k=slot_key(f)
          local from=f.import_from and (type(f.import_from)=='string' and f.import_from or try(function() return f.import_from.name end)) or '?'
          -- (d24 batch137 PI1) what a section keeps at that planet is its max (freight.lua hub_keeps_at): the maxes add up,
          -- none (infinite) keeps it all
          if k then keep[from]=keep[from] or {}; keep[from][k]=(keep[from][k] or 0)+(f.max or math.huge) end
        end
      end
    end
    return keep
  end
  -- The rule (d17 batch31 B6; maxes from d24 batch137 PI1; sections summed, d27 batch260 HR, Sol #2494): at a stop the
  -- hub keeps what the maxes of its requests importing from that planet add up to (none: all), sends all above to the
  -- landing pads there asked or not, and an item no such request names as far as the pads ask; a request from another
  -- planet keeps nothing there. Cases with each claim are in KEEP_RULE.
  M.KEEP_RULE='each item by quality: a request\'s max is for its own quality, and a landing pad\'s ask too (2.0.77, d24-d25: Kestrel IVc at Fulgora kept its legendary and normal asteroid collectors under asteroid-collector@rare 0..1 from fulgora; Fulgora\'s pad asking 2 normal took 2 normal and none of the legendary). At a stop the hub keeps what its active requests importing from that planet allow, their maxes added up over every section (a request\'s min is what the hub asks rockets for and keeps nothing by itself): no max keeps all of it; with a max it sends down all it holds above it to the landing pad there, whether the pad asks or not; an item no such request names goes down as far as the pads there ask (their ask less what they hold); a request from another planet keeps nothing there (2.0.77, d24: Petrel at Nauvis kept all 1980 calcite under 200..inf from nauvis with the pad asking 2000, and sent all above 200 under 200..200; d27: Limestone at Nauvis, small-lamp 0..60 from nauvis in two sections, kept all 100 with the pad asking 1000; with one cleared, 40 went down to the pad asking 0; under 50..inf it kept all 60 with the pad asking 1000). In flight what it holds over the hub\'s max (the maxes of its active requests for the item added up, any planet) goes to its trash within a second, as much as the trash (10 slots) has room for, and down at the first stop it waits at, asked or not; the rest stays in the hub while it flies (2.0.77, d24: Meridian-V flying to Nauvis, bioflux 20..30 from gleba: its 150 over 30 went down at Nauvis, 30 stayed aboard; d26: Kestrel II with 2000 low-density-structure over its max and 9 trash slots free: 450 in the trash the next tick, 3050 still in the hub 2346 ticks later). Stopped at a planet, what is over the max of a request from that planet goes to the trash within a few ticks and down in cargo pods, a trash load each, within about 5 s for a load (d26: Kestrel IVc at Fulgora, 3857 iron-plate over 2000: 1000 in the trash the next tick, the hub at 2000 after 120 ticks, the trash empty by 2340); over the max of a request from another planet it stays in the hub until the platform flies (2.0.77, d25: 20 barrels under barrel 0..0, from nauvis at Nauvis: trash in 8 ticks, down in 276; from fulgora at Nauvis: in the hub after 600 ticks)'
  -- Per item whose kept stock a change alters: what goes down at each stop after it. The stops: where it waits now,
  -- then its schedule's in order. before, after: hub_keep_at.
  function M.sends_down(hub,pl,before,after)
    local stops,seen={},{}
    local sch=pl and try(function() return pl.schedule end)
    local w=pl and try(function() return freight.where(pl) end) or {}
    if w.stopped and w.at then stops[1]={planet=w.at,here=true}; seen[w.at]=true end
    local recs=sch and sch.records or {}
    for k=0,#recs-1 do
      local st=recs[((sch.current or 1)-1+k)%#recs+1].station
      if st and not seen[st] then seen[st]=true; stops[#stops+1]={planet=st} end
    end
    -- (d25 batch198 QK1) by item@quality: the pads' ask and hold of each quality (freight.lua pads)
    local pads={}
    local function pad(planet)
      if not pads[planet] then
        local ask,hold
        if freight.pads then ask,hold=freight.pads(planet,pl and pl.force,true) end
        -- (a reader without qualities: normal)
        local function norm(t) local out={}; for k,v in pairs(t or {}) do out[k:find('@',1,true) and k or k..'@normal']=v end; return out end
        pads[planet]={ask=norm(ask),hold=norm(hold)}
      end
      return pads[planet]
    end
    local names,named={},{}
    for _,t in ipairs({before,after}) do
      for _,list in pairs(t) do for n in pairs(list) do if not named[n] then named[n]=true; names[#names+1]=n end end end
    end
    table.sort(names)
    -- an item a request with a quality comparator names: what the hub keeps of it is not forecast
    local ranged={}
    for _,n in ipairs(names) do local item,q=key_parts(n); if not q:match('^[%w%-]+$') then ranged[item]=n end end
    local function kept(t,n,held)
      local parts,total={},0
      local planets={}
      for planet,list in pairs(t) do if (list[n] or 0)>0 then planets[#planets+1]=planet end end
      table.sort(planets)
      for _,planet in ipairs(planets) do parts[#parts+1]=string.format('%s at %s',t[planet][n]==math.huge and 'all' or tostring(math.min(held,t[planet][n])),planet); total=total+t[planet][n] end
      return #parts>0 and table.concat(parts,', ') or 'none',total
    end
    local lines={}
    local said={}
    -- (d26 batch231 RG) in flight the trash takes what it has room for, the rest stays in the hub (copy of world n:
    -- Kestrel II, 2000 low-density-structure over its max, 9 of 10 trash slots free: 450 went, 3050 stayed 2346 ticks)
    local trash=hub and defines.inventory.hub_trash and try(function() return hub.get_inventory(defines.inventory.hub_trash) end)
    local function room_now(item,q) return trash and try(function() return trash.get_insertable_count({name=item,quality=q}) end) end
    local function room_flying(item)
      local slots=trash and try(function() return #trash end)
      local stack=try(function() return prototypes.item[item].stack_size end)
      return slots and stack and slots*stack or nil,slots
    end
    for _,n in ipairs(names) do
      local item,q=key_parts(n)
      local held=not ranged[item] and held_q(hub,item,q) or 0
      -- (d25 batch199 QL3) a max of 0 keeps nothing and is told apart from no request there
      local differs=false
      for planet in pairs(seen) do
        if (before[planet] or {})[n]~=(after[planet] or {})[n] then differs=true end
      end
      for planet,list in pairs(before) do if list[n]~=(after[planet] or {})[n] then differs=true end end
      for planet,list in pairs(after) do if list[n]~=(before[planet] or {})[n] then differs=true end end
      if differs and ranged[item] and not said[item] and #lines<12 then
        said[item]=true
        lines[#lines+1]=string.format('%s: a request names it with a quality comparator (%s): what the hub keeps of it is not forecast',item,key_label(ranged[item]))
      elseif differs and held>0 and #lines<12 then
        local left=held
        local parts={}
        -- (d24 batch141 PM1, Sol #2125) over the hub's max: to its trash now, down at the first stop, asked or not; the
        -- pads there then hold it
        local cap,capped=0,false
        for _,list in pairs(after) do if list[n] then capped=true; cap=cap+list[n] end end
        local dumped={}
        -- (d25 batch199 QL3, Sol #2298) the hub's max sends to the trash in flight; stopped at a planet only the requests
        -- from that planet keep or send (the stop rule below), so there it applies once the platform flies on
        local here=stops[1] and stops[1].here
        if capped and cap<left and not here then
          local first=stops[1]
          local over=left-cap
          local fit=room_now(item,q)
          local where_=not first and 'at the first planet it stops at' or 'to '..first.planet..' at its next stop'
          if fit and fit<over then
            parts[#parts+1]=string.format('%d over its max %d: %d go to the hub\'s trash now (the room its trash has) and down %s, asked or not; %d stay in the hub while it flies',
              over,cap,fit,where_,over-fit)
          else
            fit=over
            parts[#parts+1]=string.format('%d over its max %d go to the hub\'s trash now and down %s, asked or not',over,cap,where_)
          end
          if first then dumped[first.planet]=fit end
          left=left-fit
        end
        local keep_here=here and (after[stops[1].planet] or {})[n]
        if keep_here and keep_here~=math.huge and keep_here<left then
          parts[#parts+1]=string.format('%d over its max %d go to the hub\'s trash now and down to %s (here), asked or not',left-keep_here,keep_here,stops[1].planet)
          dumped[stops[1].planet]=left-keep_here
          left=keep_here
        end
        for i,st in ipairs(stops) do
          if i==2 and here and capped and cap<left then
            local over=left-cap
            local fit,slots=room_flying(item)
            if fit and fit<over then
              parts[#parts+1]=string.format('%d over its max %d: at most %d (its %d trash slots) go to the hub\'s trash once it flies and down to %s at its next stop, asked or not; the rest stays in the hub while it flies',
                over,cap,fit,slots,st.planet)
            else
              fit=over
              parts[#parts+1]=string.format('%d over its max %d go to the hub\'s trash once it flies and down to %s at its next stop, asked or not',over,cap,st.planet)
            end
            dumped[st.planet]=fit
            left=left-fit
          end
          local pd=pad(st.planet)
          -- (d24 batch142 PN1) a stop with unloading off: its pads take nothing (a finite max still sends down)
          local off=freight.no_unload and freight.no_unload(pl,st.planet)
          local want=off and 0 or (pd.ask[n] or 0)-(pd.hold[n] or 0)-(dumped[st.planet] or 0)
          local named=(after[st.planet] or {})[n]~=nil
          local keep=(after[st.planet] or {})[n] or 0
          -- (PI1) all above a finite max goes down, asked or not (a max of 0: all of it); an infinite max keeps it all
          local go=keep==math.huge and 0 or named and math.max(0,left-keep) or math.max(0,math.min(left,want))
          if go>0 then
            left=left-go
            -- (d24 batch141 PM1, Sol #2125) a pad that asks none of it: ask 0 (nil made the format fail after the change)
            parts[#parts+1]=string.format('%d down to %s%s (its landing pads ask %d, hold %d%s%s)',go,st.planet,st.here and ' (here)' or '',pd.ask[n] or 0,pd.hold[n] or 0,
              named and string.format('; its requests from %s keep %s',st.planet,keep==math.huge and 'all of it' or tostring(keep)) or '',off and '; unloading off there: only what is above the max' or '')
          end
        end
        local now_text=kept(after,n,held)
        local was_text=kept(before,n,held)
        lines[#lines+1]=string.format('%s: the hub holds %d; its requests would keep %s (kept %s): %s',key_label(n),held,now_text,was_text,
          #parts>0 and table.concat(parts,', ')..(left>0 and string.format('; %d stay aboard',left) or '')
          or 'no landing pad on its stops asks for more than its requests from there keep: it stays aboard')
      end
    end
    return #lines>0 and lines or nil
  end
  local requests_body
  -- (d24 batch141 PM1) a dry run that fails after it set slots puts them back before the error goes out
  function M.requests(p,a)
    local ctx={}
    local ok,r=pcall(requests_body,p,a,ctx)
    if ok then return r end
    if ctx.undo then pcall(ctx.undo) end
    error(r,0)
  end
  requests_body=function(p,a,ctx)
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
    -- (d20 batch53 L4) groups: true: the force's named logistic groups, their requests and members
    if a.groups~=nil then
      assert(a.groups==true,'groups is true: the named logistic groups')
      for k in pairs(a) do assert(k=='groups' or k=='compact' or k=='fields','groups: true goes alone (a read of every group)') end
      return M.reqgroups.list(p.force)
    end
    local label,secs,chest=sections_of(p,a)
    -- (d24 batch178 QU3, Sol #2052) a section named by its logistic group: the one section in that group
    if type(a.section)=='string' then
      local hits,groups={},{}
      for i=1,secs.sections_count do
        local g=secs.get_section(i).group
        if g~='' then groups[#groups+1]=string.format('%d "%s"',i,g) end
        if g==a.section then hits[#hits+1]=i end
      end
      assert(#hits>0,'no section is in the logistic group "'..a.section..'"'..(#groups>0 and ' (sections in a group: '..table.concat(groups,', ')..')' or ' (no section is in a group)'))
      assert(#hits==1,'sections '..table.concat(hits,', ')..' are all in the logistic group "'..a.section..'": give section as one of those indices')
      local b={}; for k,v in pairs(a) do b[k]=v end
      b.section=hits[1]; b.section_group=a.section; a=b
    end
    local entries=M.check_requests(p,a,label,chest,secs)
    -- (QU3: construction_requests true inserted the game's section at 1 and section 5 then meant the one after) the
    -- sections as they were before the call: each section index this call names means that section, and a write's
    -- reply gives the section it wrote before and after (index, group, active). A switch of construction_requests puts
    -- the manual sections back in their order, so a manual section is found again by its place among them.
    local rows_before={}
    for i=1,secs.sections_count do
      local s_=secs.get_section(i)
      rows_before[i]={index=i,group=s_.group~='' and s_.group or nil,active=s_.active~=false,manual=s_.is_manual or nil}
    end
    local function manual_place(index)
      local k=0
      for i=1,index do if (rows_before[i] or {}).manual then k=k+1 end end
      return (rows_before[index] or {}).manual and k or nil
    end
    -- (d24 batch141 PM1) each change as it is made (made.lua): a failure after one answers the changes made
    local function mark(t) if not a.dry_run and api.made then api.made(t) end end
    local slots_changing=a.set~=nil or a.clear~=nil or a.clear_all~=nil or a.active~=nil
    -- A requester chest's "request from buffer chests" switch.
    local buffers
    if a.from_buffers~=nil then
      local ok,err=pcall(function() chest.request_from_buffers=a.from_buffers end)
      assert(ok,'the game refused from_buffers: '..tostring(err))
      mark('request from buffer chests '..(a.from_buffers and 'on' or 'off'))
    end
    if chest then pcall(function() buffers=chest.request_from_buffers end) end
    -- Trash unrequested (d17 batch20 C2, Grok: yumako and nutrient chests filled with spoilage, each clear a walk): the
    -- GUI's checkbox on a requester or buffer chest, a hub and your own logistics; robots take to storage what it holds
    -- that no request names, spoilage among it.
    local owner=chest or (a.platform~=nil and M.platform(p,a.platform).hub) or (label=='character' and p.character) or nil
    local tpoint=owner and try(function() return owner.get_requester_point() end)
    if a.trash_unrequested~=nil then
      assert(type(a.trash_unrequested)=='boolean','trash_unrequested must be true or false')
      local mode=chest and try(function() return chest.prototype.logistic_mode end)
      assert(tpoint,'trash_unrequested is the trash-unrequested switch of a requester or buffer chest, a hub or your own logistics; '..label..' has none'
        ..((mode=='passive-provider' or mode=='storage') and ('; robots take spoilage from a '..mode..' chest only to a requester or buffer chest that requests spoilage, '
          ..'and an inserter filtered to spoilage moves it into the chest it drops into (an active provider chest: robots take its contents to storage)') or ''))
      local ok,err=pcall(function() tpoint.trash_not_requested=a.trash_unrequested end)
      local now=try(function() return tpoint.trash_not_requested end)
      assert(ok and now==a.trash_unrequested,'the game kept trash unrequested '..(now and 'on' or 'off')..(ok and '' or ': '..tostring(err)))
      mark('trash unrequested '..(now and 'on' or 'off'))
    end
    -- A hub's Request missing construction materials (Astra, shift12 19:16: a paste switched Starling's off and its
    -- construction requests vanished): switched as the GUI's checkbox does (keep.lua).
    local hub=a.platform~=nil and M.platform(p,a.platform).hub or (chest and chest.type=='space-platform-hub' and chest) or nil
    local keep=api.keep and api.keep()
    local switched
    local section_moved
    if a.construction_requests~=nil then
      local place=type(a.section)=='number' and manual_place(a.section)
      local on=keep.set_construction(hub,a.construction_requests)
      assert(on==a.construction_requests,'the game kept Request missing construction materials '..(on and 'on' or 'off'))
      switched=true
      mark('Request missing construction materials '..(on and 'on' or 'off'))
      -- (QU3) the section named, found again among the manual sections after the switch
      if place then
        local k,now=0,nil
        for i=1,secs.sections_count do if secs.get_section(i).is_manual then k=k+1; if k==place then now=i; break end end end
        assert(now,'section '..a.section..' is gone after the switch of Request missing construction materials')
        if now~=a.section then
          section_moved=string.format('section %d (as the call found it) is section %d after construction_requests %s switched the game\'s section %s: the call wrote section %d',
            a.section,now,on and 'on' or 'off',on and 'in' or 'out',now)
          local b={}; for k2,v in pairs(a) do b[k2]=v end
          b.section=now; a=b
        end
      end
    end
    local changing=slots_changing or a.add_section~=nil or a.remove_section~=nil or a.group~=nil
    -- (d17 batch29 C4) on a hub: what it keeps before the change (sends_down), and for dry_run every manual section's
    -- slots and switch and the hub's kept minimum payloads, put back after the read
    local before=hub and hub.valid and changing and M.hub_keep_at(secs) or nil
    -- (d19 batch41 B1) the sections before the edit, for the edit log
    local is_hub_target=a.platform~=nil or (chest and chest.type=='space-platform-hub') or false
    local logged=changing and not a.dry_run and api.editlog and (chest or hub) or nil
    local texts_before=logged and section_texts(secs,is_hub_target)
    local snap
    if a.dry_run then
      snap={count=secs.sections_count,secs={}}
      for i=1,secs.sections_count do
        local s_=secs.get_section(i)
        if s_.is_manual then snap.secs[i]={filters=try(function() return s_.filters end) or {},active=s_.active} end
      end
      local mem=hub and hub.unit_number and api.state and api.state().hub_min_payload
      mem=mem and mem[hub.unit_number]
      if mem then snap.mp={}; for k,v in pairs(mem) do snap.mp[k]=v end end
      snap.groups=M.reqgroups.snapshot(secs)
    end
    -- (d20 batch53 L3, L4) the section added or removed and the group joined or left, before the slots are edited: set,
    -- clear and active after add_section go to the new section. A dry run's removal switches the section off as its
    -- stand-in (what the hub keeps and sends down reads as without it), put back after.
    local section_change,group_change,made={},nil,{}
    -- a dry run's undo: sections it added removed, groups, slots and switches, and the kept minimum payloads put back
    local function undo()
      for i=secs.sections_count,snap.count+1,-1 do pcall(secs.remove_section,i) end
      -- a section's group back before its requests: a section in a group writes the group
      for i,v in pairs(snap.secs) do
        local s_=secs.get_section(i)
        if s_ then pcall(M.reqgroups.restore_group,p.force,s_,snap.groups[i] or '') end
      end
      for i,v in pairs(snap.secs) do
        local s_=secs.get_section(i)
        if s_ then s_.filters=v.filters; if v.active~=nil then s_.active=v.active end end
      end
      M.reqgroups.drop_made(p.force,made)
      local mem=hub and hub.unit_number and api.state and api.state().hub_min_payload
      if mem then mem[hub.unit_number]=snap.mp end
    end
    if snap then ctx.undo=undo end
    if a.remove_section~=nil then
      local rsec=secs.get_section(a.remove_section)
      local r=M.reqgroups.removal(rsec)
      section_change[#section_change+1]=r.line
      if a.dry_run then rsec.active=false else secs.remove_section(a.remove_section) end
      mark(r.line)
    end
    if a.add_section then
      local nsec=secs.add_section()
      assert(nsec,'the game added no section')
      section_change[#section_change+1]='section '..nsec.index..' added'
      mark('section '..nsec.index..' added')
      local b={}; for k,v in pairs(a) do b[k]=v end
      b.section=nsec.index; b.add_section=nil; a=b
    end
    if a.group~=nil then
      local gsec=secs.get_section(a.section)
      if a.group~=false and not try(function() return p.force.get_logistic_group(a.group) end) then made[a.group]=true end
      group_change=M.reqgroups.set_group(p.force,gsec,a.group)
      section_change[#section_change+1]=group_change.line
      mark(group_change.line)
    end
    -- changed: a slot set or cleared, or the section switched (friction2: a set the call read as nothing still said
    -- changed_section).
    local touched,stored,changed,told,group_edit
    local others={}
    -- keep: the import planet and minimum payload of each request the change drops
    local gone={}
    local function note_gone(f)
      local n=f and f.value and slot_key(f)
      if n and not gone[n] then
        gone[n]={from=f.import_from and (type(f.import_from)=='string' and f.import_from or try(function() return f.import_from.name end)),mp=f.minimum_delivery_count}
      end
    end
    if slots_changing then
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
        if not default.is_manual then refuse_controlled(default,a) end
        return default
      end
      local function for_item(name,quality)
        local found,rest=holding(name,quality)
        local target=found or default_section()
        if #rest>0 then others[#others+1]=string.format('%s is requested in section%s %s too (the hub requests the sum; requests {section, clear} removes one)',
          name,#rest>1 and 's' or '',table.concat(rest,', ')) end
        if target.group~='' then others[#others+1]=string.format('%s: section %d is the logistic group "%s": every entity in the group gets the change, as in the GUI%s',name,target.index,target.group,
          target.group:find('^platform_bom: ') and '; platform_bom keeps this section to what the ghosts need: its keeper takes a min_payload changed here as its own, and sets min itself' or '') end
        return target
      end
      sec=(a.active~=nil or a.clear_all) and default_section() or nil
      touched=sec
      -- A hub's custom minimum payloads outlive a clear (d17 batch20 A4, Sol: requests clear_all, then set, and small
      -- freight waited for full rockets): each cleared slot's is kept per hub and item, and a later set of that item
      -- without min_payload takes it again; min_payload false forgets it.
      local mpmem
      if hub and hub.valid and hub.unit_number and api.state then
        local st=api.state()
        st.hub_min_payload=st.hub_min_payload or {}
        mpmem=st.hub_min_payload[hub.unit_number] or {}
        st.hub_min_payload[hub.unit_number]=mpmem
      end
      local function remember(f)
        if not (mpmem and f and f.minimum_delivery_count and f.value) then return end
        local q=f.value.quality
        mpmem[(f.value.name or '?')..'|'..(type(q)=='table' and q.name or q or 'normal')]=f.minimum_delivery_count
      end
      if a.active==false or a.clear_all then for _,f in pairs(try(function() return sec.filters end) or {}) do note_gone(f) end end
      if a.active~=nil then sec.active=a.active; changed=true; mark('section '..sec.index..' switched '..(a.active and 'on' or 'off')) end
      if a.clear_all then
        for _,f in pairs(try(function() return sec.filters end) or {}) do remember(f) end
        changed=changed or (sec.filters_count or 0)>0; sec.filters={}
        mark('section '..sec.index..' emptied')
      end
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
          remember(csec.get_slot(i))
          note_gone(csec.get_slot(i))
          csec.clear_slot(i); changed=true
          stored[#stored+1]=name..': cleared'..(was and ' (was '..was..')' or '')
          mark(stored[#stored])
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
        local none=from==false
        if none then from=nil end
        if from==nil and not none and old and old.import_from then
          from=type(old.import_from)=='string' and old.import_from or try(function() return old.import_from.name end)
          kept=from~=nil
        end
        -- The minimum payload: the one named (false clears it), else the slot's, as for the import planet.
        local mp,mp_kept=e.min_payload,false
        if mp==nil and old and old.minimum_delivery_count then mp=old.minimum_delivery_count; mp_kept=true end
        local mkey=name..'|'..quality
        local mp_back
        if mp==nil and mpmem and mpmem[mkey] then mp=mpmem[mkey]; mp_back=mp end
        if mpmem and (e.min_payload~=nil or mp_back) then mpmem[mkey]=nil end
        local was=old and filter_text(old,is_hub)
        ssec.set_slot(i,{value={type='item',name=name,quality=quality,comparator='='},min=min,max=max,import_from=from,minimum_delivery_count=mp or nil}); changed=true
        local now=filter_text(ssec.get_slot(i),is_hub) or name
        local set_from=is_hub and not kept and e.from==nil or none
        local read_from=set_from and is_hub and now:match(' from (%S+)')
        stored[#stored+1]=now..max_note..(kept and is_hub and ' (import planet kept: not named in this edit)' or '')
          ..(read_from and string.format(' (no import planet given: the game set %s)',read_from) or '')
          ..(mp_kept and ' (min payload kept: not named in this edit)' or '')
          ..(mp_back and string.format(' (min payload %d kept from the request cleared before)',mp_back) or '')..(was and was~=now and ' (was '..was..')' or '')
        mark(stored[#stored])
      end
      -- keep: each named item the hub would now keep less of than it holds is requested up to the count held, in the
      -- section that requests it (else the default one; a new section when that is off), with the dropped request's
      -- import planet and minimum payload
      -- (d25 batch198 QK1) "item@quality" keeps that quality ("item": normal), its count held against the requests of
      -- that quality: a request's max is for its own quality (freight.lua hub_keeps_at)
      for _,kname in ipairs(hub and a.keep or {}) do
        local kq=type(kname)=='string' and kname:match('@([^@]+)$')
        local name=item_name(kq and kname:sub(1,-#kq-2) or kname)
        kq=kq or 'normal'
        assert(prototypes.quality[kq],'unknown quality: '..kq)
        local key=name..'@'..kq
        local held=held_q(hub,name,kq)
        local need=held-(M.hub_keep(secs)[key] or 0)
        if need>0 then
          local ksec=for_item(name,kq)
          if ksec.active==false then ksec=secs.add_section() end
          touch(ksec)
          local i,found=slot_of(ksec,name,kq)
          local old=found and ksec.get_slot(i) or nil
          local g=gone[key] or {}
          local from=g.from or (old and old.import_from and (type(old.import_from)=='string' and old.import_from or try(function() return old.import_from.name end)))
          local min=(old and old.min or 0)+need
          ksec.set_slot(i,{value={type='item',name=name,quality=kq,comparator='='},min=min,import_from=from,minimum_delivery_count=(old and old.minimum_delivery_count) or g.mp or nil})
          changed=true
          stored[#stored+1]=string.format('%s: kept at the %d the hub holds (%s in section %d)',key_label(key),held,filter_text(ksec.get_slot(i),true) or name,ksec.index)
          mark(stored[#stored])
        else
          stored[#stored+1]=string.format('%s: kept already (the hub holds %d, its requests keep %d)',key_label(key),held,M.hub_keep(secs)[key] or 0)
        end
      end
      if not touched then touch(default_section()) end
      if #sections_touched>1 then table.sort(sections_touched); others[#others+1]='sections changed: '..table.concat(sections_touched,', ') end
      -- (d20 batch53 L4) a section in a group: the edit is every member's; each member it changes besides this one
      for _,i in ipairs(sections_touched) do
        local gs=secs.get_section(i)
        local o=gs and (a.set~=nil or a.clear~=nil or a.clear_all or a.keep~=nil) and M.reqgroups.others(p.force,gs)
        if o then group_edit=group_edit or {}; group_edit[#group_edit+1]=o.line end
      end
    end
    if #section_change>0 then changed=true end
    -- (d24 batch141 PM1, Sol #2125: sends_down failed after the change and the call answered a plain failure) each part
    -- of the reply after the change is read on its own: one that fails is named with its error in reply_failed, the rest
    -- stay
    local out={target=label,from_buffers=buffers}
    local function part(name,fn)
      local ok,err=pcall(fn)
      if not ok then
        out.reply_failed=out.reply_failed or {}
        out.reply_failed[#out.reply_failed+1]=name..': '..(tostring(err):gsub('^[^:]*:%d+: ',''))
      end
    end
    -- (B1) each section the call changed: recorded with the editor and the tick; whoever set it last before, if someone
    -- else, is told once
    part('told_of_edit',function()
      if logged and logged.valid and logged.unit_number then
        local changes=api.editlog.diff(texts_before,section_texts(secs,is_hub_target))
        if #changes>0 then
          local pl=a.platform~=nil and M.platform(p,a.platform) or try(function() return logged.surface.platform end)
          local name=pl and pl.name..' hub' or string.format('%s (%g,%g) on %s',logged.name,logged.position.x,logged.position.y,logged.surface.name)
          local owed=api.editlog.record('req:'..logged.unit_number,p.name or '?',changes,function(k) return name..' request section '..k end)
          told=api.editlog.tell(owed,p.name or '?')
        end
      end
    end)
    part('sections',function() out.sections=list_sections(secs,is_hub_target,logged and logged.unit_number or (chest or hub) and (chest or hub).unit_number,is_hub_target and hub or nil) end)
    out.told_of_edit=told
    part('sends_down',function()
      if before then
        local pl=a.platform~=nil and M.platform(p,a.platform) or try(function() return hub.surface.platform end)
        local after=M.hub_keep_at(secs)
        out.sends_down=M.sends_down(hub,pl,before,after)
        if out.sends_down then out.sends_down_rule=M.KEEP_RULE end
        -- (d26 batch231 RG) the item_count waits at the stop it waits at and its next one that the new maxes leave unmet
        out.waits_unmet=pl and M.gate_lines(pl,hub,before,after) or nil
      end
    end)
    -- (d17 batch34 B3, Opus: 20 old requesters pulled ore 500 tiles for 20 hours) a dry run of a requester's, a buffer
    -- chest's or the character's requests: the robots' trips for what it would ask beyond what it holds
    if a.dry_run and api.dispatch and type(a.set)=='table' and not (chest and chest.type=='space-platform-hub') then
      local where=chest and chest.valid and chest or (label=='character' and p.character) or nil
      local jobs={}
      for _,w in ipairs(a.set[1] and a.set or {}) do
        local name=type(w)=='table' and (w.item or w.name)
        local min=type(w)=='table' and tonumber(w.min) or nil
        if where and type(name)=='string' and min and min>0 then
          -- (d26 batch249 R10) what it holds of the quality asked
          local q=type(w.quality)=='string' and w.quality or 'normal'
          local held=try(function() return where.get_item_count(q=='normal' and name or {name=name,quality=q}) end) or 0
          if min>held then jobs[#jobs+1]={kind='deliver',pos=where.position,item=name,quality=q,count=min-held} end
        end
      end
      local okd,lines=pcall(api.dispatch,where and where.surface or p.surface,p.force,jobs)
      if okd and lines then out.robot_dispatch=lines end
    end
    -- (d20 batch53) the index read before a dry run's undo removes a section it added
    local touched_index=touched and try(function() return touched.index end) or a.section
    if snap then
      ctx.undo=nil
      undo()
      out.dry_run=true
      out.dry_note='nothing was changed: sections, stored and sends_down are what the change would make'..(a.remove_section~=nil and ' (the section to remove reads switched off, its stand-in)' or '')
    end
    -- trash unrequested, when set now or on: what robots take to storage (a chest's items no request names).
    local ton=tpoint and try(function() return tpoint.trash_not_requested end)
    part('trash_unrequested',function()
      if tpoint and (a.trash_unrequested~=nil or ton) then
        local named={}
        for i=1,secs.sections_count or 0 do
          local s_=secs.get_section(i)
          if s_ and s_.active~=false then
            for _,f in pairs(try(function() return s_.filters end) or {}) do local n=f.value and (type(f.value.name)=='string' and f.value.name or try(function() return f.value.name.name end)); if n then named[n]=true end end
          end
        end
        local away={}
        if chest then
          local inv=try(function() return chest.get_inventory(defines.inventory.chest) end)
          for _,st in ipairs(inv and try(function() return inv.get_contents() end) or {}) do
            if not named[st.name] then away[#away+1]=st.name..'*'..st.count end
          end
          table.sort(away)
        end
        out.trash_unrequested=ton and ('on: robots take to storage what no request names'..(chest and (#away>0 and ': '..table.concat(away,' ',1,math.min(#away,8))..(#away>8 and ' ...' or '') or ' (it holds none now)') or ''))
          or 'off: what no request names stays'
      end
    end)
    -- (d20 batch132 PD1, Sol #2093: pods of 1000 and 300 came down for a request of 300, and the circuit-set request
    -- of 1000 was gone when Sol read the pad) a landing pad: what it counts on the way, the cargo pods coming down to
    -- it by the game's count (its requester point's deliveries; 2.0.77 on a copy of world n: 1300 from the hub's launch
    -- to the landing)
    part('on_the_way',function()
      if chest and chest.type=='cargo-landing-pad' and tpoint then
        local way={}
        for _,it in ipairs(try(function() return tpoint.targeted_items_deliver end) or {}) do
          local q=type(it.quality)=='table' and it.quality.name or it.quality
          way[#way+1]=it.name..(q and q~='normal' and '@'..q or '')..'*'..it.count
        end
        table.sort(way)
        out.on_the_way=#way>0 and table.concat(way,' ')..' (cargo pods coming down to it)' or 'nothing'
      end
    end)
    -- The character's requests not filled, each with why (personal.lua; Haiku, d15: 10 repair packs never came).
    part('unfilled',function()
      if label=='character' and api.personal then
        local rows=try(function() return api.personal().unfilled(p) end)
        if rows and #rows>0 then
          local lines={}
          for i,r in ipairs(rows) do if i<=12 then lines[i]=r.line end end
          out.unfilled=lines
        end
      end
    end)
    -- Requests set into a section that is off are not made: say so.
    part('note',function()
      local off={}
      for _,row in ipairs(out.sections or {}) do if row.off and #row.requests>0 and not (a.dry_run and row.index==a.remove_section) then off[#off+1]=row.index end end
      if #off>0 then
        out.note=string.format('section%s %s %s switched off: %s requests are not made (requests {section, active: true} switches one on)',
          #off>1 and 's' or '',table.concat(off,', '),#off>1 and 'are' or 'is',#off>1 and 'their' or 'its')
      end
    end)
    out.changed_section=changed and touched_index or nil
    -- (QU3) the section written, before the call and now
    if changing and touched and try(function() return touched.valid end) ~= false then
      local now_i=try(function() return touched.index end)
      local k=0
      if now_i and try(function() return touched.is_manual end) then
        for i=1,now_i do if secs.get_section(i).is_manual then k=k+1 end end
      end
      local was
      if k>0 then
        local m=0
        for i=1,#rows_before do if rows_before[i].manual then m=m+1; if m==k then was=rows_before[i]; break end end end
      end
      if now_i and was and was.index<=#rows_before and not (a.add_section and now_i>#rows_before) then
        out.section_before={index=was.index,group=was.group,active=was.active}
      end
      if now_i then out.section_after={index=now_i,group=try(function() return touched.group~='' and touched.group or nil end),active=try(function() return touched.active~=false end)} end
    end
    out.section_moved=section_moved
    out.section_group=a.section_group
    out.sections_note=#others>0 and others or nil
    out.section_change=#section_change>0 and section_change or nil
    out.group=group_change
    out.group_edit=group_edit
    if changing and not changed then out.unchanged='this call set, cleared and switched nothing in section '..(touched_index or '?') end
    out.stored=stored and #stored>0 and stored or nil
    part('construction_requests',function()
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
    end)
    -- A hub: what is over a max goes to its trash, and where the trash goes.
    part('hub_trash',function()
      if a.platform~=nil or (chest and chest.type=='space-platform-hub') then
        local pl=a.platform~=nil and M.platform(p,a.platform) or chest.surface.platform
        local hub=pl and pl.hub
        if hub and hub.valid then
          local over,overs={},{}
          local main=try(function() return hub.get_inventory(defines.inventory.hub_main) end)
          -- the planet each request imports from, as the hub's sections hold it after the call
          local from={}
          local hs=try(function() return hub.get_logistic_sections() end)
          for i=1,hs and hs.sections_count or 0 do
            local sec=hs.get_section(i)
            for _,f in ipairs(sec.active~=false and try(function() return sec.filters end) or {}) do
              local v=f.value
              if v and v.name and f.import_from then from[v.name..'@'..(v.quality or 'normal')]=try(function() return f.import_from.name end) or f.import_from end
            end
          end
          for _,e in ipairs(entries) do
            local held=e.max and main and try(function() return main.get_item_count({name=e.name,quality=e.quality}) end) or 0
            if e.max and held>e.max then
              local src=from[e.name..'@'..(e.quality or 'normal')]
              over[#over+1]=string.format('%s: the hub holds %d, %d over the max %d%s',e.name,held,held-e.max,e.max,src and ' (from '..src..')' or '')
              overs[#overs+1]={name=e.name,from=src}
            end
          end
          local trash=defines.inventory.hub_trash and try(function() return hub.get_inventory(defines.inventory.hub_trash) end)
          out.hub_trash=trash and top_items(trash,12) or nil
          out.over_max=#over>0 and over or nil
          if out.hub_trash or out.over_max then out.trash_note=M.trash_note(pl,#overs>0 and overs or nil) end
        end
      end
    end)
    if out.reply_failed then
      out.reply_failed_note=(a.dry_run and 'nothing was changed (dry run)' or changed and 'the change was made (stored, changed_section)' or 'nothing was changed')
        ..'; these parts of the reply failed and are left out'
    end
    return out
  end
  -- Platforms -----------------------------------------------------------------
  top_items=function(inv,limit)
    local list=inv and inv.get_contents() or {}
    table.sort(list,function(x,y) return x.count>y.count end)
    if #list==0 then return nil end
    local out={}
    for i=1,math.min(#list,limit) do local s=list[i]; out[i]=s.name..(s.quality and s.quality~='normal' and '@'..s.quality or '')..'*'..num(s.count) end
    return #list>limit and table.concat(out,' ')..string.format(' +%d more',#list-limit) or table.concat(out,' ')
  end
  local function schedule_text(pl)
    local sch=pl.schedule
    if not (sch and sch.records and #sch.records>0) then return nil end
    local parts={}
    for i,r in ipairs(sch.records) do
      local function wait_text(w)
        -- (d17 batch31 B9) a count or circuit wait with its condition (none: the game compares nothing); the harness's
        -- never-holding circuit wait (platwait.lua) as what it is
        local c=w.condition
        local f=type(c)=='table' and c.first_signal and c.first_signal.name
        local text
        if f=='signal-dot' and c.constant==-2147483648 then text='the harness sends it on'
        elseif w.type=='item_count' or w.type=='fluid_count' or w.type=='circuit' then
          text=w.type..(f and ' '..sigtext(c.first_signal)..' '..(({['≥']='>=',['≤']='<=',['≠']='!='})[c.comparator] or c.comparator or '?')..' '..tostring(c.constant or (c.second_signal and sigtext(c.second_signal)) or 0) or ' with no condition')
        else text=w.type..(w.ticks and ' '..math.floor(w.ticks/60)..'s' or '') end
        return text
      end
      -- (d18 batch36 A3) as the game evaluates them: and binds before or; a branch that leaves with no fuel, oxidizer or
      -- ammunition condition another branch has is named
      local grouped,notes=M.waitgroups.text(r.wait_conditions,wait_text)
      parts[i]=(i==sch.current and '>' or '')..(r.station or '?')..(r.allows_unloading==false and ' [unloading off]' or '')..(grouped and ' ('..grouped..')' or '')..(notes and ' ['..table.concat(notes,'; ')..']' or '')
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
      out.turned_back=l.turned_back  -- (CN1) it left heading_to and turned back mid-connection
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
    -- (d22 batch96 BF1: a find of every entity aboard took 33 ms on a copy of world n's Asterion, and its limit of 5000
    -- left 2,957 of its 7,957 unread) the entities hit since the platform's list was seeded (platalerts.lua, from the
    -- game's damage events), each read now; the list is seeded by one read of every entity aboard
    local dm=api.plat_damaged and try(function() return api.plat_damaged(pl) end)
    if dm and dm.seeded then
      local gone={}
      for u,e in pairs(dm.set) do
        local h,m=e.valid and e.health,e.valid and e.max_health
        if h and m and m>0 and h<m then list[#list+1]={e=e,h=h,m=m} else gone[#gone+1]=u end
      end
      if #gone>0 and api.plat_damaged_forget then try(function() api.plat_damaged_forget(pl,gone) end) end
    else
      local hurt={}
      try(function()
        for _,e in ipairs(pl.surface.find_entities_filtered{force=pl.force}) do
          local h,m=e.health,e.max_health
          if h and m and m>0 and h<m then list[#list+1]={e=e,h=h,m=m}; hurt[#hurt+1]=e end
        end
      end)
      if api.plat_damaged_seed then try(function() api.plat_damaged_seed(pl,hurt) end) end
    end
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
  -- W(key, ...): whether the reply wants any of those keys (fields: only those are made; d22 batch96 BF1)
  local function every() return true end
  local function detail(pl,row,W)
    W=W or every
    -- The game's own value, km per tick (the stream tools read it; speed_kms is on every row).
    row.speed=W('speed') and try(function() return pl.speed and math.floor(pl.speed*1000+0.5)/1000 end) or nil
    local damaged=W('damaged_tiles') and try(function() return #pl.damaged_tiles end)
    row.damaged_tiles=damaged and damaged>0 and damaged or nil
    -- (d25 batch216 QAA1) foundation destroyed by asteroids (ghosts no one placed) and rebuilt by the platform (flightwatch.lua)
    row.foundation_lost=W('foundation_lost') and api.floor_read and try(function() return api.floor_read(pl) end) or nil
    local chunks=W('asteroid_chunks') and try(function() return pl.find_asteroid_chunks_filtered{} end)
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
      local thrusters=W('thrusters','thrust_inputs') and try(function() return s.find_entities_filtered{type='thruster'} end) or {}
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
        -- (d27 batch294 TQ) by quality: quality multiplies a thruster's burn and thrust
        local gr,_,qtext=nil,nil,nil
        if api.thrust_groups then gr,_,qtext=api.thrust_groups(thrusters) end
        row.thrusters=string.format('%d%s, lowest tank %d%%',#thrusters,qtext and ((gr and #gr>1) and ': '..qtext or ' '..qtext) or '',math.floor(low*100))
        -- What they lack and the chain behind it (thrust.lua): a line per input under half full.
        local t=W('thrust_inputs') and api.thrust and try(function() return api.thrust(pl) end)
        row.thrust_inputs=t and #t.lines>0 and t.lines or nil
      end
      -- (by name: half the time of a count by type, the ghosts' prototypes being named as their types)
      local ghosts=W('unbuilt_ghosts') and try(function() return s.count_entities_filtered{name={'entity-ghost','tile-ghost'}} end)
      row.unbuilt_ghosts=ghosts and ghosts>0 and ghosts or nil
      -- Inserters taking from the hub with nothing to drop into: they put
      -- the hub's items on the tile at their drop point (empty space: thrown
      -- overboard).
      local hub=pl.hub
      local drains={}
      -- (d22 batch96 BF1) the inserters whose pickup can reach the hub: within 4 tiles of its box (a long-handed
      -- inserter picks up 2 tiles out); every inserter aboard was read before, at most 500
      local hb=hub and hub.valid and try(function() return hub.bounding_box end)
      local hp=not hb and hub and hub.valid and try(function() return hub.position end)
      local near=hb and {{hb.left_top.x-4,hb.left_top.y-4},{hb.right_bottom.x+4,hb.right_bottom.y+4}}
        or hp and {{hp.x-6,hp.y-6},{hp.x+6,hp.y+6}}
      for _,i in ipairs(near and W('hub_inserters_without_target') and try(function() return s.find_entities_filtered{type='inserter',area=near} end) or {}) do
        if hub and try(function() return i.pickup_target==hub and not i.drop_target end) then
          local d=i.drop_position
          local tile=try(function() return s.get_tile(math.floor(d.x),math.floor(d.y)).name end) or '?'
          drains[#drains+1]=string.format('(%g,%g) drops onto %s',i.position.x,i.position.y,tile)
        end
      end
      row.hub_inserters_without_target=#drains>0 and drains or nil
      -- The game's item statistics for this platform's surface, last 10 minutes.
      local stats=W('consumed_10min','produced_10min') and try(function() return pl.force.get_item_production_statistics(s) end)
      if stats then
        for _,c in ipairs({{'output','consumed_10min'},{'input','produced_10min'}}) do
          local list={}
          for name,all in pairs(try(function() return c[1]=='output' and stats.output_counts or stats.input_counts end) or {}) do
            local n=try(function() return qflow.flow(stats,name,c[1],defines.flow_precision_index.ten_minutes,true,all) end)
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
    local ejected=W('thrown_overboard') and try(function() return pl.ejected_items end)
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
    local free=inv and try(function() return inv.count_empty_stacks(true, false) end)
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
          -- (d26 batch249 R10) by the ghost's quality: it waits for that quality's item
          local gq=try(function() return g.quality.name end) or 'normal'
          local key=gq=='normal' and gname or gname..'@'..gq
          turrets_need[key]=(turrets_need[key] or 0)+1
          if #rows<8 then rows[#rows+1]=string.format('%s ghost (%g,%g) on %d empty tile%s %s',gname,g.position.x,g.position.y,#holes,#holes==1 and '' or 's',table.concat(holes,' ',1,math.min(6,#holes))) end
        end
      end
    end
    if #empty==0 then return nil end
    -- (d26 batch249 R10) foundation of every quality, named when any is above normal
    local held,held_by=0,nil
    if inv then held,held_by=qflow.held(inv,'space-platform-foundation') end
    local short=math.max(0,#empty-held)
    local items={}
    for key,n in pairs(turrets_need) do
      local gname,gq=key:match('^([^@]+)@?(.*)$')
      gq=gq~='' and gq or 'normal'
      local it=try(function() return prototypes.entity[gname].items_to_place_this[1].name end) or gname
      local have=inv and (try(function() return inv.get_item_count{name=it,quality=gq} end) or 0) or 0
      if have<n then items[#items+1]=string.format('%d %s%s (hub has %d)',n-have,it,gq=='normal' and '' or '@'..gq,have) end
    end
    table.sort(items)
    return string.format('defense ghosts wait on foundation: %s; their footprints take %d foundation tiles (* marks the %d with a foundation ghost planned), the hub holds %s space-platform-foundation: the least to bring %s%s',
      table.concat(rows,'; '),#empty,planned_n,qflow.text(held,held_by),short>0 and short..' space-platform-foundation' or 'no more foundation',#items>0 and ', '..table.concat(items,', ') or '')
  end
  function M.blockers(pl)
    local hub=pl.hub
    if not (hub and hub.valid) then return nil end
    local inv=hub.get_inventory(defines.inventory.hub_main)
    local s=pl.surface
    local out={}
    local free=try(function() return inv.count_empty_stacks(true, false) end)
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
    -- (d17 batch33 A1, Sol: Wayfarer's 1597 entity ghosts and 3318 tile ghosts read as the first 1000 and 3000) past a
    -- cap the counts come from a tally across ticks (ghosttally.lua): exact once it is done (kept 30 s), and until then
    -- the first ones counted, said as such, with the tally running
    local tallied
    -- (d22 batch96 BF1) ghosts of either kind counted first, in one count: most platforms have none, and a count makes
    -- no entity objects (the compact platforms read made two finds of each platform here). By name: the ghosts'
    -- prototypes are named as their types, and a count by name took half the time of one by type (19 platforms on a copy
    -- of world n: 1.3 ms against 2.7-3.4 ms).
    local any=try(function() return s.count_entities_filtered{name={'entity-ghost','tile-ghost'},limit=1} end)
    for _,kind in ipairs({'entity-ghost','tile-ghost'}) do
      local cap=M.GHOST_CAP[kind]
      local list=any==0 and {} or try(function() return s.find_entities_filtered{type=kind,limit=cap} end) or {}
      lists[kind]=list
      if #list>=cap then
        local total=try(function() return s.count_entities_filtered{type=kind} end) or #list
        if total>#list then short[#short+1]=string.format('the first %d of %d %ss counted',#list,total,kind) end
      end
    end
    if #short>0 and api.ghost_tally and api.ghost_tally() then
      local T=api.ghost_tally()
      local d=T.get(pl)
      if d then
        tallied=string.format('every ghost counted (%d entity ghosts, %d tile ghosts) across ticks %ds ago',d.counts['entity-ghost'] or 0,d.counts['tile-ghost'] or 0,math.floor((game.tick-d.tick)/60))
        for _,k in ipairs(d.order) do local w=d.need[k]; need[k]={name=w.name,quality=w.quality,count=w.count}; order[#order+1]=k end
        short={}
      else
        short[#short+1]='every ghost is being counted across ticks (1000 a tick): read again in a few seconds'
      end
    end
    for _,kind in ipairs(tallied and {} or {'entity-ghost','tile-ghost'}) do
      local list=lists[kind]
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
    if #missing>0 then out[#out+1]='ghosts wait for items the hub lacks: '..table.concat(missing,', ')..(#short>0 and ' ('..table.concat(short,'; ')..')' or '')..(tallied and ' ('..tallied..')' or '') end
    -- Past a cap the hub may hold enough for the ghosts counted and not for the rest: what the counted ones need.
    if #short>0 then out[#out+1]='ghost count capped ('..table.concat(short,'; ')..'): the counted ghosts need '..(#counted>0 and table.concat(counted,', ') or 'nothing') end
    -- Defense ghosts waiting on foundation (Sol 00:21: 173 foundation missing; a spare rocket turret in the hub could not
    -- build): each turret ghost with tiles of empty space under it, those tiles, whether foundation ghosts are planned
    -- there, and the least foundation the hub needs for all of them.
    local line=try(function() return M.defense_waits(pl,lists['entity-ghost'] or {},lists['tile-ghost'] or {},inv) end)
    if line then out[#out+1]=line end
    -- Tile ghosts the foundation rules hold back.
    -- (BF1) with no ghost there is no tile ghost to hold back: no second find
    for _,line2 in ipairs(any~=0 and try(function() return tiles.stalled(pl) end) or {}) do out[#out+1]=line2 end
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
          -- (d21 batch66 AB4) stopped at a station reading no_schedule counts as there too (waiting_now)
          local here=(pl.state==defines.space_platform_state.waiting_at_station or pl.state==defines.space_platform_state.no_schedule)
            and not try(function() return pl.space_connection end) and try(function() return pl.space_location.name end) or false
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
    local first=c.first_signal and c.first_signal.name and sigtext(c.first_signal) or '?'
    local right=c.second_signal and c.second_signal.name and sigtext(c.second_signal) or tostring(c.constant or 0)
    local cmp=({['≥']='>=',['≤']='<=',['≠']='!='})[c.comparator] or c.comparator or '<'
    return first..' '..cmp..' '..right
  end
  local function compare(a,cmp,b)
    if cmp=='<' then return a<b elseif cmp=='>' then return a>b elseif cmp=='=' then return a==b
    elseif cmp=='>=' or cmp=='≥' then return a>=b elseif cmp=='<=' or cmp=='≤' then return a<=b else return a~=b end
  end
  -- (d26 batch231 RG, Astra #2427: at 66620993 Kestrel II, waiting at Fulgora on item_count low-density-structure >=
  -- 3500, had its Fulgora request lowered to max 2100; 1400 went down and the wait could not hold) the item_count waits
  -- of the stop it waits at and of its next stop that a requests change leaves unmet: at a stop the hub keeps at most
  -- the maxes of its requests from that planet added up (KEEP_RULE), so a wait for more cannot hold there. before,
  -- after: hub_keep_at; only items whose max there the change altered. Lines or nil.
  function M.gate_lines(pl,hub,before,after)
    local sch=pl and try(function() return pl.schedule end)
    local recs=sch and sch.records or {}
    local n=#recs
    if n==0 then return nil end
    local cur=sch.current or 1
    local here=try(function() return pl.space_location.name end)
    local st=platform_states[pl.state]
    local waiting=recs[cur] and recs[cur].station==here and (st=='waiting_at_station' or st=='no_schedule' and M.waiting_now(pl)~=nil)
    local stops=waiting and {{i=cur,when='where it waits now'}} or {{i=cur,when='its next stop'}}
    if waiting and n>1 then stops[2]={i=cur%n+1,when='its next stop'} end
    local inv=hub and try(function() return hub.get_inventory(defines.inventory.hub_main) end)
    local lines={}
    for _,s_ in ipairs(stops) do
      local rec=recs[s_.i]
      local planet=rec.station
      local conds=rec.wait_conditions or {}
      local any_or=false
      for k,w in ipairs(conds) do if k>1 and w.compare_type=='or' then any_or=true end end
      for _,w in ipairs(conds) do
        local c=w.condition
        local sig=w.type=='item_count' and type(c)=='table' and c.first_signal
        if sig and sig.name and c.constant and not c.second_signal then
          local q=sig.quality
          if type(q)~='string' then q=q and try(function() return q.name end) or 'normal' end
          local key=sig.name..'@'..q
          local keep=(after[planet] or {})[key]
          local was=(before[planet] or {})[key]
          local cmp=({['≥']='>=',['≤']='<=',['≠']='!='})[c.comparator] or c.comparator or '<'
          local need=(cmp=='>=' or cmp=='=') and c.constant or cmp=='>' and c.constant+1 or nil
          if need and keep and keep~=math.huge and keep<need and keep~=was then
            local held=inv and try(function() return inv.get_item_count({name=sig.name,quality=q}) end) or 0
            lines[#lines+1]=string.format('%s: stop %d (%s), %s, waits for item_count %s; its requests from %s would keep at most %d there (were %s), so that wait cannot hold while it is there (the hub holds %d now)%s',
              key_label(key),s_.i,planet,s_.when,cond_text(c),planet,keep,was==nil and 'none' or was==math.huge and 'no max' or tostring(was),held,
              any_or and '; the stop\'s waits are joined by or: another group can send it on' or '')
          end
        end
      end
    end
    return #lines>0 and lines or nil
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
    elseif t=='circuit' and w.condition and w.condition.first_signal then
      -- (d17 batch31 B1, Luna) what the hub's wires read of the condition's signals now
      local c=w.condition
      if c.first_signal.name=='signal-dot' and c.constant==-2147483648 then return 'the harness sends it on (platwait)' end
      local function wires(sig)
        local n,wired=0,false
        for _,id in ipairs({defines.wire_connector_id.circuit_red,defines.wire_connector_id.circuit_green}) do
          local net=pl.hub and pl.hub.valid and try(function() return pl.hub.get_circuit_network(id) end)
          if net then wired=true; n=n+(try(function() return net.get_signal(sig) end) or 0) end
        end
        return wired and n or nil
      end
      local a=wires(c.first_signal)
      local b=c.second_signal and wires(c.second_signal) or c.constant or 0
      if a==nil then text=text..': the hub has no circuit wire (the condition reads 0)'
      else
        local met=compare(a,c.comparator or '<',b)
        text=text..string.format(': the hub\'s wires read %s %d%s (%s)',sigtext(c.first_signal),a,c.second_signal and string.format(', %s %d',sigtext(c.second_signal),b) or '',met and 'met' or 'not met')
      end
    elseif t=='all_requests_satisfied' or t=='any_request_satisfied' or t=='any_request_not_satisfied' or t=='request_satisfied' or t=='request_not_satisfied' then
      local rows,total=unmet(pl)
      local parts={}
      for i=1,math.min(4,#rows) do parts[i]=string.format('%s %d/%d',rows[i].name,rows[i].n,rows[i].min) end
      text=text..string.format(': %d of %d requests unmet%s',#rows,total,#parts>0 and ' ('..table.concat(parts,', ')..(#rows>4 and ', ...' or '')..')' or '')
    end
    return text
  end
  -- (d21 batch66 AB4, Sol #1681: Solstice at Nauvis, current stop 1 nauvis, read no_schedule from tick 42819577 to
  -- 42828245 while its wait processing-unit >= 300 was false (246 in the hub, none on the way at 42825293), and left by
  -- 42829613 once 346 had come; the recheck said the call failed) a platform stopped at the station of its current
  -- stop, not paused, reading waiting_at_station or no_schedule, waits there on that stop's conditions, as the schedule
  -- GUI shows. Whether one condition holds now: true, false, or nil (not read).
  local function cond_now(pl,w,arrived)
    local t,c=w.type,w.condition
    if t=='time' then
      if not arrived.tick then return nil end
      return (w.ticks or 0)-(game.tick-arrived.tick)<=0
    elseif t=='inactivity' then
      local last=try(function() return pl.get_schedule().tick_of_last_activity end) or 0
      return game.tick-math.max(last,arrived.tick or arrived.first or 0)>=(w.ticks or 0)
    elseif t=='item_count' and c and c.first_signal and not c.second_signal then
      local inv=pl.hub and pl.hub.valid and try(function() return pl.hub.get_inventory(defines.inventory.hub_main) end)
      local n=inv and try(function() return inv.get_item_count({name=c.first_signal.name,quality=c.first_signal.quality or 'normal'}) end) or 0
      return compare(n,c.comparator or '<',c.constant or 0)
    elseif t=='circuit' and c and c.first_signal then
      if c.first_signal.name=='signal-dot' and c.constant==-2147483648 then return false end
      local function wires(sig)
        local n=0
        for _,id in ipairs({defines.wire_connector_id.circuit_red,defines.wire_connector_id.circuit_green}) do
          local net=pl.hub and pl.hub.valid and try(function() return pl.hub.get_circuit_network(id) end)
          if net then n=n+(try(function() return net.get_signal(sig) end) or 0) end
        end
        return n
      end
      return compare(wires(c.first_signal),c.comparator or '<',c.second_signal and wires(c.second_signal) or c.constant or 0)
    elseif t=='all_requests_satisfied' then return #unmet(pl)==0
    elseif t=='any_request_not_satisfied' then return #unmet(pl)>0
    end
    return nil
  end
  -- {stop, station, game_state, met (true, false, or nil: some not read), conditions [{text, holds, join}], line}, or nil
  -- when it is not stopped at its current stop's station. The conditions are joined as the game joins them (and binds
  -- before or).
  -- (d24 batch139 PK1, Sol #2115) a paused platform's state note: it goes nowhere; stopped at a planet, its hub sends
  -- pods down there all the same (AB6's copy at Fulgora; Sol's watch 283 at Nauvis: 2000 landed)
  function M.paused_note(pl)
    local here=not try(function() return pl.space_connection end) and try(function() return pl.space_location.name end)
    return 'state paused: the platform goes nowhere until unpaused (paused: false)'..(here and try(function() return game.planets[here] end)
      and '; stopped at '..here..', its hub sends pods down there all the same (by its sections for '..here..' and the landing pads\' asks)' or '')
  end
  function M.waiting_now(pl)
    local st=platform_states[pl.state]
    if st~='waiting_at_station' and st~='no_schedule' then return nil end
    if try(function() return pl.paused end) or try(function() return pl.space_connection end) then return nil end
    local sch=try(function() return pl.schedule end)
    local records=sch and sch.records or {}
    local cur=sch and sch.current or 1
    local rec=records[cur]
    local here=try(function() return pl.space_location.name end)
    if not (rec and here and rec.station==here) then return nil end
    local S=api.state and api.state()
    local arrived=S and S.platform_stops and S.platform_stops[pl.index] or {}
    if arrived.at~=here then arrived={} end
    local g={ok=true,words={}}
    local groups,conds={g},{}
    for k,w in ipairs(rec.wait_conditions or {}) do
      if k>1 and w.compare_type=='or' then g={ok=true,words={}}; groups[#groups+1]=g end
      local ok=cond_now(pl,w,arrived)
      local text=wait_text(pl,w,true,arrived)
      conds[#conds+1]={text=text,holds=ok,join=k>1 and (w.compare_type=='or' and 'or' or 'and') or nil}
      g.words[#g.words+1]=text..(ok==true and ' [holds]' or ok==false and ' [false]' or ' [not read]')
      if ok==false then g.ok=false elseif ok==nil and g.ok then g.ok=nil end
    end
    local met=true
    if #conds>0 then
      local any,all_false=false,true
      for _,x in ipairs(groups) do if x.ok==true then any=true end; if x.ok~=false then all_false=false end end
      if any then met=true elseif all_false then met=false else met=nil end
    end
    local words={}
    for _,x in ipairs(groups) do words[#words+1]=table.concat(x.words,' and ') end
    local head=string.format('waiting at stop %d (%s): ',cur,here)
    local line=#conds==0 and head..'no wait condition'
      or head..(met==false and 'conditions false now: ' or met==true and 'conditions hold now: ' or 'conditions not all read: ')..table.concat(words,' or ')
    if st=='no_schedule' then
      line=line..(met==false and '; the game reads no_schedule while it waits there and leaves when they hold (Solstice at Nauvis, shift52)'
        or '; the game reads no_schedule')
    end
    return {stop=cur,station=here,game_state=st,met=met,conditions=conds,line=line}
  end
  function M.waiting_line(pl) local w=M.waiting_now(pl); return w and w.line or nil end
  -- the state note of a platform reading no_schedule while it waits at its current stop on conditions false now
  function M.waiting_note(pl,state)
    if state~='no_schedule' then return nil end
    local w=M.waiting_now(pl)
    return w and w.met==false and 'state no_schedule: '..w.line or nil
  end
  -- Each stop of the schedule: its wait conditions, where the platform waits
  -- (with how far each condition is) or which stop it flies to, and the next one.
  function M.stops(pl)
    local sch=try(function() return pl.schedule end)
    local records=sch and sch.records or {}
    if #records==0 then return nil end
    local cur=sch.current or 1
    local here=try(function() return pl.space_location.name end)
    local waiting=M.waiting_now(pl)~=nil
    -- (d24 batch153, harness review bug 2: shipment read Petrel, paused at Nauvis with current 1 nauvis, "flying to it")
    -- paused, waiting_now is nil: stopped at a location it stands at that stop (as delivery_watch reads it), on a route
    -- it is paused on the way to its current stop
    local paused=try(function() return pl.paused end) and true or false
    local flying=try(function() return pl.space_connection end) and true or false
    local paused_at=paused and not flying and here and records[cur] and records[cur].station==here
    local st=api.state and api.state()
    local arrived=st and st.platform_stops and st.platform_stops[pl.index] or {}
    if arrived.at~=here then arrived={} end
    local nxt=(waiting or paused_at) and cur%#records+1 or cur
    local out={}
    for i,rec in ipairs(records) do
      local ws={}
      for k,w in ipairs(rec.wait_conditions or {}) do
        local text=wait_text(pl,w,waiting and i==cur,arrived)
        ws[#ws+1]=(k>1 and (w.compare_type=='or' and 'or ' or 'and ') or '')..text
      end
      local tag=waiting and i==cur and 'waiting here'
        or paused_at and i==cur and 'stopped here, paused: it goes nowhere until unpaused (paused: false)'
        or paused and i==cur and (flying and 'flying to it, paused on the route: it goes nowhere until unpaused (paused: false)'
          or 'the current stop; paused at '..tostring(here or '?')..': it goes nowhere until unpaused (paused: false)')
        or (i==nxt and ((waiting or paused_at) and 'next' or 'flying to it')) or nil
      -- (d24 batch142 PN1) unloading off: its landing pads take nothing from the hub there
      local off=rec.allows_unloading==false and 'unloading off: the landing pads take nothing from the hub here, all above a finite max still goes down' or nil
      if off and tag then tag=tag..'; '..off elseif off then tag=off end
      out[i]=string.format('%d %s%s: %s',i,rec.station or '?',tag and ' ('..tag..')' or '',#ws>0 and table.concat(ws,' ') or 'no wait condition')
      -- (C8, Grok) the stop it waits at: a queue step or order that sets its schedule may send it on before these waits
      if waiting and i==cur then
        local dep=api.departure and try(function() return api.departure(pl.name) end)
        if dep and #dep>0 then out[i]=out[i]..'; or sooner, when '..table.concat(dep,' | ')..' runs' end
      end
    end
    return out
  end
  -- platform_gate {platform} (d17 batch15 A3, Grok: the full Swift record before every agricultural launch): one line
  -- per platform: where it is (at a station, moving, stopped) and the current stop's departure conditions with what
  -- the hub holds against each, as the schedule GUI shows them.
  function M.gate(p,a)
    local lines,edits={},{}
    for _,pl in pairs(p.force.platforms) do
      if pl.valid and (a.platform==nil or pl.name==a.platform) then
        local st=platform_states[pl.state] or '?'
        local where=location(pl) or '?'
        local sch=try(function() return pl.schedule end)
        local records=sch and sch.records or {}
        local cur=sch and sch.current or 1
        local state
        if try(function() return pl.paused end) then state='stopped (paused)'
        elseif pl.state==defines.space_platform_state.waiting_at_station then state='at station '..where
        elseif M.waiting_now(pl) then state='at station '..where..' (the game reads no_schedule)'
        elseif pl.state==defines.space_platform_state.on_the_path then state='moving '..where
        else state='stopped ('..st:gsub('_',' ')..') at '..where end
        local gate
        if #records==0 then gate='no schedule'
        else
          local ls=M.stops(pl) or {}
          gate=string.format('stop %d of %d: %s',cur,#records,(ls[cur] or '?'):gsub('^%d+ ',''))
        end
        -- (d19 batch41 B1) the current stop's last edit, and every stop's in edits
        local last=api.editlog and api.editlog.text(api.editlog.last('gate:'..pl.name,cur))
        lines[#lines+1]=string.format('%s: %s; %s%s',pl.name,state,gate,last and '; stop '..cur..' '..last or '')
        for i=1,#records do
          local e=api.editlog and api.editlog.text(api.editlog.last('gate:'..pl.name,i))
          if e then edits[#edits+1]=string.format('%s stop %d: %s',pl.name,i,e) end
        end
      end
    end
    if a.platform~=nil and #lines==0 then error('no platform of ours named '..tostring(a.platform),0) end
    return {lines=lines,edits=#edits>0 and edits or nil,note='the schedule\'s wait conditions at the current stop, each with what the hub holds now; edits: each stop\'s last edit (who, when, old -> new); read only'}
  end
  -- platforms {compact: true} (Astra 13:50: the full read is long): a line a platform: where, ammunition aboard (hub
  -- and turrets), thruster fuel and its 10-minute trend, the ghosts' missing items in all, and only the blockers this
  -- agent was not shown in its last compact read.
  -- 'thruster fuel 1200 units (+3/min over 10 min)': in its thrusters and tanks, and the platform's net over 10 minutes.
  -- lists: the platform's background read's (freight.platform_lists), when the caller has them
  function M.fuel_text(pl,lists)
    local P=defines.flow_precision_index or {}
    local fuel=0
    -- (d22 batch96 BF1) the thrusters and tanks the background read listed when they are all there are, else a find
    local list=lists and lists.tanks
      or try(function() return pl.surface.find_entities_filtered{type={'thruster','storage-tank'},force=pl.force} end) or {}
    for _,e in ipairs(list) do
      for i=1,try(function() return #e.fluidbox end) or 0 do
        local f=try(function() return e.fluidbox[i] end)
        if f and f.name=='thruster-fuel' then fuel=fuel+f.amount end
      end
    end
    local fs=try(function() return pl.force.get_fluid_production_statistics(pl.surface) end)
    local function per(cat) return fs and P.ten_minutes and (try(function() return fs.get_flow_count{name='thruster-fuel',category=cat,precision_index=P.ten_minutes,count=true} end) or 0)/10 or 0 end
    local net=per('input')-per('output')
    return string.format('thruster fuel %d units (%s%d/min over 10 min)',math.floor(fuel+0.5),net>=0 and '+' or '',math.floor(net+0.5))
  end
  -- (BF1) an item's type read once per name: the compact read looked up every hub item of every platform
  local ammo_of={}
  local function is_ammo(name)
    local v=ammo_of[name]
    if v==nil then v=try(function() return prototypes.item[name].type end)=='ammo'; ammo_of[name]=v end
    return v
  end
  function M.platforms_compact(p,a)
    local st=api.state and api.state()
    local seen_all=st and st.platforms_compact_seen or {}
    if st then st.platforms_compact_seen=seen_all end
    local mine=seen_all[p.index] or {}
    seen_all[p.index]=mine
    -- (d22 batch96 BF1) every platform's departure lines in one walk of the queues and orders
    local deps=api.departure_all and try(function() return api.departure_all() end)
    local lines={}
    for _,pl in pairs(p.force.platforms) do
      if pl.valid and (a.platform==nil or pl.name==a.platform) and pl.surface then
        local parts={string.format('%s: %s',pl.name,location(pl) or platform_states[pl.state] or '?')}
        local ammo={}
        local hub=pl.hub
        local inv=hub and hub.valid and try(function() return hub.get_inventory(defines.inventory.hub_main) end)
        for _,s2 in ipairs(inv and try(function() return inv.get_contents() end) or {}) do
          if is_ammo(s2.name) then ammo[s2.name]=(ammo[s2.name] or 0)+s2.count end
        end
        -- (BF1) the turrets the platform's background read listed (freight.platform_lists: only when a count finds no
        -- other turret, thruster or tank aboard), else a find over the platform; the finds were 5.7 ms of the read for
        -- 19 platforms on a copy of world n, the count 1.5
        local lists=api.platform_lists and try(function() return api.platform_lists(pl) end)
        local turrets=lists and lists.turrets
          or try(function() return pl.surface.find_entities_filtered{type='ammo-turret',force=pl.force} end) or {}
        for _,t in ipairs(turrets) do
          local ti=try(function() return t.get_inventory(defines.inventory.turret_ammo) end)
          for _,s2 in ipairs(ti and try(function() return ti.get_contents() end) or {}) do ammo[s2.name]=(ammo[s2.name] or 0)+s2.count end
        end
        local al={}
        for n,c in pairs(ammo) do al[#al+1]=n..' '..c end
        table.sort(al)
        parts[#parts+1]='ammo '..(#al>0 and table.concat(al,', ') or 'none')
        parts[#parts+1]=M.fuel_text(pl,lists)
        local blk=try(function() return M.blockers(pl) end) or {}
        local missing=0
        for _,b in ipairs(blk) do
          for need,have in b:gmatch('ghosts need [^%d]*(%d+), hub has (%d+)') do missing=missing+math.max(0,tonumber(need)-tonumber(have)) end
        end
        parts[#parts+1]=missing>0 and string.format('ghosts lack %d items in all',missing) or 'ghosts lack nothing'
        local off=api.requests_off and try(function() return api.requests_off(pl) end)
        if off then parts[#parts+1]=off end
        local dep=api.departure and try(function() return api.departure(pl.name,deps) end)
        if dep then parts[#parts+1]='also sent on by '..table.concat(dep,' | ') end
        local was=mine[pl.name] or {}
        local now,new={},{}
        for _,b in ipairs(blk) do now[b]=true; if not was[b] then new[#new+1]=b end end
        mine[pl.name]=now
        local same=#blk-#new
        if #new>0 then parts[#parts+1]='new blockers: '..table.concat(new,' | ') end
        if same>0 then parts[#parts+1]=string.format('%d blocker%s as in your last compact read',same,same==1 and '' or 's') end
        lines[#lines+1]=table.concat(parts,'; ')
      elseif pl.valid and (a.platform==nil or pl.name==a.platform) and pl.state==defines.space_platform_state.waiting_for_starter_pack then
        -- (d26 batch229 SP) a platform with no surface yet waits for its starter pack: how long, and where it is in the
        -- game's order
        local sp=api.starterpack and api.starterpack()
        lines[#lines+1]=pl.name..': '..(sp and try(function() return sp.row_line(pl) end) or 'waiting for its starter pack')
      end
    end
    return {compact=true,lines=lines}
  end
  M.PAGE=2
  function M.platforms(p,a)
    -- (d20 batch62 X2, Sol #1529) a platform name that is none of ours is refused, never read as no platform
    if a.platform~=nil then
      local names={}
      for _,pl in pairs(p.force.platforms) do if pl.valid then names[#names+1]=pl.name end end
      local found=false
      for _,n in ipairs(names) do if n==a.platform then found=true end end
      table.sort(names)
      assert(found,'no platform of ours named '..tostring(a.platform)..'; platforms: '..(#names>0 and table.concat(names,', ') or 'none'))
    end
    -- (d22 batch90 AZ4, the AU1 review's finding 7: platforms with no arguments was 138 KB median and an agent saw 2 of
    -- 19 platforms of it through the host's pages) compact by default when no platform is named; compact: false gives
    -- the full rows
    if a.compact==true or (a.compact==nil and a.platform==nil) then
      assert(a.page==nil,'page goes with every platform\'s full row (compact: false): the compact lines come whole')
      local out=M.platforms_compact(p,a)
      if a.compact==nil then out.note='compact by default with no platform named: platforms {platform: NAME} reads one in full, compact: false every one in full, 2 a page' end
      return out
    end
    local out={platforms={}}
    local deps=api.departure_all and try(function() return api.departure_all() end)
    -- (d22 batch96 BF1: every platform's full row, 19 of them, was 62-102 ms and 118 KB in one call on a copy of world
    -- n) with no platform named, PAGE rows a page: page, pages, next
    assert(a.page==nil or (type(a.page)=='number' and a.page>=1 and a.page==math.floor(a.page)),'page is 1 or more')
    local want
    if a.platform==nil then
      local all={}
      for _,pl in pairs(p.force.platforms) do if pl.valid then all[#all+1]=pl end end
      local page=a.page or 1
      out.page,out.pages,out.count=page,math.max(1,math.ceil(#all/M.PAGE)),#all
      want={}
      for i=(page-1)*M.PAGE+1,math.min(#all,page*M.PAGE) do want[all[i].index]=true end
      if page<out.pages then out.next=string.format('platforms {compact: false, page: %d}',page+1) end
    else
      assert(a.page==nil,'page goes with every platform (compact: false and no platform named)')
    end
    -- (d22 batch96 BF1) with fields, the parts of a row only those fields need (__want, from the fields wrapper: the
    -- stream's platforms {platform} read 13 of a row's keys and was 11-15 ms a call on a copy of world n)
    local fw=a.__want
    local function W(...) if not fw then return true end for _,k in ipairs({...}) do if fw[k] then return true end end return false end
    for _,pl in pairs(p.force.platforms) do
      if pl.valid and (a.platform==nil or pl.name==a.platform) and (not want or want[pl.index]) then
        local row={name=pl.name,state=platform_states[pl.state],at=location(pl),paused=pl.paused or nil,
          starter_pack=pl.state==defines.space_platform_state.waiting_for_starter_pack and api.starterpack and try(function() return api.starterpack().row_line(pl) end) or nil,
          schedule=W('schedule') and schedule_text(pl) or nil,waiting=W('waiting') and try(function() return M.waiting_line(pl) end) or nil,stops=W('stops') and try(function() return M.stops(pl) end) or nil,departure=W('departure') and api.departure and try(function() return api.departure(pl.name,deps) end) or nil,deleting=pl.scheduled_for_deletion and pl.scheduled_for_deletion>0 or nil,
          weight=pl.weight and math.floor(pl.weight/1000) or nil}
        -- (d19 batch46 3) the latest edit of each setting: stops, paused, a request's minimum payload (min_payload)
        row.setting_edits=W('setting_edits') and api.editlog and try(function() return api.editlog.lines('plat:'..pl.name) end) or nil
        for k,v in pairs(M.flight(pl) or {}) do row[k]=v end
        local hub=pl.hub
        if hub and hub.valid then
          row.hub=hub.position
          row.hub_items=W('hub_items') and top_items(hub.get_inventory(defines.inventory.hub_main),a.platform and 64 or 12) or nil
          row.hub_slots=W('hub_slots') and M.hub_slots(hub) or nil
          -- Each spoilable item's spread in the hub and, for a pack the running research takes, how many a unit it
          -- takes and its units left (Sol, 22:52: 1960 agricultural packs aboard Sunward, judged before departure).
          local trash=defines.inventory.hub_trash and try(function() return hub.get_inventory(defines.inventory.hub_trash) end)
          local leg=W('freshness') and freight.leg(pl)
          row.freshness=W('freshness') and api.fresh_inv and try(function() return api.fresh_inv(pl.force,hub.get_inventory(defines.inventory.hub_main),nil,leg and leg.eta_ticks,trash) end) or nil
          row.hub_chunks=W('hub_chunks') and try(function() return M.hub_chunks(hub) end) or nil
          row.hub_trash=W('hub_trash','hub_trash_note') and trash and top_items(trash,12) or nil
          row.hub_trash_note=row.hub_trash and M.trash_note(pl) or nil
          local secs=W('requests','imports','requests_off','requests_off_line','request_edits') and hub.get_logistic_sections()
          if secs then
            local req,off,imports={},{},{}
            local edits={}
            for _,s in ipairs(list_sections(secs,true,hub.unit_number,hub)) do
              for _,r in ipairs(s.requests) do if s.off then off[#off+1]=r else req[#req+1]=r end end
              for _,r in ipairs(s.imports or {}) do imports[#imports+1]=r end
              if s.last_edit then edits[#edits+1]='section '..s.index..': '..s.last_edit end
            end
            -- (d19 batch41 B1) the last edit of each section edited since the edit log began; (d22 batch90 AZ4) with
            -- request_edits: true only (52 KB of the 166 KB full read on a copy of world n, edits up to 40 h old)
            row.request_edits=a.request_edits==true and #edits>0 and edits or nil
            row.requests=#req>0 and req or nil
            -- (d20 batch55 P6) each import request: asks, holds, on the way in rockets launched to the hub, lacks
            row.imports=#imports>0 and imports or nil
            -- In a section switched off: not requested.
            row.requests_off=#off>0 and off or nil
            row.requests_off_line=api.requests_off and try(function() return api.requests_off(pl) end) or nil
          end
          row.leave_ok=W('leave_ok') and pl.can_leave_current_location and pl.can_leave_current_location() or nil
          -- Hub health, turrets, turret ammo against the hub's, repair packs.
          row.defense=W('defense') and api.defense and try(function() return api.defense(pl) end) or nil
        end
        -- Damaged entities, most damaged first (10 with platform=, else 3)
        -- with damaged_count, and the hub's repair packs.
        if pl.surface and W('repair_packs','damaged','damaged_count') then
          local repair=M.repair_view(pl)
          local list=repair.damaged or {}
          local count=repair.damaged_count or #list
          if not a.platform and #list>3 then list={list[1],list[2],list[3]} end
          row.repair_packs,row.damaged=repair.repair_packs,#list>0 and list or nil
          row.damaged_count=count>#list and count or nil
        end
        if a.platform then
          detail(pl,row,W); row.construction_blocked=W('construction_blocked') and try(function() return M.blockers(pl) end) or nil
          row.tile_removals=W('tile_removals') and try(function() return M.tile_removals(pl) end) or nil
          -- (d17 batch31 B9) the stop waits the harness keeps for it
          row.harness_waits=W('harness_waits') and api.platwait and try(function() return api.platwait().line(pl.name) end) or nil
          -- (d18 batch36 A2) a silo at its stop that lacks a rocket-part ingredient its own hub holds
          row.launch_needs=W('launch_needs') and api.launch_need and try(function() return api.launch_need(pl) end) or nil
          -- (d18 batch37 B2) each stop's item wait: the planet's stock and its production rate against it
          row.wait_facts=W('wait_facts') and api.wait_need and try(function() return api.wait_need(pl) end) or nil
          -- Its last stops and legs (expected, left, came aboard, spoiled, rockets) and its spoilable items now
          -- against the arrival (Luna, shift12 12:47).
          local fr=W('freight') and try(function() return freight.read(pl) end)
          if fr then row.freight={}; for i,s in ipairs(fr) do row.freight[i]=s.line end end
          -- (d17 batch23 A3) each cargo pod's landed receipt, kept apart from the stops
          row.landed=W('landed') and freight.receipts and try(function() return freight.receipts(pl) end) or nil
          row.spoiling=W('spoiling') and try(function() return freight.freshness(pl) end) or nil
          -- Per ammo type over the last leg, and rockets on their way up to it (freight.lua; Astra, 22:50).
          row.ammo_rates=W('ammo_rates') and try(function() return freight.ammo(pl) end) or nil
          local inc=W('incoming','incoming_cargo') and try(function() return freight.incoming(pl) end)
          if inc then row.incoming=inc.lines; row.incoming_cargo=string.format('%d rocket%s on the way: %s',inc.rockets,inc.rockets==1 and '' or 's',inc.cargo) end
          -- Its flight over the last 60 and 180 s (engine.lua; Astra, 21:20).
          local en=W('engine') and api.engine and try(function() return api.engine(pl) end)
          row.engine=en and en.lines or nil
          -- What its thrusters keep burning when their pumps stop, and the thruster's burn as the game runs it
          -- (thrust.lua; Grok, shift17 20:40: a pump cut at V >= 15 and the leg peaked at 51 km/s).
          local ap=W('after_pumps','thruster_burn') and api.thrust_after and try(function() return api.thrust_after(pl) end)
          if ap then row.after_pumps=ap.lines; row.thruster_burn=ap.rule end
        end
        out.platforms[#out.platforms+1]=row
      end
    end
    -- Silos on the character's surface: what the launch button would send.
    local silos={}
    if not W('silos') then out.planet=p.surface.planet and p.surface.planet.name or nil; return out end
    -- (d19 batch44 A2: this find was about 10.5 ms on the private copy's Nauvis in every platform read, 228 an hour in
    -- shifts 39-41) the census pass's silos when it has them
    local known=api.census_typed and try(function() return api.census_typed(p.force,p.surface,'rocket-silo') end)
    for i,e in ipairs(known or p.surface.find_entities_filtered{type='rocket-silo',force=p.force,limit=16}) do
      if i>16 then break end
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
    assert(a.name==nil or (type(a.name)=='string' and #a.name>=1 and #a.name<=M.NAME_MAX),'name must be 1..'..M.NAME_MAX..' characters')
    local pl=p.force.create_space_platform{name=a.name,planet=planet,starter_pack=pack}
    assert(pl,'the game refused to create a platform')
    if api.chronicle_created then pcall(api.chronicle_created,pl,p.name) end  -- who made it (chronicle.lua)
    -- (d26 batch229 SP, Sol: Loom's pack went to Aethera, waiting at Vulcanus since 89h) the others waiting there, and
    -- which one the game sends a pack to
    local sp=api.starterpack and api.starterpack()
    if sp then pcall(sp.made,pl,game.tick) end
    local queue=sp and try(function() return sp.queue_line(p.force,planet,2) end)
    return {name=pl.name,state=platform_states[pl.state],planet=planet,starter_queue=queue,
      next='a rocket silo on '..planet..' with a '..pack..' in its rocket cargo (transfer item='..pack..', inventory rocket_silo_rocket) launches it on its own once the rocket is ready'}
  end
  -- Records: {station=planet, wait={{type,ticks?,compare?}}}; the game's
  -- wait types include all_requests_satisfied, any_request_zero,
  -- any_request_not_satisfied, time, inactivity, item_count, circuit.
  -- (B9) what world n showed of the game's fluid_count stop condition on a platform
  local FLUID_NOTE='on world n the game\'s fluid_count stop condition on a platform did not hold while its storage tanks held more: Cinder at Gleba (2026-10-18 14:23 UTC) waited over 5 min on thruster-fuel >= 22000 and thruster-oxidizer >= 22000 with 26000 of each in its tanks; the API does not say what it reads, and the hub holds no fluid. What reads the tanks: a circuit wait, with the tanks wired (red or green) to the hub, their contents on the wire (Cinder\'s hub read 25000 of each so), or harness: true on the wait (the harness reads the tanks and sends the platform on)'
  -- One stop's waits as the game's records take them, and the harness's watch for it (B9), or nil; runs and read_as get
  -- their lines. Shared by stops and by stop (B8).
  -- Wait lists kept by name (save_as / wait_from), as written; the harness's storage, no defaults.
  function M.saved_waits(i,stop,read_as,p)
    if stop.save_as==nil and stop.wait_from==nil then return stop end
    local st=api.state and api.state()
    assert(st,'saved waits need the harness storage')
    st.saved_waits=st.saved_waits or {}
    local out={}
    for k,v in pairs(stop) do if k~='save_as' and k~='wait_from' then out[k]=v end end
    if stop.wait_from~=nil then
      assert(stop.wait==nil,'stop '..i..': wait_from takes the saved wait list; give wait or wait_from, not both')
      local saved=st.saved_waits[stop.wait_from]
      if not saved then
        local names={}
        for n in pairs(st.saved_waits) do names[#names+1]=n end
        table.sort(names)
        error(string.format('stop %d: no wait list saved as %s (saved: %s)',i,tostring(stop.wait_from),#names>0 and table.concat(names,', ') or 'none'),0)
      end
      out.wait=saved.wait
      read_as[#read_as+1]=string.format('stop %d: waits from %s%s',i,tostring(stop.wait_from),saved.by and ' (saved by '..saved.by..')' or '')
    end
    if stop.save_as~=nil then
      assert(type(stop.save_as)=='string' and #stop.save_as>0 and #stop.save_as<=40,'stop '..i..': save_as is a name of 1..40 characters')
      assert(out.wait~=nil,'stop '..i..': save_as keeps the stop\'s wait list; it has none')
      st.saved_waits[stop.save_as]={wait=out.wait,tick=game.tick,by=p and p.name or nil}
      read_as[#read_as+1]=string.format('stop %d: its waits saved as %s',i,stop.save_as)
    end
    return out
  end
  local function stop_waits(i,stop,runs,read_as)
    local entry
    local waits={}
    local harness_conds,mirror,other,ordered={},{},{},{}
    -- (d18 batch36 A3) any_of / all_of as the game's chain; kinds mixed with no compare past the first: refused
    local list,grouped=M.waitgroups.flatten(stop.wait,'stop '..i)
    if grouped then read_as[#read_as+1]=string.format('stop %d: %s written as the game\'s chain of %d waits',i,stop.wait.any_of and 'any_of' or 'all_of',#list)
    else M.waitgroups.mixed(list,'stop '..i) end
    for j,w in ipairs(list or {}) do
      assert(type(w)=='table' and type(w.type)=='string','stop '..i..' wait '..j..' needs a type')
      -- (d17 batch31 B9, Luna: {type: fluid_count, fluid, count} was taken with no condition, and the game's wait
      -- then had nothing to compare) a field a wait does not take is refused, and a count wait needs its condition
      -- (B9: Luna wrote {item|fluid|name, count|at_least} 67 times and {seconds} 3 times on shift33-34, each dropped by
      -- the game) those read as the condition and the ticks they name, said in read_as
      local count=w.at_least or w.count
      local thing=w.fluid or w.item or w.name
      if w.condition==nil and (w.type=='item_count' or w.type=='fluid_count') and type(thing)=='string' and type(count)=='number' and not (w.at_least and w.count) then
        local copy={}
        for k,v in pairs(w) do if k~='fluid' and k~='item' and k~='name' and k~='count' and k~='at_least' then copy[k]=v end end
        copy.condition=string.format('%s >= %d',thing,count)
        read_as[#read_as+1]=string.format('stop %d wait %d: %s %s %s %g read as condition "%s"',i,j,w.type,thing,w.at_least and 'at_least' or 'count',count,copy.condition)
        w=copy
      end
      if w.seconds~=nil and w.ticks==nil and (w.type=='time' or w.type=='inactivity') and type(w.seconds)=='number' then
        local copy={}
        for k,v in pairs(w) do if k~='seconds' then copy[k]=v end end
        copy.ticks=math.floor(w.seconds*60+0.5)
        read_as[#read_as+1]=string.format('stop %d wait %d: seconds %g read as ticks %d',i,j,w.seconds,copy.ticks)
        w=copy
      end
      local bad={}
      for k in pairs(w) do
        if k~='type' and k~='ticks' and k~='condition' and k~='compare' and k~='harness' then bad[#bad+1]=tostring(k) end
      end
      if #bad>0 then
        table.sort(bad)
        error(string.format('stop %d wait %d: %s %s not wait fields (a wait takes type, ticks, condition, compare, harness); a count is a condition: {"type":"%s","condition":"%s >= %s"}',
          i,j,table.concat(bad,', '),#bad==1 and 'is' or 'are',w.type,tostring(w.fluid or w.item or w.signal or 'thruster-fuel'),tostring(w.count or w.value or w.at_least or 10000)),0)
      end
      if (w.type=='item_count' or w.type=='fluid_count' or w.type=='circuit') and w.condition==nil then
        error(string.format('stop %d wait %d: %s needs a condition ("%s >= 10000" or {signal, comparator, value}); without one the game\'s wait compares nothing',
          i,j,w.type,w.type=='item_count' and 'iron-plate' or 'thruster-fuel'),0)
      end
      assert(w.harness==nil or (w.harness==true and w.type=='fluid_count'),'stop '..i..' wait '..j..': harness: true goes with a fluid_count wait (the harness reads the storage tanks)')
      -- A condition (d17 batch17 A5, Astra board #842: a departure guard on fuel): "thruster-fuel >= 10000" or
      -- {signal, comparator, value | signal2}, as circuit_set takes it, or the game's {first_signal, comparator,
      -- constant}; item_count takes an item signal, fluid_count a fluid one; circuit reads the hub's wires.
      local cond=w.condition
      if cond~=nil then
        local what='stop '..i..' wait '..j..' condition'
        if type(cond)=='table' and cond.first_signal~=nil and cond.signal==nil then cond={signal=cond.first_signal,comparator=cond.comparator,value=cond.constant,signal2=cond.second_signal} end
        cond=api.circuit_condition(cond,what)
        local st=cond.first_signal.type
        if w.type=='item_count' then assert(st=='item',what..': item_count takes an item signal ("iron-plate >= 100")') end
        if w.type=='fluid_count' then assert(st=='fluid',what..': fluid_count takes a fluid signal ("thruster-fuel >= 10000")') end
        assert(w.type=='item_count' or w.type=='fluid_count' or w.type=='circuit',what..': a condition goes with type item_count, fluid_count or circuit')
      end
      local text=w.type..(cond and ' '..sigtext(cond.first_signal)..' '..(({['≥']='>=',['≤']='<=',['≠']='!='})[cond.comparator] or cond.comparator)..' '..tostring(cond.constant or (cond.second_signal and sigtext(cond.second_signal))) or '')
        ..(w.ticks and ' '..math.floor(w.ticks/60)..'s' or '')
      if w.harness then
        assert(cond.constant~=nil,'stop '..i..' wait '..j..': a harness fluid_count compares with a number ("thruster-fuel >= 24000")')
        harness_conds[#harness_conds+1]={kind='tanks',name=cond.first_signal.name,comparator=cond.comparator,value=cond.constant,text=text}
        ordered[#ordered+1]=harness_conds[#harness_conds]
      else
        waits[#waits+1]={type=w.type,ticks=w.ticks,compare_type=#waits>0 and (w.compare or 'and') or nil,condition=cond}
        if w.type=='time' and w.ticks then mirror[#mirror+1]={kind='time',ticks=w.ticks}; ordered[#ordered+1]=mirror[#mirror]
        elseif w.type=='item_count' and cond.constant~=nil then mirror[#mirror+1]={kind='hub',name=cond.first_signal.name,comparator=cond.comparator,value=cond.constant}; ordered[#ordered+1]=mirror[#mirror]
        else other[#other+1]=w.type end
        if (w.compare or 'and')~='and' and j>1 then other[#other+1]='compare '..tostring(w.compare) end
        -- (B9) the game's fluid_count on a platform, as seen on world n
        if w.type=='fluid_count' then runs[#runs+1]=string.format('stop %d (%s) %s: the game\'s condition',i,stop.station,text) end
      end
      if w.harness then runs[#runs+1]=string.format('stop %d (%s) %s: the harness (the sum in its storage tanks, read every second while it waits there)',i,stop.station,text) end
    end
    if #harness_conds>0 then
      assert(#other==0,string.format('stop %d: harness waits go with time and item_count waits joined by and (the harness reads those too); this stop also has %s',i,table.concat(other,', ')))
      waits[#waits+1]={type='circuit',compare_type=#waits>0 and 'and' or nil,condition=api.platwait and api.platwait().NEVER}
      entry={station=stop.station,conds=ordered}
      runs[#runs+1]=string.format('stop %d (%s): the game\'s record also holds circuit signal-dot < -2147483648, which never holds, so the game does not send it on; the harness does (go to station on the next stop) when every condition of the stop holds%s',
        i,stop.station,#mirror>0 and ' (its time and item_count waits too, read by the harness from when it is first seen waiting there, and from the hub)' or '')
    end
    return waits,entry
  end
  local stuck
  -- (d17 batch31 C4, Astra and Sol 11:09: Kestrel II at Fulgora set to [nauvis] read no_schedule, the rebuild too, and
  -- the queue step said success, then waited) the state after the call: no_schedule, no_path, or paused when paused was
  -- not asked, fails the call (a failed queue step), with what the journals showed. The schedule stays as set.
  -- (d21 batch66 AB4) the cases behind the old rule ("8 of 8 with the current on the stop it waits at") read again in
  -- the journals: Luna's 4 (shift32 05:38:14-05:38:34) had Spindle at gleba with the current on fulgora, and a rocket of
  -- 120 carbon fiber launched to it at 05:38:10; it left by 05:38:46. Sol's (shift31 03:04:58-03:07:29) had Swiftlet at
  -- aquilo with the current on aquilo (time 1 tick, held) or on gleba; no rocket was launched to it (aquilo's silo held a
  -- ready rocket of 36 cryogenic science packs for it, not launched); it left at 03:07:54 after the GUI's go to station.
  M.STUCK_RULE='seen across the journals: every one-stop schedule read no_schedule (Sol\'s lone gleba, Luna\'s lone fulgora, Kestrel II at Fulgora set to [nauvis] current 1, Swiftlet); with stops set, no_schedule was read while rockets launched to it were on their way (Spindle at gleba on shift32 left when the rocket arrived), while it waited at its current stop with its conditions false (Solstice at nauvis on shift52 left when they held), and with neither (Swiftlet at aquilo on shift31, current on aquilo or gleba, aquilo\'s silo holding a ready rocket for it, not launched; it left after the GUI\'s go to station)'
  -- (d18 batch38 A1, Sol 18:21: refused for no_schedule while the platform began flying moments later; duplicate edits
  -- and reversals followed) no_schedule and no_path are read again: the game updates a platform in a later tick. On
  -- shift36 Cinder (next: true at tick 29119760) was flying 39 ticks later, and Wayfarer (stop 2, go: true at 29611678)
  -- left within 265 ticks, while the calls whose platform still read no_schedule 175-334 ticks later stayed. So such a
  -- read starts a recheck (M.recheck): read every RECHECK_EVERY ticks for up to RECHECK_TICKS, going on as soon as the
  -- state reads otherwise. A queue step waits for it and fails only when the platform still reads it then; a direct
  -- call's reply gives the first read and recheck, and the second read comes as a tell. paused is read at once (the
  -- game sets it in the call).
  M.RECHECK_TICKS,M.RECHECK_EVERY=300,10
  local function stuck_why(pl,st,cleared)
    if st=='no_schedule' and not cleared then
      -- (AB4) waiting at its current stop on conditions false now: not stuck, said (waiting_now)
      local w=M.waiting_now(pl)
      if w and w.met==false then return nil end
      local sch=try(function() return pl.schedule end)
      local recs=sch and sch.records or {}
      if w then return 'no_schedule: '..w.line..'; '..M.STUCK_RULE end
      if #recs>0 then
        local cur=sch.current or 1
        return string.format('no_schedule with %d stop%s set (current %d, %s) while it is at %s: it has not left; %s',#recs,#recs==1 and '' or 's',cur,
          tostring(recs[cur] and recs[cur].station or '?'),tostring(location(pl) or '?'),M.STUCK_RULE)
      end
      return 'no_schedule: it follows no schedule and goes nowhere; '..M.STUCK_RULE
    end
    if st=='no_path' then return 'no_path: it has no way from where it is to its next stop and goes nowhere' end
  end
  -- (d19 batch48 cp2, Sol 18:01: Kestrel IV at Nauvis read no_schedule after stops+current 2 and a queue step failed at
  -- 305 ticks) the game keeps a platform at its station until the rockets launched to it arrive, and it reads
  -- no_schedule meanwhile: on shift42 Kestrel IV left Nauvis 2129 and 2116 ticks after a rocket was launched to it
  -- (33991951 -> 33994080, 34340264 -> 34342380) and left Aquilo at once with none on the way (34251660). The rockets
  -- on their way (freight.lua incoming): until when the recheck waits for them, at most ROCKET_HOLD after the call.
  M.ROCKET_UP,M.ROCKET_HOLD,M.ROCKET_MARGIN=2200,3600,180
  local function rockets_coming(pl)
    local inc=api.freight and api.freight.incoming and try(function() return api.freight.incoming(pl) end)
    if not (inc and inc.rockets and inc.rockets>0) then return nil end
    local last=game.tick
    for _,r in ipairs(inc.rows or {}) do
      local left=r.eta_ticks or math.max(0,M.ROCKET_UP-(game.tick-(r.tick or game.tick)))
      last=math.max(last,game.tick+left+M.ROCKET_MARGIN)
    end
    return {arrive_tick=last,line=string.format('%d rocket%s launched to it %s still on the way (%s); the game keeps a platform at its station until the rockets launched to it arrive, reading no_schedule meanwhile (Kestrel IV on shift42 left 2129 and 2116 ticks after a launch to it)',
      inc.rockets,inc.rockets==1 and '' or 's',inc.rockets==1 and 'is' or 'are',(inc.lines or {})[1] or inc.cargo)}
  end
  M.rockets_coming=rockets_coming
  stuck=function(pl,a,rebuilt,cleared)
    local st=platform_states[pl.state]
    if stuck_why(pl,st,cleared) then
      local hold=st=='no_schedule' and rockets_coming(pl) or nil
      local ends=game.tick+M.RECHECK_TICKS
      if hold then ends=math.min(game.tick+M.ROCKET_HOLD,math.max(ends,hold.arrive_tick)) end
      return {platform=pl.name,first=st,tick=game.tick,ends_tick=ends,cleared=cleared or nil,rebuilt=rebuilt,rockets=hold and hold.line or nil,
        line=string.format('%s read %s in the tick of this call (the game updates a platform in a later tick); read again every %d ticks for up to %d: a queue step waits for that read and fails only when it still reads no_schedule or no_path; a direct call gets the second read in a tell%s',
          pl.name,st,M.RECHECK_EVERY,ends-game.tick,hold and '; '..hold.line or '')}
    end
    -- (d24 batch153, harness review bug 1: Petrel, paused at Nauvis, took stop 2's new wait and the call answered
    -- ok:false, "it was paused before this call after this call, so the call failed") a platform paused before the call
    -- and not unpaused by it has the change made: the reply says it is still paused (still_paused). Only paused: false
    -- that leaves it paused fails.
    if pl.paused and a.paused==false then
      error(string.format('%s still reads paused after this call (paused: false was given), so the call failed; the schedule stays as set: %s%s',pl.name,
        schedule_text(pl),rebuilt and '; '..rebuilt or ''),0)
    end
  end
  -- The line for a call that changed a platform paused before it and left paused (no paused given).
  local function still_paused(pl,a)
    if a.paused~=nil or not try(function() return pl.paused end) then return nil end
    return string.format('%s was paused before this call and still is: the change is made, and it goes nowhere until unpaused (paused: false)',pl.name)
  end
  -- The second read of a recheck: nil while it reads no_schedule or no_path and time is left; else {ok, line, error?}.
  function M.recheck_read(rc)
    local pl
    local f=rc.force and game.forces[rc.force]
    for _,each in pairs(f and try(function() return f.platforms end) or {}) do if each.valid and each.name==rc.platform then pl=each end end
    if not pl then return {ok=false,line=rc.platform..' is gone',error=rc.platform..' is gone'} end
    local st=platform_states[pl.state]
    local why=stuck_why(pl,st,rc.cleared)
    local after=game.tick-rc.tick
    if not why then
      local w=st=='no_schedule' and M.waiting_now(pl)
      return {ok=true,state=st,after_ticks=after,waiting=w and w.line or nil,line=string.format('%s read %s at tick %d (the call\'s tick) and %s %d ticks later, at %s%s%s',rc.platform,rc.first,rc.tick,tostring(st),after,tostring(location(pl) or "?"),
        rc.rockets and ' (it waited for the rockets launched to it)' or '',w and '; '..w.line or '')}
    end
    if game.tick<rc.ends_tick then return nil end
    -- rockets launched to it still on the way (a later launch, or a slower rocket): wait on, up to ROCKET_HOLD
    local hold=st=='no_schedule' and rockets_coming(pl) or nil
    if hold and game.tick<rc.tick+M.ROCKET_HOLD then
      rc.ends_tick=math.min(rc.tick+M.ROCKET_HOLD,math.max(game.tick+M.RECHECK_EVERY,hold.arrive_tick)); rc.rockets=hold.line
      return nil
    end
    local line=string.format('%s read %s at tick %d (the call\'s tick) and still %s %d ticks later%s',rc.platform,rc.first,rc.tick,st,after,
      hold and '; '..hold.line..' (waited the longest it waits, '..M.ROCKET_HOLD..' ticks)' or '')
    return {ok=false,state=st,after_ticks=after,line=line,
      error=string.format('%s; the call failed: it reads %s; the schedule stays as set: %s%s',line,why,schedule_text(pl),rc.rebuilt and '; '..rc.rebuilt or '')}
  end
  -- Direct calls' rechecks, by player index: told when they end (a queue step's is read by the queue, queued=true).
  function M.recheck_start(p,rc)
    if not rc then return end
    rc.force=p.force and p.force.name
    if not api.state then return end
    local s=api.state()
    s.schedule_rechecks=s.schedule_rechecks or {}
    rc.index=p.index
    s.schedule_rechecks[#s.schedule_rechecks+1]=rc
  end
  function M.recheck_tick()
    local s=api.state and api.state()
    local list=s and s.schedule_rechecks
    if not list or #list==0 or game.tick%M.RECHECK_EVERY~=0 then return end
    for i=#list,1,-1 do
      local rc=list[i]
      if rc.queued then table.remove(list,i)
      else
        local r=M.recheck_read(rc)
        if r then
          table.remove(list,i)
          if api.deliver then pcall(api.deliver,rc.index,{seq='schedule',tick=game.tick,from='platform_schedule',
            text=r.ok and r.line or r.error}) end
        end
      end
    end
  end
  -- (d26 batch231 RG) whether a stop's new waits make the platform leave now (platform_schedule stop: and the queue's dry
  -- run, schedule_check): leave (it leaves at once: the reason), unknown (waits not read that may hold), cur, new_cur,
  -- before (its state)
  -- (d26 batch231) the refusal of current alone on the stop it waits at or flies to (schedule_call and schedule_check)
  local function already_current(cur,station,st,n)
    return string.format('nothing changed: stop %d (%s) is already the current stop (%s); current %d sends it to stop %d now, next: true to the stop after the current one, stops with current rewrites the schedule',
      cur,tostring(station),st=='waiting_at_station' and 'it waits there' or 'it flies there',cur%n+1,cur%n+1)
  end
  local function leave_check(pl,sch,recs,n,idx,station,waits,current)
    local cur=sch.current or 1
    local new_cur=current~=nil and api.integer(current,cur,1,n,'current') or cur
    local before=platform_states[pl.state]
    local here=try(function() return pl.space_location.name end)
    local waiting=(before=='waiting_at_station' or before=='no_schedule' and M.waiting_now(pl)) and recs[cur] and recs[cur].station==here
    -- the new waits at the stop it waits at: true, false or nil (not read) each, joined as the game joins them
    -- (and binds before or)
    local st=api.state and api.state()
    local arrived=st and st.platform_stops and st.platform_stops[pl.index] or {}
    if arrived.at~=here then arrived={} end
    local function holds(w)
      local c=w.condition
      if w.type=='time' then
        if not arrived.tick then return nil,'time: its arrival was not seen' end
        local left=(w.ticks or 0)-(game.tick-arrived.tick)
        return left<=0,string.format('time %s: %s',secs(w.ticks or 0),left<=0 and 'passed' or secs(left)..' left')
      elseif w.type=='item_count' and c and c.first_signal and c.constant then
        local held=try(function() return pl.hub.get_inventory(defines.inventory.hub_main).get_item_count({name=c.first_signal.name,quality=c.first_signal.quality or 'normal'}) end) or 0
        local ok=compare(held,c.comparator or '<',c.constant)
        return ok,string.format('item_count %s: the hub holds %d',cond_text(c),held)
      elseif w.type=='circuit' and c and c.first_signal then
        if c.first_signal.name=='signal-dot' and c.constant==-2147483648 then return false,'the harness sends it on' end
        local function wires(sig)
          local v,wired=0,false
          for _,id in ipairs({defines.wire_connector_id.circuit_red,defines.wire_connector_id.circuit_green}) do
            local net=pl.hub and pl.hub.valid and try(function() return pl.hub.get_circuit_network(id) end)
            if net then wired=true; v=v+(try(function() return net.get_signal(sig) end) or 0) end
          end
          return v,wired
        end
        local x=wires(c.first_signal)
        local y=c.second_signal and wires(c.second_signal) or c.constant or 0
        local ok=compare(x,c.comparator or '<',y)
        return ok,string.format('circuit %s: the hub\'s wires read %d',cond_text(c),x)
      elseif w.type=='all_requests_satisfied' then
        local rows=unmet(pl)
        return #rows==0,string.format('all_requests_satisfied: %d requests unmet',#rows)
      end
      return nil,w.type..': not read'
    end
    local leave,unknown
    if waiting and new_cur~=cur then
      leave=string.format('it waits at stop %d (%s) and current %d sends it to stop %d (%s) at once',cur,recs[cur].station,new_cur,new_cur,recs[new_cur].station)
    elseif waiting and idx==cur then
      if #waits==0 then leave=string.format('stop %d (%s), where it waits, would have no wait condition: it leaves at once',idx,station)
      else
        local groups,g={},{ok=true,words={}}
        groups[1]=g
        for k,w in ipairs(waits) do
          if k>1 and w.compare_type=='or' then g={ok=true,words={}}; groups[#groups+1]=g end
          local ok,words=holds(w)
          g.words[#g.words+1]=words
          if ok==false then g.ok=false elseif ok==nil and g.ok then g.ok=nil end
        end
        local any_true,all_false=false,true
        for _,gg in ipairs(groups) do if gg.ok==true then any_true=true end; if gg.ok~=false then all_false=false end end
        local words={}
        for _,gg in ipairs(groups) do words[#words+1]=table.concat(gg.words,' and ') end
        if any_true then leave=string.format('its new waits at stop %d (%s), where it waits, hold now: %s; it leaves at once',idx,station,table.concat(words,' or '))
        elseif not all_false then unknown=string.format('its new waits at stop %d (%s) may hold now: %s',idx,station,table.concat(words,' or ')) end
      end
    end
    return leave,unknown,cur,new_cur,before
  end
  -- (d26 batch231 RG) the call's checks of its arguments alone, in its order, for the path it takes: run first by
  -- schedule_call (so a refusal comes before anything is written) and by schedule_check (the queue's dry run)
  local function arg_checks(a)
    assert(a.unloading==nil or a.stop~=nil,'unloading goes with stop (that record\'s allow unloading) or in a stops entry')
    assert(a.unloading==nil or type(a.unloading)=='boolean','unloading must be true or false')
    if a.next~=nil then
      assert(a.next==true,'next is true: go to the schedule\'s next stop now')
      assert(a.stops==nil and a.current==nil and a.keep_leg==nil,'next goes alone: it keeps the records and sends the platform to the stop after the current one')
      return
    end
    if a.current~=nil and a.stops==nil and a.stop==nil then
      assert(a.keep_leg==nil,'keep_leg goes with stops')
      assert(a.paused==nil or type(a.paused)=='boolean','paused must be boolean')
      return
    end
    if a.stop~=nil then
      assert(a.stops==nil and a.next==nil and a.keep_leg==nil,'stop edits one record\'s waits; stops, next and keep_leg go without it')
      assert(type(a.wait)=='table' or a.unloading~=nil and a.wait==nil,'stop goes with wait (the stop\'s new wait conditions, [] for none), unloading (true or false), or both')
      assert(a.go==nil or type(a.go)=='boolean','go must be true or false')
      if a.wait==nil then assert(a.current==nil and a.go==nil,'current and go go with wait') end
      return
    end
    assert(a.keep_leg==nil or type(a.keep_leg)=='boolean','keep_leg must be true or false')
    if a.stops~=nil then
      assert(type(a.stops)=='table' and #a.stops<=M.STOPS_MAX,'stops requires 0..'..M.STOPS_MAX..' {station,wait?}')
      for i,stop in ipairs(a.stops) do
        assert(type(stop)=='table' and type(stop.station)=='string' and prototypes.space_location[stop.station],'stop '..i..': station must be a planet or space location name')
        assert(stop.unloading==nil or type(stop.unloading)=='boolean','stop '..i..': unloading must be true or false')
      end
      assert(a.one_stop==nil or a.one_stop=='as given','one_stop is "as given" (the one stop as it is given)')
      if a.keep_leg then assert(a.current==nil,'keep_leg sets the current stop (the leg\'s destination); current goes without it') end
    end
    assert(a.paused==nil or type(a.paused)=='boolean','paused must be boolean')
  end
  function M.schedule_call(p,a)
    local pl=M.platform(p,a.platform)
    arg_checks(a)
    local runs,read_as
    -- (d24 batch142 PN1) unloading: one record's (with stop) or each stops entry's
    assert(a.unloading==nil or a.stop~=nil,'unloading goes with stop (that record\'s allow unloading) or in a stops entry')
    assert(a.unloading==nil or type(a.unloading)=='boolean','unloading must be true or false')
    -- next: true (d17 batch31 B2, Luna: whole schedules rebuilt when a stop's wait stalled): the GUI's go to station on
    -- the record after the current one, the records and their waits kept
    if a.next~=nil then
      assert(a.next==true,'next is true: go to the schedule\'s next stop now')
      assert(a.stops==nil and a.current==nil and a.keep_leg==nil,'next goes alone: it keeps the records and sends the platform to the stop after the current one')
      local sch=pl.get_schedule()
      local n=sch and sch.get_record_count() or 0
      assert(n>0,pl.name..' has no schedule: give stops')
      local before=platform_states[pl.state]
      local cur=sch.current or 1
      local recs=pl.schedule and pl.schedule.records or {}
      local function name(i) return recs[i] and recs[i].station or '?' end
      local nxt=cur%n+1
      local where=(before=='waiting_at_station' or M.waiting_now(pl)) and 'waiting at '..tostring(try(function() return pl.space_location.name end))
        or pl.space_connection and 'flying to stop '..cur..' ('..name(cur)..')' or tostring(before)
      sch.go_to_station(nxt)
      local state=platform_states[pl.state]
      local rc=stuck(pl,a)
      M.recheck_start(p,rc)
      return {name=pl.name,state=state,at=location(pl),schedule=schedule_text(pl),recheck=rc,
        sent_to=string.format('from stop %d (%s) to stop %d (%s): go to station called (it was %s)%s',cur,name(cur),nxt,name(nxt),where,
          n==1 and '; its schedule has one stop, so the next stop is the same one' or ''),
        waiting=M.waiting_line(pl),state_note=rc and rc.line or state=='paused' and M.paused_note(pl) or M.waiting_note(pl,state),still_paused=still_paused(pl,a)}
    end
    -- (d19 batch48 1, Sol 17:29: `current: 4` alone left Kestrel IV at Aquilo, no effect, no error) current alone: the
    -- GUI's go to station on that record, the records and their waits kept; current on the stop it is at or already
    -- flying to changes nothing and is refused, saying what does
    if a.current~=nil and a.stops==nil and a.stop==nil then
      assert(a.keep_leg==nil,'keep_leg goes with stops')
      local sch=pl.get_schedule()
      local n=sch and sch.get_record_count() or 0
      assert(n>0,pl.name..' has no schedule: give stops (and current)')
      local new=api.integer(a.current,nil,1,n,'current')
      local cur=sch.current or 1
      local recs=pl.schedule and pl.schedule.records or {}
      local function name(i) return recs[i] and recs[i].station or '?' end
      local before=platform_states[pl.state]
      local here=try(function() return pl.space_location.name end)
      -- (AB4) waiting at its current stop while the game reads no_schedule is waiting there too
      if before=='no_schedule' and M.waiting_now(pl) then before='waiting_at_station' end
      if new==cur and (before=='waiting_at_station' or before=='on_the_path') then
        error(already_current(cur,name(cur),before,n),0)
      end
      if a.paused~=nil then assert(type(a.paused)=='boolean','paused must be boolean'); pl.paused=a.paused end
      sch.go_to_station(new)
      local state=platform_states[pl.state]
      local rc=stuck(pl,a)
      M.recheck_start(p,rc)
      return {name=pl.name,state=state,at=location(pl),paused=pl.paused or nil,schedule=schedule_text(pl),recheck=rc,
        sent_to=string.format('from stop %d (%s) to stop %d (%s): go to station called (it was %s), the records and their waits kept',cur,name(cur),new,name(new),
          before=='waiting_at_station' and 'waiting at '..tostring(here) or tostring(before)),
        waiting=M.waiting_line(pl),state_note=rc and rc.line or state=='paused' and M.paused_note(pl) or M.waiting_note(pl,state),still_paused=still_paused(pl,a)}
    end
    -- stop: N, wait: [...] (d17 batch31 B8, Luna 07:18: to make Spindle wait at Nauvis, stop 1, for fuel and oxidizer
    -- >= 24000 she set current 2, since current = the stop it waits at had read no_schedule, and it left at once with
    -- 4,660 fuel): that record's wait conditions replaced in place through the schedule's own wait condition calls,
    -- the records, the current stop and the state kept. Before anything changes, whether the edit makes it leave now:
    -- current set to another stop while it waits, or the stop it waits at left with no wait, or its new waits holding
    -- now (time from its arrival, item_count against the hub, circuit against the hub's wires, all requests satisfied);
    -- refused unless go: true.
    if a.stop~=nil then
      assert(a.stops==nil and a.next==nil and a.keep_leg==nil,'stop edits one record\'s waits; stops, next and keep_leg go without it')
      assert(type(a.wait)=='table' or a.unloading~=nil and a.wait==nil,'stop goes with wait (the stop\'s new wait conditions, [] for none), unloading (true or false), or both')
      assert(a.go==nil or type(a.go)=='boolean','go must be true or false')
      local sch=pl.get_schedule()
      local n=sch and sch.get_record_count() or 0
      assert(n>0,pl.name..' has no schedule: give stops')
      local idx=api.integer(a.stop,nil,1,n,'stop')
      local recs=pl.schedule.records
      local station=recs[idx].station
      -- (d24 batch142 PN1, Sol #2135, Luna #2136) the stop's allow unloading, set in place (the records, their waits,
      -- the current stop and the state kept); with wait, after the waits' edit
      local function set_unloading()
        local was=recs[idx].allows_unloading~=false
        local ok,err=pcall(function() sch.set_allow_unloading({schedule_index=idx},a.unloading) end)
        if not ok then error('the game refused stop '..idx..'\'s unloading: '..tostring(err),0) end
        local now=try(function() return sch.get_record({schedule_index=idx}).allows_unloading end)~=false
        return string.format('stop %d (%s): unloading %s (was %s)%s',idx,station,now and 'on' or 'off',was and 'on' or 'off',
          now==a.unloading and '' or '; the game kept it '..(now and 'on' or 'off'))
      end
      if a.wait==nil then
        assert(a.current==nil and a.go==nil,'current and go go with wait')
        local line=set_unloading()
        local state=platform_states[pl.state]
        return {name=pl.name,state=state,at=location(pl),schedule=schedule_text(pl),
          edited=line..'; its waits, the records and the current stop kept',unloading_rule=freight.NO_UNLOAD_RULE,waiting=M.waiting_line(pl),
          state_note=state=='paused' and M.paused_note(pl) or nil,still_paused=still_paused(pl,a)}
      end
      runs,read_as={},{}
      local waits,entry=stop_waits(idx,{station=station,wait=a.wait},runs,read_as)
      local leave,unknown,cur,new_cur,before=leave_check(pl,sch,recs,n,idx,station,waits,a.current)
      if leave and a.go~=true then error('nothing changed: '..leave..'; go: true makes the edit anyway',0) end
      local pos={schedule_index=idx}
      local ok,err=pcall(function()
        for k=sch.get_wait_condition_count(pos),1,-1 do sch.remove_wait_condition(pos,k) end
        for k,w in ipairs(waits) do
          sch.add_wait_condition(pos,k,w.type)
          sch.change_wait_condition(pos,k,{type=w.type,ticks=w.ticks,condition=w.condition,compare_type=w.compare_type or 'and'})
          if k>1 and w.compare_type=='or' then pcall(function() sch.set_wait_condition_mode(pos,k,'or') end) end
        end
      end)
      if not ok then error('the game refused the edit of stop '..idx..'\'s waits: '..tostring(err),0) end
      if new_cur~=cur then sch.go_to_station(new_cur) end
      local unloading_line=a.unloading~=nil and set_unloading() or nil
      -- the harness's watch: this stop's replaced, the others kept
      local W=api.platwait and api.platwait()
      if W then
        local had=W.get(pl.name)
        local stops={}
        for k,v in pairs(had and had.stops or {}) do if k~=idx then stops[k]=v end end
        stops[idx]=entry
        W.set(pl,next(stops) and stops or nil)
      end
      local state=platform_states[pl.state]
      local rc=stuck(pl,a)
      M.recheck_start(p,rc)
      local fluid_note
      for _,l in ipairs(runs) do if l:find(": the game's condition",1,true) then fluid_note=FLUID_NOTE end end
      return {name=pl.name,state=state,at=location(pl),schedule=schedule_text(pl),
        edited=string.format('stop %d (%s): %d wait condition%s set in place; the records and the current stop (%d) %s; state %s%s',idx,station,#waits,#waits==1 and '' or 's',
          new_cur,new_cur~=cur and string.format('changed from %d (current)',cur) or 'kept',state,state~=before and ' (was '..tostring(before)..')' or ' (kept)'),
        unloading=unloading_line,unloading_rule=unloading_line and freight.NO_UNLOAD_RULE or nil,
        leaves=leave,may_leave=unknown,read_as=#read_as>0 and read_as or nil,waits_run=#runs>0 and runs or nil,fluid_count_note=fluid_note,recheck=rc,waiting=M.waiting_line(pl),
        state_note=rc and rc.line or state=='paused' and M.paused_note(pl) or M.waiting_note(pl,state),still_paused=still_paused(pl,a),
        launch_needs=api.launch_need and try(function() return api.launch_need(pl) end) or nil,
      wait_facts=api.wait_need and try(function() return api.wait_need(pl) end) or nil,
        harness_waits=W and W.line(pl.name) or nil}
    end
    local circuit_note,sent,go_error,rebuilt,one_stop_note,unloading
    -- (d17 batch23 A0b) where it is before the edit: the station it waits at, or the leg it flies
    local before=platform_states[pl.state]
    local waits_at=(before=='waiting_at_station' or M.waiting_now(pl)) and try(function() return pl.space_location.name end) or nil
    local leg_before=pl.space_connection and try(function() return freight.leg(pl) end) or nil
    assert(a.keep_leg==nil or type(a.keep_leg)=='boolean','keep_leg must be true or false')
    if a.stops~=nil then
      assert(type(a.stops)=='table' and #a.stops<=M.STOPS_MAX,'stops requires 0..'..M.STOPS_MAX..' {station,wait?}')
      local records={}
      local watch={}
      runs,read_as={},{}
      -- (d24 batch142 PN1) each stop's unloading (the GUI's allow unloading): as given, else as the schedule's first
      -- stop at that station had it before this call, else on (the game's default)
      local was_off={}
      for _,r in ipairs(try(function() return pl.schedule.records end) or {}) do
        if r.station and was_off[r.station]==nil then was_off[r.station]=r.allows_unloading==false end
      end
      local kept_off={}
      for i,stop in ipairs(a.stops) do
        assert(type(stop)=='table' and type(stop.station)=='string' and prototypes.space_location[stop.station],'stop '..i..': station must be a planet or space location name')
        assert(stop.unloading==nil or type(stop.unloading)=='boolean','stop '..i..': unloading must be true or false')
        -- (d18 batch36 A3) a stop's wait list kept under a name for reuse (save_as) or taken from one (wait_from)
        stop=M.saved_waits(i,stop,read_as,p)
        local waits,entry=stop_waits(i,stop,runs,read_as)
        watch[i]=entry
        local unl=stop.unloading
        if unl==nil and was_off[stop.station] then unl=false end
        records[i]={station=stop.station,wait_conditions=#waits>0 and waits or nil,allows_unloading=unl}
        if stop.unloading==nil and unl==false then kept_off[records[i]]=true end
      end
      -- (d17 batch31 C4, Astra and Sol 11:09) one stop that is not where the platform is: written as [where it is, that
      -- stop], current 2, since every one-stop schedule in the journals read no_schedule; one_stop: "as given" keeps it
      assert(a.one_stop==nil or a.one_stop=='as given','one_stop is "as given" (the one stop as it is given)')
      local one_stop
      local loc=not pl.space_connection and try(function() return pl.space_location.name end) or nil
      if #records==1 and a.one_stop==nil and loc and loc~=records[1].station and (a.current==nil or a.current==1) and not a.keep_leg then
        records={{station=loc,allows_unloading=was_off[loc] and false or nil},records[1]}
        if was_off[loc] then kept_off[records[1]]=true end
        watch={[2]=watch[1]}
        one_stop=string.format('one stop (%s) given while the platform is at %s: written as [%s, %s] with current 2, as every one-stop schedule in the journals read no_schedule; at %s it waits as given, and once those waits hold it goes on to %s (a stop with no wait: at once); one_stop: "as given" writes the one stop alone',
          records[2].station,loc,loc,records[2].station,records[2].station,loc)
        a=setmetatable({current=2},{__index=a})
        one_stop_note=one_stop
      end
      if api.platwait then api.platwait().set(pl,next(watch) and watch or nil) end
      for i,r in ipairs(records) do
        if r.allows_unloading==false then
          unloading=unloading or {}
          unloading[#unloading+1]=string.format('stop %d (%s): unloading off%s',i,r.station,kept_off[r] and ', kept from the schedule before this call (unloading: true turns it on)' or '')
        end
      end
      local current=api.integer(a.current,1,1,math.max(1,#records),'current')
      -- (A0b, Astra 22:52: Sol's edit turned Spindle back to Gleba in flight, unsaid) keep_leg: the current stop is the
      -- stop for the leg's destination
      if a.keep_leg then
        assert(a.current==nil,'keep_leg sets the current stop (the leg\'s destination); current goes without it')
        assert(leg_before,'keep_leg: '..pl.name..' flies no leg now ('..tostring(before)..')')
        local found
        for i,r in ipairs(records) do if r.station==leg_before.to then found=i; break end end
        assert(found,string.format('keep_leg: the stops hold no %s, the destination of the leg it flies (%s->%s); add it or leave keep_leg out',leg_before.to,leg_before.from,leg_before.to))
        current=found
      end
      pl.schedule=#records>0 and {current=current,records=records} or nil
      -- (d17 batch23 A0, Sol 20:05: Swiftlet, waiting at Aquilo, read no_schedule after each of four schedules that
      -- held an Aquilo record, current 1 or 2, and replied as a success; one without an Aquilo record departed at
      -- once. Not reproduced on a copy.) Then: the GUI's go to station for current; if the state still reads
      -- no_schedule with records set, the schedule is written again record by record through LuaSchedule (the GUI's
      -- path, as trains.lua does) and sent again; each step is said in the reply.
      if #records>0 then
        local sch=try(function() return pl.get_schedule() end)
        if sch then
          local ok,err=pcall(function() sch.go_to_station(current) end)
          if ok then sent={index=current,station=records[current].station} else go_error='go_to_station('..current..') was refused: '..tostring(err) end
          if platform_states[pl.state]=='no_schedule' then
            local ok2,err2=pcall(function()
              for _=sch.get_record_count(),1,-1 do sch.remove_record({schedule_index=1}) end
              for _,r in ipairs(records) do sch.add_record({station=r.station,wait_conditions=r.wait_conditions,allows_unloading=r.allows_unloading}) end
              sch.go_to_station(current)
            end)
            -- a rebuild cut short is undone: the records as set first
            if not ok2 then pcall(function() pl.schedule={current=current,records=records} end) end
            rebuilt=ok2 and string.format('the state read no_schedule after the schedule was set and sent to stop %d; it was written again record by record (as the GUI does) and sent again: %s now',
              current,tostring(platform_states[pl.state])) or 'the state read no_schedule after the schedule was set; writing it again record by record was refused ('..tostring(err2)..'), and the records were set back as given'
          end
        end
      end
      -- a circuit wait reads the hub's red and green wires: none, and it never holds
      for _,r in ipairs(records) do
        for _,w in ipairs(r.wait_conditions or {}) do
          if w.type=='circuit' and not (w.condition and w.condition.first_signal and w.condition.first_signal.name=='signal-dot' and w.condition.constant==-2147483648) then
            local hub=pl.hub
            local function net(id) local ok,n=pcall(function() return hub.get_circuit_network(id) end); return ok and n or nil end
            local wired=hub and hub.valid and (net(defines.wire_connector_id.circuit_red) or net(defines.wire_connector_id.circuit_green))
            if not wired then circuit_note='a circuit wait reads the hub\'s red and green wires, and the hub has none: wire a tank or a combinator to it (wire {platform, from, to: {x:0,y:0}, color})' end
          end
        end
      end
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
    local state=platform_states[pl.state]
    -- (A0b: Sol's 4 at Aquilo on d17 and Luna's 4 on Spindle at Fulgora on shift32, rebuilt or not, read no_schedule;
    -- the same stops with the current on the next stop went on_the_path at once. Not found on a copy.) The rule seen,
    -- said when it applies.
    local sch_now=a.stops~=nil and pl.schedule
    local cur_rec=sch_now and sch_now.records and sch_now.records[sch_now.current]
    -- (AB4) it waits there on that stop's conditions: each with its value now (waiting_now)
    local wnow=M.waiting_now(pl)
    local current_note=waits_at and cur_rec and cur_rec.station==waits_at and string.format(
      'the current stop (%d, %s) is the station it is at: %s',sch_now.current,waits_at,
      wnow and wnow.line or 'it waits there on that stop\'s conditions') or nil
    -- (A0b) the leg before and after an edit in flight
    local leg_note
    if leg_before and cur_rec then
      local to=cur_rec.station
      leg_note=string.format('it was flying %s->%s (%d%%); the current stop is now %s%s',leg_before.from,leg_before.to,math.floor((leg_before.flown or 0)*100+0.5),to,
        to==leg_before.to and ': the same destination' or to==leg_before.from and ': it turns back the way it came' or ': a new destination')
    end
    -- the states in which it is not going anywhere, said in the reply
    local state_note=state=='no_schedule' and wnow and wnow.met==false and 'state no_schedule: '..wnow.line..(sent and ' (go to station '..sent.index..' was called)' or '')
      or state=='no_schedule' and 'state no_schedule: '..(pl.schedule and #(pl.schedule.records or {})>0 and 'the game reads no_schedule with stops set; it has not left' or 'the platform follows no schedule now and goes nowhere')
        ..(sent and ' (go to station '..sent.index..' was called)' or '')..(current_note and '; '..current_note or '')
      or state=='no_path' and 'state no_path: the platform has no way from where it is to its next stop and goes nowhere'
      or state=='paused' and M.paused_note(pl)
      or nil
    -- (B9) a game fluid_count wait on a platform, as world n showed it
    local fluid_note
    for _,l in ipairs(runs or {}) do if l:find(": the game's condition",1,true) then fluid_note=FLUID_NOTE end end
    -- a call that changes nothing is a read, and is not failed
    local rc
    if a.stops~=nil or a.paused~=nil then rc=stuck(pl,a,rebuilt,a.stops~=nil and #a.stops==0); M.recheck_start(p,rc) end
    if rc then state_note=state_note..'; '..rc.line end
    return {name=pl.name,state=state,state_note=state_note,waiting=wnow and wnow.line or nil,recheck=rc,at=location(pl),paused=pl.paused or nil,schedule=schedule_text(pl),one_stop=one_stop_note,
      still_paused=(a.stops~=nil or a.current~=nil) and still_paused(pl,a) or nil,
      sent_to=sent and string.format('stop %d (%s): go to station called',sent.index,sent.station) or nil,go_error=go_error,rebuilt=rebuilt,note=note,circuit_note=circuit_note,
      current_note=current_note,leg=leg_note,read_as=read_as and #read_as>0 and read_as or nil,waits_run=runs and #runs>0 and runs or nil,fluid_count_note=fluid_note,
      unloading=unloading,unloading_rule=unloading and freight.NO_UNLOAD_RULE or nil,
      harness_waits=api.platwait and api.platwait().line(pl.name) or nil,
      launch_needs=api.launch_need and try(function() return api.launch_need(pl) end) or nil,
      wait_facts=api.wait_need and try(function() return api.wait_need(pl) end) or nil}
  end
  -- (d19 batch41 B1, Sol seq 861) each stop's departure conditions as one text, for the edit log: the station and its
  -- waits as the schedule GUI lists them (and/or, type, time or condition).
  local function gate_texts(pl)
    local out={}
    local sch=try(function() return pl.schedule end)
    for i,rec in ipairs(sch and sch.records or {}) do
      local ws={}
      for k,w in ipairs(rec.wait_conditions or {}) do
        local t=w.type..(w.ticks and ' '..secs(w.ticks) or '')..(w.condition and ' '..cond_text(w.condition) or '')
        ws[#ws+1]=(k>1 and (w.compare_type=='or' and 'or ' or 'and ') or '')..t
      end
      out[i]=(rec.station or '?')..': '..(#ws>0 and table.concat(ws,' ') or 'no wait condition')..(rec.allows_unloading==false and '; unloading off' or '')
    end
    return out
  end
  M.gate_texts=gate_texts
  -- platform_schedule: the call (schedule_call), with each stop it changed recorded (who, when, old and new) and whoever
  -- set that stop last before, if someone else, told once.
  -- (d19 batch46 3) the stops in order ("1 nauvis, 2 vulcanus") and paused, for the platform's setting edits
  local function stop_list(pl)
    local sch=try(function() return pl.schedule end)
    local out={}
    for i,rec in ipairs(sch and sch.records or {}) do out[#out+1]=i..' '..tostring(rec.station or '?') end
    return #out>0 and table.concat(out,', ') or 'no stops'
  end
  -- (d19 batch48 2, Sol 17:29: a queued wait_until platform_left right after a platform_schedule step that departed at
  -- once began after the departure and waited for a later one) the departure a call causes: platform name ->
  -- {from, tick, by}; wait_until platform_left begun within DEPART_GRACE ticks after it counts it (conditions.lua).
  M.DEPART_GRACE=60  -- (conditions.lua DEPART_GRACE)
  function M.platform_schedule(p,a)
    -- (d22 batch100 BJ1) a game object is userdata in 2.0: a type check for a table dropped every platform, so no
    -- departure was ever recorded on the real engine (the tests' platforms are tables)
    local found,plw=pcall(M.platform,p,a.platform)
    if not found then plw=nil end
    local function waiting(x) return platform_states[x.state]=='waiting_at_station' or M.waiting_now(x)~=nil end
    local from=plw and waiting(plw) and try(function() return plw.space_location.name end) or nil
    local out1=M.platform_schedule_call(p,a)
    if from and plw.valid and not a.dry_run and not waiting(plw) then
      local st=api.state and api.state()
      if st then
        st.schedule_departures=st.schedule_departures or {}
        st.schedule_departures[plw.name]={from=from,tick=game.tick,by=p.name}
      end
      if type(out1)=='table' then out1.departed=string.format('left %s at tick %d (state %s): a wait_until platform_left begun within %d ticks counts this departure',
        from,game.tick,tostring(platform_states[plw.state]),M.DEPART_GRACE) end
    end
    return out1
  end
  function M.platform_schedule_call(p,a)
    -- (d24 batch141 PM1 cp2) a failed lookup leaves nil: a type check for a table dropped every real platform (userdata,
    -- as batch100 BJ1 found in platform_schedule), so no schedule edit was recorded on the game
    local pl
    if api.editlog and (a.stops~=nil or a.stop~=nil or a.paused~=nil or a.current~=nil) then
      local found,x=pcall(M.platform,p,a.platform)
      if found then pl=x end
    end
    local before=pl and api.editlog and gate_texts(pl)
    local stops_before,paused_before=pl and stop_list(pl),pl and (pl.paused and 'paused' or 'not paused')
    -- (d24 batch141 PM1) the schedule's change, marked (made.lua) whether the call goes on to fail or not
    local okm,mpl=pcall(M.platform,p,a.platform)
    local function sched(x) return stop_list(x)..', current '..tostring(try(function() return x.schedule.current end) or 'none')..(x.paused and ', paused' or '') end
    local was=okm and mpl and not a.dry_run and sched(mpl)
    local gates_was=was and gate_texts(mpl)
    local ok,out=pcall(M.schedule_call,p,a)
    local now=was and mpl.valid and sched(mpl)
    if now and now~=was and api.made then api.made(mpl.name..' schedule: '..now..' (was '..was..')') end
    -- (d24 batch153) a stop's waits or unloading changed with the stops kept: each such stop marked too
    if now and api.made then
      local g=gate_texts(mpl)
      if #g==#gates_was then for i,t in ipairs(g) do if t~=gates_was[i] then api.made(string.format('%s stop %d: %s (was %s)',mpl.name,i,t,gates_was[i])) end end end
    end
    if not ok then error(out,0) end
    if pl and pl.valid and not a.dry_run then
      local told={}
      -- (the stops' own edit is told with the departure gate's, below)
      api.editlog.setting('plat:'..pl.name,'schedule stops',p.name or '?',stops_before,stop_list(pl),true)
      for _,n in ipairs(api.editlog.setting('plat:'..pl.name,'paused',p.name or '?',paused_before,pl.paused and 'paused' or 'not paused') or {}) do told[#told+1]=n end
      if #told>0 then out.told_of_setting_edit=told end
    end
    if before and pl.valid and not a.dry_run then
      local changes=api.editlog.diff(before,gate_texts(pl))
      if #changes>0 then
        local owed=api.editlog.record('gate:'..pl.name,p.name or '?',changes,function(k) return pl.name..' stop '..k end)
        out.told_of_edit=api.editlog.tell(owed,p.name or '?')
      end
    end
    return out
  end
  -- (d26 batch231 RG, Astra #2427: the queue's dry run took a platform_schedule step the run then refused, "nothing
  -- changed: its new waits at stop 1 (fulgora), where it waits, hold now ...; go: true makes the edit anyway") a
  -- platform_schedule step read against the world now as the call reads it before it changes anything: refused (the
  -- call's own refusal now) and depends (what a refusal when it runs turns on). Nothing is changed.
  local function plain(err) return (tostring(err):gsub('^[^:]*:%d+: ','')) end
  function M.schedule_check(p,a)
    local okp,pl=pcall(M.platform,p,a.platform)
    if not okp then return {refused=plain(pl),depends='the platform '..tostring(a.platform)..' when it runs'} end
    local bad=select(2,pcall(arg_checks,a))
    if bad then return {refused=plain(bad)} end
    local sch=try(function() return pl.get_schedule() end)
    local n=sch and try(function() return sch.get_record_count() end) or 0
    local recs=try(function() return pl.schedule.records end) or {}
    local stuck_note='; a call that changes the schedule fails when the platform still reads no_schedule or no_path 300 ticks after it'
    local function first_err(fn) local ok,err=pcall(fn); if not ok then return plain(err) end end
    if a.next~=nil then
      if n==0 then return {refused=pl.name..' has no schedule: give stops'} end
      return {depends='its schedule when it runs (it has '..n..' stops now)'..stuck_note}
    end
    if a.current~=nil and a.stops==nil and a.stop==nil then
      if n==0 then return {refused=pl.name..' has no schedule: give stops (and current)'} end
      local new
      local err=first_err(function() new=api.integer(a.current,nil,1,n,'current') end)
      if err then return {refused=err} end
      local cur=sch.current or 1
      local st=platform_states[pl.state]
      if st=='no_schedule' and M.waiting_now(pl) then st='waiting_at_station' end
      local depends=string.format('refused if stop %d (%s) is then the current stop and it waits or flies there (now: current %d, %s)%s',
        new,tostring(recs[new] and recs[new].station),cur,tostring(st),stuck_note)
      if new==cur and (st=='waiting_at_station' or st=='on_the_path') then
        return {refused=already_current(cur,recs[cur] and recs[cur].station,st,n),depends=depends}
      end
      return {depends=depends}
    end
    if a.stop~=nil then
      if n==0 then return {refused=pl.name..' has no schedule: give stops'} end
      local idx
      local err=first_err(function() idx=api.integer(a.stop,nil,1,n,'stop') end)
      if err then return {refused=err} end
      if a.wait==nil then return nil end
      local station=recs[idx].station
      local waits
      err=first_err(function() waits=stop_waits(idx,{station=station,wait=a.wait},{},{}) end)
      if err then return {refused=err} end
      local leave,unknown,cur=leave_check(pl,sch,recs,n,idx,station,waits,a.current)
      local depends=string.format('the edit makes it leave at once if it then waits at stop %d (%s) and its new waits hold then (time from its arrival, item_count against the hub, circuit against the hub\'s wires, all_requests_satisfied)%s; %s',
        idx,tostring(station),a.current~=nil and a.current~=cur and ', or current '..tostring(a.current)..' sends it to another stop while it waits' or '',
        a.go==true and 'go: true makes it then' or 'that is refused, nothing changed, without go: true')
      if leave and a.go~=true then return {refused='nothing changed: '..leave..'; go: true makes the edit anyway',depends=depends} end
      return {depends=depends,now=leave and 'it would leave at once now: '..leave or unknown}
    end
    if a.stops~=nil then
      for i,stop in ipairs(type(a.stops)=='table' and a.stops or {}) do
        local err=first_err(function()
          assert(type(stop)=='table' and type(stop.station)=='string' and prototypes.space_location[stop.station],'stop '..i..': station must be a planet or space location name')
          -- (save_as left out: it would keep the list now)
          local copy={}
          for k,v in pairs(stop) do if k~='save_as' then copy[k]=v end end
          stop_waits(i,M.saved_waits(i,copy,{},p),{},{})
        end)
        if err then return {refused=err} end
      end
      local err=a.current~=nil and first_err(function() api.integer(a.current,1,1,math.max(1,#a.stops),'current') end)
      if err then return {refused=err} end
      if a.keep_leg then
        local leg=pl.space_connection and try(function() return freight.leg(pl) end) or nil
        local depends='keep_leg: the leg it flies when it runs'..stuck_note
        if not leg then return {refused='keep_leg: '..pl.name..' flies no leg now ('..tostring(platform_states[pl.state])..')',depends=depends} end
        local found
        for _,stop in ipairs(a.stops) do if type(stop)=='table' and stop.station==leg.to then found=true end end
        if not found then return {refused=string.format('keep_leg: the stops hold no %s, the destination of the leg it flies (%s->%s); add it or leave keep_leg out',leg.to,leg.from,leg.to),depends=depends} end
        return {depends=depends}
      end
      return {depends='the platform when it runs'..stuck_note}
    end
    return nil
  end
  -- Each platform_schedule step of a plan, and the first REQUEST_CHECKS requests steps on a platform hub (their dry run:
  -- waits_unmet and sends_down; about 5 ms each on a copy of world n, Kestrel IVc's 30 sections), read now; lines or nil
  -- (scheduler.lua queue_submit dry_run: world_checks).
  local REQUEST_CHECKS=4
  M.REQUEST_CHECKS=REQUEST_CHECKS
  function M.world_checks(p,items)
    local lines={}
    local reqs,skipped=0,{}
    for i,st in ipairs(items or {}) do
      local a=type(st.args)=='table' and st.args or {}
      local head=string.format('step %d (%s%s%s)',i,st.action,a.platform and ' '..tostring(a.platform) or '',a.stop and ' stop '..tostring(a.stop) or '')
      if st.action=='platform_schedule' then
        local ok,r=pcall(M.schedule_check,p,a)
        if not ok then lines[#lines+1]=head..': not checked: '..plain(r)
        elseif r then
          if r.refused then lines[#lines+1]=head..': refused if it ran now: '..r.refused end
          if r.now then lines[#lines+1]=head..': now: '..r.now end
          if r.depends then lines[#lines+1]=head..': when it runs: '..r.depends end
        end
      elseif st.action=='requests' and a.platform~=nil and a.dry_run==nil and reqs>=REQUEST_CHECKS then
        skipped[#skipped+1]=tostring(i)
      elseif st.action=='requests' and a.platform~=nil and a.dry_run==nil then
        reqs=reqs+1
        local b={}
        for k,v in pairs(a) do b[k]=v end
        b.dry_run=true
        local ok,r=pcall(M.requests,p,b)
        if not ok then lines[#lines+1]=head..': refused if it ran now: '..plain(r)
        elseif type(r)=='table' then
          for _,l in ipairs(r.waits_unmet or {}) do lines[#lines+1]=head..': if it ran now: '..l end
          for _,l in ipairs(r.sends_down or {}) do lines[#lines+1]=head..': if it ran now: '..l end
        end
      end
    end
    if #skipped>0 then lines[#lines+1]=string.format('requests steps %s: not read (the first %d requests steps on a platform are read, each a dry run of the call)',table.concat(skipped,', '),REQUEST_CHECKS) end
    return #lines>0 and lines or nil
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
      assert(a.force==nil or type(a.force)=='boolean','force must be true or false')
      -- (d17 batch32 A1) refused while the rocket holds cargo no platform above asks for, unless force
      local risk=a.auto_requests and not silo.use_transitional_requests and api.trash_risk and api.trash_risk(silo,p.force)
      if risk and risk.lost and not a.force then
        error(string.format('automatic requests stay off: %s. Launch it first (launch {position, platform}), take it out (transfer {position, direction: to_player, inventory: cargo}), or force: true to switch them on anyway',risk.line),0)
      end
      local rinv=silo.get_inventory(defines.inventory.rocket_silo_rocket)
      -- (d26 batch229 SP) a starter pack while a platform of ours waits here stays aboard (settings.starter_pack: where it goes)
      if risk and risk.starter_pack then
        local rest={}
        for _,c in ipairs(rinv.get_contents()) do if not api.starterpack().is_pack(c.name) then rest[#rest+1]=c end end
        rinv={get_contents=function() return rest end}
      end
      local loaded=a.auto_requests and not silo.use_transitional_requests and top_items(rinv,8)
      local was=silo.use_transitional_requests and 'on' or 'off'
      silo.use_transitional_requests=a.auto_requests
      -- (d19 batch46 3) who switched it, when, before and after (editlog.lua; the silo's reads show it)
      if api.editlog and silo.unit_number then pcall(api.editlog.setting,'silo:'..silo.unit_number,'automatic requests',p.name or '?',was,silo.use_transitional_requests and 'on' or 'off') end
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
    local destination,to,pl,hub_note
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
      -- (d17 batch22 A4, Gemini) the hub's room for this cargo; one that does not fit is refused unless hub_full: true
      assert(a.hub_full==nil or type(a.hub_full)=='boolean','hub_full must be true or false')
      if api.hub_room and destination.station then
        local items={}
        for _,c in ipairs(try(function() return silo.get_inventory(defines.inventory.rocket_silo_rocket).get_contents() end) or {}) do
          items[#items+1]={name=c.name,quality=type(c.quality)=='table' and c.quality.name or c.quality or 'normal',count=c.count}
        end
        local room=#items>0 and try(function() return api.hub_room(pl.hub,items) end)
        if room and not room.fits then
          if a.hub_full~=true then error(string.format('launch refused: %s (%s); hub_full: true launches anyway',room.line,pl.name),0) end
          hub_note=room.line
        end
      end
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
    -- (d26 batch229 SP) a starter pack aboard: what this launch does with it (the copy, 2.0.77)
    local sp=api.starterpack and api.starterpack()
    local packs=sp and sp.packs_in(silo.get_inventory(defines.inventory.rocket_silo_rocket))
    if packs then
      packs=packs..(destination.space_platform and ' starts '..pl.name or destination.station and ' goes to '..pl.name..'\'s hub as cargo' or ' is lost in orbit')
    end
    if not silo.launch_rocket(destination,rider) then error(refused(silo,pl,destination),0) end
    return {launched=true,to=to,starter_pack=packs,cargo=cargo or 'empty',spoiled_percent=spoiled,went_up=went_up,freshness=fresh,hub_full=hub_note,riding=rider and 'the character rides along (~40 s); actions fail until it sits in the hub: poll status (platform, riding)' or nil,
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
    assert(type(a.items)=='table' and #a.items>=1 and #a.items<=M.DROP_ITEMS,'items requires 1..'..M.DROP_ITEMS..' {item,count,quality?}')
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
        local id=api.drops and api.drops.record(p,{pod=pod,hub=pl.hub,platform=pl.name,surface=job.surface,pad=job.pad,pad_e=job.pad_e,near=job.dest.position,sent=text,items=sent,to=job.to})
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
    local job={kind='drop',platform=pl,planet=loc.name,surface=surface.name,pad=pad and pad.position or nil,pad_e=pad,dest=dest,to=to,
      pods=split.pods,sent={},short={},moved={},want=want,full=a.full==true}
    send(p,job,not job.full and 1 or nil)
    -- (d24 batch141 PM1) each pod sent, marked (made.lua): a failure after it answers what went
    for _,x in ipairs(job.sent) do
      if api.made then api.made(string.format('cargo pod %d sent from %s to %s: %s',x.pod,pl.name,surface.name,tostring(x.items))) end
    end
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
      -- (batch28 A2, Astra: 400 rocket fuel asked, 200 sent for want of 10 slots, and the remote queue went on as if
      -- complete) a drop that sent part of what was asked says partial; a queue step with it fails unless partial: true
      out.partial={sent=table.concat(moved_list(job,want),' '),stayed=items_text(left),
        why=string.format('a cargo pod holds %d slots and the list takes %d pods; without full only pod 1 goes',POD_SLOTS,total)}
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
    platform_gate={platform='optional platform name (default every one of ours)',returns='lines: a line a platform: at station X, moving (the leg as flown, from->to with the share flown) or stopped (paused, no schedule, no path), and the current stop of its schedule with each departure condition and what the hub holds against it (item counts: holds N, met or N to go; time left; unmet requests); note. Read only'},
    requests={surface='optional planet name, with position: a requester or buffer chest or landing pad there by remote view, where our force sees the chunk (the reply\'s target says on which surface)',target='character (default when no position/platform)',from_buffers='requester chest: boolean, the "request from buffer chests" switch (the reply says its state)',on_the_way='returned for a landing pad: what it counts on the way, the cargo pods coming down to it (the game\'s count, item*count)',trash_unrequested='boolean: the "trash unrequested" switch of a requester or buffer chest, a hub or your own logistics; on, robots take to storage what it holds that no request names (spoilage among it); the reply\'s trash_unrequested says on or off and, for a chest, what it holds that goes',position='{x,y} of a requester/buffer chest, landing pad or other requester in a visible chunk (remote view; no reach needed)',platform='platform name: its hub requests (what the planet in orbit sends up)',
      set='array of {item,min,max? (omitted: the slot\'s max is kept while at least min; "inf": none),quality?,from? (planet to import from, platform hubs; omitted: the planet the slot already has is kept; false or "": none named, the slot\'s dropped too: the game then stores nauvis, as it does for a new slot with none, and stored says so. At a stop the hub keeps only what its requests from that planet ask; the rest the landing pads there ask for goes down),min_payload? (platform hubs: the GUI\'s custom minimum payload for the request, minimum_delivery_count; omitted: the slot\'s is kept; false clears it). Seen on 2.0.77 above Fulgora: with min_payload 10 and min 50, automatic silos sent rockets of 28, 10 and 12 stone, 50 in all; with none, one full rocket (100 concrete for a min of 50). min is how much the hub asks for; min_payload how little a rocket may carry for it} (a map {item: min} runs as that list); replaces that item\'s slot',clear='array of item names whose request slot is deleted (what is held stays)',remove='the same as clear',force='true: set a personal max under what you hold (the game moves the rest to your trash); without it such a set is refused',clear_all='boolean: empty the section first',keep='platform hubs, with a change: item names or "item@quality" (array; a name alone is normal) the change would leave the hub keeping less of than it holds: each stays requested up to the count held (the dropped request\'s import planet and min payload; stored says), so none goes down as surplus at a stop on that import planet',dry_run='true: change nothing; the reply (sections, stored, sends_down) is what the change would make; on a requester or buffer chest or the character, robot_dispatch: the logistic robots\' trips for what it would ask beyond what it holds (from the chest the network would take each from, select_pickup_point; how many at once, from which roboports, the longest and mean trip, trips over 200 tiles, legs within reach of a worm or spawner the map shows)',section='1-based section index as the sections are before the call (a construction_requests switch in the same call moves the game\'s section: the call still writes the section it named, section_moved says where it is now), or a logistic group\'s name (the one section in that group) (default the first manual ungrouped section, created if none); a section the game controls (controlled in the read) is refused, naming what controls it and the same call with add_section: true in place of section',
      active='boolean: switch the section on or off (the GUI\'s checkbox; a section that is off requests nothing)',
      add_section='true: a new manual section (the GUI\'s Add section), its index in section_change; set, clear and active in the same call go to it; with group it joins that group',
      remove_section='a manual section\'s index: the section removed with its requests (alone, or with dry_run: what the hub would keep and send down without it); a section in a group leaves it, the group stays',
      group='with section (or add_section): the GUI\'s logistic group of that section: a name that exists: the section takes the group\'s requests and its own are gone (dropped names them); a new name: the group is made from the section\'s requests; false: it leaves the group keeping a copy of the requests. A set or clear in a section of a group changes every member: group_edit names each other one (a dry run too)',
      groups='true, alone: every named logistic group of our force: name, requests, members_count and members (each entity and section whose GUI shows the group); a group with no members stays',
      construction_requests='platform hub: boolean, the hub\'s Request missing construction materials (on: the game keeps a section requesting what the platform\'s ghosts need; a paste of a hub blueprint that has it off switches it off, and paste switches it back on)',
      returns='target, sections [{index, group, off (switched off: its requests are not made), controlled (true: the game writes this section, and refuses a script\'s write to it; false: manual), controlled_by (what controls it: a hub\'s construction requests, a silo\'s automatic requests, or the circuit network), requests ["item min..max from planet", "item=n from planet"], imports (a platform hub, a section switched on: each import request "item from planet: asks N, holds H, W on the way, lacks L", on the way being what rockets launched to the hub carry, the hub GUI\'s in-transit count)}], changed_section (only when a slot was set or cleared or the section switched; else unchanged), section_before and section_after (a write: the section written, {index, group, active}, before the call and now), section_moved, stored (each item this call set or cleared, as read back from its slot: "processing-unit 0..400 from vulcanus (import planet kept: not named in this edit) (was 0..200 from vulcanus)", "coal: cleared (was coal=500 from vulcanus)"), note (sections that are off but hold requests); on a platform hub: construction_requests (on: its controlled section lists what the ghosts need), construction_overlap (items a manual section requests too: the hub requests the sum), over_max (a max set in this call under what the hub holds), hub_trash, trash_note (where the game sends the trash); sends_down (a change on a hub that alters what its requests keep of an item it holds, each quality its own (item@quality for one other than normal): what they would keep and kept, by import planet, and what goes down to the landing pads of its stops, where it waits first then its schedule\'s: at each stop their ask less what they hold, beyond what its requests from that planet keep; or that it stays aboard; in flight only what the trash has room for goes now, the rest stays in the hub while it flies), sends_down_rule (the rule, with the cases it comes from); waits_unmet (a change on a hub: each item_count wait of the stop it waits at or its next stop whose number the new maxes from that stop\'s planet leave unreached: the stop, the wait, the max there (was), what the hub holds; the hub keeps no more than those maxes there); reply_failed (each part of the reply that failed after the change, with its error; the change stands: stored), reply_failed_note; a call that fails partway after a change answers change_made (each change made) and reply_failed (the error); call with no set/clear/active to just read'},
    platform={fields='optional 1..32 names (a list, or one string with | or ,): only those fields of the reply: a top-level key, a key of each row (platforms, inspect results or entities; rows keep name and position), or one level down (\"hub.cargo\"); a name this reply lacks that the read can have is listed in absent; a name the read never has is refused, with the names there are',platform='optional platform name (or name): the platforms read of that one (as platforms {platform}); none: every platform',name='the same as platform',compact='as platforms',returns='as platforms'},
    platforms={page='with compact: false and no platform named (or eta_to): 1.. the page of full rows, 2 a page (the reply: page, pages, count, next)',fields='optional 1..32 names (a list, or one string with | or ,): only those fields of the reply: a top-level key, a key of each row (platforms, inspect results or entities; rows keep name and position), or one level down (\"hub.cargo\"); a name this reply lacks that the read can have is listed in absent; a name the read never has is refused, with the names there are',eta_to='optional planet name: each platform\'s ETA to it through its schedule (the leg it flies at its cruise speed, its stops\' waits and what an agent\'s queue or order sends it on with, the legs between), or why there is none (no schedule, paused, it does not go there); eta_to lines and on each row {planet, eta_s, line}',departure='returned on each platform: the agents\' queue steps and standing orders that set its schedule (platform_schedule), each with the wait before it, beside the schedule\'s own waits (stops)',compact='the default with no platform named (false: every platform\'s full row, 2 a page: page (1..), pages, count, next): a line a platform: where it is, ammunition aboard (hub and turrets), thruster fuel and its net trend over 10 min, how many items its ghosts lack in all, and only the blockers you were not shown in your last compact read (the rest counted)',request_edits='true: request_edits on each full row (each hub section\'s last edit: who, when, old -> new)',platform='optional name: only this one, with its full hub inventory, speed (the game\'s value, km per tick), damaged up to 10 (the game repairs platform entities itself with the hub\'s repair packs, one at a time), damaged_tiles, foundation_lost (asteroids destroy foundation tiles with no event and the game puts a ghost on each at once; the hub builds them from its foundation, uncounted in the item statistics: {since_tick, rebuilt (built on ghosts no one placed: destroyed tiles), placed_built, taken {quality: n}, open (foundation ghosts no one placed aboard now), open_placed, rows [{tick, what, count, at}], builds_heard, line}; a placer is the harness\'s ghost log), asteroid_chunks on the platform surface by type, thrusters (count by quality, lowest fuel/oxidizer tank), after_pumps (a line per thruster fluid: what stays with the thrusters when their pumps stop and how long it burns at their own quality; a last line names the fluid that sets the thrust) and thruster_burn (its thrusters by quality and their burn at full thrust, then the game\'s rule: quality multiplies the burn and thrust), thrust_inputs (a line per thruster input under half full: the pumps, tanks and machines behind it and why they stop, down to the hub\'s asteroid chunks), unbuilt_ghosts, construction_blocked (why the hub cannot build or deconstruct now: hub full, ghosts whose items the hub lacks, tile ghosts the foundation rules hold back: one that would split the empty space beside it (the hub looks at a tile\'s 8 neighbours), with the hole on one side that has no ghosts, or one with no foundation among the 8 tiles round it), tile_removals (the marked foundation tiles: marked, go (those the hub removes, one at a time, in order), waiting (each with why, as deconstruct says it)), hub_inserters_without_target (inserters taking from the hub with nothing to drop into, and the tile they drop onto), thrown_overboard (items in flight off the platform), consumed_10min and produced_10min (the game\'s item statistics for the platform surface), freight (its last 6 stops and legs, newest first: per stop what the planet\'s landing pads asked of the hub on arrival (expected down), what the hub asks from that planet (expected up), what left the hub and came aboard (net over the stop; a rocket cargo item construction robots placed at once counts as came aboard and is said as built at once), what spoiled aboard, rockets launched to it with their cargo, the cargo pods sent down with what each landing pad received (landed: a line a pod, its cargo, where and when, and what the planet\'s landing pad asked of that cargo when the pod left the hub, as the pad\'s window showed it then: each active section asking it with min..max and whether the circuit network sets it, what the pad held, and what the other pods followed to that planet carried of it), those that landed with no pad, and those still in flight (unit numbers, cargo); per leg the spoilable items aboard at departure, spoiled on the way and at arrival), spoiling (the hub\'s spoilable items: the first stack to spoil and its share; in flight how many spoil before the arrival and when the next spoils after it; spoilable science effective research units now and at the current-speed leg ETA, before lab bonuses), freshness (on every row: spoilable science effective research units now and, when the leg ETA is known, at arrival (before lab bonuses); the hub\'s spoilable items, each one\'s spread as inspect gives it, and for a pack the running research takes how many a unit the running research takes and its units left), engine (the last 60 and 180 s, sampled each second: speed mean, lowest, highest, first and last; each thruster fluid used and made by the surface\'s fluid statistics and in the thrusters\' tanks at start and end; the pumps\' share of time working, from a read of each pump once a second at a phase 7 ticks later each second, so a minute meets every tick of a second once), ammo_rates (per ammo type held or made or used: made and used a minute over the last leg from the surface\'s item statistics (used: turret shots and ammo crafted into other items), every place aboard now; in flight the reserve at the arrival at that rate, or when it runs out first, counted as platform_endurance counts it: ammunition that can reach a turret, rockets on their way up, made at most what the ingredients aboard allow, and binds: the limit that sets what is made; a leg begun before the runtime counted: the last 10 min), incoming (rockets launched to its hub whose cargo pod has not arrived: from, how long ago, cargo, rising or coming down) and incoming_cargo',returns='platforms [{name, state, at (the location where it is stopped; a location it is still on its path at says so; in flight the leg as flown, from->to with the share flown; turned back mid-connection: back to the end it left, km left), speed_kms, next_stop (the stop it flies to; waiting at a stop, the one after), on a route leg (as flown), heading_to (the schedule stop when it is an end of the connection, else the end with the shorter way on to it), turned_back, leg_km, leg_left_km, eta_min (at the current speed), schedule, waiting (stopped at the station of its current stop, not paused, the game reading waiting_at_station or no_schedule: \'waiting at stop N (station): conditions false now: each condition with its value [holds|false|not read]\', or hold now; the game reads no_schedule while a platform waits at a stop it was sent to while there), stops (each stop with its wait conditions: waiting here with how far each is (time left, inactivity, the hub\'s count for item_count, unmet requests), flying to it, next), hub, hub_items, hub_slots (free of all), hub_chunks (hub slots asteroid chunks take, one a slot), hub_trash, hub_trash_note (where the game sends the trash: kept in flight; at a planet stop down in cargo pods to its landing pad, or with none as cargo-pod containers near (0,0)), requests, imports (each import request: asks, holds, on the way in rockets launched to the hub (the hub GUI\'s in-transit count), lacks), requests_off (in hub sections switched off: not requested), leave_ok, defense {hub_health, turrets (count: empty, low under 10 rounds), ammo (rounds the turrets hold against the ammo in the hub)}, repair_packs, damaged (most damaged first: 3, or 10 with platform; damaged_count when more)}], silos on this surface {position, status, parts, cargo}, planet'},
    platform_create={name='optional platform name',planet='default the character\'s planet',starter_pack='default space-platform-starter-pack',note='like the platform GUI: the platform waits for its starter pack; a silo holding one in its rocket cargo launches it on its own'},
    platform_schedule={one_stop='"as given": one stop written alone (default: one stop that is not where the platform is goes as [where it is, that stop], current 2, as every one-stop schedule in the journals read no_schedule; the reply\'s one_stop says so). Any call that changes the schedule or paused fails when the platform then reads paused without paused: true; no_schedule or no_path read in the call\'s tick are read again every 10 ticks for up to 300 (the game updates a platform in a later tick: Cinder flew 39 ticks after such a read): a queue step waits for that read and fails only when it still reads so; a direct call\'s reply has recheck and the second read comes as a tell from platform_schedule (the schedule stays as set; the error gives the rule seen)',unloading='with stop: true or false, that stop\'s allow unloading (the schedule GUI\'s checkbox) set in place, alone or with wait (the reply\'s unloading says it, was and now); off: the landing pads there take nothing from the hub, all the hub holds above a finite max of its sections for that planet still goes down (2.0.77 on a copy of world n), and drop still sends pods; every schedule read marks such a stop [unloading off]',stop='1-based record, with wait (B8) or unloading: that stop\'s wait conditions replaced in place (the schedule\'s own wait condition calls), the records, the current stop and the state kept; current with it changes the current stop too. Refused, nothing changed, when the edit makes the platform leave now (current set to another stop while it waits; the stop it waits at left with no wait; its new waits holding now: time from its arrival, item_count against the hub, circuit against the hub\'s wires, all_requests_satisfied) unless go: true. Returns edited, leaves, may_leave (waits not read that may hold), read_as, waits_run, harness_waits',wait='with stop: that stop\'s waits, as a stops entry\'s wait ([] for none)',go='true, with stop: make an edit that sends the platform on now',next='true, alone: the game\'s go to station on the stop after the current one now (the records and their waits kept); sent_to says from which stop to which',platform='name',stops='array of {station=planet, wait=[{type=all_requests_satisfied|any_request_not_satisfied|any_request_zero|time|inactivity|item_count|fluid_count|circuit, ticks? (time, inactivity), condition? (item_count, fluid_count, circuit: "thruster-fuel >= 10000" or {signal, comparator, value | signal2}; item_count an item, fluid_count a fluid; circuit any signal on the hub\'s red and green wires; {item|fluid, count|at_least} reads as "NAME >= N", seconds as ticks, said in read_as; any other field is refused), compare=and|or, harness? (fluid_count: true: the harness reads the storage tanks and sends the platform on, the game\'s record holding a circuit wait that never holds; with time and item_count waits joined by and only)}], unloading? (true or false: the stop\'s allow unloading; default as the schedule\'s first stop at that station had it before the call, else on)}; e.g. {"station":"nauvis","wait":[{"type":"time","ticks":216000},{"type":"circuit","condition":"thruster-fuel >= 10000","compare":"and"}]}; [] clears; circuit_note when the hub has no wire',current='1-based stop to head for (default 1); alone (no stops): go to that stop now, the records and their waits kept (the GUI\'s go to station), refused when it is already the current stop',keep_leg='optional true, while flying: the current stop is the stop for the leg\'s destination (refused when the stops hold none; current goes without it)',paused='boolean: pause/unpause thrust and the schedule (paused on a route, the platform stays among its asteroids and drifts back; the reply\'s note says so)',returns='name, state (read after the change), waiting (at the station of its current stop, not paused, the game reading waiting_at_station or no_schedule: \'waiting at stop N (station): conditions false now: each with its value\', or they hold now), state_note (no_schedule waiting on conditions false now: that line, and no recheck or failure; no_schedule otherwise, no_path or paused: it goes nowhere), recheck (any other no_schedule or no_path read: read again, its line), at, paused, schedule; with stops: sent_to (the GUI\'s go to station called for current), rebuilt (when the state read no_schedule after the records were set: written again record by record as the GUI does and sent again, with the state after), go_error; current_note (the current stop is the station it is at: it waits there on that stop\'s conditions, the waiting line); leg (in flight: the leg before the edit and the current stop now: the same destination, back the way it came, or new); unloading (with stops: each stop with unloading off, and whether it was kept from before; with stop and unloading: was and now), unloading_rule; note, circuit_note'},
    drop={partial='optional true: a queue step that sends part of what was asked (without full, pod 1 of several) is done; without it such a step fails. Every reply that sent part says partial {sent, stayed (still in the hub), why}',up_to='optional true: drop what the hub holds now of each item, up to its count (up_to says what it held); holding none of any, the drop is done with nothing sent (nothing_to_drop), a queue step too',platform='platform name (default: the one you are aboard)',items='array of 1..20 {item,count,quality?} from the hub inventory',position='optional {x,y} to land near when the planet has no landing pad of ours (default: a bot\'s last spot there, else the spawn point)',to='optional teammate name or list: told where it landed too, in their team block',
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
      arrived='optional true, with platform: launch only when the platform is stopped at this planet (not on its path), by the platform_arrived rule, read in the tick it launches; else refused, nothing launched',auto_requests='boolean: the silo GUI setting to fill and launch rockets on its own for platforms\' requests in orbit (alone: only sets it; switched on with cargo loaded by hand, the game moves that cargo to the silo\'s trash slots, which never launch: so true is refused while the rocket holds cargo no platform stopped above asks this planet for, naming it, unless force: true; then cargo_to_trash, note, trash)',force='with auto_requests: true: switch them on even though cargo aboard would go to the trash slots',returns='launched, to, cargo, spoiled_percent {item: its spoiled share by count} and went_up (a line: each spoilable item, its count and share), freshness (the cargo\'s spoilable items, each one\'s spread and how many a unit the running research takes and its units left, read before it goes); checked {tick, lines} (min_cargo, arrived); settings {silo, auto_requests, send_to_orbit_automatically, requesting_for, rocket, parts}: the silo\'s switches after the call',refused='overweight by N kg (a rocket lifts 1000 kg; the cargo listed by weight) before the game is asked; when the game refuses, what it may check'},
  }
  return M
end
