-- Standing orders (docs/STANDING-ORDERS.md in the pog repo): routines an agent
-- sets once (rearm turrets, feed labs, refuel, courier, repair, build ghosts)
-- that its character runs whenever it has nothing else to do. Shifts 04-06:
-- agents that act one request at a time left their characters idle 35-85% of
-- the shift, and nobody used guards.
-- An order is a plan (queue_submit steps) with a priority and, for a triggered
-- order, a `when` condition (conditions.lua); one order without `when` is the
-- default routine. Orders run as plans in the agent's own queue (scheduler.lua
-- run_order), through the same handlers as its own requests: walking, reach,
-- inventory and crafting time as for a player. They start only while the
-- character is free (no action, the queue empty and not repeating, a body on
-- the map) and `hold` ticks after the agent's own last character work. Between
-- the rounds of a repeating plan (scheduler.lua resting) triggered orders run
-- too, and the default routine with queue_repeat orders=all; the hold then
-- counts from the agent's own last request, not the round's last step. Any
-- request of the agent's that drives the character, and any queue call of its
-- own, stops a running order at once (scheduler.lua: the run's remaining steps
-- come back as order_result `interrupted`); the order resumes when the
-- character is free again (a trigger only if its condition still holds).
-- Limits: 6 orders of 32 steps; each agent looked at once a second (staggered
-- by index) with at most one condition checked; when radius 256, 16 positions;
-- a run stops after max_ticks; 3 failed runs in a row switch an order off.
-- The operator's switch (orders_kill, operator dispatch only) stops every
-- agent's running order and starts none until it is switched off again.
return function(api)
  local M={handlers={},operator={}}
  local MAX_ORDERS,MAX_STEPS,MAX_RADIUS,MAX_POSITIONS,MAX_FAILS=6,32,256,16,3
  local CHECK,HOLD=60,1200
  local function int(v,default,low,high,name)
    if v==nil then return default end
    assert(type(v)=='number' and v==math.floor(v) and v>=low and v<=high,name..' must be an integer '..low..'..'..high)
    return v
  end
  local function book(index,create)
    local s=api.state()
    s.orders=s.orders or {}
    if create and not s.orders[index] then s.orders[index]={list={},hold=HOLD,rr=0,busy_tick=0,drove_tick=0} end
    return s.orders[index]
  end
  local function find(b,name)
    for i,o in ipairs(b.list) do if o.name==name then return o,i end end
  end
  local function default(b)
    for _,o in ipairs(b.list) do if not o.when then return o end end
  end
  local function short(text)
    text=tostring(text or '')
    return #text>100 and text:sub(1,97)..'...' or text
  end
  local function secs(ticks) return math.max(0,math.ceil(ticks/60)) end
  local function paused(b)
    if b.paused_until and game.tick>=b.paused_until then b.paused,b.paused_until=nil,nil end
    return b.paused
  end
  local function killed() return api.state().orders_kill end
  -- Orders start only while their agent plays: a request of its own (or an fh
  -- sleep poll) in the last AWAY ticks. A world left running between shifts
  -- does not play on for absent agents.
  local AWAY=108000
  local function away(index)
    local seen=api.last_seen(index)
    return not seen or game.tick-seen>AWAY
  end
  -- What keeps the character from an order: its own action, its queue, no body. A repeating plan resting between
  -- rounds keeps none out unless it says orders=none.
  local function busy(index)
    local kind=api.busy(index)
    if kind then return 'your '..kind end
    if not api.scheduler.free(index) then
      local rest=api.scheduler.resting(index)
      if not rest then
        local loop=api.scheduler.loop_orders(index)
        if loop=='none' then return 'your repeating plan (orders: none)' end
        if loop then return 'your repeating plan\'s round (orders run between its rounds: '..(loop=='all' and 'all' or 'triggered ones')..')' end
        return 'your queue'
      end
      if rest.orders=='none' then return 'your repeating plan (orders: none)' end
    end
    local ok,p=pcall(api.player,index)
    if not (ok and p and p.character) then return 'character (dead, riding or aboard)' end
  end
  M.ENEMY_RECHECK, M.ENEMY_WAIT_MAX = 600, 108000
  local function transient(reason)
    local r=tostring(reason or '')
    return r:find('under attack now',1,true) or r:find('seen now',1,true) or r:find('attack #',1,true) or nil
  end
  -- Orders waiting out enemies (C2), due again: the place clear of the enemies our force sees now, run; still there,
  -- look again in ENEMY_RECHECK ticks; past ENEMY_WAIT_MAX, a failure.
  local function enemy_waits(index,b)
    for _,o in ipairs(b.list) do
      local w=o.enemy_wait
      if w and game.tick>=o.next_tick then
        local there=api.enemies_near and api.enemies_near(index,w.at)
        if not there then o.enemy_wait=nil
        elseif game.tick-w.since>M.ENEMY_WAIT_MAX then
          o.enemy_wait=nil; o.failures=o.failures+1
          o.last={outcome='failed',reason='enemies there for '..secs(M.ENEMY_WAIT_MAX)..' s: '..short(there),tick=game.tick}
          if o.failures>=MAX_FAILS then o.off=o.last.reason end
          o.next_tick=game.tick+(o.when and o.cooldown or o.interval)
        else w.now=short(there); o.next_tick=game.tick+M.ENEMY_RECHECK end
      end
    end
  end
  -- A run's end (scheduler.lua order_result): done or failed sets the next
  -- time; interrupted keeps the remaining steps to resume.
  local function settle(b,r)
    local o=r and find(b,r.name)
    if not o or r.outcome=='replaced' or r.outcome=='removed' then return end
    if r.outcome=='interrupted' and r.remaining and #r.remaining>0 then
      o.resume=r.remaining; return
    end
    -- The operator's stop: no failure, no resume; the order starts afresh once switched back on.
    if r.outcome=='stopped' then
      o.resume=nil; o.held=nil; o.next_tick=game.tick
      o.last={outcome='stopped',reason=r.reason,tick=r.tick or game.tick}
      return
    end
    -- Refused for enemies that come and go (d17 batch12 C2, Luna: a spoilage top-up order switched itself off after
    -- three refusals during a short wriggler attack): an area under attack now, enemy units or a group seen now. Not a
    -- failure: the order waits for the place to be clear of the enemies seen there and runs again (checked every
    -- ENEMY_RECHECK ticks; after ENEMY_WAIT_MAX it counts as a failure after all).
    if r.outcome=='failed' and transient(r.reason) then
      local x,y=tostring(r.reason):match('%((%-?[%d%.]+),(%-?[%d%.]+)%)')
      o.enemy_wait=o.enemy_wait or {since=game.tick}
      o.enemy_wait.reason=short(r.reason); o.enemy_wait.at=x and {x=tonumber(x),y=tonumber(y)} or nil
      o.last={outcome='waiting',reason='enemies there: '..short(r.reason),tick=r.tick or game.tick}
      o.resume=nil; o.held=nil
      o.next_tick=game.tick+M.ENEMY_RECHECK
      return
    end
    if r.outcome=='failed' then
      o.failures=o.failures+1
      if o.failures>=MAX_FAILS then o.off=short(r.reason) end
    else o.failures=0; o.runs=o.runs+1 end
    o.enemy_wait=nil
    o.last={outcome=r.outcome=='failed' and 'failed' or 'done',reason=r.reason and short(r.reason) or nil,tick=r.tick or game.tick}
    o.resume=nil; o.held=nil
    o.next_tick=game.tick+(o.when and o.cooldown or o.interval)
  end
  -- Where an order works (A2): its first step's position (or first of positions, or its area's middle), else its
  -- condition's position; nil when none is named.
  local function place_of(o)
    local st=o.steps and o.steps[1]
    local a=st and st.args or {}
    local q=a.position or (type(a.positions)=='table' and a.positions[1]) or nil
    if not q and type(a.area)=='table' then
      local lt,rb=a.area.left_top or a.area[1],a.area.right_bottom or a.area[2]
      if lt and rb then q={x=((lt.x or lt[1])+(rb.x or rb[1]))/2,y=((lt.y or lt[2])+(rb.y or rb[2]))/2} end
    end
    q=q or (o.when and o.when.position)
    if type(q)~='table' then return nil end
    local x,y=q.x or q[1],q.y or q[2]
    return type(x)=='number' and type(y)=='number' and {x=x,y=y} or nil
  end
  -- max_walk (A2): an order whose place lies farther than that from you waits (said in its state), looked at again in
  -- 10 s; true when it may start.
  local function near_enough(index,o)
    if not o.max_walk then return true end
    local q=place_of(o)
    if not q then return true end
    local ok,p=pcall(api.player,index)
    local c=ok and p and p.character
    if not (c and c.valid) then return true end
    local d=math.sqrt((c.position.x-q.x)^2+(c.position.y-q.y)^2)
    if d<=o.max_walk then o.far=nil; return true end
    o.far=string.format('its place (%g,%g) lies %.0f tiles from you, over max_walk %d',q.x,q.y,d,o.max_walk)
    o.next_tick=game.tick+600
    return false
  end
  local function start(index,o)
    if not near_enough(index,o) then return end
    local why=o.resume and 'resumed' or o.when and o.held and o.held.saw or 'default routine'
    local items=o.resume or o.steps
    o.resume=nil
    api.scheduler.run_order(index,o.name,items,short(why))
  end
  -- One condition per look: the triggers that pass `filter`, are on and are
  -- due (or wait to resume), checked in turn; then the highest priority of
  -- those whose last check (recent) held.
  local function trigger(b,p,filter)
    local due={}
    for _,o in ipairs(b.list) do
      if o.when and not o.off and filter(o) and (o.resume or game.tick>=o.next_tick) then due[#due+1]=o end
    end
    if #due==0 then return nil end
    table.sort(due,function(x,y) if x.priority~=y.priority then return x.priority>y.priority end return x.name<y.name end)
    b.rr=(b.rr or 0)%#due+1
    local o=due[b.rr]
    local ok,met,saw=pcall(api.condition,p,o.when)
    o.held={met=ok and met or false,saw=ok and saw or 'condition failed: '..short(met),tick=game.tick}
    if not o.held.met then o.resume=nil end
    local fresh=game.tick-CHECK*(#due+1)
    for _,x in ipairs(due) do
      if x.held and x.held.met and x.held.tick>=fresh then return x end
    end
  end
  -- The tick the hold counts from: the agent's own last request or busy character; between the rounds of a repeating
  -- plan, a busy look from before the round ended was the round's own step, so only the agent's request counts.
  function M.since(index,b)
    local rest=api.scheduler.resting(index)
    if rest and (b.busy_tick or 0)<=rest.since then return b.drove_tick or 0 end
    return math.max(b.busy_tick or 0,b.drove_tick or 0)
  end
  local function look(index,b)
    settle(b,api.scheduler.order_result(index))
    enemy_waits(index,b)
    local running=api.scheduler.order(index)
    if running then
      local o=find(b,running.name)
      if not o then api.scheduler.cancel_order(index,'removed','order removed'); api.scheduler.order_result(index); return end
      if game.tick-running.started_tick>o.max_ticks then
        api.scheduler.cancel_order(index,'failed','ran over max_ticks '..o.max_ticks)
        settle(b,api.scheduler.order_result(index))
        return
      end
      -- A holding trigger of higher priority takes over; the running one resumes after.
      local ok,p=pcall(api.player,index)
      if not ok then return end
      local rank=o.when and o.priority or 0
      local t=trigger(b,p,function(x) return x.priority>rank end)
      if t then
        api.interrupt(index)
        settle(b,api.scheduler.order_result(index))
        start(index,t)
      end
      return
    end
    if paused(b) or away(index) then return end
    -- a sleep with orders: false (A2): none starts while it runs
    local sl=(api.state().sleeps or {})[index]
    if sl and sl.no_orders and game.tick<(sl.until_tick or 0) then return end
    if busy(index) then b.busy_tick=game.tick; return end
    if game.tick-M.since(index,b)<b.hold then return end
    local p=api.player(index)
    local t=trigger(b,p,function() return true end)
    if t then return start(index,t) end
    -- Between rounds the default routine runs only with orders=all.
    local rest=api.scheduler.resting(index)
    local d=default(b)
    if d and not d.off and (d.resume or game.tick>=d.next_tick) and (not rest or rest.orders=='all') then start(index,d) end
  end
  -- Once a tick: the agents whose second it is. A fault stays with the agent's
  -- orders (shown in its line), never the runtime.
  function M.tick()
    if killed() then return end
    for index,b in pairs(api.state().orders or {}) do
      if #b.list>0 and game.tick%CHECK==index%CHECK then
        local ok,err=pcall(look,index,b)
        b.error=not ok and {tick=game.tick,message=short(err)} or nil
      end
    end
  end
  -- The agent's own character work (runtime.lua dispatch): orders wait `hold` after it.
  function M.on_drive(index)
    local b=book(index)
    if b then b.drove_tick=game.tick end
  end
  local function state_of(index,b,o)
    local running=api.scheduler.order(index)
    if running and running.name==o.name then return 'running' end
    if o.off then return 'off' end
    if killed() then return 'paused by the operator' end
    if o.resume then return 'resumes when free' end
    if o.far and game.tick<o.next_tick then return 'waits: '..o.far end
    if o.enemy_wait then
      local w=o.enemy_wait
      return string.format('waiting for enemies%s to clear (%s), looks again in %s s',w.at and string.format(' near (%g,%g)',w.at.x,w.at.y) or '',w.now or w.reason,secs(math.max(0,o.next_tick-game.tick)))
    end
    if game.tick<o.next_tick then return (o.when and 'cooling ' or 'next in ')..secs(o.next_tick-game.tick)..' s' end
    if o.when then return o.held and o.held.tick>game.tick-600 and (o.held.met and 'holds' or 'not holding') or 'ready' end
    return 'ready'
  end
  local function summary(index,b,o)
    return {name=o.name,when=o.when,priority=o.when and o.priority or nil,steps=#o.steps,state=state_of(index,b,o),
      cooldown_ticks=o.when and o.cooldown or nil,interval_ticks=not o.when and o.interval or nil,max_ticks=o.max_ticks,
      runs=o.runs,failures=o.failures,off=o.off,last=o.last,saw=o.held and o.held.saw or nil}
  end
  local function list(index,b)
    settle(b,api.scheduler.order_result(index))
    local out={}
    for _,o in ipairs(b.list) do out[#out+1]=summary(index,b,o) end
    return out
  end
  -- One line on every reply while the agent has orders.
  function M.line(index)
    local b=book(index)
    if not b or #b.list==0 then return nil end
    -- A run that ended since the last look (the request that stopped it is this reply's).
    settle(b,api.scheduler.order_result(index))
    local parts={}
    local running=api.scheduler.order(index)
    local waiting
    for _,o in ipairs(b.list) do if o.resume then waiting=o; break end end
    if running then
      parts[1]=string.format('%s running (%s), step %d/%d',running.name,running.reason or '',running.step,running.total)
    elseif killed() then
      parts[1]='paused by the operator'
    elseif b.paused then
      parts[1]='paused'..(b.paused_until and ' for '..secs(b.paused_until-game.tick)..' s' or '')..' (orders_resume)'
    else
      local why=busy(index)
      local left=b.hold-(game.tick-M.since(index,b))
      if why then
        parts[1]=waiting and (waiting.name..' waits for '..why..', resumes after') or ('waiting for '..why)
      elseif left>0 then
        parts[1]=(waiting and waiting.name..' resumes' or 'start')..' in '..secs(left)..' s (after your last action)'
      else
        local triggers=0
        for _,o in ipairs(b.list) do if o.when and not o.off then triggers=triggers+1 end end
        local d=default(b)
        local bits={}
        if triggers>0 then bits[#bits+1]=triggers..(triggers==1 and ' trigger' or ' triggers')..' not holding' end
        if d and not d.off then bits[#bits+1]=d.name..(game.tick<d.next_tick and ' next in '..secs(d.next_tick-game.tick)..' s' or ' next') end
        parts[1]=#bits>0 and 'waiting ('..table.concat(bits,'; ')..')' or 'waiting'
      end
    end
    for _,o in ipairs(b.list) do
      if o.enemy_wait then parts[#parts+1]=o.name..' waits for enemies'..(o.enemy_wait.at and string.format(' near (%g,%g)',o.enemy_wait.at.x,o.enemy_wait.at.y) or '')..' to clear (not a failure)' end
      if o.off then parts[#parts+1]=o.name..' off after '..MAX_FAILS..' failures: '..o.off..' (order_set it again)'
      elseif o.failures>0 and o.last then parts[#parts+1]=o.name..' failed '..o.failures..'/'..MAX_FAILS..': '..(o.last.reason or '?') end
    end
    if b.error then parts[#parts+1]='error: '..b.error.message end
    return 'orders: '..table.concat(parts,'; ')
  end
  -- The running order for the stream overlay ("auto: name") and the operator's idle report.
  function M.brief(index)
    local running=api.scheduler.order(index)
    return running and {name=running.name,reason=running.reason,step=running.step,steps=running.total} or nil
  end
  function M.report(index)
    local b=book(index)
    if not b or #b.list==0 then return nil end
    local running=api.scheduler.order(index)
    return {set=#b.list,running=running and running.name or nil,reason=running and running.reason or nil,paused=b.paused or nil,
      operator_paused=killed() and true or nil}
  end
  function M.handlers.order_set(p,a)
    local name=a.name
    assert(type(name)=='string' and #name<=32 and name:match('^[%w][%w_%-]*$'),'name: 1..32 letters, digits, - or _')
    assert(type(a.steps)=='table' and #a.steps>=1 and #a.steps<=MAX_STEPS,'steps: 1..'..MAX_STEPS..' plan steps, as queue_submit')
    local _,items=api.scheduler.validate({steps=a.steps})
    local when=a.when
    if when~=nil then
      api.validate_condition(when)
      assert(when.timeout==nil,'when takes no timeout')
      assert((when.radius or 32)<=MAX_RADIUS,'when radius is at most '..MAX_RADIUS..' for a standing order')
      assert(when.positions==nil or #when.positions<=MAX_POSITIONS,'when positions: at most '..MAX_POSITIONS..' for a standing order')
    end
    assert(when or a.cooldown_ticks==nil,'cooldown_ticks is for an order with when; the default routine takes interval_ticks')
    assert(not when or a.interval_ticks==nil,'interval_ticks is for the default routine (no when); an order with when takes cooldown_ticks')
    assert(when or a.priority==nil,'priority is for an order with when; the default routine runs when no trigger holds')
    -- A base-wide tour has the same walking speed as a small one. Default
    -- order budget covers its widest scope and explicit child action budgets.
    local span=when and (when.radius or 32) or 32
    if when and when.area then
      local l,r=when.area.left_top or when.area[1],when.area.right_bottom or when.area[2]
      span=math.max(span,math.abs((r.x or r[1])-(l.x or l[1])),math.abs((r.y or r[2])-(l.y or l[2])))
    end
    local budget=0
    for _,step in ipairs(items) do
      local a=step.args or {}
      span=math.max(span,a.radius or 0)
      if a.area then
        local l,r=a.area.left_top or a.area[1],a.area.right_bottom or a.area[2]
        if l and r then span=math.max(span,math.abs((r.x or r[1])-(l.x or l[1])),math.abs((r.y or r[2])-(l.y or l[2]))) end
      end
      local tour=(step.action=='rearm' or step.action=='refuel') and (a.area or (a.radius or 0)>64 or a.from)
      budget=budget+(a.ticks or (tour and 36000) or 0)
    end
    local default_ticks=math.min(216000,math.max(3600,math.ceil(span/64)*3600,budget+600))
    local o={name=name,steps=items,when=when,priority=int(a.priority,5,1,9,'priority'),cooldown=int(a.cooldown_ticks,600,300,216000,'cooldown_ticks'),
      interval=int(a.interval_ticks,1800,60,216000,'interval_ticks'),max_ticks=int(a.max_ticks,default_ticks,60,216000,'max_ticks'),
      max_walk=a.max_walk~=nil and int(a.max_walk,nil,1,1000,'max_walk') or nil,
      failures=0,runs=0,next_tick=game.tick}
    local b=book(p.index,true)
    local old,at=find(b,name)
    if not old then assert(#b.list<MAX_ORDERS,'at most '..MAX_ORDERS..' standing orders: order_remove one first') end
    if not when then
      local d=default(b)
      assert(not d or d.name==name,'one default routine (no when) per agent: '..(d and d.name or '')..' is it; give this one a when, or replace or remove that one')
    end
    -- Replacing the running order ends its run.
    local running=api.scheduler.order(p.index)
    if running and running.name==name then api.scheduler.cancel_order(p.index,'replaced','replaced by order_set'); api.scheduler.order_result(p.index) end
    if at then b.list[at]=o else b.list[#b.list+1]=o end
    b.error=nil
    return {order=summary(p.index,b,o),list=list(p.index,b)}
  end
  function M.handlers.order_remove(p,a)
    assert(type(a.name)=='string','name is required')
    local b=book(p.index)
    local o,at
    if b then o,at=find(b,a.name) end
    assert(o,'no standing order '..a.name)
    local running=api.scheduler.order(p.index)
    if running and running.name==a.name then api.scheduler.cancel_order(p.index,'removed','order removed'); api.scheduler.order_result(p.index) end
    table.remove(b.list,at)
    return {removed=a.name,list=list(p.index,b)}
  end
  function M.handlers.orders(p)
    local b=book(p.index)
    if not b or #b.list==0 then return {list={},note='no standing orders: order_set {name, steps, when?, priority?}'} end
    return {list=list(p.index,b),hold_s=secs(b.hold),paused=b.paused or nil,paused_by_operator=killed() and true or nil}
  end
  -- Stops a running order (it resumes after) and starts none until orders_resume or the time is up.
  function M.handlers.orders_pause(p,a)
    local b=book(p.index,true)
    local seconds=int(a.seconds,nil,1,3600,'seconds')
    b.paused=true; b.paused_until=seconds and game.tick+seconds*60 or nil
    if api.scheduler.order(p.index) then
      api.interrupt(p.index)
      settle(b,api.scheduler.order_result(p.index))
    end
    return {paused=true,until_tick=b.paused_until}
  end
  function M.handlers.orders_resume(p,a)
    local b=book(p.index,true)
    b.paused,b.paused_until=nil,nil
    if a.hold_s~=nil then b.hold=int(a.hold_s,nil,0,600,'hold_s')*60 end
    return {paused=false,hold_s=secs(b.hold),
      note=killed() and 'orders are paused by the operator for everyone: they start again when the operator switches them back on' or nil}
  end
  -- Operator only (runtime.lua dispatch with operator=true; agents cannot reach it).
  -- on=true stops every running order (no resume, no failure counted) and
  -- starts none, triggers included, for every agent until on=false; on=false
  -- lets them start again `hold` after now. No `on`: the switch's state.
  function M.operator.orders_kill(a)
    local on=a.on
    assert(on==nil or type(on)=='boolean','on: true stops all standing orders, false lets them run again')
    local s=api.state()
    local names={}
    for _,ag in ipairs(api.agents() or {}) do names[ag.index]=ag.name end
    local stopped,agents={},0
    if on==true and not s.orders_kill then
      s.orders_kill={tick=game.tick}
      for index,b in pairs(s.orders or {}) do
        settle(b,api.scheduler.order_result(index))
        if api.scheduler.order(index) then
          api.scheduler.cancel_order(index,'stopped','paused by the operator')
          settle(b,api.scheduler.order_result(index))
          stopped[#stopped+1]=names[index] or ('#'..index)
        end
      end
      table.sort(stopped)
    elseif on==false and s.orders_kill then
      s.orders_kill=nil
      for _,b in pairs(s.orders or {}) do b.busy_tick=game.tick end
    end
    for _,b in pairs(s.orders or {}) do if #b.list>0 then agents=agents+1 end end
    local k=s.orders_kill
    return {ok=true,tick=game.tick,on=k and true or false,since_tick=k and k.tick or nil,stopped=stopped,agents_with_orders=agents}
  end
  M.schema={
    order_set={name='1..32 letters, digits, - or _; the same name replaces that order (and switches one that went off back on)',max_walk='optional 1..1000 tiles: the order starts only while its place (its first step\'s position, positions or area, else its when\'s position) lies within that many tiles of you; farther, it waits (its state says how far)',
      steps='1..32 plan steps, as queue_submit (action, args, wait, label, on_fail)',
      when='optional condition, as wait_until: until=ammo_below|item_count|ghosts_waiting|damaged|fuel_below|health_below|no_enemies|platform_arrived|platform_left|...; radius at most 256; ammo_below/fuel_below also take area up to 256x256, positions at most 16. The order runs when it holds. Without when: your default routine (one), run every interval_ticks while no trigger holds',
      priority='with when: 1..9 (default 5). The highest holding trigger runs first; a holding trigger stops a running order of lower priority (the default routine counts 0), which resumes after',
      cooldown_ticks='with when: 300..216000 (default 600) after a run before the trigger can fire again',
      interval_ticks='default routine: 60..216000 (default 1800; up to an hour, D6: an 18-minute refuel round) from the end of a run to the next',
      max_ticks='60..216000 (default scales with scope and child ticks, at least 3600): a run that takes longer is stopped and counts as failed',
      returns='order, list. Orders run only while your character is free (no action, your queue empty and not repeating, a body on the map; between the rounds of a repeating queue, triggered orders, and the default routine with queue_repeat orders=all) and hold_s after your own last action. Your own character request or queue call stops a running order at once; it resumes after (a trigger only if it still holds). 3 failed runs in a row switch an order off. Every reply carries the orders line (which runs and why, or what they wait for)'},
    order_remove={name='order name'},
    orders={returns='your standing orders: state (running, ready, holds, not holding, cooling N s, next in N s, resumes when free, off), runs, failures, last'},
    orders_pause={seconds='optional 1..3600 (default until orders_resume); a running order stops and resumes after'},
    orders_resume={hold_s='optional 0..600 (default 20): how long your character must be free after your own last action before an order starts'},
  }
  return M
end
