-- Run from the harness root: lua tests/d25_batch200.lua
-- d25 batch200 QM1 (Astra #2292): a laser destroyed mid-watch restarted the asteroid watch (mixed.lua) and only the
-- summary line of the read before it was left. The watch an edit closes is now done at the edit with its full result
-- and records and kept on the new watch as a segment (at most 3), read by its start tick (segment_start); turret rows
-- give range (prototype range times the quality's range_multiplier), min_range, turn_range and facing.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
local function fails(f,x) local ok,e=pcall(f); assert(not ok,'should fail: '..x); has(e,x) end
game={tick=1000}
defines={inventory={turret_ammo=1},direction={north=0,east=4,south=8,west=12}}
local box={collision_box={left_top={x=-1,y=-1},right_bottom={x=1,y=1}}}
prototypes={entity={['medium-carbonic-asteroid']=box}}
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
local asts={}
local function asteroid(u,x,y) local e={valid=true,unit_number=u,name='medium-carbonic-asteroid',type='asteroid',surface=surface,position={x=x,y=y}}; asts[u]=e; return e end
local player_force={name='player'}
local function turret(u,name,x,y,quality,ap)
  local t={valid=true,unit_number=u,name=name,type=name=='laser-turret' and 'electric-turret' or 'ammo-turret',position={x=x,y=y},surface=surface,force=player_force,
    quality=quality,prototype={attack_parameters=ap},direction=defines.direction.east,bounding_box={left_top={x=x-1,y=y-1},right_bottom={x=x+1,y=y+1}}}
  t.get_inventory=function() return {get_item_count=function() return 0 end} end
  return t
end
local uncommon={name='uncommon',range_multiplier=1.1}
local t1=turret(900,'gun-turret',5,2,uncommon,{range=18,min_range=0,turn_range=1})
local rail=turret(901,'railgun-turret',15,2,{name='normal',range_multiplier=1},{range=40,min_range=3.5,turn_range=0.2})
local laser=turret(902,'laser-turret',10,30,{name='rare',range_multiplier=1.2},{range=24,min_range=0,turn_range=1})
local turrets={t1,rail,laser}
surface.find_entities_filtered=function(f)
  if f.type=='asteroid' then local out={}; for _,e in pairs(asts) do if e.valid then out[#out+1]=e end end; table.sort(out,function(a,b) return a.unit_number<b.unit_number end); return out end
  local out={}; for _,t in ipairs(turrets) do if t.valid then out[#out+1]=t end end; return out
end
local A=require('asteroidwatch'){state=function() return st end,on_platform=function() return {surface=surface,force=player_force} end}
local p={index=1,valid=true,name='astra'}
local function start(a)
  local out=A.handler(p,a)
  local job=st.asteroid_watch[1]
  if job.start==game.tick and not job.call then local c={}; for k,v in pairs(a) do c[k]=v end; job.call={action='platform_defense',args=c} end
  return out
end
local X=require('mixed'){state=function() return st end,player=function() return p end,who_index=function() return 'astra' end,
  call=function(q,action,args) return start(args) end,read={asteroid_watch=function(job) return A.result(job,false) end},
  close={asteroid_watch=function(job,new,tick,why) return A.close(job,new,tick,why) end}}

start({platform='Probe6',asteroids=true,seconds=60})
for u=1,5 do asteroid(u,1+u*3,-20) end
A.tick(1000)
for _,e in pairs(asts) do e.position={x=e.position.x,y=e.position.y+7.5} end
game.tick=1015; A.tick(1015)
-- asteroid 1 hits the laser; t1 destroys 2 after the railgun hit it
A.on_damaged({entity=laser,cause=asts[1],final_damage_amount=120,tick=1016})
A.on_damaged({entity=asts[2],cause=rail,final_damage_amount=300,tick=1017})
A.on_damaged({entity=asts[2],cause=t1,final_damage_amount=100,tick=1018})
A.on_died({entity=asts[2],cause=t1,tick=1018}); asts[2].valid=false
game.tick=1030; A.tick(1030)
local first=st.asteroid_watch[1]

-- the laser is destroyed at 1100: the watch starts again from there, the first one closed and kept whole
game.tick=1100
laser.valid=false
eq(X.edit(setmetatable({valid=true},{__index=laser}),'destroyed by medium-carbonic-asteroid',true),1)
local new=st.asteroid_watch[1]
assert(new~=first,'a new watch from the edit')
eq(new.start,1100); eq(new.until_tick,1100+58*60)
eq(#new.segments,1); eq(new.segments[1],first)
eq(first.until_tick,1100); eq(first.turrets,nil); assert(first.result and first.hitmap)
eq(new.mixed.parts[1].segment_start,1000); eq(new.mixed.parts[1].to_tick,1100)
has(new.mixed.parts[1].line,'watched Probe6 for 1.7s: 5 asteroids seen in view')

-- the read lists the segment; segment_start reads it in full
local r=A.handler(p,{platform='Probe6',asteroids=true})
eq(#r.segments,1); eq(r.segments[1].segment_start,1000); eq(r.segments[1].end_tick,1100); eq(r.segments[1].seconds,1.7)
has(r.segments[1].closed_by,'destroyed by medium-carbonic-asteroid on laser-turret (10,30)'); has(r.segments_note,'segment_start: its start tick')
local g=A.handler(p,{platform='Probe6',asteroids=true,segment_start=1000})
eq(g.done,true); eq(g.segment.segment_start,1000); eq(g.segment.end_tick,1100); eq(g.asteroids,5); eq(g.platform_hits,1)
has(g.platform_hit_lines[1],'medium-carbonic-asteroid hit laser-turret (10,30) at +0.3s for 120')
eq(g.trajectory_page.total,5)
local d
for _,row in ipairs(g.trajectories) do if row.unit==2 then d=row end end
eq(d.outcome,'destroyed'); eq(d.by,'gun-turret (5,2)'); eq(d.hit_by[1].turret,'gun-turret (5,2)'); eq(d.hit_by[1].killed,true); eq(d.hit_by[2].turret,'railgun-turret (15,2)'); eq(d.hit_by[2].damage,300)
-- turret rows: range by quality, the railgun's cone
local rows={}
for _,t in ipairs(g.turrets) do rows[t.name]=t end
eq(rows['gun-turret'].range,19.8); eq(rows['gun-turret'].quality,'uncommon'); eq(rows['gun-turret'].turn_range,nil); eq(rows['gun-turret'].min_range,nil)
eq(rows['railgun-turret'].range,40); eq(rows['railgun-turret'].min_range,3.5); eq(rows['railgun-turret'].turn_range,0.2); eq(rows['railgun-turret'].facing,'east')
-- a page of a segment, and a refusal naming the kept starts
eq(#A.handler(p,{platform='Probe6',asteroids=true,segment_start=1000,trajectory_limit=2}).trajectories,2)
fails(function() A.handler(p,{platform='Probe6',asteroids=true,segment_start=1050}) end,'no segment of your watch starts at tick 1050 (kept: 1000)')
fails(function() A.handler(p,{platform='Probe6',asteroids=true,segment_start='x'}) end,'segment_start: a segment\'s start tick')
fails(function() A.handler(p,{platform='Probe6',asteroids=true,seconds=30,segment_start=1000}) end,'segment_start is for the read')

-- three more edits: at most 3 segments, the oldest dropped; each closed watch kept whole
for k=1,3 do
  game.tick=1100+k*120
  A.tick(game.tick)
  eq(X.edit(t1,'configure priority_targets by astra'),1)
end
local w=st.asteroid_watch[1]
eq(w.start,1460); eq(#w.segments,3); eq(w.segments[1].start,1100); eq(w.segments[3].start,1340)
eq(#A.handler(p,{platform='Probe6',asteroids=true}).segments,3)
fails(function() A.handler(p,{platform='Probe6',asteroids=true,segment_start=1000}) end,'(kept: 1100, 1220, 1340)')
eq(w.segments_dropped,1); eq(A.handler(p,{platform='Probe6',asteroids=true}).segments_dropped,1)
-- the records bound: with 5 tracked asteroids at most, only the newest segment (4 tracked) stays
eq(w.segments[3].nast,4)
A.SEGMENT_RECORDS=5
A.tick(game.tick); game.tick=game.tick+60; A.tick(game.tick)
eq(X.edit(t1,'configure priority_targets by astra'),1)
w=st.asteroid_watch[1]
eq(#w.segments,1); eq(w.segments[1].start,1460); eq(w.segments_dropped,4)
A.SEGMENT_RECORDS=3000
-- the watch done at its end keeps its segments
game.tick=1000+3600; A.tick(game.tick)
local done=A.handler(p,{platform='Probe6',asteroids=true})
eq(done.done,true); eq(#done.segments,1); eq(done.segments_dropped,4)
eq(A.handler(p,{platform='Probe6',asteroids=true,segment_start=1460}).segment.end_tick,1520)
-- a new watch of its own starts with none
game.tick=5000
local fresh=A.handler(p,{platform='Probe6',asteroids=true,seconds=10})
eq(st.asteroid_watch[1].segments,nil)
eq(A.handler(p,{platform='Probe6',asteroids=true}).segments,nil)
prototypes,defines,game=nil,nil,nil
print('d25_batch200 QM1 asteroid watch segments: ok')
