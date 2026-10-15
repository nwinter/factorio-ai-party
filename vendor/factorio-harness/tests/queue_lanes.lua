package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b) assert(a==b,tostring(a)..' ~= '..tostring(b)) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
game={tick=0}
local s={active={}}
local p={index=1}
local arrived=false
local calls={}
local handlers={
  walk=function() s.active[1]={kind='walk'} end,
  transfer=function() calls[#calls+1]='transfer' end,
  drop=function() calls[#calls+1]='drop'; s.drop=true; return {until_tick=game.tick+30} end,
  platform_schedule=function() calls[#calls+1]='schedule' end,
  circuit_set=function() calls[#calls+1]='circuit' end,
  platforms=function() calls[#calls+1]='read'; return {platforms={}} end,
  observe=function() return {} end,
  inspect=function() error('entity no longer visible') end,
}
local base={state=function() return s end,player=function(_,seated) eq(seated,true); return p end,handlers=handlers,
  busy=function(_,action) return action=='drop' and s.drop or action=='walk' and s.active[1]~=nil end,
  stop=function() s.active[1]=nil end,stop_index=function() s.active[1]=nil end,
  claim=function() if s.active[1] then s.active[1].queued=true end end,
  direct_action=function() return s.active[1] and not s.active[1].queued and 'walk' end,
  condition=function() return arrived,'arrival' end,validate_condition=function(c) assert(c['until']) end,
  outcome=function() return 'dropped' end}
-- Body callback still applies its own actor rules; the remote one requests seated access.
local make=require('scheduler')
local body_api={}; for k,v in pairs(base) do body_api[k]=v end
body_api.player=function() return p end
local body=make(body_api)
local q=require('queue_lanes'){scheduler=body,factory=make,base=base,is_read=function(name) return ({platforms=true,observe=true,inspect=true,inventory=true})[name] end}
local h=q.handlers
local function tick(n) for _=1,n or 1 do game.tick=game.tick+1; q.tick() end end
local function remote(a) a=a or {}; a.lane='remote'; return a end
local function status() return h.queue_status(p,remote{history='all'}) end
-- Astra's arrival / circuit / drop / schedule plan goes on through local work.
h.queue_submit(p,remote{steps={{action='wait_until',args={['until']='platform_arrived',platform='Sunward',timeout=200}},
  {action='circuit_set',args={platform='Sunward'}},{action='drop',args={platform='Sunward'}},
  {action='platform_schedule',args={platform='Sunward'}},{action='platforms'}}})
handlers.walk(); local walk=s.active[1]
tick(); eq(status().active.action,'wait_until'); eq(s.active[1],walk)
body.pause(1); handlers.transfer(); tick(15); eq(status().paused,false); eq(s.active[1],walk)
arrived=true; tick(10); eq(status().active.action,'drop'); eq(calls[3],'drop'); eq(s.active[1],walk); eq(walk.queued,nil)
s.drop=false; tick(); eq(calls[4],'schedule'); eq(calls[5],'read'); eq(status().active,false)
eq(#status().history,5); eq(status().lanes.body.paused,true); eq(status().lanes.remote.pending,0)
-- The body lane retains its wait-after-direct behavior and independent revision.
local revision=status().revision
h.queue_submit(p,{steps={{action='transfer'}}}); tick(); eq(h.queue_status(p,{}).after_direct,'walk')
eq(status().revision,revision)
-- Cancels, failures and guards on remote never stop or claim the body.
h.queue_submit(p,remote{steps={{action='wait_until',args={['until']='researched',technology='x',timeout=20}}}})
tick(); h.queue_cancel(p,remote{clear=false}); eq(s.active[1],walk); eq(status().paused,true)
h.queue_resume(p,remote{}); tick(12); eq(s.active[1],walk)
h.queue_submit(p,remote{steps={{action='inspect'},{action='platforms'}}}); tick()
eq(status().paused,true); eq(status().last_failure.action,'inspect'); eq(s.active[1],walk)
h.queue_cancel(p,remote{}); arrived=false
h.queue_submit(p,remote{steps={{action='wait_until',args={['until']='platform_arrived',platform='Sunward',timeout=20}}}})
tick(30); eq(status().last_failure.result.outcome,'timed_out'); eq(s.active[1],walk)
h.queue_cancel(p,remote{}); arrived=true
h.queue_submit(p,remote{steps={{action='wait_ticks',args={ticks=100}}},guards={{when={['until']='researched',technology='x'},steps={{action='platforms'}}}}})
tick(15); eq(status().active,false); eq(status().paused,false); eq(s.active[1],walk)
-- Whole-plan validation, with paths, including guards, edits and repeat conditions.
for _,action in ipairs{'walk','transfer','inventory','queue_submit'} do
  fails(function() h.queue_submit(p,remote{steps={{action='platforms'},{action=action}}}) end,'steps[2]')
end
fails(function() h.queue_submit(p,remote{steps={{action='observe'}}}) end,'steps[1]')
fails(function() h.queue_submit(p,remote{steps={{action='circuit_set'}}}) end,'requires platform')
fails(function() h.queue_submit(p,remote{steps={},guards={{when={['until']='researched'},steps={{action='walk'}}}}}) end,'guards[1]')
fails(function() h.queue_submit(p,remote{steps={},guards={{when={['until']='health_below',fraction=.5}}}}) end,'guards[1]')
fails(function() h.queue_repeat(p,remote{steps={{action='platforms'}},condition={['until']='health_below',fraction=.5}}) end,'condition')
fails(function() h.queue_edit(p,remote{expected_revision=status().revision,index=1,steps={{action='transfer'}}}) end,'steps[1]')
fails(function() h.queue_submit(p,{lane='space',steps={}}) end,'lane must be')
fails(function() h.queue_cancel(p,remote{expected_revision=-1}) end,'revision conflict')
-- Independent loop and bounded instant work; queued reads remain forbidden in the default lane.
fails(function() h.queue_submit(p,{steps={{action='platforms'}}}) end,'not queueable')
h.queue_repeat(p,remote{steps={{action='platforms'}},times=2,interval_ticks=60}); tick(65)
eq(status().loop_done.rounds,2); eq(s.active[1],walk)
local steps={}; for i=1,10 do steps[i]={action='platforms'} end
h.queue_submit(p,remote{steps=steps}); tick(); eq(status().pending_count,6)
q.pause_all(); eq(status().paused,true)
-- A competing drop occupies only the drop channel, never the body channel.
h.queue_cancel(p,remote{}); s.drop=true
h.queue_submit(p,remote{steps={{action='drop',args={platform='Sunward'}}}}); tick()
eq(status().after_direct,'drop'); eq(status().pending_count,1)
s.drop=false; tick(); eq(status().active.action,'drop'); eq(s.active[1],walk)
print('queue lanes: ok')
