-- Run from the harness root: lua tests/d23_batch133.lua
-- d23 batch133 PE1 (Sol #2094): the asteroid watch's totals by asteroid name, tracked or not; the tracked cap, the
-- untracked counted once an asteroid (it was counted at every sighting and event), and the scope of the classes.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
game={tick=1000}
defines={inventory={turret_ammo=1}}
local box={collision_box={left_top={x=-1,y=-1},right_bottom={x=1,y=1}}}
prototypes={entity={['medium-carbonic-asteroid']=box,['huge-promethium-asteroid']=box,['small-metallic-asteroid']=box}}
local function foundation(x,y) return x>=0 and x<=19 and y>=0 and y<=39 end
local surface={index=7,name='platform-7',platform={name='Probe 1161'}}
function surface.get_chunks()
  local list={{area={left_top={x=0,y=0},right_bottom={x=32,y=32}}},{area={left_top={x=0,y=32},right_bottom={x=32,y=64}}}}
  local i=0
  return function() i=i+1; return list[i] end
end
function surface.count_tiles_filtered(f)
  local a=f.area
  local lt,rb=a.left_top or a[1],a.right_bottom or a[2]
  local x0,y0,x1,y1=lt.x or lt[1],lt.y or lt[2],rb.x or rb[1],rb.y or rb[2]
  for x=math.floor(x0),math.ceil(x1)-1 do for y=math.floor(y0),math.ceil(y1)-1 do if foundation(x,y) then return 1 end end end
  return 0
end
function surface.get_tile(x,y) return {name=foundation(x,y) and 'space-platform-foundation' or 'empty-space'} end
game.get_surface=function(i) return i==7 and surface or nil end
local st={}
local api={state=function() return st end,on_platform=function() return {surface=surface,force={name='player'}} end}
local asts={}
local function asteroid(u,name,x,y) local e={valid=true,unit_number=u,name=name,type='asteroid',surface=surface,position={x=x,y=y}}; asts[u]=e; return e end
local turret={valid=true,unit_number=900,name='gun-turret',type='ammo-turret',position={x=5,y=2},surface=surface,force={name='player'},ammo=10}
turret.get_inventory=function() return {get_item_count=function() return turret.ammo end} end
local hub={valid=true,unit_number=901,name='space-platform-hub',type='space-platform-hub',position={x=5,y=2},surface=surface,force={name='player'}}
surface.find_entities_filtered=function(f)
  if f.type=='asteroid' then local out={}; for _,e in pairs(asts) do if e.valid then out[#out+1]=e end end; table.sort(out,function(a,b) return a.unit_number<b.unit_number end); return out end
  return {turret}
end
local A=require('asteroidwatch'){state=api.state,on_platform=api.on_platform}
A.MAX_ASTEROIDS=2
A.handler({index=1},{platform='Probe 1161',asteroids=true,seconds=10})
-- 2 tracked (a carbonic, a huge promethium), 4 past the cap (2 huge promethium, a carbonic, a small metallic)
asteroid(1,'medium-carbonic-asteroid',5.5,-20); asteroid(2,'huge-promethium-asteroid',-10,-20)
asteroid(3,'huge-promethium-asteroid',12,-25); asteroid(4,'huge-promethium-asteroid',14,-25)
asteroid(5,'medium-carbonic-asteroid',16,-25); asteroid(6,'small-metallic-asteroid',18,-25)
A.tick(1000)
for _,e in pairs(asts) do e.position={x=e.position.x,y=e.position.y+7.5} end
game.tick=1015; A.tick(1015)
-- each sample sees the untracked again: counted once each
eq(st.asteroid_watch[1].untracked,4,'before: 8 (two sightings each)')
-- the turret destroys tracked 2 and untracked 3; untracked 5 hits the hub; untracked 6 leaves the view
A.on_damaged({entity=asts[2],cause=turret,final_damage_amount=50,tick=1016})
A.on_died({entity=asts[2],cause=turret,tick=1016}); asts[2].valid=false
A.on_damaged({entity=asts[3],cause=turret,final_damage_amount=50,tick=1017})
A.on_died({entity=asts[3],cause=turret,tick=1017}); asts[3].valid=false
A.on_damaged({entity=hub,cause=asts[5],final_damage_amount=120,tick=1018})
A.on_died({entity=asts[5],tick=1018}); asts[5].valid=false
asts[6].valid=false
game.tick=1030; A.tick(1030)
local r=A.handler({index=1},{platform='Probe 1161',asteroids=true})
eq(r.asteroids,6); eq(r.tracked,2); eq(r.tracked_cap,2); eq(r.untracked,4)
local by={}
for _,t in ipairs(r.by_name) do by[t.name]=t end
eq(r.by_name[1].name,'huge-promethium-asteroid','the most seen first')
local hp=by['huge-promethium-asteroid']
eq(hp.seen,3); eq(hp.untracked,2); eq(hp.destroyed,2); eq(hp.hit,0); eq(hp.in_view,1); eq(hp.left_view,0)
local mc=by['medium-carbonic-asteroid']
eq(mc.seen,2); eq(mc.untracked,1); eq(mc.destroyed,0); eq(mc.hit,1); eq(mc.in_view,1)
local sm=by['small-metallic-asteroid']
eq(sm.seen,1); eq(sm.left_view,1); eq(sm.in_view,0)
eq(by['medium-carbonic-asteroid'].seen+hp.seen+sm.seen,r.asteroids,'every asteroid in by_name')
has(table.concat(r.by_name_lines,' | '),'huge-promethium-asteroid: 3 seen (2 untracked), 2 destroyed, 0 hit the platform, 0 left the view, 1 still in view')
has(r.scope,'by_name counts every asteroid seen in view (6); classes, platform_hits, the turrets\' kills by class and trajectories cover the tracked ones (the first 2 seen: 2), untracked: 4')
has(r.scope,'asteroid chunks are not entities: this watch does not see them')
has(r.line,'6 asteroids seen in view, 4 of them past the 2 tracked')
-- the classes keep to the tracked
local n=0
for _,c in ipairs(r.classes) do n=n+c.seen end
eq(n,2)
-- a watch begun before these counts: the untracked counts start empty
st.asteroid_watch[1].untr=nil
asteroid(7,'small-metallic-asteroid',3,-20)
game.tick=1045; A.tick(1045)
eq(st.asteroid_watch[1].useen['small-metallic-asteroid'],1)
print('d23_batch133 PE1 asteroid_watch by name: ok')
