-- Keeping the character alive on the move. Walking actions watch for hostile
-- units (and worms whose range reaches the character) and for falling
-- health; on danger they turn back to the last safe spot on the way while
-- returning fire, then end with outcome `threat`. Guns: the character fires
-- the best loaded gun, not whatever slot happens to be selected.
return function(api)
  local M={}
  local CHECK_TICKS,DEFEND_SCAN,SAFE_MARGIN,RETREAT_TICKS=10,6,8,900
  local AMMO_DAMAGE={['firearm-magazine']=5,['piercing-rounds-magazine']=8,['uranium-rounds-magazine']=24,
    ['shotgun-shell']=60,['piercing-shotgun-shell']=80}
  -- Rockets at close range hurt the character; only used when nothing else is loaded.
  local LAST_RESORT={['rocket-launcher']=true}
  function M.hostile_forces(p)
    local out={}
    for _,force in pairs(game.forces) do
      if force~=p.force and force.name~='neutral' and not p.force.get_friend(force) and not p.force.get_cease_fire(force) then out[#out+1]=force end
    end
    return out
  end
  local function gun_stats(name)
    local ok,params=pcall(function() return prototypes.item[name].attack_parameters end)
    params=ok and params or {}
    return params.cooldown or 30,params.range or 15
  end
  -- Every gun slot holding a gun and ammo, with a damage-per-second score.
  function M.guns(p)
    local guns=p.get_inventory(defines.inventory.character_guns)
    local ammo=p.get_inventory(defines.inventory.character_ammo)
    local out={}
    for i=1,guns and #guns or 0 do
      local g,a=guns[i],ammo and ammo[i]
      if g.valid_for_read then
        local cooldown,range=gun_stats(g.name)
        local loaded=a and a.valid_for_read
        out[#out+1]={index=i,gun=g.name,ammo=loaded and a.name or nil,count=loaded and a.count or 0,range=range,
          score=loaded and (60/math.max(1,cooldown))*(AMMO_DAMAGE[a.name] or 5)*(LAST_RESORT[g.name] and 0.001 or 1) or 0}
      end
    end
    return out
  end
  function M.best_gun(p)
    local best
    for _,g in ipairs(M.guns(p)) do if g.count>0 and (not best or g.score>best.score) then best=g end end
    return best
  end
  -- Selects the best loaded gun; returns it (nil when nothing is loaded).
  function M.arm_best(p)
    local best=M.best_gun(p)
    local c=p.character
    if best and c and c.selected_gun_index~=best.index then c.selected_gun_index=best.index end
    return best
  end
  local function worm_range(e)
    local ok,r=pcall(function() return e.prototype.attack_parameters.range end)
    return ok and r or 20
  end
  -- Hostile units within radius and worms/turrets whose range (+2) reaches pos.
  function M.threats(p,pos,radius)
    local forces=M.hostile_forces(p)
    local out={units={},worms={},spawners={}}
    if #forces==0 then return out end
    for _,e in pairs(p.surface.find_entities_filtered{position=pos,radius=math.max(radius,40),force=forces,type={'unit','turret','unit-spawner'},limit=256}) do
      if e.valid and api.known(p,e) then
        local d=api.distance(pos,e.position)
        if e.type=='unit' and d<=radius and api.visible(p,e.position) then out.units[#out.units+1]={entity=e,distance=d}
        elseif e.type=='turret' and d<=worm_range(e)+2 then out.worms[#out.worms+1]={entity=e,distance=d}
        elseif e.type=='unit-spawner' and d<=radius then out.spawners[#out.spawners+1]={entity=e,distance=d} end
      end
    end
    return out
  end
  local function describe(t)
    local counts,nearest={},nil
    for _,kind in ipairs({'units','worms','spawners'}) do
      for _,r in ipairs(t[kind]) do
        counts[r.entity.name]=(counts[r.entity.name] or 0)+1
        if not nearest or r.distance<nearest.distance then nearest=r end
      end
    end
    local names={}
    for name,n in pairs(counts) do names[#names+1]=n..' '..name end
    table.sort(names)
    return names,nearest
  end
  M.describe=describe
  -- Validates and stores the safety options of a walking action.
  function M.options(a)
    assert(a.unsafe==nil or type(a.unsafe)=='boolean','unsafe must be boolean')
    local radius=a.threat_radius or 16
    assert(type(radius)=='number' and radius>=4 and radius<=32,'threat_radius must be 4..32')
    local health=a.min_health or 0.5
    assert(type(health)=='number' and health>=0 and health<1,'min_health is a fraction 0..1')
    return {unsafe=a.unsafe==true,radius=radius,min_health=health}
  end
  -- Return fire at the nearest hostile unit in range of the best loaded gun,
  -- while walking. An explicit `shoot` owns the trigger instead.
  local function defend(p,action,tick)
    if api.shooting(p) then return end
    if tick>=(action.defend_scan or 0) or (action.defend_target and not action.defend_target.valid) then
      action.defend_scan=tick+DEFEND_SCAN
      action.defend_target=nil
      local gun=M.best_gun(p)
      if gun then
        local t=M.threats(p,p.position,gun.range)
        local best
        for _,r in ipairs(t.units) do if not best or r.distance<best.distance then best=r end end
        if best then M.arm_best(p); action.defend_target=best.entity end
      end
    end
    local target=action.defend_target
    if target and target.valid then
      p.shooting_state={state=defines.shooting.shooting_enemies,position=target.position}
      action.defending=true
    elseif action.defending then
      p.shooting_state={state=defines.shooting.not_shooting,position=p.position}
      action.defending=nil
    end
  end
  -- Called every tick for a walking action. Returns an outcome to finish
  -- with, and whether the retreat took over this tick.
  function M.guard(p,action,tick)
    local opts=action.safety
    if not opts then return nil,false end
    if action.retreat then
      defend(p,action,tick)
      local outcome=api.navigate(p,action.retreat.nav)
      if outcome or tick>=action.retreat.until_tick then return 'threat',true end
      return nil,true
    end
    if not opts.unsafe and tick%CHECK_TICKS==0 then
      local c=p.character
      local t=M.threats(p,p.position,opts.radius)
      local names,nearest=describe(t)
      local health=c.health/c.max_health
      local hurt=health<opts.min_health and (action.last_health or 1)>health
      action.last_health=health
      if #t.units>0 or #t.worms>0 or hurt then
        local pos=p.position
        local safe=action.safe_at
        if not safe or (nearest and api.distance(safe,nearest.entity.position)<opts.radius) then
          -- No safe spot seen yet: straight away from the nearest threat.
          local from=nearest and nearest.entity.position or pos
          local dx,dy=pos.x-from.x,pos.y-from.y
          local d=math.max(0.1,math.sqrt(dx*dx+dy*dy))
          safe={x=pos.x+dx/d*20,y=pos.y+dy/d*20}
        end
        action.threat={enemies=#names>0 and table.concat(names,', ') or nil,
          nearest=nearest and {name=nearest.entity.name,position=nearest.entity.position,distance=math.floor(nearest.distance*10+0.5)/10} or nil,
          health=math.floor(health*100+0.5)..'%',at={x=pos.x,y=pos.y},retreat_to=safe}
        local nav={position=safe,tolerance=1.5,direct=true,max_stalls=6,replans=0,stalled=0,last_position=p.position}
        action.retreat={nav=nav,until_tick=tick+RETREAT_TICKS}
        action.nav=nil
        return nil,true
      end
      -- Remember where it was quiet, a margin beyond the watch radius.
      if #M.threats(p,p.position,opts.radius+SAFE_MARGIN).units==0 then action.safe_at={x=p.position.x,y=p.position.y} end
    end
    defend(p,action,tick)
    return nil,false
  end
  function M.release(p,action)
    if action.defending and p and p.valid and p.character and p.character.valid then
      p.shooting_state={state=defines.shooting.not_shooting,position=p.position}
    end
  end
  -- Status lines: enemies close to the character, and the selected gun.
  function M.status(p,warnings)
    local t=M.threats(p,p.position,30)
    local names,nearest=describe(t)
    if #names>0 then
      table.insert(warnings,1,string.format('ENEMIES within 30 tiles: %s; nearest %s at (%g,%g) %d tiles',table.concat(names,', '),
        nearest.entity.name,nearest.entity.position.x,nearest.entity.position.y,math.floor(nearest.distance+0.5)))
    end
    local c=p.character
    local guns=M.guns(p)
    local selected
    for _,g in ipairs(guns) do if g.index==c.selected_gun_index then selected=g end end
    local best=M.best_gun(p)
    if best and (not selected or selected.count==0) then
      warnings[#warnings+1]=string.format('weapon: selected gun slot %d (%s) has no ammo while slot %d (%s, %s*%d) does; select_gun (or any shoot/walk defence) switches',
        c.selected_gun_index,selected and selected.gun or 'empty',best.index,best.gun,best.ammo,best.count)
    elseif not best and #guns>0 then
      warnings[#warnings+1]='weapon: no gun has ammo'
    end
    return selected and string.format('slot %d: %s%s',selected.index,selected.gun,selected.ammo and ' + '..selected.ammo..'*'..selected.count or ' (no ammo)') or 'slot '..c.selected_gun_index..': empty'
  end
  M.schema={select_gun={slot='1..3 gun slot; default the best loaded gun (damage per second)',returns='selected slot, gun, ammo'}}
  return M
end
