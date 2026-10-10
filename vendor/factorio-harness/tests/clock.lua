-- Run from repository root: lua tests/clock.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
local p={index=1,valid=true,character={valid=true},crafting_queue_size=0}
game={tick=100,tick_paused=false,connected_players={p},get_player=function(i) if i==1 then return p end end}
local s={active={},combat={},queues={}}
local clock=dofile('mod/agent-harness_0.1.0/clock.lua'){state=function() return s end}
local function tick(n) for _=1,(n or 1) do game.tick=game.tick+1; clock.tick() end end
-- Realtime by default: the tick handler never pauses.
eq(clock.handlers.clock(p,{}).mode,'realtime')
tick(); eq(game.tick_paused,false)
fails(function() clock.handlers.clock(p,{mode='sideways'}) end,'realtime or turns')
-- Turns mode with nothing in progress pauses at once; status reports it.
local r=clock.handlers.clock(p,{mode='turns'})
eq(r.mode,'turns'); eq(r.paused,true); eq(r.busy,false); eq(game.tick_paused,true)
-- A timed action starting (after_dispatch) unpauses; finishing pauses again.
s.active[1]={kind='walk',until_tick=game.tick+10}
clock.after_dispatch(); eq(game.tick_paused,false)
tick(); eq(game.tick_paused,false)
s.active[1]=nil; tick(); eq(game.tick_paused,true)
-- Combat counts as work in progress.
s.combat[1]={}; clock.after_dispatch(); eq(game.tick_paused,false)
s.combat[1]=nil; tick(); eq(game.tick_paused,true)
-- A running queue keeps time going; a paused or empty one does not.
s.queues[1]={paused=false,pending={{action='walk'}}}
clock.after_dispatch(); eq(game.tick_paused,false)
s.queues[1].paused=true; tick(); eq(game.tick_paused,true)
s.queues[1]={paused=false,pending={},current={action='mine'}}
clock.after_dispatch(); eq(game.tick_paused,false)
s.queues[1].current=nil; tick(); eq(game.tick_paused,true)
s.queues[1]={paused=false,pending={},loop=true}
clock.after_dispatch(); eq(game.tick_paused,false)
s.queues={}; tick(); eq(game.tick_paused,true)
-- advance runs exactly N ticks while the character stands still, then pauses.
fails(function() clock.handlers.advance(p,{ticks=0}) end,'1..36000')
fails(function() clock.handlers.advance(p,{ticks=36001}) end,'1..36000')
fails(function() clock.handlers.advance(p,{ticks=1.5}) end,'1..36000')
local start=game.tick
r=clock.handlers.advance(p,{ticks=5})
eq(r.until_tick,start+5); eq(game.tick_paused,false); eq(r.run_until,start+5)
tick(4); eq(game.tick_paused,false)
tick(1); eq(game.tick_paused,true); eq(clock.report().run_until,nil)
-- until_crafted stops early once the hand-crafting queue empties.
p.crafting_queue_size=3
clock.handlers.advance(p,{ticks=100,until_crafted=true})
tick(10); eq(game.tick_paused,false)
p.crafting_queue_size=0; tick(1); eq(game.tick_paused,true)
-- An advance does not end early while work is in progress, and the pause
-- waits for that work too.
s.active[1]={kind='mine'}
clock.handlers.advance(p,{ticks=3}); tick(3); eq(game.tick_paused,false,'busy after advance keeps running')
s.active[1]=nil; tick(); eq(game.tick_paused,true)
-- Switching back to realtime unpauses and forgets a pending advance.
clock.handlers.advance(p,{ticks=50})
r=clock.handlers.clock(p,{mode='realtime'})
eq(r.mode,'realtime'); eq(game.tick_paused,false); eq(r.run_until,nil)
tick(100); eq(game.tick_paused,false)
-- advance in realtime mode is harmless: time already runs.
r=clock.handlers.advance(p,{ticks=10}); eq(r.until_tick,game.tick+10); eq(game.tick_paused,false)
print('clock: ok')
-- With nobody connected the clock leaves pausing to the server, so a client can rejoin.
clock.handlers.clock(p,{mode='turns'}); game.tick_paused=false
game.connected_players={}; tick(); eq(game.tick_paused,false)
game.connected_players={p}; tick(); eq(game.tick_paused,true)

