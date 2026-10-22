-- The body scheduler keeps its original state and callbacks. The opt-in remote
-- scheduler has independent revisions, waits and failure policies, and no body controls.
return function(api)
  local base=api.scheduler
  local remote_api={}
  for k,v in pairs(api.base) do remote_api[k]=v end
  local WAITS={platform_arrived=true,platform_left=true,researched=true,platform_built=true}
  -- place_ghosts and deconstruct on a platform (Astra, d15 06:23: ship conversions held the body queue): marks and
  -- ghosts the hub's robots build, no body needed; platform_built waits for the foundation.
  local PLATFORM_WRITES={configure=true,circuit_set=true,circuit=true,wire=true,requests=true,flush=true,place_ghosts=true,deconstruct=true,platform_rearm=true}
  local BODY_READS={inventory=true,craftable=true,sleep_check=true,dry_run=true,screenshot=true}
  -- (d20 batch62 X3, Astra #1540: circuit_set took surface as a direct call and was refused in the remote lane) the
  -- writes whose direct call acts on a planet by remote view with surface (bots.lua SURFACE_ACTIONS) take it here too.
  local SURFACE_WRITES={configure=true,circuit_set=true,circuit=true,wire=true,requests=true,place_ghosts=true,deconstruct=true}
  -- (X3) waits on our machines, turrets, burners and tanks on a planet by remote view
  local SURFACE_WAITS={produced=true,ammo_below=true,fuel_below=true,fluid_count=true}
  local function check(action,a)
    a=a or {}
    if action=='wait_ticks' then return end
    if action=='wait_until' then
      -- (all: every member one the lane takes; Sol, board #874: a fuel and an oxidizer wait together)
      local function remote_ok(c)
        if type(c)~='table' then return false end
        if c['until']=='all' then
          if type(c.conditions)~='table' or #c.conditions==0 then return false end
          for _,m in ipairs(c.conditions) do if not remote_ok(m) then return false end end
          return true
        end
        return WAITS[c['until']] or (c['until']=='item_count' and (type(c.platform)=='string' and c.platform~='' or type(c.surface)=='string' and c.surface~=''))
          or ((c['until']=='produced' or c['until']=='fluid_count' or c['until']=='circuit_signal' or c['until']=='pod_landed') and type(c.platform)=='string' and c.platform~='')
          -- (d20 batch52 K1) the guns of a platform; (K2) a silo on a named planet
          or (c['until']=='ammo_below' and type(c.platform)=='string' and c.platform~='')
          -- (d20 batch55 P5, Sol #1400) a platform's losses since the wait began; its ghosts
          or ((c['until']=='platform_loss' or c['until']=='ghosts_waiting') and type(c.platform)=='string' and c.platform~='')
          -- (d22 batch92 BB1, BB2: Sol #1884, Astra #1886) a platform's hits or damage since the wait began; its
          -- accumulators' charge
          or ((c['until']=='platform_hit' or c['until']=='platform_damage' or c['until']=='platform_energy_below' or c['until']=='platform_progress') and type(c.platform)=='string' and c.platform~='')
          or ((c['until']=='rocket_ready' or c['until']=='rocket_parts' or SURFACE_WAITS[c['until']]) and type(c.surface)=='string' and c.surface~='')
      end
      assert(remote_ok(a),
        'remote lane wait_until supports platform_arrived, platform_left, platform_built, researched, item_count with platform or surface, produced, fluid_count, circuit_signal or pod_landed with platform, ammo_below with platform, platform_loss, platform_hit (platform_damage), platform_energy_below, platform_progress or ghosts_waiting with platform, rocket_ready, rocket_parts, produced, ammo_below, fuel_below or fluid_count with surface, and all of those')
      return
    end
    -- min_payload names its platforms (platforms, default all): no body (d17 batch20 A4, Sol).
    if action=='min_payload' then return end
    -- (d18 batch36 C4, Astra: steps[7] rotate refused in the remote lane) rotate by remote view, as its direct call takes
    -- it: on a platform (platform) or on a planet in a chunk our force sees (surface)
    if action=='rotate' then
      assert((type(a.platform)=='string' and a.platform~='') or (type(a.surface)=='string' and a.surface~=''),
        'remote lane rotate requires platform or surface (rotate by remote view, as the direct call takes it)')
      return
    end
    if action=='drop' or action=='platform_schedule' or PLATFORM_WRITES[action] then
      assert(type(a.platform)=='string' and a.platform~='' or SURFACE_WRITES[action] and type(a.surface)=='string' and a.surface~='',
        'remote lane '..action..' requires platform'..(SURFACE_WRITES[action] and ' or surface (by remote view, as the direct call takes them)' or ''))
      return
    end
    if action=='observe' then
      assert(a.platform or (a.scope and not BODY_READS[a.scope]), 'remote lane observe requires platform or a body-independent scope')
    end
    assert(api.is_read(action) and not BODY_READS[action], 'action '..action..' is not supported in the remote lane (no body steps)')
  end
  remote_api.queue_key='remote_queues'
  remote_api.check_step=check
  remote_api.player=function(index) return api.base.player(index,true) end
  remote_api.stop=function() end
  remote_api.stop_index=function() end
  remote_api.claim=nil
  remote_api.step_begin=nil
  remote_api.step_done=nil
  remote_api.moved_step=nil
  remote_api.simulate=nil
  remote_api.busy=function(p,action) return action=='drop' and api.base.busy(p,action) or false end
  -- Drop jobs already have a separate channel. A new drop waits for that channel;
  -- walking never blocks this lane, and a remote step never claims a body action.
  remote_api.direct_action=function(p,action) return action=='drop' and api.base.busy(p,'drop') and 'drop' or nil end
  local remote=api.factory(remote_api)
  -- A lane per platform (d17 batch21 D1, Sol: three couriers, and one platform's cargo wait held the other platforms'
  -- steps): lane "platform:NAME" is a remote lane of its own, its queues under storage key lane_queues|NAME; the
  -- names are kept in storage (platform_lanes) and each is ticked as the remote lane is.
  local engines={}
  local function M_key(name) return 'lane_queues|'..name end
  local function platform_engine(name)
    local e=engines[name]
    if e then return e end
    local papi={}
    for k,v in pairs(remote_api) do papi[k]=v end
    papi.queue_key=M_key(name)
    e=api.factory(papi)
    engines[name]=e
    local s=api.base.state(); s.platform_lanes=s.platform_lanes or {}; s.platform_lanes[name]=true
    return e
  end
  local function lane(a)
    local name=a and a.lane or 'body'
    if type(name)=='string' then
      local pl=name:match('^platform:(.+)$')
      if pl then return name,platform_engine(pl) end
    end
    assert(name=='body' or name=='remote','lane must be body, remote or platform:NAME (a remote lane of its own for that platform)')
    return name,name=='remote' and remote or base
  end
  local function each_platform(fn)
    local s=api.base.state()
    for name in pairs(s.platform_lanes or {}) do fn(name,platform_engine(name)) end
  end
  -- (d20 batch70 AF3) the submission the active step came in: kind (submit or repeat), the repeating job's name, the
  -- tick it was submitted and its step count; nil for a step from an earlier submission than the queue's latest.
  local function run_of(q)
    local r=q.plan
    if not (r and q.current and q.current.plan==r.id) then return nil end
    return {kind=r.kind,name=r.name,tick=r.tick,steps=r.steps}
  end
  local function brief(q)
    if not q then return {paused=true,pending=0,active=false} end
    local step=q.current
    local waiting=not q.paused and step and (step.action=='wait_until' or step.action=='wait_ticks') and
      {kind=step.action,condition=step.action=='wait_until' and step.args or nil,until_tick=step.until_tick} or nil
    if waiting and api.base.wait_info then api.base.wait_info(waiting,step) end
    -- what paused it (d17 batch16 A4): "paused by you (queue_pause) ..." holds; any other pause says its cause
    local why=q.paused and q.paused_why and q.paused_why.line or nil
    return {revision=q.revision,paused=q.paused,paused_by=why,held=q.held and true or nil,pending=#q.pending,repeating=q.loop~=nil,waiting=waiting,
      active=q.current and {id=q.current.id,action=q.current.action,label=q.current.label,started_tick=q.current.started_tick,run=run_of(q)} or false,
      after_direct=q.after_direct}
  end
  local M={handlers={},schema=base.schema}
  for k,v in pairs(base) do if M[k]==nil then M[k]=v end end
  function M.lanes(index)
    local s=api.base.state()
    local out={body=brief((s.queues or {})[index]),remote=brief((s.remote_queues or {})[index])}
    for name in pairs(s.platform_lanes or {}) do
      local q=(s[M_key(name)] or {})[index]
      if q then out.platforms=out.platforms or {}; out.platforms[name]=brief(q) end
    end
    return out
  end
  -- The storage keys of every remote-like lane (remote, then each platform's): carry, clock, departure and waiteta read
  -- them all.
  function M.remote_keys(s)
    local keys={'remote_queues'}
    for name in pairs((s or api.base.state()).platform_lanes or {}) do keys[#keys+1]=M_key(name) end
    return keys
  end
  M.lane_key=M_key
  for name in pairs(base.handlers) do
    M.schema[name].lane='body (default, existing queue) | remote (independent of body work) | platform:NAME (a remote lane of its own for that platform: its waits and platform steps apart from the remote lane and the other platforms\' lanes); revisions belong to the selected lane'
    M.handlers[name]=function(p,a)
      local selected,engine=lane(a)
      if selected=='remote' and name=='queue_repeat' then
        assert(a.orders==nil or a.orders==false or a.orders=='none','standing orders run only in the body lane')
        local copy={}; for k,v in pairs(a) do copy[k]=v end
        copy.orders='none'; a=copy
      end
      local out=engine.handlers[name](p,a or {})
      out.lane=selected
      if name=='queue_status' then out.lanes=M.lanes(p.index) end
      return out
    end
  end
  M.schema.queue_submit.note='remote lane: wait_ticks; wait_until platform_arrived|platform_left|platform_built|researched or item_count with platform, ammo_below, platform_loss, platform_hit (platform_damage), platform_energy_below, platform_progress or ghosts_waiting with platform, rocket_ready, rocket_parts, item_count, produced, ammo_below, fuel_below or fluid_count with surface (guards\' when too); drop, platform_schedule, flush and platform_rearm with explicit platform; configure, circuit_set, circuit, wire, requests, place_ghosts and deconstruct with platform or surface (a planet, by remote view as the direct call); rotate with platform or surface; min_payload; body-independent read actions (observe needs platform or scope). Body steps, body conditions and nested queue calls refuse with the step/guard path. Full drops already started continue sending pods if the queue is cancelled, as in the body lane.'
  M.schema.queue_status.returns=M.schema.queue_status.returns..'; lane and lanes {body, remote, platforms {NAME: ...}}: each lane\'s paused, pending, active, revision and repeating state'
  function M.validate(a) local _,engine=lane(a); return engine.validate(a) end
  function M.tick() base.tick(); remote.tick(); each_platform(function(_,e) e.tick() end) end
  function M.pause_all() base.pause_all(); remote.pause_all(); each_platform(function(_,e) e.pause_all() end) end
  function M.round_news(index)
    local out=base.round_news(index) or {}
    for _,line in ipairs(remote.round_news(index) or {}) do out[#out+1]='remote '..line end
    each_platform(function(name,e) for _,line in ipairs(e.round_news(index) or {}) do out[#out+1]='platform:'..name..' '..line end end)
    return #out>0 and out or nil
  end
  return M
end
