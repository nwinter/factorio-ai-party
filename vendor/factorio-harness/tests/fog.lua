-- Run from the harness root: lua tests/fog.lua
-- The fog view and lost buildings (fogmem.lua, lostlog.lua; Nick d17 17:28): the memory of our buildings out of sight,
-- each loss of ours, the losses read and the one-call rebuild.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,part) assert(type(s)=='string' and s:find(part,1,true),tostring(s)..'\n  lacks: '..part) end
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path

local storage_={}
local visible={}
local function vis(cx,cy) return visible[cx..','..cy]==true end
local force={name='player'}
force.is_chunk_visible=function(_,c) return vis(c.x,c.y) end
local enemy={name='enemy'}
local world={}            -- entities the fake surface finds
local networks={}         -- construction areas: {box, id, idle, items}
local surface={name='vulcanus'}
surface.find_entities_filtered=function(f)
  local want
  if f.type then want={} for _,t in ipairs(type(f.type)=='table' and f.type or {f.type}) do want[t]=true end end
  local out={}
  for _,e in ipairs(world) do
    local q=e.position
    local ok=e.valid and (not want or want[e.type]) and (not f.force or e.force==f.force)
    if ok and f.area then
      local lt,rb=f.area[1] or f.area.left_top,f.area[2] or f.area.right_bottom
      local x1,y1,x2,y2=lt[1] or lt.x,lt[2] or lt.y,rb[1] or rb.x,rb[2] or rb.y
      ok=q.x>=x1 and q.x<=x2 and q.y>=y1 and q.y<=y2
    end
    if ok and f.position then ok=(q.x-f.position.x)^2+(q.y-f.position.y)^2<=(f.radius or 0)^2 end
    if ok then out[#out+1]=e end
  end
  return out
end
surface.find_entity=function(name,q)
  for _,e in ipairs(world) do if e.valid and e.name==name and e.position.x==q.x and e.position.y==q.y then return e end end
end
surface.find_logistic_networks_by_construction_area=function(q,f)
  local out={}
  for _,n in ipairs(networks) do
    if q.x>=n.box[1] and q.x<=n.box[3] and q.y>=n.box[2] and q.y<=n.box[4] then
      out[#out+1]={network_id=n.id,available_construction_robots=n.idle,get_item_count=function(item) return n.items[item] or 0 end}
    end
  end
  return out
end
game={tick=1000,forces={player=force,enemy=enemy},surfaces={vulcanus=surface},get_surface=function(n) return n=='vulcanus' and surface or nil end}
local turret_proto={type='ammo-turret',items_to_place_this={{name='gun-turret',count=1}}}
local belt_proto={type='transport-belt',items_to_place_this={{name='transport-belt',count=1}}}
local wall_proto={type='wall',items_to_place_this={{name='stone-wall',count=1}}}
prototypes={entity={['gun-turret']=turret_proto,['transport-belt']=belt_proto,['stone-wall']=wall_proto,radar={type='radar',items_to_place_this={{name='radar',count=1}}}},
  tile={},recipe={}}
defines={inventory={chest=1}}
local function ent(name,type,x,y,extra)
  local e={valid=true,name=name,type=type,position={x=x,y=y},force=force,surface=surface,direction=0,supports_direction=true}
  for k,v in pairs(extra or {}) do e[k]=v end
  return e
end
local function ghost(name,x,y)
  return ent('entity-ghost','entity-ghost',x,y,{ghost_name=name,ghost_prototype=prototypes.entity[name]})
end
local function state() return storage_ end
local belt_memory={}
local lost=require('lostlog'){state=state,position=function(v) return {x=v.x or v[1],y=v.y or v[2]} end,
  integer=function(v,d,lo,hi,name) v=v==nil and d or v; assert(type(v)=='number' and v>=lo and v<=hi and v%1==0,name..' must be '..lo..'..'..hi); return v end,
  distance=function(a,b) return ((a.x-b.x)^2+(a.y-b.y)^2)^0.5 end,visible=function(p,q) return vis(math.floor(q.x/32),math.floor(q.y/32)) end,
  entity=function(p,q) for _,e in ipairs(world) do if e.position.x==q.x and e.position.y==q.y then return e end end end,
  submit=function(p,a) return {queued=#a.steps} end,
  gather=function(p,want,chests) return require('stage'){hand_recipe=function() return nil end}.gather(p,want,chests) end}
local fog=require('fogmem'){state=state,max_chunks=3,direction_name=function(d) return ({[0]='north',[4]='east',[8]='south',[12]='west'})[d] end,
  belt_chunk=function(f,s,cx,cy) return belt_memory[cx..','..cy] end,lost_in=function(f,s,box) return lost.rows_in(f,s,box) end}

-- 1. The memory: what our force saw in a chunk in sight; out of sight it is what fog() returns, with when it was seen.
visible['6,-8']=true
local t1=ent('gun-turret','ammo-turret',200.5,-250.5)
local radar=ent('radar','radar',210.5,-230.5)
local bug=ent('small-biter','unit',201,-249,{force=enemy})
local belt=ent('transport-belt','transport-belt',205.5,-250.5)
for _,e in ipairs{t1,radar,bug,belt} do fog.note(e,e.position,e.name=='radar' and 'no_power' or 'working') end
eq(fog.stats().rows,2,'a turret and a radar; no enemy, belts are belt memory\'s')
local box={{192,-256},{223.5,-224.5}}
eq(fog.area(force,surface,box),nil,'all in sight: no fog')
game.tick=4600
visible['6,-8']=nil  -- the radar's power went: the chunk is out of sight
t1.valid=false                           -- destroyed out of sight: a ghost stands for it, and the loss is told
lost.died(t1,'small-biter'); world[#world+1]=ghost('gun-turret',200.5,-250.5)
belt_memory['6,-8']={tiles={['205,-251']={name='transport-belt',position={x=205.5,y=-250.5},direction=4,tick=900}}}
local f=fog.area(force,surface,box)
eq(f.chunks_out_of_sight,1); eq(f.remembered_count,3); eq(f.ghost_count,1); eq(f.lost_count,1)
local by={}
for _,r in ipairs(f.remembered) do by[r.name]=r end
eq(by['gun-turret'].status,'working'); eq(by['gun-turret'].seen_s_ago,60); eq(by['gun-turret'].remembered,true)
has(by['gun-turret'].lost_after_seen,'lost 0s ago (small-biter)')
eq(by.radar.status,'no_power'); eq(by['transport-belt'].direction,'east'); eq(by['transport-belt'].seen_s_ago,61)
eq(f.ghosts[1].name,'gun-turret'); eq(f.lost[1].cause,'small-biter')
has(f.note,'the last chart'); has(f.line,'1 of 1 chunks here out of sight: 3 buildings and belts remembered, 1 ghosts of ours, 1 of ours lost there')
-- 2. Removed in sight: forgotten. A chunk in sight is dropped first when the memory is full (3 chunks in this test).
fog.forget(radar)
eq(fog.stats().rows,1)
for i=1,3 do visible[(20+i)..',0']=true; fog.note(ent('radar','radar',(20+i)*32+1,1),{x=(20+i)*32+1,y=1},'working') end
eq(fog.stats().chunks,3)
local kept=fog.area(force,surface,box)
eq(kept.remembered_count,2,'the turret out of sight kept (with the belt), chunks in sight dropped first')

-- 3. losses: each one of ours, its ghost, robots, the items to rebuild.
storage_.lost_log=nil; world={}
local function die(name,x,y,cause) local e=ent(name,prototypes.entity[name].type,x,y); lost.died(e,cause); return e end
game.tick=10000
for i=0,3 do die('gun-turret',192.5+i*2,-250.5,'medium-biter'); world[#world+1]=ghost('gun-turret',192.5+i*2,-250.5) end
die('stone-wall',100.5,64.5,'small-spitter'); world[#world+1]=ghost('stone-wall',100.5,64.5)
die('stone-wall',101.5,64.5,'small-spitter')                       -- no ghost, out of sight: unknown
visible['3,1']=true; die('radar',110.5,40.5,'small-biter'); world[#world+1]=ent('radar','radar',110.5,40.5)   -- rebuilt in sight
networks={{box={90,50,120,80},id=7,idle=3,items={['stone-wall']=40}}}
game.tick=13600
local p={surface=surface,force=force,position={x=100,y=60},get_main_inventory=function() return {get_item_count=function(i) return i=='gun-turret' and 1 or 0 end} end}
local r=lost.read(p,{})
eq(r.count,7)
has(r.line,'7 buildings of ours lost on vulcanus: 5 with a ghost now (1 robots can build')
has(r.line,'4 not: 0 of those in a construction area without robots or the item, 4 outside every one)')
has(r.line,'2 without a ghost (1 rebuilt in sight, 0 gone in sight, 1 out of sight)')
eq(r.by_name[1].name,'gun-turret'); eq(r.by_name[1].lost,4); eq(r.by_name[1].outside,4)
local items={}
for _,it in ipairs(r.items) do items[it.item]=it end
eq(items['gun-turret'].need,4); eq(items['gun-turret'].to_carry,4); eq(items['gun-turret'].you_hold,1)
eq(items['stone-wall'].robots_build,1); eq(items['stone-wall'].in_covering_networks,40)
local rows={}
for _,x in ipairs(r.losses) do rows[x.name..'@'..x.position.x] = x end
has(rows['stone-wall@100.5'].robots,'robots can build it (network 7: 3 idle, 40 stone-wall)')
has(rows['gun-turret@192.5'].robots,'no roboport\'s construction area covers it')
has(rows['stone-wall@101.5'].now,'out of sight')
has(rows['radar@110.5'].now,'rebuilt')
eq(rows['gun-turret@192.5'].lost_s_ago,60); eq(rows['gun-turret@192.5'].cause,'medium-biter')
has(r.rebuild,'rebuild {area} plans the 4 ghosts robots will not build')
eq(lost.read(p,{area={{180,-260},{210,-240}}}).count,4)
eq(lost.read(p,{name='stone-wall'}).count,2)
game.tick=20000; eq(lost.read(p,{since=1}).count,0,'none in the last minute'); game.tick=13600
eq(lost.read(p,{limit=2}).pages,4)

-- 4. rebuild: the ghosts robots will not build, the items you lack from the chests, then construct per box.
local function tens(i) return i=='gun-turret' and 10 or 0 end
local chest=ent('iron-chest','container',101.5,58.5,{get_inventory=function() return {get_item_count=tens} end,get_item_count=tens})
world[#world+1]=chest
visible['3,1']=true
local plan=lost.rebuild(p,{area={{90,-260},{210,70}},dry_run=true})
eq(plan.ghosts,4); eq(plan.left_for_robots,1); eq(plan.items['gun-turret'],4)
eq(plan.steps[1].action,'transfer'); eq(plan.steps[1].args.items['gun-turret'],3,'you carry one')
eq(plan.steps[2].action,'construct'); eq(plan.steps[2].args.outside_robots,true)
eq(plan.steps[2].args.area.left_top.x,191); eq(plan.steps[2].args.area.right_bottom.x,200)
has(plan.plan[1],'take gun-turret 3 from iron-chest (101.5,58.5)')
local every=lost.rebuild(p,{area={{90,-260},{210,70}},all=true,dry_run=true})
eq(every.ghosts,5); eq(#every.steps,3,'a take and two boxes: the wall is 300 tiles from the turrets')
local none=lost.rebuild(p,{area={{90,50},{120,80}},dry_run=true})
has(none.line,'all 1 ghosts there are for robots')
local q=lost.rebuild(p,{area={{90,-260},{210,70}}})
eq(q.queued,2); has(q.line,'queued 2 steps for 4 ghosts')
print('fog: ok (the memory in sight, the fog view out of sight with ghosts and losses, forgetting, eviction; losses with ghosts, '
  ..'robots and items; rebuild: takes, construct boxes, all, robots\' ghosts left)')
