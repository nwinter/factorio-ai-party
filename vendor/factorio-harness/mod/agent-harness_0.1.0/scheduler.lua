-- Short-horizon plans execute at simulation speed. No coroutines or host clock.
return function(api)
  local LOOP_WALK
  local M = {handlers={}}
  local QUEUES=api.queue_key or 'queues'
  local MAX_PENDING, MAX_HISTORY, MAX_INSTANT, MAX_BYTES, MAX_GUARDS, CHECK_TICKS = 128, 64, 4, 1048576, 8, 10
  -- Outcomes of timed actions that count as the step succeeding.
  local SUCCESS={duration_elapsed=true,target_mined=true,mined=true,repair_completed=true,arrived=true,arrived_near=true,path_built=true,constructed=true,nothing_to_do=true,clear=true,fed=true,collected=true,topped_up=true,target_destroyed=true,dropped=true,transferred=true,picked_up=true,
    -- load_silo walk (Luna, shift14 21:20): the list aboard, and launched
    loaded=true,launched=true,
    -- clear_cliffs and use_item with cliff explosives (Sol 22:45), and a vehicle drive's dry run
    cliffs_destroyed=true,previewed=true,
    -- a call made after its walk into reach (autowalk.lua)
    done=true}
  -- construct's 'incomplete' (ghosts left for lack of items, or failures) is a failure.
  local forbidden = {attach=true, detach=true, recipes=true, technologies=true, inspect=true, blueprint_export=true, blueprint_list=true, stop=true, describe=true, status=true, observe=true, screenshot=true, map=true, nearest=true, craftable=true, scan=true, power=true, grid=true, rates=true, bottleneck=true, stock=true, platforms=true,
    order_set=true, order_remove=true, orders=true, orders_pause=true, orders_resume=true}
  local function queue(index)
    local s=api.state()
    s[QUEUES]=s[QUEUES] or {}
    s[QUEUES][index]=s[QUEUES][index] or {revision=0,sequence=0,pending={},history={},paused=true}
    return s[QUEUES][index]
  end
  local function revision(q,a)
    if a.expected_revision~=nil then assert(a.expected_revision==q.revision,'queue revision conflict; inspect queue_status') end
  end
  local function checked(path, fn)
    local ok, result = pcall(fn)
    if not ok then error(path..': '..tostring(result):gsub('^[^:]*:%d+: ', ''), 0) end
    return result
  end
  local STEP_KEYS={action=true,args=true,wait=true,label=true,on_fail=true,on_short=true,min_moved=true,plan=true,id=true}
  local function steps(a,p,path)
    path=path or 'steps'
    assert(type(a.steps)=='table' and #a.steps<=MAX_PENDING,'steps must be an array of at most 128 entries')
    local out,corrected={},{}
    for i,step in ipairs(a.steps) do
      local where=path..'['..i..']'
      if type(step)=='table' then
        local label=type(step.label)=='string' and (#step.label<=64 and string.format('%q',step.label) or #step.label..' bytes')
        where=where..' ('..tostring(step.action)..(label and ', label '..label or '')..')'
      end
      checked(where,function()
        assert(type(step)=='table' and type(step.action)=='string','each step needs an action')
        -- A step written flat ({action, position, ...}) ran with no arguments and failed later ("pos nil"; Muse, twice,
        -- each a loop rebuild): an argument of the action beside action is refused here, naming the shape.
        if api.takes then
          local flat={}
          for k in pairs(step) do
            if type(k)=='string' and not STEP_KEYS[k] and api.takes(step.action,k) then flat[#flat+1]=k end
          end
          if #flat>0 then
            table.sort(flat)
            local inner={}
            for _,k in ipairs(flat) do inner[#inner+1]=k..': ...' end
            error(string.format('%s %s of %s written beside action; a step is {action: "%s", args: {%s}} (wait, label, on_fail, on_short, min_moved beside args)%s',
              table.concat(flat,', '),#flat==1 and 'is an argument' or 'are arguments',step.action,step.action,table.concat(inner,', '),
              step.args~=nil and '; this step also has args: put every argument of the action in it' or ''),0)
          end
        end
        -- Wrong argument names and position/positions mix-ups run as a direct call would (aliases.lua).
        local action,args=step.action,step.args
        if api.fix_args and type(args)=='table' then
          local ok,fixed_action,fixed_args,fix=pcall(api.fix_args,action,args)
          if ok and fix then
            action,args=fixed_action,fixed_args
            if not fix.quiet then corrected[#corrected+1]='step '..i..': '..fix.call..' ('..table.concat(fix.notes,'; ')..')' end
          elseif ok and fixed_args~=args then action,args=fixed_action,fixed_args end
        end
        assert(not action:match('^queue_') and (api.check_step or not forbidden[action]),'action is not queueable')
        if api.check_step then api.check_step(action,args or {}) end
        assert(action=='wait_ticks' or action=='wait_until' or api.handlers[action],'unknown action in plan')
        assert(args==nil or type(args)=='table','step args must be an object')
        if api.check_args then checked('args',function() api.check_args(action,args) end) end
        if p and api.check_action then api.check_action(p.index,action,args) end
        assert(step.wait==nil or type(step.wait)=='boolean','step wait must be boolean')
        assert(step.min_moved==nil or (action=='transfer' and step.wait~=false and type(step.min_moved)=='number' and step.min_moved==math.floor(step.min_moved) and step.min_moved>=1 and step.min_moved<=10000), 'min_moved requires a transfer step with wait=true and an integer 1..10000')
        assert(step.label==nil or (type(step.label)=='string' and #step.label<=64),'label must be a string of at most 64 bytes')
        local on_fail=step.on_fail
        assert(step.on_short==nil or step.on_short=='skip','on_short must be skip')
        assert(on_fail==nil or on_fail=='abort' or on_fail=='skip' or (type(on_fail)=='string' and on_fail:match('^goto:.+')),'on_fail must be abort, skip or goto:<label>')
        if action=='wait_ticks' then
          local ticks=args and args.ticks
          assert(type(ticks)=='number' and ticks==math.floor(ticks) and ticks>=1 and ticks<=54000,'wait_ticks requires ticks 1..54000')
        end
        if action=='wait_until' then
          local timeout=args and args.timeout
          assert(timeout==nil or (type(timeout)=='number' and timeout==math.floor(timeout) and timeout>=1 and timeout<=54000),'wait_until timeout must be 1..54000 ticks')
          checked('args',function() api.validate_condition(args) end)
        end
        out[#out+1]={action=action,args=args or {},wait=step.wait~=false,label=step.label,on_fail=on_fail,on_short=step.on_short,min_moved=step.min_moved}
      end)
    end
    return out,#corrected>0 and corrected or nil
  end
  -- Conservative JSON-size estimate, independent of Factorio's serializer.
  -- Count keys even for arrays; this slightly overestimates rather than allowing
  -- many blueprint imports to grow pending work without a memory bound.
  local function bytes(value,depth)
    assert(depth<=32,'queue arguments exceed maximum nesting depth')
    if type(value)=='string' then
      local _,escaped=value:gsub('[%z\1-\31\\"]','')
      return #value+escaped*5+2
    end
    if type(value)~='table' then return 32 end
    local size=2
    for key,item in pairs(value) do
      size=size+bytes(tostring(key),depth+1)+bytes(item,depth+1)+2
      assert(size<=MAX_BYTES,'queue argument byte budget exceeded')
    end
    return size
  end
  local function total(items)
    local size=0
    for _,step in ipairs(items) do size=size+bytes(step,0) end
    return size
  end
  local function assign(q,items)
    for _,step in ipairs(items) do q.sequence=q.sequence+1; step.id='job-'..q.sequence end
  end
  local function copy_steps(items)
    local out={}
    for _,step in ipairs(items) do out[#out+1]={action=step.action,args=step.args,wait=step.wait,label=step.label,on_fail=step.on_fail,on_short=step.on_short,min_moved=step.min_moved,plan=step.plan} end
    return out
  end
  -- Plans (Grok, shift14 22:50: queue status showed hours of standing-order history, and a finished pickup plan read
  -- as a failure): each queue_submit and queue_repeat starts a plan; its steps, the rounds of a repeating one, its
  -- edits and its guards' steps carry the plan's number into the history.
  local function new_plan(q,items,kind,name)
    q.plan_seq=(q.plan_seq or 0)+1
    q.plan={id=q.plan_seq,kind=kind,name=name,tick=game.tick,steps=#items}
    for _,step in ipairs(items) do step.plan=q.plan_seq end
  end
  -- Guards: {when=<condition>, goto='label' | steps=[...] | neither (abort)}.
  local function guards(a,p)
    if a.guards==nil then return {} end
    assert(type(a.guards)=='table' and #a.guards<=MAX_GUARDS,'guards must be an array of at most '..MAX_GUARDS)
    local out={}
    for i,g in ipairs(a.guards) do
      checked('guards['..i..']',function()
        assert(type(g)=='table','each guard is {when, goto|steps}')
        checked('when',function()
          api.validate_condition(g.when)
          if api.check_step then api.check_step('wait_until',g.when) end
        end)
        if p and api.check_action then api.check_action(p.index,'wait_until',g.when) end
        assert(g['goto']==nil or type(g['goto'])=='string','guard goto must be a label')
        assert(not (g['goto'] and g.steps),'a guard takes goto or steps, not both')
        out[#out+1]={when=g.when,['goto']=g['goto'],steps=g.steps and steps({steps=g.steps},p) or nil}
      end)
    end
    return out
  end
  -- recent: keep only the newest entries of the history (the changing calls;
  -- shake3: Opus's queue cancel printed 60+ entries); queue_status takes a count.
  local RECENT,PLAN_RECENT=3,16
  -- The plan's entries (the last plan submitted; before plans were numbered, every entry not from an order).
  local function in_plan(q,e)
    if e.order then return false end
    if q.plan_seq==nil or e.plan==nil then return q.plan_seq==nil end
    return e.plan==q.plan_seq
  end
  -- orders: true lists the standing orders' entries too (every entry, as before plans); else the plan's own entries,
  -- the orders' counted.
  local function snapshot(q,recent,orders,with_args)
    local list,from_orders=q.history,0
    if not orders then
      list={}
      for _,e in ipairs(q.history) do
        if in_plan(q,e) then list[#list+1]=e elseif e.order then from_orders=from_orders+1 end
      end
    end
    local failure
    for i=#list,1,-1 do if not list[i].ok then failure=list[i]; break end end
    local history=list
    if recent and #history>recent then
      history={}
      for i=#list-recent+1,#list do history[#history+1]=list[i] end
    end
    local trimmed=history~=q.history
    -- Each entry's arguments only when asked (queue_status {args: true}): replies stay as small as before.
    if not with_args then
      local copies={}
      for i,e in ipairs(history) do
        if e.args~=nil then local c={}; for k,v in pairs(e) do if k~='args' then c[k]=v end end; copies[i]=c else copies[i]=e end
      end
      history=copies
    end
    local loop_done=q.loop_done
    if loop_done and loop_done.steps and not with_args then
      loop_done={}
      for k,v in pairs(q.loop_done) do if k~='steps' then loop_done[k]=v end end
      loop_done.steps_count=#q.loop_done.steps
    end
    local plan
    if q.plan then
      local done,ok_n,failed=0,0,0
      for _,e in ipairs(q.history) do
        if not e.order and e.plan==q.plan.id and e.id then done=done+1; if e.ok then ok_n=ok_n+1 else failed=failed+1 end end
      end
      local left=0
      for _,step in ipairs(q.pending) do if step.plan==q.plan.id then left=left+1 end end
      plan={id=q.plan.id,kind=q.plan.kind,name=q.plan.name,submitted_s_ago=math.floor((game.tick-q.plan.tick)/60),steps=q.plan.steps,
        done=done,ok=ok_n,failed=failed,pending=left,running=q.current and q.current.plan==q.plan.id or nil}
    end
    local current=q.current
    local waiting=current and current.action=='wait_until' and {condition=current.args,saw=current.saw,until_tick=current.until_tick} or nil
    if waiting and api.wait_info then
      api.wait_info(waiting,current)
      local copy={}
      for k,v in pairs(current) do if k~='wait_samples' then copy[k]=v end end
      api.wait_info(copy,current); current=copy
    end
    return {revision=q.revision,paused=q.paused,pending=q.pending,active=current or false,history=history,plan=plan,
      order=q.order and {name=q.order.name,reason=q.order.reason,steps=q.order.total} or nil,
      orders_history=from_orders>0 and string.format('%d entries from standing orders left out (queue_status {"orders": true} lists them)',from_orders) or nil,
      history_total=trimmed and #q.history or nil,
      waiting=waiting,
      guards=q.guards and #q.guards>0 and q.guards or nil,last_failure=failure,after_direct=q.after_direct,
      repeating=q.loop~=nil,cycle=q.cycle,next_cycle_tick=q.next_cycle_tick,orders_between_rounds=q.loop and (q.orders or 'triggers') or nil,
      times=q.loop and q.times or nil,rounds_left=q.loop and q.times and math.max(0,q.times-(q.cycle or 1)) or nil,
      stops_tick=q.loop and q.stop_tick or nil,loop_done=loop_done,repeat_name=q.loop and q.name or nil,condition=q.loop and q.condition or nil,condition_error=q.condition_error,submission=q.submission,
      limits={pending=MAX_PENDING,history=MAX_HISTORY,instant_per_tick=MAX_INSTANT,argument_bytes=MAX_BYTES}}
  end
  -- A repeating plan's round tallies its steps that ran short (Opus, after short steps were skipped): action, item and
  -- why, e.g. "transfer iron-plate inventory_full". The outcomes and errors short() reads, or a reply's short {reason}.
  local ROUND_SHORT={out_of_items=true,nothing_collected=true,inventory_full=true}
  local function short_key(step,result)
    if type(result)~='table' then return nil end
    local why
    if ROUND_SHORT[result.outcome] then why=result.outcome
    elseif type(result.reason)=='string' and result.reason:match('^no %S+ in inventory') then why='none_held'
    elseif type(result.short)=='table' and type(result.short.reason)=='string' then why=result.short.reason end
    if not why then return nil end
    local a=type(step.args)=='table' and step.args or {}
    local what=a.item or a.recipe or (type(a.items)=='table' and a.items[1]) or a.fuel or a.ammo
    return step.action..(type(what)=='string' and ' '..what or '')..' '..why
  end
  -- A step given up_to=true or on_short=skip expects to run short at times.
  local function allows_short(step)
    return (type(step.args)=='table' and step.args.up_to==true) or step.on_short=='skip'
  end
  -- Its shorts stay out of the round line, which is for shorts the plan did not allow for (Grok, shift10: a brick loop
  -- whose up_to steps found an empty chest put a line in the team block every round; he cancelled two loops over it).
  -- Items a step moved, from its reply or its timed action's completion (moved, transferred, given).
  local MOVERS={transfer=true,collect=true,feed=true,refuel=true,rearm=true,pickup=true,load_silo=true}
  local function moved_count(result)
    if type(result)~='table' then return 0 end
    local n=0
    for _,src in ipairs({result,type(result.completion)=='table' and result.completion or {},type(result.accepted)=='table' and result.accepted or {}}) do
      for _,k in ipairs({'moved','transferred','given','loaded','taken'}) do
        if type(src[k])=='number' and src[k]>n then n=src[k] end
      end
    end
    return n
  end
  local function tally(q,step,result)
    -- A courier round's items (d15 trajectory analysis: 21 of Muse's 33 rounds moved nothing, and the loop still read as
    -- work): what its item-moving steps moved.
    if q.loop and not step.order and q.round and MOVERS[step.action] then
      q.round.movers=(q.round.movers or 0)+1
      q.round.moved=(q.round.moved or 0)+moved_count(result)
    end
    local r=q.loop and not step.order and not allows_short(step) and q.round
    local key=r and short_key(step,result)
    if not key then return end
    if not r.counts[key] then r.counts[key]=0; r.keys[#r.keys+1]=key end
    r.counts[key]=r.counts[key]+1; r.n=r.n+1
  end
  -- At a round's end: one line when its shorts differ from the last round's (a steady loop says it once).
  local function round_done(q)
    local r=q.round
    q.round={counts={},keys={},n=0}
    if not r then return end
    -- A round whose item-moving steps moved nothing: said in the history and the team block, and counted (idle.lua
    -- counts the loop as idle while its last round moved nothing).
    if (r.movers or 0)>0 then
      if (r.moved or 0)==0 then
        q.empty_rounds=(q.empty_rounds or 0)+1
        local line=string.format('queue %sround %d moved nothing (%d item-moving step%s; %d round%s in a row)',q.name and q.name..' ' or '',q.cycle or 1,
          r.movers,r.movers==1 and '' or 's',q.empty_rounds,q.empty_rounds==1 and '' or 's')
        q.history[#q.history+1]={action='round',ok=true,result={round=q.cycle or 1,moved=0,line=line},finished_tick=game.tick,plan=q.plan_seq}
        if #q.history>MAX_HISTORY then table.remove(q.history,1) end
        -- once a streak, in the team block (a round whose steps ran short has its own line below, naming them)
        if (r.n or 0)==0 and q.empty_rounds==1 then
          q.round_news=q.round_news or {}
          q.round_news[#q.round_news+1]=line
          while #q.round_news>3 do table.remove(q.round_news,1) end
        end
      else q.empty_rounds=nil end
    end
    local parts={}
    for _,key in ipairs(r.keys) do parts[#parts+1]=key..(r.counts[key]>1 and ' x'..r.counts[key] or '') end
    local sig=table.concat(parts,', ')
    if sig==(q.round_sig or '') then return end
    q.round_sig=sig
    if sig=='' then return end
    q.round_news=q.round_news or {}
    q.round_news[#q.round_news+1]=string.format('queue %sround %d: %d of %d steps short: %s',q.name and q.name..' ' or '',q.cycle or 1,r.n,#q.loop,sig)
    while #q.round_news>3 do table.remove(q.round_news,1) end
  end
  -- A loop's end (Muse, 21:20: refill loops of a set number of rounds or for a set time): after round `times`, or when
  -- the next round would start at or after stop_tick (for_ticks from the queue_repeat call); a round under way always
  -- finishes. The loop is gone (the queue is empty and free), with a history entry and one team block line.
  local function loop_over(q)
    if q.times and (q.cycle or 1)>=q.times then return string.format('%d of %d rounds run (times %d)',q.cycle or 1,q.times,q.times) end
    if q.stop_tick and game.tick+q.interval>=q.stop_tick then
      return string.format('no round starts at or after tick %d (for_ticks %d)',q.stop_tick,q.for_ticks)
    end
  end
  local function end_loop(q,why)
    q.loop_done={name=q.name,rounds=q.cycle or 1,reason=why,tick=game.tick}
    -- The loop's steps, as queue_repeat took them (Muse, Luna, shift19): with queue_status {args: true}.
    local steps={}
    for i,st in ipairs(q.loop or {}) do steps[i]={action=st.action,args=st.args,label=st.label,wait=st.wait,on_fail=st.on_fail,on_short=st.on_short,min_moved=st.min_moved} end
    q.loop_done.steps=#steps>0 and steps or nil
    q.history[#q.history+1]={action='loop_done',ok=true,result={rounds=q.cycle or 1,reason=why,name=q.name},finished_tick=game.tick,plan=q.plan_seq}
    if #q.history>MAX_HISTORY then table.remove(q.history,1) end
    q.round_news=q.round_news or {}
    q.round_news[#q.round_news+1]=string.format('queue %sdone after %d round%s: %s',q.name and q.name..' ' or '',q.cycle or 1,(q.cycle or 1)==1 and '' or 's',why)
    while #q.round_news>3 do table.remove(q.round_news,1) end
    -- With the loop its orders setting goes: the queue is free again, and every order may run as at any free time.
    q.loop=nil; q.next_cycle_tick=nil; q.times=nil; q.stop_tick=nil; q.for_ticks=nil; q.orders=nil; q.condition=nil
    q.revision=q.revision+1
  end
  -- The round lines not yet shown to the agent (the reply's team block).
  function M.round_news(index)
    local q=(api.state()[QUEUES] or {})[index]
    local lines=q and q.round_news
    if lines then q.round_news=nil end
    return lines
  end
  local function record(q,step,ok,result)
    if step.action=='wait_until' and api.wait_info then api.wait_info(result,step) end
    tally(q,step,result)
    -- with its arguments (Muse, Luna, shift19: a finished 40-round loop could not be rebuilt from its history)
    q.history[#q.history+1]={id=step.id,action=step.action,label=step.label,ok=ok,result=result,started_tick=step.started_tick,finished_tick=game.tick,order=step.order,
      plan=not step.order and (step.plan or q.plan_seq) or nil,args=step.args}
    if #q.history>MAX_HISTORY then table.remove(q.history,1) end
    q.revision=q.revision+1
  end
  -- Drops pending steps up to the labelled one; false when it is not pending.
  local function jump(q,label)
    for i,step in ipairs(q.pending) do
      if step.label==label then
        for _=1,i-1 do table.remove(q.pending,1) end
        q.revision=q.revision+1
        return true
      end
    end
    return false
  end
  -- A short step (out of items, an empty source, a full inventory: the outcomes below, or the error a transfer gives
  -- when none is held) with up_to=true in its args or on_short=skip is done, not failed: the plan goes on (couriers;
  -- Grok, Luna, Sonnet and Muse in shift08). The history entry says short.
  local SHORT={out_of_items=true,nothing_collected=true,inventory_full=true}
  local function short(step,result)
    if result and result.minimum_failed then return false end
    if not allows_short(step) then return false end
    if type(result)~='table' then return false end
    if SHORT[result.outcome] then return true end
    return type(result.reason)=='string' and result.reason:match('^no %S+ in inventory')~=nil
  end
  -- A failed step follows its on_fail policy; the default stops the plan.
  -- An item-moving step's entry says moved and carries the inventory line after it, as a direct reply does
  -- (runtime.lua M.moved_step; operator 08:01).
  local function moved(p,step,result)
    if api.moved_step and type(result)=='table' then pcall(api.moved_step,p,step,result) end
  end
  local function minimum(step,result)
    if not step.min_moved then return true end
    local r=type(result)=='table' and (result.completion or result) or {}
    local n=r.moved or r.transferred
    if type(n)=='number' and n>=step.min_moved then return true end
    if not result.minimum_failed then
      result.reason='transfer min_moved '..step.min_moved..': moved '..(type(n)=='number' and n or 'unknown')..(result.reason and '; '..result.reason or '')
    end
    result.minimum_failed=true
    return false
  end
  -- A batch step with entries that failed (Astra 07:50: queues read all ok while place_ghosts had failed entries, and
  -- key belts were never placed): place_ghosts and build (all=true lists the entries it could not build) report
  -- failed [{index, ..., error}]; such a step fails, so on_fail and the plan's outcome see it. A timed build (walking,
  -- stepping aside, awaiting a craft) keeps the batch's result in its completion. Tile areas' tiles_refused stay out
  -- (a tile already laid there is refused too).
  local ENTRY_STEPS={place_ghosts=true,build=true}
  local function entries_failed(step,result)
    if not ENTRY_STEPS[step.action] or type(result)~='table' then return nil end
    local r=result
    if type(r.completion)=='table' then r=type(r.completion.result)=='table' and r.completion.result or r.completion end
    local list=type(r.failed)=='table' and r.failed or nil
    if not list or #list==0 then return nil end
    local f=list[1]
    local what=type(f)=='table' and (f.name or f.item) or nil
    local pos=type(f)=='table' and type(f.position)=='table' and f.position or nil
    local at=pos and string.format(' (%g,%g)',pos.x or pos[1] or 0,pos.y or pos[2] or 0) or ''
    local placed=type(r.placed)=='number' and r.placed or type(r.built)=='number' and r.built or nil
    return string.format('%s: %d entr%s failed%s; first: #%s %s%s: %s',step.action,#list,#list==1 and 'y' or 'ies',
      placed and string.format(' (%d %s)',placed,step.action=='build' and 'built' or 'placed') or '',tostring(type(f)=='table' and f.index or '?'),tostring(what or '?'),at,
      tostring(type(f)=='table' and f.error or f)),#list
  end
  local function fail(q,p,step,result)
    minimum(step,result)
    moved(p,step,result)
    if short(step,result) then result.short=true; record(q,step,true,result); return end
    record(q,step,false,result)
    -- Counted for the agent's review (selfview.lua).
    if api.on_fail then pcall(api.on_fail,p.index,step.action,type(result)=='table' and (result.reason or result.outcome) or result) end
    local policy=step.on_fail or 'abort'
    if policy=='skip' then return end
    local label=policy:match('^goto:(.+)$')
    if label and jump(q,label) then api.stop(p); return end
    if label then q.history[#q.history].result.goto_error='label not pending: '..label end
    q.paused=true; api.stop(p)
    -- A standing order's run ends here (orders.lua counts the failure); its
    -- remaining steps are dropped, so the queue is free again.
    if q.order then
      local why=type(result)=='table' and (result.reason or result.outcome) or result
      q.order_result={name=q.order.name,outcome='failed',reason=step.action..': '..tostring(why),tick=game.tick}
      q.order=nil; q.pending={}; q.revision=q.revision+1
    end
  end
  local function check_guards(q,p)
    for i,g in ipairs(q.guards or {}) do
      local ok,met,saw=pcall(api.condition,p,g.when)
      if ok and met then
        -- A guard fires once; its reaction replaces whatever was running.
        table.remove(q.guards,i)
        if q.current then record(q,q.current,false,{reason='guard',condition=g.when['until'],saw=saw}); q.current=nil end
        api.stop(p)
        q.history[#q.history+1]={action='guard',ok=true,result={condition=g.when['until'],saw=saw},finished_tick=game.tick,plan=q.plan_seq}
        if #q.history>MAX_HISTORY then table.remove(q.history,1) end
        if g.steps then
          local items=copy_steps(g.steps); assign(q,items); q.pending=items
          for _,step in ipairs(items) do step.plan=q.plan_seq end
        elseif not (g['goto'] and jump(q,g['goto'])) then q.paused=true end
        q.revision=q.revision+1
        return
      end
    end
  end
  -- An interrupted step goes back to the head of pending work (restarting from
  -- scratch), so resuming retries it instead of running later steps without it.
  -- Steps toward an absolute goal restart cleanly; relative ones (walk N
  -- ticks, wait N ticks) would repeat what already happened, so they are not
  -- requeued.
  local RESTARTABLE={move_to=true,construct=true,build_path=true,mine=true,repair=true,kite=true,wait_until=true,rearm=true,refuel=true,collect=true,recover=true}
  function M.pause(index)
    local q=queue(index)
    if q.current then
      local step=q.current
      local again=RESTARTABLE[step.action]==true
      -- A transfer or feed tour (or a courier) with a part done goes on from the stops left (runtime: tour_left).
      local args=step.args
      local resumed
      local tl=step.tour_left
      if not again and tl and tl.done>0 and type(args)=='table' and (step.action=='transfer' or step.action=='feed' or step.action=='collect') then
        if tl.courier then
          -- taken at the picked place: what is left is the give at the destination
          local undelivered=math.max(0,(tl.taken or 0)-math.max(0,(tl.got or 0)-(tl.taken or 0)))
          local to=tl.positions[#tl.positions]
          if to and undelivered>0 and tl.item then
            args={position=to,direction='to_entity',item=tl.item,quality=tl.quality,count=undelivered,walk=true,inventory=tl.give_inventory,
              avoid_enemies=args.avoid_enemies,unsafe_goal=args.unsafe_goal}
            again=true; resumed=string.format('the take is done (%d %s); requeued as the give at (%g,%g)',tl.taken or 0,tl.item,to.x,to.y)
          end
        elseif #tl.positions>0 and (args.positions~=nil or args.position~=nil) then
          local rest={}
          for k,v in pairs(args) do rest[k]=v end
          rest.position=nil; rest.positions=tl.positions
          if tl.fill and type(args.count)=='number' then rest.count=math.max(1,args.count-(tl.got or 0)) end
          args=rest; again=true
          resumed=string.format('%d of %d stops done (moved %d); requeued with the %d left',tl.done,tl.total,tl.got or 0,#tl.positions)
        end
      end
      -- load_silo (Sonnet, Astra: a running or queued load_silo was failed by the agent's own build or transfer, and
      -- resume skipped it): requeued; a walking load's goals are the rocket's totals, so it goes on from what is aboard.
      if not again and step.action=='load_silo' and type(args)=='table' then
        local act=(api.state().active or {})[index]
        local goals=act and act.queued and act.op=='load_silo' and act.goals
        if type(goals)=='table' and #goals>0 then
          local rest,items={},{}
          for k,v in pairs(args) do rest[k]=v end
          for _,g in ipairs(goals) do items[#items+1]={item=g.name,quality=g.quality,count=g.target} end
          rest.items=items; rest.to_total=true
          args=rest
          resumed='requeued with the rocket\'s totals (to_total): it goes on from what is aboard'
        else
          resumed='requeued as it was'
        end
        again=true
        q.requeued_load={id=step.id,tick=game.tick}
      end
      record(q,step,false,{reason='interrupted',requeued=again or nil,resumed_from=resumed}); q.current=nil
      -- A walk through via points goes on from the first one it had not reached (runtime: via_done).
      if again and step.via_done and type(args)=='table' and type(args.via)=='table' then
        local rest,left={},{}
        for k,v in pairs(args) do rest[k]=v end
        for i=step.via_done+1,#args.via do left[#left+1]=args.via[i] end
        rest.via=#left>0 and left or nil
        args=rest
      end
      if again then table.insert(q.pending,1,{id=step.id,action=step.action,args=args,wait=step.wait,label=step.label,on_fail=step.on_fail,on_short=step.on_short,min_moved=step.min_moved,plan=step.plan}) end
    end
    q.paused=true; q.revision=q.revision+1
    -- A standing order stopped by anything else (the agent's own request, a
    -- ride, a death) keeps its remaining steps for later (orders.lua) and
    -- leaves the queue empty for the agent.
    if q.order then
      q.order_result={name=q.order.name,outcome='interrupted',remaining=copy_steps(q.pending),tick=game.tick}
      q.order=nil; q.pending={}
    end
  end
  -- Standing orders (orders.lua) run in the agent's own queue while it is
  -- free: no step running or pending and no repeating plan.
  function M.free(index)
    local q=(api.state()[QUEUES] or {})[index]
    return not q or (not q.current and #q.pending==0 and not q.loop)
  end
  -- Between the rounds of a repeating plan (Opus, shift13: orders never ran while Opus's queue repeated, so turret rearm
  -- and boiler fuel orders never fired): resting, not paused, no order in it. since: the tick its last round ended;
  -- next: when the next round is due (it waits for an order that runs then); orders: which may run (queue_repeat
  -- orders: triggers, the default; all; none).
  function M.resting(index)
    local q=(api.state()[QUEUES] or {})[index]
    if not (q and q.loop and not q.paused and not q.current and #q.pending==0 and not q.order) then return nil end
    local next_tick=q.next_cycle_tick or game.tick+(q.interval or 0)
    return {since=next_tick-(q.interval or 0),next=next_tick,orders=q.orders or 'triggers'}
  end
  -- A repeating plan that is not paused: which orders may run between its rounds (orders.lua's line).
  function M.loop_orders(index)
    local q=(api.state()[QUEUES] or {})[index]
    return q and q.loop and not q.paused and (q.orders or 'triggers') or nil
  end
  function M.run_order(index,name,items,reason)
    local q=queue(index)
    local rest=M.resting(index)
    assert(M.free(index) or (rest and rest.orders~='none'),'the queue is busy')
    items=copy_steps(items); assign(q,items)
    for _,step in ipairs(items) do step.order=name end
    q.pending=items; q.paused=false
    q.order={name=name,reason=reason,total=#items,started_tick=game.tick}
    q.revision=q.revision+1
  end
  -- The running order: name, reason, its step number and count.
  function M.order(index)
    local q=(api.state()[QUEUES] or {})[index]
    if not (q and q.order) then return nil end
    local o=q.order
    return {name=o.name,reason=o.reason,total=o.total,started_tick=o.started_tick,step=math.max(1,math.min(o.total,o.total-#q.pending))}
  end
  -- Ends the running order at once (removed, over its time): outcome and reason for orders.lua.
  function M.cancel_order(index,outcome,why)
    local q=(api.state()[QUEUES] or {})[index]
    if not (q and q.order) then return end
    local name=q.order.name
    if q.current then record(q,q.current,false,{reason=why}); q.current=nil end
    api.stop_index(index)
    q.order=nil; q.pending={}; q.paused=true; q.revision=q.revision+1
    q.order_result={name=name,outcome=outcome,reason=why,tick=game.tick}
  end
  function M.order_result(index)
    local q=(api.state()[QUEUES] or {})[index]
    local r=q and q.order_result
    if r then q.order_result=nil end
    return r
  end
  -- The agent's own queue calls come first: a running order steps aside.
  local function preempt(p,q)
    if q.order then api.stop(p); M.pause(p.index) end
  end
  -- A repeating plan resting between cycles runs nothing, so a runtime
  -- replacement leaves it scheduled instead of pausing the loop.
  function M.pause_all()
    for index,q in pairs(api.state()[QUEUES] or {}) do
      local resting=q.loop and not q.current and #q.pending==0 and not (api.state().active or {})[index]
      if not resting then M.pause(index) end
    end
  end
  -- queue_status is compact (Sol 10:50: a repeating courier plan's long done history hid its stalled step): the
  -- active step with how long it has run, the next pending step and the newest 3 history entries, with
  -- pending_count and history_total; pending and history take a count or 'all'.
  local function count_arg(v,default,max,what)
    if v==nil then return default end
    if v=='all' then return max end
    if type(v)~='number' or v~=math.floor(v) or v<0 or v>max then error(what..' is a count 0..'..max..' or "all"',0) end
    return v
  end
  function M.handlers.queue_status(p,a)
    a=a or {}
    local q=queue(p.index)
    assert(a.orders==nil or type(a.orders)=='boolean','orders must be true or false')
    assert(a.args==nil or type(a.args)=='boolean','args must be true or false')
    -- The plan's entries: up to 16 by default (its steps and outcomes); with orders, the newest 3 of all as before.
    local s=snapshot(q,count_arg(a.history,a.orders and RECENT or PLAN_RECENT,MAX_HISTORY,'history'),a.orders==true,a.args==true)
    local np=count_arg(a.pending,1,MAX_PENDING,'pending')
    if #q.pending>np then
      local some={}
      for i=1,np do some[i]=q.pending[i] end
      s.pending=some
    end
    s.pending_count=#q.pending
    s.history_total=#q.history
    if q.current then
      local active={}
      for k,v in pairs(s.active) do active[k]=v end
      if q.current.started_tick then active.running_s=math.floor((game.tick-q.current.started_tick)/60) end
      s.active=active
    end
    return s
  end
  -- Checks a plan as queue_submit would (saved plans, standing orders);
  -- returns its byte size and the checked steps.
  function M.validate(a)
    local items,corrected=steps(a)
    assert(#items<=MAX_PENDING,'queue capacity exceeded')
    guards(a)
    local size=total(items)
    assert(size<=MAX_BYTES,'queue argument byte budget exceeded')
    return size,items,corrected
  end
  -- A reply that carries the steps' corrections.
  local function with(out,corrected) out.corrected=corrected; return out end
  function M.handlers.queue_submit(p,a)
    -- dry_run (Luna 15:20): the plan checked as a submit checks it, nothing queued, the queue left as it is; the silo
    -- cargo its steps would leave before each launch (rocketload.lua M.simulate).
    assert(a.dry_run==nil or type(a.dry_run)=='boolean','dry_run must be true or false')
    if a.dry_run then
      local items,corrected=steps(a,p)
      guards(a,p)
      assert(#items<=MAX_PENDING,'queue capacity exceeded')
      local out={dry_run=true,queued=false,steps=#items}
      if api.simulate then
        local ok,sim=pcall(api.simulate,p,items)
        if ok then for k,v in pairs(sim) do out[k]=v end else out.simulate_error=api.reason and api.reason(sim) or tostring(sim) end
      end
      return with(out,corrected)
    end
    local q=queue(p.index); revision(q,a)
    local items,corrected=steps(a,p)
    local new_guards=guards(a,p)
    assert(a.mode==nil or a.mode=='append' or a.mode=='replace' or a.mode=='ahead' or a.mode=='pending','mode must be append, replace, ahead or pending')
    -- pending (Astra, d15 09:20: change what comes next while a load_silo runs): the pending steps are replaced, the
    -- active step and the guards stay; into a repeating plan it refuses (replace or ahead say what happens to the loop).
    if a.mode=='pending' then
      assert(not q.loop,'mode="pending" replaces the pending steps of an ordinary plan; this queue repeats ("'..tostring(q.name or 'unnamed repeating plan')..'"): replace or ahead')
      assert(#items<=MAX_PENDING,'queue capacity exceeded')
      assert(total(items)<=MAX_BYTES,'queue argument byte budget exceeded')
      assert(#(q.guards or {})+#new_guards<=MAX_GUARDS,'at most '..MAX_GUARDS..' guards')
      preempt(p,q)
      assign(q,items)
      for _,step in ipairs(items) do step.plan=q.plan_seq end
      local dropped=#q.pending
      q.pending=items
      q.guards=q.guards or {}
      for _,g in ipairs(new_guards) do q.guards[#q.guards+1]=g end
      if a.start~=false then q.paused=false end
      q.submission=string.format('pending replaced: %d dropped, %d queued; the active step goes on',dropped,#items)
      q.revision=q.revision+1
      return with(snapshot(q,RECENT),corrected)
    end
    local loop=q.loop and (q.name or 'unnamed repeating plan')
    local active=q.current and (q.current.id..' '..q.current.action) or 'between rounds'
    if loop and #items>0 and a.mode==nil then
      error('queue_submit queued nothing: repeating job "'..loop..'" ('..active..'); mode="replace" stops its active step and removes the loop; mode="ahead" runs before its remaining steps (restarts an active absolute-goal step); mode="append" waits behind the current round',0)
    end
    if a.mode=='ahead' and q.current then
      assert(RESTARTABLE[q.current.action],'mode="ahead" cannot restart active '..q.current.action..'; mode="replace" stops it and replaces the repeating plan')
    end
    local replacing=a.mode=='replace'
    local extra=a.mode=='ahead' and q.current and 1 or 0
    assert((replacing and 0 or #q.pending)+#items+extra<=MAX_PENDING,'queue capacity exceeded')
    assert((replacing and 0 or total(q.pending))+total(items)+(extra>0 and bytes(q.current,0) or 0)<=MAX_BYTES,'queue argument byte budget exceeded')
    assert((replacing and 0 or #(q.guards or {}))+#new_guards<=MAX_GUARDS,'at most '..MAX_GUARDS..' guards')
    preempt(p,q)
    if (replacing and loop) or a.mode=='ahead' then api.stop(p); M.pause(p.index)
    elseif replacing and q.current then
      -- replace stops the plan's active step too (Sonnet 07:50: a running load_silo went on after mode replace and
      -- took a queue_cancel first, about 5 times); its history entry says so, and it is not run again.
      local step=q.current
      api.stop(p); q.current=nil
      record(q,step,false,{reason='stopped by queue_submit mode=replace',stopped_by='replace'})
    end
    assign(q,items)
    if #items>0 then new_plan(q,items,'submit') end
    if replacing then q.pending={}; q.loop=nil; q.next_cycle_tick=nil; q.guards={}; q.times=nil; q.stop_tick=nil; q.orders=nil; q.condition=nil; q.condition_error=nil end
    q.submission=loop and ('repeating job "'..loop..'": '..(a.mode=='replace' and 'stopped and replaced' or a.mode=='ahead' and 'new steps run first; interrupted absolute-goal step restarts afterward' or 'new steps wait behind the current round ('..active..')')) or nil
    if a.mode=='ahead' then
      for i=#items,1,-1 do table.insert(q.pending,1,items[i]) end
    else
      for _,step in ipairs(items) do q.pending[#q.pending+1]=step end
    end
    q.guards=q.guards or {}
    assert(#q.guards+#new_guards<=MAX_GUARDS,'at most '..MAX_GUARDS..' guards')
    for _,g in ipairs(new_guards) do q.guards[#q.guards+1]=g end
    if a.start~=false then q.paused=false end
    q.revision=q.revision+1
    return with(snapshot(q,RECENT),corrected)
  end
  LOOP_WALK={transfer=true,collect=true,feed=true,rearm=true,refuel=true}
  function M.handlers.queue_repeat(p,a)
    local q=queue(p.index); revision(q,a)
    local items,corrected=steps(a,p)
    assert(#items>0,'repeating plan must not be empty')
    assert(total(items)<=MAX_BYTES,'queue argument byte budget exceeded')
    local interval=a.interval_ticks or 1800
    assert(type(interval)=='number' and interval==math.floor(interval) and interval>=60 and interval<=36000,'interval_ticks must be 60..36000')
    assert(a.name==nil or (type(a.name)=='string' and #a.name>=1 and #a.name<=32),'name must be 1..32 characters')
    local times,for_ticks=a.times,a.for_ticks
    assert(times==nil or (type(times)=='number' and times==math.floor(times) and times>=1 and times<=10000),'times must be 1..10000 rounds')
    assert(for_ticks==nil or (type(for_ticks)=='number' and for_ticks==math.floor(for_ticks) and for_ticks>=60 and for_ticks<=432000),
      'for_ticks must be 60..432000 ticks (2 hours)')
    if a.condition~=nil then
      checked('condition',function()
        api.validate_condition(a.condition)
        if api.check_step then api.check_step('wait_until',a.condition) end
        if api.check_action then api.check_action(p.index,'wait_until',a.condition) end
      end)
    end
    local met,saw
    if a.condition then met,saw=api.condition(p,a.condition) end
    local orders=a.orders
    if orders==true then orders='all' elseif orders==false then orders='none' end
    assert(orders==nil or orders=='triggers' or orders=='all' or orders=='none','orders must be triggers, all or none')
    preempt(p,q)
    api.stop(p)
    M.pause(p.index)
    new_plan(q,items,'repeat',a.name)
    q.loop=copy_steps(items); q.interval=interval; q.next_cycle_tick=nil; q.cycle=1; q.orders=orders
    q.name=a.name; q.round={counts={},keys={},n=0}; q.round_sig=nil; q.round_news=nil; q.empty_rounds=nil
    q.times=times; q.for_ticks=for_ticks; q.stop_tick=for_ticks and game.tick+for_ticks or nil; q.loop_done=nil; q.condition=a.condition; q.condition_error=nil; q.submission=nil
    assign(q,items); q.pending=items; q.paused=false; q.revision=q.revision+1
    if met then q.pending={}; q.cycle=0; end_loop(q,"condition met: "..tostring(saw or a.condition["until"])) end
    return with(snapshot(q,RECENT),corrected)
  end
  function M.handlers.queue_edit(p,a)
    local q=queue(p.index)
    -- id (Astra, d15 09:20): a pending step by its job id (queue_status pending: "job-12"), without a revision; to: move
    -- it to that pending place (1-based) instead of editing; the active step is never touched.
    if a.id~=nil then
      assert(a.index==nil,'give id or index, not both')
      local at
      for i,step in ipairs(q.pending) do if step.id==a.id then at=i; break end end
      if not at then
        local ids={}
        for i=1,math.min(8,#q.pending) do ids[#ids+1]=q.pending[i].id..' '..q.pending[i].action end
        error('no pending step '..tostring(a.id)..(q.current and q.current.id==a.id and ' (it is the active step: queue_edit changes pending steps only)' or '')
          ..'; pending: '..(#ids>0 and table.concat(ids,', ') or 'none'),0)
      end
      if a.to~=nil then
        assert(a.steps==nil and a.remove==nil,'to moves the step; steps and remove go without to')
        assert(type(a.to)=='number' and a.to==math.floor(a.to) and a.to>=1 and a.to<=#q.pending,'to is a pending place 1..'..#q.pending)
        local step=table.remove(q.pending,at)
        table.insert(q.pending,a.to,step)
        q.revision=q.revision+1
        return snapshot(q,RECENT)
      end
      local b={}
      for k,v in pairs(a) do b[k]=v end
      b.id=nil; b.index=at; b.expected_revision=q.revision
      if b.remove==nil then b.remove=1 end
      b.steps=b.steps or {}
      a=b
    end
    assert(a.expected_revision~=nil,'queue_edit requires expected_revision (or id: a pending step\'s job id)')
    revision(q,a)
    assert(not q.order,'a standing order ('..(q.order and q.order.name or '')..') is running in the queue: queue_cancel stops it, then edit your own steps')
    local index=a.index
    assert(type(index)=='number' and index==math.floor(index) and index>=1 and index<=#q.pending+1,'index outside pending queue (1-based)')
    local remove=a.remove or 0
    assert(type(remove)=='number' and remove==math.floor(remove) and remove>=0 and remove<=#q.pending-index+1,'invalid remove count')
    local items,corrected=steps(a,p)
    assert(#q.pending-remove+#items<=MAX_PENDING,'queue capacity exceeded')
    local size=total(q.pending)+total(items)
    for n=index,index+remove-1 do size=size-bytes(q.pending[n],0) end
    assert(size<=MAX_BYTES,'queue argument byte budget exceeded')
    assign(q,items)
    for _,step in ipairs(items) do step.plan=q.plan_seq end
    for _=1,remove do table.remove(q.pending,index) end
    for n=#items,1,-1 do table.insert(q.pending,index,items[n]) end
    q.revision=q.revision+1
    return with(snapshot(q,RECENT),corrected)
  end
  function M.handlers.queue_cancel(p,a)
    local q=queue(p.index); revision(q,a)
    preempt(p,q)
    api.stop(p)
    M.pause(p.index)
    if a.clear~=false then q.pending={}; q.loop=nil; q.next_cycle_tick=nil; q.guards={}; q.times=nil; q.stop_tick=nil; q.orders=nil; q.condition=nil; q.condition_error=nil end
    return snapshot(q,RECENT)
  end
  function M.handlers.queue_resume(p,a)
    local q=queue(p.index); revision(q,a)
    q.paused=false; q.revision=q.revision+1
    return snapshot(q,RECENT)
  end
  -- A call timed as its own profile part while the operator profile runs (runtime M.timed; operator 18:12:
  -- scheduler.tick 182 ms in one game second at 17:53); else just the call.
  local function timed(label,fn,...)
    if api.timed then return api.timed(label,fn,...) end
    return fn(...)
  end
  function M.tick()
    for index,q in pairs(api.state()[QUEUES] or {}) do
      if not q.paused then
        -- A vehicle step (a drive, getting in or out) runs with the character seated, as a direct vehicle call does;
        -- any other step needs it on foot: the lookup refuses a seated one and the plan pauses, as before
        -- (eng/queuecliffs: a queued drive paused its plan the tick after it began).
        local nxt=q.current or (not q.current and q.pending[1]) or nil
        local valid,p=pcall(api.player,index,nxt and nxt.action=='vehicle' or nil)
        if not valid then
          api.stop_index(index); M.pause(index)
        else
          -- The agent's guards watch its own plans, not a standing order's run.
          if q.guards and #q.guards>0 and not q.order and game.tick%CHECK_TICKS==0 then check_guards(q,p) end
          if q.current and q.current.action=='wait_until' then
            local step=q.current
            if game.tick>=step.next_check then
              step.next_check=game.tick+CHECK_TICKS
              local ok,met,saw=pcall(timed,'scheduler.wait_until',api.wait_check or api.condition,p,step.args,step)
              step.saw=ok and saw or nil
              q.current=nil
              local result={saw=step.saw}
              if not ok then result.reason=tostring(met); fail(q,p,step,result)
              elseif met then result.outcome='met'; record(q,step,true,result)
              elseif game.tick>=step.until_tick then result.outcome='timed_out'; fail(q,p,step,result)
              else q.current=step end
            end
          elseif q.current then
            local step=q.current
            local waiting=step.action=='wait_ticks' and game.tick<step.until_tick or
              step.action~='wait_ticks' and api.busy(p,step.action)
            if not waiting then
              local outcome=step.action~='wait_ticks' and api.outcome and api.outcome(p,step.action) or nil
              local success=not outcome or SUCCESS[outcome]==true
              local result={accepted=step.result,outcome=outcome or 'completed',completion=api.completion and api.completion(p,step.action)}
              q.current=nil
              local partial,nfailed=entries_failed(step,result)
              if partial then result.reason=partial; result.entries_failed=nfailed end
              if success and not partial and minimum(step,result) then moved(p,step,result); record(q,step,true,result) else fail(q,p,step,result) end
            end
          end
          -- An order running between rounds finishes first; the next round loads after it.
          if not q.paused and not q.current and #q.pending==0 and q.loop and not q.order then
            if not q.next_cycle_tick then
              round_done(q)
              local why=loop_over(q)
              if q.condition then
                local ok,met,saw=pcall(api.condition,p,q.condition)
                if not ok then q.paused=true; q.condition_error=tostring(met)
                elseif met then why='condition met: '..tostring(saw or q.condition['until']) end
              end
              if why then end_loop(q,why) else q.next_cycle_tick=game.tick+q.interval end
            end
            -- An order between rounds can hold the next round back to or past for_ticks' end: no round starts then.
            if q.loop and q.stop_tick and game.tick>=q.next_cycle_tick and game.tick>=q.stop_tick then
              end_loop(q,string.format('no round starts at or after tick %d (for_ticks %d)',q.stop_tick,q.for_ticks))
            end
            if q.loop and not q.paused and game.tick>=q.next_cycle_tick and q.condition then
              local ok,met,saw=pcall(api.condition,p,q.condition)
              if not ok then q.paused=true; q.condition_error=tostring(met)
              elseif met then end_loop(q,'condition met: '..tostring(saw or q.condition['until'])) end
            end
            if q.loop and not q.paused and game.tick>=q.next_cycle_tick then
              q.pending=copy_steps(q.loop); assign(q,q.pending)
              q.next_cycle_tick=nil; q.cycle=q.cycle+1; q.revision=q.revision+1
            end
          end
          -- A plan submitted while a direct command still drives the
          -- character runs after it, as if it had been the plan's first step.
          q.after_direct=nil
          if not q.paused and not q.current and #q.pending>0 and api.direct_action then q.after_direct=api.direct_action(p,q.pending[1].action) end
          for _=1,MAX_INSTANT do
            if q.paused or q.current or q.after_direct or #q.pending==0 then break end
            local step=table.remove(q.pending,1)
            step.started_tick=game.tick
            q.revision=q.revision+1
            -- Every step started counts as the agent's (selfview.lua my_hour).
            if api.on_step then pcall(api.on_step,index,step.action) end
            local allowed,why=true,nil
            if api.check_step then allowed,why=pcall(api.check_step,step.action,step.args) end
            if allowed and api.check_action then allowed,why=pcall(api.check_action,index,step.action,step.args) end
            if not allowed then
              fail(q,p,step,{reason=api.reason and api.reason(why) or tostring(why)})
            elseif step.action=='wait_ticks' then
              step.until_tick=game.tick+step.args.ticks
              q.current=step
            elseif step.action=='wait_until' then
              -- Checked from the next tick, so a wait placed after an action
              -- sees the world that action changed.
              step.until_tick=game.tick+(step.args.timeout or 3600)
              step.next_check=game.tick+1
              if api.wait_info then
                local text=step.args['until']
                step.wait_estimates={{condition=text,as_of_tick=game.tick,no_estimate='first condition observation pending',
                  line=text..': no estimate (first condition observation pending)'}}
              end
              q.current=step
            else
              -- What the step moves by hand is the queue's or its standing order's (hauling.lua).
              if api.step_begin then pcall(api.step_begin,index,step) end
              -- A repeating loop's hand steps walk into reach (Muse, d15 twice: a hand haul ended elsewhere and the loop's
              -- collect failed out of reach, past the 32 tiles a call walks by default): a transfer, collect, feed, rearm
              -- or refuel step with a position and no walk runs with walk: true; walk: false keeps it from walking.
              local args=step.args
              if q.loop and not step.order and LOOP_WALK[step.action] and type(args)=='table' and args.walk==nil and args.from==nil
                and (args.position~=nil or args.positions~=nil) then
                local c={}
                for k,v in pairs(args) do c[k]=v end
                c.walk=true; args=c
              end
              local ok,result=pcall(timed,'scheduler.step '..tostring(step.action),api.handlers[step.action],p,args)
              if ok and api.claim then api.claim(p) end
              if api.step_done then pcall(api.step_done,index) end
              if not ok then
                fail(q,p,step,{reason=api.reason and api.reason(result) or tostring(result)})
              elseif step.wait and api.busy(p,step.action) then
                step.result=result; q.current=step
              elseif entries_failed(step,result) then
                result.reason,result.entries_failed=entries_failed(step,result)
                fail(q,p,step,result)
              elseif minimum(step,result) then moved(p,step,result); record(q,step,true,result)
              else fail(q,p,step,result) end
            end
          end
          if q.order and not q.paused and not q.current and #q.pending==0 then
            q.order_result={name=q.order.name,outcome='done',tick=game.tick}
            q.order=nil; q.revision=q.revision+1
          end
        end
      end
    end
  end
  -- A direct wait while the queue runs would pause it (runtime.lua dispatch_request refuses it).
  local PAUSE_QUEUE='direct call only, boolean: true pauses your running queue for this wait; without it a direct wait refuses while your queue runs (fh sleep SECONDS waits and lets it run)'
  M.schema={
    queue_status={args='optional true: each history entry with the arguments its step ran with, and loop_done with the finished loop\'s steps (as queue_repeat took them), so a finished plan or loop can be submitted again',history='optional count 0..64 or "all": newest history entries of the plan (default 16; with orders, of all entries, default 3)',pending='optional count 0..128 or "all": next pending steps (default 1)',
      orders='true: the standing orders\' history entries too, every entry in order as it ran (default: the plan last submitted only, the orders\' entries counted in orders_history)',
      returns='active (the running step in full, running_s: how long it has run), pending (the next step), plan {id, kind submit|repeat, name, submitted_s_ago, steps, done, ok, failed, pending, running}: the plan last submitted (queue_submit or queue_repeat), history (its entries, the newest 16), orders_history (how many entries standing orders left, not listed), pending_count, history_total, last_failure (the plan\'s), waiting, guards, repeating, cycle; a loop with an end: times, rounds_left (after this round), stops_tick; loop_done {name, rounds, reason, tick} once one ended'},
    queue_repeat={steps='replace the queue with a repeating plan; errors pause it; cancel clear=true removes the loop',interval_ticks='60..36000 pause between cycles; default 1800',expected_revision='optional',
      orders='which standing orders may run in the pause between rounds: triggers (default: orders with when, as they would while you are free), all (the default routine too) or none; an order that runs then finishes before the next round loads (the round waits for it, up to its max_ticks); its hold counts from your own last request, not the round\'s last step; queue_status says orders_between_rounds',
      name='optional 1..32 characters: names the loop in its round lines',
      condition='optional wait_until condition object: checked before the first round, after each round and before the next; a met condition ends the loop successfully, without starting another round',
      times='optional 1..10000: the number of rounds; after the last one the loop ends',
      for_ticks='optional 60..432000: from this call, no round starts at or after that many ticks (a round under way finishes); with times, whichever comes first ends the loop',
      note='a loop that ends (times, for_ticks) leaves the queue empty: history entry loop_done {rounds, reason}, queue_status loop_done, and one team block line under queue ("queue NAME done after N rounds: ...");a round whose steps ran short (out_of_items, nothing_collected, inventory_full, none held, or a short reply) puts one line in the team block (queue: "queue NAME round N: K of M steps short: transfer iron-plate inventory_full x2, ..."), only when it differs from the last round\'s; a step with up_to=true or on_short=skip is left out of it (its history entry says short=true)'},
    queue_submit={steps='array of {action,args,wait?,label?,on_fail?,min_moved?}; max 128; wait defaults true; use shoot wait=false for firing while walking; a timed action started by a direct call finishes first (after_direct names it; to preempt it, stop then queue_resume)',mode='append|replace|ahead|pending: pending replaces the pending steps and keeps the active step and guards (ordinary plans; a repeating plan refuses); omitted refuses nonempty submits into a repeating plan, naming it; replace stops the active step (its history entry: stopped by queue_submit mode=replace; not run again), drops pending steps and guards, and removes a loop; ahead interrupts and restarts an absolute-goal step after the new steps, preserving the loop (other active steps refuse); append explicitly waits behind the current round',start='default true',expected_revision='optional optimistic concurrency guard',guards='optional, see guards; replace clears them',
      dry_run='true: check the plan as a submit does and queue nothing (the queue is left as it is); returns steps, corrected, and the silo cargo the steps would leave: launches [{step, label, silo, cargo (before that launch), kg, min_cargo (lines), platform_now, would_refuse}], silos_after, notes (steps whose item moves are not counted); counted from what you, the chests and the silos hold now through transfer, load_silo and launch steps'},
    queue_edit={expected_revision='required from queue_status (not with id)',index='1-based pending index',remove='count to remove (with id: default 1, the step itself)',steps='replacement steps (with id: in its place; none: the step is deleted)',
      id='a pending step\'s job id (queue_status pending, "job-12"): edit, delete or move that step; the active step is never touched',to='with id: move that step to this pending place (1-based)'},
    queue_cancel={clear='default true; false retains pending steps; always cancels active controls and pauses',expected_revision='optional'},
    queue_resume={expected_revision='optional'},
    wait_ticks={ticks='1..54000 simulation ticks: a queue step, or a direct timed action (fh call wait_ticks --wait)',pause_queue=PAUSE_QUEUE,
      wake_on_viewers='direct call only, optional true (fh --wake-on-viewers): a viewer\'s @mention ends it too (a tell or teammate\'s mention does by default)',
      wake_on_messages='direct call only, boolean default true; false keeps waiting through all tells and mentions, including viewers; messages remain in the next reply'},
    wait_until={['until']='no_enemy_structures|no_enemies|turrets_idle|ammo_below|health_below|health_above|item_count|rocket_ready|rocket_parts|crafting_done|researched|ghosts_waiting|damaged|fuel_below|platform_arrived|platform_left|produced|platform_built; a queue step, a standing order\'s when, a queue guard\'s when, or a direct timed action (fh call wait_until --wait): outcomes met | timed_out | failed; status/last show saw, wait_estimates (ETA/rate basis or no_estimate), idle_s (character idle seconds in this wait), wait_line (one line)',
      position='area predicates: centre (default character); rocket_ready: the rocket silo (any tile of it), met when its rocket is built and ready to launch (saw: rocket state, parts, cargo); rocket_parts: the silo, met when the rocket being built has at_least parts (a built rocket, rising or ready, has all of them; while one launches, the next one\'s count; saw: rocket parts N/50 and the silo line)',area='ammo_below/fuel_below: {left_top,right_bottom} up to 256x256, excludes position/radius',radius='1..256 (default 32)',count='ammo_below: per-turret ammo items; fuel_below: fuel items per burner machine (furnaces, drills, boilers, burner inserters, ...)',fraction='health_*: 0..1; damaged: our buildings under this health fraction (default 1: any damage)',
      item='item_count; produced (optional)',platform_built='platform (name): met when no tile ghost (foundation) is left on it; entities: true also no entity ghost; saw: platform NAME: N tile ghosts left (, M entity ghosts); a remote lane wait',entities='platform_built: true also waits for no entity ghost on the platform (default: tile ghosts only)',produced='positions (or position): 1..64 machines of ours; met when they made at_least items of item (crafts times what the recipe makes of it per craft; without item: crafts) since the wait began, by the products-finished counter each machine\'s GUI shows; a wait_until step or a direct wait only (a guard, an order\'s when or a loop condition refuses); saw: made N item (K crafts) in M machines since the wait began',at_least='item_count; produced; rocket_parts: parts 1..required; ghosts_waiting: ghosts (entity and tile) in the area (default 1)',below='item_count',positions='item_count: 1..64 {x,y} of our entities (chests, machines) to count in, summed over all their inventories (a rocket silo\'s rocket cargo too; saw adds each silo\'s rocket state and cargo: the rocket is no item, the item rocket is ammunition); default the character\'s inventory',technology='researched',platform='item_count: count landed items in the named platform hub main inventory (not incoming cargo or hub trash); no positions or surface; platform_arrived, platform_left: a platform of ours by name; platform_arrived is met while it is stopped at a space location (the platform list shows it there, not on its path or a route); platform_left while it is not (Gemini, 16:50: departure)',location='platform_arrived, platform_left: optional planet name; default any stop',timeout='ticks 1..54000 (default 3600; fh call wait_until --wait takes it from --wait-timeout); timing out fails the step (timed_out)',
      checked='every 10 ticks; enemies count only if known from the chart (units only in visible chunks)',pause_queue=PAUSE_QUEUE,
      wake_on_viewers='direct call only, optional true (fh --wake-on-viewers): a viewer\'s @mention ends it too (a tell or teammate\'s mention does by default)',
      wake_on_messages='direct call only, boolean default true; false keeps waiting through all tells and mentions, including viewers; messages remain in the next reply'},
    step_options={min_moved='transfer steps only, integer 1..10000, wait=true: require at least this many reported items moved after completion; otherwise on_fail applies, even with up_to=true or on_short=skip; missing moved count is unknown and fails; no rollback',label='name a step as a goto target',on_fail='abort (default: pause plan) | skip | goto:<label> (drops pending steps before it); a place_ghosts or build step with failed entries (build all=true) fails: reason "place_ghosts: N entries failed (K placed); first: #i NAME (x,y): why", entries_failed N, the entries placed stay',on_short='skip: a step that runs short (out_of_items, nothing_collected, inventory_full, or no item held to give) counts as done (history: short=true) and the plan goes on; up_to=true in a transfer, collect or feed step does the same'},
    guards={usage='queue_submit guards=[{when={until=...,...}, goto=label | steps=[...] | neither=abort}]; checked every 10 ticks while the plan runs; each fires once, stops the running step',max=MAX_GUARDS}
  }
  return M
end
