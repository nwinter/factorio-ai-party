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
p.character.unit_number=7; s.char_hits={[7]={hits=1,damage=10,last=990,by='small-biter'}}
game.tick=1000; W.handlers.sleep(p,{seconds=60}); eq(W.handlers.sleep_check(p,{peek=true}).woke,nil)
s.char_hits[7].last=1005; game.tick=1010
r=W.handlers.sleep_check(p,{peek=true}); eq(r.woke,'damaged'); eq(r.by,'small-biter'); eq(r.lost,nil)
s.char_hits=nil
-- A mention filed after the sleep began wakes it; an older one does not.
s.mentions={[1]={list={{tick=900,from='sol',text='old news'}},dropped=0}}
W.handlers.sleep(p,{seconds=60}); eq(W.handlers.sleep_check(p,{peek=true}).woke,nil)
game.tick=1060; table.insert(s.mentions[1].list,{tick=1060,from='opus',text='@astra coal at the boilers'})
r=W.handlers.sleep_check(p,{peek=true}); eq(r.woke,'mentioned'); eq(r.mention,'opus: @astra coal at the boilers')
-- Death wakes.
W.handlers.sleep(p,{seconds=60}); s.mentions=nil
p.character=nil; eq(W.handlers.sleep_check(p,{}).woke,'died')
-- In turns mode the clock is asked to run for the sleep (advance caps at 36000).
p.character={valid=true,health=250}; mode='turns'
W.handlers.sleep(p,{seconds=900}); eq(advanced,36000)
print('waits: ok')
