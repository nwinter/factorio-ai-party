-- Run from repository root: lua tests/d28_batch316.lua
-- d28 batch316 SW (Sol #2703: Resolute's adaptive pilot runs a 10-tick clock C and pulses its pumps 1 or 2 ticks a
-- period; signal_watch samples every 60 ticks, the same phase each time, so the pumps' true enabled share and a missing
-- clock could not be seen). signal_watch {entities, seconds}: a duty watch reads each entity's status every tick.
-- A 10-tick clock, a pump on C < 1 (1 tick of 10) and one on C < 2 (2 of 10), each enabled the tick after its
-- condition is met (as on the iMac copy of world n); the clock stops for 100 ticks in the middle.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
defines={wire_connector_id={circuit_red=1,circuit_green=2},entity_status={working=1,disabled_by_control_behavior=55,no_input_fluid=33}}
prototypes={item={},fluid={},virtual_signal={['signal-C']=true},recipe={},entity={},quality={normal={level=0}}}
local Ci=dofile('mod/agent-harness_0.1.0/circuits.lua'){}
game={tick=100000,surfaces={}}
local surface={valid=true,index=22,name='platform-22',platform={name='Resolute'}}
game.surfaces[22]=surface
-- the clock: C = tick % 10, except from STOP to STOP+99 it stays at 5
local STOP=100000+1200
local function C(t) if t>=STOP and t<STOP+100 then return 5 end return t%10 end
local reads=0
local function pump(x,below)
  local e={valid=true,name='pump',type='pump',position={x=x,y=160},surface=surface,unit_number=1000+x}
  setmetatable(e,{__index=function(_,k) if k=='status' then reads=reads+1
    return C(game.tick-1)<below and defines.entity_status.working or defines.entity_status.disabled_by_control_behavior end end})
  return e
end
local p1,p2=pump(-14.5,1),pump(14.5,2)
local clock_net={network_id=2140,get_signal=function(sig) return C(game.tick) end}
local decider={valid=true,name='medium-electric-pole',type='electric-pole',position={x=-16.5,y=167},surface=surface,
  get_circuit_network=function(id) if id==2 then return clock_net end end}
local wall={valid=true,name='stone-wall',type='wall',position={x=0.5,y=0.5},surface=surface}
local S={}
local W=dofile('mod/agent-harness_0.1.0/signalwatch.lua'){state=function() return S end,reason=function(v) return v end,
  on_platform=function(p,name) eq(name,'Resolute'); return p end,on_surface=function(p) return p end,
  remote_entity=function(q,a) local x=a.position.x or a.position[1]
    if x==-14.5 then return p1 elseif x==14.5 then return p2 elseif x==-16.5 then return decider elseif x==0.5 then return wall end
    error('no entity of ours there') end,
  parse_signals=Ci.parse_signals}
local p={index=4}
local function run(to) while game.tick<to do game.tick=game.tick+1; W.tick(game.tick) end end

-- the default watch is unchanged: a sample every 60 ticks, and on this clock every sample reads the same C (aliasing)
local r=W.handler(p,{position={x=-16.5,y=167},platform='Resolute',wire='green',signals='signal-C',seconds=10})
eq(r.every_ticks,60)
run(100000+600)
r=W.handler(p,{})
eq(r.done,true); eq(r.samples,11); eq(r.every_ticks,60)
eq(r.signals[1].min.count,0); eq(r.signals[1].max.count,0)  -- C is 0 at every 60th tick: 10% and 20% duty never seen

-- bounds
fails(function() W.handler(p,{entities={{x=-14.5,y=160}},platform='Resolute',seconds=61}) end,'seconds: 10..60 with entities')
fails(function() W.handler(p,{entities={{x=-14.5,y=160}},platform='Resolute',seconds=9}) end,'seconds: 10..60 with entities')
fails(function() W.handler(p,{entities={},platform='Resolute',seconds=30}) end,'entities: 1..8')
local nine={} for k=1,9 do nine[k]={x=-14.5,y=160} end
fails(function() W.handler(p,{entities=nine,platform='Resolute',seconds=30}) end,'entities: 1..8')
fails(function() W.handler(p,{entities={{x=-14.5,y=160},{x=-14.5,y=160}},platform='Resolute',seconds=30}) end,'is named twice')
fails(function() W.handler(p,{entities={{x=-14.5,y=160}},position={x=1,y=1},wire='green',seconds=30}) end,'position, wire, side and signals go with a signal watch')

-- the duty watch: 30 s of both pumps and a wall (no status), a status read per entity every tick, nothing else
game.tick=100000
reads=0
local s=W.handler(p,{entities={{x=-14.5,y=160},{x=14.5,y=160},{x=0.5,y=0.5}},platform='Resolute',seconds=30,reason='duty check'})
eq(s.duty,true); eq(s.every_ticks,1); eq(s.start_tick,100000); eq(s.end_tick,100000+1799)
has(s.replaced,'your earlier signal watch'); has(s.line,'for 30 s (1800 ticks, to tick 101799)')
eq(reads,2,'the first tick read at the start')
run(100000+600)
eq(reads,2*601,'one status read per entity a tick')
local mid=W.handler(p,{})
eq(mid.watching,true); eq(mid.entities[1].ticks,601)
run(100000+1799)
local d=W.handler(p,{})
eq(d.done,true); eq(d.samples,1800); eq(S.signal_watch[4].ents[1].e,nil,"entity refs let go")
local before=reads; run(100000+1900); eq(reads,before,'never read again once done')
local a,b,w=d.entities[1],d.entities[2],d.entities[3]
-- 1800 ticks, 100 of them with the clock stopped at 5 (both pumps disabled then): 170 periods of 10
eq(a.ticks,1800); eq(a.enabled_ticks,170); eq(a.enabled_share,0.0944)
eq(b.enabled_ticks,340); eq(b.status.working,340); eq(b.status.disabled_by_control_behavior,1460)
-- runs: pump 1 enabled 1 tick each time, disabled 9 between, and 109 across the stop; enabled again after 10, and 110
eq(#a.enabled_runs,1); eq(a.enabled_runs[1].ticks,1); eq(a.enabled_runs[1].count,170)
eq(a.disabled_runs[1].ticks,9); eq(a.disabled_runs[1].count,168); eq(a.disabled_runs[2].ticks,109); eq(a.disabled_runs[2].count,1)
eq(a.longest_disabled.ticks,109); eq(a.longest_disabled.from_tick,STOP-8)
eq(a.enable_every[1].ticks,10); eq(a.enable_every[2].ticks,110); eq(a.enable_every[2].count,1)
eq(b.enabled_runs[1].ticks,2); eq(b.disabled_runs[1].ticks,8); eq(b.disabled_runs[2].ticks,108)
-- 60-tick windows: 6 enabled ticks a window for pump 1, none in the window the stop covers whole
eq(a.windows.count,30); eq(a.windows.max.enabled_ticks,6); eq(a.windows.min.enabled_ticks,0); eq(a.windows.min.from_tick,STOP)
eq(a.transitions,340)  -- 170 enables and 170 disables
eq(#a.first_transitions,8); eq(a.first_transitions[1].to,'enabled'); eq(a.first_transitions[1].tick,100001)
eq(#a.last_transitions,8); eq(a.last_transitions[8].tick,100000+1792)
eq(a.open_start.enabled,false); eq(a.open_start.ticks,1); eq(a.open_end.enabled,false)
-- the wall has no status: enabled the whole window, no transition
eq(w.status.none,1800); eq(w.transitions,0); eq(w.open_start.whole_window,true); eq(w.open_end,nil)
has(a.line,'pump (-14.5,160): enabled 170 of 1800 ticks (9.4%); enabled runs (ticks x times) 1 x170; disabled runs 9 x168, 109 x1; enabled again after 10 x168, 110 x1')
has(a.line,'per 60-tick window 0-6 enabled ticks (least from tick '..STOP..'')
has(d.line,'every tick from tick 100000 to tick 101799 (1800 ticks)')
has(d.note,'a circuit condition takes effect on the tick after it is met')

-- capped histograms: a pump enabled for 1, 2, 3, ... ticks keeps 24 lengths, the rest counted together
game.tick=200000
local len_on=0
local q=pump(-14.5,1)
local k,left=1,1
setmetatable(q,{__index=function(_,key) if key=='status' then
  if left>0 then left=left-1; return defines.entity_status.working end
  k=k+1; left=k; return defines.entity_status.disabled_by_control_behavior end end})
p1=q
W.handler(p,{entities={{x=-14.5,y=160}},platform='Resolute',seconds=60})
run(200000+3599)
local c=W.handler(p,{}).entities[1]
eq(#c.enabled_runs,24); eq(c.enabled_runs_other.count>0,true); eq(c.enabled_runs_other.min,26)

-- an entity gone mid-watch: its gone_tick; all gone ends the watch there
game.tick=300000
p1=pump(-14.5,1)
W.handler(p,{entities={{x=-14.5,y=160}},platform='Resolute',seconds=20})
run(300000+100)
p1.valid=false
run(300000+101)
local g=W.handler(p,{})
eq(g.done,true); eq(g.ended.tick,300101); eq(g.entities[1].gone_tick,300101); eq(g.entities[1].ticks,101)
print('d28_batch316 duty watch: per-tick status, runs, windows, transitions, bounds, default unchanged: ok')
