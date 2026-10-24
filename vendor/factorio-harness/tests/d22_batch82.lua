-- Run from the harness root: lua tests/d22_batch82.lua
-- d22 batch82 AR1 (Astra #1855): platform_defense {platform, asteroids: true, seconds}, the asteroid watch: the hull's box, an asteroid's approach by where its straight line
-- enters it, the projection across foundation tiles, outcomes from the game's events, turrets' hits and kills by class.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
local function fails(f,x) local ok,err=pcall(f); assert(not ok,'did not fail'); has(err,x) end
game={tick=1000}
defines={inventory={turret_ammo=1}}
prototypes={entity={['medium-carbonic-asteroid']={collision_box={left_top={x=-1,y=-1},right_bottom={x=1,y=1}}}}}
-- A hull: foundation x 0..19, y 0..39, with a slot x 8..11 from y 10 to its south edge (empty space)
local function foundation(x,y) return x>=0 and x<=19 and y>=0 and y<=39 and not (x>=8 and x<=11 and y>=10) end
local reads=0
local surface={index=7,name='platform-7'}
function surface.get_chunks()
  local list={{area={left_top={x=0,y=0},right_bottom={x=32,y=32}}},{area={left_top={x=0,y=32},right_bottom={x=32,y=64}}},{area={left_top={x=-32,y=0},right_bottom={x=0,y=32}}}}
  local i=0
  return function() i=i+1; return list[i] end
end
function surface.count_tiles_filtered(f)
  reads=reads+1
  local a=f.area
  local lt,rb=a.left_top or a[1],a.right_bottom or a[2]
  local x0,y0,x1,y1=lt.x or lt[1],lt.y or lt[2],rb.x or rb[1],rb.y or rb[2]
  for x=math.floor(x0),math.ceil(x1)-1 do for y=math.floor(y0),math.ceil(y1)-1 do if foundation(x,y) then return 1 end end end
  return 0
end
function surface.get_tile(x,y) return {name=foundation(x,y) and 'space-platform-foundation' or 'empty-space'} end
local W=require('asteroidwatch'){state=function() return {} end}
local hull=W.hull(surface)
eq(hull.x0,0); eq(hull.y0,0); eq(hull.x1,20); eq(hull.y1,40)
-- approach: where the line enters the box (the platform faces north)
local _,_,edge=W.enter(hull,{x=5,y=-20},{x=0,y=0.5}); eq(edge,'north')
_,_,edge=W.enter(hull,{x=-10,y=20},{x=0.5,y=0}); eq(edge,'west')
eq(W.enter(hull,{x=-10,y=-20},{x=0,y=0.5}),nil,'a line west of the hull never enters its box')
-- projections: straight down at x=5 crosses foundation at the top edge; down the hole's middle (x=10, small) misses
local cells={}
local pj=W.project(surface,hull,nil,{x=5.5,y=-20},{x=0,y=0.5},1,nil,cells)
eq(pj.approach,'front'); eq(pj.crosses,true); eq(pj.at.y,0.5); eq(pj.eta_s,0.7)
pj=W.project(surface,hull,nil,{x=10,y=12},{x=0,y=0.5},0.2,nil,cells)
eq(pj.approach,'side'); eq(pj.crosses,false,'down the slot, inside the box')
pj=W.project(surface,hull,nil,{x=10,y=-20},{x=0,y=0.5},0.2,nil,cells)
eq(pj.approach,'front'); eq(pj.crosses,true,'from the north it meets the top rows first')
pj=W.project(surface,hull,nil,{x=-10,y=-20},{x=0,y=0.5},1,true,cells)
eq(pj.approach,'clear'); eq(pj.crosses,false); eq(pj.assumed,true)
-- a medium asteroid (radius 1) passing 0.5 tiles west of the hull's edge: its width meets foundation
pj=W.project(surface,hull,nil,{x=-0.5,y=-20},{x=0,y=0.5},1,nil,cells)
eq(pj.crosses,true,'as wide as the asteroid')
-- the watch: samples, events, result
local st={}
local api={state=function() return st end,on_platform=function() return {surface=surface,force={name='player'}} end}
surface.platform={name='Asterion'}
game.get_surface=function(i) return i==7 and surface or nil end
local asts={}
local function asteroid(u,x,y) local e={valid=true,unit_number=u,name='medium-carbonic-asteroid',type='asteroid',surface=surface,position={x=x,y=y}}; asts[u]=e; return e end
local turret={valid=true,unit_number=900,name='gun-turret',type='ammo-turret',position={x=-1,y=2},surface=surface,force={name='player'},
  ammo=10}
turret.get_inventory=function() return {get_item_count=function() return turret.ammo end} end
local hub={valid=true,unit_number=901,name='space-platform-hub',type='space-platform-hub',position={x=5,y=2},surface=surface,force={name='player'}}
surface.find_entities_filtered=function(f)
  if f.type=='asteroid' then local out={}; for _,e in pairs(asts) do if e.valid then out[#out+1]=e end end; table.sort(out,function(a,b) return a.unit_number<b.unit_number end); return out end
  return {turret}
end
local A=require('asteroidwatch'){state=api.state,on_platform=api.on_platform}
fails(function() A.handler({index=1},{platform='Asterion',asteroids=true,seconds=5}) end,'seconds: 10..1800')
fails(function() A.handler({index=1},{platform='Asterion',asteroids=true}) end,'no asteroid watch of yours yet')
local start=A.handler({index=1},{platform='Asterion',asteroids=true,seconds=10})
eq(start.turrets,1); has(start.line,'foundation box (0,0)-(20,40)')
-- 3 asteroids: 1 heads down x=5 (crosses), 2 passes west of the hull (clear), 3 heads for the hub
asteroid(1,5.5,-20); asteroid(2,-10,-20); asteroid(3,5.5,-6)
A.tick(1000)
for _,e in pairs(asts) do e.position={x=e.position.x,y=e.position.y+7.5} end
game.tick=1015; A.tick(1015)
-- the turret shoots asteroid 2 (clear) twice and destroys it; asteroid 3 hits the hub; asteroid 1 is destroyed by it too
A.on_damaged({entity=asts[2],cause=turret,final_damage_amount=50,tick=1016})
A.on_damaged({entity=asts[2],cause=turret,final_damage_amount=50,tick=1017})
A.on_died({entity=asts[2],cause=turret,tick=1017}); asts[2].valid=false
A.on_damaged({entity=hub,cause=asts[3],final_damage_amount=120,tick=1018})
A.on_died({entity=asts[3],tick=1018}); asts[3].valid=false
A.on_damaged({entity=asts[1],cause=turret,final_damage_amount=400,tick=1019})
A.on_died({entity=asts[1],cause=turret,tick=1019}); asts[1].valid=false
turret.ammo=8
game.tick=1075; A.tick(1030); A.tick(1045); A.tick(1060); A.tick(1075)
local r=A.handler({index=1},{platform='Asterion',asteroids=true})
eq(r.asteroids,3); eq(r.platform_hits,1)
local by={}
for _,c in ipairs(r.classes) do by[c.class]=c end
eq(by['front/crosses'].seen,2); eq(by['front/crosses'].destroyed,1); eq(by['front/crosses'].hit,1)
eq(by.clear.seen,1); eq(by.clear.destroyed,1); eq(by.clear.destroyed_by['gun-turret'],1)
has(table.concat(r.class_lines,' | '),'clear (its line never enters the hull\'s box): 1 seen, 1 destroyed (by gun-turret 1), 0 hit the platform')
has(r.platform_hit_lines[1],'medium-carbonic-asteroid hit space-platform-hub (5,2)')
has(r.platform_hit_lines[1],'approach front; projected: crosses foundation at (5.5,0.5)')
local t=r.turrets[1]
eq(t.hits.clear,2); eq(t.kills.clear,1); eq(t.hits['front/crosses'],1); eq(t.kills['front/crosses'],1); eq(t.damage,500); eq(t.ammo_used,2)
has(r.turret_group_lines[1],'gun-turret x1 (front west of the hull): 3 hits, 2 kills, 500 damage, 2 ammo used; on asteroids clear of the hull\'s box 2 hits and 1 kills')
eq(#r.trajectories,3); eq(r.trajectories[1].outcome,'destroyed')
eq(r.drift_tiles_per_s.y,30)
-- the end: the result is kept, the turrets let go; (d24 batch161) the asteroids' records stay for filtered reads
game.tick=1000+600; A.tick(1600)
local done=A.handler({index=1},{platform='Asterion',asteroids=true})
eq(done.done,true); eq(st.asteroid_watch[1].turrets,nil); assert(st.asteroid_watch[1].asts and st.asteroid_watch[1].hitmap)
print('d22_batch82 AR1 asteroid_watch: ok')
