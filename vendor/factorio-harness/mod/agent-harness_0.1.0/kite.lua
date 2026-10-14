-- Run-and-gun: walk and shoot in the same tick. Keep the nearest enemy unit
-- inside a distance band, focus structures while units are not close, and
-- stop when the area is clear, health is low, or ammunition runs out. With a
-- retreat point, low health or no ammunition walks there instead (firing at
-- units on the way while ammunition lasts) and ends retreated on arrival
-- (request #57: a bot stopped among biters with ammunition unused). Every end
-- says why (action.why).
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
  M.ammo_count=ammo_count
  -- Stronger ammo first when several kinds are carried.
  local AMMO_RANK={['uranium-rounds-magazine']=3,['piercing-rounds-magazine']=2,['firearm-magazine']=1}
  -- With nothing in the ammo slots, carried ammo goes into them: a carried
  -- gun first into an empty gun slot, then per gun the first carried ammo
  -- stack its slot accepts (the engine's own check in swap_stack). Returns
  -- what was moved as one line, or nil when nothing was.
  function M.auto_equip(p)
    local ok,res=pcall(function()
      local guns=p.get_inventory(defines.inventory.character_guns)
      local ammo=p.get_inventory(defines.inventory.character_ammo)
      local main=p.get_main_inventory()
      if not (guns and ammo and main) or ammo.get_item_count()>0 then return nil end
      local function carried(kind)
        local out={}
        for k,v in pairs(main.get_contents()) do
          local name=type(v)=='table' and v.name or k
          local proto=prototypes.item[name]
          if proto and proto.type==kind then out[#out+1]=name end
        end
        table.sort(out,function(x,y) return (AMMO_RANK[x] or 0)>(AMMO_RANK[y] or 0) or (AMMO_RANK[x] or 0)==(AMMO_RANK[y] or 0) and x<y end)
        return out
      end
      local moved={}
      for i=1,#guns do
        if not guns[i].valid_for_read then
          for _,name in ipairs(carried('gun')) do
            local stack=main.find_item_stack(name)
            if stack and guns[i].swap_stack(stack) then moved[#moved+1]=name..' to gun slot '..i; break end
          end
        end
        if guns[i].valid_for_read and not ammo[i].valid_for_read then
          for _,name in ipairs(carried('ammo')) do
            local stack=main.find_item_stack(name)
            local count=stack and stack.count
            if stack and ammo[i].swap_stack(stack) then moved[#moved+1]=count..' '..name..' to ammo slot '..i; break end
          end
        end
      end
      return #moved>0 and 'equipped from your inventory: '..table.concat(moved,', ') or nil
    end)
    return ok and res or nil
  end
  -- Mid-fight: slots run dry while ammo is carried. Refills them, counts the
  -- refill into ammo_start (so ammo_used stays whole magazines spent), and
  -- returns true; false when nothing could be equipped.
  function M.reload(p,action)
    local note=M.auto_equip(p)
    if not note then return false end
    action.ammo_start=action.ammo_start+ammo_count(p)
    action.reloads=(action.reloads or 0)+1
    action.equipped=note
    return true
  end
  function M.plan(p,a)
    local band_min,band_max=a.min_distance or 7,a.max_distance or 12
    assert(type(band_min)=='number' and type(band_max)=='number' and band_min>=2 and band_max>band_min and band_max<=30,'need 2 <= min_distance < max_distance <= 30')
    local health=a.min_health or 0.4
    assert(type(health)=='number' and health>=0 and health<1,'min_health is a fraction 0..1')
    local equipped=ammo_count(p)==0 and M.auto_equip(p) or nil
    local ammo=ammo_count(p)
    assert(ammo>0,'no ammunition equipped, and none carried that fits a gun (craft firearm-magazine)')
    return {kind='kite',equipped=equipped,band_min=band_min,band_max=band_max,min_health=health,
      radius=api.integer(a.radius,32,8,32,'radius'),range=a.range or 14,
      anchor=a.position and api.position(a.position),retreat=a.retreat and api.position(a.retreat),
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
    local du,ds,seen=math.huge,math.huge,0
    for _,e in pairs(p.surface.find_entities_filtered{position=p.position,radius=action.radius,force=forces,
        type={'unit','spider-unit','segmented-unit','unit-spawner','turret'},limit=256}) do
      if e.valid and api.visible(p,e.position) then
        seen=seen+1
        local d=api.distance(p.position,e.position)
        if structures[e.type] then if d<ds then ds,action.structure=d,e end
        elseif d<du then du,action.unit=d,e end
      end
    end
    action.seen=seen
  end
  -- Retreating: walk straight to the retreat point, firing at the nearest
  -- unit in reach while any ammunition is left.
  local function retreat_step(p,action,tick)
    local pos=p.position
    if api.distance(pos,action.retreat)<=3 then return 'retreated' end
    if tick>=action.next_scan or (action.unit and not action.unit.valid) then scan(p,action); action.next_scan=tick+SCAN_EVERY end
    local unit=action.unit and action.unit.valid and action.unit or nil
    local shoot=unit and ammo_count(p)>0 and api.distance(pos,unit.position)<action.band_max+3
    action.target=shoot and {name=unit.name,position=unit.position} or nil
    p.shooting_state=shoot and {state=defines.shooting.shooting_enemies,position=unit.position}
      or {state=defines.shooting.not_shooting,position=pos}
    p.walking_state={walking=true,direction=heading(action.retreat.x-pos.x,action.retreat.y-pos.y)}
  end
  function M.tick(p,action,tick)
    local c=p.character
    if action.retreating then return retreat_step(p,action,tick) end
    local stop
    if c.health<action.min_health*c.max_health then
      stop='low_health'
      action.why=string.format('health %d%% fell below min_health %d%%',math.floor(c.health/c.max_health*100),math.floor(action.min_health*100))
    elseif ammo_count(p)==0 and not M.reload(p,action) then
      stop='out_of_ammo'; action.why='out of ammunition'
    end
    if stop then
      scan(p,action); action.next_scan=tick+SCAN_EVERY -- what is left, for the reply
      if not action.retreat then return stop end
      action.retreating=stop
      action.why=action.why..string.format('; retreating to (%g,%g)',action.retreat.x,action.retreat.y)
      return retreat_step(p,action,tick)
    end
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
      action.why='no enemies left within the scan radius'
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
