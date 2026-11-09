-- Compound wait members must never borrow another member's baseline.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,why) assert(a==b,(why or '')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,t) assert(s:find(t,1,true),s..' lacks '..t) end
game={tick=100}
prototypes={space_location={nauvis={},gleba={}}}
local ships={{valid=true,name='A',surface={name='A'}},{valid=true,name='B',surface={name='B'}}}
local drops={[1]={id=1,platform='A',state='landed'},[2]={id=2,platform='B',state='descending'}}
local latest={A=1,B=2}
local techs={a={level=2,researched=false,prototype={max_level=100}},b={level=8,researched=false,prototype={max_level=100}}}
local p={index=1,character={valid=true,health=250},force={name='player',platforms=ships,technologies=techs}}
local where={A={stopped=true,at='nauvis',text='at nauvis'},B={text='flying'}}
local api={last_drop=function(name) return latest[name] end,drop_record=function(id) return drops[id] end,
  platform_where=function(pl) return where[pl.name] end}
local C=require('conditions')(api)
local function pod(name,id) return {['until']='pod_landed',platform=name,drop_id=id,last_drop=id==nil or nil} end
local function group(kind,a,b) return {['until']=kind,conditions={a,b}} end
local function ordered(a,b,reverse) if reverse then return b,a end; return a,b end

-- Aurora's reproduction: the first landed pod made both members look landed.
for _,reverse in ipairs{false,true} do
  for _,last in ipairs{false,true} do
    drops[1].state='landed'; drops[2].state='descending'
    local a,b=ordered(pod('A',not last and 1 or nil),pod('B',not last and 2 or nil),reverse)
    local c=group('all',a,b); C.validate(c)
    local record={start_tick=90}
    local met,saw=C.check(p,c,nil,record)
    eq(met,false,'all must wait for the second cargo pod'); has(saw,'drop #1'); has(saw,'drop #2 from B still descending')
    drops[2].state='landed'
    eq(C.check(p,c,nil,record),true)
    drops[2].state='descending'
    c=group('any',a,b); record={start_tick=90}
    met,saw=C.check(p,c,nil,record)
    eq(met,true,'any must see the landed pod in either order')
    eq(record.matched.index,reverse and 2 or 1); has(saw,'drop #2 from B still descending')
  end
end
print('compound baselines: cargo reproduction and reversed order ok')

local function research(name) return {['until']='researched',technology=name} end
local function left(name) return {['until']='platform_left',platform=name,location='nauvis'} end
for _,reverse in ipairs{false,true} do
  for _,kind in ipairs{'all','any'} do
    techs.a.level,techs.b.level=2,8
    local a,b=ordered(research('a'),research('b'),reverse)
    local c=group(kind,a,b); local record={start_tick=90}
    eq(C.check(p,c,nil,record),false,'neither research level has completed')
    techs.a.level=3
    eq(C.check(p,c,nil,record),kind=='any','only research a completed')
    techs.b.level=9
    eq(C.check(p,c,nil,record),true,'both research levels completed')

    -- Seeing A stopped must not make B's already ongoing flight a departure.
    where.A={stopped=true,at='nauvis',text='at nauvis'}; where.B={text='flying'}
    a,b=ordered(left('A'),left('B'),reverse)
    c=group(kind,a,b); record={start_tick=90}
    eq(C.check(p,c,nil,record),false,'B has not been observed stopped')
    where.A={text='flying'}
    eq(C.check(p,c,nil,record),kind=='any','only A left after the baseline')
    where.B={stopped=true,at='nauvis',text='at nauvis'}
    C.check(p,c,nil,record)
    where.B={text='flying'}
    eq(C.check(p,c,nil,record),true,'both platforms left')
  end
end

-- Duration state must not be reset by the other platform's low speed.
game.tick=1000; ships[1].speed=2; ships[2].speed=0
local speed=group('any',{['until']='platform_speed_above',platform='A',above=60,for_s=1},
  {['until']='platform_speed_above',platform='B',above=60,for_s=1})
local rec={start_tick=1000}
eq(C.check(p,speed,nil,rec),false)
game.tick=1060
eq(C.check(p,speed,nil,rec),true); eq(rec.matched.index,1)
eq(rec.evidence.platform,'B','shared evidence retains the existing last-writer behavior')
eq(rec.condition_members[1].speed_since,1000); eq(rec.condition_members[2].speed_since,nil)

-- Different explicit time windows are member state too.
api.losses_since=function(_,surface,since)
  local tick=surface=='A' and 950 or 1050
  local rows=tick>since and {{n='inserter',x=0,y=0,t=tick}} or {}
  return rows,#rows
end
C=require('conditions')(api)
local losses=group('all',{['until']='platform_loss',platform='A',since_tick=900},
  {['until']='platform_loss',platform='B',since_tick=1060})
local met,saw=C.check(p,losses,nil,{start_tick=900})
eq(met,false); has(saw,'since tick 900'); has(saw,'since tick 1060')

-- Nested evaluation has separate state at every path and parent-level diagnostics.
-- Submission still requires plain members; this fix does not expand that API.
drops[1].state='landed'; drops[2].state='descending'
local nested=group('all',group('any',pod('B',2),pod('A',1)),group('all',pod('A',1),pod('B',2)))
assert(not pcall(C.validate,nested),'nested submission remains refused')
rec={start_tick=80,wait_started=90,started_tick=85,after_step={tick=70,action='platform_schedule'}}
eq(C.check(p,nested,nil,rec),false)
eq(rec.matched,nil,'inner any must not overwrite parent diagnostics')
eq(rec.condition_members[1].matched.index,2)
local child=rec.condition_members[2].condition_members[2]
eq(child.start_tick,80); eq(child.wait_started,90); eq(child.started_tick,85); eq(child.after_step.tick,70)

-- Simulate serialized storage, with no metatables or parent cycles to restore.
local function copy(v,seen)
  if type(v)~='table' then return v end
  assert(getmetatable(v)==nil,'record must be plain storage data')
  seen=seen or {}; if seen[v] then return seen[v] end
  local out={}; seen[v]=out
  for k,x in pairs(v) do assert(type(k)=='string' or type(k)=='number'); out[k]=copy(x,seen) end
  return out
end
rec=copy(rec); C=require('conditions')(api)
eq(C.check(p,nested,nil,rec),false)
drops[2].state='landed'
eq(C.check(p,nested,nil,rec),true)

-- Parent timing still reaches platform arrival/departure event readers.
local arrival_since,departure_since
api.arrived_since=function(_,_,_,since) arrival_since=since end
api.left_since=function(_,_,_,since) departure_since=since end
C=require('conditions')(api)
local timed=group('all',{['until']='platform_arrived',platform='A',location='gleba'},left('B'))
rec={start_tick=50,after_step={tick=40,action='platform_schedule'}}
C.check(p,timed,nil,rec)
eq(arrival_since,50); eq(departure_since,40)
rec.after_step={tick=60,action='platform_schedule'}
C.check(p,timed,nil,rec)
eq(arrival_since,50,'arrival baseline retained'); eq(departure_since,60,'shared context refreshed')

-- Real scheduler hold and pause/requeue retain every member, including across reload.
for _,mode in ipairs{'hold','pause'} do
  local state={}; local ran=0
  game.tick=2000; techs.a.level,techs.b.level=2,8
  drops[1].state='descending'; drops[2].state='descending'; latest={A=1,B=2}
  where.A={stopped=true,at='nauvis',text='at nauvis'}; where.B={stopped=true,at='nauvis',text='at nauvis'}
  local function scheduler()
    C=require('conditions')(api)
    return require('scheduler'){state=function() return state end,player=function() return p end,
      handlers={craft=function() ran=ran+1; return {started=1} end},busy=function() return false end,
      stop=function() end,condition=function(pp,c,r) return C.check(pp,c,nil,r) end,validate_condition=C.validate}
  end
  local Q=scheduler()
  local function tick(n) for _=1,n do game.tick=game.tick+1; Q.tick() end end
  local c={['until']='all',conditions={pod('A'),pod('B'),research('a'),research('b'),left('A'),left('B')},timeout=30,on_timeout='hold'}
  Q.handlers.queue_submit(p,{steps={{action='wait_until',args=c},{action='craft'}}})
  tick(mode=='hold' and 60 or 15)
  if mode=='pause' then Q.pause(1,'test pause') end
  eq(state.queues[1].paused,true); eq(ran,0)
  local members=state.queues[1].pending[1].condition_members
  eq(members[1].drop_id,1); eq(members[2].drop_id,2)
  eq(members[3].tech_start,2); eq(members[4].tech_start,8)
  drops[3]={id=3,platform='A',state='descending'}; drops[4]={id=4,platform='B',state='descending'}
  latest={A=3,B=4} -- A resume must keep the original latest drops.
  drops[1].state='landed'; techs.a.level=3; where.A={text='flying'}
  state=copy(state); Q=scheduler()
  Q.handlers.queue_resume(p,{})
  tick(15); eq(ran,0,'B is still pending after reload/resume')
  drops[2].state='landed'; techs.b.level=9; where.B={text='flying'}
  tick(15); eq(ran,1,'only completion of every original member advances')
  local out=Q.handlers.queue_status(p,{})
  eq(out.pending_count,0); has(out.history[#out.history-1].result.saw,'drop #2 from B landed')
end
print('compound baselines: research, platforms, nested state, timing, hold, pause and reload ok')

-- Sleep flattens any/list members, and can nest an all under that outer any.
for _,reverse in ipairs{false,true} do
  for _,shape in ipairs{'any','list','nested'} do
    game.tick=3000; latest={A=1,B=2}; drops[1].state='descending'; drops[2].state='descending'
    local state={active={}}
    local function sleep_module()
      C=require('conditions')(api)
      local W=require('waiteta'){check=function(pp,c,r) return C.check(pp,c,true,r) end}
      return require('waits'){state=function() return state end,integer=function(v,d) return v or d end,
        clock_mode=function() return 'realtime' end,condition=W.check,validate_condition=C.validate,wait_info=W.info}
    end
    local Sleep=sleep_module()
    local a,b=ordered(pod('A'),pod('B'),reverse)
    local c=shape=='list' and {a,b} or group('any',a,b)
    if shape=='nested' then c=group('any',group('all',a,b),{['until']='tick_at_least',tick=4000}) end
    local out=Sleep.handlers.sleep(p,{seconds=60,condition=c})
    eq(out.already_met,nil)
    drops[1].state='landed'
    state=copy(state); Sleep=sleep_module(); game.tick=3010
    out=Sleep.handlers.sleep_check(p,{peek=true})
    eq(out.woke,shape~='nested' and 'condition' or nil)
    if shape=='nested' then drops[2].state='landed'; out=Sleep.handlers.sleep_check(p,{peek=true}); eq(out.woke,'condition') end
    -- The terminal refresh still reads B's original drop, despite a newer one.
    drops[2].state='landed'; latest.B=4; game.tick=3020
    out=Sleep.handlers.sleep_check(p,{})
    eq(out.woke,'condition'); eq(out.sleep_started_tick,3000)
  end
end

-- A different wake also re-reads every member with its own original baseline.
do
  local state={active={}}
  game.tick=5000; drops[1].state='descending'; drops[2].state='descending'; latest={A=1,B=2}
  local W=require('waiteta'){check=function(pp,c,r) return C.check(pp,c,true,r) end}
  local Sleep=require('waits'){state=function() return state end,integer=function(v,d) return v or d end,
    clock_mode=function() return 'realtime' end,condition=W.check,validate_condition=C.validate}
  Sleep.handlers.sleep(p,{seconds=60,condition=group('any',pod('A'),pod('B'))})
  state.sleeps[1].told_wake='tester'; latest={A=3,B=4}
  game.tick=5010
  local out=Sleep.handlers.sleep_check(p,{})
  eq(out.woke,'told'); has(out.waited_now[1],'drop #1'); has(out.waited_now[2],'drop #2')
end
print('compound baselines: sleep any/list, nested all, reload and post-wake reads ok')
