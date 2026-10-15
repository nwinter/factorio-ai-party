-- Recheck recorded egg sites locally. A timer is history, never proof of a hatch.
return function(api)
  local M={}
  local function d(a,b) return ((a.x-b.x)^2+(a.y-b.y)^2)^0.5 end
  local function at(p) return string.format('(%g,%g)',p.x,p.y) end
  local function seen(p,pos)
    return d(p.position,pos)<=32 or p.force.is_chunk_visible(p.surface,{x=math.floor(pos.x/32),y=math.floor(pos.y/32)})
  end
  function M.read(p,sites)
    if not (p.position and p.surface and p.force) then return nil end
    local near,keys={},{}
    for _,s in ipairs(sites) do
      local key=s.surface..'|'..at(s.position)
      if s.surface==p.surface.name and s.tick>=game.tick-36000 and s.tick<=game.tick+18000 and
        d(p.position,s.position)<=64 and seen(p,s.position) and not keys[key] then
        keys[key]=true;near[#near+1]=s
      end
    end
    table.sort(near,function(a,b) return d(p.position,a.position)<d(p.position,b.position) end)
    local out={}
    for i=1,math.min(3,#near) do
      local s=near[i]
      local enemies=p.surface.find_entities_filtered{position=s.position,radius=16,force='enemy',type={'unit','spider-unit','segmented-unit'},limit=33}
      local count,names=0,{}
      for _,e in ipairs(enemies) do
        if e.valid and seen(p,e.position) then count=count+1;names[e.name]=true end
      end
      local kinds={};for name in pairs(names) do kinds[#kinds+1]=name end;table.sort(kinds)
      local guns=p.surface.find_entities_filtered{position=s.position,radius=64,force=p.force,name='gun-turret',limit=65}
      local cover={}
      for _,e in ipairs(guns) do
        if e.valid and seen(p,e.position) then
          local proto=e.prototype
          local range=proto.turret_range or (proto.attack_parameters and proto.attack_parameters.range) or 18
          if d(e.position,s.position)<=range then
            local inv=e.get_inventory(defines.inventory.turret_ammo)
            cover[#cover+1]=string.format('%s %s ammo %d%s',e.name,at(e.position),inv and inv.get_item_count() or 0,e.active==false and ' inactive' or '')
          end
        end
      end
      table.sort(cover)
      local elapsed=game.tick>=s.tick
      local timing=elapsed and string.format('recorded first-hatch timer elapsed %ds ago',math.floor((game.tick-s.tick)/60))
        or string.format('recorded first-hatch timer in %ds',math.ceil((s.tick-game.tick)/60))
      out[#out+1]=string.format('egg site %s: %s; %s; gun range covering the spot: %s%s; checked tick %d',at(s.position),
        count>0 and string.format('%d%s enemies visible within 16 tiles now (%s)',count,#enemies==33 and '+' or '',table.concat(kinds,', '))
          or 'no enemies visible within 16 tiles now',timing,
        #cover>0 and table.concat(cover,'; ') or 'none among visible guns within 64 tiles',#guns==65 and ' (gun read capped at 65)' or '',game.tick)
    end
    return #out>0 and out or nil
  end
  return M
end
