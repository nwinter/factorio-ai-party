-- Run from repository root: lua tests/selfview.lua
-- An agent's own play, reviewed (selfview.lua; operator task-selfview: shift 4, 85% of game actions were item moves
-- and walking, and nothing totalled them; 22:13: a review every 2 game hours and a retro at shift start): requests
-- and queue steps by kind, the character's time by kind, the hand hauls repeated most, failures, open alerts in its
-- claims, losses near its work; team.review, the review read, team.shift.retro. Fake engine.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(text,part) assert(text and text:find(part,1,true),'missing "'..part..'" in: '..tostring(text)) end
storage={active={},queues={},clocks={[1]={},[2]={}},board={items={}},losses={}}
game={tick=0}
local body={[1]=true,[2]=true}
local asleep={}
local READS={status=true,inventory=true,review=true}
local pos={[1]={x=10,y=10,s='nauvis'},[2]={x=500,y=500,s='nauvis'}}
local alerts={}
local news={}
local V=dofile('mod/agent-harness_0.1.0/selfview.lua'){
  state=function() return storage end,
  is_read=function(action) return READS[action]==true end,
  talk=function(action) return action=='say' or action=='tell' end,
  waiting=function(s,index) return asleep[index] and 'sleep' or nil end,
  has_body=function(index) return body[index] end,
  where=function(index) return pos[index] end,
  name=function(index) return ({'astra','sol'})[index] or 'director' end,
  is_director=function(index) return index==9 end,
  claims=function(name)
    local out={}
    for _,i in pairs(storage.board.items) do if i.kind=='claim' and i.owner==name then out[#out+1]=i.area end end
    return out
  end,
  claim_alerts=function(p) return alerts[p.index] or {} end,
  losses=function() return storage.losses end,
  loss_line=function(i) return string.format('#%d %d destroyed', i.id, i.total) end,
  research_between=function(force,from,to)
    local out={}
    for _,e in ipairs(news) do if e.tick>from and e.tick<=to then out[#out+1]=e.name end end
    return out
  end,
  board_items=function() return storage.board.items end}
local function advance(sec) for _=1,sec do game.tick=game.tick+60; V.tick() end end
local S=storage

-- 1. Kinds: game actions by what they do; reads, talk, waits; anything else is other.
eq(V.kind_of('transfer'),'item moves'); eq(V.kind_of('feed'),'item moves'); eq(V.kind_of('move_to'),'walking')
eq(V.kind_of('paste'),'building'); eq(V.kind_of('mine'),'mining'); eq(V.kind_of('craft'),'crafting')
eq(V.kind_of('research'),'research'); eq(V.kind_of('wait_ticks'),'waits'); eq(V.kind_of('say'),'talk')
eq(V.kind_of('status'),'reads'); eq(V.kind_of('queue_submit'),'reads'); eq(V.kind_of('review'),'reads'); eq(V.kind_of('equip'),'other')

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
eq(r.text,'review (last 14 min): 8 actions (1 of them queue steps): reads 3, item moves 1, walking 1, mining 1, waits 1, talk 1; time: 88% no request, 4% item moves, 3% waits, 3% walking, 2% mining, 1% talk')
-- The stretch since the last request is shown as such until a request ends it.
advance(40)
r=V.report(1,'nauvis'); eq(r.time_s['since your last request'],40)
V.request(1,'feed'); r=V.report(1,'nauvis'); eq(r.time_s['item moves'],70); eq(r.time_s['since your last request'],nil)
-- No body (dead, or a bot in a cargo pod): no time counted.
body[1]=false; advance(30); body[1]=true
eq(V.report(1,'nauvis').time_s['since your last request'],nil)

-- 3. Hauls: puts by hand, by item, the spot it was last taken from and the spot it went to (each within 10 tiles);
-- the top 3 of those repeated 5 times or more.
local P={index=1,surface={name='nauvis'},force={name='player'}}
local function ent(name,x,y,surface) return {name=name,position={x=x,y=y},surface={name=surface or 'nauvis'}} end
local chest=ent('wooden-chest',88,-3)
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
eq(r.hauls_text,'repeated hauls: iron-plate (13,40) -> wooden-chest (89,-3) x38, coal -> boiler (5,63) x21, copper-cable -> assembling-machine-1 (200,200) on vulcanus x7')
eq(#r.hauls,4,'every haul at 5 or more in the read')
eq(r.hauls[4].item,'automation-science-pack'); eq(r.hauls[4].times,6); eq(r.hauls[4].from,nil)
eq(r.hauls[1].from.x,13); eq(r.hauls[1].to_name,'wooden-chest')
-- A take over 2 hours old is no source any more.
S.selfview[1].takes['iron-plate'].tick=game.tick-432001
V.moved(P,'to_entity',chest,{{name='iron-plate',count=1}})
local h=S.selfview[1].hauls[#S.selfview[1].hauls]; eq(h.from,nil); eq(h.item,'iron-plate')

-- 4. Failures: failed requests (not peeks, operators or directors), failed queue steps, direct timed actions that
-- ended other than done; by action and reason with the numbers taken out.
eq(V.reason_key('transfer','no iron-plate in inventory; the target has 12 at (3.5,-4)'),'transfer: no iron-plate in inventory; the target has N at (N,N)')
for i=1,5 do V.dispatch_failed({action='transfer',player=1,args={}},'no iron-plate in inventory; the target has '..i) end
V.dispatch_failed({action='transfer',player=1,args={peek=true}},'x')
V.dispatch_failed({action='board',operator=true},'x'); V.dispatch_failed({action='status',player=9,args={}},'x')
V.dispatch_failed({action='build',player=1,args={}},'placement blocked by tree at (4,5) [ran as build {item}: alias]')
V.failed(1,'move_to','no_path')
for _,o in ipairs({'arrived','replaced','told','timed_out','no_path'}) do V.ended(1,'move_to',o) end
V.ended(1,'mine','stuck','mining took no ore at (1,2)')
r=V.report(1,'nauvis')
eq(r.failed,10)
eq(r.failed_text,'failed: 10 (transfer: no iron-plate in inventory; the target has N x5; move_to: no_path x2; build: placement blocked by tree at (N,N) x1)')

-- 5. The review block: the report line, hauls, failures, alerts open in its claims, losses near where it was.
local lines=V.review(P)
eq(lines[1],r.text); eq(lines[2],r.hauls_text); eq(lines[3],r.failed_text)
eq(lines[4],'open alerts in your claims: no claims')
eq(lines[5],'losses near your work: none')
S.board.items[1]={id=4,kind='claim',owner='astra',status='claimed',area={left_top={x=100,y=100},right_bottom={x=150,y=150}}}
alerts[1]={'12 gun-turret out of ammo near (120,130)'}
S.losses={{id=7,surface='nauvis',box={60,10,70,12},first=game.tick-600,last=game.tick-60,total=20,names={['stone-wall']=20}},  -- 50 tiles from (10,10)
  {id=8,surface='nauvis',box={140,140,145,145},first=game.tick-600,last=game.tick-60,total=5,names={['gun-turret']=5}},        -- in the claim
  {id=9,surface='vulcanus',box={10,10,12,12},first=game.tick-600,last=game.tick-60,total=9,names={}},                         -- another surface
  {id=10,surface='nauvis',box={400,400,410,410},first=game.tick-600,last=game.tick-60,total=3,names={}}}                     -- far off
lines=V.review(P)
eq(lines[4],'open alerts in your claims: 1: 12 gun-turret out of ammo near (120,130)')
eq(lines[5],'losses near your work: 2 incidents, 25 destroyed: #7 20 destroyed; #8 5 destroyed')
alerts[1]={}
eq(V.review(P)[4],'open alerts in your claims: none')

-- 6. team.review: every 2 game hours per agent, the first 2 hours into the shift (or after its first request).
S.shift={seq=1,tick=game.tick}
V.request(2,'status')
local Q={index=2,surface={name='nauvis'}}
eq(V.review_due(Q),nil)
advance(6700); V.request(2,'transfer')
advance(499); eq(V.review_due(Q),nil)
advance(1)
local block=V.review_due(Q)
assert(block and block[1]:find('^review %(last 2h%): 1 action: item moves 1; time: 93%% no request, 7%% since your last request$'),block and block[1])
eq(#block,4,'no hauls line'); eq(block[2],'failed: none'); eq(block[3],'open alerts in your claims: no claims'); eq(block[4],'losses near your work: none')
advance(3600); V.request(2,'status'); eq(V.review_due(Q),nil,'once per 2 hours')
advance(3600); assert(V.review_due(Q),'the next 2 hours')
-- The window is the last 2 hours: older minutes drop out.
advance(7200); V.request(1,'status')
r=V.report(1,'nauvis'); eq(r.minutes,120); eq(r.actions,1); eq(r.hauls,nil); eq(r.failed,0)
eq(r.text,'review (last 2h): 1 action: reads 1; time: 100% no request')
local read=V.read(P); eq(read.lines[1],r.text); assert(read.note:find('^time: game seconds of your character'),read.note)

-- 7. team.shift.retro: the previous shift for the team, once per shift (the same lines for everyone).
eq(V.retro(P),nil,'no previous shift')
local from=game.tick
news={{name='steel-axe',tick=from-10},{name='logistics-2',tick=from+100},{name='solar-energy',tick=from+200}}
S.losses={{id=11,surface='nauvis',box={0,0,5,5},first=from+300,last=from+400,total=40,names={['gun-turret']=30,['stone-wall']=10}},
  {id=12,surface='nauvis',box={0,0,5,5},first=from+500,last=from+600,total=8,names={['stone-wall']=8}},
  {id=6,surface='nauvis',box={0,0,5,5},first=from-900,last=from-800,total=99,names={}}}
advance(60)
for i=1,4 do V.failed(1,'transfer','no coal in inventory') end
V.failed(2,'transfer','no coal in inventory'); V.failed(2,'move_to','no_path')
S.board.items={[1]={id=4,kind='claim',owner='astra',status='claimed'},
  [2]={id=20,kind='request',title='copper plates to Vulcanus',status='open',created_tick=from+60},
  [3]={id=21,kind='task',title='rail to the north ore',owner='sol',status='doing',created_tick=from+30},
  [4]={id=22,kind='task',title='done one',status='done',created_tick=from},
  [5]={id=23,kind='harness',title='a read for belts',owner='operator',status='open',created_tick=from+90}}
advance(3600*3)
S.shift={seq=2,tick=game.tick,prev_tick=from}
local retro=V.retro(P)
eq(retro[1],'retro: previous shift (3h01m of game time): research done: logistics-2, solar-energy')
eq(retro[2],'losses: 2 incidents, 48 destroyed (30 gun-turret, 18 stone-wall); largest: #11 40 destroyed')
eq(retro[3],'failed (team): 6 (transfer: no coal in inventory x5 (astra 4, sol 1); move_to: no_path x1 (sol 1))')
eq(retro[4],'open board items: 3 (1 harness, 1 request, 1 task); oldest: #21 task "rail to the north ore" (sol, doing, 3h00m old); '
  ..'#20 request "copper plates to Vulcanus" (no owner, open, 3h00m old); #23 harness "a read for belts" (operator, open, 3h00m old)')
eq(V.retro({index=2,force={name='player'}}),retro,'kept for the shift: the same lines for everyone')
print('selfview: ok')
