-- World predicates for plan waits and guards. Each reads only what the player
-- could see: enemy structures on the chart, units in visible chunks, our own
-- turrets, ghosts, buildings and burners, the character's health and inventory.
return function(api)
  local M={}
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
    -- An area search meets the footprint (a position and radius only the silo's centre, read on a copy of world n).
    for _,e in pairs(p.surface.find_entities_filtered{area={{pos.x-0.01,pos.y-0.01},{pos.x+0.01,pos.y+0.01}},type='rocket-silo',force=p.force}) do
      if e.valid then return e end
    end
    error(string.format('no rocket silo of ours at (%g,%g) on %s',pos.x,pos.y,p.surface.name),0)
  end
  -- Each returns met, and a short description of what it saw.
  -- A condition's own memory where no wait record is given (queue step conditions, orders): kept while the condition
  -- table lives.
  local seen=setmetatable({},{__mode='k'})
  local function seen_by(c) seen[c]=seen[c] or {}; return seen[c] end
  local checks={
    no_enemy_structures=function(p,c)
      local n=enemies(p,c,ENEMY_STRUCTURES); return n==0,n..' enemy structures'
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
    ammo_below=function(p,c)
      local low=0
      for _,e in ipairs(turrets(p,c)) do
        local n=e.valid and ammo(e)
        if n and n<c.count then low=low+1 end
      end
      return low>0,low..' turrets below '..c.count
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
        n=inv.get_item_count(c.item)
        scope={'platform',c.platform}
        where=' in '..c.platform..' hub (landed stock; excludes incoming cargo and hub trash)'
      elseif positions then
        scope={tostring(p.surface.index or p.surface.name or '')}
        local seen,silos=0,{}
        for _,raw in ipairs(positions) do
          local pos=api.position(raw)
          scope[#scope+1]=pos.x..','..pos.y
          for _,e in pairs(p.surface.find_entities_filtered{position=pos,radius=0.3,force=p.force}) do
            -- A silo's rocket stands on its centre and holds nothing of its own (the silo counts the cargo); a robot
            -- flying over a chest is not the chest (runtime.lua M.target_rank, Astra 07:05).
            if e.valid and e~=p.character and e.type~='rocket-silo-rocket' and e.type~='rocket-silo-rocket-shadow'
              and not (api.passing and api.passing(e)) then
              local ok,k=pcall(e.get_item_count,c.item)
              if ok and k then n=n+k end
              seen=seen+1
              if e.type=='rocket-silo' and #silos<4 then silos[#silos+1]=(silo_line(e)) end
            end
          end
        end
        where=' in '..seen..' entities'..(#silos>0 and '; '..table.concat(silos,'; ') or '')
      else
        n=p.get_main_inventory().get_item_count(c.item)
        scope={'character',tostring(p.index)}
      end
      local met=(c.at_least==nil or n>=c.at_least) and (c.below==nil or n<c.below)
      return met,c.item..' '..n..where,estimate and {value=n,scope=table.concat(scope,':')} or nil
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
      return n>=c.at_least,string.format('rocket parts %d/%d (at least %d); %s',n,required,c.at_least,line),
        estimate and {entity=e,parts=n,required=required} or nil
    end,
    crafting_done=function(p)
      local n=p.crafting_queue_size; return n==0,n..' crafts queued'
    end,
    researched=function(p,c)
      local t=p.force.technologies[c.technology]; return t.researched,c.technology..(t.researched and ' researched' or ' not researched')
    end,
    -- Our ghosts (entities and tiles) waiting to be built.
    ghosts_waiting=function(p,c)
      local centre,radius=area(p,c)
      local n=#p.surface.find_entities_filtered{position=centre,radius=radius,type={'entity-ghost','tile-ghost'},force=p.force}
      return n>=(c.at_least or 1),n..' ghosts'
    end,
    -- A platform's foundation built (Astra, d15 06:23: ship conversions ran in the body queue with an outside tile
    -- checker): no tile ghost left on the named platform; with entities=true no entity ghost either.
    platform_built=function(p,c)
      local pl
      for _,each in pairs(p.force.platforms) do if each.valid and each.name==c.platform then pl=each; break end end
      assert(pl,'no platform of ours named '..tostring(c.platform))
      local surface=pl.surface
      assert(surface,'platform '..c.platform..' has no surface yet')
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
      if there then holder.platform_was_there=w.at; return false,c.platform..' '..w.text..' (met when it leaves)' end
      if holder.platform_was_there then return true,c.platform..' left '..holder.platform_was_there..'; now '..w.text end
      return false,c.platform..' '..w.text..'; met when it stops '..(c.location and 'at '..c.location or 'somewhere')..' and leaves again (a departure before this wait does not count)'
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
  local NAMES='no_enemy_structures|no_enemies|turrets_idle|ammo_below|health_below|health_above|item_count|rocket_ready|rocket_parts|crafting_done|researched|ghosts_waiting|damaged|fuel_below|platform_arrived|platform_left|produced|platform_built'
  -- Argument checks run when a plan is submitted, not when it first fires.
  function M.validate(c)
    assert(type(c)=='table' and checks[c['until']],'until must be one of '..NAMES)
    if c.position~=nil then api.position(c.position) end
    if c.radius~=nil then number(c.radius,1,256,'radius') end
    local kind=c['until']
    if c.area~=nil then
      assert(kind=='ammo_below' or kind=='fuel_below','area applies to ammo_below or fuel_below')
      assert(c.radius==nil and c.position==nil,'area excludes position and radius')
      local l,r=api.position(c.area.left_top or c.area[1]),api.position(c.area.right_bottom or c.area[2])
      assert(r.x>l.x and r.y>l.y and r.x-l.x<=256 and r.y-l.y<=256,'area must be nonempty and at most 256x256')
    end
    if kind=='ammo_below' then number(c.count,1,1000,'count') end
    if kind=='health_below' or kind=='health_above' then number(c.fraction,0,1,'fraction') end
    if kind=='item_count' then
      assert(type(c.item)=='string' and prototypes.item[c.item],'item_count requires a known item')
      if c.platform~=nil then
        assert(type(c.platform)=='string' and #c.platform>0,'item_count platform requires a platform name')
        assert(c.position==nil and c.positions==nil and c.surface==nil,'item_count platform counts the hub; no position, positions or surface')
      end
      assert(c.at_least~=nil or c.below~=nil,'item_count requires at_least or below')
      if c.at_least~=nil then number(c.at_least,0,1e9,'at_least') end
      if c.below~=nil then number(c.below,1,1e9,'below') end
      if c.positions~=nil then
        assert(type(c.positions)=='table' and #c.positions>=1 and #c.positions<=64,'item_count positions takes 1..64 {x,y} (chests)')
        for _,pos in ipairs(c.positions) do api.position(pos) end
      end
    end
    if kind=='produced' then
      assert(c.item==nil or (type(c.item)=='string' and prototypes.item[c.item]),'produced item must be a known item')
      assert(c.position~=nil or c.positions~=nil,'produced requires position or positions (the machines, 1..64 {x,y})')
      if c.positions~=nil then
        assert(type(c.positions)=='table' and #c.positions>=1 and #c.positions<=64,'produced positions takes 1..64 {x,y} (machines)')
        for _,pos in ipairs(c.positions) do api.position(pos) end
      end
      assert(c.at_least~=nil,'produced requires at_least (items made since the wait began; crafts without item)')
      number(c.at_least,1,1e9,'at_least')
    end
    if kind=='platform_built' then
      assert(type(c.platform)=='string' and #c.platform>0,'platform_built requires platform (a platform name)')
      assert(c.entities==nil or type(c.entities)=='boolean','platform_built entities must be true or false')
    end
    if kind=='researched' then assert(type(c.technology)=='string','researched requires technology') end
    if kind=='rocket_ready' then assert(c.position~=nil,'rocket_ready requires position (a rocket silo\'s, any tile of it)') end
    if kind=='rocket_parts' then
      assert(c.position~=nil,'rocket_parts requires position (a rocket silo\'s, any tile of it)')
      assert(c.at_least~=nil,'rocket_parts requires at_least (parts of the rocket being built, 1..required)')
      number(c.at_least,1,1000,'at_least')
    end
    if kind=='ghosts_waiting' and c.at_least~=nil then number(c.at_least,1,100000,'at_least') end
    if kind=='damaged' and c.fraction~=nil then number(c.fraction,0.01,1,'fraction') end
    if kind=='fuel_below' then number(c.count,1,1000,'count') end
    if kind=='platform_arrived' or kind=='platform_left' then
      assert(type(c.platform)=='string' and #c.platform>0,kind..' requires platform (a platform name)')
      assert(c.location==nil or (type(c.location)=='string' and prototypes.space_location[c.location]),'location must be a space location (a planet name)')
    end
    return c
  end
  function M.check(p,c,estimate,record)
    if c['until']=='researched' then assert(p.force.technologies[c.technology],'unknown technology') end
    return checks[c['until']](p,c,estimate,record)
  end
  M.names=NAMES
  return M
end
