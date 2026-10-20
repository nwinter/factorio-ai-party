-- World predicates for plan waits and guards. Each reads only what the player
-- could see: enemy structures on the chart, units in visible chunks, our own
-- turrets, ghosts, buildings and burners, the character's health and inventory.
return function(api)
  local M={}
  local function try(fn) local ok,v=pcall(fn); if ok then return v end end
  local ENEMY_STRUCTURES={'unit-spawner','turret'}
  local OUR_TURRETS={'ammo-turret','electric-turret','fluid-turret','artillery-turret'}
  local BURNERS={'furnace','mining-drill','boiler','inserter','assembling-machine','reactor','burner-generator','car','locomotive'}
  local function number(v,low,high,name)
    assert(type(v)=='number' and v>=low and v<=high,name..' must be a number in '..low..'..'..high)
    return v
  end
  -- Area predicates centre on `position` (default: the character).
  local function area(p,c)
    return c.position and api.position(c.position) or p.position,c.radius or 32
  end
  local function enemies(p,c,types)
    local centre,radius=area(p,c)
    local n=0
    for _,e in pairs(p.surface.find_entities_filtered{position=centre,radius=radius,type=types,force='enemy'}) do
      if e.valid and api.known(p,e) then n=n+1 end
    end
    return n
  end
  local function selected(p,c,types)
    local centre,radius=area(p,c)
    local filter={position=not c.area and centre or nil,radius=not c.area and radius or nil,area=c.area,type=types,force=p.force,limit=1025}
    local list=p.surface.find_entities_filtered(filter)
    assert(#list<=1024,'condition area exceeds 1024 entities')
    return list
  end
  local function turrets(p,c) return selected(p,c,OUR_TURRETS) end
  local function ammo(e)
    local inv=e.type=='ammo-turret' and e.get_inventory(defines.inventory.turret_ammo)
    return inv and inv.get_item_count() or nil
  end
  -- A rocket silo as its GUI shows it: the rocket's state and its cargo
  -- (Luna, shift10 06:20: an item_count wait for the item rocket stayed 0 at a
  -- silo whose rocket was ready; the rocket is no item, the item rocket is ammunition).
  local silo_states
  -- A built rocket rising into place (silo.lua's RISING): its parts are all made.
  local ROCKET_UP={create_rocket=true,lights_blinking_open=true,doors_opening=true,doors_opened=true,rocket_rising=true,arms_advance=true}
  local function rocket_state(e)
    if not silo_states then silo_states={}; for k,v in pairs(defines.rocket_silo_status) do silo_states[v]=k end end
    local ok,st=pcall(function() return e.rocket_silo_status end)
    return ok and (silo_states[st] or tostring(st)) or 'unknown',ok and st==defines.rocket_silo_status.rocket_ready
  end
  local function silo_line(e)
    local state,ready=rocket_state(e)
    local parts,after='',''
    pcall(function() parts=string.format(', parts %d/%d',e.rocket_parts,e.prototype.rocket_parts_required) end)
    -- A built rocket said plainly: ready to launch, not launched (Astra 10:50); the parts counted then are the next
    -- rocket's, said last (round1650d: Grok read "parts consumed (13/50)" beside a ready rocket as one being built), and
    -- the built rocket's own parts with it (shift14 21:20: Grok read a ready rocket beside 6/50 as one with 6 parts).
    if ready then
      state='rocket built and ready to launch, not launched'
      pcall(function()
        local n=e.prototype.rocket_parts_required
        state=string.format('rocket built (%d/%d parts) and ready to launch, not launched',n,n)
        after=string.format('; parts for the rocket after it %d/%d',e.rocket_parts,n)
      end)
      parts=''
    end
    local cargo={}
    local ok,inv=pcall(e.get_inventory,defines.inventory.rocket_silo_rocket)
    if ok and inv then
      for _,c in ipairs(inv.get_contents()) do cargo[#cargo+1]=c.name..'*'..c.count end
    end
    return string.format('rocket-silo (%g,%g): %s%s, cargo %s%s',e.position.x,e.position.y,state,parts,
      #cargo>0 and table.concat(cargo,' ') or 'none',after),ready
  end
  -- Our rocket silo on the tile c.position (any tile of its footprint).
  local function silo_at(p,c)
    assert(c.position,tostring(c['until'] or 'rocket_ready')..' requires position (a rocket silo\'s, any tile of it)')
    local pos=api.position(c.position)
    -- (d20 batch52 K2, Sol #882: surface=nauvis from Aquilo read the character's surface) surface: the silo there, by
    -- remote view in a chunk our force has charted, as its GUI opens there.
    local s=p.surface
    if c.surface~=nil then
      s=game.get_surface(c.surface)
      if not s then error('no surface named '..tostring(c.surface),0) end
      if s~=p.surface and not p.force.is_chunk_charted(s,{math.floor(pos.x/32),math.floor(pos.y/32)}) then
        error(string.format('(%g,%g) on %s is not charted: no remote view of a silo there',pos.x,pos.y,s.name),0)
      end
    end
    -- An area search meets the footprint (a position and radius only the silo's centre, read on a copy of world n).
    for _,e in pairs(s.find_entities_filtered{area={{pos.x-0.01,pos.y-0.01},{pos.x+0.01,pos.y+0.01}},type='rocket-silo',force=p.force}) do
      if e.valid then return e end
    end
    error(string.format('no rocket silo of ours at (%g,%g) on %s',pos.x,pos.y,s.name),0)
  end
  -- Each returns met, and a short description of what it saw.
  -- A condition's own memory where no wait record is given (queue step conditions, orders): kept while the condition
  -- table lives.
  local seen=setmetatable({},{__mode='k'})
  local DEPART_GRACE=60  -- (d19 batch48 2) ticks: a platform_schedule departure this long before a platform_left wait began counts
  local function seen_by(c) seen[c]=seen[c] or {}; return seen[c] end
  -- An area or a list of them ({left_top, right_bottom} or [[x,y],[x,y]]), as {{x0,y0},{x1,y1}} boxes; {} for nil.
  function M.areas_of(v)
    if v==nil then return {} end
    assert(type(v)=='table','area/tiles is {left_top, right_bottom} or a list of them')
    local list=(v.left_top or (type(v[1])=='table' and type(v[1][1])=='number')) and {v} or v
    assert(#list>=1 and #list<=64,'area/tiles: 1..64 areas')
    local out={}
    for _,ar in ipairs(list) do
      local lt,rb=ar.left_top or ar[1],ar.right_bottom or ar[2]
      lt,rb=api.position(lt),api.position(rb)
      assert(lt.x<rb.x and lt.y<rb.y,'an area has left_top above and left of right_bottom')
      out[#out+1]={{lt.x,lt.y},{rb.x,rb.y}}
    end
    return out
  end
  local checks={
    no_enemy_structures=function(p,c)
      local n=enemies(p,c,ENEMY_STRUCTURES); return n==0,n..' enemy structures'
    end,
    -- Enemy units only (d17 batch13 A2: a rearm waiting for passing enemies to go; worms and spawners stay): units,
    -- pentapods and demolishers within the radius, as no_enemies counts them.
    units_clear=function(p,c)
      local n=enemies(p,c,{'unit','spider-unit','segmented-unit'}); return n==0,n..' enemy units'
    end,
    no_enemies=function(p,c)
      -- spider-unit: Gleba's strafer and stomper pentapods; segmented-unit: Vulcanus' demolishers.
      local n=enemies(p,c,{'unit-spawner','turret','unit','spider-unit','segmented-unit'}); return n==0,n..' enemies'
    end,
    turrets_idle=function(p,c)
      local busy=0
      for _,e in ipairs(turrets(p,c)) do if e.valid and e.shooting_target then busy=busy+1 end end
      return busy==0,busy..' turrets shooting'
    end,
    -- (d20 batch52 K1, Astra #1352: a bounded native flight test's rescue guard, refused in the remote lane) platform:
    -- the ammo turrets on that platform, all of them, those at positions or in area (platform coordinates), as its
    -- turret GUIs show them; saw names the lowest turret and what it holds.
    ammo_below=function(p,c)
      local list
      if c.platform then
        local pl=M.platform_named(p,c.platform)
        local s=pl.surface
        if not s then error('platform '..c.platform..' has no surface yet',0) end
        if c.positions then
          list={}
          for _,raw in ipairs(c.positions) do
            local q=api.position(raw)
            local found=s.find_entities_filtered{area={{q.x-0.01,q.y-0.01},{q.x+0.01,q.y+0.01}},type='ammo-turret',force=p.force,limit=1}
            if not found[1] then error(string.format('no ammo turret of ours at (%g,%g) on %s',q.x,q.y,c.platform),0) end
            list[#list+1]=found[1]
          end
        else
          list=s.find_entities_filtered{area=c.area,type='ammo-turret',force=p.force,limit=1025}
          assert(#list<=1024,'condition area exceeds 1024 entities')
        end
      else list=turrets(p,c) end
      local low,n,lowest=0,0,nil
      for _,e in ipairs(list) do
        local k=e.valid and ammo(e)
        if k then
          n=n+1
          if k<c.count then low=low+1 end
          if not lowest or k<lowest.k then lowest={e=e,k=k} end
        end
      end
      local saw=low..' turrets below '..c.count
      if lowest and c.platform then
        local inv=lowest.e.get_inventory(defines.inventory.turret_ammo)
        local held=try(function() local t={} for _,r in ipairs(inv.get_contents()) do t[#t+1]=r.count..' '..r.name end return table.concat(t,', ') end)
        saw=saw..string.format(' (of %d%s; lowest %s (%g,%g): %s)',n,c.platform and ' on '..c.platform or '',lowest.e.name,lowest.e.position.x,lowest.e.position.y,
          held and held~='' and held or 'no ammo')
      elseif c.platform then saw=saw..' (no ammo turret of ours '..(c.area and 'in that area' or 'aboard')..' on '..c.platform..')' end
      return low>0,saw
    end,
    health_below=function(p,c)
      local ch=p.character; local r=ch.health/ch.max_health
      return r<c.fraction,string.format('health %d%%',math.floor(r*100))
    end,
    health_above=function(p,c)
      local ch=p.character; local r=ch.health/ch.max_health
      return r>c.fraction,string.format('health %d%%',math.floor(r*100))
    end,
    -- In a named platform hub's main inventory, the character's main inventory, or summed over our entities on the
    -- given tiles (chests, machines: every inventory they have; a rocket
    -- silo's rocket cargo too, which the game counts with the silo's own; each
    -- silo's rocket state and cargo follow in saw).
    item_count=function(p,c,estimate)
      local n,where=0,''
      local scope={}
      -- quality (d17 batch33 A2, Astra 09:33: Petrel's wait with quality rare and uncommon read 0 while the hub held 5
      -- rare and 10 uncommon quality-module-3): a count by the item's name alone is normal quality only in 2.0, so each
      -- count reads {name, quality}; "any" sums every quality
      local qualities=c.quality and {c.quality} or nil
      if c.quality=='any' then qualities={}; for q in pairs(prototypes.quality or {normal=true}) do if q~='quality-unknown' then qualities[#qualities+1]=q end end end
      local function counted(fn)
        if not qualities then local ok,k=pcall(fn,c.item); return ok and k or 0 end  -- (the name alone: normal quality)
        local t=0
        for _,q in ipairs(qualities) do local ok,k=pcall(fn,{name=c.item,quality=q}); if ok and k then t=t+k end end
        return t
      end
      -- One position counts as positions={position} (Haiku, 12:20: item_count coal below 20 at a chest; a lone position
      -- was ignored and the character's inventory counted).
      local positions=c.positions or (c.position and {c.position})
      if c.platform then
        local pl
        for _,each in pairs(p.force.platforms) do if each.valid and each.name==c.platform then pl=each; break end end
        assert(pl,'no platform of ours named '..c.platform)
        local hub=pl.hub
        assert(hub and hub.valid,'platform '..c.platform..' has no hub')
        local inv=hub.get_inventory(defines.inventory.hub_main)
        assert(inv,'platform '..c.platform..' has no hub inventory')
        n=counted(inv.get_item_count)
        scope={'platform',c.platform}
        where=' in '..c.platform..' hub (landed stock; excludes incoming cargo and hub trash)'
      elseif c.network then
        -- network {x,y} (batch27 A6): the logistic network covering that spot (on surface, else yours), as its GUI shows it
        local surf=c.surface and game.get_surface(c.surface) or p.surface
        local pos=api.position(c.network)
        local ln=surf.find_logistic_network_by_position(pos,p.force)
        assert(ln,string.format('no logistic network of ours covers (%g,%g)%s',pos.x,pos.y,surf~=p.surface and ' on '..surf.name or ''))
        n=counted(ln.get_item_count)
        scope={'network',surf.name,pos.x..','..pos.y}
        where=string.format(' in the logistic network at (%g,%g)%s',pos.x,pos.y,surf~=p.surface and ' on '..surf.name or '')
      elseif c.surface and not positions then
        -- surface alone (E6, Sol board #755 and Gemini 19:50: from Aquilo, a wait on Nauvis U-235): what our logistic
        -- networks there hold, as each network's GUI shows it
        local s=game.get_surface(c.surface)
        assert(s,'no surface '..tostring(c.surface))
        local nets=p.force.logistic_networks and p.force.logistic_networks[s.name] or {}
        for _,ln in ipairs(nets) do n=n+counted(ln.get_item_count) end
        scope={'surface',s.name}
        where=string.format(' in our %d logistic network%s on %s',#nets,#nets==1 and '' or 's',s.name)
      elseif positions then
        -- surface: the chests at positions on that surface (E6), else yours
        local surf=c.surface and game.get_surface(c.surface) or p.surface
        assert(surf,'no surface '..tostring(c.surface))
        scope={tostring(surf.index or surf.name or '')}
        local seen,silos,dark=0,{},0
        for _,raw in ipairs(positions) do
          local pos=api.position(raw)
          scope[#scope+1]=pos.x..','..pos.y
          local visible=surf==p.surface or pcall(function() return p.force.is_chunk_visible(surf,{x=math.floor(pos.x/32),y=math.floor(pos.y/32)}) end)
            and p.force.is_chunk_visible(surf,{x=math.floor(pos.x/32),y=math.floor(pos.y/32)})
          if not visible then dark=dark+1 end
          for _,e in pairs(visible and surf.find_entities_filtered{position=pos,radius=0.3,force=p.force} or {}) do
            -- A silo's rocket stands on its centre and holds nothing of its own (the silo counts the cargo); a robot
            -- flying over a chest is not the chest (runtime.lua M.target_rank, Astra 07:05).
            if e.valid and e~=p.character and e.type~='rocket-silo-rocket' and e.type~='rocket-silo-rocket-shadow'
              and not (api.passing and api.passing(e)) then
              n=n+counted(e.get_item_count)
              seen=seen+1
              if e.type=='rocket-silo' and #silos<4 then silos[#silos+1]=(silo_line(e)) end
            end
          end
        end
        where=' in '..seen..' entities'..(surf~=p.surface and ' on '..surf.name or '')..(dark>0 and string.format(' (%d position%s not in sight of our force now: not counted)',dark,dark==1 and '' or 's') or '')
          ..(#silos>0 and '; '..table.concat(silos,'; ') or '')
      else
        local inv=p.get_main_inventory()
        n=counted(inv.get_item_count)
        scope={'character',tostring(p.index)}
      end
      local met=(c.at_least==nil or n>=c.at_least) and (c.below==nil or n<c.below)
      return met,c.item..(c.quality and c.quality~='normal' and ' ('..c.quality..' quality)' or '')..' '..n..where,estimate and {value=n,scope=table.concat(scope,':')} or nil
    end,
    -- fluid_count {platform, fluid, at_least | below} (d17 batch17 A5, Astra board #842: Swift's reserve tanks had no
    -- departure guard): the fluid in the platform's storage tanks, as each tank's window shows it.
    -- (batch28 A4, Sol: Kestrel III held full propellant in pipes and thrusters, and a gate on the tanks would wait
    -- forever) every fluidbox of ours on the platform that holds it: storage tanks, pipes (pipes, pipes-to-ground,
    -- pumps), thrusters and machines, each kind said.
    fluid_count=function(p,c,estimate)
      local pl=M.platform_named(p,c.platform)
      local KIND={['storage-tank']='tanks',pipe='pipes',['pipe-to-ground']='pipes',pump='pipes',thruster='thrusters',
        ['assembling-machine']='machines',furnace='machines'}
      local n,by,count={},{},{}
      local total=0
      for _,e in pairs(pl.surface.find_entities_filtered{type={'storage-tank','pipe','pipe-to-ground','pump','thruster','assembling-machine','furnace'},force=p.force,limit=4096}) do
        local ok,k=pcall(function() return e.get_fluid_count(c.fluid) end)
        local kind=KIND[e.type] or 'other'
        if ok and k and k>0 then by[kind]=(by[kind] or 0)+k; count[kind]=(count[kind] or 0)+1; total=total+k end
      end
      local parts={}
      for _,kind in ipairs({'tanks','pipes','thrusters','machines'}) do
        if by[kind] then parts[#parts+1]=string.format('%s %d (%d)',kind,math.floor(by[kind]+0.5),count[kind]) end
      end
      local met=(c.at_least==nil or total>=c.at_least) and (c.below==nil or total<c.below)
      return met,string.format('%s %d on %s: %s',c.fluid,math.floor(total+0.5),c.platform,#parts>0 and table.concat(parts,', ') or 'none in its tanks, pipes, thrusters or machines'),
        estimate and {value=total,scope='fluid:'..c.platform..':'..c.fluid} or nil
    end,
    -- circuit_signal {platform, signal, at_least | below} (A5): the signal on the platform hub's red and green wires
    -- together, as a circuit wait condition reads it.
    circuit_signal=function(p,c,estimate)
      local pl=M.platform_named(p,c.platform)
      local hub=pl.hub
      assert(hub and hub.valid,'platform '..c.platform..' has no hub')
      local sig=M.signal_of(c.signal)
      local n,wires=0,{}
      for _,w in ipairs({{'red',defines.wire_connector_id.circuit_red},{'green',defines.wire_connector_id.circuit_green}}) do
        local ok,net=pcall(function() return hub.get_circuit_network(w[2]) end)
        if ok and net then
          wires[#wires+1]=w[1]
          local okv,v=pcall(function() return net.get_signal(sig) end)
          if okv and v then n=n+v end
        end
      end
      local met=#wires>0 and (c.at_least==nil or n>=c.at_least) and (c.below==nil or n<c.below)
      return met,#wires>0 and string.format('%s %d on %s\'s hub (%s)',c.signal,n,c.platform,table.concat(wires,' and '))
        or string.format('%s\'s hub has no red or green wire: no signal to read',c.platform),estimate and {value=n,scope='circuit:'..c.platform..':'..c.signal} or nil
    end,
    -- What machines made since the wait began (Grok 07:50: item_count on a provider that robots empty never rises, so a
    -- machine that makes things looks stopped): the products-finished counter each machine's GUI shows, on the given
    -- tiles (crafting machines: assemblers, furnaces, chemical plants, ...), counted from its value at the wait's first
    -- check. With item: crafts times what the machine's recipe makes of it per craft; without: crafts. Needs the wait's
    -- record (a wait_until step or a direct wait), where the starting counts are kept.
    produced=function(p,c,estimate,record)
      assert(record,'produced counts from the start of a wait: a wait_until step or a direct wait_until (not a guard, an order\'s when or a loop condition)')
      local base=record.produced_base or {}
      record.produced_base=base
      -- On a platform (D4, Astra ~10 times: the produced wait found no machine counter there): the platform's own item
      -- production statistics, made since the wait began.
      if c.platform~=nil then
        local pl
        for _,each in pairs(p.force.platforms) do if each.valid and each.name==c.platform then pl=each end end
        if not pl then error('no platform of ours named '..tostring(c.platform),0) end
        if not pl.surface then error('platform '..c.platform..' has no surface yet',0) end
        local now=p.force.get_item_production_statistics(pl.surface).get_input_count(c.item)
        if base.platform==nil then base.platform=now end
        local made=now-base.platform
        return made>=c.at_least,string.format('made %d %s on platform %s since the wait began (at least %d; the platform\'s production statistics)',made,c.item,c.platform,c.at_least),
          estimate and {value=made,scope='produced:platform:'..c.platform..':'..c.item} or nil
      end
      local crafts,items,seen,machines=0,0,0,0
      local positions=c.positions or {c.position}
      local scope={tostring(p.surface.index or p.surface.name or '')}
      for _,raw in ipairs(positions) do
        local pos=api.position(raw)
        scope[#scope+1]=pos.x..','..pos.y
        for _,e in pairs(p.surface.find_entities_filtered{position=pos,radius=0.3,force=p.force}) do
          local ok,pf=pcall(function() return e.products_finished end)
          seen=seen+1
          if ok and type(pf)=='number' then
            machines=machines+1
            local key=e.unit_number or (e.position.x..','..e.position.y)
            if base[key]==nil or pf<base[key] then base[key]=pf end
            local made=pf-base[key]
            crafts=crafts+made
            if c.item then
              local per=0
              local okr,recipe=pcall(function() return e.get_recipe() or (e.type=='furnace' and e.previous_recipe) end)
              if okr and recipe and recipe.name then recipe=prototypes.recipe[recipe.name] or recipe end
              for _,prod in ipairs(okr and recipe and recipe.products or {}) do
                if prod.name==c.item then per=per+(prod.amount or ((prod.amount_min or 0)+(prod.amount_max or 0))/2)*(prod.probability or 1) end
              end
              items=items+made*per
            end
          end
        end
      end
      local n=c.item and math.floor(items+0.5) or crafts
      local what=c.item and string.format('made %d %s (%d crafts)',n,c.item,crafts) or string.format('made %d crafts',crafts)
      local saw=string.format('%s in %d machine%s since the wait began (at least %d)%s',what,machines,machines==1 and '' or 's',c.at_least,
        seen>machines and string.format('; %d other entities on the tiles have no products counter',seen-machines) or '')
      if machines==0 then saw='no machine with a products counter on the given tiles' end
      return machines>0 and n>=c.at_least,saw,estimate and {value=n,scope='produced:'..table.concat(scope,':')} or nil
    end,
    -- A silo's rocket built and ready to launch (the GUI's rocket state).
    rocket_ready=function(p,c,estimate)
      local e=silo_at(p,c)
      local line,ready=silo_line(e)
      local state=rocket_state(e)
      return ready,line,estimate and {entity=e,required=e.prototype.rocket_parts_required,
        parts=(ready or ROCKET_UP[state]) and e.prototype.rocket_parts_required or e.rocket_parts} or nil
    end,
    -- The rocket being built has at least at_least parts (Sonnet, shift14 22:50: a wait on the build's progress). A
    -- built rocket (rising into place or ready) has all of its parts; while one launches, the count is the next one's.
    rocket_parts=function(p,c,estimate)
      local e=silo_at(p,c)
      local state,ready=rocket_state(e)
      local required=e.prototype.rocket_parts_required
      local n=(ready or ROCKET_UP[state]) and required or e.rocket_parts
      local line=silo_line(e)
      -- without at_least: every part of the rocket (A1, Sonnet 22:50)
      local want=c.at_least or required
      return n>=want,string.format('rocket parts %d/%d (at least %d); %s',n,required,want,line),
        estimate and {entity=e,parts=n,required=required} or nil
    end,
    crafting_done=function(p)
      local n=p.crafting_queue_size; return n==0,n..' crafts queued'
    end,
    -- (d18 batch39 A3, Luna 20:25: railgun-damage-1 finished a level and the wait read "not researched" until its timeout;
    -- on world n it read researched false, level 3, max_level 4294967295) a technology with levels: level is the one
    -- researching next, so level N is researched once level reads past N. Met when it rises past the level it read when
    -- the wait began, or past `level: N` when given; researched (every level done) is met too.
    researched=function(p,c,_,record)
      local t=p.force.technologies[c.technology]
      local max=try(function() return t.prototype.max_level end) or 1
      local lv=try(function() return t.level end) or 1
      if not (max>1 or c.level) then return t.researched,c.technology..(t.researched and ' researched' or ' not researched') end
      local holder=record or seen_by(c)
      holder.tech_start=holder.tech_start or lv
      local want=c.level or holder.tech_start
      local met=t.researched or lv>want
      local infinite=max>=4294967295
      return met,string.format('%s level %d%s: %s (levels to %d researched%s)',c.technology,want,c.level and '' or ' (its level when the wait began)',
        met and 'researched' or 'not researched yet',t.researched and lv or lv-1,t.researched and ', every level' or string.format(', level %d next%s',lv,infinite and ', infinite' or string.format(' of %d',max)))
    end,
    -- Our ghosts (entities and tiles) waiting to be built. (d20 batch55 P5, Sol #1400) with platform: on that platform of
    -- ours (every ghost, or those in area, platform coordinates), a remote lane wait and guard too.
    ghosts_waiting=function(p,c)
      if c.platform then
        local pl
        for _,each in pairs(p.force.platforms) do if each.valid and each.name==c.platform then pl=each; break end end
        assert(pl and pl.surface,'no platform of ours named '..tostring(c.platform)..' with a surface')
        local n=0
        local boxes=M.areas_of(c.area)
        if #boxes==0 then n=pl.surface.count_entities_filtered{type={'entity-ghost','tile-ghost'},force=p.force}
        else for _,ar in ipairs(boxes) do n=n+pl.surface.count_entities_filtered{area=ar,type={'entity-ghost','tile-ghost'},force=p.force} end end
        return n>=(c.at_least or 1),string.format('platform %s: %d ghost%s%s',c.platform,n,n==1 and '' or 's',#boxes>0 and ' in the area' or '')
      end
      local centre,radius=area(p,c)
      local n=#p.surface.find_entities_filtered{position=centre,radius=radius,type={'entity-ghost','tile-ghost'},force=p.force}
      return n>=(c.at_least or 1),n..' ghosts'
    end,
    -- (d20 batch55 P5, Sol #1400: Edge5 lost a railgun turret in one shot while every other turret was fed, so no
    -- ammo_below guard fired) our entities on a platform destroyed since the wait or guard began (since_tick, default
    -- its first check, kept on the wait or the condition): met at at_least (default 1), of names when given; saw names
    -- each one (where, by what, when), as the game's destroyed alerts do.
    platform_loss=function(p,c,estimate,record)
      local pl
      for _,each in pairs(p.force.platforms) do if each.valid and each.name==c.platform then pl=each; break end end
      assert(pl and pl.surface,'no platform of ours named '..tostring(c.platform)..' with a surface')
      local holder=record or c
      holder.loss_since=holder.loss_since or c.since_tick or game.tick
      local names
      if c.names then names={}; for _,n in ipairs(c.names) do names[n]=true end end
      local rows,n={},0
      if api.losses_since then rows,n=api.losses_since(p.force.name,pl.surface.name,holder.loss_since,names,4) end
      local want=c.at_least or 1
      if n==0 then return false,string.format('platform %s: nothing of ours%s lost since tick %d',c.platform,names and ' of those names' or '',holder.loss_since) end
      local parts={}
      for _,r in ipairs(rows) do
        parts[#parts+1]=string.format('%s (%g,%g)%s %ds ago',r.n,r.x,r.y,r.c and ' by '..r.c or '',math.floor((game.tick-r.t)/60))
      end
      return n>=want,string.format('platform %s: %d of ours lost since tick %d%s: %s%s',c.platform,n,holder.loss_since,
        n<want and string.format(' (met at %d)',want) or '',table.concat(parts,', '),n>#rows and string.format(', +%d more',n-#rows) or '')
    end,
    -- A platform's foundation built (Astra, d15 06:23: ship conversions ran in the body queue with an outside tile
    -- checker): no tile ghost left on the named platform; with entities=true no entity ghost either.
    platform_built=function(p,c)
      local pl
      for _,each in pairs(p.force.platforms) do if each.valid and each.name==c.platform then pl=each; break end end
      assert(pl,'no platform of ours named '..tostring(c.platform))
      local surface=pl.surface
      assert(surface,'platform '..c.platform..' has no surface yet')
      -- A subset (d17 batch12 C5, Sol: one finished module gating its commissioning among hundreds of other ghosts):
      -- the entity ghosts at positions and in area, the tile ghosts in tiles, as platform_plan ready reads them.
      if c.positions or c.area or c.tiles then
        local ents,tiles=0,0
        for _,q in ipairs(c.positions or {}) do
          local pos=api.position(q)
          ents=ents+surface.count_entities_filtered{position=pos,radius=0.5,type='entity-ghost',force=p.force}
        end
        for _,ar in ipairs(M.areas_of(c.area)) do ents=ents+surface.count_entities_filtered{area=ar,type='entity-ghost',force=p.force} end
        for _,ar in ipairs(M.areas_of(c.tiles)) do tiles=tiles+surface.count_entities_filtered{area=ar,type='tile-ghost',force=p.force} end
        return ents==0 and tiles==0,string.format('platform %s, the part asked: %d entity ghost%s, %d tile ghost%s left',c.platform,ents,ents==1 and '' or 's',tiles,tiles==1 and '' or 's')
      end
      local tiles=surface.count_entities_filtered{type='tile-ghost',force=p.force}
      local ents=c.entities and surface.count_entities_filtered{type='entity-ghost',force=p.force} or nil
      local met=tiles==0 and (ents==nil or ents==0)
      return met,string.format('platform %s: %d tile ghost%s left%s',c.platform,tiles,tiles==1 and '' or 's',
        ents and string.format(', %d entity ghost%s',ents,ents==1 and '' or 's') or '')
    end,
    -- Our buildings under a health fraction (default: any damage), the nearest named.
    damaged=function(p,c)
      local centre,radius=area(p,c)
      local below=c.fraction or 1
      local n,near,best=0,nil,nil
      for _,e in pairs(p.surface.find_entities_filtered{position=centre,radius=radius,force=p.force}) do
        if e.valid and e.type~='character' and e.type~='entity-ghost' and e.type~='tile-ghost' then
          local ok,r=pcall(function() return e.get_health_ratio() end)
          if ok and r and r<below then
            n=n+1
            local d=(e.position.x-centre.x)^2+(e.position.y-centre.y)^2
            if not best or d<best then best,near=d,e end
          end
        end
      end
      return n>0,n..' damaged'..(near and string.format(' (nearest %s at %d,%d)',near.name,math.floor(near.position.x),math.floor(near.position.y)) or '')
    end,
    -- A platform of ours stopped at a space location (Gemini, shift10: rocket launches wait on a platform's
    -- arrival): at `location` when given (a planet), else at any stop. As the platform list shows it: a platform is
    -- at a location while it is stopped there and on a route between two while it flies (2.0.77: space_location
    -- clears within 4 ticks of leaving).
    platform_arrived=function(p,c,estimate)
      local pl
      for _,each in pairs(p.force.platforms) do if each.valid and each.name==c.platform then pl=each end end
      if not pl then error('no platform of ours named '..tostring(c.platform),0) end
      -- freight.lua's rule, the platforms row's too (Luna, shift12 12:47: a wait met while the row showed the platform
      -- in flight): stopped at a location and not on its path; a leg in the way it is flown.
      local w=api.platform_where and api.platform_where(pl)
      if w then return w.stopped==true and (c.location==nil or w.at==c.location),c.platform..' '..w.text,
        estimate and {leg=w.leg,paused=pl.paused,platform=pl} or nil end
      local loc=pl.space_location and pl.space_location.name
      local conn=pl.space_connection
      local where=loc and ('at '..loc) or conn and string.format('flying %s->%s %d%%',conn.from.name,conn.to.name,math.floor((pl.distance or 0)*100+0.5)) or 'nowhere'
      return loc~=nil and (c.location==nil or loc==c.location),c.platform..' '..where
    end,
    -- Its departure (Gemini, 16:50): met while it is not stopped at `location` (a planet), else at no stop (flying, or
    -- still at a location but on its path). The same rule as platform_arrived and the platforms row.
    -- The next departure (Grok 07:51: in flight it was met at once, an earlier departure counting and the location left
    -- out): met once the platform, seen stopped at location (any stop without one) since the wait began, is not.
    platform_left=function(p,c,_,record)
      local pl
      for _,each in pairs(p.force.platforms) do if each.valid and each.name==c.platform then pl=each end end
      if not pl then error('no platform of ours named '..tostring(c.platform),0) end
      local w=api.platform_where and api.platform_where(pl)
      if not w then
        local loc=pl.space_location and pl.space_location.name
        w={at=loc,stopped=loc~=nil,text=loc and ('at '..loc) or 'not at a stop'}
      end
      local holder=record or seen_by(c)
      local there=w.stopped==true and (c.location==nil or w.at==c.location)
      holder.platform_began=holder.platform_began or game.tick
      if there then holder.platform_was_there=w.at; return false,c.platform..' '..w.text..' (met when it leaves)' end
      if holder.platform_was_there then return true,c.platform..' left '..holder.platform_was_there..'; now '..w.text end
      -- (d19 batch48 2) a departure made by platform_schedule in the second before this wait began (the same tick, or
      -- the previous step of the same queue) counts
      local d=w.departed
      if d and d.tick>=holder.platform_began-DEPART_GRACE and (c.location==nil or d.from==c.location) then
        return true,string.format('%s left %s at tick %d (platform_schedule by %s, %d ticks before this wait began); now %s',c.platform,d.from,d.tick,
          tostring(d.by),math.max(0,holder.platform_began-d.tick),w.text)
      end
      return false,c.platform..' '..w.text..'; met when it stops '..(c.location and 'at '..c.location or 'somewhere')..' and leaves again (a departure before this wait does not count)'
    end,
    -- spoil_within {position, seconds, item?} (batch27 A6, Grok, dozens of times an hour: the copper cultivator dies when
    -- copper ore stays over 300 longer than the bacteria last, ~40 s, and only inspect showed it): the machine at
    -- position, its input's first stack (of item, or any) that spoils or hatches, met when that is within seconds.
    spoil_within=function(p,c)
      local surf=c.surface and game.get_surface(c.surface) or p.surface
      local pos=api.position(c.position)
      local e
      for _,x in pairs(surf.find_entities_filtered{position=pos,radius=0.6,force=p.force}) do
        if x.valid and (x.type=='assembling-machine' or x.type=='furnace') then e=x; break end
      end
      if not e then return false,string.format('no assembler or furnace of ours at (%g,%g)',pos.x,pos.y) end
      local ok,inv=pcall(function() return e.get_inventory(e.type=='furnace' and defines.inventory.furnace_source or defines.inventory.assembling_machine_input) end)
      local best,item
      for i=1,ok and inv and #inv or 0 do
        local st=inv[i]
        if st.valid_for_read and (not c.item or st.name==c.item) then
          local okt,tick=pcall(function() return st.spoil_tick end)
          if okt and type(tick)=='number' and tick>0 and (not best or tick<best) then best,item=tick,st.name end
        end
      end
      local where=string.format('%s (%g,%g)',e.name,e.position.x,e.position.y)
      if not best then return false,string.format('%s: no %s in its input spoils',where,c.item or 'item') end
      local left=(best-game.tick)/60
      local hatch=pcall(function() return prototypes.item[item].spoil_to_trigger_result end) and prototypes.item[item].spoil_to_trigger_result
      return left<c.seconds,string.format('%s: its input\'s first %s %s in %ds',where,item,hatch and 'hatches' or 'spoils',math.max(0,math.floor(left+0.5)))
    end,
    -- pod_landed {platform, item?, at_least?} (batch28 B1, Luna: polled silo, shipment and where_is for Spindle's packs
    -- and two fuel pods): pods sent down from the platform that landed since the wait began (freight's receipts: received
    -- by a landing pad, or landed as a cargo pod container); with item, how many of it they carried; met at at_least
    -- (default 1: one pod, or one of the item).
    pod_landed=function(p,c,estimate,record)
      assert(record,'pod_landed counts from the start of a wait: a wait_until step or a direct wait_until')
      local pl=M.platform_named(p,c.platform)
      -- (d17 batch33 A4, Astra 09:50: Petrel's freight queue stopped at each drop for a hand check) one drop: drop_id, or
      -- last_drop (the platform's latest drop when the wait began); met once it is no longer descending
      if c.drop_id~=nil or c.last_drop then
        record.drop_id=record.drop_id or c.drop_id or (api.last_drop and api.last_drop(c.platform))
        assert(record.drop_id,'no drop from '..c.platform..' is recorded (the last 20 drops are kept)')
        local r=api.drop_record and api.drop_record(record.drop_id)
        assert(r,'drop #'..tostring(record.drop_id)..' is no longer kept (the last 20 drops are)')
        if r.state=='lost' then error('drop #'..r.id..' is lost: '..tostring(r.note),0) end
        local landed=r.state~='descending'
        return landed,string.format('drop #%d from %s %s',r.id,tostring(r.platform),landed and ('landed'..(r.into and ' in '..r.into or '')
          ..(r.at and string.format(' at (%g,%g)',r.at.x,r.at.y) or '')..(r.surface and ' on '..r.surface or '')) or 'still descending'),
          estimate and {value=landed and 1 or 0,scope='drop:'..r.id} or nil
      end
      record.pod_since=record.pod_since or game.tick
      local list=api.receipts and api.receipts(pl,record.pod_since) or {}
      local pods,items,last=0,0,nil
      for _,r in ipairs(list) do
        if r.kind~='gone' and r.kind~='lost' then
          local n=c.item and ((r.cargo or {})[c.item] or 0) or 1
          if n>0 then pods=pods+1; items=items+(c.item and n or 0); last=r end
        end
      end
      local want=c.at_least or 1
      local have=c.item and items or pods
      return have>=want,string.format('%d pod%s from %s landed since the wait began%s%s',pods,pods==1 and '' or 's',c.platform,
        c.item and string.format(' with %d %s',items,c.item) or '',last and string.format(' (the last %s)',tostring(last.where)) or ''),
        estimate and {value=have,scope='pods:'..c.platform..':'..tostring(c.item)} or nil
    end,
    -- Our burner machines (furnaces, drills, boilers, burner inserters...) holding under count fuel items.
    fuel_below=function(p,c)
      local centre,radius=area(p,c)
      local n,near,best=0,nil,nil
      for _,e in pairs(selected(p,c,BURNERS)) do
        local inv=e.valid and e.burner and e.get_fuel_inventory()
        if inv and inv.get_item_count()<c.count then
          n=n+1
          local d=(e.position.x-centre.x)^2+(e.position.y-centre.y)^2
          if not best or d<best then best,near=d,e end
        end
      end
      return n>0,n..' burners below '..c.count..' fuel'..(near and string.format(' (nearest %s at %d,%d)',near.name,math.floor(near.position.x),math.floor(near.position.y)) or '')
    end,
  }
  -- A platform of ours by name, and a signal by name (an item, a fluid or a virtual signal such as signal-A).
  function M.platform_named(p,name)
    for _,each in pairs(p.force.platforms) do if each.valid and each.name==name then return each end end
    error('no platform of ours named '..tostring(name),0)
  end
  function M.signal_of(name)
    if prototypes.item[name] then return {type='item',name=name} end
    if prototypes.fluid[name] then return {type='fluid',name=name} end
    if prototypes.virtual_signal and prototypes.virtual_signal[name] then return {type='virtual',name=name} end
    error('unknown signal '..tostring(name)..' (an item, a fluid, or a virtual signal such as signal-A)',0)
  end
  local NAMES='no_enemy_structures|no_enemies|units_clear|turrets_idle|ammo_below|health_below|health_above|item_count|fluid_count|circuit_signal|rocket_ready|rocket_parts|crafting_done|researched|ghosts_waiting|damaged|fuel_below|spoil_within|pod_landed|platform_arrived|platform_left|produced|platform_built|platform_ready|platform_loss|all'
  -- Other names for a condition (A1, Sonnet 22:50: silo_parts refused as an invalid until): the name it goes by.
  M.ALIASES={silo_parts='rocket_parts'}
  -- Every member holds (B2, Grok 22:50: a launch waiting for both its rocket and its platform): {until=all,
  -- conditions=[...]} met when each is; saw joins theirs. Members are plain conditions.
  checks.platform_ready=checks.platform_built
  checks['all']=function(p,c,estimate,record)
    local all,saws=true,{}
    for i,m in ipairs(c.conditions) do
      local met,saw=checks[m['until']](p,m,nil,record)
      if not met then all=false end
      saws[i]=(met and 'met: ' or 'not yet: ')..tostring(saw)
    end
    return all,table.concat(saws,'; ')
  end
  -- Argument checks run when a plan is submitted, not when it first fires.
  function M.validate(c)
    if type(c)=='table' and M.ALIASES[c['until']] then c['until']=M.ALIASES[c['until']] end
    -- queue_done (A1, Sonnet 22:50) is a sleep's: fh sleep/fh wait --until queue_done; in a queue the next step is that.
    if type(c)=='table' and c['until']=='queue_done' then
      error('until queue_done is a sleep\'s (fh sleep SECONDS --until queue_done, fh wait --until queue_done, sleep {seconds, condition: {until: "queue_done"}}): it wakes when your queue finishes or stalls; in a queue the next step runs when this one ends',0)
    end
    assert(type(c)=='table' and checks[c['until']],'until must be one of '..NAMES..'; a sleep also takes queue_done')
    if c['until']=='all' then
      assert(type(c.conditions)=='table' and #c.conditions>=1 and #c.conditions<=8,'until=all takes conditions: 1..8 wait_until conditions, met when every one holds')
      for _,m in ipairs(c.conditions) do
        assert(type(m)=='table' and m['until']~='all' and m['until']~='any','until=all takes plain conditions')
        M.validate(m)
      end
      return c
    end
    if c.position~=nil then api.position(c.position) end
    if c.radius~=nil then number(c.radius,1,256,'radius') end
    local kind=c['until']
    if c.area~=nil and (kind=='platform_built' or kind=='platform_ready') then
      -- (C5: an area or a list of them on the platform, checked below)
    elseif c.area~=nil and kind=='ghosts_waiting' and c.platform~=nil then
      M.areas_of(c.area)
    elseif c.area~=nil then
      assert(kind=='ammo_below' or kind=='fuel_below','area applies to ammo_below or fuel_below (and platform_built, platform_ready, ghosts_waiting with platform)')
      assert(c.radius==nil and c.position==nil,'area excludes position and radius')
      local l,r=api.position(c.area.left_top or c.area[1]),api.position(c.area.right_bottom or c.area[2])
      assert(r.x>l.x and r.y>l.y and r.x-l.x<=256 and r.y-l.y<=256,'area must be nonempty and at most 256x256')
    end
    if kind=='ammo_below' then number(c.count,1,1000,'count') end
    if kind=='ammo_below' and c.platform~=nil then
      assert(type(c.platform)=='string' and #c.platform>0,'ammo_below platform takes a platform name')
      assert(c.position==nil and c.radius==nil,'ammo_below on a platform: every ammo turret aboard, or positions or area in platform coordinates (no position or radius)')
      assert(c.positions==nil or c.area==nil,'ammo_below on a platform: positions or area, not both')
    end
    if kind=='ammo_below' and c.positions~=nil then
      assert(c.platform~=nil,'ammo_below positions applies with platform (turrets on a platform, platform coordinates)')
      assert(type(c.positions)=='table' and #c.positions>=1 and #c.positions<=64,'ammo_below positions takes 1..64 {x,y} (turrets)')
      for _,pos in ipairs(c.positions) do api.position(pos) end
    end
    if kind=='health_below' or kind=='health_above' then number(c.fraction,0,1,'fraction') end
    -- (batch33 A2) quality: item_count reads it; no other condition does, and one given there is refused
    if c.quality~=nil then
      assert(kind=='item_count','quality applies to item_count only (no other condition counts by quality)')
      assert(c.quality=='any' or (type(c.quality)=='string' and prototypes.quality and prototypes.quality[c.quality]),
        'item_count quality is a quality name (normal, uncommon, rare, epic, legendary) or "any" (every quality summed)')
    end
    if kind=='item_count' then
      assert(type(c.item)=='string' and prototypes.item[c.item],'item_count requires a known item')
      if c.platform~=nil then
        assert(type(c.platform)=='string' and #c.platform>0,'item_count platform requires a platform name')
        assert(c.position==nil and c.positions==nil and c.surface==nil,'item_count platform counts the hub; no position, positions or surface')
      end
      if c.surface~=nil then
        assert(type(c.surface)=='string' and game.get_surface(c.surface),'item_count surface must be a surface name (nauvis, vulcanus, ...)')
        assert(not game.get_surface(c.surface).platform,'item_count surface is a planet; a platform\'s hub: platform=NAME')
      end
      assert(c.at_least~=nil or c.below~=nil,'item_count requires at_least or below')
      if c.at_least~=nil then number(c.at_least,0,1e9,'at_least') end
      if c.below~=nil then number(c.below,1,1e9,'below') end
      if c.network~=nil then
        api.position(c.network)
        assert(c.position==nil and c.positions==nil and c.platform==nil,'item_count network counts that logistic network; no position, positions or platform')
      end
      if c.positions~=nil then
        assert(type(c.positions)=='table' and #c.positions>=1 and #c.positions<=64,'item_count positions takes 1..64 {x,y} (chests)')
        for _,pos in ipairs(c.positions) do api.position(pos) end
      end
    end
    if kind=='fluid_count' or kind=='circuit_signal' then
      assert(type(c.platform)=='string' and #c.platform>0,kind..' requires platform (a platform name)')
      if kind=='fluid_count' then assert(type(c.fluid)=='string' and prototypes.fluid[c.fluid],'fluid_count requires fluid (a fluid name: thruster-fuel, thruster-oxidizer, water, ...)')
      else assert(type(c.signal)=='string','circuit_signal requires signal (an item, fluid or virtual signal name)'); M.signal_of(c.signal) end
      assert(c.at_least~=nil or c.below~=nil,kind..' requires at_least or below')
      if c.at_least~=nil then number(c.at_least,-2147483648,2147483647,'at_least') end
      if c.below~=nil then number(c.below,-2147483648,2147483647,'below') end
    end
    if kind=='produced' then
      assert(c.item==nil or (type(c.item)=='string' and prototypes.item[c.item]),'produced item must be a known item')
      if c.platform~=nil then
        assert(type(c.platform)=='string' and #c.platform>0,'produced platform takes a platform name')
        assert(c.item~=nil and c.position==nil and c.positions==nil,'produced on a platform counts an item (item=...) from its production statistics: no position or positions')
      else
        assert(c.position~=nil or c.positions~=nil,'produced requires position or positions (the machines, 1..64 {x,y}), or platform and item')
      end
      if c.positions~=nil then
        assert(type(c.positions)=='table' and #c.positions>=1 and #c.positions<=64,'produced positions takes 1..64 {x,y} (machines)')
        for _,pos in ipairs(c.positions) do api.position(pos) end
      end
      assert(c.at_least~=nil,'produced requires at_least (items made since the wait began; crafts without item)')
      number(c.at_least,1,1e9,'at_least')
    end
    if kind=='platform_built' or kind=='platform_ready' then
      assert(type(c.platform)=='string' and #c.platform>0,kind..' requires platform (a platform name)')
      assert(c.entities==nil or type(c.entities)=='boolean',kind..' entities must be true or false')
      if c.positions~=nil then
        assert(type(c.positions)=='table' and #c.positions>=1 and #c.positions<=512,kind..' positions takes 1..512 {x,y} (entity ghosts)')
        for _,pos in ipairs(c.positions) do api.position(pos) end
      end
      M.areas_of(c.area); M.areas_of(c.tiles)
    end
    if kind=='researched' then assert(type(c.technology)=='string','researched requires technology'); assert(c.level==nil or (type(c.level)=='number' and c.level>=1 and c.level==math.floor(c.level)),'level is a whole number from 1: the level of the technology the wait waits for') end
    if kind=='rocket_ready' then assert(c.position~=nil,'rocket_ready requires position (a rocket silo\'s, any tile of it)') end
    if (kind=='rocket_ready' or kind=='rocket_parts') and c.surface~=nil then
      assert(type(c.surface)=='string' and game.get_surface(c.surface),kind..' surface must be a surface name (nauvis, vulcanus, ...)')
      assert(not game.get_surface(c.surface).platform,kind..' surface is a planet (a rocket silo stands on one)')
    end
    if kind=='rocket_parts' then
      assert(c.position~=nil,'rocket_parts requires position (a rocket silo\'s, any tile of it)')
      if c.at_least~=nil then number(c.at_least,1,1000,'at_least') end
    end
    if kind=='ghosts_waiting' and c.at_least~=nil then number(c.at_least,1,100000,'at_least') end
    if kind=='ghosts_waiting' and c.platform~=nil then
      assert(type(c.platform)=='string' and #c.platform>0,'ghosts_waiting platform takes a platform name')
      assert(c.position==nil and c.radius==nil,'ghosts_waiting on a platform: every ghost aboard, or those in area (platform coordinates); no position or radius')
    end
    if kind=='platform_loss' then
      assert(type(c.platform)=='string' and #c.platform>0,'platform_loss requires platform (a platform of ours by name)')
      if c.at_least~=nil then number(c.at_least,1,1000,'at_least') end
      assert(c.names==nil or (type(c.names)=='table' and #c.names>=1 and #c.names<=16),'platform_loss names: 1..16 entity names')
      for _,n in ipairs(c.names or {}) do assert(type(n)=='string','platform_loss names are entity names') end
      assert(c.since_tick==nil or (type(c.since_tick)=='number' and c.since_tick>=0 and c.since_tick<=game.tick),'platform_loss since_tick is a game tick up to now')
    end
    if kind=='damaged' and c.fraction~=nil then number(c.fraction,0.01,1,'fraction') end
    if kind=='fuel_below' then number(c.count,1,1000,'count') end
    if kind=='pod_landed' then
      assert(type(c.platform)=='string' and #c.platform>0,'pod_landed requires platform (the platform the pods come down from)')
      assert(c.drop_id==nil or (type(c.drop_id)=='number' and c.drop_id==math.floor(c.drop_id) and c.drop_id>=1),'drop_id is a drop number (drop and drops give it)')
      assert(c.last_drop==nil or type(c.last_drop)=='boolean','last_drop must be true or false')
      assert(not (c.drop_id and c.last_drop),'drop_id or last_drop, not both')
      assert(not ((c.drop_id or c.last_drop) and (c.item or c.at_least)),'drop_id and last_drop wait for one drop: no item or at_least')
      assert(c.item==nil or (type(c.item)=='string' and prototypes.item[c.item]),'item must be a known item')
      if c.at_least~=nil then number(c.at_least,1,1e9,'at_least') end
    end
    if kind=='spoil_within' then
      assert(c.position~=nil,'spoil_within requires position (an assembler, furnace or biochamber)')
      number(c.seconds,1,3600,'seconds')
      assert(c.item==nil or (type(c.item)=='string' and prototypes.item[c.item]),'item must be a known item')
      assert(c.surface==nil or (type(c.surface)=='string' and game.get_surface(c.surface)),'surface must be a surface name')
    end
    if kind=='platform_arrived' or kind=='platform_left' then
      assert(type(c.platform)=='string' and #c.platform>0,kind..' requires platform (a platform name)')
      assert(c.location==nil or (type(c.location)=='string' and prototypes.space_location[c.location]),'location must be a space location (a planet name)')
    end
    return c
  end
  function M.check(p,c,estimate,record)
    if M.ALIASES[c['until']] then c['until']=M.ALIASES[c['until']] end
    if c['until']=='researched' then assert(p.force.technologies[c.technology],'unknown technology') end
    return checks[c['until']](p,c,estimate,record)
  end
  M.names=NAMES
  return M
end
