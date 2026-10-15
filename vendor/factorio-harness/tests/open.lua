-- Run from repository root: lua tests/open.lua
-- d15 H3: "open for you" on a sleep's replies (open.lua); H4: a sleep with nothing running and no condition is capped
-- at 300 s (waits.lua).
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,text,m) assert(type(s)=='string' and s:find(text,1,true),(m or 'missing')..': '..tostring(s)..' lacks '..text) end
game={tick=100000,surfaces={nauvis={index=1},vulcanus={index=3}}}
local s={active={}}
local groups={}
local O=dofile('mod/agent-harness_0.1.0/open.lua'){state=function() return s end,
  claim_surface=function(i) return i.surface or 'nauvis' end,claim_stale=function(i) return i.stale==true end,
  alert_groups=function() return groups end,alert_text=function(g) return g.line end}
local force={name='player'}

-- Nothing open, no claims.
eq(O.line('sonnet',force),'open for you: none (no board items of yours, no fresh claims, no unanswered requests or tells)')

-- Board items of mine (claims, notes and plans aside), with status; a request a teammate gave me that I never noted.
s.board={items={
  {id=425,kind='task',owner='sonnet',status='doing',title='purple science'},
  {id=449,kind='request',owner='sonnet',requested_by='astra',status='claimed',title='acid well',notes={},edits={},created_tick=100000-3600*12},
  {id=450,kind='request',owner='sonnet',requested_by='grok',status='claimed',title='cliff explosives',notes={{by='sonnet',text='on it'}}},
  {id=451,kind='task',owner='sonnet',status='done',title='old'},
  {id=452,kind='note',owner='sonnet',status='open',title='a note'},
  {id=453,kind='task',owner='haiku',status='doing',title='boilers'},
  {id=500,kind='claim',owner='sonnet',status='doing',title='Vulcanus core',surface='vulcanus',area={left_top={x=0,y=100},right_bottom={x=150,y=200}}},
  {id=501,kind='claim',owner='sonnet',status='doing',title='old corner',stale=true,area={left_top={x=-50,y=-50},right_bottom={x=50,y=50}}},
}}
-- Alert groups: one in my fresh claim, one in my stale claim, one elsewhere.
groups={{kind='feed_chest_low',surface='vulcanus',center={x=20,y=140},line='boiler (20,140): its feed chest holds no fuel'},
  {kind='no_ammo',surface='nauvis',center={x=0,y=0},line='2 gun-turret out of ammo near (0,0)'},
  {kind='no_power',surface='vulcanus',center={x=400,y=0},line='5 drills no power'}}
-- The survey's cached non-working positions: two starved in my fresh claim, one working-adjacent status ignored, one outside.
s.survey_cache={['player/3']={positions={
  ['chemical-plant']={item_ingredient_shortage={{x=24.5,y=116.5}},fluid_ingredient_shortage={{x=30.5,y=116.5}}},
  ['assembling-machine-2']={low_power={{x=10.5,y=120.5}},no_ingredients={{x=500.5,y=10.5}}},
  belt_ends={{x=1,y=1}}}}}
-- Tells: astra asked me 5 min ago (unanswered), grok 20 min ago and I answered, haiku's fyi, a team tell, one 40 min old.
s.tells={log={
  {seq=1,tick=100000-40*3600,from='luna',to={'sonnet'},text='too old'},
  {seq=2,tick=100000-20*3600,from='grok',to={'sonnet'},text='explosives?'},
  {seq=3,tick=100000-19*3600,from='sonnet',to={'grok'},text='none here'},
  {seq=4,tick=100000-5*3600,from='astra',to={'sonnet'},text='how much LDS can you ship?'},
  {seq=5,tick=100000-4*3600,from='haiku',to={'sonnet'},text='fyi coal',fyi=true},
  {seq=6,tick=100000-3*3600,from='opus',to={'sonnet','haiku'},team=true,text='status'},
}}
local line=O.line('sonnet',force)
eq(line,'open for you: 3 board items of yours (#425 purple science [doing]; #449 acid well [claimed]; #450 cliff explosives [claimed]); '
  ..'1 alert group in your claims (boiler (20,140): its feed chest holds no fuel (claim #500)); '
  ..'2 machines idle or starved in your claims (chemical-plant (30.5,116.5) fluid ingredient shortage; chemical-plant (24.5,116.5) ingredient shortage); '
  ..'2 requests or tells to you unanswered (board #449 from astra 12m00s ago: acid well; tell from astra 5m00s ago: how much LDS can you ship?)')
-- Answering astra by tell clears it; examples stop at 3 with "...".
s.tells.log[#s.tells.log+1]={seq=7,tick=100000-60,from='sonnet',to={'astra'},text='150 LDS'}
for k=1,3 do s.board.items[#s.board.items+1]={id=600+k,kind='task',owner='sonnet',status='open',title='job '..k} end
line=O.line('sonnet',force)
has(line,'6 board items of yours (#425 purple science [doing]; #449 acid well [claimed]; #450 cliff explosives [claimed]; ...)')
has(line,'1 request or tell to you unanswered (board #449 from astra')
-- Claims but nothing in them.
s.board={items={{id=500,kind='claim',owner='sonnet',status='doing',title='x',area={left_top={x=1000,y=1000},right_bottom={x=1001,y=1001}}}}}
s.tells=nil
eq(O.line('sonnet',force),'open for you: none (no board items of yours, no alert groups or idle machines in your claims, no unanswered requests or tells)')

-- waits.lua: the open line on the first reply and on the reply that reads the wake; the 300 s cap.
local function integer(v,d,lo,hi,name) if v==nil then v=d end; assert(type(v)=='number' and v==math.floor(v) and v>=lo and v<=hi,name..' out of range'); return v end
local opened=0
local W=dofile('mod/agent-harness_0.1.0/waits.lua'){state=function() return s end,integer=integer,replace=function() end,
  advance=function() end,clock_mode=function() return 'realtime' end,validate_condition=function() end,
  condition=function() return false,'x 0' end,open_line=function() opened=opened+1; return 'open for you: 1 board item of yours (#1 x [doing])' end}
local p={index=1,character={valid=true,health=250}}
s.active={}
local r=W.handlers.sleep(p,{seconds=900})
eq(r.sleeping_s,300); eq(r.until_tick,game.tick+18000); eq(r.capped,'capped at 300 s: no queue, action or condition')
eq(r.while_asleep,'no queue and no action: your character stands idle for up to 300 s')
eq(r.open,'open for you: 1 board item of yours (#1 x [doing])'); eq(opened,1)
eq(W.handlers.sleep_check(p,{peek=true}).open,nil,'polls do not compute it'); eq(opened,1)
game.tick=game.tick+18000
r=W.handlers.sleep_check(p,{peek=true}); eq(r.woke,'elapsed'); eq(opened,1)
r=W.handlers.sleep_check(p,{}); eq(r.woke,'elapsed'); eq(r.capped,'capped at 300 s: no queue, action or condition'); has(r.open,'open for you'); eq(opened,2)
r=W.handlers.sleep_check(p,{}); eq(opened,2,'once')
-- Not capped: 300 s or less, a condition, an alert, a running action, a running queue.
game.tick=game.tick+1000
eq(W.handlers.sleep(p,{seconds=240}).capped,nil)
r=W.handlers.sleep(p,{seconds=900,condition={['until']='crafting_done'}}); eq(r.sleeping_s,900); eq(r.capped,nil)
r=W.handlers.sleep(p,{seconds=900,condition={['until']='alert'}}); eq(r.sleeping_s,900)
s.active[1]={kind='move_to',until_tick=game.tick+600}
eq(W.handlers.sleep(p,{seconds=900}).sleeping_s,900); s.active[1]=nil
s.queues={[1]={pending={{action='mine'}},history={}}}
eq(W.handlers.sleep(p,{seconds=900}).sleeping_s,900); s.queues=nil
s.remote_queues={[1]={pending={{action='wait_until'}},history={}}}
eq(W.handlers.sleep(p,{seconds=900}).sleeping_s,900); s.remote_queues=nil
-- A paused queue does not count as running.
s.queues={[1]={paused=true,pending={{action='mine'}},history={}}}
r=W.handlers.sleep(p,{seconds=900}); eq(r.sleeping_s,300); has(r.while_asleep,'your queue is paused with 1 steps pending'); s.queues=nil
-- A standing order's rounds (Opus, shift17 12:20: about 30 sleeps woke on copper-fuel rounds): a sleep begun while one
-- runs is not ended when the round finishes, and it is not capped (the character works); wake_on_orders ends it; the
-- agent's own plan still does.
game.tick=game.tick+5000
s.queues={[1]={pending={{action='refuel'}},history={},order={name='copper-fuel'}}}
r=W.handlers.sleep(p,{seconds=900})
eq(r.sleeping_s,900); eq(r.capped,nil)
eq(r.while_asleep,'your standing order copper-fuel runs in your queue (1 steps pending); its rounds do not end this sleep (wake_on_orders: true ends it on them)')
assert(not r.wakes_on:find('queue',1,true),r.wakes_on)
s.queues[1].pending={}; s.queues[1].order=nil
game.tick=game.tick+60
eq(W.handlers.sleep_check(p,{peek=true}).woke,nil,'the round finished: still asleep')
s.queues={[1]={pending={{action='refuel'}},history={},order={name='copper-fuel'}}}
r=W.handlers.sleep(p,{seconds=900,wake_on_orders=true})
s.queues[1].pending={}; s.queues[1].order=nil
game.tick=game.tick+60
eq(W.handlers.sleep_check(p,{peek=true}).woke,'queue_done')
-- the agent's own plan: ends it as before
game.tick=game.tick+1000
s.queues={[1]={pending={{action='mine'}},history={}}}
W.handlers.sleep(p,{seconds=900})
s.queues[1].pending={}
game.tick=game.tick+60
eq(W.handlers.sleep_check(p,{peek=true}).woke,'queue_done')
s.queues=nil
-- d15 trajectory analysis: stale items counted apart; no claims: idle machines near the agent; unowned items and steps.
do
  local kept_board,kept_cache=s.board,s.survey_cache
  s.board={items={
    {id=425,kind='task',owner='sonnet',status='doing',title='purple science',updated_tick=game.tick-3*3600*60},
    {id=449,kind='task',owner='sonnet',status='doing',title='plastic',updated_tick=game.tick-600},
    {id=700,kind='request',status='open',title='belts to the mall',updated_tick=game.tick-600},
    {id=701,kind='task',status='open',title='an old job',updated_tick=game.tick-5*3600*60}}}
  s.survey_cache={['player/3']={positions={['assembling-machine-3']={item_ingredient_shortage={{x=10.5,y=10.5},{x=300.5,y=10.5}},no_power={{x=50.5,y=0.5}}}}}}
  local O2=dofile('mod/agent-harness_0.1.0/open.lua'){state=function() return s end,claim_surface=function(i) return i.surface or 'nauvis' end,
    claim_stale=function() return false end,open_steps=function() return {'#9 step 2: lay the belt (no owner; take it with board_update {id: 9, take_step: 2})'} end}
  local l=O2.line('sonnet',force,{surface='vulcanus',position={x=0,y=0}})
  has(l,'1 board item of yours (#449 plastic [doing]), 1 more of yours unchanged for 2h+ left out')
  has(l,'2 machines idle or starved near you (you hold no fresh claim) (assembling-machine-3 (10.5,10.5) ingredient shortage, 15 tiles; assembling-machine-3 (50.5,0.5) no power, 51 tiles)')
  has(l,'1 unowned board item open to take (#700 request belts to the mall)')
  has(l,'project steps open to take: #9 step 2: lay the belt')
  assert(not l:find('an old job',1,true) and not l:find('purple science',1,true),l)
  -- a fresh claim with a starved machine and no alert group: the machine is listed (the loop stopped at the empty part)
  s.board={items={{id=800,kind='claim',owner='sonnet',status='doing',title='core',surface='vulcanus',area={left_top={x=0,y=0},right_bottom={x=20,y=20}}}}}
  l=O2.line('sonnet',force,{surface='vulcanus',position={x=0,y=0}})
  has(l,'1 machine idle or starved in your claims (assembling-machine-3 (10.5,10.5) ingredient shortage)')
  s.board,s.survey_cache=kept_board,kept_cache
end
print('open: ok')
