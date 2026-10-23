-- Enemy and pollution awareness: evolution, the pollution cloud and which
-- spawners it reaches, plus attack alerts. Only what a player could see: the
-- pollution overlay and spawners on charted chunks, unit groups in visible ones.
-- The surface scan is cached because status is polled several times a second.
local snapfail=require('snapfail')
return function(api)
  local M={}
  local CACHE_TICKS,CHART_TICKS,MAX_BASE_RANGE,CLOUD_SEARCH,EVOLUTION_WINDOW,MAX_NEWS=600,3600,512,8,18000,16
  local NEAR_TICKS,CLOUD_TICKS,FORGET_TICKS,FRESH=18000,3600,108000,2  -- per base: 5 min, 1 min, forgotten after 30 min; searches per call
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
  -- (d22 batch110 BT1: the background sweep made a chunk position and a centre table for each chunk, 16 to 2000 a
  -- tick) one position each, filled in place for the game's reads (read, not kept)
  local SWEEP_CHUNK,CHUNK_CENTRE={x=0,y=0},{x=0,y=0}
  -- (BT1) the background steps' force by name and surface by index, kept while valid: the same object the game's
  -- lookup gives (a force's name and a surface's index do not change); module state
  local forces_kept,surfaces_kept={},{}
  local function force_named(name)
    local f=name~=nil and forces_kept[name]
    if f and f.valid then return f end
    f=game.forces[name]
    if name~=nil then forces_kept[name]=f end
    return f
  end
  local function surface_at(index)
    local s=index~=nil and surfaces_kept[index]
    if s and s.valid then return s end
    s=game.get_surface(index)
    if index~=nil then surfaces_kept[index]=s end
    return s
  end
  -- (BT1) a table's keys sorted, the list kept while the keys are the same (a new list only when they change; a list
  -- given out is never changed)
  local sorted_kept={}
  local NO_KEYS={}
  local function sorted_keys(t,slot)
    t=t or NO_KEYS
    local kept=sorted_kept[slot]
    if kept then
      local n,same=0,true
      for k in pairs(t) do n=n+1; if not kept.set[k] then same=false; break end end
      if same and n==#kept.list then return kept.list end
    end
    local list,set={},{}
    for k in pairs(t) do list[#list+1]=k; set[k]=true end
    table.sort(list)
    sorted_kept[slot]={list=list,set=set}
    return list
  end

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
  -- The spawners within MAX_BASE_RANGE of the agent (operator 18:33: threat.watch 93 ms in one reply, a find over
  -- the ~800 chunks of that circle): from the force's spawner index for the surface (M.tick builds it in bands over
  -- every circle asked for, SPAWN_TICKS old at most) when the index covers the circle, else found at once. An entity
  -- counts when its box reaches the circle, as the find has it; south to north, then west to east, either way.
  local SPAWN_TICKS,SPAWN_KEEP,SPAWN_BAND=3600,36000,32
  local function spawn_key(p) return p.force.name..'/'..p.surface.index end
  local function box_within(e,c,r)
    local ok,b=pcall(function() return e.bounding_box end)
    local x0,y0,x1,y1=e.position.x,e.position.y,e.position.x,e.position.y
    if ok and b and b.left_top then x0,y0,x1,y1=b.left_top.x,b.left_top.y,b.right_bottom.x,b.right_bottom.y end
    local dx=math.max(x0-c.x,0,c.x-x1)
    local dy=math.max(y0-c.y,0,c.y-y1)
    return dx*dx+dy*dy<=r*r
  end
  -- (d19 batch45: threat.watch was 35 ms on the private copy's Nauvis, 430 spawners: 5 ms the sort reading positions
  -- in its comparison, 13 ms the clustering) each spawner's position read once: {e, position}
  local function by_position(a,b)
    if a.position.y~=b.position.y then return a.position.y<b.position.y end
    return a.position.x<b.position.x
  end
  local function spawners_near(p)
    local st=api.state()
    local s,centre=p.surface,p.position
    local key=spawn_key(p)
    -- (the circle asked for, so the next index covers it)
    st.spawn_want=st.spawn_want or {}
    local want=st.spawn_want[key] or {}
    st.spawn_want[key]=want
    want[p.index]={tick=game.tick,x=centre.x,y=centre.y}
    local idx=(st.spawn_index or {})[key]
    local m=MAX_BASE_RANGE/32
    local found
    if idx and game.tick-idx.tick<2*SPAWN_TICKS and math.floor(centre.x/32-m)>=idx.box.left and math.floor(centre.x/32+m)<=idx.box.right
      and math.floor(centre.y/32-m)>=idx.box.top and math.floor(centre.y/32+m)<=idx.box.bottom then
      found={}
      for _,e in ipairs(idx.list) do if e.valid and box_within(e,centre,MAX_BASE_RANGE) then found[#found+1]=e end end
    else
      found=s.find_entities_filtered{type='unit-spawner',position=centre,radius=MAX_BASE_RANGE}
    end
    local keyed={}
    for i,e in ipairs(found) do keyed[i]={e=e,position=e.position} end
    table.sort(keyed,by_position)
    return keyed
  end
  -- The index's background pass: the chunk box of every circle asked for in the last SPAWN_KEEP ticks, a band of up to
  -- SPAWN_BAND chunks of one row a step, the steps spread over half of SPAWN_TICKS.
  function M.spawn_step(st,key,tick)
    st.spawn_jobs=st.spawn_jobs or {}
    st.spawn_index=st.spawn_index or {}
    local job,idx=st.spawn_jobs[key],st.spawn_index[key]
    local force_name,index=key:match('^(.*)/(%d+)$')
    local force,s=force_named(force_name),surface_at(tonumber(index))
    if not (force and s) then st.spawn_jobs[key],st.spawn_index[key],st.spawn_want[key]=nil,nil,nil; return end
    if not job then
      if idx and tick-idx.start<SPAWN_TICKS then return end
      local b,m={},math.ceil(MAX_BASE_RANGE/32)+1
      for i,w in pairs(st.spawn_want[key]) do
        if tick-w.tick>SPAWN_KEEP then st.spawn_want[key][i]=nil
        else
          local cx,cy=math.floor(w.x/32),math.floor(w.y/32)
          b.left=math.min(b.left or cx-m,cx-m); b.right=math.max(b.right or cx+m,cx+m)
          b.top=math.min(b.top or cy-m,cy-m); b.bottom=math.max(b.bottom or cy+m,cy+m)
        end
      end
      if not b.left then st.spawn_want[key]=nil; st.spawn_index[key]=nil; return end
      local steps=(b.bottom-b.top+1)*math.ceil((b.right-b.left+1)/SPAWN_BAND)
      st.spawn_jobs[key]={start=tick,box=b,x=b.left,y=b.top,list={},last=tick,every=math.max(1,math.min(600,math.floor(SPAWN_TICKS*0.5/steps)))}
      return
    end
    if tick-job.last<job.every then return end
    job.last=tick
    local b=job.box
    local x1=math.min(job.x+SPAWN_BAND-1,b.right)
    local X0,Y0,X1,Y1=job.x*32,job.y*32,(x1+1)*32,(job.y+1)*32
    for _,e in ipairs(s.find_entities_filtered{area={{X0,Y0},{X1,Y1}},type='unit-spawner'}) do
      local q=e.position
      if q.x>=X0 and q.x<X1 and q.y>=Y0 and q.y<Y1 and e.force~=force then job.list[#job.list+1]=e end
    end
    job.x=x1+1
    if job.x>b.right then job.x=b.left; job.y=job.y+1 end
    if job.y>b.bottom then
      st.spawn_index[key]={tick=job.start,start=job.start,box=b,list=job.list}
      st.spawn_jobs[key]=nil
    end
  end
  -- Spawners within range of the agent, clustered into bases. In steps (d19 batch45: a reply's watch, M.watch_step):
  -- bases_begin lists them, bases_slice clusters n more (nil: the rest), bases_end keeps what each base's position
  -- decides.
  local function bases_begin(p)
    return {found=spawners_near(p),i=1,out={},known={},visible={},surface=p.surface.index}
  end
  local function bases_slice(p,job,n)
    local s=p.surface
    local found,out,known,visible=job.found,job.out,job.known,job.visible
    local last=n and math.min(#found,job.i+n-1) or #found
    -- per chunk: known (a spawner of another force there, as api.known has it), visible
    for i=job.i,last do
      local e,q=found[i].e,found[i].position
      local key=math.floor(q.x/32)..','..math.floor(q.y/32)
      if known[key]==nil and e.valid then known[key]=api.known(p,e) and true or false end
      if e.valid and known[key] and e.type=='unit-spawner' and e.force~=p.force then
        local base
        for _,b in ipairs(out) do local dx,dy=b.fx-q.x,b.fy-q.y; if dx*dx+dy*dy<=4096 then base=b; break end end
        if not base then base={fx=q.x,fy=q.y,sx=0,sy=0,spawners=0,chunks={},keys={},absorbing=0}; out[#out+1]=base end
        base.sx=base.sx+q.x; base.sy=base.sy+q.y; base.spawners=base.spawners+1
        if not base.chunks[key] then
          base.chunks[key]=true; base.keys[#base.keys+1]=key
          local amount,last=M.polluted(s,q)
          base.absorbing=base.absorbing+amount
          if last and (not base.polluted_tick or last>base.polluted_tick) then base.polluted_tick=last end
          if visible[key]==nil then visible[key]=p.force.is_chunk_visible(s,{x=math.floor(q.x/32),y=math.floor(q.y/32)}) end
          if visible[key] then base.visible=true end
        end
      end
    end
    job.i=last+1
    return job.i>#found
  end
  local function bases_end(p,job)
    local s,out=p.surface,job.out
    -- What a base's position alone decides (our nearest building, the cloud's
    -- gap) is kept per surface and base chunk for every agent: NEAR_TICKS and
    -- CLOUD_TICKS. At most FRESH searches per call (task-statuscost, 01:15 on
    -- world n: the ring searches made threat.summary 110 ms and threat.watch
    -- up to 123 ms); a base not searched yet has no distance ('?') and comes
    -- in a later call.
    local st=api.state()
    st.base_info=st.base_info or {}
    local info=st.base_info[s.index]
    if not info then info={}; st.base_info[s.index]=info end
    local fresh_left=FRESH
    for key,v in pairs(info) do if game.tick-v.tick>=FORGET_TICKS then info[key]=nil end end
    for _,b in ipairs(out) do
      b.position={x=round(b.sx/b.spawners),y=round(b.sy/b.spawners)}
      b.fx,b.fy,b.sx,b.sy,b.chunks=nil,nil,nil,nil,nil
      b.absorbing=round(b.absorbing)
      b.reached=M.reached(b.polluted_tick)
      local key=math.floor(b.position.x/32)..','..math.floor(b.position.y/32)
      local kept=info[key]
      if kept and game.tick-kept.tick<NEAR_TICKS then
        b.distance,b.direction=kept.distance,kept.direction
      elseif fresh_left>0 then
        fresh_left=fresh_left-1
        kept={tick=game.tick}
        -- Nearest of our buildings, searched in widening rings.
        for _,r in ipairs{64,128,256,MAX_BASE_RANGE} do
          local ours={}
          for _,e in pairs(s.find_entities_filtered{position=b.position,radius=r,force=p.force,limit=256}) do
            if e.valid and not NOT_BUILDING[e.type] then ours[#ours+1]=e end
          end
          local near=#ours>0 and s.get_closest(b.position,ours)
          if near then
            kept.distance=round(api.distance(b.position,near.position)); kept.direction=compass(near.position,b.position); break
          end
        end
        info[key]=kept
        b.distance,b.direction=kept.distance,kept.direction
      elseif kept then b.distance,b.direction=kept.distance,kept.direction  -- older than NEAR_TICKS: searched again in a later call
      else b.distance_pending=true end
      if not b.reached then
        if kept and kept.cloud_tick and game.tick-kept.cloud_tick<CLOUD_TICKS then
          b.cloud_gap,b.cloud_direction=kept.cloud_gap,kept.cloud_direction
        elseif kept and kept.tick==game.tick or fresh_left>0 then
          if not (kept and kept.tick==game.tick) then fresh_left=fresh_left-1 end
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
          kept=info[key] or {tick=game.tick}
          info[key]=kept
          kept.cloud_tick,kept.cloud_gap,kept.cloud_direction=game.tick,b.cloud_gap,b.cloud_direction
        end
      end
    end
    table.sort(out,function(a,b) return (a.distance or math.huge)<(b.distance or math.huge) end)
    return out
  end
  local function bases(p)
    local job=bases_begin(p)
    bases_slice(p,job)
    return bases_end(p,job)
  end

  -- Chart coverage and the charted extent of the pollution cloud; polluted
  -- chunks beyond the chart only reveal in which directions the cloud leaves it.
  -- In pieces: a tally, one generated chunk into it, the result (chart() all
  -- at once over get_chunks; the background sweep, M.tick, over the box of
  -- generated chunks the last chart saw plus a margin, SWEEP a tick).
  local function grow(b,x,y)
    b.left=math.min(b.left or x,x); b.right=math.max(b.right or x,x)
    b.top=math.min(b.top or y,y); b.bottom=math.max(b.bottom or y,y)
  end
  local function chart_new(s,force)
    local c=force.get_spawn_position(s)
    return {charted=0,visible=0,polluted=0,box={},cloud={},beyond={},gen={},centre={x=c.x,y=c.y},cells={}}
  end
  -- The cloud layer for the stream map (viewer Joonazan, operator 13:02: Gleba's spore cloud): each charted chunk's
  -- amount as the game's map pollution layer shows it, {cx, cy, amount}, at most MAX_CELLS (the sweep reads it anyway).
  local MAX_CELLS=6000
  local function chart_chunk(t,s,force,c)
    grow(t.gen,c.x,c.y)
    local is_charted=force.is_chunk_charted(s,c)
    if is_charted then
      t.charted=t.charted+1; grow(t.box,c.x,c.y)
      if force.is_chunk_visible(s,c) then t.visible=t.visible+1 end
    end
    CHUNK_CENTRE.x,CHUNK_CENTRE.y=c.x*32+16,c.y*32+16
    local amount=s.get_pollution(CHUNK_CENTRE)
    if amount>0 then
      if is_charted then
        t.polluted=t.polluted+1; grow(t.cloud,c.x,c.y)
        t.cells=t.cells or {}
        if #t.cells<MAX_CELLS then t.cells[#t.cells+1]={c.x,c.y,math.floor(amount*10+0.5)/10} end
      else t.beyond[compass(t.centre,chunk_centre(c.x,c.y))]=true end
    end
  end
  -- The surface's pollutant (2.0: pollution on Nauvis, spores on Gleba, none on Vulcanus/Fulgora) and its map colour.
  local function pollutant(s)
    local ok,p=pcall(function() return s.pollutant_type end)
    if not (ok and p) then return nil end
    local okc,c=pcall(function() return p.chart_color end)
    return {name=p.name,color=okc and c and {r=c.r or c[1],g=c.g or c[2],b=c.b or c[3],a=c.a or c[4]} or nil}
  end
  local function chart_done(t,s,force,tick)
    local function extent(b)
      return b.left and string.format('x %d..%d y %d..%d',b.left*32,b.right*32+31,b.top*32,b.bottom*32+31) or nil
    end
    local dirs={}
    for _,name in ipairs(names) do if t.beyond[name] then dirs[#dirs+1]=name end end
    return {tick=tick or game.tick,charted_chunks=t.charted,visible_chunks=t.visible,extent=extent(t.box),
      radars=#s.find_entities_filtered{type='radar',force=force},gen=t.gen,
      cloud={chunks=t.polluted,extent=extent(t.cloud),beyond_chart=#dirs>0 and table.concat(dirs,',') or nil},
      cells=t.cells or {},pollutant=pollutant(s)}
  end
  local function chart(p)
    local s,force=p.surface,p.force
    local t=chart_new(s,force)
    for c in s.get_chunks() do chart_chunk(t,s,force,c) end
    return chart_done(t,s,force)
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
    e.force,e.surface=p.force.name,p.surface.index
    -- With the background sweep running (M.tick) the chart is redone there; here only when asked (threats=true),
    -- when there is none, or when it lacks the box the sweep starts from.
    if fresh or not e.chart or not e.chart.gen or (not st.chart_bg and game.tick-e.chart.tick>=CHART_TICKS) then e.chart=chart(p) end
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
  -- The background chart (task-statuscost: the chart walk went over every
  -- generated chunk in one status call once a minute per surface): started
  -- when a surface's chart is CHART_TICKS old, it sweeps the box of generated
  -- chunks the last chart saw, grown by SWEEP_MARGIN and to every player on
  -- the surface, SWEEP chunk positions a tick; its state is in storage.
  -- Operator 18:12 (threat.tick 83 ms in one game second at 17:53): SWEEP a tick finished a big surface's sweep in a
  -- few ticks; now the box's chunk positions spread over SWEEP_TICKS, at least SWEEP_MIN and at most SWEEP a tick.
  local SWEEP,SWEEP_MARGIN,SWEEP_TICKS,SWEEP_MIN=2000,4,1800,16
  function M.tick(tick)
    local st=api.state()
    st.chart_bg=true
    st.chart_jobs=st.chart_jobs or {}
    local keys=sorted_keys(st.threat_shared,'shared')
    for _,key in ipairs(keys) do
      -- A step that fails ends its sweep (noted in chart_errors and on the chart, snapfail.lua); the chart keeps the tick
      -- it was made at and the next sweep starts CHART_TICKS after the failure.
      local e=st.threat_shared[key]
      local ok,err=pcall(M.sweep_step,st,key,e,tick)
      if not ok then
        st.chart_jobs[key]=nil
        st.chart_errors={count=((st.chart_errors or {}).count or 0)+1,last=tostring(err),tick=tick}
        if e.chart then e.chart.refresh_failed=snapfail.failed(err,tick) end
      end
    end
    -- A reply's nest watch (M.watch).
    M.watch_step(st,tick)
    -- The spawner index (spawners_near), per force and surface asked for.
    local wanted=sorted_keys(st.spawn_want,'want')
    for _,key in ipairs(wanted) do
      local ok,err=pcall(M.spawn_step,st,key,tick)
      if not ok then
        st.spawn_jobs[key]=nil
        st.spawn_errors={count=((st.spawn_errors or {}).count or 0)+1,last=tostring(err),tick=tick}
      end
    end
  end
  function M.sweep_step(st,key,e,tick)
    do
      local job=st.chart_jobs[key]
      local force=e.force and force_named(e.force)
      local s=e.surface and surface_at(e.surface)
      if not job then
        local g=e.chart and e.chart.gen
        if g and force and s and tick-math.max(snapfail.since(e.chart.tick,e.chart.refresh_failed),e.chart.idle_tick or e.chart.tick)>=CHART_TICKS then
          local b={}
          if g.left then b={left=g.left-SWEEP_MARGIN,right=g.right+SWEEP_MARGIN,top=g.top-SWEEP_MARGIN,bottom=g.bottom+SWEEP_MARGIN} end
          for _,pl in pairs(game.players or {}) do
            local ok,here=pcall(function() return pl.surface.index==s.index and pl.position end)
            if ok and here then grow(b,math.floor(here.x/32)-SWEEP_MARGIN,math.floor(here.y/32)-SWEEP_MARGIN); grow(b,math.floor(here.x/32)+SWEEP_MARGIN,math.floor(here.y/32)+SWEEP_MARGIN) end
          end
          if b.left then
            local per=math.min(SWEEP,math.max(SWEEP_MIN,math.ceil((b.right-b.left+1)*(b.bottom-b.top+1)/SWEEP_TICKS)))
            st.chart_jobs[key]={start=tick,left=b.left,right=b.right,top=b.top,bottom=b.bottom,x=b.left,y=b.top,per=per}
          else e.chart.idle_tick=tick end  -- no generated chunk and nobody there: nothing to sweep (the chart's tick stays)
        end
      elseif not (force and s) then st.chart_jobs[key]=nil
      else
        job.t=job.t or chart_new(s,force)
        local n=0
        local c=SWEEP_CHUNK
        while n<(job.per or SWEEP) and job.y<=job.bottom do
          c.x,c.y=job.x,job.y
          if s.is_chunk_generated(c) then chart_chunk(job.t,s,force,c) end
          n=n+1; job.x=job.x+1
          if job.x>job.right then job.x=job.left; job.y=job.y+1 end
        end
        if job.y>job.bottom then
          -- (a chart made since the sweep started, threats=true, is newer: the sweep's is dropped)
          if not snapfail.older(job.start,e.chart and e.chart.tick) then e.chart=chart_done(job.t,s,force,job.start) end
          st.chart_jobs[key]=nil
        end
      end
    end
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
    -- (d19 batch45: 25-35 ms in the reply with 430 spawners in range on the private copy's Nauvis) asked here, read in
    -- the background (M.watch_step)
    st.watch_jobs=st.watch_jobs or {}
    st.watch_jobs[p.index]=st.watch_jobs[p.index] or {asked=game.tick}
  end
  -- One agent's watch at a time, a step a tick: its spawners listed, WATCH_SLICE of them clustered a tick, then what
  -- each base's position decides (FRESH searches at most) and the news. A step that fails ends that watch
  -- (watch_errors).
  local WATCH_SLICE=64
  function M.watch_step(st,tick)
    local jobs=st.watch_jobs
    if not (jobs and next(jobs)) then return end
    local index
    for i in pairs(jobs) do if not index or i<index then index=i end end
    local job=jobs[index]
    local ok,err=pcall(function()
      local p=api.lookup and api.lookup(index)
      if not (p and p.valid and p.character and p.character.valid) or (job.surface and job.surface~=p.surface.index) then jobs[index]=nil; return end
      if not job.found then
        for k,v in pairs(bases_begin(p)) do job[k]=v end
        return
      end
      if not bases_slice(p,job,WATCH_SLICE) then return end
      jobs[index]=nil
      note_bases(p,bases_end(p,job))
    end)
    if not ok then
      jobs[index]=nil
      st.watch_errors={count=((st.watch_errors or {}).count or 0)+1,last=tostring(err),tick=tick}
    end
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
      chart={charted_chunks=c.charted_chunks,visible_chunks=c.visible_chunks,extent=c.extent,radars=c.radars,
        refresh_failed=snapfail.line('the chart',c.tick,c.refresh_failed)}}
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
    -- (d22 batch100 BJ2) 2.0.77 keeps a unit's spawner on its commandable (unit.spawner is no key: the read failed),
    -- and the spawner is userdata (a check for a table refused it): this branch never ran on the real engine
    local ok,own=pcall(function() return unit and unit.valid and unit.commandable and unit.commandable.spawner end)
    if ok and own and own.valid and charted(force,surface,own.position) then
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
  -- The cloud layer (viewer Joonazan, operator 13:02): per surface an agent is on (the background chart's last
  -- sweep, about once a minute), every charted chunk's pollution or spores {cx, cy, amount} as the game's map
  -- pollution layer shows them, the pollutant's name and map colour, and the nests the cloud reached lately (the
  -- pollution_reached_nest news). a.surface: one surface by name.
  function M.operator.clouds(a)
    local st=api.state()
    local out={}
    local keys={}
    for key in pairs(st.threat_shared or {}) do keys[#keys+1]=key end
    table.sort(keys)
    for _,key in ipairs(keys) do
      local e=st.threat_shared[key]
      local s=e.surface and game.get_surface(e.surface)
      local c=e.chart
      if s and c and c.cells and (not a or a.surface==nil or a.surface==s.name) then
        local mx,total=0,0
        for _,cell in ipairs(c.cells) do total=total+cell[3]; if cell[3]>mx then mx=cell[3] end end
        local reached={}
        for _,n in ipairs(st.enemy_news or {}) do
          if n.kind=='pollution_reached_nest' and n.surface==s.name then reached[#reached+1]={tick=n.tick,position=n.position,spawners=n.spawners} end
        end
        out[#out+1]={surface=s.name,force=e.force,tick=c.tick,pollutant=c.pollutant,cells=c.cells,chunks=#c.cells,max=mx,total=math.floor(total),
          reached=#reached>0 and reached or nil}
      end
    end
    return {clouds=out,tick=game.tick}
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
  -- Big enemies on their way (operator `big_enemies_live`; Nick, 14:44: "The demolisher approaching should be good
  -- in a PIP camera"): segmented units (demolishers) on each planet, found by a type search every SCAN_TICKS and
  -- kept by reference in between (a few per surface), each with where it is, how fast it moves, our nearest building
  -- and character within BIG_RANGE and whether it is closing on them. Big biters and behemoths come as unit groups
  -- (attack_groups_live). Read-only; the cost is one search per planet every 10 s and two radius searches per unit.
  local SCAN_TICKS,BIG_RANGE,MAX_BIG=600,500,12
  local function scan_big(s)
    local found={}
    for _,surface in pairs(game.surfaces) do
      if not surface.platform then
        local ok,list=pcall(function() return surface.find_entities_filtered{type='segmented-unit',force='enemy'} end)
        if ok then
          for _,e in ipairs(list) do
            if e.valid and #found<MAX_BIG then found[#found+1]={entity=e,id=e.unit_number,name=e.name,surface=surface.name} end
          end
        end
      end
    end
    s.big_enemies,s.big_scan=found,game.tick
  end
  -- Our nearest building (or character, with type='character') within BIG_RANGE.
  local function nearest_of(surface,pos,type_name)
    local list={}
    for _,force in pairs(game.forces) do
      if force.name~='enemy' and force.name~='neutral' and #force.players>0 then
        local f={position=pos,radius=BIG_RANGE,force=force,limit=300,type=type_name}
        for _,e in pairs(surface.find_entities_filtered(f)) do
          if e.valid and (type_name or not NOT_BUILDING[e.type]) then list[#list+1]=e end
        end
      end
    end
    return #list>0 and surface.get_closest(pos,list) or nil
  end
  function M.operator.big_enemies_live(a)
    local s=api.state()
    if not s.big_enemies or game.tick-(s.big_scan or -SCAN_TICKS)>=SCAN_TICKS then scan_big(s) end
    s.big_seen=s.big_seen or {}
    local out,keep,seen={},{},{}
    for _,r in ipairs(s.big_enemies) do
      local e=r.entity
      local ok,valid=pcall(function() return e and e.valid end)
      if ok and valid then
        keep[#keep+1]=r
        local pos,surface=e.position,e.surface
        local building=nearest_of(surface,pos,nil)
        local character=nearest_of(surface,pos,'character')
        local prev=s.big_seen[r.id]
        local speed,closing
        local bd=building and api.distance(pos,building.position)
        if prev and game.tick>prev.tick then
          speed=api.distance(prev.position,pos)/((game.tick-prev.tick)/60)
          if bd and prev.building_distance then closing=bd<prev.building_distance-0.5 end
        end
        seen[r.id]={position={x=pos.x,y=pos.y},tick=game.tick,building_distance=bd}
        if building or character then
          out[#out+1]={id=r.id,name=r.name,surface=r.surface,position={x=round(pos.x),y=round(pos.y)},
            speed=speed and round(speed,2) or nil,closing=closing,
            nearest=building and {x=round(building.position.x),y=round(building.position.y),name=building.name} or nil,
            nearest_distance=bd and round(bd) or nil,
            eta_s=closing and speed and speed>0.05 and bd and round(bd/speed) or nil,
            character=character and {x=round(character.position.x),y=round(character.position.y),
              player=character.player and character.player.name or nil} or nil,
            character_distance=character and round(api.distance(pos,character.position)) or nil}
        end
      end
    end
    s.big_enemies,s.big_seen=keep,seen
    return {ok=true,tick=game.tick,enemies=out}
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
  -- Enemy groups our force sees now round a point (batch24 C2, Haiku: a 1,194-item corpse sat near a wave for minutes):
  -- the live groups (gathered with a target) whose units stand in a chunk our force sees now, within radius of pos:
  -- {size, kinds, position, distance, heading (compass, from where it gathered to where it is), closing (its distance to
  -- pos now under where it gathered, or its target within 32 tiles of pos), target_distance}, nearest first; and a line.
  function M.groups_near(force,surface,pos,radius)
    local out={}
    for _,r in ipairs(api.state().live_groups or {}) do
      local g=r.group
      local ok,valid=pcall(function() return g and g.valid end)
      if ok and valid and r.surface==surface.name then
        local members=g.members or {}
        local at=g.position
        local seen=#members>0 and force.is_chunk_visible(surface,{x=math.floor(at.x/32),y=math.floor(at.y/32)})
        local d=api.distance(at,pos)
        if seen and d<=radius then
          local from=r.gathered or at
          local dx,dy=at.x-from.x,at.y-from.y
          local heading=(dx*dx+dy*dy)>=4 and compass(from,at) or 'still'
          local target=command_target(g.command) or r.target
          local closing=(target and api.distance(target,pos)<=32) or d<api.distance(from,pos)-2
          out[#out+1]={size=#members,kinds=kinds_text(member_kinds(members)),position={x=round(at.x),y=round(at.y)},distance=round(d),
            heading=heading,closing=closing or nil,target_distance=target and round(api.distance(at,target)) or nil}
        end
      end
    end
    table.sort(out,function(a,b) return a.distance<b.distance end)
    return out
  end
  function M.groups_line(list)
    if #list==0 then return 'no enemy group our force sees within reach of it' end
    local parts={}
    for i,g in ipairs(list) do
      if i<=4 then parts[#parts+1]=string.format('a group of %d (%s) at (%d,%d), %d tiles off, moving %s%s',g.size,g.kinds,g.position.x,g.position.y,g.distance,g.heading,g.closing and ', closing on it' or '') end
    end
    return 'enemy groups our force sees: '..table.concat(parts,'; ')..(#list>4 and string.format('; +%d more',#list-4) or '')
  end
  return M
end
