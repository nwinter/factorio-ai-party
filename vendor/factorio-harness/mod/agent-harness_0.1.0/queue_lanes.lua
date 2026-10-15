-- The body scheduler keeps its original state and callbacks. The opt-in remote
-- scheduler has independent revisions, waits and failure policies, and no body controls.
return function(api)
  local base=api.scheduler
  local remote_api={}
  for k,v in pairs(api.base) do remote_api[k]=v end
  local WAITS={platform_arrived=true,platform_left=true,researched=true}
  local PLATFORM_WRITES={configure=true,circuit_set=true,circuit=true,wire=true,requests=true,flush=true}
  local BODY_READS={inventory=true,craftable=true,sleep_check=true,dry_run=true,screenshot=true}
  local function check(action,a)
    a=a or {}
    if action=='wait_ticks' then return end
    if action=='wait_until' then
      assert(WAITS[a['until']] or (a['until']=='item_count' and type(a.platform)=='string' and a.platform~=''),
        'remote lane wait_until supports platform_arrived, platform_left, researched or item_count with platform')
      return
    end
    if action=='drop' or action=='platform_schedule' or PLATFORM_WRITES[action] then
      assert(type(a.platform)=='string' and a.platform~='', 'remote lane '..action..' requires platform')
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
  local function lane(a)
    local name=a and a.lane or 'body'
    assert(name=='body' or name=='remote','lane must be body or remote')
    return name,name=='remote' and remote or base
  end
  local function brief(q)
    if not q then return {paused=true,pending=0,active=false} end
    local step=q.current
    local waiting=not q.paused and step and (step.action=='wait_until' or step.action=='wait_ticks') and
      {kind=step.action,condition=step.action=='wait_until' and step.args or nil,until_tick=step.until_tick} or nil
    if waiting and api.base.wait_info then api.base.wait_info(waiting,step) end
    return {revision=q.revision,paused=q.paused,pending=#q.pending,repeating=q.loop~=nil,waiting=waiting,
      active=q.current and {id=q.current.id,action=q.current.action,started_tick=q.current.started_tick} or false,
      after_direct=q.after_direct}
  end
  local M={handlers={},schema=base.schema}
  for k,v in pairs(base) do if M[k]==nil then M[k]=v end end
  function M.lanes(index)
    local s=api.base.state()
    return {body=brief((s.queues or {})[index]),remote=brief((s.remote_queues or {})[index])}
  end
  for name in pairs(base.handlers) do
    M.schema[name].lane='body (default, existing queue) | remote (independent of body work); revisions belong to the selected lane'
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
  M.schema.queue_submit.note='remote lane: wait_ticks; wait_until platform_arrived|platform_left|researched or item_count with platform; drop, platform_schedule, configure, circuit_set, circuit, wire, requests and flush with explicit platform; body-independent read actions (observe needs platform or scope). Body steps, body conditions and nested queue calls refuse with the step/guard path. Full drops already started continue sending pods if the queue is cancelled, as in the body lane.'
  M.schema.queue_status.returns=M.schema.queue_status.returns..'; lane and lanes {body, remote}: each lane\'s paused, pending, active, revision and repeating state'
  function M.validate(a) local _,engine=lane(a); return engine.validate(a) end
  function M.tick() base.tick(); remote.tick() end
  function M.pause_all() base.pause_all(); remote.pause_all() end
  function M.round_news(index)
    local out=base.round_news(index) or {}
    for _,line in ipairs(remote.round_news(index) or {}) do out[#out+1]='remote '..line end
    return #out>0 and out or nil
  end
  return M
end
