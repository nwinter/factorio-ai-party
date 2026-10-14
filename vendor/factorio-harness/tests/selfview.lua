-- Run from repository root: lua tests/selfview.lua
-- An agent's own hour (selfview.lua; operator task-selfview: shift 4, 85% of game actions were item moves and
-- walking, and nothing totalled them): requests and queue steps by kind, the character's time by kind, the hand
-- hauls repeated most; team.your_hour once per game hour, and the my_hour read. Fake engine.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(text,part) assert(text:find(part,1,true),'missing "'..part..'" in: '..text) end
storage={active={},queues={},clocks={[1]={},[2]={}}}
game={tick=0}
local body={[1]=true,[2]=true}
local asleep={}
local READS={status=true,inventory=true,my_hour=true}
local V=dofile('mod/agent-harness_0.1.0/selfview.lua'){
  state=function() return storage end,
  is_read=function(action) return READS[action]==true end,
  talk=function(action) return action=='say' or action=='tell' end,
  waiting=function(s,index) return asleep[index] and 'sleep' or nil end,
  has_body=function(index) return body[index] end}
local function advance(sec) for _=1,sec do game.tick=game.tick+60; V.tick() end end
local S=storage

-- 1. Kinds: game actions by what they do; reads, talk, waits; anything else is other.
eq(V.kind_of('transfer'),'item moves'); eq(V.kind_of('feed'),'item moves'); eq(V.kind_of('move_to'),'walking')
eq(V.kind_of('paste'),'building'); eq(V.kind_of('mine'),'mining'); eq(V.kind_of('craft'),'crafting')
eq(V.kind_of('research'),'research'); eq(V.kind_of('wait_ticks'),'waits'); eq(V.kind_of('say'),'talk')
eq(V.kind_of('status'),'reads'); eq(V.kind_of('queue_submit'),'reads'); eq(V.kind_of('equip'),'other')

-- 2. Time: a running action counts as its kind; the stretch before a request counts toward that request's kind
-- (the time it took to issue it); a sleep counts as waits; a stretch of 10 min or more is "no request".
V.request(1,'status')
advance(30); V.request(1,'transfer')            -- 30 s to item moves
S.active[1]={kind='move_to',until_tick=game.tick+1200}; V.request(1,'move_to')
advance(20); S.active[1]=nil                    -- 20 s walking
advance(10); V.request(1,'say')                 -- 10 s to talk
S.queues[1]={current={action='mine'},pending={},paused=false}; V.request(1,'mine',true)
advance(15); S.queues[1]=nil                    -- 15 s mining, by the queue (no gap credited, no request)
asleep[1]=true; V.request(1,'sleep'); advance(25); asleep[1]=nil  -- 25 s waits
V.request(1,'status')
advance(700); V.request(1,'status')             -- 700 s: no request
local r=V.report(1,'nauvis')
eq(r.actions,8); eq(r.queue_steps,1)
eq(r.counts.reads,3); eq(r.counts['item moves'],1); eq(r.counts.walking,1); eq(r.counts.talk,1); eq(r.counts.mining,1); eq(r.counts.waits,1)
eq(r.time_s['item moves'],30); eq(r.time_s.walking,20); eq(r.time_s.talk,10); eq(r.time_s.mining,15); eq(r.time_s.waits,25)
eq(r.time_s['no request'],700); eq(r.time_s.reads,nil,'a read right after the sleep took no time')
eq(r.time_pct['no request'],88); eq(r.time_pct['item moves'],4)
has(r.text,'your last 14 min: 8 actions (1 of them queue steps): reads 3, item moves 1, walking 1, mining 1, waits 1, talk 1; time: 88% no request, 4% item moves, 3% waits, 3% walking, 2% mining, 1% talk')
-- The stretch since the last request is shown as such until a request ends it.
advance(40)
r=V.report(1,'nauvis'); eq(r.time_s['since your last request'],40)
V.request(1,'feed'); r=V.report(1,'nauvis'); eq(r.time_s['item moves'],70); eq(r.time_s['since your last request'],nil)
-- No body (dead, or a bot in a cargo pod): no time counted.
body[1]=false; advance(30); body[1]=true
eq(V.report(1,'nauvis').time_s['since your last request'],nil)

-- 3. Hauls: puts by hand, by item, the spot it was last taken from and the spot it went to (each within 10 tiles);
-- the top 3 of those repeated 5 times or more.
local P={index=1}
local function ent(name,x,y,surface) return {name=name,position={x=x,y=y},surface={name=surface or 'nauvis'}} end
local chest,furnace=ent('wooden-chest',88,-3),ent('stone-furnace',12,40)
for i=1,38 do
  V.moved(P,'to_player',ent('stone-furnace',12+(i%3),40),{{name='iron-plate',count=50}})
  V.moved(P,'to_entity',ent('wooden-chest',88+(i%4),-3),{{name='iron-plate',count=50}})
end
for i=1,21 do V.moved(P,'to_entity',ent('boiler',5,60+(i%2)*3),{{name='coal',count=5}}) end
for i=1,6 do V.moved(P,'to_entity',ent('lab',-30,7),{{name='automation-science-pack',count=10}}) end
for i=1,7 do V.moved(P,'to_entity',ent('assembling-machine-1',200,200,'vulcanus'),{{name='copper-cable',count=10}}) end
for i=1,4 do V.moved(P,'to_entity',ent('wooden-chest',300,300),{{name='stone',count=50}}) end
V.moved(P,'to_entity',ent('wooden-chest',115,-3),{{name='iron-plate',count=50}})  -- 27 tiles on: another haul
r=V.report(1,'nauvis')
has(r.text,'; repeated hauls: iron-plate (13,40) -> wooden-chest (89,-3) x38, coal -> boiler (5,63) x21, copper-cable -> assembling-machine-1 (200,200) on vulcanus x7')
eq(#r.hauls,4,'every haul at 5 or more in the read')
eq(r.hauls[4].item,'automation-science-pack'); eq(r.hauls[4].times,6); eq(r.hauls[4].from,nil)
eq(r.hauls[1].from.x,13); eq(r.hauls[1].to_name,'wooden-chest')
-- A take over an hour old is no source any more.
S.selfview[1].takes['iron-plate'].tick=game.tick-216001
V.moved(P,'to_entity',chest,{{name='iron-plate',count=1}})
local h=S.selfview[1].hauls[#S.selfview[1].hauls]; eq(h.from,nil); eq(h.item,'iron-plate')

-- 4. The team block line: once per game hour per agent, the first an hour into the shift (or after its first request).
S.shift={tick=game.tick}
V.request(2,'status')
eq(V.hour_line({index=2,surface={name='nauvis'}}),nil)
advance(3100); V.request(2,'transfer')
advance(499); eq(V.hour_line({index=2,surface={name='nauvis'}}),nil)
advance(1)
local line=V.hour_line({index=2,surface={name='nauvis'}})
assert(line and line:find('^your hour: 1 action: item moves 1; time: 8%d%% no request, 1%d%% since your last request$'),line)
advance(1800); V.request(2,'status'); eq(V.hour_line({index=2,surface={name='nauvis'}}),nil,'once per hour')
advance(1800); assert(V.hour_line({index=2,surface={name='nauvis'}}),'the next hour')

-- 5. The window is the last hour: older minutes drop out.
advance(3600); V.request(1,'status')
r=V.report(1,'nauvis'); eq(r.minutes,60); eq(r.actions,1); eq(r.hauls,nil)
has(r.text,'your hour: 1 action: reads 1; time: 100% no request')
local read=V.read({index=1,surface={name='nauvis'}}); assert(read.note:find('^time: game seconds of your character'),read.note)
print('selfview: ok')
