-- The `defense` read: the team's built-up areas, the turrets whose range
-- reaches each with their ammo and flamer oil, the parts no turret reaches,
-- and charted enemy nests near our buildings with whether pollution reaches
-- them. Areas are clusters of buildings by 32-tile cells: belts, pipes, poles,
-- walls, rails and turrets link cells but do not join two clusters (shift 6:
-- they joined the whole base into one 420 by 1,000 tile area), so an outpost is
-- its own area and a pipeline or belt between clusters is a line; a cluster
-- wider than 128 tiles is split into 128-tile blocks. One force-wide scan when
-- called, cached for 10 s in storage and shared by the force's agents; output
-- capped. Nothing runs per tick.
--
-- The `flamers` read: each flamethrower turret's oil and our own buildings
-- inside its arc that fire can burn (the friendly-fire risk: shift 5-6 lost a
-- pipe row in front of the southeast flamers 8 times).
local flameroil=require('flameroil')
return function(api)
  local M={handlers={},schema={}}
  local CELL,BLOCK,CACHE_TICKS,MAX_AREAS,MAX_GAPS,MAX_TURRETS,MAX_NESTS,AREA_NESTS,NEST_RANGE,LOW_AMMO,LOW_OIL=32,4,600,16,3,6,8,3,256,10,0.25
  local MAX_FLAMERS,FIRE_MARGIN=12,3
  -- Mobile or transient entities of the force are not buildings.
  local SKIP={character=true,car=true,['spider-vehicle']=true,locomotive=true,['cargo-wagon']=true,['fluid-wagon']=true,
    ['artillery-wagon']=true,['entity-ghost']=true,['tile-ghost']=true,['construction-robot']=true,['logistic-robot']=true,
    ['combat-robot']=true,['character-corpse']=true,projectile=true,stream=true,fire=true,sticker=true,beam=true,
    ['artillery-projectile']=true,['smoke-with-trigger']=true,['highlight-box']=true,['speech-bubble']=true,['item-request-proxy']=true,
    ['entity-ghost-proxy']=true,['spider-leg']=true,['spider-unit']=true,unit=true,['asteroid']=true}
  -- Turrets that shoot biters near them (artillery is listed apart).
  local GUARD={['ammo-turret']=true,['electric-turret']=true,['fluid-turret']=true}
  -- Links: they connect cells of one cluster but never join two clusters.
  local LINK={['transport-belt']=true,['underground-belt']=true,splitter=true,loader=true,['loader-1x1']=true,['lane-splitter']=true,
    pipe=true,['pipe-to-ground']=true,pump=true,['electric-pole']=true,wall=true,gate=true,lamp=true,['power-switch']=true,
    ['straight-rail']=true,['curved-rail-a']=true,['curved-rail-b']=true,['half-diagonal-rail']=true,['legacy-straight-rail']=true,
    ['legacy-curved-rail']=true,['elevated-straight-rail']=true,['elevated-curved-rail-a']=true,['elevated-curved-rail-b']=true,
    ['elevated-half-diagonal-rail']=true,['rail-ramp']=true,['rail-support']=true,['rail-signal']=true,['rail-chain-signal']=true,
    ['ammo-turret']=true,['electric-turret']=true,['fluid-turret']=true,['artillery-turret']=true,['land-mine']=true}
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
  local function ago(ticks)
    local m=math.floor(ticks/3600)
    return m<1 and math.floor(ticks/60)..'s ago' or m..'m ago'
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
  -- A flamer's oil: all it holds, its own buffer too, of the fluids it fires, and its fluidboxes' volume plus that
  -- buffer (flameroil.lua; not get_capacity, which in 2.0 is the whole connected segment's: 66700 on a flamer line,
  -- shift07 15:31; nor fluidbox[1] alone, empty once the line drains while the buffer still fires, shift11 16:36).
  local function oil(e)
    local ok,amount,cap,fluid=pcall(flameroil.read,e)
    if not ok then return 0,nil end
    return amount or 0,cap,fluid
  end
  local function ammo(e)
    if e.type=='ammo-turret' then
      local inv=e.get_inventory(defines.inventory.turret_ammo)
      return inv and inv.get_item_count() or 0
    elseif e.type=='artillery-turret' then
      local inv=e.get_inventory(defines.inventory.artillery_turret_ammo)
      return inv and inv.get_item_count() or 0
    elseif e.type=='fluid-turret' then
      return round((oil(e)))
    end
    return nil
  end
  -- Whether pollution reaches a spawner: the memory status and the news use
  -- (threat.lua: one reading at the cloud's edge flickers), else one reading.
  local function polluted(s,pos)
    if api.polluted then
      local amount,last=api.polluted(s,pos)
      return api.reached(last),last,amount
    end
    local amount=s.get_pollution(pos)
    return amount>0,amount>0 and game.tick or nil,amount
  end
  -- Connected groups of cell keys (8 neighbours) among `cells` (key -> {cx,cy}).
  local function components(cells)
    local seen,out={},{}
    local keys={}
    for key in pairs(cells) do keys[#keys+1]=key end
    table.sort(keys)
    for _,key in ipairs(keys) do
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
  -- Clusters: anchor cells (any building that is not a link) grouped by touch;
  -- a link-only cell beside a cluster belongs to it; other link-only cells
  -- form lines. A cluster over BLOCK cells wide or tall is split into blocks.
  local function groups_of(cells)
    local anchors,links={},{}
    for key,c in pairs(cells) do if c.anchor then anchors[key]=c else links[key]=c end end
    local comps,comp_of={},{}
    for ci,g in ipairs(components(anchors)) do comps[ci]=g; for _,k in ipairs(g) do comp_of[k]=ci end end
    local loose,joined={},{}
    for key,c in pairs(links) do
      local ci
      for dx=-1,1 do for dy=-1,1 do ci=ci or comp_of[(c.cx+dx)..','..(c.cy+dy)] end end
      if ci then joined[#joined+1]={ci,key} else loose[key]=c end
    end
    table.sort(joined,function(a,b) return a[2]<b[2] end)
    for _,j in ipairs(joined) do table.insert(comps[j[1]],j[2]) end
    local out={}
    for _,g in ipairs(comps) do
      local x0,y0,x1,y1
      for _,k in ipairs(g) do
        local c=cells[k]
        x0,y0=math.min(x0 or c.cx,c.cx),math.min(y0 or c.cy,c.cy); x1,y1=math.max(x1 or c.cx,c.cx),math.max(y1 or c.cy,c.cy)
      end
      if x1-x0+1>BLOCK or y1-y0+1>BLOCK then
        local blocks,order={},{}
        for _,k in ipairs(g) do
          local c=cells[k]
          local bk=math.floor(c.cx/BLOCK)..','..math.floor(c.cy/BLOCK)
          if not blocks[bk] then blocks[bk]={}; order[#order+1]=bk end
          table.insert(blocks[bk],k)
        end
        table.sort(order)
        for _,bk in ipairs(order) do out[#out+1]={keys=blocks[bk],kind='block'} end
      else out[#out+1]={keys=g,kind='cluster'} end
    end
    for _,g in ipairs(components(loose)) do out[#out+1]={keys=g,kind='line'} end
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
        if not LINK[e.type] then c.anchor=true end
        if GUARD[e.type] then
          local t={name=e.name,position={x=e.position.x,y=e.position.y},range=range(e),ammo=ammo(e),type=e.type}
          if e.type=='fluid-turret' then t.oil,t.cap,t.fluid=oil(e) end
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
    local ok,spawn=pcall(function() return force.get_spawn_position(s) end)
    local centre=ok and spawn or {x=0,y=0}
    local areas={}
    for _,grp in ipairs(groups_of(cells)) do
      local a={box={},kinds={},buildings=0,covered=0,single=0,turrets={},sx=0,sy=0,cells={},kind=grp.kind}
      local gaps={}
      for _,key in ipairs(grp.keys) do
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
      a.from_centre=round(dist(centre,a.centre)); a.bearing=compass(centre,a.centre)
      areas[#areas+1]=a
    end
    table.sort(areas,function(x,y) return x.buildings>y.buildings or x.buildings==y.buildings and (x.centre.x<y.centre.x or x.centre.x==y.centre.x and x.centre.y<y.centre.y) end)
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
          if not nest then nest={first=e.position,sx=0,sy=0,spawners=0,worms=0,polluted=false,chunks={}}; nests[#nests+1]=nest end
          if e.type=='unit-spawner' then
            nest.spawners=nest.spawners+1; nest.sx=nest.sx+e.position.x; nest.sy=nest.sy+e.position.y
            local key=math.floor(e.position.x/32)..','..math.floor(e.position.y/32)
            if not nest.chunks[key] then
              nest.chunks[key]=true
              local reached,last,amount=polluted(s,e.position)
              if reached then nest.polluted=true end
              if last and (not nest.last or last>nest.last) then nest.last=last end
              if amount>0 then nest.now=true end
            end
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
          kept[#kept+1]={position=n.position,spawners=n.spawners,worms=n.worms,pollution_reaches=n.polluted,
            pollution_now=n.now or nil,pollution_last=n.polluted and not n.now and n.last or nil,distance=round(bd),
            bearing=compass(best,n.position),nearest_building={name=best.name,position={x=round(best.x),y=round(best.y)}},area=barea}
        end
      end
    end
    table.sort(kept,function(x,y) return x.distance<y.distance end)
    return areas,kept,artillery,#turrets
  end

  local function pollution_text(n)
    if not n.pollution_reaches then return 'does not reach it' end
    if n.pollution_now then return 'reaches it' end
    return 'reaches it (last there '..ago(game.tick-(n.pollution_last or game.tick))..')'
  end
  local function area_out(i,a,nests)
    local list,ammo_total,empty,low={},0,0,0
    local guns,lasers,flamers,dry,low_oil,oil_sum,cap_sum=0,0,0,0,0,0,0
    local oiled={}  -- the flamers, for flameroil.summary
    table.sort(a.turrets,function(x,y) return (x.ammo or math.huge)<(y.ammo or math.huge) end)
    for _,t in ipairs(a.turrets) do
      if t.type=='ammo-turret' then
        guns=guns+1; ammo_total=ammo_total+(t.ammo or 0)
        if t.ammo==0 then empty=empty+1 elseif t.ammo<LOW_AMMO then low=low+1 end
      elseif t.type=='fluid-turret' then
        flamers=flamers+1
        oil_sum=oil_sum+(t.oil or 0); cap_sum=cap_sum+(t.cap or 0)
        oiled[#oiled+1]={amount=t.oil or 0,fluid=t.fluid,position=t.position}
        if (t.oil or 0)<1 then dry=dry+1 elseif t.cap and t.oil/t.cap<LOW_OIL then low_oil=low_oil+1 end
      elseif t.type=='electric-turret' then lasers=lasers+1 end
      if #list<MAX_TURRETS then list[#list+1]={name=t.name,position={x=t.position.x,y=t.position.y},ammo=t.ammo} end
    end
    local gaps={}
    for k,g in ipairs(a.gaps) do
      if k>MAX_GAPS then break end
      gaps[k]={box=box_text(g.box),buildings=g.buildings,kinds=counted(g.kinds,4)}
    end
    local uncovered=a.buildings-a.covered
    local parts={}
    if guns>0 then parts[#parts+1]=string.format('%d gun (%d ammo%s%s)',guns,ammo_total,empty>0 and ', '..empty..' empty' or '',low>0 and ', '..low..' low' or '') end
    if flamers>0 then
      parts[#parts+1]=string.format('%d flamethrower (%s; oil %s%s%s)',flamers,flameroil.summary(oiled,1),
        cap_sum>0 and round(100*oil_sum/cap_sum)..'%' or round(oil_sum)..'',dry>0 and ', '..dry..' dry' or '',low_oil>0 and ', '..low_oil..' low' or '')
    end
    if lasers>0 then parts[#parts+1]=lasers..' laser' end
    local line=string.format('area %d (%s, %d tiles %s of base centre) around (%d,%d) %s: %d buildings (%s); %s',i,a.kind,a.from_centre,a.bearing,a.centre.x,a.centre.y,
      box_text(a.box),a.buildings,counted(a.kinds,3),#a.turrets==0 and 'no turret in range' or 'turrets in range: '..table.concat(parts,', '))
    if #a.turrets>0 then
      line=line..string.format('; %d buildings covered (%d by one turret only), %d not',a.covered,a.single,uncovered)
      if gaps[1] then line=line..string.format('; largest uncovered part %s: %d buildings (%s)',gaps[1].box,gaps[1].buildings,gaps[1].kinds) end
    end
    local near={}
    for _,n in ipairs(nests) do
      if n.area==i and #near<AREA_NESTS then
        near[#near+1]=string.format('(%d,%d) %d tiles %s%s',n.position.x,n.position.y,n.distance,n.bearing,n.pollution_reaches and ' polluted' or '')
      end
    end
    if #near>0 then line=line..'; nests: '..table.concat(near,', ') end
    return {area=i,kind=a.kind,line=line,centre=a.centre,from_centre=a.from_centre,bearing=a.bearing,box=box_text(a.box),buildings=a.buildings,kinds=counted(a.kinds,5),
      turrets=#a.turrets,ammo=ammo_total,empty=empty>0 and empty or nil,low=low>0 and low or nil,
      flamers=flamers>0 and {count=flamers,with_oil=flamers-dry,oil=round(oil_sum),capacity=cap_sum>0 and round(cap_sum) or nil,dry=dry>0 and dry or nil,low=low_oil>0 and low_oil or nil} or nil,
      lasers=lasers>0 and lasers or nil,turret_list=list[1] and list or nil,
      covered=a.covered,covered_once=a.single,uncovered=uncovered,uncovered_parts=gaps[1] and gaps or nil,nests=near[1] and near or nil}
  end

  local function cached(p,kind,limit,build)
    local st=api.state()
    st.defense_cache=st.defense_cache or {}
    local key=kind..'/'..p.force.name..'@'..p.surface.index
    local entry=st.defense_cache[key]
    if not entry or game.tick-entry.tick>=CACHE_TICKS or entry.limit~=limit then
      entry={tick=game.tick,limit=limit,result=build()}
      st.defense_cache[key]=entry
    end
    local r={}
    for k,v in pairs(entry.result) do r[k]=v end
    r.as_of=entry.tick<game.tick and entry.tick or nil
    r.tick=game.tick
    return r
  end

  function M.handlers.defense(p,a)
    a=a or {}
    local limit=math.max(1,math.min(40,math.floor(tonumber(a.limit) or MAX_AREAS)))
    return cached(p,'defense',limit,function()
      local areas,nests,artillery,turret_count=scan(p)
      local out,uncovered={},{}
      local rest={areas=0,buildings=0,no_turret=0}
      for i,area in ipairs(areas) do
        if i<=limit then out[#out+1]=area_out(i,area,nests)
        else rest.areas=rest.areas+1; rest.buildings=rest.buildings+area.buildings; if #area.turrets==0 then rest.no_turret=rest.no_turret+1 end end
        if #area.turrets==0 then uncovered[#uncovered+1]=i end
      end
      while #nests>MAX_NESTS do table.remove(nests) end
      for _,n in ipairs(nests) do
        n.line=string.format('nest (%d,%d) %d spawner%s, %d worm%s: %d tiles %s of %s at (%d,%d) (area %d); pollution %s',n.position.x,n.position.y,
          n.spawners,n.spawners==1 and '' or 's',n.worms,n.worms==1 and '' or 's',n.distance,n.bearing,n.nearest_building.name,
          n.nearest_building.position.x,n.nearest_building.position.y,n.area,pollution_text(n))
      end
      return {areas=out,areas_without_turrets=uncovered[1] and uncovered or nil,
        more=rest.areas>0 and string.format('+%d smaller areas with %d buildings (%d with no turret in range): limit raises the count',rest.areas,rest.buildings,rest.no_turret) or nil,
        nests=nests[1] and nests or nil,turrets=turret_count,artillery=artillery[1] and artillery or nil}
    end)
  end
  M.schema.defense={limit='optional: areas listed in full (default '..MAX_AREAS..', max 40)',
    returns='read, cached 10 s: areas [{area, kind, line, centre, from_centre, bearing, box, buildings, kinds, turrets, ammo, empty, low, '
    ..'flamers {count, oil, capacity, dry, low}, lasers, turret_list, covered, covered_once, uncovered, uncovered_parts [{box, buildings, kinds}], nests}]: '
    ..'the team\'s buildings in clusters, largest first. kind: cluster (buildings touching by 32-tile cells, an outpost or the base), '
    ..'block (a 128-tile block of a cluster wider than that), line (belts, pipes, poles, walls or rails between clusters); '
    ..'from_centre and bearing from the base centre (the spawn point). A building counts as covered when its centre is within range of a gun, laser or '
    ..'flamethrower turret; ammo counts gun rounds, flamer oil is apart (dry: empty, low: under 25%). areas_without_turrets: area numbers; '
    ..'nests [{line, position, spawners, worms, distance, bearing, nearest_building, area, pollution_reaches, pollution_now, pollution_last}]: charted '
    ..'spawner groups within '..NEST_RANGE..' tiles of our buildings, nearest first; pollution reaches a nest while one of its chunks had pollution '
    ..'in the last 15 minutes (the same memory as status enemies and the reached-nest news); artillery; more'}

  -- Flamer arcs. A flamethrower turret turns only within turn_range (a
  -- fraction of a full circle) about the way it was built facing, and fires
  -- between min_range and range; burning ground spreads a few tiles further.
  local arcs,burns={},{}
  local function arc(e)
    local v=arcs[e.name]
    if not v then
      local ok,ap=pcall(function() return e.prototype.attack_parameters end)
      ap=ok and type(ap)=='table' and ap or {}
      v={range=tonumber(ap.range) or 30,min=tonumber(ap.min_range) or 6,turn=tonumber(ap.turn_range) or 1/3}
      arcs[e.name]=v
    end
    return v
  end
  -- Fire resistance from the prototype: walls and other fully fire-proof buildings are not at risk.
  local function burnable(e)
    local v=burns[e.name]
    if v==nil then
      local ok,pct=pcall(function() local r=e.prototype.resistances; return r and r.fire and r.fire.percent end)
      v=not (ok and type(pct)=='number' and pct>=1)
      burns[e.name]=v
    end
    return v
  end
  local function facing(e)
    local east=defines.direction and defines.direction.east or 4
    return (e.direction or 0)*(math.pi/2)/east
  end
  local function in_arc(dx,dy,face,turn)
    if turn>=1 then return true end
    local a=(math.atan2 or math.atan)(dx,-dy)
    local diff=(a-face+math.pi)%(2*math.pi)-math.pi
    return math.abs(diff)<=turn*math.pi+1e-9
  end
  function M.handlers.flamers(p,a)
    a=a or {}
    local limit=math.max(1,math.min(40,math.floor(tonumber(a.limit) or MAX_FLAMERS)))
    return cached(p,'flamers',limit,function()
      local s,force=p.surface,p.force
      local list,dry,low,at_risk=0,0,0,0
      local rows,oiled={},{}
      for _,e in pairs(s.find_entities_filtered{force=force,type='fluid-turret'}) do
        if e.valid then
          list=list+1
          local g=arc(e)
          local face=facing(e)
          local amount,cap,fluid=oil(e)
          if amount<1 then dry=dry+1 elseif cap and amount/cap<LOW_OIL then low=low+1 end
          oiled[#oiled+1]={amount=amount,fluid=fluid,position=e.position}
          local kinds,count,nearest,nd={},0,nil,nil
          local reach=g.range+FIRE_MARGIN
          for _,b in pairs(s.find_entities_filtered{force=force,position=e.position,radius=reach}) do
            if b.valid and not SKIP[b.type] and not (b.position.x==e.position.x and b.position.y==e.position.y) and burnable(b) then
              local dx,dy=b.position.x-e.position.x,b.position.y-e.position.y
              local d=(dx*dx+dy*dy)^0.5
              if d>=g.min-1 and d<=reach and in_arc(dx,dy,face,g.turn) then
                count=count+1; kinds[b.name]=(kinds[b.name] or 0)+1
                if not nd or d<nd then nearest,nd=b,d end
              end
            end
          end
          if count>0 then at_risk=at_risk+1 end
          local dir=names[math.floor(face/(math.pi/4)+0.5)%8+1]
          local oil_text=(amount<1 and 'none' or (fluid or 'oil')..' '..round(amount))..(cap and string.format('/%d (%d%%)',round(cap),round(100*amount/cap)) or '')
          rows[#rows+1]={position={x=e.position.x,y=e.position.y},facing=dir,oil=round(amount),capacity=cap and round(cap) or nil,at_risk=count,
            kinds=count>0 and counted(kinds,4) or nil,
            fluid=fluid,nearest=nearest and {name=nearest.name,position={x=nearest.position.x,y=nearest.position.y},distance=round(nd)} or nil,
            line=string.format('%s (%g,%g) facing %s, oil %s: %s',e.name,e.position.x,e.position.y,dir,oil_text,
              count==0 and 'none of our burnable buildings in its arc'
              or string.format('%d of our burnable buildings in its arc within %d tiles: %s (nearest %s (%g,%g), %d tiles)',count,reach,counted(kinds,4),
                nearest.name,nearest.position.x,nearest.position.y,round(nd)))}
        end
      end
      table.sort(rows,function(x,y) return x.at_risk>y.at_risk or x.at_risk==y.at_risk and (x.position.x<y.position.x or x.position.x==y.position.x and x.position.y<y.position.y) end)
      local shown={}
      for i=1,math.min(limit,#rows) do shown[i]=rows[i] end
      return {summary=list>0 and flameroil.summary(oiled) or nil,flamers=shown[1] and shown or nil,count=list,with_oil=list-dry,
        dry=dry>0 and dry or nil,low=low>0 and low or nil,with_buildings_in_arc=at_risk,
        more=#rows>limit and string.format('+%d more flamers: limit raises the count',#rows-limit) or nil}
    end)
  end
  M.schema.flamers={limit='optional: flamers listed (default '..MAX_FLAMERS..', max 40)',
    returns='read, cached 10 s: summary (N of M with oil (crude-oil 87 at (x,y), ...)), flamers [{line, position, facing, oil, fluid, capacity, at_risk, kinds, '
    ..'nearest {name, position, distance}}], the most at risk first: each flamethrower turret on your surface with its oil (all it holds, its own '
    ..'buffer too: a flamer fires from it after its pipe has drained; capacity: its fluidbox plus that buffer), and our own buildings that fire can burn '
    ..'(fire resistance under 100%; walls are immune) inside its arc: the direction it was built facing, plus or minus its turn range, from its minimum '
    ..'range to its range plus '..FIRE_MARGIN..' tiles for burning ground; count, with_oil, dry (no oil), low (under 25%), with_buildings_in_arc, more'}
  return M
end
