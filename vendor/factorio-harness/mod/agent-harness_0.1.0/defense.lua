-- The `defense` read: the team's built-up areas (its buildings grouped by
-- touching 32-tile cells, so an outpost or a pipeline is an area of its own),
-- the turrets whose range reaches each with their ammo, the parts no turret
-- reaches, and charted enemy nests near our buildings with whether pollution
-- reaches them. One force-wide scan when called, cached for 10 s in storage
-- and shared by the force's agents; output capped. Nothing runs per tick.
return function(api)
  local M={handlers={},schema={}}
  local CELL,CACHE_TICKS,MAX_AREAS,MAX_GAPS,MAX_TURRETS,MAX_NESTS,NEST_RANGE,LOW_AMMO=32,600,12,3,6,8,256,10
  -- Mobile or transient entities of the force are not buildings.
  local SKIP={character=true,car=true,['spider-vehicle']=true,locomotive=true,['cargo-wagon']=true,['fluid-wagon']=true,
    ['artillery-wagon']=true,['entity-ghost']=true,['tile-ghost']=true,['construction-robot']=true,['logistic-robot']=true,
    ['combat-robot']=true,['character-corpse']=true,projectile=true,stream=true,fire=true,sticker=true,beam=true,
    ['artillery-projectile']=true,['smoke-with-trigger']=true,['highlight-box']=true,['speech-bubble']=true,['item-request-proxy']=true,
    ['entity-ghost-proxy']=true,['spider-leg']=true,['spider-unit']=true,unit=true,['asteroid']=true}
  -- Turrets that shoot biters near them (artillery is listed apart).
  local GUARD={['ammo-turret']=true,['electric-turret']=true,['fluid-turret']=true}
  local names={'N','NE','E','SE','S','SW','W','NW'}
  local function compass(from,to)
    local angle=(math.atan2 or math.atan)(to.x-from.x,-(to.y-from.y))
    return names[math.floor(angle/(math.pi/4)+0.5)%8+1]
  end
  local function round(v) return math.floor(v+0.5) end
  local function dist(a,b) return ((a.x-b.x)^2+(a.y-b.y)^2)^0.5 end
  local function cell_of(pos) return math.floor(pos.x/CELL),math.floor(pos.y/CELL) end
  local function counted(t,max)
    local list={}
    for name,n in pairs(t) do list[#list+1]={name,n} end
    table.sort(list,function(a,b) return a[2]>b[2] or a[2]==b[2] and a[1]<b[1] end)
    for i,v in ipairs(list) do list[i]=v[2]..' '..v[1] end
    while #list>max do table.remove(list) end
    return table.concat(list,', ')
  end
  local function box_text(b) return string.format('(%d,%d)-(%d,%d)',math.floor(b[1]),math.floor(b[2]),math.ceil(b[3]),math.ceil(b[4])) end
  local function grow(b,pos)
    if not b[1] then b[1],b[2],b[3],b[4]=pos.x,pos.y,pos.x,pos.y; return end
    b[1],b[2],b[3],b[4]=math.min(b[1],pos.x),math.min(b[2],pos.y),math.max(b[3],pos.x),math.max(b[4],pos.y)
  end
  local ranges={}
  local function range(e)
    local r=ranges[e.name]
    if not r then
      local ok,v=pcall(function() local proto=e.prototype; return proto.turret_range or (proto.attack_parameters and proto.attack_parameters.range) end)
      r=ok and type(v)=='number' and v or 18
      ranges[e.name]=r
    end
    return r
  end
  local function ammo(e)
    if e.type=='ammo-turret' then
      local inv=e.get_inventory(defines.inventory.turret_ammo)
      return inv and inv.get_item_count() or 0
    elseif e.type=='artillery-turret' then
      local inv=e.get_inventory(defines.inventory.artillery_turret_ammo)
      return inv and inv.get_item_count() or 0
    elseif e.type=='fluid-turret' then
      local ok,f=pcall(function() return e.fluidbox[1] end)
      return ok and f and round(f.amount) or 0
    end
    return nil
  end
  -- Connected groups of cell keys (8 neighbours) among `cells` (key -> {cx,cy}).
  local function components(cells)
    local seen,out={},{}
    for key,c in pairs(cells) do
      if not seen[key] then
        local group,stack={},{key}
        seen[key]=true
        while #stack>0 do
          local k=table.remove(stack)
          group[#group+1]=k
          local cx,cy=cells[k].cx,cells[k].cy
          for dx=-1,1 do for dy=-1,1 do
            local n=(cx+dx)..','..(cy+dy)
            if cells[n] and not seen[n] then seen[n]=true; stack[#stack+1]=n end
          end end
        end
        table.sort(group)
        out[#out+1]=group
      end
    end
    return out
  end

  local function scan(p)
    local s,force=p.surface,p.force
    local cells,turrets,artillery={},{},{}
    local tcells={}
    local maxr=0
    for _,e in pairs(s.find_entities_filtered{force=force}) do
      if e.valid and not SKIP[e.type] then
        local cx,cy=cell_of(e.position)
        local key=cx..','..cy
        local c=cells[key]
        if not c then c={cx=cx,cy=cy,list={}}; cells[key]=c end
        c.list[#c.list+1]={x=e.position.x,y=e.position.y,name=e.name}
        if GUARD[e.type] then
          local t={name=e.name,position={x=e.position.x,y=e.position.y},range=range(e),ammo=ammo(e),type=e.type}
          turrets[#turrets+1]=t
          maxr=math.max(maxr,t.range)
          tcells[key]=tcells[key] or {}; table.insert(tcells[key],t)
        elseif e.type=='artillery-turret' then
          artillery[#artillery+1]={name=e.name,position={x=e.position.x,y=e.position.y},ammo=ammo(e)}
        end
      end
    end
    -- Coverage: each building's centre against the turrets in nearby cells.
    local reach=math.ceil(maxr/CELL)
    for _,c in pairs(cells) do
      for _,b in ipairs(c.list) do
        local n=0
        for dx=-reach,reach do for dy=-reach,reach do
          for _,t in ipairs(tcells[(c.cx+dx)..','..(c.cy+dy)] or {}) do
            if dist(t.position,b)<=t.range then n=n+1; t.covers=true; t.hit=t.hit or {}; t.hit[c] =true end
          end
        end end
        b.cover=n
      end
    end
    -- Areas: groups of touching cells.
    local areas={}
    for _,group in ipairs(components(cells)) do
      local a={box={},kinds={},buildings=0,covered=0,single=0,turrets={},sx=0,sy=0,cells={}}
      local gaps={}
      for _,key in ipairs(group) do
        local c=cells[key]
        a.cells[c]=true
        for _,b in ipairs(c.list) do
          a.buildings=a.buildings+1; a.sx=a.sx+b.x; a.sy=a.sy+b.y
          grow(a.box,b); a.kinds[b.name]=(a.kinds[b.name] or 0)+1
          if b.cover>0 then a.covered=a.covered+1; if b.cover==1 then a.single=a.single+1 end
          else
            local g=gaps[key]
            if not g then g={cx=c.cx,cy=c.cy,list={}}; gaps[key]=g end
            g.list[#g.list+1]=b
          end
        end
      end
      for _,t in ipairs(turrets) do
        if t.hit then for c in pairs(t.hit) do if a.cells[c] then a.turrets[#a.turrets+1]=t; break end end end
      end
      -- The uncovered parts: touching cells holding uncovered buildings.
      a.gaps={}
      for _,g in ipairs(components(gaps)) do
        local gap={box={},kinds={},buildings=0}
        for _,key in ipairs(g) do
          for _,b in ipairs(gaps[key].list) do gap.buildings=gap.buildings+1; grow(gap.box,b); gap.kinds[b.name]=(gap.kinds[b.name] or 0)+1 end
        end
        a.gaps[#a.gaps+1]=gap
      end
      table.sort(a.gaps,function(x,y) return x.buildings>y.buildings end)
      a.centre={x=round(a.sx/a.buildings),y=round(a.sy/a.buildings)}
      a.group=group
      areas[#areas+1]=a
    end
    table.sort(areas,function(x,y) return x.buildings>y.buildings end)
    -- Nests: charted spawners and worms near our buildings, grouped within 64 tiles.
    local nests={}
    local all={}
    for _,a in ipairs(areas) do if a.box[1] then grow(all,{x=a.box[1],y=a.box[2]}); grow(all,{x=a.box[3],y=a.box[4]}) end end
    if all[1] then
      local found=s.find_entities_filtered{area={{all[1]-NEST_RANGE,all[2]-NEST_RANGE},{all[3]+NEST_RANGE,all[4]+NEST_RANGE}},type={'unit-spawner','turret'},force='enemy'}
      for _,e in pairs(found) do
        if e.valid and force.is_chunk_charted(s,{x=math.floor(e.position.x/32),y=math.floor(e.position.y/32)}) then
          local nest
          for _,n in ipairs(nests) do if dist(n.first,e.position)<=64 then nest=n; break end end
          if not nest then nest={first=e.position,sx=0,sy=0,spawners=0,worms=0,polluted=false}; nests[#nests+1]=nest end
          if e.type=='unit-spawner' then
            nest.spawners=nest.spawners+1; nest.sx=nest.sx+e.position.x; nest.sy=nest.sy+e.position.y
            if s.get_pollution(e.position)>0 then nest.polluted=true end
          else nest.worms=nest.worms+1 end
        end
      end
    end
    local kept={}
    for _,n in ipairs(nests) do
      if n.spawners>0 then
        n.position={x=round(n.sx/n.spawners),y=round(n.sy/n.spawners)}
        -- The nearest building: cells by centre first, then the buildings of the closest few.
        local best,bd,barea
        local cutoff
        for _,a in ipairs(areas) do
          for c in pairs(a.cells) do
            local d=dist(n.position,{x=c.cx*CELL+16,y=c.cy*CELL+16})
            if not cutoff or d<cutoff then cutoff=d end
          end
        end
        for ai,a in ipairs(areas) do
          for c in pairs(a.cells) do
            if dist(n.position,{x=c.cx*CELL+16,y=c.cy*CELL+16})<=cutoff+46 then
              for _,b in ipairs(c.list) do
                local d=dist(n.position,b)
                if not bd or d<bd then best,bd,barea=b,d,ai end
              end
            end
          end
        end
        if bd and bd<=NEST_RANGE then
          kept[#kept+1]={position=n.position,spawners=n.spawners,worms=n.worms,pollution_reaches=n.polluted,distance=round(bd),
            bearing=compass(best,n.position),nearest_building={name=best.name,position={x=round(best.x),y=round(best.y)}},area=barea}
        end
      end
    end
    table.sort(kept,function(x,y) return x.distance<y.distance end)
    return areas,kept,artillery,#turrets
  end

  local function area_out(i,a)
    local list,ammo_total,empty,low={},0,0,0
    table.sort(a.turrets,function(x,y) return (x.ammo or math.huge)<(y.ammo or math.huge) end)
    for _,t in ipairs(a.turrets) do
      if t.ammo then
        ammo_total=ammo_total+t.ammo
        if t.ammo==0 then empty=empty+1 elseif t.type=='ammo-turret' and t.ammo<LOW_AMMO then low=low+1 end
      end
      if #list<MAX_TURRETS then list[#list+1]={name=t.name,position={x=t.position.x,y=t.position.y},ammo=t.ammo} end
    end
    local gaps={}
    for k,g in ipairs(a.gaps) do
      if k>MAX_GAPS then break end
      gaps[k]={box=box_text(g.box),buildings=g.buildings,kinds=counted(g.kinds,4)}
    end
    local uncovered=a.buildings-a.covered
    local line=string.format('area %d around (%d,%d) %s: %d buildings (%s); %s',i,a.centre.x,a.centre.y,box_text(a.box),a.buildings,counted(a.kinds,3),
      #a.turrets==0 and 'no turret in range' or string.format('%d turret%s in range (%d ammo%s%s)',#a.turrets,#a.turrets==1 and '' or 's',ammo_total,
        empty>0 and ', '..empty..' empty' or '',low>0 and ', '..low..' low' or ''))
    if #a.turrets>0 then
      line=line..string.format('; %d buildings covered (%d by one turret only), %d not',a.covered,a.single,uncovered)
      if gaps[1] then line=line..string.format('; largest uncovered part %s: %d buildings (%s)',gaps[1].box,gaps[1].buildings,gaps[1].kinds) end
    end
    return {area=i,line=line,centre=a.centre,box=box_text(a.box),buildings=a.buildings,kinds=counted(a.kinds,5),
      turrets=#a.turrets,ammo=ammo_total,empty=empty>0 and empty or nil,low=low>0 and low or nil,turret_list=list[1] and list or nil,
      covered=a.covered,covered_once=a.single,uncovered=uncovered,uncovered_parts=gaps[1] and gaps or nil}
  end

  function M.handlers.defense(p,a)
    a=a or {}
    local limit=math.max(1,math.min(30,math.floor(tonumber(a.limit) or MAX_AREAS)))
    local st=api.state()
    st.defense_cache=st.defense_cache or {}
    local key=p.force.name..'@'..p.surface.index
    local entry=st.defense_cache[key]
    if not entry or game.tick-entry.tick>=CACHE_TICKS or entry.limit~=limit then
      local areas,nests,artillery,turret_count=scan(p)
      local out,uncovered={},{}
      local rest={areas=0,buildings=0,no_turret=0}
      for i,area in ipairs(areas) do
        if i<=limit then out[#out+1]=area_out(i,area)
        else rest.areas=rest.areas+1; rest.buildings=rest.buildings+area.buildings; if #area.turrets==0 then rest.no_turret=rest.no_turret+1 end end
        if #area.turrets==0 then uncovered[#uncovered+1]=i end
      end
      while #nests>MAX_NESTS do table.remove(nests) end
      for _,n in ipairs(nests) do
        n.line=string.format('nest (%d,%d) %d spawner%s, %d worm%s: %d tiles %s of %s at (%d,%d) (area %d); pollution %s',n.position.x,n.position.y,
          n.spawners,n.spawners==1 and '' or 's',n.worms,n.worms==1 and '' or 's',n.distance,n.bearing,n.nearest_building.name,
          n.nearest_building.position.x,n.nearest_building.position.y,n.area,n.pollution_reaches and 'reaches it' or 'does not reach it')
      end
      entry={tick=game.tick,limit=limit,result={areas=out,areas_without_turrets=uncovered[1] and uncovered or nil,
        more=rest.areas>0 and string.format('+%d smaller areas with %d buildings (%d with no turret in range): limit raises the count',rest.areas,rest.buildings,rest.no_turret) or nil,
        nests=nests[1] and nests or nil,turrets=turret_count,artillery=artillery[1] and artillery or nil}}
      st.defense_cache[key]=entry
    end
    local r={}
    for k,v in pairs(entry.result) do r[k]=v end
    r.as_of=entry.tick<game.tick and entry.tick or nil
    r.tick=game.tick
    return r
  end
  M.schema.defense={limit='optional: areas listed in full (default '..MAX_AREAS..', max 30)',
    returns='read, cached 10 s: areas [{area, line, centre, box, buildings, kinds, turrets, ammo, empty, low, turret_list, covered, covered_once, uncovered, '
    ..'uncovered_parts [{box, buildings, kinds}]}]: the team\'s buildings grouped by touching 32-tile cells (outposts and pipelines are areas of their own), '
    ..'largest first; a building counts as covered when its centre is within range of a gun, laser or flamethrower turret. areas_without_turrets: area numbers; '
    ..'nests [{line, position, spawners, worms, distance, bearing, nearest_building, area, pollution_reaches}]: charted spawner groups within '..NEST_RANGE
    ..' tiles of our buildings, nearest first; artillery; more'}
  return M
end
