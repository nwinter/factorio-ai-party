-- batch361: one 80-hour wait, the ordinary check cadence and guards, shared dry/live bounds.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b) assert(a==b,tostring(a)..' ~= '..tostring(b)) end
local function fails(fn,text)
  local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err))
end
game={tick=100,tick_paused=false,connected_players={}}
prototypes={space_location={nauvis={},gleba={}}}
local wall=1800000000000
local state={active={}}
local ship={valid=true,name='Sunward',space_location={name='nauvis'}}
local p={index=1,force={platforms={ship},technologies={automation={researched=false}}}}
local observations,reactions=0,0
local leg={from='nauvis',to='gleba',flown=0.25,length=15000}
local C=require('conditions'){leg=function() return leg end}
local W=require('waiteta'){check=function(p,c,record)
  observations=observations+1; return C.check(p,c,true,record)
end}
local base={state=function() return state end,wall=function() return wall end,
  player=function() return p end,player_check=function() return true end,
  handlers={platform_schedule=function() reactions=reactions+1 end},
  busy=function() return false end,stop=function() end,stop_index=function() end,
  condition=C.check,validate_condition=C.validate,deadline=C.deadline,wait_check=W.check,wait_info=W.info,extend_wait=W.extend}
local make=require('scheduler')
local Q=require('queue_lanes'){scheduler=make(base),base=base,factory=make,is_read=function() return false end}
local H=Q.handlers
local function tick(n) for _=1,n or 1 do game.tick=game.tick+1; Q.tick() end end
local function args(lane,kind,timeout)
  local c={['until']=kind,timeout=timeout}
  if kind=='researched' then c.technology='automation'
  elseif kind=='all' or kind=='any' then c.conditions={{['until']='platform_arrived',platform='Sunward',location='gleba'}}
  else c.platform='Sunward'; if kind=='platform_progress' then c.at_least=1 else c.location='gleba' end end
  return {lane=lane,mode='replace',steps={{action='wait_until',args=c}}}
end
local lane='platform:Sunward'
-- Bounds in every lane, dry submission, live submission and saved-plan validation. A platform argument in a body
-- or remote lane is insufficient; wrapping the condition in all/any does not widen the timeout.
for _,which in ipairs{'body','remote',lane} do
  for _,kind in ipairs{'platform_arrived','platform_progress','platform_left','researched','all','any'} do
    local cap=which==lane and (kind=='platform_arrived' or kind=='platform_progress') and 17280000 or 54000
    for _,value in ipairs{0,1,54000,54001,17280000,17280001,1.5,'17280000'} do
      for _,dry in ipairs{true,false} do
        local a=args(which,kind,value); a.dry_run=dry
        if type(value)=='number' and value==math.floor(value) and value>=1 and value<=cap then
          local out=H.queue_submit(p,a)
          if dry then eq(out.queued,false) end
          Q.validate(a)
        else
          fails(function() H.queue_submit(p,a) end,'timeout must be 1..'..cap)
          fails(function() Q.validate(a) end,'timeout must be 1..'..cap)
        end
      end
    end
    H.queue_cancel(p,{lane=which})
  end
  -- wait_ticks and the pending-step/storage/guard bounds stay independent of timeout length.
  for _,dry in ipairs{true,false} do
    for _,n in ipairs{1,54000,54001} do
      local a={lane=which,mode='replace',dry_run=dry,steps={{action='wait_ticks',args={ticks=n}}}}
      if n<=54000 then H.queue_submit(p,a) else fails(function() H.queue_submit(p,a) end,'1..54000') end
    end
    local a={lane=which,mode='replace',dry_run=dry,steps={}}
    for i=1,128 do a.steps[i]={action='wait_ticks',args={ticks=1}} end
    H.queue_submit(p,a)
    a.steps[129]={action='wait_ticks',args={ticks=1}}
    fails(function() H.queue_submit(p,a) end,'at most 128')
    a.steps={{action='wait_ticks',args={ticks=1}}}; a.guards={}
    for i=1,8 do a.guards[i]={when={['until']='researched',technology='automation'},steps={{action='wait_ticks',args={ticks=1}}}} end
    H.queue_submit(p,a)
    a.guards[9]=a.guards[1]
    fails(function() H.queue_submit(p,a) end,'at most 8')
  end
  H.queue_cancel(p,{lane=which})
  for _,dry in ipairs{true,false} do
    -- Named condition bounds are independent too (TICK_AHEAD, not just literal limits).
    local a={lane=which,mode='replace',dry_run=dry,steps={{action='wait_until',args={['until']='tick_at_least',tick=game.tick+C.TICK_AHEAD}}}}
    H.queue_submit(p,a)
    a.steps[1].args.tick=a.steps[1].args.tick+1
    fails(function() H.queue_submit(p,a) end,'at most '..C.TICK_AHEAD)
    a=args(which,'platform_progress',54000); a.dry_run=dry
    H.queue_submit(p,a)
    a.steps[1].args.at_least=1.001
    fails(function() H.queue_submit(p,a) end,'up to 1')
  end
  H.queue_cancel(p,{lane=which})
end
local a=args(lane,'platform_arrived',17280000)
a.dry_run=true
local projected=H.queue_submit(p,a).wait_deadlines[1]
eq(projected.state,'if_started_now'); eq(projected.tick,game.tick+17280000)
eq(projected.wall_unix_ms,wall+288000000)
a.dry_run=false
local out=H.queue_submit(p,a)
eq(out.wait_deadlines[1].state,'if_started_now')
tick(); local started=game.tick
out=H.queue_status(p,{lane=lane})
eq(out.waiting.until_tick,started+17280000)
eq(out.waiting.deadline.tick,out.waiting.until_tick)
eq(out.wait_deadlines[1].state,'waiting'); eq(out.wait_deadlines[1].wall_unix_ms,wall+288000000)
eq(out.lanes.platforms.Sunward.waiting.deadline.tick,out.waiting.until_tick)
local n=observations
tick(); eq(observations,n+1); tick(9); eq(observations,n+1); tick(); eq(observations,n+2)
-- Status and wall projections read no conditions, keep the game deadline, and refresh when wall time moved.
wall=wall+5000
out=H.queue_status(p,{lane=lane}); eq(observations,n+2)
eq(out.wait_deadlines[1].tick,started+17280000)
eq(out.wait_deadlines[1].wall_unix_ms,wall+(17280000-11)*1000/60)
wall=nil; eq(H.queue_status(p,{lane=lane}).wait_deadlines[1].wall_unix_ms,nil); wall=1800000000000
-- It remains one record past the old timeout and expires at the new deadline's ordinary check.
game.tick=started+54000; tick(); eq(H.queue_status(p,{lane=lane}).active.action,'wait_until')
game.tick=started+17280000-1; tick(10)
eq(H.queue_status(p,{lane=lane}).last_failure.result.outcome,'timed_out')
-- An emergency/deadline guard still interrupts the long wait and executes its reaction on the due tick.
a=args(lane,'platform_arrived',17280000)
a.guards={{when={['until']='tick_at_least',tick=game.tick+20},steps={{action='platform_schedule',args={platform='Sunward'}}}}}
H.queue_submit(p,a); tick(19); eq(reactions,0)
tick(); eq(reactions,1); eq(H.queue_status(p,{lane=lane}).active,false)
local guard_seen=false
for _,e in ipairs(H.queue_status(p,{lane=lane,history='all'}).history) do if e.action=='guard' then guard_seen=true end end
assert(guard_seen)
-- A non-deadline emergency predicate interrupts on the ordinary 10-tick guard check too.
a=args(lane,'platform_arrived',17280000)
a.guards={{when={['until']='platform_progress',platform='Sunward',at_least=0.5},steps={{action='platform_schedule',args={platform='Sunward'}}}}}
H.queue_submit(p,a); tick(); leg.flown=0.75; tick(10)
eq(reactions,2); eq(H.queue_status(p,{lane=lane}).active,false); leg.flown=0.25
-- The same validator covers waits inside guard reactions, edits and repeating plans.
for _,which in ipairs{'body','remote',lane} do
  local cap=which==lane and 17280000 or 54000
  for _,dry in ipairs{true,false} do
    local a={lane=which,mode='replace',dry_run=dry,steps={},guards={{scope='standing',when={['until']='researched',technology='automation'},steps=args(which,'platform_arrived',cap).steps}}}
    H.queue_submit(p,a)
    a.guards[1].steps[1].args.timeout=cap+1
    fails(function() H.queue_submit(p,a) end,'guards[1]: steps[1]')
  end
  H.queue_repeat(p,args(which,'platform_arrived',cap))
  fails(function() H.queue_repeat(p,args(which,'platform_arrived',cap+1)) end,'timeout must be 1..'..cap)
  H.queue_cancel(p,{lane=which})
  local a=args(which,'platform_arrived',cap); a.index=1; a.expected_revision=H.queue_status(p,{lane=which}).revision
  H.queue_edit(p,a)
  a.expected_revision=H.queue_status(p,{lane=which}).revision
  a.steps[1].args.timeout=cap+1
  fails(function() H.queue_edit(p,a) end,'timeout must be 1..'..cap)
  H.queue_cancel(p,{lane=which})
end
-- Conditions can meet at their next ordinary check, long before the timeout.
for _,kind in ipairs{'platform_arrived','platform_progress'} do
  a=args(lane,kind,17280000); H.queue_submit(p,a); tick()
  ship.space_location={name='gleba'}; leg.flown=1
  tick(); eq(H.queue_status(p,{lane=lane}).active,false)
  ship.space_location={name='nauvis'}; leg.flown=0.25
end
-- Default timeout and realtime clock behavior stay unchanged.
a=args(lane,'platform_progress'); H.queue_submit(p,a); tick()
eq(H.queue_status(p,{lane=lane}).waiting.until_tick,game.tick+3600)
local clock=require('clock'){state=function() return state end}
clock.after_dispatch(); clock.tick(); eq(clock.report().mode,'realtime'); eq(game.tick_paused,false)
print('long platform waits: dry/live/validate bounds, deadlines, cadence, expiry, guards and realtime ok')
