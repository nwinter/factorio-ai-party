-- Wait estimates from the predicate's own observation and existing rate/queue reads. No entity searches here.
return function(api)
  local M={}
  local function try(fn) local ok,v=pcall(fn); if ok then return v end end
  local function label(c)
    local text=c['until']..(c.technology and ' '..c.technology or c.item and ' '..c.item or c.platform and ' '..c.platform or '')
    if c['until']=='platform_ammo_below' then text=text..(c.area and ' in an area of ' or c.loop and ' in a belt loop of ' or ' aboard ')..tostring(c.platform)  -- (d22 batch117 BZ1) every place aboard; (d24 batch173) or a scope
    elseif c['until']=='pod_landed' then text='pod_landed '..(c.item or 'pods')..' landed from '..tostring(c.platform)..(c.since_tick and ' since tick '..c.since_tick or '')  -- (d25 batch205 QR1) pods sent down, not the hub
    elseif c.item and c.platform then text=text..' in '..c.platform..' hub'
    elseif c.positions or c.position then
      local positions=c.positions or {c.position}; local parts={}
      for i=1,math.min(#positions,4) do
        local p=positions[i]; parts[#parts+1]='('..tostring(p.x or p[1])..','..tostring(p.y or p[2])..')'
      end
      text=text..' at '..table.concat(parts,' ')
      if #positions>4 then text=text..' and '..(#positions-4)..' more positions' end
    elseif c.item then text=text..' in character inventory' end
    return text:gsub('[\r\n]+',' ')
  end
  local function research(p,c)
    local force=p.force
    if force.research_enabled==false then return nil,'research is disabled' end
    local current=force.current_research
    if not current then return nil,'no research is running' end
    local rate,window,fallback=api.research_rate(force.name)
    if not rate or rate<=0 then return nil,'no measured research throughput' end
    if fallback then return nil,'no research progress in the last minute' end
    local work,found=0,false
    local queue=force.research_queue or {current}
    if #queue==0 then queue={current} end
    for i,t in ipairs(queue) do
      if i>128 then return nil,'target is beyond the first 128 queued technologies' end
      if not t.researched then
        local progress=t.name==current.name and (force.research_progress or 0) or (try(function() return t.saved_progress end) or 0)
        local count,energy=t.research_unit_count,t.research_unit_energy
        if not count or not energy or count<=0 or energy<=0 then return nil,'queued research has no lab-work rate' end
        work=work+(1-progress)*count*energy
      end
      if t.name==c.technology then found=true; break end
    end
    if not found then return nil,'technology is not in the current research queue' end
    return work/rate/60,nil,string.format('remaining queued lab work / throughput measured over %.0fs; unchanged throughput and pack supply',window/60)
  end
  local function rocket(c,o)
    local e=o.entity
    if c.at_least and c.at_least>o.required then return nil,'threshold exceeds the parts in one rocket' end
    if o.parts>=o.required then return nil,'rocket is rising; launch-ready timing is not measured' end
    if not try(function() return e.is_crafting() end) then return nil,'silo is not crafting rocket parts' end
    local recipe=try(function() return e.get_recipe() end)
    local speed=try(function() return e.crafting_speed end)
    if not recipe or not speed or speed<=0 then return nil,'no rocket-part crafting rate' end
    local prod=1+math.min((try(function() return e.productivity_bonus end) or 0)+(try(function() return e.force.recipes[recipe.name].productivity_bonus end) or 0),
      try(function() return recipe.prototype.maximum_productivity end) or 3)
    local left=math.max(0,(c['until']=='rocket_parts' and c.at_least or o.required)-o.parts)
    local crafts=math.ceil(left/prod-1e-9)
    local progress=try(function() return e.crafting_progress end) or 0
    local seconds=math.max(0,crafts-progress)*recipe.energy/speed
    return seconds,nil,'remaining parts / current crafting cadence, including productivity; uninterrupted crafting'
  end
  local function items(c,o,record)
    record.wait_samples=record.wait_samples or {}
    local key=label(c)..' '..tostring(o.scope or '')
    local old=record.wait_samples[key]
    if not old then old={tick=game.tick,value=o.value}; record.wait_samples[key]=old end
    local dt=game.tick-old.tick
    if dt>=60 then
      old.rate=(o.value-old.value)/(dt/60); old.window=dt/60
      old.tick,old.value=game.tick,o.value
    end
    if not old.rate then return nil,'needs two inventory observations at least 1 game second apart' end
    if old.rate==0 then return nil,'no net inventory change in the measured interval' end
    if c.at_least and c.below and c.at_least>=c.below then return nil,'item thresholds cannot both hold' end
    local target=(c.at_least and o.value<c.at_least) and math.ceil(c.at_least) or math.ceil(c.below)-1
    local seconds=(target-o.value)/old.rate
    if seconds<0 then return nil,'inventory trend is moving away from the threshold' end
    return seconds,nil,string.format('net %+.3g items/s at this inventory/place over %.1fs; unchanged net rate',old.rate,old.window)
  end
  function M.estimate(p,c,met,o,record)
    local row={condition=label(c),as_of_tick=game.tick}
    local seconds,unknown,basis
    if met then seconds,basis=0,'condition holds now'
    elseif c['until']=='researched' then seconds,unknown,basis=research(p,c)
    elseif c['until']=='crafting_done' then
      seconds=api.crafting_left(p)
      if not seconds or seconds<=0 then seconds=nil; unknown='no hand-crafting time available'
      else basis='remaining hand-crafting queue at current hand-crafting speed' end
    elseif c['until']=='item_count' and o then seconds,unknown,basis=items(c,o,record)
    elseif (c['until']=='rocket_ready' or c['until']=='rocket_parts') and o then
      seconds,unknown,basis=rocket(c,o)
      if seconds and c['until']=='rocket_ready' then
        row.parts_eta_s=math.ceil(seconds); row.parts_basis=basis
        seconds=nil; unknown='launch-ready timing is not measured; parts ETA '..row.parts_eta_s..'s ('..basis..'), then rocket raising'
      end
    elseif c['until']=='platform_arrived' and o then
      local leg=o.leg
      if not leg then
        -- Before it leaves (Sonnet, every shift): its schedule, the stop's waits, the legs at its last speed.
        local est,why
        if api.before_departure and o.platform then est,why=api.before_departure(o.platform,c.location) end
        if est and est.eta_s then seconds=est.eta_s; basis='before departure: '..est.line:gsub('^ETA [%a ]-%d+s before departure: ','')
        elseif est then unknown=est.line
        else unknown='platform has not departed'..(why and '; '..why or '') end
      elseif c.location and leg.to~=c.location then
        -- Its later legs through the schedule (Sonnet: "current flight leg ends at gleba, not vulcanus").
        local est,why
        if api.before_departure and o.platform then est,why=api.before_departure(o.platform,c.location) end
        if est and est.eta_s then seconds=est.eta_s; basis='through its schedule: '..est.line:gsub('^ETA [%a ]-%d+s: ','')
        elseif est then unknown=est.line
        else unknown='current flight leg ends at '..leg.to..', not '..c.location..(why and '; '..why or '') end
      elseif o.paused then unknown='platform is paused; arrival rate is unavailable'
      elseif not leg.eta_ticks or leg.eta_ticks<=0 then unknown='current platform speed is zero or unavailable'
      else seconds=leg.eta_ticks/60; basis='distance left on current connection / current speed; unchanged speed, excludes later legs' end
    elseif c['until']=='tick_at_least' and type(c.tick)=='number' then seconds,basis=(c.tick-game.tick)/60,'the game tick it names'
    else unknown='no measured rate for this condition' end
    if type(seconds)=='number' and seconds==seconds and seconds>=0 and seconds<math.huge then
      row.eta_s=math.ceil(seconds); row.basis=basis
      row.line=string.format('%s: ETA %ds (%s)',row.condition,row.eta_s,basis)
    else
      row.no_estimate=unknown or 'estimate data unavailable'
      row.line=row.condition..': no estimate ('..row.no_estimate..')'
    end
    return row
  end
  function M.check(p,c,record)
    -- A predicate error must not leave a previous ETA attached to a failed wait.
    record.wait_estimates={{condition=label(c),as_of_tick=game.tick,no_estimate='condition is unavailable',
      line=label(c)..': no estimate (condition is unavailable)'}}
    local met,saw,o=api.check(p,c,record)
    local ok,row=pcall(M.estimate,p,c,met,o,record)
    if not ok then row={condition=label(c),as_of_tick=game.tick,no_estimate='estimate data unavailable',
      line=label(c)..': no estimate (estimate data unavailable)'} end
    record.wait_estimates={row}
    return met,saw,row
  end
  -- A platform wait with no timeout given (Luna 07:50: a queued platform_arrived timed out at the default 60 s with the
  -- ETA at 77 s): at its end while the ETA is known it goes on to the ETA plus a quarter and 10 s, at most 54000 ticks
  -- from its start; the new end tick, or nil.
  local EXTEND = {platform_arrived=true, platform_left=true}
  function M.extend(record, c, started)
    local row = record.wait_estimates and record.wait_estimates[1]
    if not (c and EXTEND[c['until']] and row and row.eta_s and started) then return nil end
    local limit = started + 54000
    if game.tick >= limit then return nil end
    local to = math.min(limit, game.tick + math.ceil(row.eta_s * 60 * 1.25) + 600)
    if to <= game.tick then return nil end
    record.extended = string.format('no timeout given: extended to the ETA %ds plus a quarter and 10 s (at most 54000 ticks from the start)', row.eta_s)
    return to
  end
  function M.info(out,record)
    out.idle_s=math.floor((record.idle_ticks or 0)/60)
    out.wait_estimates=record.wait_estimates
    out.matched=record.matched  -- (d23 batch127 CJ1) until=any: the member that held
    local lines={}
    for _,row in ipairs(record.wait_estimates or {}) do lines[#lines+1]=row.line end
    lines[#lines+1]=string.format('character idle %ds in this wait',out.idle_s)
    out.wait_line=table.concat(lines,'; '):gsub('[\r\n]+',' ')
    return out
  end
  -- Called inside the existing per-agent idle tick. No scans or rate reads; body actions that run during sleep
  -- remain work. A queue's wait is idle even in a repeating plan. Dead/aboard agents have no character to idle.
  function M.idle_tick(index)
    local s=api.state()
    local act=s.active and s.active[index]
    local q=s.queues and s.queues[index]
    local step=q and not q.paused and q.current
    local waiting=function(k) return k=='wait_until' or k=='wait_ticks' end
    local sleep=s.sleeps and s.sleeps[index]
    local remote=s.remote_queues and s.remote_queues[index]
    local remote_step=remote and not remote.paused and remote.current
    if not (sleep and not sleep.woke and game.tick<=sleep.until_tick or act and waiting(act.kind)
      or step and waiting(step.action) or remote_step and waiting(remote_step.action)) then return end
    if not api.has_body(index) then return end
    local idle=not api.busy(s,index) or (not act and step and waiting(step.action))
    if not idle then return end
    if sleep and not sleep.woke and game.tick<=sleep.until_tick then sleep.idle_ticks=(sleep.idle_ticks or 0)+1 end
    if act and waiting(act.kind) then act.idle_ticks=(act.idle_ticks or 0)+1 end
    local all={s.queues or {},s.remote_queues or {}}
    for name in pairs(s.platform_lanes or {}) do all[#all+1]=s['lane_queues|'..name] or {} end
    for _,queues in ipairs(all) do
      local lane=queues[index]; local st=lane and not lane.paused and lane.current
      if st and waiting(st.action) then st.idle_ticks=(st.idle_ticks or 0)+1 end
    end
  end
  return M
end
