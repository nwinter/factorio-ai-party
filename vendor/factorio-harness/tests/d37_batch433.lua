-- batch433: recovery schedules are idempotent without swallowing unrelated failures.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or '')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
local function fails(fn,x) local ok,e=pcall(fn); eq(ok,false); has(e,x) end
local S={on_the_path=2,waiting_at_station=6,paused=7,no_schedule=1,no_path=3}
defines={space_platform_state=S,rocket_silo_status={},inventory={hub_main=1}}
prototypes={space_location={nauvis={},gleba={}},item={},fluid={}}
local function fixture(opts)
  opts=opts or {}; game={tick=1000}
  local st={active={}}
  local records={{station='nauvis',wait_conditions={{type='time',ticks=600}}},{station='gleba',wait_conditions={{type='time',ticks=600}}}}
  local pl={valid=true,index=1,name='Asterion',state=opts.state or S.on_the_path,paused=opts.paused or false,
    distance=0.375,speed=0.1,schedule={current=opts.current or 2,records=records},
    space_connection={name='nauvis-gleba',from={name='nauvis'},to={name='gleba'},length=15000}}
  if opts.docked then pl.space_connection=nil; pl.space_location={name=records[pl.schedule.current].station} end
  if opts.empty then pl.schedule=nil end
  local calls,wait_progress=0,245
  local sch=setmetatable({},{__index=function(_,k) if k=='current' then return pl.schedule and pl.schedule.current end end})
  sch.get_record_count=function() return pl.schedule and #pl.schedule.records or 0 end
  sch.go_to_station=function(i)
    calls=calls+1; wait_progress=0
    if not opts.reject_current then pl.schedule.current=i end
    if not opts.reject_unpause then pl.paused=false end
    if not opts.stuck then pl.state=pl.space_connection and S.on_the_path or S.waiting_at_station end
  end
  pl.get_schedule=function() return sch end
  local force={name='player',platforms={pl}}
  pl.force=force; game.forces={player=force}
  local p={index=1,name='astra',force=force}; local tells={}
  local space=require('space'){state=function() return st end,
    integer=function(v,d,lo,hi,label) v=v==nil and d or v; assert(type(v)=='number' and v%1==0 and v>=lo and v<=hi,label..' out of range'); return v end,
    deliver=function(_,t) tells[#tells+1]=t end}
  local tails=0
  local base={state=function() return st end,player=function() return p end,
    handlers={platform_schedule=space.platform_schedule,configure=function() tails=tails+1; return {} end},
    busy=function() return false end,stop=function() end,stop_index=function() end,
    validate_condition=function() end,condition=function() return true,'recovery triggered' end,recheck_read=space.recheck_read}
  local factory=require('scheduler')
  local q=require('queue_lanes'){scheduler=factory(base),factory=factory,base=base,is_read=function() return false end}
  local f={pl=pl,space=space,p=p,q=q,tells=tells,records=records}
  function f.counts() return calls,wait_progress,tails end
  function f.tick(n) for _=1,n or 1 do game.tick=game.tick+1; q.tick() end end
  function f.submit(lane,args,guard)
    local steps={{action='platform_schedule',args=args},{action='configure',args={platform='Asterion'}}}
    local a={lane=lane,steps=steps}
    if guard then a.steps={{action='wait_ticks',args={ticks=100}}}; a.guards={{when={['until']='tick_at_least',tick=game.tick},steps=steps}} end
    q.handlers.queue_submit(p,a)
  end
  function f.status(lane) return q.handlers.queue_status(p,{lane=lane,history='all'}) end
  return f
end
local function args(current) return {platform='Asterion',current=current or 2} end
-- Direct calls: outbound/inbound no-ops preserve records, distance and wait timer.
for _,cur in ipairs{1,2} do
  local f=fixture{current=cur}; local a=args(cur)
  eq(f.space.schedule_check(f.p,a).refused,nil)
  local r=f.space.platform_schedule(f.p,a)
  eq(r.changed,false); eq(r.current,cur); eq(r.paused,false); eq(r.paused_before,false)
  eq(r.heading_to,cur==1 and 'nauvis' or 'gleba')
  eq(r.direction.from,cur==1 and 'gleba' or 'nauvis'); eq(r.direction.to,r.heading_to)
  eq(r.progress,cur==1 and 0.625 or 0.375); eq(r.distance,0.375)
  eq(f.pl.schedule.records,f.records); eq(r.recheck,nil); eq(r.sent_to,nil)
  local calls,progress=f.counts(); eq(calls,0); eq(progress,245)
end
local f=fixture{docked=true,state=S.waiting_at_station}
local r=f.space.platform_schedule(f.p,args()); eq(r.changed,false); eq(r.direction,nil)
local calls,progress=f.counts(); eq(calls,0); eq(progress,245)
-- Paused same-current and explicit unpause call the game, which also unpauses current alone.
for _,explicit in ipairs{false,true} do
  f=fixture{paused=true,state=S.paused}; local a=args(); if explicit then a.paused=false end
  r=f.space.platform_schedule(f.p,a)
  eq(r.changed,true); eq(r.paused_before,true); eq(r.paused,false); eq(r.current,2); eq(r.distance,0.375)
  eq(f.counts(),1); eq(r.direction.to,'gleba')
end
f=fixture(); r=f.space.platform_schedule(f.p,args(1))
eq(r.changed,true); eq(r.current,1); eq(r.direction.to,'nauvis'); eq(r.progress,0.625); eq(r.distance,0.375)
f=fixture{reject_current=true}; fails(function() f.space.platform_schedule(f.p,args(1)) end,'did not select current')
f=fixture{paused=true,state=S.paused,reject_unpause=true}; fails(function() f.space.platform_schedule(f.p,args()) end,'still reads paused')
-- Immediate failures still refuse before go-to.
for _,case in ipairs{
  {{},{platform='Missing',current=2},'no platform named'},{{},args(3),'current out of range'},{{},args(0),'current out of range'},
  {{empty=true},args(),'has no schedule'},{{},{platform='Asterion',current=2,paused='false'},'paused must be boolean'},
} do
  f=fixture(case[1]); fails(function() f.space.platform_schedule(f.p,case[2]) end,case[3]); eq(f.counts(),0)
end
-- Persistent no_path and genuine no_schedule keep delayed direct failure/tell.
for _,state in ipairs{S.no_path,S.no_schedule} do
  f=fixture{state=state,stuck=true}; r=f.space.platform_schedule(f.p,args()); assert(r.recheck); eq(f.counts(),1)
  game.tick=r.recheck.ends_tick; eq(f.space.recheck_read(r.recheck).ok,false)
  f.space.recheck_tick(); eq(#f.tells,1); has(f.tells[1].text,'call failed')
end
-- Real space handler through every scheduler lane: recovery tails run without manual resume.
for _,lane in ipairs{'body','remote','platform:Asterion'} do
  for _,case in ipairs{{current=2},{current=1},{current=2,paused=true,state=S.paused},{current=2,docked=true,state=S.waiting_at_station}} do
    f=fixture(case); f.submit(lane,args(case.current)); f.tick(15)
    local q=f.status(lane); eq(q.paused,false); eq(q.active,false); eq(q.pending_count,0)
    local _,_,tails=f.counts(); eq(tails,1)
    eq(q.history[1].ok,true); eq(q.history[1].result.current,case.current); eq(q.history[1].result.changed,case.paused==true)
  end
  f=fixture(); f.submit(lane,args(1)); f.tick(15)
  eq(f.status(lane).history[1].result.direction.to,'nauvis'); eq(f.counts(),1)
  f.submit(lane,args(1),true); f.tick(20)
  eq(f.status(lane).paused,false); local n,_,tails=f.counts(); eq(n,1); eq(tails,2)
  -- Errors pause the remaining recovery step under default on_fail (no skip).
  for _,case in ipairs{{{},{platform='Missing',current=2}},{{},args(3)},{{empty=true},args()}} do
    f=fixture(case[1]); f.submit(lane,case[2]); f.tick(15)
    local q=f.status(lane); eq(q.paused,true); eq(q.pending_count,1); eq(q.last_failure.action,'platform_schedule')
    local _,_,tails=f.counts(); eq(tails,0)
  end
  for _,state in ipairs{S.no_path,S.no_schedule} do
    f=fixture{state=state,stuck=true}; f.submit(lane,args()); f.tick(20)
    local q=f.status(lane); eq(q.active.action,'platform_schedule'); eq(q.pending_count,1)
    f.tick(310); q=f.status(lane)
    eq(q.paused,true); eq(q.pending_count,1); eq(q.last_failure.action,'platform_schedule')
    has(q.last_failure.result.reason,'call failed'); local _,_,tails=f.counts(); eq(tails,0)
  end
end
print('batch433: current idempotence, pause/current verification, direction/progress, direct failures and all queue lanes: ok')
