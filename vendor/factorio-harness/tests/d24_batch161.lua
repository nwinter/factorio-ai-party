-- Run from the harness root: lua tests/d24_batch161.lua
-- d24 batch161 QD1 (Astra #2212): the asteroid watch counted 1 huge-promethium destroyed and 3 big-promethium leaving
-- the view, and its trajectories showed only the first 24 asteroids, all common. The read now lists every tracked
-- asteroid's record (first and last tick and position, outcome, the turret that destroyed it, the turrets that hit it;
-- points for the first 24 only), the rarest names first by the watch's own counts, a page at a time, filtered by
-- asteroid_names (names or patterns with *), with the untracked of a filtered name counted; a done watch keeps them.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
local function fails(f,x) local ok,e=pcall(f); assert(not ok,'should fail: '..x); has(e,x) end
game={tick=1000}
defines={inventory={turret_ammo=1}}
local box={collision_box={left_top={x=-1,y=-1},right_bottom={x=1,y=1}}}
prototypes={entity={['medium-carbonic-asteroid']=box,['huge-promethium-asteroid']=box,['big-promethium-asteroid']=box,['small-metallic-asteroid']=box}}
local function foundation(x,y) return x>=0 and x<=19 and y>=0 and y<=39 end
local surface={index=7,name='platform-7',platform={name='Probe6'}}
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
local function turret(u,x,y)
  local t={valid=true,unit_number=u,name='gun-turret',type='ammo-turret',position={x=x,y=y},surface=surface,force={name='player'},ammo=10}
  t.get_inventory=function() return {get_item_count=function() return t.ammo end} end
  return t
end
local t1,t2=turret(900,5,2),turret(901,15,2)
surface.find_entities_filtered=function(f)
  if f.type=='asteroid' then local out={}; for _,e in pairs(asts) do if e.valid then out[#out+1]=e end end; table.sort(out,function(a,b) return a.unit_number<b.unit_number end); return out end
  return {t1,t2}
end
local A=require('asteroidwatch'){state=api.state,on_platform=api.on_platform}
A.MAX_ASTEROIDS=29
A.handler({index=1},{platform='Probe6',asteroids=true,seconds=10})
-- 26 common first (the first 24 get points), then a huge promethium and two big ones (tracked, no points), then two
-- more big promethium past the cap of 29 (untracked)
for u=1,26 do asteroid(u,'medium-carbonic-asteroid',1+u*0.5,-30) end
asteroid(27,'huge-promethium-asteroid',-10,-20); asteroid(28,'big-promethium-asteroid',24,-20); asteroid(29,'big-promethium-asteroid',26,-22)
asteroid(30,'big-promethium-asteroid',28,-22); asteroid(31,'big-promethium-asteroid',30,-22)
A.tick(1000)
for _,e in pairs(asts) do e.position={x=e.position.x,y=e.position.y+7.5} end
game.tick=1015; A.tick(1015)
-- t2 hits the huge one twice and t1 destroys it; t2 hits big 28, which leaves the view; 29 leaves too
A.on_damaged({entity=asts[27],cause=t2,final_damage_amount=300,tick=1016})
A.on_damaged({entity=asts[27],cause=t2,final_damage_amount=300,tick=1017})
A.on_damaged({entity=asts[27],cause=t1,final_damage_amount=400,tick=1018})
A.on_died({entity=asts[27],cause=t1,tick=1018}); asts[27].valid=false
A.on_damaged({entity=asts[28],cause=t2,final_damage_amount=90,tick=1019})
asts[28].valid=false; asts[29].valid=false
game.tick=1030; A.tick(1030)

-- the default read: every tracked asteroid, the rarest name first (huge 1 seen, big 4, carbonic 26)
local r=A.handler({index=1},{platform='Probe6',asteroids=true})
eq(r.tracked,29); eq(r.untracked,2)
local tp=r.trajectory_page
eq(tp.total,29); eq(tp.per_page,24); eq(tp.pages,2); eq(tp.returned,24); eq(tp.next,2)
has(tp.order,'the rarest names first by this watch\'s by_name seen counts')
eq(r.trajectories[1].name,'huge-promethium-asteroid'); eq(r.trajectories[2].name,'big-promethium-asteroid'); eq(r.trajectories[4].name,'medium-carbonic-asteroid')
local h=r.trajectories[1]
eq(h.first_tick,1000); eq(h.last_tick,1018); eq(h.first_position.x,-10); eq(h.first_position.y,-20); eq(h.last_position.y,-12.5)
eq(h.outcome,'destroyed'); eq(h.by,'gun-turret (5,2)'); eq(h.points,nil,'no points past the first 24')
eq(h.hit_by[1].turret,'gun-turret (15,2)'); eq(h.hit_by[1].hits,2); eq(h.hit_by[1].damage,600); eq(h.hit_by[2].turret,'gun-turret (5,2)'); eq(h.hit_by[2].killed,true)
local b=r.trajectories[2]
eq(b.outcome,'left_view'); eq(b.hit_by[1].hits,1); eq(b.last_tick,1015)
eq(#r.trajectories[4].points,1)  -- a carbonic of the first 24: its samples
has(r.trajectory_note,'points (one a second, up to 16) only for the first 24 tracked')
-- page 2: the last 5 carbonic
local r2=A.handler({index=1},{platform='Probe6',asteroids=true,trajectory_page=2})
eq(r2.trajectory_page.returned,5); eq(r2.trajectory_page.from,25); eq(r2.trajectory_page.next,nil)

-- a pattern: the three tracked promethium, and the two big ones past the cap counted
local f=A.handler({index=1},{platform='Probe6',asteroids=true,asteroid_names={'*promethium*'}})
eq(f.trajectory_page.total,3); eq(f.trajectory_page.filter,'*promethium*')
eq(f.trajectory_untracked[1].name,'big-promethium-asteroid'); eq(f.trajectory_untracked[1].untracked,2)
has(f.trajectory_untracked_lines[1],'big-promethium-asteroid: 2 past the 29 tracked: in by_name (seen, destroyed, hit, left the view), no record or trajectory')
-- a name, one a page
local g=A.handler({index=1},{platform='Probe6',asteroids=true,asteroid_names={'big-promethium-asteroid'},trajectory_limit=1,trajectory_page=2})
eq(g.trajectory_page.total,2); eq(g.trajectory_page.pages,2); eq(#g.trajectories,1); eq(g.trajectories[1].first_position.x,26)
-- a name with none tracked
local n=A.handler({index=1},{platform='Probe6',asteroids=true,asteroid_names={'small-metallic-asteroid'}})
eq(n.trajectory_page.total,0); has(n.trajectory_page.line,'no tracked asteroid matches small-metallic-asteroid in this watch')
-- refused
fails(function() A.handler({index=1},{platform='Probe6',asteroids=true,asteroid_names={'big-asteroid'}}) end,'unknown asteroid big-asteroid (big-promethium-asteroid, huge-promethium-asteroid')
fails(function() A.handler({index=1},{platform='Probe6',asteroids=true,asteroid_names={'*rubber*'}}) end,'*rubber* matches no asteroid name')
fails(function() A.handler({index=1},{platform='Probe6',asteroids=true,trajectory_limit=0}) end,'trajectory_limit: 1..100')
fails(function() A.handler({index=1},{platform='Probe6',asteroids=true,asteroid_names={}}) end,'asteroid_names: 1..16')
fails(function() A.handler({index=2},{platform='Probe6',asteroids=true,seconds=10,asteroid_names={'*promethium*'}}) end,'asteroid_names is for the read')

-- done: the records are kept (and who hit which), the filter still reads them
game.tick=1700; A.tick(1700)
local kept=0; for _ in pairs(st.asteroid_watch[1].asts) do kept=kept+1 end
eq(kept,29); eq(st.asteroid_watch[1].turrets,nil); eq(#st.asteroid_watch[1].hitmap[27],2)
local d=A.handler({index=1},{platform='Probe6',asteroids=true,asteroid_names={'huge-promethium-asteroid'}})
eq(d.done,true); eq(d.trajectory_page.total,1); eq(d.trajectories[1].by,'gun-turret (5,2)')
eq(d.trajectories[1].hit_by[1].turret,'gun-turret (15,2)'); eq(d.trajectories[1].hit_by[1].hits,2); eq(d.trajectories[1].hit_by[2].killed,true)  -- from the kept map, sorted
eq(st.asteroid_watch[1].result.trajectory_page.filter,nil,'the stored result is not changed by a read')
-- a watch done before the records were kept: its old trajectories, said so
st.asteroid_watch[1].asts=nil
local o=A.handler({index=1},{platform='Probe6',asteroids=true})
has(o.trajectory_note,'this watch ended before every tracked asteroid\'s record was kept')
print('d24_batch161 QD1 asteroid trajectories by name: ok')
