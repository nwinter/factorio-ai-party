-- World predicates for plan waits and guards. Each reads only what the player
-- could see: enemy structures on the chart, units in visible chunks, our own
-- turrets, ghosts, buildings and burners, the character's health and inventory.
local qflow=require('qflow')   -- (d24 batch152 PX1) statistics read at every quality
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
  -- (d20 batch62 X3, Astra #1540: produced on Nauvis from Aquilo) surface: a planet by remote view, else the character's
  -- own; our entities there count in chunks our force has charted, as their GUIs open by remote view.
  local function surface_of(p,c)
    if c.surface==nil then return p.surface end
    local s=game.get_surface(c.surface)
    if not s then error('no surface named '..tostring(c.surface),0) end
    return s
  end
  local function charted(p,s,pos) return s==p.surface or p.force.is_chunk_charted(s,{math.floor(pos.x/32),math.floor(pos.y/32)}) end
  -- A crafting machine's recipe name: set (assemblers), or a furnace's current or last one; nil when it has none.
  local function recipe_of(e)
    local ok,r=pcall(function() return e.get_recipe() or (e.type=='furnace' and e.previous_recipe) or nil end)
    if not ok or not r then return nil end
    local n=r.name
    if type(n)~='string' then n=try(function() return n.name end) end
    if type(n)~='string' then return nil end
    return n,(prototypes.recipe and prototypes.recipe[n]) or r
  end
  local function uncharted(s,pos,what) error(string.format('(%g,%g) on %s is not charted: no remote view of %s there',pos.x,pos.y,s.name,what),0) end
  local function selected(p,c,types)
    local centre,radius=area(p,c)
    local s=surface_of(p,c)
    local filter={position=not c.area and centre or nil,radius=not c.area and radius or nil,area=c.area,type=types,force=p.force,limit=1025}
    local list=s.find_entities_filtered(filter)
    assert(#list<=1024,'condition area exceeds 1024 entities')
    if s~=p.surface then
      local out={}
      for _,e in ipairs(list) do if e.valid and charted(p,s,e.position) then out[#out+1]=e end end
      list=out
    end
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
  -- fluid_count's holders by kind (module level: built once, not at each check; d22 batch110 BT1)
  local FLUID_KIND={['storage-tank']='tanks',pipe='pipes',['pipe-to-ground']='pipes',pump='pipes',thruster='thrusters',
    ['assembling-machine']='machines',furnace='machines',['mining-drill']='machines',['fusion-reactor']='fusion',
    ['fusion-generator']='fusion',boiler='power',generator='power'}
  local FLUID_TYPES={'storage-tank','pipe','pipe-to-ground','pump','thruster','assembling-machine','furnace','mining-drill',
    'fusion-reactor','fusion-generator','boiler','generator'}
  local FLUID_ORDER={'tanks','pipes','thrusters','machines','fusion','power'}
  local FLUID_SAID={fusion='fusion reactors and generators',power='boilers and generators'}
  -- (d22 batch110 BT1: on a copy of world n, Asterion's guards read two fluids every 10 ticks, finding each of its
  -- thousands of pipes, tanks and machines anew: 4 MB of garbage a second) a platform's holders found once and kept
  -- while their count (count_entities_filtered, no entity objects made) is the same and every one kept is still valid;
  -- else found again. The same entities as a find at each check. Module state: rebuilt after a load.
  local fluid_cache={}
  local FLUID_FIND={type=FLUID_TYPES,force=nil,limit=4096}
  local function fluid_holders(surface,force)
    FLUID_FIND.force=force
    local key=surface.index
    local okn,n=pcall(surface.count_entities_filtered,FLUID_FIND)
    if not (okn and key) then return surface.find_entities_filtered(FLUID_FIND) end
    local kept=fluid_cache[key]
    if kept and kept.n==n and kept.force==force.index then
      local all=true
      for i=1,#kept.list do if not kept.list[i].valid then all=false; break end end
      if all then return kept.list,kept.read end
    end
    local list=surface.find_entities_filtered(FLUID_FIND)
    -- each one's get_fluid_count, read once with the list (a method read makes a new function each time)
    local read={}
    for i,e in ipairs(list) do read[i]=e.get_fluid_count end
    fluid_cache[key]={n=#list,list=list,read=read,force=force.index}
    return list,read
  end
  -- (d22 batch110 BT1: on a copy of world n the platform guards in queue lanes, checked every 10 ticks, found a
  -- platform's every ammo turret (18 KB a check) and accumulator (8 KB) anew) kept as fluid_count's holders are: the
  -- list, and each turret's ammo inventory and its get_item_count (a method read makes a new function), while the
  -- count (count_entities_filtered: no entity objects) is the same and every one kept is valid; positions: each kept
  -- turret valid (a turret does not move; another cannot stand on its tile). The same entities as a find at each
  -- check; what each holds is read live. Module state: rebuilt after a load.
  local TURRET_FIND={type='ammo-turret',force=nil,area=nil,limit=1025}
  local turret_kept,turret_kept_by={},setmetatable({},{__mode='k'})  -- by surface index (every turret); by c.area or c.positions
  local function kept_valid(kept)
    for i=1,#kept.list do
      local e,inv=kept.list[i],kept.inv[i]
      if not e.valid or (inv and not inv.valid) then return false end
    end
    return true
  end
  local function platform_turrets(c,s,force)
    local key,fi=s.index,force.index
    local ref=c.positions or c.area
    local kept
    if ref then kept=turret_kept_by[ref] else kept=key and turret_kept[key] end
    if kept and key and kept.s==key and kept.force==fi then
      local n=kept.n
      if not c.positions then
        TURRET_FIND.force,TURRET_FIND.area=force,c.area
        local okn,m=pcall(s.count_entities_filtered,TURRET_FIND)
        TURRET_FIND.area=nil
        n=okn and m or nil
      end
      if n==kept.n and kept_valid(kept) then return kept.list,kept.inv,kept.cnt end
    end
    local list
    if c.positions then
      list={}
      for _,raw in ipairs(c.positions) do
        local q=api.position(raw)
        local found=s.find_entities_filtered{area={{q.x-0.01,q.y-0.01},{q.x+0.01,q.y+0.01}},type='ammo-turret',force=force,limit=1}
        if not found[1] then error(string.format('no ammo turret of ours at (%g,%g) on %s',q.x,q.y,c.platform),0) end
        list[#list+1]=found[1]
      end
    else
      list=s.find_entities_filtered{area=c.area,type='ammo-turret',force=force,limit=1025}
      assert(#list<=1024,'condition area exceeds 1024 entities')
    end
    -- each one's ammo inventory and get_item_count, read once with the list (ammo() at each check)
    local inv,cnt={},{}
    for i,e in ipairs(list) do
      local v=e.valid and e.type=='ammo-turret' and e.get_inventory(defines.inventory.turret_ammo) or false
      inv[i]=v; cnt[i]=v and v.get_item_count or false
    end
    -- (a surface that cannot count has its turrets found at each check, as before: the count kept differs)
    if key then
      kept={s=key,force=fi,n=#list,list=list,inv=inv,cnt=cnt}
      if ref then turret_kept_by[ref]=kept else turret_kept[key]=kept end
    end
    return list,inv,cnt
  end
  local ACC_FIND={type='accumulator',force=nil}
  local acc_kept={}
  local function platform_accumulators(s,force)
    ACC_FIND.force=force
    local key=s.index
    local okn,n=pcall(s.count_entities_filtered,ACC_FIND)
    if not (okn and key) then return s.find_entities_filtered(ACC_FIND) end
    local kept=acc_kept[key]
    if kept and kept.n==n and kept.force==force.index then
      local all=true
      for i=1,#kept.list do if not kept.list[i].valid then all=false; break end end
      if all then return kept.list end
    end
    local list=s.find_entities_filtered(ACC_FIND)
    acc_kept[key]={n=#list,list=list,force=force.index}
    return list
  end
  -- what a turret's ammo slots hold, as its GUI shows them (no closure a check)
  local function held_text(inv)
    local t={}
    for _,r in ipairs(inv.get_contents()) do t[#t+1]=r.count..' '..r.name end
    return table.concat(t,', ')
  end
  -- names given (c.names, c.entity_names) as a set, made once per list
  local name_sets=setmetatable({},{__mode='k'})
  local function name_set(list)
    if not list then return nil end
    local set=name_sets[list]
    if not set then set={}; for _,n in ipairs(list) do set[n]=true end; name_sets[list]=set end
    return set
  end
  local function ring_row(ring,size,s) local x=ring[(s-1)%size+1]; if x and x.s==s then return x end end
  local function tenth(v) return math.floor(v*10+0.5)/10 end
  local function location_name(pl) return pl.space_location and pl.space_location.name end
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
      local list,invs,cnts
      if c.platform then
        local pl=M.platform_named(p,c.platform)
        local s=pl.surface
        if not s then error('platform '..c.platform..' has no surface yet',0) end
        -- (BT1) kept while the same; each one's inventory and get_item_count with it
        list,invs,cnts=platform_turrets(c,s,p.force)
      elseif c.positions then
        -- (X3) surface with positions: those turrets on that planet
        local s=surface_of(p,c)
        list={}
        for _,raw in ipairs(c.positions) do
          local q=api.position(raw)
          if not charted(p,s,q) then uncharted(s,q,'a turret') end
          local found=s.find_entities_filtered{area={{q.x-0.01,q.y-0.01},{q.x+0.01,q.y+0.01}},type='ammo-turret',force=p.force,limit=1}
          if not found[1] then error(string.format('no ammo turret of ours at (%g,%g) on %s',q.x,q.y,s.name),0) end
          list[#list+1]=found[1]
        end
      else list=turrets(p,c) end
      local on=c.platform or (c.surface~=nil and surface_of(p,c).name) or nil
      local low,n,lowest,lowest_k,lowest_i=0,0,nil,nil,nil
      for i,e in ipairs(list) do
        local k
        -- (BT1) a kept turret's count by its kept get_item_count, as ammo() reads it
        if cnts then k=e.valid and (cnts[i] and cnts[i]() or nil) else k=e.valid and ammo(e) end
        if k then
          n=n+1
          if k<c.count then low=low+1 end
          if not lowest or k<lowest_k then lowest,lowest_k,lowest_i=e,k,i end
        end
      end
      local saw=low..' turrets below '..c.count
      if lowest and on then
        local inv=invs and invs[lowest_i] or lowest.get_inventory(defines.inventory.turret_ammo)
        local okh,held=pcall(held_text,inv)
        if not okh then held=nil end
        local pos=lowest.position
        saw=saw..string.format(' (of %d on %s; lowest %s (%g,%g): %s)',n,on,lowest.name,pos.x,pos.y,
          held and held~='' and held or 'no ammo')
      elseif on then saw=saw..' (no ammo turret of ours '..(c.area and 'in that area' or c.platform and 'aboard' or 'within the radius')..' on '..on..')' end
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
    -- (d20 batch62 X3) surface with positions or area: our tanks, pipes and machines there on that planet, by remote view
    -- in chunks our force has charted.
    -- (d22 batch77 AM2, Astra #1769: Asterion's two fusion reactors held 1000 fluoroketone-cold each and the wait read
    -- the pipes alone) fusion reactors and fusion generators, boilers and heat exchangers, steam engines and turbines,
    -- and mining drills too, each kind said.
    fluid_count=function(p,c,estimate)
      local KIND,TYPES=FLUID_KIND,FLUID_TYPES
      local list,on,read
      if c.platform then
        local pl=M.platform_named(p,c.platform)
        list,read=fluid_holders(pl.surface,p.force)
        on=c.platform
      else
        local s=surface_of(p,c)
        list,on={},s.name
        local seen={}
        local function add(e) local key=e.unit_number or e; if e.valid and not seen[key] then seen[key]=true; list[#list+1]=e end end
        if c.positions then
          for _,raw in ipairs(c.positions) do
            local pos=api.position(raw)
            if not charted(p,s,pos) then uncharted(s,pos,'a tank, pipe or machine') end
            local found=s.find_entities_filtered{position=pos,radius=0.3,type=TYPES,force=p.force}
            if not found[1] then error(string.format('no tank, pipe or machine of ours at (%g,%g) on %s',pos.x,pos.y,s.name),0) end
            for _,e in ipairs(found) do add(e) end
          end
        else
          local found=s.find_entities_filtered{area=c.area,type=TYPES,force=p.force,limit=1025}
          assert(#found<=1024,'condition area exceeds 1024 entities')
          for _,e in ipairs(found) do if charted(p,s,e.position) then add(e) end end
        end
      end
      local by,count={},{}
      local total=0
      for i,e in pairs(list) do
        -- (BT1) the method itself under pcall, kept with the list: a closure per entity was most of a check's garbage
        local ok,k=false,nil
        if e.valid~=false then ok,k=pcall(read and read[i] or e.get_fluid_count,c.fluid) end
        if ok and k and k>0 then local kind=KIND[e.type] or 'other'; by[kind]=(by[kind] or 0)+k; count[kind]=(count[kind] or 0)+1; total=total+k end
      end
      local parts={}
      for _,kind in ipairs(FLUID_ORDER) do
        if by[kind] then parts[#parts+1]=string.format('%s %d (%d)',FLUID_SAID[kind] or kind,math.floor(by[kind]+0.5),count[kind]) end
      end
      local met=(c.at_least==nil or total>=c.at_least) and (c.below==nil or total<c.below)
      return met,string.format('%s %d on %s: %s',c.fluid,math.floor(total+0.5),on,#parts>0 and table.concat(parts,', ')
        or (c.platform and 'none in its tanks, pipes, thrusters, machines, fusion reactors or generators' or 'none in our '..#list..' tanks, pipes and machines '..(c.positions and 'there' or 'in the area'))),
        estimate and {value=total,scope='fluid:'..on..':'..c.fluid..(c.platform and '' or ':'..#list)} or nil
    end,
    -- circuit_signal {platform, signal, at_least | below} (A5): the signal on the platform hub's red and green wires
    -- together, as a circuit wait condition reads it. A hub with no red or green wire reads every signal as 0, as the
    -- game's own circuit wait conditions read it (d22 batch118 CA1, Astra: "no signal to read" held a below guard
    -- unmet; measured on a copy of world n: a platform schedule's circuit condition rocket < 4850 on an unwired hub
    -- was met at once and the platform left, rocket > -1 too; on a wired hub with no rocket signal, rocket < 4850 met,
    -- rocket > 4850 not): below N (over 0) is met, at_least N (over 0) is never met while it has none.
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
      local met=(c.at_least==nil or n>=c.at_least) and (c.below==nil or n<c.below)
      return met,#wires>0 and string.format('%s %d on %s\'s hub (%s)',c.signal,n,c.platform,table.concat(wires,' and '))
        or string.format('%s\'s hub has no red or green wire: %s reads 0 there, as the game\'s own circuit conditions read an unwired hub (%s)',
          c.platform,c.signal,met and 'met' or 'never met while it has none'),estimate and {value=n,scope='circuit:'..c.platform..':'..c.signal} or nil
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
        local now=qflow.count(p.force.get_item_production_statistics(pl.surface),c.item,'input')   -- (PX1) every quality
        if base.platform==nil or not base.platform_q then base.platform,base.platform_q=now,true end   -- (PX1) a base kept before every quality was summed is taken again
        local made=now-base.platform
        return made>=c.at_least,string.format('made %d %s on platform %s since the wait began (at least %d; the platform\'s production statistics)',made,c.item,c.platform,c.at_least),
          estimate and {value=made,scope='produced:platform:'..c.platform..':'..c.item} or nil
      end
      -- (d20 batch62 X3, Astra #1540) surface: our machines on that planet by remote view, in chunks our force has
      -- charted. Each machine is kept with its recipe from its first check: one gone from its tile, or one whose recipe
      -- changed, fails the wait with the reason (its count so far would be wrong).
      local s=surface_of(p,c)
      local there=s~=p.surface and ' on '..s.name or ''
      base.machines=base.machines or {}
      local crafts,items,seen,machines=0,0,0,0
      local positions=c.positions or {c.position}
      local scope={tostring(s.index or s.name or '')}
      local counted={}
      for _,raw in ipairs(positions) do
        local pos=api.position(raw)
        scope[#scope+1]=pos.x..','..pos.y
        if not charted(p,s,pos) then uncharted(s,pos,'a machine') end
        for _,e in pairs(s.find_entities_filtered{position=pos,radius=0.3,force=p.force}) do
          local ok,pf=pcall(function() return e.products_finished end)
          seen=seen+1
          local key=e.unit_number or (e.position.x..','..e.position.y)
          if ok and type(pf)=='number' and not counted[key] then
            counted[key]=true
            machines=machines+1
            local rname,recipe=recipe_of(e)
            local was=base.machines[key]
            if not was then
              was={name=e.name,x=e.position.x,y=e.position.y,recipe=rname}
              base.machines[key]=was
            elseif was.recipe~=nil and was.recipe~=rname then
              error(string.format('the %s at (%g,%g)%s changed recipe since the wait began (%s, now %s): its count would mix the two',
                e.name,was.x,was.y,there,tostring(was.recipe or 'none'),tostring(rname or 'none')),0)
            end
            if was.recipe==nil and rname~=nil then was.recipe=rname end
            if base[key]==nil or pf<base[key] then base[key]=pf end
            local made=pf-base[key]
            crafts=crafts+made
            if c.item then
              local per=0
              for _,prod in ipairs(recipe and recipe.products or {}) do
                if prod.name==c.item then per=per+(prod.amount or ((prod.amount_min or 0)+(prod.amount_max or 0))/2)*(prod.probability or 1) end
              end
              items=items+made*per
            end
          end
        end
      end
      for key,was in pairs(base.machines) do
        if not counted[key] then
          error(string.format('the %s at (%g,%g)%s is gone since the wait began (mined, destroyed or replaced): its products are no longer counted',was.name,was.x,was.y,there),0)
        end
      end
      local n=c.item and math.floor(items+0.5) or crafts
      local what=c.item and string.format('made %d %s (%d crafts)',n,c.item,crafts) or string.format('made %d crafts',crafts)
      local saw=string.format('%s in %d machine%s%s since the wait began (at least %d)%s',what,machines,machines==1 and '' or 's',there,c.at_least,
        seen>machines and string.format('; %d other entities on the tiles have no products counter',seen-machines) or '')
      if machines==0 then saw='no machine with a products counter on the given tiles'..there end
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
      local force=p.force  -- (BT1) the force and the surface read once a check
      for _,each in pairs(force.platforms) do if each.valid and each.name==c.platform then pl=each; break end end
      local surface=pl and pl.surface
      assert(surface,'no platform of ours named '..tostring(c.platform)..' with a surface')
      local holder=record or c
      holder.loss_since=holder.loss_since or c.since_tick or game.tick
      local names=name_set(c.names)  -- (BT1) made once per list
      local rows,n={},0
      if api.losses_since then rows,n=api.losses_since(force.name,surface.name,holder.loss_since,names,4) end
      local want=c.at_least or 1
      if n==0 then return false,string.format('platform %s: nothing of ours%s lost since tick %d',c.platform,names and ' of those names' or '',holder.loss_since) end
      local parts={}
      for _,r in ipairs(rows) do
        parts[#parts+1]=string.format('%s (%g,%g)%s %ds ago',r.n,r.x,r.y,r.c and ' by '..r.c or '',math.floor((game.tick-r.t)/60))
      end
      return n>=want,string.format('platform %s: %d of ours lost since tick %d%s: %s%s',c.platform,n,holder.loss_since,
        n<want and string.format(' (met at %d)',want) or '',table.concat(parts,', '),n>#rows and string.format(', +%d more',n-#rows) or '')
    end,
    -- (d26 batch246 FL, Astra #2461: trial 242 lost a floor tile at (-50,-60), tick 67333569, with no entity lost or hit)
    -- foundation tiles of that platform destroyed since the wait or guard began (since_tick, default its first check,
    -- kept on the wait or the condition), from flightwatch.lua's loss log: the hub's rebuilds of tiles on ghosts no
    -- one placed (a tile lost and rebuilt between checks counts), and the platform's foundation ghosts no one placed
    -- (a find at most once a second a platform while it is checked). Floor placed or mined on purpose is not counted.
    -- Met at at_least (default 1); saw names each tile: where, when its ghost was first seen and after which find, when
    -- it was rebuilt; a fired guard keeps them as its evidence.
    platform_foundation_loss=function(p,c,estimate,record)
      local pl
      for _,each in pairs(p.force.platforms) do if each.valid and each.name==c.platform then pl=each; break end end
      assert(pl and pl.surface,'no platform of ours named '..tostring(c.platform)..' with a surface')
      local holder=record or c
      holder.fl_since=holder.fl_since or c.since_tick or game.tick
      assert(api.floor_losses,'foundation losses are not read on this runtime')
      local r,keep=api.floor_losses(pl,game.tick)
      if holder.fl_seq==nil then
        -- the rows logged after since_tick, back through the ring (older than the ring holds: counted from its oldest);
        -- of those, a ghost first seen after a find from before since_tick is left out (its loss may be older); a tile
        -- rebuilt after since_tick counts
        local s,skip=r.seq,nil
        while s>0 and s>r.seq-keep do
          local e=r.ring[(s-1)%keep+1]
          if not e or e.seq~=s or e.pt<=holder.fl_since then break end
          if e.seen and e.after and e.after<holder.fl_since then skip=skip or {}; skip[#skip+1]=s end
          s=s-1
        end
        holder.fl_seq,holder.fl_skip=s,skip
      end
      local skipped={}
      for _,s in ipairs(holder.fl_skip or {}) do skipped[s]=true end
      local n=r.seq-holder.fl_seq-#(holder.fl_skip or {})
      local want=c.at_least or 1
      -- a find that met too many tile ghosts to read (rebuilds are still heard)
      local unread=r.skipped and r.skipped==r.scan_tick and string.format(' (the find at tick %d met over %d tile ghosts aboard and read none; rebuilds are still counted)',r.skipped,(r.skipped_n or 1)-1) or ''
      if n<=0 then return false,string.format('platform %s: no foundation tile of it destroyed since tick %d%s',c.platform,holder.fl_since,unread) end
      local rows,parts={},{}
      for seq=math.max(holder.fl_seq+1,r.seq-keep+1),r.seq do
        local e=r.ring[(seq-1)%keep+1]
        if e and e.seq==seq and not skipped[seq] and #rows<8 then
          rows[#rows+1]={x=e.x,y=e.y,seen=e.seen,after=e.after,rebuilt=e.rebuilt}
          local when=e.seen and string.format('ghost first seen at tick %d%s',e.seen,e.after and ' (lost after tick '..e.after..')' or '')
            or string.format('lost and rebuilt between reads%s',e.after and ' (after tick '..e.after..')' or '')
          parts[#parts+1]=string.format('(%d,%d) %s%s',e.x,e.y,when,e.rebuilt and ', rebuilt at tick '..e.rebuilt or ', not rebuilt yet')
        end
      end
      local met=n>=want
      if met then holder.evidence=rows end
      return met,string.format('platform %s: %d foundation tile%s destroyed since tick %d%s: %s%s',c.platform,n,n==1 and '' or 's',holder.fl_since,
        n<want and string.format(' (met at %d)',want) or '',table.concat(parts,', '),n>#parts and string.format(', +%d more',n-#parts) or '')..unread
    end,
    -- (d22 batch92 BB1, Sol #1884: platform_loss fires only once something is destroyed, and medium asteroid impacts
    -- can cascade before the next flight_watch read; BB2, Astra #1886: damage, as a repaired hit leaves no damaged
    -- entity to find) hits on our entities on a platform since the wait or guard began (since_tick, default its first
    -- check, kept on the wait or the condition), by anything not of our force (asteroids, enemies), as the platform's hit
    -- alerts count them (platalerts.lua, one ring row a hit, with the platform's damage total after it): met at at_least
    -- hits or at damage summed, whichever is given first reached (neither: the first hit), on entity_names when given;
    -- saw names the first hits (what, where, damage, by what, when), kept on the condition (a fired guard's evidence).
    -- Each check reads only the hits since the one before.
    platform_hit=function(p,c,estimate,record)
      local pl
      for _,each in pairs(p.force.platforms) do if each.valid and each.name==c.platform then pl=each; break end end
      assert(pl and pl.surface,'no platform of ours named '..tostring(c.platform)..' with a surface')
      local holder=record or c
      holder.hit_since=holder.hit_since or c.since_tick or game.tick
      local r,size
      if api.platform_hits then r,size=api.platform_hits(pl) end
      local seq,ring=r and r.seq or 0,r and r.ring or {}
      local total=r and r.total and r.total.damage or 0
      size=size or 64
      if holder.hit_seq==nil then
        -- the hits already after since_tick, back through the ring; older than the ring holds: counted from its oldest
        local s=seq
        while s>0 and s>seq-size do
          local x=ring_row(ring,size,s)
          if not x or x.t<=holder.hit_since then break end
          s=s-1
        end
        local after=ring_row(ring,size,s+1)
        holder.hit_seq,holder.hit_read,holder.hit_n,holder.hit_d,holder.hit_first=s,s,0,0,{}
        holder.hit_d0=after and after.D and after.D-after.d or total
        holder.hit_older=s>0 and s==seq-size and after~=nil or nil
      end
      local names=name_set(c.entity_names)  -- (BT1) made once per list
      local from=holder.hit_read+1
      -- more hits between two checks than the ring holds: the overwritten ones are counted, not named
      if seq-from+1>size then holder.hit_unread=(holder.hit_unread or 0)+(seq-size-from+1); from=seq-size+1 end
      for s=from,seq do
        local x=ring_row(ring,size,s)
        if x and (not names or names[x.n]) then
          holder.hit_n,holder.hit_d=holder.hit_n+1,holder.hit_d+(x.d or 0)
          if #holder.hit_first<4 then holder.hit_first[#holder.hit_first+1]={t=x.t,n=x.n,x=x.x,y=x.y,d=x.d,c=x.c,k=x.k} end
        end
      end
      holder.hit_read=math.max(holder.hit_read,seq)
      local n=names and holder.hit_n or seq-holder.hit_seq
      local dmg=names and holder.hit_d or math.max(0,total-holder.hit_d0)
      local g=tenth  -- (BT1) no closure a check
      local met
      if c.at_least==nil and c.damage==nil then met=n>=1
      else met=(c.at_least~=nil and n>=c.at_least) or (c.damage~=nil and dmg>=c.damage) end
      local goal={}
      if c.at_least then goal[#goal+1]=c.at_least..' hit'..(c.at_least==1 and '' or 's') end
      if c.damage then goal[#goal+1]=string.format('%g damage',g(c.damage)) end
      local older=holder.hit_older and ' (the ring keeps the last '..size..' hits: earlier ones since then not counted)' or ''
      local unread=names and holder.hit_unread and string.format(' (%d more hits came between two checks, not read by name)',holder.hit_unread) or ''
      if n==0 then return false,string.format('platform %s: no hit on ours%s since tick %d%s%s',c.platform,names and ' of those names' or '',holder.hit_since,older,unread) end
      local parts={}
      for _,x in ipairs(holder.hit_first) do
        parts[#parts+1]=string.format('%s (%g,%g) %g damage %s %ds ago',x.n,math.floor(x.x*2+0.5)/2,math.floor(x.y*2+0.5)/2,g(x.d or 0),
          x.c and 'by '..x.c or x.k and '('..x.k..', no cause)' or '(no cause)',math.floor((game.tick-x.t)/60))
      end
      return met,string.format('platform %s: %d hit%s, %g damage, on ours%s since tick %d%s, first: %s%s%s%s',c.platform,n,n==1 and '' or 's',g(dmg),
        names and ' of those names' or '',holder.hit_since,not met and #goal>0 and ' (met at '..table.concat(goal,' or ')..')' or '',
        #parts>0 and table.concat(parts,', ') or 'none kept',n>#parts and string.format(', +%d more',n-#parts) or '',older,unread)
    end,
    -- (d22 batch92 BB3, Astra #1887: a probe flight turned back at a share of its outer leg, whatever its speed) the
    -- share of its leg a platform has flown, as the platforms read gives it (freight.lua leg: from and to in the
    -- direction it flies), met at at_least; on the leg asked only (from, to), so a return leg, another leg or a stop
    -- never meets it, said in saw. When met, the progress and the leg are kept on the condition (a fired guard's
    -- evidence).
    platform_progress=function(p,c,estimate,record)
      local pl
      for _,each in pairs(p.force.platforms) do if each.valid and each.name==c.platform then pl=each; break end end
      assert(pl,'no platform of ours named '..tostring(c.platform))
      local holder=record or c
      local asked=(c.from or c.to) and string.format(' (asked: %s->%s)',c.from or 'any',c.to or 'any') or ''
      local l=api.leg and api.leg(pl)
      if not l then
        local oka,at=pcall(location_name,pl)  -- (BT1) no closure a check
        if not oka then at=nil end
        return false,string.format('platform %s: not flying (%s): not counted%s',c.platform,at and 'at '..at or 'no space location',asked)
      end
      local pct=math.floor(l.flown*1000+0.5)/10
      if (c.from and l.from~=c.from) or (c.to and l.to~=c.to) then
        return false,string.format('platform %s: flying %s->%s, %g%% flown: not the leg asked, not counted%s',c.platform,l.from,l.to,pct,asked)
      end
      local met=l.flown>=c.at_least
      if met then holder.evidence={tick=game.tick,from=l.from,to=l.to,flown=math.floor(l.flown*1000+0.5)/1000,length_km=math.floor((l.length or 0)+0.5)} end
      return met,string.format('platform %s: flying %s->%s, %g%% of %d km flown (met at %g%%)',c.platform,l.from,l.to,pct,math.floor((l.length or 0)+0.5),
        math.floor(c.at_least*1000+0.5)/10)
    end,
    -- (d22 batch92 BB2, Astra #1886: a probe flight's retreat when its power reserve drops) a platform's accumulators
    -- together: the energy they hold over what they can hold, as each one's GUI shows them; met under fraction. Read
    -- at each check (a platform holds tens of them); (d22 batch110 BT1) the list kept while the same, as fluid_count's
    -- holders are.
    platform_energy_below=function(p,c)
      local pl
      local force=p.force
      for _,each in pairs(force.platforms) do if each.valid and each.name==c.platform then pl=each; break end end
      local surface=pl and pl.surface
      assert(surface,'no platform of ours named '..tostring(c.platform)..' with a surface')
      local stored,cap,n=0,0,0
      for _,e in ipairs(platform_accumulators(surface,force)) do
        n=n+1; stored=stored+(e.energy or 0); cap=cap+(e.electric_buffer_size or 0)
      end
      if n==0 or cap<=0 then return false,string.format('platform %s: no accumulator of ours',c.platform) end
      local f=stored/cap
      return f<c.fraction,string.format('platform %s: %d accumulator%s hold %.1f of %.1f MJ (%d%%; met under %d%%)',c.platform,n,n==1 and '' or 's',
        stored/1e6,cap/1e6,math.floor(f*100),math.floor(c.fraction*100+0.5))
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
      local l=conn and api.leg and api.leg(pl)  -- (CN1) the leg as flown
      local where=loc and ('at '..loc) or l and string.format('flying %s->%s %d%%',l.from,l.to,math.floor(l.flown*100+0.5))
        or conn and string.format('flying %s->%s %d%%',conn.from.name,conn.to.name,math.floor((pl.distance or 0)*100+0.5)) or 'nowhere'
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
      -- (d22 batch100 BJ1, Sol #1905: a queued platform_left right after the platform_schedule step that sent the platform
      -- off began with it already on its path and waited for the next departure) a departure in the platform log
      -- (freight.lua) at or after the baseline counts: since_tick, else in a queue the tick the step before it in the same
      -- plan started (record.after_step); a lone wait keeps its first check
      local since=c.since_tick or (record and record.after_step and record.after_step.tick)
      if since and api.left_since then
        local e=api.left_since(pl.name,p.force.name,c.location,since)
        if e then
          return true,string.format('%s left %s at tick %d (%s); now %s',c.platform,e.at,e.tick,
            c.since_tick and 'since_tick '..c.since_tick or string.format('after the step before this wait, %s, began at tick %d',tostring(record.after_step.action),since),w.text)
        end
      end
      if there then holder.platform_was_there=w.at; return false,c.platform..' '..w.text..' (met when it leaves)' end
      if holder.platform_was_there then return true,c.platform..' left '..holder.platform_was_there..'; now '..w.text end
      -- (d19 batch48 2) a departure made by platform_schedule in the second before this wait began (the same tick, or
      -- the previous step of the same queue) counts
      local d=w.departed
      if d and d.tick>=holder.platform_began-DEPART_GRACE and (c.location==nil or d.from==c.location) then
        return true,string.format('%s left %s at tick %d (platform_schedule by %s, %d ticks before this wait began); now %s',c.platform,d.from,d.tick,
          tostring(d.by),math.max(0,holder.platform_began-d.tick),w.text)
      end
      return false,c.platform..' '..w.text..'; met when it stops '..(c.location and 'at '..c.location or 'somewhere')..' and leaves again'
        ..(since and string.format(' (a departure before tick %d does not count)',since) or ' (a departure before this wait does not count)')
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
    -- pod_landed {platform, item?, at_least?, location?} (batch28 B1, Luna: polled silo, shipment and where_is for Spindle's
    -- packs and two fuel pods): pods sent down from the platform that landed since the wait began (freight's receipts:
    -- received by a landing pad, or landed as a cargo pod container); with item, how many of it they carried; met at
    -- at_least (default 1: one pod, or one of the item). (d27 batch259 PL, Astra #2484) location: only pods landed on
    -- that planet.
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
      -- (d25 batch205 QR1, Sol #2337: a 750-magazine pickup outlasted the 54000-tick timeout and its resume counted from
      -- zero) since_tick: a fixed start; else the wait's first check, kept by a held or requeued step (scheduler.lua).
      -- Counted from the pod ledger (podlog.lua: its last 1000 journeys a planet), else freight's last 16 receipts.
      record.pod_since=record.pod_since or game.tick
      local since=c.since_tick or record.pod_since
      local from=c.since_tick and 'since tick '..since or string.format('since the wait began (tick %d)',since)
      local want=c.at_least or 1
      local what=c.item and (c.quality and c.quality~='any' and c.item..' ('..c.quality..' quality)' or c.item) or nil
      if api.pods_landed then
        local r=api.pods_landed(c.platform,since,c.item,c.quality~='any' and c.quality or nil,c.location)
        local have=c.item and r.items or r.pods
        local other={}
        for planet,n in pairs(r.elsewhere or {}) do other[#other+1]=string.format('%d on %s',n,planet) end
        table.sort(other)
        -- (d25 batch207 QT1, Sol #2344) a pod counts once its cargo is delivered (about 80 ticks after it lands)
        return have>=want,string.format('%d pod%s from %s landed%s and delivered %s%s%s%s%s%s',r.pods,r.pods==1 and '' or 's',c.platform,
          c.location and ' on '..c.location or '',from,
          what and string.format(' with %d %s',r.items,what) or '',r.last and string.format(' (the last delivered at tick %d, %s on %s)',r.last.delivered or r.last.landed,tostring(r.last.dest or 'where not read'),r.last.planet) or '',
          (r.landing or 0)>0 and string.format('; %d more landed, cargo not delivered yet',r.landing) or '',
          r.complete and '' or string.format('; the pod ledger keeps journeys sent from tick %d on: pods landed before that are not counted',r.oldest or 0),
          #other>0 and '; not counted, landed elsewhere: '..table.concat(other,', ') or ''),
          estimate and {value=have,scope='pods:'..c.platform..':'..tostring(what)} or nil
      end
      local list=api.receipts and api.receipts(pl,since) or {}
      local pods,items,last=0,0,nil
      for _,r in ipairs(list) do
        if r.kind~='gone' and r.kind~='lost' and (not c.location or r.stop==c.location) then
          local n=c.item and ((r.cargo or {})[c.item] or 0) or 1
          if n>0 then pods=pods+1; items=items+(c.item and n or 0); last=r end
        end
      end
      local have=c.item and items or pods
      return have>=want,string.format('%d pod%s from %s landed%s %s%s%s',pods,pods==1 and '' or 's',c.platform,c.location and ' on '..c.location or '',from,
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
      return n>0,n..' burners below '..c.count..' fuel'..(c.surface~=nil and ' on '..surface_of(p,c).name or '')..(near and string.format(' (nearest %s at %d,%d)',near.name,math.floor(near.position.x),math.floor(near.position.y)) or '')
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
  local NAMES='no_enemy_structures|no_enemies|units_clear|turrets_idle|ammo_below|health_below|health_above|item_count|fluid_count|circuit_signal|rocket_ready|rocket_parts|crafting_done|researched|ghosts_waiting|damaged|fuel_below|spoil_within|pod_landed|platform_arrived|platform_left|produced|platform_built|platform_ready|platform_loss|platform_hit|platform_foundation_loss|platform_energy_below|platform_progress|platform_ammo_below|all|any'
  -- Other names for a condition (A1, Sonnet 22:50: silo_parts refused as an invalid until): the name it goes by.
  M.ALIASES={silo_parts='rocket_parts',platform_damage='platform_hit'}
  -- Every member holds (B2, Grok 22:50: a launch waiting for both its rocket and its platform): {until=all,
  -- conditions=[...]} met when each is; saw joins theirs. Members are plain conditions.
  checks.platform_ready=checks.platform_built
  -- (d22 batch117 BZ1, Astra #1970: a full-edge abort that keeps the return leg's ammunition) a platform's whole stock
  -- of one ammunition item: hub, turret slots, belts, inserter hands, machine outputs and chests, from the background
  -- reading (ammoreserve.lua) with its age; a reading older than max_age (or none by then) meets it.
  checks.platform_ammo_below=function(p,c)
    local pl=M.platform_named(p,c.platform)
    if not pl.surface then error('platform '..c.platform..' has no surface yet',0) end
    return api.ammo_reserve(pl,p.force,c)
  end
  checks['all']=function(p,c,estimate,record)
    local all,saws=true,{}
    for i,m in ipairs(c.conditions) do
      local met,saw=checks[m['until']](p,m,nil,record)
      if not met then all=false end
      saws[i]=(met and 'met: ' or 'not yet: ')..tostring(saw)
    end
    return all,table.concat(saws,'; ')
  end
  -- (d23 batch127 CJ1, Sol #2076: Asterion's probe waits for outward progress or promethium in the hub, one lane, its
  -- guards on) Any member holds: {until=any, conditions=[...]} met when one is; each member is read every check (their
  -- baselines start together); saw names the first that holds (#N) with its own saw, then the others'; the record keeps
  -- matched {index, until, saw}.
  checks['any']=function(p,c,estimate,record)
    local first,saws=nil,{}
    for i,m in ipairs(c.conditions) do
      local met,saw=checks[m['until']](p,m,nil,record)
      if met and not first then first={index=i,['until']=m['until'],saw=tostring(saw)} end
      saws[i]=string.format('#%d %s: %s%s',i,m['until'],met and 'met: ' or 'not yet: ',tostring(saw))
    end
    if record then record.matched=first end
    if not first then return false,'none yet: '..table.concat(saws,'; ') end
    local rest={}
    for i,t in ipairs(saws) do if i~=first.index then rest[#rest+1]=t end end
    return true,saws[first.index]..(#rest>0 and ' (others: '..table.concat(rest,'; ')..')' or '')
  end
  -- Argument checks run when a plan is submitted, not when it first fires.
  local SURFACE_LIST='item_count, rocket_ready, rocket_parts, spoil_within, produced, ammo_below, fuel_below and fluid_count'
  local PLATFORM_LIST='ammo_below, item_count, fluid_count, circuit_signal, produced, ghosts_waiting, pod_landed, platform_loss, platform_hit, platform_foundation_loss, platform_energy_below, platform_progress, platform_ammo_below, platform_built, platform_ready, platform_arrived and platform_left'
  local SURFACE_KINDS,PLATFORM_KINDS={},{}
  for k in SURFACE_LIST:gsub(' and ',', '):gmatch('[%w_]+') do SURFACE_KINDS[k]=true end
  for k in PLATFORM_LIST:gsub(' and ',', '):gmatch('[%w_]+') do PLATFORM_KINDS[k]=true end
  function M.validate(c)
    if type(c)=='table' and M.ALIASES[c['until']] then c['until']=M.ALIASES[c['until']] end
    -- queue_done (A1, Sonnet 22:50) is a sleep's: fh sleep/fh wait --until queue_done; in a queue the next step is that.
    if type(c)=='table' and c['until']=='queue_done' then
      error('until queue_done is a sleep\'s (fh sleep SECONDS --until queue_done, fh wait --until queue_done, sleep {seconds, condition: {until: "queue_done"}}): it wakes when your queue finishes or stalls; in a queue the next step runs when this one ends',0)
    end
    assert(type(c)=='table' and checks[c['until']],'until must be one of '..NAMES..'; a sleep also takes queue_done')
    -- (d20 batch62 X2, Sol #1529: a surface a read took and did not use) surface and platform only where the condition reads them
    if c.surface~=nil then
      assert(SURFACE_KINDS[c['until']],'surface applies to '..SURFACE_LIST..'; '..tostring(c['until'])..' reads no other surface')
      -- (d20 batch62 X3) a planet by name; a platform goes by platform=NAME, and its place there is given (your character
      -- may stand on another surface)
      local kind=c['until']
      assert(type(c.surface)=='string' and game.get_surface(c.surface),kind..' surface must be a surface name (nauvis, vulcanus, ...)')
      assert(not game.get_surface(c.surface).platform,kind..' surface is a planet; a platform goes by platform=NAME')
      assert(c.platform==nil,kind..': surface or platform, not both')
      if kind=='produced' or kind=='ammo_below' or kind=='fuel_below' or kind=='fluid_count' then
        assert(c.position~=nil or c.positions~=nil or c.area~=nil,kind..' with surface needs '..(kind=='produced' and 'position or positions (the machines there)'
          or kind=='fluid_count' and 'positions or area there' or 'position (with radius), positions or area there')..' (your character may stand on another surface)')
      end
    end
    if c.platform~=nil then
      assert(PLATFORM_KINDS[c['until']],'platform applies to '..PLATFORM_LIST..'; '..tostring(c['until'])..' reads no platform')
    end
    if c['until']=='all' or c['until']=='any' then
      local kind=c['until']
      assert(type(c.conditions)=='table' and #c.conditions>=1 and #c.conditions<=8,'until='..kind..' takes conditions: 1..8 wait_until conditions, met when '..(kind=='all' and 'every one holds' or 'one of them holds'))
      for i,m in ipairs(c.conditions) do
        assert(type(m)=='table' and m['until']~='all' and m['until']~='any','until='..kind..' takes plain conditions')
        -- (CJ1) a member's refusal names it
        local ok,err=pcall(M.validate,m)
        if not ok then error(kind..' conditions['..i..'] ('..tostring(m['until'])..'): '..tostring(err):gsub('^[^:]*:%d+: ',''),0) end
      end
      return c
    end
    if c.position~=nil then api.position(c.position) end
    if c.radius~=nil then number(c.radius,1,256,'radius') end
    local kind=c['until']
    if c.loop~=nil and kind~='platform_ammo_below' then error('loop applies to platform_ammo_below only (the belts joined to the belt at that position)',0) end
    if c.area~=nil and (kind=='platform_built' or kind=='platform_ready') then
      -- (C5: an area or a list of them on the platform, checked below)
    elseif c.area~=nil and kind=='ghosts_waiting' and c.platform~=nil then
      M.areas_of(c.area)
    elseif c.area~=nil and kind=='platform_ammo_below' then
      -- (d24 batch173 QP1) one area aboard, in platform coordinates
      assert(type(c.area)=='table' and (c.area.left_top or type(c.area[1])=='table'),'platform_ammo_below area: one {left_top, right_bottom} (or [[x,y],[x,y]]) aboard')
      local l,r=api.position(c.area.left_top or c.area[1]),api.position(c.area.right_bottom or c.area[2])
      assert(r.x>l.x and r.y>l.y and r.x-l.x<=1024 and r.y-l.y<=1024,'platform_ammo_below area must be nonempty and at most 1024x1024')
    elseif c.area~=nil then
      assert(kind=='ammo_below' or kind=='fuel_below' or kind=='fluid_count','area applies to ammo_below, fuel_below or fluid_count (and platform_built, platform_ready, ghosts_waiting with platform)')
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
      assert(c.platform~=nil or c.surface~=nil,'ammo_below positions applies with platform (turrets on a platform, platform coordinates) or surface (turrets on that planet)')
      assert(c.position==nil and c.radius==nil and c.area==nil,'ammo_below positions excludes position, radius and area')
      assert(type(c.positions)=='table' and #c.positions>=1 and #c.positions<=64,'ammo_below positions takes 1..64 {x,y} (turrets)')
      for _,pos in ipairs(c.positions) do api.position(pos) end
    end
    if kind=='health_below' or kind=='health_above' then number(c.fraction,0,1,'fraction') end
    -- (batch33 A2) quality: item_count and (d22 batch117 BZ1) platform_ammo_below read it, and (d25 batch205 QR1)
    -- pod_landed with item; one given elsewhere is refused
    if c.quality~=nil then
      assert(kind=='item_count' or kind=='platform_ammo_below' or kind=='pod_landed','quality applies to item_count, platform_ammo_below and pod_landed only (no other condition counts by quality)')
      assert(c.quality=='any' or (type(c.quality)=='string' and prototypes.quality and prototypes.quality[c.quality]),
        kind..' quality is a quality name (normal, uncommon, rare, epic, legendary) or "any" (every quality summed)')
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
    if kind=='fluid_count' and c.surface~=nil then
      assert(c.position==nil and c.radius==nil,'fluid_count on a planet: positions (1..64 {x,y}: tanks, pipes, machines) or area; no position or radius')
      assert(c.positions==nil or c.area==nil,'fluid_count on a planet: positions or area, not both')
      if c.positions~=nil then
        assert(type(c.positions)=='table' and #c.positions>=1 and #c.positions<=64,'fluid_count positions takes 1..64 {x,y} (tanks, pipes, machines)')
        for _,pos in ipairs(c.positions) do api.position(pos) end
      end
    end
    if kind=='fluid_count' or kind=='circuit_signal' then
      assert(type(c.platform)=='string' and #c.platform>0 or (kind=='fluid_count' and c.surface~=nil),kind..' requires platform (a platform name)'..(kind=='fluid_count' and ', or surface (a planet) with positions or area' or ''))
      assert(kind~='fluid_count' or c.platform==nil or (c.positions==nil and c.area==nil),'fluid_count on a platform reads all of it: no positions or area (those go with surface)')
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
    if kind=='platform_foundation_loss' then
      assert(type(c.platform)=='string' and #c.platform>0,'platform_foundation_loss requires platform (a platform of ours by name)')
      if c.at_least~=nil then number(c.at_least,1,1000,'at_least') end
      assert(c.since_tick==nil or (type(c.since_tick)=='number' and c.since_tick>=0 and c.since_tick<=game.tick),'platform_foundation_loss since_tick is a game tick up to now')
    end
    if kind=='platform_hit' then
      assert(type(c.platform)=='string' and #c.platform>0,'platform_hit requires platform (a platform of ours by name)')
      if c.at_least~=nil then number(c.at_least,1,1000,'at_least') end
      assert(c.entity_names==nil or (type(c.entity_names)=='table' and #c.entity_names>=1 and #c.entity_names<=16),'platform_hit entity_names: 1..16 entity names')
      for _,n in ipairs(c.entity_names or {}) do assert(type(n)=='string' and prototypes.entity[n],'platform_hit entity_names: '..tostring(n)..' is no entity name') end
      assert(c.since_tick==nil or (type(c.since_tick)=='number' and c.since_tick>=0 and c.since_tick<=game.tick),'platform_hit since_tick is a game tick up to now')
      if c.damage~=nil then number(c.damage,0.1,1e9,'damage') end
    end
    if kind=='platform_progress' then
      assert(type(c.platform)=='string' and #c.platform>0,'platform_progress requires platform (a platform of ours by name)')
      assert(type(c.at_least)=='number' and c.at_least>0 and c.at_least<=1,'platform_progress at_least: the share of the leg flown, over 0 and up to 1 (0.2: 20%)')
      for _,k in ipairs({'from','to'}) do
        assert(c[k]==nil or (type(c[k])=='string' and prototypes.space_location[c[k]]),'platform_progress '..k..': a planet or space location name')
      end
    end
    if kind=='platform_energy_below' then
      assert(type(c.platform)=='string' and #c.platform>0,'platform_energy_below requires platform (a platform of ours by name)')
      assert(type(c.fraction)=='number' and c.fraction>0 and c.fraction<=1,'platform_energy_below fraction: the share of the accumulators\' capacity, over 0 and up to 1 (0.3: under 30%)')
    end
    if kind=='platform_ammo_below' then
      assert(type(c.platform)=='string' and #c.platform>0,'platform_ammo_below requires platform (a platform of ours by name)')
      assert(type(c.item)=='string' and prototypes.item[c.item] and prototypes.item[c.item].type=='ammo','platform_ammo_below item: an ammunition item (firearm-magazine, rocket, railgun-ammo, ...)')
      assert(type(c.count)=='number' and c.count>=1 and c.count<=1e6 and c.count==math.floor(c.count),'platform_ammo_below count: 1..1000000, met below it')
      assert(c.quality==nil or c.quality=='any' or (type(c.quality)=='string' and prototypes.quality and prototypes.quality[c.quality]),'platform_ammo_below quality: a quality name or "any" (default normal)')
      assert(c.max_age==nil or (type(c.max_age)=='number' and c.max_age>=30 and c.max_age<=900),'platform_ammo_below max_age: 30..900 seconds (default 120): a reading older than this meets it')
      -- (d24 batch173 QP1, Astra #2241) loop: the belts joined to the belt at that position, their inserters and turrets
      assert(c.area==nil or c.loop==nil,'platform_ammo_below: area or loop, not both')
      assert(c.position==nil and c.radius==nil,'platform_ammo_below: area or loop (a belt\'s position aboard) scopes it; no position or radius')
      if c.loop~=nil then api.position(c.loop) end
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
      -- (d25 batch205 QR1) a fixed start, and one quality of item
      assert(c.since_tick==nil or (type(c.since_tick)=='number' and c.since_tick==math.floor(c.since_tick) and c.since_tick>=0 and c.since_tick<=game.tick),
        'pod_landed since_tick is a whole game tick 0..now ('..game.tick..'): pods landed after it count')
      assert(not ((c.drop_id or c.last_drop) and c.since_tick~=nil),'drop_id and last_drop wait for one drop: no since_tick')
      assert(c.quality==nil or c.item~=nil,'pod_landed quality goes with item; without it (or with "any") every quality of item counts')
      -- (d27 batch259 PL) location: only pods landed on that planet count (a drop is one pod: its own landing says where)
      assert(c.location==nil or (type(c.location)=='string' and game.planets[c.location]~=nil),'pod_landed location is a planet name (only pods landed there count)')
      assert(not ((c.drop_id or c.last_drop) and c.location~=nil),'drop_id and last_drop wait for one drop: no location (its own landing says where)')
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
      assert(c.since_tick==nil or (kind=='platform_left' and type(c.since_tick)=='number' and c.since_tick>=0 and c.since_tick<=game.tick),
        kind=='platform_left' and 'platform_left since_tick is a game tick up to now' or 'platform_arrived takes no since_tick')
    end
    return c
  end
  -- A guard that can never be met as things stand (d22 batch118 CA1, Astra: a guard on an unwired hub held unmet with
  -- nothing said): circuit_signal at_least N (over 0) on a hub with no red or green wire (every signal reads 0 there),
  -- alone or in all (any: every member so). The refusal's text, or nil.
  function M.guard_refusal(p,c)
    if type(c)~='table' then return nil end
    local kind=M.ALIASES[c['until']] or c['until']
    if kind=='all' then
      for _,m in ipairs(type(c.conditions)=='table' and c.conditions or {}) do
        local why=M.guard_refusal(p,m)
        if why then return why end
      end
      return nil
    end
    -- (CJ1) any: never met only when no member can be
    if kind=='any' then
      local whys={}
      for _,m in ipairs(type(c.conditions)=='table' and c.conditions or {}) do
        local why=M.guard_refusal(p,m)
        if not why then return nil end
        whys[#whys+1]=why
      end
      return #whys>0 and 'any: no member can be met: '..table.concat(whys,'; ') or nil
    end
    if kind~='circuit_signal' or c.at_least==nil or c.at_least<=0 then return nil end
    local ok,hub=pcall(function() return M.platform_named(p,c.platform).hub end)
    if not (ok and hub and hub.valid) then return nil end
    for _,w in ipairs({defines.wire_connector_id.circuit_red,defines.wire_connector_id.circuit_green}) do
      local okn,net=pcall(function() return hub.get_circuit_network(w) end)
      if okn and net then return nil end
    end
    return string.format('circuit_signal %s at_least %d on %s: its hub has no red or green wire, so %s reads 0 there (as the game\'s own circuit conditions read an unwired hub) and at_least %d is never met while it has none',
      c.signal,c.at_least,c.platform,c.signal,c.at_least)
  end
  function M.check(p,c,estimate,record)
    if M.ALIASES[c['until']] then c['until']=M.ALIASES[c['until']] end
    if c['until']=='researched' then assert(p.force.technologies[c.technology],'unknown technology') end
    return checks[c['until']](p,c,estimate,record)
  end
  M.names=NAMES
  return M
end
