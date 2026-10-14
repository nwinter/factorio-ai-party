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
  local function turrets(p,c)
    local centre,radius=area(p,c)
    return p.surface.find_entities_filtered{position=centre,radius=radius,type=OUR_TURRETS,force=p.force}
  end
  local function ammo(e)
    local inv=e.type=='ammo-turret' and e.get_inventory(defines.inventory.turret_ammo)
    return inv and inv.get_item_count() or nil
  end
  -- Each returns met, and a short description of what it saw.
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
    -- In the character's main inventory, or summed over our entities on the
    -- given tiles (chests, machines: every inventory they have).
    item_count=function(p,c)
      local n,where=0,''
      if c.positions then
        local seen=0
        for _,raw in ipairs(c.positions) do
          for _,e in pairs(p.surface.find_entities_filtered{position=api.position(raw),radius=0.3,force=p.force}) do
            if e.valid and e~=p.character then
              local ok,k=pcall(e.get_item_count,c.item)
              if ok and k then n=n+k end
              seen=seen+1
            end
          end
        end
        where=' in '..seen..' entities'
      else
        n=p.get_main_inventory().get_item_count(c.item)
      end
      local met=(c.at_least==nil or n>=c.at_least) and (c.below==nil or n<c.below)
      return met,c.item..' '..n..where
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
    -- Our burner machines (furnaces, drills, boilers, burner inserters...) holding under count fuel items.
    fuel_below=function(p,c)
      local centre,radius=area(p,c)
      local n,near,best=0,nil,nil
      for _,e in pairs(p.surface.find_entities_filtered{position=centre,radius=radius,force=p.force,type=BURNERS}) do
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
  local NAMES='no_enemy_structures|no_enemies|turrets_idle|ammo_below|health_below|health_above|item_count|crafting_done|researched|ghosts_waiting|damaged|fuel_below'
  -- Argument checks run when a plan is submitted, not when it first fires.
  function M.validate(c)
    assert(type(c)=='table' and checks[c['until']],'until must be one of '..NAMES)
    if c.position~=nil then api.position(c.position) end
    if c.radius~=nil then number(c.radius,1,128,'radius') end
    local kind=c['until']
    if kind=='ammo_below' then number(c.count,1,1000,'count') end
    if kind=='health_below' or kind=='health_above' then number(c.fraction,0,1,'fraction') end
    if kind=='item_count' then
      assert(type(c.item)=='string' and prototypes.item[c.item],'item_count requires a known item')
      assert(c.at_least~=nil or c.below~=nil,'item_count requires at_least or below')
      if c.at_least~=nil then number(c.at_least,0,1e9,'at_least') end
      if c.below~=nil then number(c.below,1,1e9,'below') end
      if c.positions~=nil then
        assert(type(c.positions)=='table' and #c.positions>=1 and #c.positions<=64,'item_count positions takes 1..64 {x,y} (chests)')
        for _,pos in ipairs(c.positions) do api.position(pos) end
      end
    end
    if kind=='researched' then assert(type(c.technology)=='string','researched requires technology') end
    if kind=='ghosts_waiting' and c.at_least~=nil then number(c.at_least,1,100000,'at_least') end
    if kind=='damaged' and c.fraction~=nil then number(c.fraction,0.01,1,'fraction') end
    if kind=='fuel_below' then number(c.count,1,1000,'count') end
    return c
  end
  function M.check(p,c)
    if c['until']=='researched' then assert(p.force.technologies[c.technology],'unknown technology') end
    return checks[c['until']](p,c)
  end
  M.names=NAMES
  return M
end
