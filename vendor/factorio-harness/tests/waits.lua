-- Run from repository root: lua tests/waits.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
game={tick=100}
local s={active={}}
local mode,advanced,replaced='realtime',nil,0
local function integer(v,d,lo,hi,name) if v==nil then v=d end; assert(type(v)=='number' and v==math.floor(v) and v>=lo and v<=hi,name..' out of range'); return v end
local W=dofile('mod/agent-harness_0.1.0/waits.lua'){state=function() return s end,integer=integer,
  replace=function() replaced=replaced+1 end,advance=function(_,ticks) advanced=ticks end,clock_mode=function() return mode end}
local p={index=1,character={valid=true,health=250}}
-- wait_ticks: a direct timed action replacing what the character did.
fails(function() W.handlers.wait_ticks(p,{}) end,'ticks (1..54000) out of range')
fails(function() W.handlers.wait_ticks(p,{ticks=54001}) end,'out of range')
eq(W.handlers.wait_ticks(p,{ticks=600}).until_tick,700); eq(s.active[1].kind,'wait_ticks'); eq(replaced,1)
-- sleep: checks are reads; nothing woke yet.
fails(function() W.handlers.sleep_check(p,{}) end,'no sleep started')
fails(function() W.handlers.sleep(p,{seconds=901}) end,'seconds (1..900) out of range')
eq(W.handlers.sleep(p,{seconds=10}).until_tick,700); eq(advanced,nil)
eq(W.handlers.sleep_check(p,{peek=true}).woke,nil)
-- Time up.
game.tick=700; eq(W.handlers.sleep_check(p,{}).woke,'elapsed')
-- Damage wakes, with how much was lost; the reason sticks.
game.tick=1000; W.handlers.sleep(p,{seconds=60})
p.character.health=200
local r=W.handlers.sleep_check(p,{peek=true}); eq(r.woke,'damaged'); eq(r.lost,50); eq(r.health,200)
p.character.health=250; eq(W.handlers.sleep_check(p,{}).woke,'damaged')
-- A recorded enemy hit counts even after the health came back; an older one does not.
-- (Past the 10 s in which a new sleep repeats the wake just read.)
p.character.unit_number=7; s.char_hits={[7]={hits=1,damage=10,last=1690,by='small-biter'}}
game.tick=1700; W.handlers.sleep(p,{seconds=60}); eq(W.handlers.sleep_check(p,{peek=true}).woke,nil)
s.char_hits[7].last=1705; game.tick=1710
r=W.handlers.sleep_check(p,{peek=true}); eq(r.woke,'damaged'); eq(r.by,'small-biter'); eq(r.lost,nil)
s.char_hits=nil
-- A mention filed after the sleep began wakes it; an older one does not.
s.mentions={[1]={list={{tick=900,from='sol',text='old news'}},dropped=0}}
W.handlers.sleep(p,{seconds=60}); eq(W.handlers.sleep_check(p,{peek=true}).woke,nil)
game.tick=1760; table.insert(s.mentions[1].list,{tick=1760,from='opus',text='@astra coal at the boilers'})
r=W.handlers.sleep_check(p,{peek=true}); eq(r.woke,'mentioned'); eq(r.mention,'opus: @astra coal at the boilers')
-- Death wakes.
W.handlers.sleep(p,{seconds=60}); s.mentions=nil
p.character=nil
-- A bot riding a cargo pod or aboard a platform has no body and keeps sleeping.
local riding=true
local Wt=dofile('mod/agent-harness_0.1.0/waits.lua'){state=function() return s end,integer=integer,
  replace=function() end,advance=function() end,clock_mode=function() return 'realtime' end,traveling=function() return riding end}
eq(Wt.handlers.sleep_check(p,{peek=true}).woke,nil)
riding=false
eq(W.handlers.sleep_check(p,{}).woke,'died')
-- A tell or mention wakes once: the reply that woke the agent delivered it,
-- so the next sleep runs (agent-minds study, fix 5: Luna's 32 repeats of
-- tells already read).
game.tick=5000; p.character={valid=true,health=250}
s.mentions={[1]={list={},dropped=0}}
W.handlers.sleep(p,{seconds=300})
game.tick=5001; table.insert(s.mentions[1].list,{tick=5001,from='sol',text='@astra hi'})
eq(W.handlers.sleep_check(p,{peek=true}).woke,'mentioned') -- a peek is not reading it
game.tick=5002; eq(W.handlers.sleep_check(p,{}).woke,'mentioned')
game.tick=5300; r=W.handlers.sleep(p,{seconds=300}); eq(r['repeat'],nil); eq(r.sleeping_s,300)
eq(W.handlers.sleep_check(p,{peek=true}).woke,nil)
game.tick=5301; table.insert(s.mentions[1].list,{tick=5301,tell=3,from='operator',text='stood idle'})
r=W.handlers.sleep_check(p,{}); eq(r.woke,'told'); eq(r.tell,'operator: stood idle')
game.tick=5310; eq(W.handlers.sleep(p,{seconds=300})['repeat'],nil)
-- Other wakes are repeated by a sleep right after the agent read them (a
-- shell loop of sleeps ends): within 10 s, at most 3 times per wake.
local function hurt(t) game.tick=t; p.character.health=p.character.health-10 end
hurt(5400); eq(W.handlers.sleep_check(p,{}).woke,'damaged')
game.tick=5640
for _=1,3 do
  r=W.handlers.sleep(p,{seconds=300}); eq(r['repeat'],true); eq(r.woke,'damaged'); eq(r.sleeping_s,0)
  eq(r.while_asleep,'this sleep did not start: you woke (damaged) 4 s ago; it ends at once and repeats that wake')
  r=W.handlers.sleep_check(p,{peek=true}); eq(r.woke,'damaged'); eq(r['repeat'],true); eq(r.slept_s,0)
  eq(W.handlers.sleep_check(p,{}).woke,'damaged')
end
r=W.handlers.sleep(p,{seconds=300}); eq(r['repeat'],nil) -- the fourth runs
eq(W.handlers.sleep_check(p,{peek=true}).woke,nil)
-- A sleep given its own condition is never a repeat.
hurt(5310+400); eq(W.handlers.sleep_check(p,{}).woke,'damaged')
local Wc=dofile('mod/agent-harness_0.1.0/waits.lua'){state=function() return s end,integer=integer,replace=function() end,
  advance=function() end,clock_mode=function() return 'realtime' end,validate_condition=function() end,condition=function() return false,'x 0' end}
r=Wc.handlers.sleep(p,{seconds=300,condition={['until']='crafting_done'}}); eq(r['repeat'],nil); eq(r.condition,'crafting_done')
-- Past 10 s it runs; a sleep that ran out (elapsed) is not repeated.
hurt(5800); eq(W.handlers.sleep_check(p,{}).woke,'damaged')
game.tick=6401; eq(W.handlers.sleep(p,{seconds=1})['repeat'],nil)
game.tick=6461; eq(W.handlers.sleep_check(p,{}).woke,'elapsed')
eq(W.handlers.sleep(p,{seconds=1})['repeat'],nil)
-- In turns mode nothing is repeated (game time stands still between requests).
hurt(6470); eq(W.handlers.sleep_check(p,{}).woke,'damaged')
mode='turns'; eq(W.handlers.sleep(p,{seconds=60})['repeat'],nil); mode='realtime'
s.mentions=nil
-- until=alert (fh wait --until alert): a new attack, enemy group or enemy base alert (threat.lua's alert_seq) wakes it.
game.tick=7000; mode='realtime'; s.alert_seq=4
r=W.handlers.sleep(p,{seconds=300,condition={['until']='alert'}}); eq(r.condition,'alert'); assert(r.wakes_on:find('a new alert',1,true))
eq(W.handlers.sleep_check(p,{peek=true}).woke,nil)
s.alert_seq=5; game.tick=7100; r=W.handlers.sleep_check(p,{peek=true}); eq(r.woke,'alert'); assert(r.alert:find('new attack',1,true))
-- In turns mode the clock is asked to run for the sleep (advance caps at 36000).
p.character={valid=true,health=250}; mode='turns'
W.handlers.sleep(p,{seconds=900}); eq(advanced,36000)
print('waits: ok')
