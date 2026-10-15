-- Run from repository root: lua tests/urgent.lua
-- Urgent alerts wake every sleep and direct wait (urgent.lua), and until=alert names its alert and takes an area and
-- size filter (Haiku, d15 06:20).
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,text,m) assert(type(s)=='string' and s:find(text,1,true),(m or 'missing')..': '..tostring(s)..' lacks '..text) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
game={tick=1000}
local s={active={}}
local hears,view={},nil
local U=dofile('mod/agent-harness_0.1.0/urgent.lua'){state=function() return s end,who=function(p) return p.name end,
  attack_line=function(v) return string.format('attack #%d at (%d,%d)',v.id,v.at.x,v.at.y) end,
  claim_surface=function(i) return i.surface or 'nauvis' end,claim_stale=function(i) return i.stale==true end,
  platform_hears=function(p,name) return hears[name]==true end,power_view=function() return view end}
local platforms={}
local p={index=1,name='haiku',surface={name='nauvis'},character={valid=true,position={x=0,y=0},health=250},force={platforms=platforms}}

-- Nothing kept: nothing urgent.
local base=U.base(p)
eq(U.check(p,base),nil)
-- An attack 30 tiles away wakes, once; one 100 tiles away does not.
game.tick=1100
s.damage={a={id=7,at={x=30,y=0},surface='nauvis',damage=30,hits=1,last=1100},b={id=8,at={x=100,y=0},surface='nauvis',damage=300,hits=9,last=1100}}
has(U.check(p,base),'attack on our structures 30 tiles from you: attack #7 at (30,0)')
eq(U.check(p,base),nil,'told once')
-- It continues: told again only after 5 minutes, and only if it grew.
game.tick=1100+U.REPEAT; s.damage.a.last=game.tick
eq(U.check(p,base),nil,'not grown')
s.damage.a.hits=5
has(U.check(p,base),'attack #7')
-- Another surface's attack at the same spot is not near.
s.damage={c={id=9,at={x=5,y=5},surface='gleba',damage=10,hits=1,last=game.tick}}
eq(U.check(p,base),nil)
-- An attack from before the sleep began does not wake it.
s.damage={d={id=10,at={x=5,y=5},surface='nauvis',damage=10,hits=1,last=900}}
eq(U.check(p,base),nil)
s.damage=nil

-- An enemy group heading for a spot within 40 tiles (Haiku, shift17 09:20: groups heading 52-63 tiles away woke it).
game.tick=20000; base=U.base(p)
s.attack_groups={{seq=1,tick=19000,size=20,position={x=0,y=200},target={x=0,y=10},surface='nauvis'},
  {seq=2,tick=20010,size=3,position={x=500,y=0},target={x=400,y=0},surface='nauvis'},
  {seq=4,tick=20015,size=9,position={x=187,y=-14},target={x=63,y=0},surface='nauvis'},
  {seq=3,tick=20020,size=9,kinds='9 big-biter',position={x=90,y=90},target={x=36,y=0},surface='nauvis'}}
game.tick=20030
eq(U.check(p,base),'enemy group of 9 (9 big-biter) gathered at (90,90), 127 tiles from you, heading for (36,0), 36 tiles from you')
eq(U.check(p,base),nil,'each group once; the one before the sleep, one heading 63 tiles away and the far one do not wake it')
s.attack_groups=nil

-- Buildings destroyed by enemies in a fresh claim of mine, or near me; friendly fire and teammates' claims do not.
game.tick=30000; base=U.base(p)
s.board={items={{id=5,kind='claim',owner='haiku',status='doing',title='home boilers',area={left_top={x=200,y=200},right_bottom={x=260,y=260}}},
  {id=6,kind='claim',owner='opus',status='doing',title='iron',area={left_top={x=-400,y=-400},right_bottom={x=-300,y=-300}}}}}
s.losses={{id=1,surface='nauvis',box={-350,-350,-340,-340},first=30010,last=30010,names={['gun-turret']=2},causes={['big-biter']=2},total=2},
  {id=2,surface='nauvis',box={210,210,212,214},first=30010,last=30020,names={['flamethrower-turret']=3},causes={},friendly={['flamethrower-turret']=3},total=3},
  {id=3,surface='nauvis',box={220,220,230,224},first=30015,last=30025,names={['boiler']=2,['transport-belt']=5},causes={['big-spitter']=4},total=7}}
game.tick=30030
eq(U.check(p,base),'buildings destroyed in your claim #5 "home boilers": loss #3 at (225,222): 7 destroyed (5 transport-belt, 2 boiler) by 4 big-spitter')
eq(U.check(p,base),nil)
-- A stale claim is not watched; a loss within 40 tiles is.
s.board.items[1].stale=true
s.losses={{id=4,surface='nauvis',box={230,230,231,231},first=30040,last=30040,names={boiler=1},causes={['big-biter']=1},total=1},
  {id=5,surface='nauvis',box={20,0,25,3},first=30040,last=30040,names={['small-electric-pole']=1},causes={['medium-spitter']=1},total=1}}
game.tick=30050
eq(U.check(p,base),'buildings destroyed 20 tiles from you: loss #5 at (23,2): 1 destroyed (1 small-electric-pole) by 1 medium-spitter')
eq(U.check(p,base),nil)
-- A platform's losses wake those its alerts go to.
s.losses={{id=6,surface='platform-2',platform='Sunward',box={1,1,2,2},first=30060,last=30060,names={['gun-turret']=1},causes={['medium-asteroid']=1},total=1}}
game.tick=30070
eq(U.check(p,base),nil,'not mine to hear')
hears.Sunward=true
has(U.check(p,base),'platform Sunward lost buildings: loss #6')
s.losses=nil

-- A platform's hub taking damage, counted from the sleep's start.
s.platform_alerts={by={[2]={total={entities={['space-platform-hub']=100},by={['medium-asteroid']=4}}}}}
platforms[2]={valid=true,index=2,name='Sunward',hub={valid=true,health=4800,max_health=5000}}
game.tick=40000; base=U.base(p)
eq(U.check(p,base),nil,'hits before the sleep')
s.platform_alerts.by[2].total.entities['space-platform-hub']=300
eq(U.check(p,base),'platform Sunward: its hub took 200 damage, health 4800 of 5000; hits by 4 medium-asteroid')
eq(U.check(p,base),nil)
hears.Sunward=false
s.platform_alerts.by[2].total.entities['space-platform-hub']=400
eq(U.check(p,base),nil,'not mine to hear')
s.platform_alerts=nil

-- A teammate's death on my surface; mine and other surfaces' do not wake me.
game.tick=50000; base=U.base(p)
s.chronicle={events={{id=1,kind='death',agent='luna',surface='gleba',tick=50010,position={x=1,y=1}},
  {id=2,kind='death',agent='haiku',surface='nauvis',tick=50020,position={x=0,y=0}},
  {id=3,kind='death',agent='opus',surface='nauvis',tick=50030,position={x=-30,y=40},by='big-spitter'}}}
game.tick=50040
eq(U.check(p,base),'opus died at (-30,40), killed by big-spitter, 50 tiles from you')
eq(U.check(p,base),nil)
s.chronicle=nil

-- Power collapse on my surface: 20+ machines, half on low or no power (the networks' cached view; nil before one).
eq(U.check(p,base),nil)
view={surfaces={{name='nauvis',electric={{id=2,machines=300,low=100,none=10,center={x=-10,y=40}},{id=9,machines=10,low=10,none=0}}},
  {name='vulcanus',electric={{id=3,machines=100,low=90,none=0}}}}}
eq(U.check(p,base),nil,'110 of 300 is under half')
view.surfaces[1].electric[1].low=160
eq(U.check(p,base),'power collapse: electric #2 near (-10,40) has 170 of 300 machines on low or no power (160 low, 10 none)')
eq(U.check(p,base),nil)
view=nil

-- No character (aboard, in a pod): the near kinds are skipped, the rest still read.
local riding={index=2,name='sol',surface={name='nauvis'},force={platforms=platforms}}
s.damage={a={id=20,at={x=0,y=0},surface='nauvis',damage=30,hits=1,last=game.tick}}
eq(U.check(riding,U.base(riding)),nil)
s.damage=nil

-- until=alert's filter and its line.
fails(function() U.filter({min_size=0},p) end,'alert min_size is a whole number')
fails(function() U.filter({radius=10},p) end,'alert radius goes with near')
fails(function() U.filter({near={x=1}},p) end,'alert near is {x,y}')
eq(U.filter({},p),nil)
local f=U.filter({near={x=0,y=0},radius=50,min_size=5},p)
eq(f.surface,'nauvis'); eq(f.area.left_top.x,-50); eq(f.area.right_bottom.y,50); eq(f.min_size,5)
eq(U.filter_text(f),'in (-50,-50)-(50,50) on nauvis min_size 5')
f=U.filter({area={left_top={x=10,y=10},right_bottom={x=-10,y=-10}},surface='gleba'},p)
eq(f.area.left_top.x,-10); eq(f.surface,'gleba')
s.damage={a={id=30,seq=11,at={x=300,y=0},surface='nauvis',damage=30,hits=1,size=1,last=game.tick},
  b={id=31,seq=12,at={x=20,y=0},surface='nauvis',damage=30,hits=1,size=1,last=game.tick}}
s.attack_groups={{seq=13,tick=game.tick,size=8,position={x=40,y=40},target={x=30,y=0},surface='nauvis'}}
s.enemy_news={{seq=14,kind='nest_charted',surface='nauvis',position={x=10,y=10},spawners=3}}
eq(U.alert(p,10,nil),'nest charted (10,10), 3 spawners','no filter: the newest')
eq(U.alert(p,10,U.filter({min_size=5},p)),'enemy group of 8 gathered at (40,40) heading for (30,0)')
eq(U.alert(p,10,U.filter({near={x=0,y=0},radius=25,min_size=1},p)),'attack #31 at (20,0)')
eq(U.alert(p,10,U.filter({near={x=0,y=0},radius=25,min_size=9},p)),nil)
eq(U.alert(p,14,nil),nil,'nothing new')
s.damage,s.attack_groups,s.enemy_news=nil,nil,nil

-- In waits.lua: a sleep wakes `urgent` with the line; wake_on_urgent=false opts out; a direct wait_ticks keeps a base.
local function integer(v,d,lo,hi,name) if v==nil then v=d end; assert(type(v)=='number' and v==math.floor(v) and v>=lo and v<=hi,name..' out of range'); return v end
local W=dofile('mod/agent-harness_0.1.0/waits.lua'){state=function() return s end,integer=integer,replace=function() end,
  advance=function() end,clock_mode=function() return 'realtime' end,
  urgent_base=function(q) return U.base(q) end,urgent=function(q,b) return U.check(q,b) end,
  alert_line=function(q,from,flt) return U.alert(q,from,flt) end,alert_filter=function(m,q) return U.filter(m,q) end,
  alert_filter_text=function(flt) return U.filter_text(flt) end}
game.tick=60000
local r=W.handlers.sleep(p,{seconds=600})
has(r.wakes_on,'an urgent alert (attack or enemy group near you')
eq(W.handlers.sleep_check(p,{peek=true}).woke,nil)
game.tick=60100; s.damage={a={id=40,at={x=10,y=10},surface='nauvis',damage=50,hits=2,last=60100}}
r=W.handlers.sleep_check(p,{peek=true}); eq(r.woke,'urgent'); has(r.urgent,'attack on our structures 14 tiles from you')
eq(W.handlers.sleep_check(p,{}).woke,'urgent','the reason sticks')
-- A sleep right after it runs, and the same attack does not wake it again (Haiku, shift17 09:20: "the next sleep
-- repeats it"); told once, again only 5 minutes later and grown.
game.tick=60200; r=W.handlers.sleep(p,{seconds=600}); eq(r['repeat'],nil); eq(r.woke,nil)
s.damage.a.last=60250; s.damage.a.hits=3; game.tick=60260
eq(W.handlers.sleep_check(p,{peek=true}).woke,nil,'the same attack, told already')
game.tick=61000; r=W.handlers.sleep(p,{seconds=600,wake_on_urgent=false})
assert(not r.wakes_on:find('urgent',1,true),r.wakes_on)
game.tick=61100; s.damage={a={id=41,at={x=5,y=5},surface='nauvis',damage=50,hits=2,last=61100}}
eq(W.handlers.sleep_check(p,{peek=true}).woke,nil,'opted out')
fails(function() W.handlers.sleep(p,{seconds=60,wake_on_urgent='no'}) end,'wake_on_urgent must be true or false')
s.damage=nil
W.handlers.wait_ticks(p,{ticks=600}); assert(s.active[1].urgent and s.active[1].urgent.tick==61100,'a direct wait keeps a base')
W.handlers.wait_ticks(p,{ticks=600,wake_on_urgent=false}); eq(s.active[1].urgent,nil)
-- until=alert names its alert; with a filter only a matching one wakes it.
game.tick=62000; s.alert_seq=50
r=W.handlers.sleep(p,{seconds=600,wake_on_urgent=false,condition={['until']='alert',near={x=0,y=0},radius=30,min_size=4}})
eq(r.condition,'alert in (-30,-30)-(30,30) on nauvis min_size 4'); has(r.wakes_on,'a new alert in (-30,-30)-(30,30) on nauvis min_size 4')
s.alert_seq=52; game.tick=62060
s.damage={a={id=50,seq=51,at={x=200,y=0},surface='nauvis',damage=30,hits=1,size=9,last=62060},
  b={id=51,seq=52,at={x=10,y=0},surface='nauvis',damage=30,hits=1,size=1,last=62060}}
eq(W.handlers.sleep_check(p,{peek=true}).woke,nil,'far, or too small')
s.alert_seq=53; s.attack_groups={{seq=53,tick=62070,size=6,position={x=80,y=0},target={x=20,y=0},surface='nauvis'}}
game.tick=62080; r=W.handlers.sleep_check(p,{peek=true})
eq(r.woke,'alert'); eq(r.alert,'enemy group of 6 gathered at (80,0) heading for (20,0)')
-- With urgent wakes on (the default) the same group, heading for a spot 20 tiles away, wakes it first as urgent.
game.tick=62200; s.alert_seq=53
W.handlers.sleep(p,{seconds=600,condition={['until']='alert',near={x=0,y=0},radius=30,min_size=4}})
s.attack_groups[2]={seq=54,tick=62210,size=7,position={x=80,y=10},target={x=25,y=0},surface='nauvis'}; s.alert_seq=54
game.tick=62220; r=W.handlers.sleep_check(p,{peek=true}); eq(r.woke,'urgent'); has(r.urgent,'enemy group of 7'); has(r.urgent,'heading for (25,0), 25 tiles from you')
game.tick=63000; s.alert_seq=60; s.attack_groups=nil; s.damage=nil
r=W.handlers.sleep(p,{seconds=600,wake_on_urgent=false,condition={['until']='alert',min_size=4}})
s.alert_seq=61; s.attack_groups={{seq=61,tick=63010,size=6,position={x=800,y=0},target={x=700,y=0},surface='nauvis'}}
game.tick=63020; r=W.handlers.sleep_check(p,{peek=true}); eq(r.woke,'alert'); eq(r.alert,'enemy group of 6 gathered at (800,0) heading for (700,0)')
-- A plain alert names it too.
game.tick=64000; s.alert_seq=70; s.attack_groups=nil
W.handlers.sleep(p,{seconds=600,wake_on_urgent=false,condition={['until']='alert'}})
s.alert_seq=71; s.damage={a={id=60,seq=71,at={x=900,y=0},surface='nauvis',damage=30,hits=1,last=64010}}
game.tick=64020; r=W.handlers.sleep_check(p,{peek=true}); eq(r.woke,'alert'); eq(r.alert,'attack #60 at (900,0)')
fails(function() W.handlers.sleep(p,{seconds=60,condition={['until']='any',conditions={{['until']='alert'},{['until']='alert',min_size=3}}}}) end,'one plain alert condition per sleep')
print('urgent: ok')
