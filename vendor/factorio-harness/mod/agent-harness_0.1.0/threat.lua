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

  -- Whether pollution reaches a nest. The pollution on a spawner's chunk hovers
  -- about zero at the cloud's edge (the spawners absorb it), so one reading
  -- flickers: shift 6's status said reached 1, 1, 0, 1, 0 on successive polls
  -- while the defense read said reached. Every reading that finds pollution on a
  -- nest chunk is remembered per surface; a nest counts as reached while one of
  -- its chunks had pollution in the last REACH_WINDOW. Status, the defense read
  -- and the news share this memory.
  local REACH_WINDOW=54000 -- 15 game minutes
  M.REACH_WINDOW=REACH_WINDOW
  function M.polluted(surface,pos)
    local st=api.state(); st.nest_reach=st.nest_reach or {}
    local m=st.nest_reach[surface.index]
    if not m then m={}; st.nest_reach[surface.index]=m end
    local key=math.floor(pos.x/32)..','..math.floor(pos.y/32)
    local amount=surface.get_pollution(pos)
    if amount>0 then m[key]=game.tick end
    return amount,m[key]
  end
  function M.reached(last) return last~=nil and game.tick-last<=REACH_WINDOW end
  -- Not buildings: what "our nearest structure" must skip (a ghost or a car
  -- 19 tiles from a nest made status say 19 tiles where the defense read said 107).
  local NOT_BUILDING={character=true,car=true,['spider-vehicle']=true,locomotive=true,['cargo-wagon']=true,['fluid-wagon']=true,
    ['artillery-wagon']=true,['entity-ghost']=true,['tile-ghost']=true,['construction-robot']=true,['logistic-robot']=true,
    ['combat-robot']=true,['character-corpse']=true,['item-request-proxy']=true,['spider-leg']=true,['spider-unit']=true}
  M.NOT_BUILDING=NOT_BUILDING
  -- Spawners within range of the agent, clustered into bases.
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
          local amount,last=M.polluted(s,e.position)
          base.absorbing=base.absorbing+amount
          if last and (not base.polluted_tick or last>base.polluted_tick) then base.polluted_tick=last end
          if p.force.is_chunk_visible(s,{x=math.floor(e.position.x/32),y=math.floor(e.position.y/32)}) then base.visible=true end
        end
      end
    end
    for _,b in ipairs(out) do
      b.position={x=round(b.sx/b.spawners),y=round(b.sy/b.spawners)}
      b.first,b.sx,b.sy,b.chunks=nil,nil,nil,nil
      b.absorbing=round(b.absorbing)
      b.reached=M.reached(b.polluted_tick)
      -- Nearest of our buildings, searched in widening rings.
      for _,r in ipairs{64,128,256,MAX_BASE_RANGE} do
        local ours={}
        for _,e in pairs(s.find_entities_filtered{position=b.position,radius=r,force=p.force,limit=256}) do
          if e.valid and not NOT_BUILDING[e.type] then ours[#ours+1]=e end
        end
        local near=#ours>0 and s.get_closest(b.position,ours)
        if near then
          b.distance=round(api.distance(b.position,near.position)); b.direction=compass(near.position,b.position); break
        end
      end
      if not b.reached then
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
  -- News is numbered with the attack alerts (alert_seq) so replies push each
  -- item once; it carries the bearing and distance from the base centre (the
  -- force's spawn position) and from our nearest structure.
  local function note_bases(p,list)
    local st=api.state()
    local first=st.nests==nil
    local nests=st.nests or {}
    st.nests=nests
    st.enemy_news=st.enemy_news or {}
    local centre=p.force.get_spawn_position(p.surface)
    local function news(kind,b)
      st.alert_seq=(st.alert_seq or 0)+1
      table.insert(st.enemy_news,{seq=st.alert_seq,tick=game.tick,kind=kind,surface=p.surface.name,position=b.position,spawners=b.spawners,
        centre={x=round(centre.x),y=round(centre.y)},from_centre=round(api.distance(centre,b.position)),bearing=compass(centre,b.position),
        nearest=b.distance,nearest_direction=b.direction})
      while #st.enemy_news>MAX_NEWS do table.remove(st.enemy_news,1) end
    end
    -- Reached-nest news comes once per nest per shift: agents start each shift
    -- afresh, and nests reached in an earlier shift were never told again (shift
    -- 6: attacks came from three reached nests with no news of them).
    local shift_tick=st.shift and st.shift.tick or -1
    for _,b in ipairs(list) do
      local known_before,told=false,nil
      for _,key in ipairs(b.keys) do
        local n=nests[key]
        if n then known_before=true; if n.reached_told and (not told or n.reached_told>told) then told=n.reached_told end end
      end
      if not known_before and not first then news('nest_charted',b) end
      local tell=b.reached and (not told or told<shift_tick)
      if tell then news('pollution_reached_nest',b) end
      local seen
      for _,key in ipairs(b.keys) do
        local n=nests[key] or {}
        nests[key]=n
        if b.visible then n.visible=game.tick end
        if tell then n.reached_told=game.tick end
        seen=math.max(seen or 0,n.visible or 0)
      end
      b.seen=seen and seen>0 and seen or nil
      b.keys,b.visible=nil,nil
    end
  end

  -- The nests around an agent are its own; the surface's pollution and the
  -- force's chart there are shared by every agent on it (each agent walked
  -- every chunk once a minute before).
  local function shared(p,fresh)
    local st=api.state()
    st.threat_shared=st.threat_shared or {}
    local key=p.force.name..'/'..p.surface.index
    local e=st.threat_shared[key]
    if not e then e={}; st.threat_shared[key]=e end
    if fresh or not e.pollution or game.tick-e.pollution_tick>=CACHE_TICKS then e.pollution,e.pollution_tick=pollution(p),game.tick end
    if fresh or not e.chart or game.tick-e.chart.tick>=CHART_TICKS then e.chart=chart(p) end
    return e
  end
  local function refresh(p,fresh)
    local cache=api.state().threat_cache or {}
    api.state().threat_cache=cache
    local entry=cache[p.index]
    if fresh or not entry or game.tick-entry.tick>=CACHE_TICKS or entry.surface~=p.surface.index then
      local list=bases(p)
      note_bases(p,list)
      entry={tick=game.tick,surface=p.surface.index,bases=list}
      cache[p.index]=entry
    end
    local s=shared(p,fresh)
    entry.pollution,entry.chart=s.pollution,s.chart
    return entry
  end
  -- Replies keep nest news flowing without a status call: the nests around an
  -- agent are rechecked when neither status nor a reply did so in the last
  -- minute (only the spawner search; the chart and pollution stay with status).
  function M.watch(p)
    if not (p.character and p.character.valid) then return end
    local st=api.state()
    local entry=st.threat_cache and st.threat_cache[p.index]
    st.threat_watch=st.threat_watch or {}
    local last=math.max(entry and entry.surface==p.surface.index and entry.tick or -math.huge,st.threat_watch[p.index] or -math.huge)
    if game.tick-last<3600 then return end
    st.threat_watch[p.index]=game.tick
    note_bases(p,bases(p))
  end
  -- Lines for news after `from` (an alert_seq), oldest first.
  function M.news_lines(from,since_tick,reader)
    local out={}
    for _,n in ipairs(api.state().enemy_news or {}) do
      local new=(from and (n.seq or 0)>from) or (not from and n.tick>=since_tick)
      if new and n.kind=='pollution_reached_nest' then
        local on=n.surface and reader and n.surface~=reader and ' on '..n.surface or ''
        out[#out+1]=string.format('pollution reached nest%s (%g,%g), %d spawner%s: %d tiles %s of base centre (%g,%g)%s',on,n.position.x,n.position.y,
          n.spawners or 0,n.spawners==1 and '' or 's',n.from_centre or 0,n.bearing or '?',n.centre and n.centre.x or 0,n.centre and n.centre.y or 0,
          n.nearest and string.format(', %d tiles %s of our nearest building',n.nearest,n.nearest_direction or '?') or '')
      end
    end
    return out
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
      if b.reached then reached[#reached+1]=b; nearest=nearest or b
      elseif b.cloud_gap and (not next_base or b.cloud_gap<next_base.cloud_gap) then next_base=b end
    end
    local enemies
    if #entry.bases>0 then
      enemies={bases=#entry.bases,reached=#reached}
      local n=entry.bases[1]
      enemies.nearest=string.format('base (%g,%g) %d spawners, %s tiles %s of our structures, %s',n.position.x,n.position.y,n.spawners,
        n.distance or '?',n.direction or '?',n.seen and 'seen '..age(n.seen) or 'not seen since charted')
      if nearest then enemies.nearest_reached=string.format('base (%g,%g) pollution %s, %s tiles %s of our structures',
        nearest.position.x,nearest.position.y,nearest.absorbing>0 and 'there now ('..nearest.absorbing..')'
          or game.tick-nearest.polluted_tick<3600 and 'last there '..math.floor((game.tick-nearest.polluted_tick)/60)..'s ago'
          or 'last there '..age(nearest.polluted_tick),
        nearest.distance or '?',nearest.direction or '?') end
      -- Every reached nest, nearest first (the defense read and the news say the same).
      if #reached>0 then
        local parts={}
        for i,b in ipairs(reached) do
          if i>6 then parts[#parts+1]='+'..(#reached-6)..' more'; break end
          parts[#parts+1]=string.format('(%g,%g) %s tiles %s',b.position.x,b.position.y,b.distance or '?',b.direction or '?')
        end
        enemies.reached_list=table.concat(parts,'; ')
      end
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
  -- entities by enemies summarised per chunk as incidents. An incident keeps
  -- what the game knows: the attacked point, the attackers seen (distinct
  -- units, by kind), a gathered group heading there, and the nearest charted
  -- spawner they likely came from (looked up once per incident).
  local MAX_GROUPS,MAX_AREAS,INCIDENT_GAP,MAX_UNITS,SOURCE_RANGE,GROUP_MATCH=16,64,3600,200,384,64
  local function charted(force,surface,pos)
    return force.is_chunk_charted(surface,{x=math.floor(pos.x/32),y=math.floor(pos.y/32)})
  end
  -- The nearest spawner on a chunk the force has charted, within SOURCE_RANGE
  -- of `at`. A unit's own spawner (when the engine exposes it) wins if charted.
  -- Lookups close in time and place share one search.
  function M.source(force,surface,at,unit)
    local ok,own=pcall(function() return unit and unit.valid and unit.spawner end)
    if ok and type(own)=='table' and own.valid and charted(force,surface,own.position) then
      return {position={x=round(own.position.x),y=round(own.position.y)},distance=round(api.distance(at,own.position)),bearing=compass(at,own.position),spawned=true}
    end
    local s=api.state()
    local memo=s.source_memo
    if not (memo and memo.surface==surface.index and memo.force==force.name and game.tick-memo.tick<60 and api.distance(memo.at,at)<=96) then
      local best,bd
      for _,e in pairs(surface.find_entities_filtered{type='unit-spawner',position=at,radius=SOURCE_RANGE,force='enemy'}) do
        if e.valid and charted(force,surface,e.position) then
          local d=api.distance(at,e.position)
          if not bd or d<bd then best,bd=e.position,d end
        end
      end
      memo={tick=game.tick,surface=surface.index,force=force.name,at=at,position=best and {x=round(best.x),y=round(best.y)} or nil}
      s.source_memo=memo
    end
    if not memo.position then return nil end
    return {position=memo.position,distance=round(api.distance(at,memo.position)),bearing=compass(at,memo.position)}
  end
  local function kinds_text(kinds)
    local list={}
    for name,n in pairs(kinds or {}) do list[#list+1]={name,n} end
    table.sort(list,function(a,b) return a[2]>b[2] or a[2]==b[2] and a[1]<b[1] end)
    for i,v in ipairs(list) do list[i]=v[2]..' '..v[1] end
    while #list>4 do table.remove(list) end
    return table.concat(list,', ')
  end
  -- Live attack groups for the operator (`attack_groups_live`: the pog stream follows a big group as it
  -- approaches a base). Every enemy group that finishes gathering with a target is kept, visible or not (the
  -- operator reads it, agents never do), while it is valid and at most LIVE_TICKS old; at most MAX_LIVE, the
  -- oldest dropped.
  local MAX_LIVE,LIVE_TICKS,NEAR_RADIUS=10,36000,160
  M.operator={}
  local function command_target(command)
    if not command then return nil end
    if command.target and command.target.valid then return command.target.position end
    if command.destination then return command.destination end
    for _,c in ipairs(command.commands or {}) do
      local t=command_target(c)
      if t then return t end
    end
  end
  local function member_kinds(members)
    local kinds={}
    for _,u in ipairs(members or {}) do
      local ok,name=pcall(function() return u.name end)
      if ok and name then kinds[name]=(kinds[name] or 0)+1 end
    end
    return kinds
  end
  local function visible_to_players(surface,pos)
    for _,force in pairs(game.forces) do
      if force.name~='enemy' and force.name~='neutral' and #force.players>0 and force.is_chunk_visible(surface,{x=math.floor(pos.x/32),y=math.floor(pos.y/32)}) then return true end
    end
    return false
  end
  local function track(g,tick,target,kinds)
    local s=api.state(); s.live_groups=s.live_groups or {}
    s.live_seq=(s.live_seq or 0)+1
    local pos=g.position
    table.insert(s.live_groups,{id=s.live_seq,group=g,tick=tick,surface=g.surface and g.surface.name or nil,
      gathered={x=round(pos.x),y=round(pos.y)},target=target and {x=round(target.x),y=round(target.y)} or nil,
      first_size=#(g.members or {}),first_kinds=next(kinds) and kinds_text(kinds) or nil})
    while #s.live_groups>MAX_LIVE do table.remove(s.live_groups,1) end
  end
  local STATE_NAMES
  local function state_name(v)
    if not STATE_NAMES then
      STATE_NAMES={}
      for name,n in pairs(defines.group_state or {}) do STATE_NAMES[n]=name end
    end
    return STATE_NAMES[v] or (v~=nil and tostring(v) or nil)
  end
  -- Our nearest building to a point (any non-enemy force with players), within NEAR_RADIUS.
  local function nearest_building(surface,pos)
    local ours={}
    for _,force in pairs(game.forces) do
      if force.name~='enemy' and force.name~='neutral' and #force.players>0 then
        for _,e in pairs(surface.find_entities_filtered{position=pos,radius=NEAR_RADIUS,force=force,limit=200}) do
          if e.valid and not NOT_BUILDING[e.type] then ours[#ours+1]=e end
        end
      end
    end
    local near=#ours>0 and surface.get_closest(pos,ours)
    return near and near.position or nil
  end
  -- Each live group: where it is now, its members by kind, its target, how far it has to go to the target and to
  -- our nearest building, and its state (gathering, moving, attacking_*); invalid or finished groups are dropped.
  function M.operator.attack_groups_live(a)
    local s=api.state()
    local keep,out={},{}
    for _,r in ipairs(s.live_groups or {}) do
      local g=r.group
      local ok,valid=pcall(function() return g and g.valid end)
      if ok and valid and game.tick-r.tick<=LIVE_TICKS then
        local members=g.members or {}
        if #members>0 then
          keep[#keep+1]=r
          local pos=g.position
          local target=command_target(g.command) or r.target
          local near=nearest_building(g.surface,pos)
          out[#out+1]={id=r.id,surface=r.surface,position={x=round(pos.x),y=round(pos.y)},size=#members,
            kinds=kinds_text(member_kinds(members)),state=state_name(g.state),gathered=r.gathered,first_size=r.first_size,
            target=target and {x=round(target.x),y=round(target.y)} or nil,
            target_distance=target and round(api.distance(pos,target)) or nil,
            nearest=near and {x=round(near.x),y=round(near.y)} or nil,nearest_distance=near and round(api.distance(pos,near)) or nil,
            visible=visible_to_players(g.surface,pos),age_s=round((game.tick-r.tick)/60)}
        end
      end
    end
    s.live_groups=keep
    return {ok=true,tick=game.tick,groups=out}
  end
  function M.on_group(event)
    local g=event.group
    if not (g and g.valid and g.force.name=='enemy') then return end
    local pos=g.position
    local target=command_target(g.command)
    local kinds=member_kinds(g.members)
    if target then track(g,event.tick,target,kinds) end
    if not visible_to_players(g.surface,pos) then return end
    local s=api.state(); s.attack_groups=s.attack_groups or {}
    s.alert_seq=(s.alert_seq or 0)+1
    table.insert(s.attack_groups,{seq=s.alert_seq,tick=event.tick,size=#g.members,kinds=next(kinds) and kinds_text(kinds) or nil,position={x=round(pos.x),y=round(pos.y)},
      target=target and {x=round(target.x),y=round(target.y)} or nil,surface=g.surface and g.surface.name or nil})
    while #s.attack_groups>MAX_GROUPS do table.remove(s.attack_groups,1) end
  end
  function M.on_damaged(event)
    local e,force=event.entity,event.force
    if not (e and e.valid and force and force.name=='enemy') then return end
    if e.force.name=='enemy' or e.force.name=='neutral' then return end
    -- Platform hits are platalerts.lua's (runtime.lua routes them there first);
    -- one that reaches here is not a ground attack either.
    local surface=e.surface
    if surface and surface.platform then return end
    local s=api.state(); s.damage=s.damage or {}
    -- Keyed by surface and chunk: hits on two planets at the same chunk are two incidents.
    local key=(surface and surface.name or '?')..':'..math.floor(e.position.x/32)..','..math.floor(e.position.y/32)
    local area=s.damage[key]
    -- An area kept from before incidents had ids (a hot deploy) starts afresh.
    local fresh=not area or not area.id or event.tick-area.last>INCIDENT_GAP
    if not area then
      local count=0
      for _ in pairs(s.damage) do count=count+1 end
      if count>=MAX_AREAS then
        -- Forget the quietest area to stay bounded.
        local oldest
        for k,v in pairs(s.damage) do if not oldest or v.last<s.damage[oldest].last then oldest=k end end
        s.damage[oldest]=nil
      end
      area={}; s.damage[key]=area
    end
    if fresh then
      -- A quiet minute ends an incident; the next hit starts a new one.
      s.incident_seq=(s.incident_seq or 0)+1
      area.id,area.first,area.hits,area.damage,area.entities,area.by=s.incident_seq,event.tick,0,0,{},nil
      area.at={x=round(e.position.x),y=round(e.position.y)}; area.surface=surface and surface.name or nil
      area.units,area.kinds,area.size,area.source,area.source_tried,area.group={},{},0,nil,nil,nil
      -- A visible group that gathered in the last 3 minutes heading here.
      for k=#(s.attack_groups or {}),1,-1 do
        local g=s.attack_groups[k]
        if event.tick-g.tick>10800 then break end
        if g.target and (not g.surface or g.surface==area.surface) and api.distance(g.target,area.at)<=GROUP_MATCH then area.group={size=g.size,kinds=g.kinds,position=g.position}; break end
      end
    end
    -- Every hit is numbered so reply hints can say exactly what is new.
    s.alert_seq=(s.alert_seq or 0)+1; area.seq=s.alert_seq
    area.last=event.tick; area.hits=area.hits+1; area.damage=area.damage+(event.final_damage_amount or 0)
    area.entities[e.name]=(area.entities[e.name] or 0)+1
    local cause=event.cause and event.cause.valid and event.cause or nil
    area.by=cause and cause.name or area.by
    if cause then
      local id=cause.unit_number
      if id and area.size<MAX_UNITS and not area.units[id] then
        area.units[id]=true; area.size=area.size+1; area.kinds[cause.name]=(area.kinds[cause.name] or 0)+1
      end
      -- The source is looked up once per incident, on the first hit by a unit.
      if not area.source_tried and e.surface then
        area.source_tried=true
        local ok,src=pcall(M.source,e.force,e.surface,area.at,cause)
        area.source=ok and src or nil
      end
    end
    if api.on_character_hit and e.type=='character' then api.on_character_hit(event) end
  end
  local function ago(ticks)
    local sec=math.floor(ticks/60)
    if sec>=3600 then return string.format('%dh%02dm',math.floor(sec/3600),math.floor(sec/60)%60) end
    if sec>=60 then return string.format('%dm%02ds',math.floor(sec/60),sec%60) end
    return sec..'s'
  end
  -- One line per incident: where, who, from where, what was hit, when.
  -- `again`: the same incident told to the same reader before. `reader`: the
  -- reader's surface name; an incident elsewhere names its surface (with no
  -- reader, an operator read, any surface but nauvis).
  function M.attack_line(v,again,reader)
    local names={}
    for name,count in pairs(v.entities or {}) do names[#names+1]=name..' x'..count end
    table.sort(names)
    while #names>5 do table.remove(names) end
    local who
    if v.group then
      who=string.format('a group of %d%s that gathered at (%d,%d)',v.group.size,v.group.kinds and ' ('..v.group.kinds..')' or '',v.group.position.x,v.group.position.y)
    elseif (v.size or 0)>0 then who=string.format('%d attacker%s seen (%s)',v.size,v.size==1 and '' or 's',kinds_text(v.kinds))
    elseif v.by then who='by '..v.by end
    local from
    if v.source then
      from=string.format('%s nest (%d,%d) %d tiles %s',v.source.spawned and 'from' or 'likely from',v.source.position.x,v.source.position.y,v.source.distance,v.source.bearing)
    elseif v.source_tried then from=string.format('no charted nest within %d tiles',SOURCE_RANGE) end
    local at=v.at or {x=0,y=0}
    local span=v.first and v.first<v.last and 'first '..ago(game.tick-v.first)..' ago, last '..ago(game.tick-v.last)..' ago' or ago(game.tick-v.last)..' ago'
    local on=v.surface and v.surface~=(reader or 'nauvis') and ' on '..v.surface or ''
    return string.format('attack #%d%s at (%d,%d)%s: %s%s%s hit %d times, %d damage, %s',v.id or 0,on,at.x,at.y,again and ' continues' or '',
      who and who..'; ' or '',from and from..'; ' or '',table.concat(names,', '),v.hits,round(v.damage),span)
  end
  function M.alerts(since,reader)
    local s,out=api.state(),{}
    local groups={}
    for _,g in ipairs(s.attack_groups or {}) do if g.tick>since then groups[#groups+1]=g end end
    local areas={}
    for key,v in pairs(s.damage or {}) do
      -- Zero-damage hits (the crash site's fire) are not an attack: readers took the wreck for one.
      if v.last>since and round(v.damage)>0 then
        -- Keys are surface:cx,cy (cx,cy before surfaces were kept).
        local cx,cy=key:match('(-?%d+),(-?%d+)$')
        local names={}
        for name,n in pairs(v.entities) do names[#names+1]=name..' x'..n end
        table.sort(names)
        areas[#areas+1]={id=v.id,surface=v.surface,at=v.at,chunk_centre=chunk_centre(tonumber(cx),tonumber(cy)),hits=v.hits,damage=round(v.damage),first_tick=v.first,last_tick=v.last,
          by=v.by,entities=table.concat(names,', '),attackers=(v.size or 0)>0 and v.size or nil,kinds=(v.size or 0)>0 and kinds_text(v.kinds) or nil,
          group=v.group,source=v.source,line=v.id and v.at and M.attack_line(v,false,reader) or nil}
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
