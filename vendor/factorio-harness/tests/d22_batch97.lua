-- Run from repository root: lua tests/d22_batch97.lua
-- d22 batch97 BG3 cp2 (Nick asked for a map like the Galaxy of Fame's): chart.lua, the operator read the stream draws
-- the site's chart from. The dirty set marks a chunk on a forwarded event (built by hand, mined, died; an enemy unit's
-- death and ghosts not), `check` marks one whose entity count changed since it was read (robot builds: control.lua
-- forwards no on_robot_built_entity), `dirty` reads the marked chunks oldest first and at most once per min_age,
-- `chunks` reads given ones, `list` says which chunks are charted, `surfaces` and `protos` list surfaces and colours.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
defines={events={on_built_entity=1,on_player_mined_entity=2,on_robot_mined_entity=3,on_entity_died=4}}
local player,enemy,neutral={name='player'},{name='enemy'},{name='neutral'}
local ents={}
local NAUVIS
local function ent(name,t,x,y,force,extra)
  local e={valid=true,name=name,type=t,position={x=x,y=y},force=force or player,direction=0,surface=NAUVIS}
  for k,v in pairs(extra or {}) do e[k]=v end
  ents[#ents+1]=e
  return e
end
local function inside(e,a) local p=e.position return p.x>=a[1][1]-1 and p.x<a[2][1]+1 and p.y>=a[1][2]-1 and p.y<a[2][2]+1 end
local finds,counts=0,0
local nauvis={name='nauvis',index=1,planet={name='nauvis'}}
local function filtered(f)
  local skip={}
  for _,t in ipairs(f.type or {}) do skip[t]=true end
  local out={}
  for _,e in ipairs(ents) do
    if e.valid and inside(e,f.area) and (not f.invert or not skip[e.type]) then out[#out+1]=e end
  end
  return out
end
function nauvis.find_entities_filtered(f) finds=finds+1 return filtered(f) end
function nauvis.count_entities_filtered(f) counts=counts+1 return #filtered(f) end
function nauvis.get_tile(x,y) return {name=(x<8 and 'water') or (y>=40 and 'concrete') or 'grass-1'} end
NAUVIS=nauvis
local deck={name='platform-3',index=5,platform={valid=true,name='Asterion'}}
local uncharted={['2,0']=true}
player.is_chunk_charted=function(s,c) return not uncharted[c[1]..','..c[2]] end
game={tick=100000,surfaces={nauvis=nauvis,['platform-3']=deck},forces={player=player}}
prototypes={entity={['stone-furnace']={type='furnace',collision_box={left_top={x=-0.9,y=-0.9},right_bottom={x=0.9,y=0.9}},
  friendly_map_color={r=0,g=96/255,b=145/255},enemy_map_color={r=1,g=0,b=0}},
  ['iron-ore']={type='resource',collision_box={left_top={x=-0.4,y=-0.4},right_bottom={x=0.4,y=0.4}},map_color={r=0.41,g=0.53,b=0.62},
    friendly_map_color={r=0,g=96/255,b=145/255},enemy_map_color={r=1,g=0,b=0}},
  ['small-biter']={type='unit'}},
  tile={water={map_color={r=51,g=83,b=95}},['grass-1']={map_color={r=55/255,g=53/255,b=11/255}}}}
local st={}
local C=dofile('mod/agent-harness_0.1.0/chart.lua'){state=function() return st end}
local read=C.operator.chart
-- a world: two furnaces in chunk (0,0), ore in (1,0), a train stop, chunk (2,0) not charted
local f1=ent('stone-furnace','furnace',4,4,player,{get_recipe=function() return {name='iron-plate'} end})
ent('stone-furnace','furnace',20,20,player,{get_recipe=function() return nil end,direction=4})
ent('iron-ore','resource',40.5,10.5,neutral)
ent('train-stop','train-stop',50,20,player,{backer_name='Ore\nnorth',direction=8})
ent('small-biter','unit',6,6,enemy)
ent('construction-robot','construction-robot',7,7,player)
-- surfaces and protos
local r=read{surfaces=true}
eq(#r.surfaces,2); eq(r.surfaces[1].name,'nauvis'); eq(r.surfaces[2].platform,'Asterion')
r=read{protos=true}
assert(r.protos:find('E stone-furnace furnace 2 2 006091 ff0000 -',1,true),r.protos)
assert(r.protos:find('E iron-ore resource 1 1 006091 ff0000 69879e',1,true),r.protos)
assert(r.protos:find('T water 33535f',1,true) and r.protos:find('T grass-1 37350b',1,true),r.protos)
assert(not r.protos:find('small-biter',1,true),'units are left out')
fails(function() read{surface='nowhere',dirty=1} end,'surface must name a surface')
fails(function() read{surface='nauvis'} end,'chart takes surfaces, protos, or a surface with list, chunks or dirty')
-- list: chunks charted in a box
r=read{surface='nauvis',list={0,0,2,1}}
eq(r.rows[1],'110'); eq(r.rows[2],'111'); eq(r.charted,5)
fails(function() read{surface='nauvis',list={0,0,64,64}} end,'list covers at most 4096 chunks')
-- chunks: rows for given chunks
r=read{surface='nauvis',chunks={0,0,1,0,2,0}}
eq(r.chunks,3); eq(r.rest,0)
local rows={}
for l in r.rows:gmatch('[^\n]+') do rows[#rows+1]=l end
eq(rows[1],'C 0 0')
local tn={} for n in r.tn:gmatch('%S+') do tn[#tn+1]=n end
local en={} for n in r.en:gmatch('%S+') do en[#en+1]=n end
eq(tn[1],'water'); eq(tn[2],'grass-1')
assert(rows[2]:sub(1,10)=='T 1,8 2,24','tiles run-length from the left: '..rows[2]:sub(1,40))
local _,bars=rows[2]:gsub('|','') eq(bars,31,'32 tile rows')
eq(rows[3],'E 1 8 8 0 1','furnace at (4,4) in half tiles, ours')
eq(rows[4],'E 1 40 40 4 1','the second furnace, east')
eq(rows[5],'R 8 8 iron-plate','a recipe; none for the idle one')
eq(rows[6],'C 1 0')
assert(r.rows:find('E 2 81 21 0 0',1,true),'the ore, neutral')
assert(r.rows:find('S 100 40 Ore north',1,true),'the stop, its name on one line')
assert(r.rows:find('U 2 0',1,true),'a chunk not charted')
assert(not r.rows:find('small-biter',1,true) and not r.rows:find('construction',1,true),'units and robots left out')
assert(r.rows:find('C 1 0\nT ',1,true))
eq(r.entities,4)
-- the dirty set: a hand build marks its chunk; a ghost, a unit's death do not
game.tick=110000
C.mark({name=1,tick=110000,entity={valid=true,type='entity-ghost',position={x=70,y=70},surface=nauvis}})
C.mark({name=4,tick=110000,entity={valid=true,type='unit',position={x=6,y=6},surface=nauvis}})
r=read{surface='nauvis',dirty=8,min_age=0}
eq(r.chunks,0); eq(r.rest,0)
local f3=ent('stone-furnace','furnace',10,30,player,{get_recipe=function() return {name='copper-plate'} end})
C.mark({name=1,tick=110000,entity=f3})
-- read at 100000 and marked at 110000: not yet 10 game minutes since the read
r=read{surface='nauvis',dirty=8}
eq(r.chunks,0); eq(r.waiting,1)
game.tick=136001
r=read{surface='nauvis',dirty=8}
eq(r.chunks,1); eq(r.waiting,0)
assert(r.rows:find('R 20 60 copper-plate',1,true),r.rows)
r=read{surface='nauvis',dirty=8,min_age=0}
eq(r.chunks,0,'a read clears its mark')
-- a robot build (no event): the check finds the changed count
ent('stone-furnace','furnace',44,4,player,{get_recipe=function() return nil end})
game.tick=200000
local before=counts
r=read{surface='nauvis',dirty=8,check=8}
eq(r.checked,3,'three chunks read so far'); eq(r.marked,1); eq(r.chunks,1)
assert(r.rows:find('C 1 0',1,true))
eq(counts-before,2,'one count a charted chunk read before')
-- removed: the furnace mined marks its chunk; oldest mark first
game.tick=300000
f1.valid=false
C.mark({name=2,tick=299000,entity={valid=true,type='furnace',position={x=4,y=4},surface=nauvis}})
C.mark({name=4,tick=298000,entity={valid=true,type='tree',position={x=40,y=4},surface=nauvis}})
r=read{surface='nauvis',dirty=1}
eq(r.chunks,1); eq(r.rest,1); assert(r.rows:find('^C 1 0'),'the older mark first: '..r.rows:sub(1,10))
r=read{surface='nauvis',dirty=1}
assert(r.rows:find('^C 0 0') and not r.rows:find('E 1 8 8',1,true),'the mined furnace is gone')
-- the entity budget: at least one chunk, then stop
C.MAX_ENTITIES=1
r=read{surface='nauvis',chunks={0,0,1,0}}
eq(r.chunks,1); eq(r.rest,1)
C.MAX_ENTITIES=1200
-- keys round-trip far from the origin
local cx,cy=C.unkey(C.key(-1234,567)) eq(cx,-1234); eq(cy,567)
print('d22 batch97 chart: ok')
