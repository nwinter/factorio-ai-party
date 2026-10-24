-- Run from repository root: lua tests/d24_batch140.lua
-- d24 batch140 PL1 (Sol #2116: Petrel's zero-hub trial needed the calcite minimum on belt (-13.5,4.5)'s green network
-- 815 through flight and coasting): signal_watch samples named signals on one network every 60 ticks, one get_signal
-- per signal, and keeps start, end, min and max with ticks, gaps and where the platform was.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
defines={wire_type={red=1,green=2,copper=3},
  wire_connector_id={circuit_red=1,circuit_green=2,combinator_input_red=1,combinator_input_green=2,combinator_output_red=3,combinator_output_green=4},
  space_platform_state={on_the_path=5,waiting_at_station=3}}
prototypes={item={calcite=true,['iron-plate']=true},fluid={},virtual_signal={['signal-R']=true},recipe={},entity={},quality={normal={level=0}}}
local C=dofile('mod/agent-harness_0.1.0/circuits.lua'){}
local gets=0
local counts={calcite=120,['signal-R']=4}
local function net(id) return {network_id=id,get_signal=function(sig) gets=gets+1; return counts[sig.name] or 0 end} end
local green=net(815)
local pl={name='Petrel',speed=0.5,space_connection={from={name='nauvis'},to={name='gleba'}}}
local surface={valid=true,index=7,name='platform-7',platform=pl}
local belt={valid=true,name='transport-belt',type='transport-belt',position={x=-13.5,y=4.5},surface=surface,
  get_circuit_network=function(id) if id==2 then return green end end}
local decider={valid=true,name='decider-combinator',type='decider-combinator',position={x=1.5,y=1},surface=surface,
  get_circuit_network=function(id) if id==3 then return net(9) end end}
game={tick=1000,surfaces={[7]=surface}}
local S={}
local W=dofile('mod/agent-harness_0.1.0/signalwatch.lua'){state=function() return S end,reason=function(v) return v end,
  on_platform=function(p,name) eq(name,'Petrel'); return p end,on_surface=function(p) return p end,
  remote_entity=function(q,a) if a.position.x==-13.5 then return belt end; if a.position.x==1.5 then return decider end; error('no entity of ours there') end,
  parse_signals=C.parse_signals}
local p={index=3}
-- refusals
fails(function() W.handler(p,{}) end,'no signal watch of yours yet')
fails(function() W.handler(p,{position={-13.5,4.5},platform='Petrel',wire='green',signals='calcite',seconds=5}) end,'seconds: 10..3600')
fails(function() W.handler(p,{position={x=-13.5,y=4.5},platform='Petrel',wire='blue',signals='calcite',seconds=60}) end,'wire: red or green')
fails(function() W.handler(p,{position={x=-13.5,y=4.5},platform='Petrel',wire='red',signals='calcite',seconds=60}) end,'no red network on that wire')
fails(function() W.handler(p,{position={x=-13.5,y=4.5},platform='Petrel',wire='green',side='input',signals='calcite',seconds=60}) end,'side: only for a combinator')
fails(function() W.handler(p,{position={x=1.5,y=1},platform='Petrel',wire='red',signals='calcite',seconds=60}) end,'side: input or output')
fails(function() W.handler(p,{position={x=-13.5,y=4.5},platform='Petrel',wire='green',signals={'calcite','signal-R','iron-plate','calcite','calcite','calcite','calcite','calcite','calcite'},seconds=60}) end,'signals: 1..8 names')
fails(function() W.handler(p,{position={x=-13.5,y=4.5},platform='Petrel',wire='green',signals='nothing-here',seconds=60}) end,'unknown signal')
-- a decider's output side
local d=W.handler(p,{position={x=1.5,y=1},platform='Petrel',wire='red',side='output',signals='signal-R',seconds=10})
eq(d.network_id,9); eq(W.handler(p,{}).wire,'red_output')
-- the start: a sample now, replacing the decider's watch
gets=0
local r=W.handler(p,{position={x=-13.5,y=4.5},platform='Petrel',wire='green',signals='calcite|signal-R',seconds=60,reason='reserve floor'})
eq(gets,2,'one get_signal per signal'); eq(r.network_id,815); eq(r.watching,true); eq(r.now,'calcite 120, signal-R 4')
has(r.replaced,'your earlier signal watch (signal-R on the red_output network #9'); has(r.replaced,'still running')
has(r.line,'watching calcite, signal-R on the green network #815 of transport-belt (-13.5,4.5) on Petrel for 60 s')
has(r.line,'until tick 4600: signal_watch {} reads it so far, and in full once done; now calcite 120, signal-R 4')
eq(W.handler(p,{}).signals[1].min.where,'flying nauvis-gleba, 30 km/s')
-- samples every 60 ticks: nothing between
gets=0
for t=1001,1059 do game.tick=t; W.tick(t) end
eq(gets,0,'nothing read between samples')
game.tick=1060; counts.calcite=80; pl.speed=0.2; W.tick(1060); eq(gets,2)
game.tick=1120; counts.calcite=150; W.tick(1120)
-- the wire cut for two samples, then joined to another network
belt.get_circuit_network=function() return nil end
gets=0
game.tick=1180; W.tick(1180); game.tick=1240; W.tick(1240)
eq(gets,0,'no network: nothing read')
belt.get_circuit_network=function(id) if id==2 then return net(902) end end
game.tick=1300; counts.calcite=100; W.tick(1300)
r=W.handler(p,{})
eq(r.samples,4); eq(r.missed,2)
local c=r.signals[1]
eq(c.start.count,120); eq(c.min.count,80); eq(c.min.tick,1060); eq(c.min.where,'flying nauvis-gleba, 12 km/s')
eq(c.max.count,150); eq(c.max.tick,1120); eq(c['end'].count,100); eq(c['end'].tick,1300)
eq(r.gaps[1].why,'no green network on that wire (wire cut, or no wire)'); eq(r.gaps[1].from_tick,1180); eq(r.gaps[1].to_tick,1300); eq(r.gaps[1].missed,2)
eq(r.gaps[2].why,'network changed: #815 to #902'); eq(r.network_id,902)
has(r.gap_lines[1],'ticks 1180-1300: no green network on that wire (wire cut, or no wire) (2 samples missed)')
-- the status row (measures.lua) while running
local Ms=dofile('mod/agent-harness_0.1.0/measures.lua'){state=function() return S end}
local rows=Ms.list(3,1310)
eq(rows[1].kind,'signal_watch'); eq(rows[1].state,'running'); eq(rows[1].id,'signal_watch@1000')
has(rows[1].line,'calcite 100 (min 80), signal-R 4 (min 4)'); has(rows[1].line,'your reason: reserve floor')
eq(Ms.running(3,1310),'signal_watch@1000')
-- the end tick: done, its final read once
for t=1301,4600 do game.tick=t; W.tick(t) end
local job=S.signal_watch[3]
assert(job.result and job.result.done,'done at its end tick'); eq(job.result['signals'][1]['end'].tick,4600); eq(job.e,nil)
eq(Ms.list(3,4610)[1].state,'done'); eq(Ms.list(3,4610)[1].final_read,false)
r=W.handler(p,{}); eq(r.done,true); eq(Ms.list(3,4610)[1].final_read,true)
-- the entity gone: the watch ends there
belt.valid=true; belt.get_circuit_network=function(id) if id==2 then return green end end
game.tick=5000; W.handler(p,{position={x=-13.5,y=4.5},platform='Petrel',wire='green',signals='calcite',seconds=600})
belt.valid=false
game.tick=5060; W.tick(5060)
r=S.signal_watch[3].result
eq(r.ended.tick,5060); eq(r.ended.why,'the entity is gone'); has(r.line,'tick 5060: the entity is gone; the watch ended there')
print('d24_batch140: ok')
