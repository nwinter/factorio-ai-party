-- Run from repository root: lua tests/danger.lua
-- danger (danger.lua; Opus, shift17 10:51: died twice walking to sites next to nests): a destination's worms and
-- spawners with their reach, enemy units seen now, attacks, losses, groups and deaths there, the nests the straight
-- line passes within reach of, and the character's health, armor and shield. Facts only: no verdict words.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,t) assert(s:find(t,1,true),s..' lacks '..t) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
game={tick=100000}
defines={inventory={character_armor=5}}
local force={name='player',get_friend=function() return false end,get_cease_fire=function() return false end,
  is_chunk_visible=function(_,c) return c.x>=10 end}
game.forces={player=force,enemy={name='enemy'},neutral={name='neutral'}}
local st={damage={a={id=7,at={x=330,y=10},surface='nauvis',last=100000-1800,damage=40,hits=3}},
  losses={{id=3,surface='nauvis',box={340,0,344,4},last=100000-600,total=4,names={['gun-turret']=3,['small-electric-pole']=1}}},
  attack_groups={{seq=1,tick=100000-300,size=9,target={x=335,y=5},surface='nauvis',position={x=380,y=0}}},
  chronicle={events={{kind='death',agent='opus',surface='nauvis',position={x=345,y=-5},tick=99000,game_time='60h28m',by='big-spitter'}}}}
local structures={{x=360,y=0,name='big-spitter-spawner',spawner=true},{x=352,y=10,name='big-worm-turret'},{x=200,y=25,name='medium-worm-turret'}}
local avoid={structures=function(_,_,chunks,budget) return {list=structures,uncharted=1,unread=0} end,
  reach=function(name,spawner) return spawner and 40 or (name=='big-worm-turret' and 48 or 30) end,
  chunks_near=function() return {{1,1,1}} end,
  seg_dist=function(a,b,q) return math.abs(q.y-a.y) end}
local units={{name='big-spitter',position={x=350,y=4}},{name='big-spitter',position={x=356,y=6}},{name='medium-biter',position={x=300,y=0}}}
local surface={name='nauvis',find_entities_filtered=function(f) eq(f.type,'unit'); eq(f.force[1],'enemy'); assert(f.limit); return units end}
local grid={shield=120,max_shield=150}
local char={valid=true,surface=surface,position={x=0,y=0},health=230,max_health=250,grid=grid,
  get_inventory=function() return {[1]={valid_for_read=true,name='modular-armor'}} end}
local p={force=force,surface=surface,character=char}
local D=dofile('mod/agent-harness_0.1.0/danger.lua'){state=function() return st end,position=function(v) return {x=v.x,y=v.y} end,avoid=avoid,
  surface=function() return surface end}
local r=D.read(p,{position={x=340,y=0}})
eq(r.distance,340); eq(r.spawners['big-spitter-spawner'],1); eq(r.worms['big-worm-turret'],1); eq(r.units['big-spitter'],2)
has(r.line,'(340,0) on nauvis, 340 tiles from you')
has(r.line,'spawners within 64 tiles: 1 big-spitter-spawner; nearest big-spitter-spawner at (360,0), 20 tiles from it (its units see 40 tiles)')
has(r.line,'worms within 64 tiles: 1 big-worm-turret (big-worm-turret range 48); nearest big-worm-turret at (352,10), 16 tiles from it')
-- (the medium biter at x 300 stands in a chunk our force does not see now: not counted)
has(r.line,'enemy units seen now within 64 tiles: 2 big-spitter; nearest big-spitter 11 tiles from it')
has(r.line,'not read: 1 uncharted chunk')
has(r.line,'attacks on our structures within 64 tiles in the last 10 min: 1; latest 30s ago at (330,10)')
has(r.line,'buildings lost within 64 tiles in the last 10 min: 4 (3 gun-turret, 1 small-electric-pole)')
has(r.line,'enemy groups gathered heading within 64 tiles in the last 10 min: 9 enemies')
has(r.line,'deaths of ours within 64 tiles: 1: opus 60h28m (big-spitter)')
has(r.line,'the straight line from you passes within reach of 1 worm or spawner outside that radius; closest medium-worm-turret at (200,25), 25 tiles from the line (reach 30)')
has(r.line,'you: health 230/250, armor modular-armor, shield 120/150')
eq(r.you.armor,'modular-armor'); eq(r.you.shield,120)
-- Facts only.
for _,w in ipairs({'safe','die','dangerous','should','avoid going','recommend'}) do assert(not r.line:lower():find(w,1,true),w) end
-- Chunks not in sight: their units are not read, and it says so.
force.is_chunk_visible=function() return false end
r=D.read(p,{position={x=340,y=0},radius=32})
has(r.line,'no enemy unit seen now within 32 tiles'); has(r.line,'not in sight of our force now')
fails(function() D.read(p,{position={x=0,y=0},radius=500}) end,'radius is 8..128')
print('danger: ok')
