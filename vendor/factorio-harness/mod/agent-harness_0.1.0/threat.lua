-- Enemy and pollution awareness: evolution, the pollution cloud and which
-- spawners it reaches, plus attack alerts. Only what a player could see: the
-- pollution overlay and spawners on charted chunks, unit groups in visible ones.
-- The surface scan is cached because status is polled several times a second.
return function(api)
  local M={}
  local CACHE_TICKS,CHART_TICKS,MAX_BASE_RANGE,CLOUD_SEARCH,EVOLUTION_WINDOW,MAX_NEWS=600,3600,512,8,18000,16
  local function round(v,digits)
    if not digits then return math.floor(v+0.5) end
    local m=10^digits; return math.floor(v*m+0.5)/m
  end
  local names={'N','NE','E','SE','S','SW','W','NW'}
  local function compass(from,to)
    local angle=(math.atan2 or math.atan)(to.x-from.x,-(to.y-from.y))
    return names[math.floor(angle/(math.pi/4)+0.5)%8+1]
  end
  local function chunk_centre(cx,cy) return {x=cx*32+16,y=cy*32+16} end

  function M.evolution(p)
    local enemy,s=game.forces.enemy,p.surface
    local f=enemy.get_evolution_factor(s)
    -- Status is polled constantly; the delta compares with a reading kept
    -- for at least five minutes, so it shows a trend rather than noise.
    local seen=api.state().evolution_seen or {}
    api.state().evolution_seen=seen
    -- The baseline is replaced by a newer reading once that one has aged too.
    local last=seen[p.index] or {tick=game.tick,factor=f}
    if last.next and game.tick-last.next.tick>=EVOLUTION_WINDOW then last=last.next end
    if not last.next and game.tick-last.tick>=EVOLUTION_WINDOW then last.next={tick=game.tick,factor=f} end
    seen[p.index]=last
    local delta=f-last.factor
    return {factor=round(f,4),time=round(enemy.get_evolution_factor_by_time(s),4),
      pollution=round(enemy.get_evolution_factor_by_pollution(s),4),kills=round(enemy.get_evolution_factor_by_killing_spawners(s),4),
      delta=delta>=0.00005 and round(delta,4) or nil,since=delta>=0.00005 and last.tick or nil}
  end

  -- Per-minute rates over the last minute; input is emission, output absorption.
  local function pollution(p)
    local stats=game.get_pollution_statistics(p.surface)
    local minute=defines.flow_precision_index.one_minute
    local emitted,absorbed,top=0,0,{}
    for name in pairs(stats.input_counts) do
      local v=stats.get_flow_count{name=name,category='input',precision_index=minute}
      emitted=emitted+v; top[#top+1]={name=name,rate=v}
    end
    for name in pairs(stats.output_counts) do absorbed=absorbed+stats.get_flow_count{name=name,category='output',precision_index=minute} end
    table.sort(top,function(a,b) return a.rate>b.rate end)
    local parts={}
    for i=1,math.min(3,#top) do if top[i].rate>=0.5 then parts[#parts+1]=top[i].name..' '..round(top[i].rate) end end
    return {total=round(p.surface.get_total_pollution()),per_min=round(emitted),absorbed_per_min=round(absorbed),top=#parts>0 and table.concat(parts,', ') or nil}
  end

  -- Spawners within range of our structures, clustered into bases.
  local function bases(p)
    local s,centre=p.surface,p.position
    local found=s.find_entities_filtered{type='unit-spawner',position=centre,radius=MAX_BASE_RANGE}
    local out={}
    for _,e in ipairs(found) do
      if e.valid and e.type=='unit-spawner' and e.force~=p.force and api.known(p,e) then
        local base
        for _,b in ipairs(out) do if api.distance(b.first,e.position)<=64 then base=b; break end end
        if not base then base={first=e.position,sx=0,sy=0,spawners=0,chunks={},keys={},absorbing=0}; out[#out+1]=base end
        base.sx=base.sx+e.position.x; base.sy=base.sy+e.position.y; base.spawners=base.spawners+1
        local key=math.floor(e.position.x/32)..','..math.floor(e.position.y/32)
        if not base.chunks[key] then
          base.chunks[key]=true; base.keys[#base.keys+1]=key
          base.absorbing=base.absorbing+s.get_pollution(e.position)
          if p.force.is_chunk_visible(s,{x=math.floor(e.position.x/32),y=math.floor(e.position.y/32)}) then base.visible=true end
        end
      end
    end
    for _,b in ipairs(out) do
      b.position={x=round(b.sx/b.spawners),y=round(b.sy/b.spawners)}
      b.first,b.sx,b.sy,b.chunks=nil,nil,nil,nil
      b.absorbing=round(b.absorbing)
      -- Nearest of our structures, searched in widening rings.
      for _,r in ipairs{64,128,256,MAX_BASE_RANGE} do
        local ours=s.find_entities_filtered{position=b.position,radius=r,force=p.force,limit=256}
        local near=#ours>0 and s.get_closest(b.position,ours)
        if near then
          b.distance=round(api.distance(b.position,near.position)); b.direction=compass(near.position,b.position); break
        end
      end
      if b.absorbing==0 then
        -- Chunks between the base and the nearest polluted chunk.
        local cx,cy=math.floor(b.position.x/32),math.floor(b.position.y/32)
        for r=1,CLOUD_SEARCH do
          for dx=-r,r do
            for dy=-r,r do
              if not b.cloud_gap and math.max(math.abs(dx),math.abs(dy))==r then
                local c=chunk_centre(cx+dx,cy+dy)
                if p.force.is_chunk_charted(s,{x=cx+dx,y=cy+dy}) and s.get_pollution(c)>0 then b.cloud_gap=r; b.cloud_direction=compass(b.position,c) end
              end
            end
          end
          if b.cloud_gap then break end
        end
      end
    end
    table.sort(out,function(a,b) return (a.distance or math.huge)<(b.distance or math.huge) end)
    return out
  end

  -- Chart coverage and the charted extent of the pollution cloud; polluted
  -- chunks beyond the chart only reveal in which directions the cloud leaves it.
  local function chart(p)
    local s,force=p.surface,p.force
    local charted,visible,polluted=0,0,0
    local box,cloud,beyond={},{},{}
    local centre=force.get_spawn_position(s)
    local function grow(b,x,y)
      b.left=math.min(b.left or x,x); b.right=math.max(b.right or x,x)
      b.top=math.min(b.top or y,y); b.bottom=math.max(b.bottom or y,y)
    end
    for c in s.get_chunks() do
      local is_charted=force.is_chunk_charted(s,c)
      if is_charted then
        charted=charted+1; grow(box,c.x,c.y)
        if force.is_chunk_visible(s,c) then visible=visible+1 end
      end
      if s.get_pollution(chunk_centre(c.x,c.y))>0 then
        if is_charted then polluted=polluted+1; grow(cloud,c.x,c.y)
        else beyond[compass(centre,chunk_centre(c.x,c.y))]=true end
      end
    end
    local function extent(b)
      return b.left and string.format('x %d..%d y %d..%d',b.left*32,b.right*32+31,b.top*32,b.bottom*32+31) or nil
    end
    local dirs={}
    for _,name in ipairs(names) do if beyond[name] then dirs[#dirs+1]=name end end
    return {tick=game.tick,charted_chunks=charted,visible_chunks=visible,extent=extent(box),
      radars=#s.find_entities_filtered{type='radar',force=force},
      cloud={chunks=polluted,extent=extent(cloud),beyond_chart=#dirs>0 and table.concat(dirs,',') or nil}}
  end

  -- Remembers each nest chunk: when it was last visible and whether the cloud
  -- reached it, so a newly charted nest or newly reached one becomes news.
  local function note_bases(list)
    local st=api.state()
    local first=st.nests==nil
    local nests=st.nests or {}
    st.nests=nests
    st.enemy_news=st.enemy_news or {}
    local function news(kind,b)
      table.insert(st.enemy_news,{tick=game.tick,kind=kind,position=b.position,spawners=b.spawners})
      while #st.enemy_news>MAX_NEWS do table.remove(st.enemy_news,1) end
    end
    for _,b in ipairs(list) do
      local known_before,reached_before=false,false
      for _,key in ipairs(b.keys) do
        local n=nests[key]
        if n then known_before=true; reached_before=reached_before or n.reached end
      end
      if not known_before and not first then news('nest_charted',b) end
      if b.absorbing>0 and not reached_before and known_before then news('pollution_reached_nest',b) end
      local seen
      for _,key in ipairs(b.keys) do
        local n=nests[key] or {}
        nests[key]=n
        if b.visible then n.visible=game.tick end
        n.reached=b.absorbing>0
        seen=math.max(seen or 0,n.visible or 0)
      end
      b.seen=seen and seen>0 and seen or nil
      b.keys,b.visible=nil,nil
    end
  end

  local function refresh(p,fresh)
    local cache=api.state().threat_cache or {}
    api.state().threat_cache=cache
    local entry=cache[p.index]
    if fresh or not entry or game.tick-entry.tick>=CACHE_TICKS or entry.surface~=p.surface.index then
      local list=bases(p)
      note_bases(list)
      local old_chart=entry and entry.surface==p.surface.index and entry.chart
      entry={tick=game.tick,surface=p.surface.index,pollution=pollution(p),bases=list,
        chart=(not fresh and old_chart and game.tick-old_chart.tick<CHART_TICKS) and old_chart or chart(p)}
      cache[p.index]=entry
    end
    return entry
  end
  local function age(tick)
    local m=math.floor((game.tick-tick)/3600)
    return m<1 and 'now' or m<60 and m..'m ago' or math.floor(m/60)..'h ago'
  end

  -- One line each by default; `threats=true` lists every base.
  function M.summary(p,detail)
    local entry=refresh(p,detail)
    local reached,nearest,next_base={},nil,nil
    for _,b in ipairs(entry.bases) do
      if b.absorbing>0 then reached[#reached+1]=b; nearest=nearest or b
      elseif b.cloud_gap and (not next_base or b.cloud_gap<next_base.cloud_gap) then next_base=b end
    end
    local enemies
    if #entry.bases>0 then
      enemies={bases=#entry.bases,reached=#reached}
      local n=entry.bases[1]
      enemies.nearest=string.format('base (%g,%g) %d spawners, %s tiles %s of our structures, %s',n.position.x,n.position.y,n.spawners,
        n.distance or '?',n.direction or '?',n.seen and 'seen '..age(n.seen) or 'not seen since charted')
      if nearest then enemies.nearest_reached=string.format('base (%g,%g) absorbing %g, %s tiles %s of our structures',
        nearest.position.x,nearest.position.y,nearest.absorbing,nearest.distance or '?',nearest.direction or '?') end
      if next_base then enemies.next=string.format('base (%g,%g) %d chunks from the cloud (cloud to its %s)',
        next_base.position.x,next_base.position.y,next_base.cloud_gap,next_base.cloud_direction) end
      if detail then enemies.list=entry.bases end
    end
    local c=entry.chart
    local pollution={}
    for k,v in pairs(entry.pollution) do pollution[k]=v end
    pollution.cloud_chunks=c.cloud.chunks; pollution.cloud_extent=c.cloud.extent
    pollution.cloud_beyond_chart=c.cloud.beyond_chart
    return {evolution=M.evolution(p),pollution=pollution,enemies=enemies,as_of=entry.tick<game.tick and entry.tick or nil,
      chart={charted_chunks=c.charted_chunks,visible_chunks=c.visible_chunks,extent=c.extent,radars=c.radars}}
  end

  -- Attack alerts: gathered groups in visible chunks, and damage to our
  -- entities by enemies summarised per chunk.
  local MAX_GROUPS,MAX_AREAS=16,64
  function M.on_group(event)
    local g=event.group
    if not (g and g.valid and g.force.name=='enemy') then return end
    local pos=g.position
    local visible
    for _,force in pairs(game.forces) do
      if force.name~='enemy' and force.name~='neutral' and #force.players>0 and force.is_chunk_visible(g.surface,{x=math.floor(pos.x/32),y=math.floor(pos.y/32)}) then visible=true end
    end
    if not visible then return end
    local command=g.command
    local target=command and (command.target and command.target.valid and command.target.position or command.destination)
    local s=api.state(); s.attack_groups=s.attack_groups or {}
    table.insert(s.attack_groups,{tick=event.tick,size=#g.members,position={x=round(pos.x),y=round(pos.y)},
      target=target and {x=round(target.x),y=round(target.y)} or nil})
    while #s.attack_groups>MAX_GROUPS do table.remove(s.attack_groups,1) end
  end
  function M.on_damaged(event)
    local e,force=event.entity,event.force
    if not (e and e.valid and force and force.name=='enemy') then return end
    if e.force.name=='enemy' or e.force.name=='neutral' then return end
    local s=api.state(); s.damage=s.damage or {}
    local key=math.floor(e.position.x/32)..','..math.floor(e.position.y/32)
    local area=s.damage[key]
    if not area then
      local count=0
      for _ in pairs(s.damage) do count=count+1 end
      if count>=MAX_AREAS then
        -- Forget the quietest area to stay bounded.
        local oldest
        for k,v in pairs(s.damage) do if not oldest or v.last<s.damage[oldest].last then oldest=k end end
        s.damage[oldest]=nil
      end
      area={first=event.tick,hits=0,damage=0,entities={}}; s.damage[key]=area
    end
    area.last=event.tick; area.hits=area.hits+1; area.damage=area.damage+(event.final_damage_amount or 0)
    area.entities[e.name]=(area.entities[e.name] or 0)+1
    area.by=event.cause and event.cause.valid and event.cause.name or area.by
  end
  function M.alerts(since)
    local s,out=api.state(),{}
    local groups={}
    for _,g in ipairs(s.attack_groups or {}) do if g.tick>since then groups[#groups+1]=g end end
    local areas={}
    for key,v in pairs(s.damage or {}) do
      if v.last>since then
        local cx,cy=key:match('^(-?%d+),(-?%d+)$')
        local names={}
        for name,n in pairs(v.entities) do names[#names+1]=name..' x'..n end
        table.sort(names)
        areas[#areas+1]={chunk_centre=chunk_centre(tonumber(cx),tonumber(cy)),hits=v.hits,damage=round(v.damage),last_tick=v.last,by=v.by,entities=table.concat(names,', ')}
      end
    end
    table.sort(areas,function(a,b) return a.last_tick>b.last_tick end)
    while #areas>4 do table.remove(areas) end
    local news={}
    for _,n in ipairs(s.enemy_news or {}) do if n.tick>since then news[#news+1]=n end end
    out.enemy_news=#news>0 and news or nil
    out.attack_groups=#groups>0 and groups or nil
    out.attacked=#areas>0 and areas or nil
    return next(out) and out or nil
  end
  return M
end
