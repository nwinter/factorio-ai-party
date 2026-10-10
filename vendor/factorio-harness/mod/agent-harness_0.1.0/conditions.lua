-- World predicates for plan waits and guards. Each reads only what the player
-- could see: enemy structures on the chart, units in visible chunks, our own
-- turrets, the character's health and inventory.
return function(api)
  local M={}
  local ENEMY_STRUCTURES={'unit-spawner','turret'}
  local OUR_TURRETS={'ammo-turret','electric-turret','fluid-turret','artillery-turret'}
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
      local n=enemies(p,c,{'unit-spawner','turret','unit'}); return n==0,n..' enemies'
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
    item_count=function(p,c)
      local n=p.get_main_inventory().get_item_count(c.item)
      local met=(c.at_least==nil or n>=c.at_least) and (c.below==nil or n<c.below)
      return met,c.item..' '..n
    end,
    crafting_done=function(p)
      local n=p.crafting_queue_size; return n==0,n..' crafts queued'
    end,
    researched=function(p,c)
      local t=p.force.technologies[c.technology]; return t.researched,c.technology..(t.researched and ' researched' or ' not researched')
    end,
  }
  local NAMES='no_enemy_structures|no_enemies|turrets_idle|ammo_below|health_below|health_above|item_count|crafting_done|researched'
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
    end
    if kind=='researched' then assert(type(c.technology)=='string','researched requires technology') end
    return c
  end
  function M.check(p,c)
    if c['until']=='researched' then assert(p.force.technologies[c.technology],'unknown technology') end
    return checks[c['until']](p,c)
  end
  M.names=NAMES
  return M
end
