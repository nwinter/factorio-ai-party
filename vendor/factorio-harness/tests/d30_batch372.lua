-- Run from the harness root: lua tests/d30_batch372.lua
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
local function start(filter)
  return A.handler({index=1},{platform='Probe 1161',asteroids=true,seconds=1200,track_filter=filter})
end
local filter={asteroid_names={'huge-promethium-*'},area={{-5,-30},{5,-10}}}
local function run(f)
  st.asteroid_watch=nil; asts={}; game.tick=1000
  local begun=start(f); assert(begun.track_filter and begun.track_scope and begun.scope)
  local u=10000
  for k=0,4800 do
    game.tick=1000+15*k; asts={}
    for j=1,5 do
      u=u+1
      asteroid(u,j==5 and 'huge-promethium-asteroid' or 'medium-carbonic-asteroid',j==5 and (k%4==0 and 0 or 10) or j,-20)
    end
    A.tick(game.tick)
    if k<4800 then
      A.on_damaged{entity=asts[u-4],cause=turret,final_damage_amount=50,tick=game.tick}
      A.on_died{entity=asts[u-4],cause=turret,tick=game.tick}; asts[u-4].valid=false
      A.on_damaged{entity=hub,cause=asts[u-3],final_damage_amount=20,tick=game.tick}
      A.on_died{entity=asts[u-3],tick=game.tick}; asts[u-3].valid=false
      A.on_damaged{entity=asts[u],cause=turret,final_damage_amount=40,tick=game.tick}
      A.on_died{entity=asts[u],cause=turret,tick=game.tick}; asts[u].valid=false
    end
    if f then assert(st.asteroid_watch[1].nast<3000,'filtered watch capped at sample '..k) end
  end
  local out=A.handler({index=1},{platform='Probe 1161',asteroids=true})
  eq(out.done,true); eq(out.asteroids,24005); eq(out.platform_hits_all,4800)
  assert(out.track_filter and out.track_scope)
  local h,kills=0,0
  for _,t in ipairs(out.turrets) do for _,n in pairs(t.hits) do h=h+n end; for _,n in pairs(t.kills) do kills=kills+n end end
  eq(h,9600); eq(kills,9600,'kills include untracked asteroids')
  return out
end
local all=run(nil); eq(all.tracked,3000); eq(all.capped,true); eq(all.track_filter.all,true)
local selected=run(filter); eq(selected.tracked,1201); eq(selected.capped,nil); eq(selected.filtered_out,22804); eq(selected.past_cap,0)
for i,row in ipairs(all.by_name) do
  eq(selected.by_name[i].name,row.name)
  for _,k in ipairs({'seen','hit','destroyed','left_view','in_view','in_first_sample','later','later_fragments','later_other'}) do
    eq(selected.by_name[i][k],row[k],row.name..'.'..k)
  end
end
for _,r in ipairs(selected.trajectories) do eq(r.name,'huge-promethium-asteroid'); eq(r.first_position.x,0) end
has(selected.scope,'global by_name, hits, losses and turret totals include excluded asteroids')
-- Admission is permanent: entering the box later cannot double-count; leaving it does not lose a record.
st.asteroid_watch=nil; asts={}; game.tick=1000; start(filter)
local excluded=asteroid(1,'huge-promethium-asteroid',5,-20)
local included=asteroid(2,'huge-promethium-asteroid',-5,-30)
A.tick(1000); excluded.position.x=0; included.position.x=8; game.tick=1015; A.tick(1015)
local r=A.handler({index=1},{platform='Probe 1161',asteroids=true})
eq(r.asteroids,2); eq(r.tracked,1); eq(r.filtered_out,1); eq(r.trajectories[1].unit,2); eq(r.trajectories[1].last_position.x,8)
-- Event admission between samples, names only and area only.
for _,f in ipairs({{asteroid_names='huge-promethium-asteroid'},{area={left_top={x=-5,y=-30},right_bottom={x=5,y=-10}}}}) do
  st.asteroid_watch=nil; asts={}; game.tick=1000; start(f)
  local e=asteroid(3,'huge-promethium-asteroid',0,-20)
  A.on_damaged{entity=e,cause=turret,tick=1000,final_damage_amount=1}; eq(st.asteroid_watch[1].nast,1)
end
-- Matching asteroids still respect the cap.
A.MAX_ASTEROIDS=2; st.asteroid_watch=nil; asts={}; game.tick=1000; start(filter)
for u=1,3 do asteroid(u,'huge-promethium-asteroid',0,-20) end
A.tick(1000); r=A.handler({index=1},{platform='Probe 1161',asteroids=true})
eq(r.tracked,2); eq(r.past_cap,1); eq(r.filtered_out,0); eq(r.capped,true)
-- Closed segments name their own filter.
local old=st.asteroid_watch[1]; game.tick=1030; start(nil); A.close(old,st.asteroid_watch[1],game.tick,'fixture edit')
r=A.handler({index=1},{platform='Probe 1161',asteroids=true,segment_start=1000})
eq(r.track_filter.asteroid_names[1],'huge-promethium-asteroid'); eq(r.track_filter.area.left_top.x,-5)
-- A completed pre-deploy watch receives explicit unrestricted scope too.
local legacy={result={line='old watch',by_name={}},start=0,until_tick=1}
st.asteroid_watch[1]=legacy
r=A.handler({index=1},{platform='Probe 1161',asteroids=true})
eq(r.track_filter.all,true); has(r.track_scope,'all names')
local function fails(a,part)
  local ok,why=pcall(A.filter_args,a); assert(not ok,'invalid filter accepted'); has(why,part)
end
for _,f in ipairs({{},false,{bad=1},{asteroid_names={}},{asteroid_names='rubber-asteroid'},
  {area={{0,0},{0,1}}},{area={{0,0},{1,math.huge}}},{area={{0,0},{1,0/0}}},{area={{0,0},{1,'2'}}}}) do
  fails({asteroids=true,seconds=1200,track_filter=f},'')
end
fails({asteroids=true,track_filter=filter},'starting an asteroid watch')
fails({seconds=1200,track_filter=filter},'starting an asteroid watch')
print('d30_batch372: 1200 seconds, 24005 global / 1201 tracked, global counters unchanged: ok')
