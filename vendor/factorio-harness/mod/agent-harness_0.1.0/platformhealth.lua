-- Current HP, never accumulated impact damage. The shared damage-event set is
-- seeded once; healed entities leave it and another impact puts them back.
return function(api)
  local M={}
  local initialized={}
  local function health(e)
    if not e.valid or e.type=='character' or e.type=='entity-ghost' or e.type=='tile-ghost' then return end
    local h,m=e.health,e.max_health
    if h and m and m>0 then return h,m end
  end
  function M.check(pl,c,record)
    local holder=record or c
    holder.evidence=nil
    assert(pl.surface,'platform '..pl.name..' has no surface yet')
    local candidates={}
    if c.positions then
      for _,raw in ipairs(c.positions) do
        local pos=api.position(raw)
        local found=pl.surface.find_entities_filtered{position=pos,force=pl.force,limit=65}
        assert(#found<=64,'damaged position overlaps more than 64 entities')
        local any=false
        for _,e in ipairs(found) do
          local h=health(e)
          if h then candidates[e.unit_number or e]=e; any=true end
        end
        assert(any,string.format('damaged: no entity of ours with health at (%g,%g) on %s',pos.x,pos.y,pl.name))
      end
    else
      local dm=api.damaged(pl)
      if not initialized[pl.index] or not dm.seeded then
        -- Bounded cold start (also after an overflow); subsequent checks only
        -- read the event set. Never silently qualify a partial hull as healthy.
        local found=pl.surface.find_entities_filtered{force=pl.force,limit=32769}
        assert(#found<=32768,'damaged whole-hull initialization exceeds 32768 entities; use positions')
        local hurt={}
        for _,e in ipairs(found) do
          local h,m=health(e)
          if h and h<m then hurt[#hurt+1]=e end
        end
        api.seed(pl,hurt)
        dm=api.damaged(pl)
        assert(dm.seeded,'damaged entity set overflow; use positions')
        initialized[pl.index]=true
      end
      candidates=dm.set
    end
    local rows,gone={},{}
    local lt,rb
    if c.area then lt=api.position(c.area.left_top or c.area[1]); rb=api.position(c.area.right_bottom or c.area[2]) end
    local fraction=c.fraction or (not c.hp and 1 or nil)
    for u,e in pairs(candidates) do
      local h,m=health(e)
      if not h or h>=m then
        if not c.positions then gone[#gone+1]=u end
      elseif (fraction and h/m<fraction) or (c.hp and h<c.hp) then
        local pos=e.position
        if not lt or (pos.x>=lt.x and pos.x<rb.x and pos.y>=lt.y and pos.y<rb.y) then
          rows[#rows+1]={health=h,max_health=m,name=e.name,unit_number=e.unit_number,
            position={x=pos.x,y=pos.y},fraction=h/m}
        end
      end
    end
    if #gone>0 then api.forget(pl,gone) end
    table.sort(rows,function(a,b)
      local av,bv=fraction and a.fraction or a.health,fraction and b.fraction or b.health
      if av~=bv then return av<bv end
      if a.health~=b.health then return a.health<b.health end
      return (a.unit_number or 0)<(b.unit_number or 0)
    end)
    local count=#rows
    while #rows>10 do rows[#rows]=nil end
    local evidence={platform=pl.name,read_tick=game.tick,count=count,entities=rows}
    holder.evidence={platform_health=evidence}
    local parts={}
    for _,r in ipairs(rows) do parts[#parts+1]=string.format('%s unit %s (%g,%g) health %.17g/%.17g',
      r.name,tostring(r.unit_number),r.position.x,r.position.y,r.health,r.max_health) end
    return count>0,string.format('platform %s: %d damaged below threshold; read_tick %d%s',pl.name,count,game.tick,
      #parts>0 and '; '..table.concat(parts,'; ') or '')
  end
  return M
end
