-- Run from repository root: lua tests/d24_batch138.lua
-- d24 batch138 PJ1 (Sol #2111: Petrel's lane, revision 452, was empty and not paused; queue_submit mode=replace
-- start:false queued revision 453, and its platform_schedule and the arrival wait after it ran without queue_resume):
-- start:false stages the steps: the lane is paused and held in the same call, whatever its state was, on every lane and
-- in every mode; nothing it submitted runs until queue_resume; a direct call ending does not resume it; the reply says
-- the lane's state. A queue started (start omitted or true) runs as before.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
game={tick=0}
local s={active={}}
local p={index=1}
local arrived=false
local calls={}
local function count(name) local n=0; for _,c in ipairs(calls) do if c==name then n=n+1 end end; return n end
local handlers={
  walk=function() s.active[1]={kind='walk'} end,
  transfer=function() calls[#calls+1]='transfer' end,
  platform_schedule=function(_,a) calls[#calls+1]='schedule'; return {paused=a.paused} end,
  circuit_set=function() calls[#calls+1]='circuit' end,
  platforms=function() calls[#calls+1]='read'; return {platforms={}} end,
}
local base={state=function() return s end,player=function() return p end,handlers=handlers,
  busy=function(_,action) return action=='walk' and s.active[1]~=nil end,
  stop=function() s.active[1]=nil end,stop_index=function() s.active[1]=nil end,
  claim=function() if s.active[1] then s.active[1].queued=true end end,
  direct_action=function() return s.active[1] and not s.active[1].queued and 'walk' end,
  condition=function() return arrived,'arrival' end,validate_condition=function(c) assert(c['until']) end,
  outcome=function() return 'done' end}
local make=require('scheduler')
local body_api={}; for k,v in pairs(base) do body_api[k]=v end
local body=make(body_api)
local q=require('queue_lanes'){scheduler=body,factory=make,base=base,is_read=function(name) return name=='platforms' end}
local h=q.handlers
local function tick(n) for _=1,n or 1 do game.tick=game.tick+1; q.tick() end end
local PETREL='platform:Petrel'
local function st(lane) return h.queue_status(p,{lane=lane,history='all'}) end

-- Petrel's lane: a read runs and ends, so the lane is empty and not paused (Sol's revision 452)
h.queue_submit(p,{lane=PETREL,steps={{action='platforms'}}}); tick(3)
local before=st(PETREL)
eq(before.paused,false); eq(before.active,false); eq(before.pending_count,0); eq(count('read'),1)
-- Sol's revision 453: replace, start:false, a mutating first step and the arrival wait
local r=h.queue_submit(p,{lane=PETREL,mode='replace',start=false,steps={
  {action='platform_schedule',args={platform='Petrel',paused=false}},
  {action='wait_until',args={['until']='platform_arrived',platform='Petrel',timeout=600}}}})
eq(r.state,'paused, held until queue_resume'); eq(r.paused,true); eq(r.lane,PETREL)
has(r.staged,'start: false: the lane is paused and held until queue_resume (it was not paused); 2 steps pending')
tick(30)
eq(count('schedule'),0,'platform_schedule ran without queue_resume')
local now=st(PETREL)
eq(now.paused,true); eq(now.pending_count,2); eq(now.active,false); eq(now.lanes.platforms.Petrel.held,true)
has(now.lanes.platforms.Petrel.paused_by,'staged by queue_submit start: false')
-- queue_resume runs them, in order
h.queue_resume(p,{lane=PETREL}); tick(3)
eq(count('schedule'),1); eq(st(PETREL).active.action,'wait_until')
arrived=true; tick(120); eq(st(PETREL).active,false); arrived=false

-- the body lane: a direct call that paused the queue and ends (resume_direct) does not resume a staged one
h.queue_submit(p,{steps={{action='transfer'}}}); tick(3); eq(count('transfer'),1); eq(st().paused,false)
r=h.queue_submit(p,{start=false,steps={{action='transfer'}}})
eq(r.state,'paused, held until queue_resume'); has(r.staged,'(it was not paused)')
eq(body.resume_direct(1),false); tick(10); eq(count('transfer'),1)
h.queue_resume(p,{}); tick(3); eq(count('transfer'),2)

-- every mode: append, next and pending onto a running lane stop and requeue its active step and hold it
for _,mode in ipairs({'append','next','pending'}) do
  h.queue_submit(p,{lane='remote',mode='replace',steps={{action='wait_until',args={['until']='researched',technology='x',timeout=600}}}})
  tick(2); eq(st('remote').active.action,'wait_until')
  local n=count('circuit')
  r=h.queue_submit(p,{lane='remote',mode=mode,start=false,steps={{action='circuit_set',args={platform='Petrel'}}}})
  eq(r.state,'paused, held until queue_resume',mode)
  has(r.staged,'(it was not paused; ')
  has(r.staged,'wait_until stopped and requeued at the head')
  tick(20)
  local now2=st('remote')
  eq(now2.active,false,mode); eq(count('circuit'),n,mode..': circuit_set ran without queue_resume')
  eq(now2.pending_count,2,mode)
end
-- ahead (it pauses itself) and a lane already paused by queue_pause: staged and held the same way
r=h.queue_submit(p,{lane='remote',mode='replace',steps={{action='wait_ticks',args={ticks=600}}}}); tick(2)
r=h.queue_submit(p,{lane='remote',mode='ahead',start=false,steps={{action='circuit_set',args={platform='Petrel'}}}})
eq(r.state,'paused, held until queue_resume'); tick(10); eq(st('remote').active,false)
h.queue_pause(p,{lane='remote'})
r=h.queue_submit(p,{lane='remote',start=false,steps={{action='platforms'}}})
has(r.staged,'(it was paused)'); eq(r.state,'paused, held until queue_resume')

-- started as before: start omitted runs at once, and the reply says running
local n=count('read')
r=h.queue_submit(p,{lane=PETREL,mode='replace',steps={{action='platforms'}}})
eq(r.state,'running'); eq(r.staged,nil); tick(2); eq(count('read'),n+1)
fails(function() h.queue_submit(p,{lane=PETREL,start='no',steps={}}) end,'start must be true or false')
print('d24 batch138: ok (start:false stages: the lane paused and held in the same call on every lane and mode; queue_resume runs it)')
