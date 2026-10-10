-- Run-and-gun: walk and shoot in the same tick. Keep the nearest enemy unit
-- inside a distance band, focus structures while units are not close, and
-- stop when the area is clear, health is low, or ammunition runs out.
return function(api)
  local M={}
  local SCAN_EVERY=6
  local structures={['unit-spawner']=true,turret=true}
  local compass={'north','northeast','east','southeast','south','southwest','west','northwest'}
  local function heading(dx,dy)
    local angle=(math.atan2 or math.atan)(dx,-dy)
    return api.directions[compass[math.floor(angle/(math.pi/4)+0.5)%8+1]]
  end
  local function ammo_count(p)
    local inv=p.get_inventory(defines.inventory.character_ammo)
    return inv and inv.get_item_count() or 0
  end
  function M.plan(p,a)
    local band_min,band_max=a.min_distance or 7,a.max_distance or 12
    assert(type(band_min)=='number' and type(band_max)=='number' and band_min>=2 and band_max>band_min and band_max<=30,'need 2 <= min_distance < max_distance <= 30')
    local health=a.min_health or 0.4
    assert(type(health)=='number' and health>=0 and health<1,'min_health is a fraction 0..1')
    local ammo=ammo_count(p)
    assert(ammo>0,'no ammunition equipped')
    return {kind='kite',band_min=band_min,band_max=band_max,min_health=health,
      radius=api.integer(a.radius,32,8,32,'radius'),range=a.range or 14,
      anchor=a.position and api.position(a.position),
      until_tick=game.tick+api.integer(a.ticks,3600,1,36000,'ticks'),
      kills=0,ammo_start=ammo,next_scan=0}
  end
  local function hostile_forces(p)
    local out={}
    for _,force in pairs(game.forces) do
      if force~=p.force and force.name~='neutral' and not p.force.get_friend(force) and not p.force.get_cease_fire(force) then out[#out+1]=force end
    end
    return out
  end
  -- Nearest unit and nearest structure; cached between scans like auto shoot.
  local function scan(p,action)
    action.unit,action.structure=nil,nil
    local forces=hostile_forces(p)
    if #forces==0 then return end
    local du,ds=math.huge,math.huge
    for _,e in pairs(p.surface.find_entities_filtered{position=p.position,radius=action.radius,force=forces,
        type={'unit','unit-spawner','turret'},limit=256}) do
      if e.valid and api.visible(p,e.position) then
        local d=api.distance(p.position,e.position)
        if structures[e.type] then if d<ds then ds,action.structure=d,e end
        elseif d<du then du,action.unit=d,e end
      end
    end
  end
  function M.tick(p,action,tick)
    local c=p.character
    if c.health<action.min_health*c.max_health then return 'low_health' end
    if ammo_count(p)==0 then return 'out_of_ammo' end
    if tick>=action.next_scan or (action.unit and not action.unit.valid) or (action.structure and not action.structure.valid) then
      scan(p,action); action.next_scan=tick+SCAN_EVERY
    end
    local pos=p.position
    local unit=action.unit and action.unit.valid and action.unit or nil
    local structure=action.structure and action.structure.valid and action.structure or nil
    local du=unit and api.distance(pos,unit.position) or math.huge
    local ds=structure and api.distance(pos,structure.position) or math.huge
    local target,walk
    if unit and du<action.band_max+3 then
      target=unit
      -- Too close: back straight away from it while firing.
      if du<action.band_min then walk=heading(pos.x-unit.position.x,pos.y-unit.position.y) end
      -- Units still at the edge of the band: spend the shots on the nest.
      if structure and ds<action.range and du>=action.band_min then target=structure end
    elseif structure then
      if ds<action.range then target=structure end
      if ds>action.band_max and not (unit and du<action.band_max+8) then
        walk=heading(structure.position.x-pos.x,structure.position.y-pos.y)
      end
    elseif unit then
      -- Distant units only: wait for them to come into the band.
    elseif action.anchor and api.distance(pos,action.anchor)>4 then
      walk=heading(action.anchor.x-pos.x,action.anchor.y-pos.y)
    else
      return 'clear'
    end
    action.target=target and {name=target.name,position=target.position} or nil
    p.shooting_state=target and {state=defines.shooting.shooting_enemies,position=target.position}
      or {state=defines.shooting.not_shooting,position=pos}
    p.walking_state=walk and {walking=true,direction=walk} or {walking=false,direction=defines.direction.north}
  end
  function M.ammo_used(p,action) return math.max(0,action.ammo_start-ammo_count(p)) end
  return M
end
