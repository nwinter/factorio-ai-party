-- Run from repository root: lua tests/census.lua
-- The census through the runtime (census.lua; operator 22:00, task-slowreads): the operator read census is listed in
-- describe; before its first pass it says ready=false; the pass runs in the harness tick, a band or slice a step,
-- and then each part answers with as_of. (tools/stream/test_census.py checks its parts against the host reads.)
-- Fake engine and bot as tests/round0320a.lua.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
storage={agent_harness={active={}}}
defines={events={on_script_path_request_finished=10,on_entity_died=11,on_entity_damaged=12,on_console_chat=13,on_unit_group_finished_gathering=14},
  shooting={not_shooting=0,shooting_enemies=1},controllers={character=1,remote=27,spectator=2},direction={north=0},inventory={chest=1},
  build_mode={normal=1},build_check_type={manual=1},flow_precision_index={five_seconds=0,one_minute=1}}
local drawn={}
rendering={draw_text=function() local obj={id=#drawn+1,valid=true}; obj.destroy=function() obj.valid=false end; drawn[#drawn+1]=obj; return obj end,
  get_object_by_id=function(id) return drawn[id] end}
remote={interfaces={}}
helpers={json_to_table=function(t) return t end}
prototypes={item={stone={}},entity={stone={name='stone',type='resource'},['iron-chest']={name='iron-chest',type='container'}}}
local force={name='player',chart=function() end,is_chunk_visible=function() return true end,is_chunk_charted=function() return true end,
  get_spawn_position=function() return {x=0,y=0} end}
local neutral={name='neutral'}
local surface={name='nauvis',index=1}
local world={}
local function box_distance(pos,e)
  local b=e.bounding_box
  local dx=math.max(b.left_top.x-pos.x,0,pos.x-b.right_bottom.x)
  local dy=math.max(b.left_top.y-pos.y,0,pos.y-b.right_bottom.y)
  return (dx*dx+dy*dy)^0.5
end
local function dist(a,b) return ((a.x-b.x)^2+(a.y-b.y)^2)^0.5 end
surface.find_non_colliding_position=function(_,pos) return {x=math.floor(pos.x)+0.5,y=math.floor(pos.y)+0.5} end
surface.can_place_entity=function() return true end
surface.find_entities_filtered=function(f)
  local out={}
  for _,e in ipairs(world) do
    local near=f.position and ((f.radius and f.radius>=1) and dist(e.position,f.position)<=f.radius
      or math.abs(e.position.x-f.position.x)<0.3 and math.abs(e.position.y-f.position.y)<0.3)
    if e.valid and near and (not f.name or f.name==e.name) and (not f.type or f.type==e.type) then out[#out+1]=e end
  end
  return out
end
surface.get_total_pollution=function() return 0 end; surface.get_chunks=function() return function() end end; surface.get_pollution=function() return 0 end
surface.request_path=function() return 1 end
local function character(pos)
  local c={valid=true,name='character',type='character',force=force,surface=surface,position=pos,unit_number=501,health=250,max_health=250,
    driving=false,build_distance=10,reach_distance=10,resource_reach_distance=2.7,character_running_speed=0.15,walking_state={walking=false},
    prototype={mining_speed=0.5,collision_mask={layers={player=true}}}}
  local inv={get_item_count=function() return 0 end,find_item_stack=function() return nil end,get_contents=function() return {} end}
  c.get_main_inventory=function() return inv end
  c.get_item_count=function() return 0 end
  c.insert=function(s) return s.count end
  c.can_insert=function() return true end
  c.can_reach_entity=function(e) return box_distance(c.position,e)<=2.7 end
  -- One unit a cycle, as the engine's mine_entity on a resource.
  c.mine_entity=function(e) e.amount=e.amount-1; if e.amount<=0 then e.valid=false end; return not e.valid end
  c.destroy=function() c.valid=false end
  return c
end
surface.create_entity=function(args) if args.name=='character' then return character(args.position) end return {valid=true,name=args.name,position=args.position} end
local nick={index=1,name='nick',valid=true,connected=true,controller_type=1,physical_controller_type=1,cheat_mode=false,driving=false,force=force,surface=surface,position={x=5,y=5},chat_color={r=1,g=1,b=1}}
nick.character=character({x=5,y=5})
local players={nick}
for _,pl in ipairs(players) do pl.print=function() end end
local tick=0
game={tick=0,players=players,forces={player=force,enemy={name='enemy',get_evolution_factor=function() return 0 end,get_evolution_factor_by_time=function() return 0 end,
  get_evolution_factor_by_pollution=function() return 0 end,get_evolution_factor_by_killing_spawners=function() return 0 end}},
  get_player=function(i) if type(i)=='string' then for _,p in ipairs(players) do if p.name==i then return p end end return nil end return players[i] end,
  get_surface=function() return surface end,print=function() end,connected_players=players,
  get_pollution_statistics=function() return {input_counts={},output_counts={},get_flow_count=function() return 0 end} end}
local runtime=dofile('mod/agent-harness_0.1.0/runtime.lua')
local function advance(n) for _=1,n do tick=tick+1; game.tick=tick; runtime.tick{tick=tick} end end
local function request(req)
  local ok,result=pcall(runtime.dispatch,req)
  if not ok then error(result,0) end
  return result
end
runtime.operator.bot_create('grok')
local function grok(action,args) return request{action=action,args=args or {},bot='grok'} end
local body=runtime.bots.lookup(runtime.bots.index_of('grok')).character
for k,v in pairs(character({x=0,y=0})) do if type(v)=='function' and k~='destroy' then body[k]=v end end
body.prototype={mining_speed=0.5,collision_mask={layers={player=true}}}
body.can_reach_entity=function(e) return box_distance(body.position,e)<=2.7 end
local function stone(x,y,amount)
  local e={valid=true,name='stone',type='resource',position={x=x,y=y},force=neutral,amount=amount,minable=true,
    bounding_box={left_top={x=x-0.4,y=y-0.4},right_bottom={x=x+0.4,y=y+0.4}},
    prototype={mineable_properties={mining_time=1,products={{type='item',name='stone',amount=1}}}}}
  world[#world+1]=e
  return e
end

local function op(action,args) return request{action=action,args=args or {},operator=true} end
local listed=false
for _,r in ipairs(grok('describe').operator_reads or {}) do listed=listed or r=='census' end
eq(listed,true,'describe lists census')
local r=op('census',{part='extras'})
eq(r.ready,false); eq(r.part,'extras')
fails(function() op('census',{part='everything'}) end,'part must be extras, snapshot, machines, basemap, planets or vehicles')
-- Grok's stone tiles and the bot's body are the only entities: the pass walks them and ends.
advance(4000)
r=op('census',{part='extras'})
local cs=storage.agent_harness.census
assert(r.ready,'no pass: '..tostring(cs.errors and cs.errors.last)..' stage '..tostring(cs.job and cs.job.stage))
eq(r.ready,true); eq(r.electric_machines,0); eq(r.starved,0); assert(r.as_of and r.as_of>0,'as_of')
r=op('census',{part='basemap',ore=true})
eq(r.ready,true); eq(r.basemap.buildings,0); eq(r.ore_pending,true)
r=op('census',{part='machines'}); eq(r.ready,true)
print('census: ok')

-- Silo discovery is published only by the existing census pass. Reads filter deleted/moved/other-force entities
-- and return a fresh list; the entities' rocket contents remain live, not a cargo snapshot.
local target={valid=true,type='rocket-silo',name='rocket-silo',unit_number=42,position={x=0,y=0},surface=surface,force=force,
  get_recipe=function() return nil end,status=0}
local localstate={}
local first=true
local C=dofile('mod/agent-harness_0.1.0/census.lua'){
  state=function() return localstate end,
  walk={every=function() return 1 end,due=function() return true end,start=function() return {} end,
    band=function() if first then first=false return {target} end end}}
game.surfaces={surface}
local list,asof=C.silos{surface=surface,force=force}; eq(#list,0); eq(asof,nil)
C.tick(5000); C.tick(5001); C.tick(5002)
assert(localstate.census.job.silos[1][1]==target,'existing walk registers the silo')
list,asof=C.silos{surface=surface,force=force}; eq(asof,nil,'unfinished pass not published')
localstate.census.job.stage='done'; localstate.census.job.base.x={}; C.tick(5003)
list,asof=C.silos{surface=surface,force=force}; eq(#list,1); eq(asof,5000); eq(list[1],target)
local counts,count_tick=C.buildings(force)
eq(counts[1].entities['rocket-silo'],1); eq(count_tick,5000)
localstate.census.done.start=7000 -- failed retry can postpone scheduling, never change the count observation age
eq(select(2,C.buildings(force)),5000)
eq(C.buildings(neutral),nil,'player census is not a different force census')
-- Fuel users (fuelbudget.lua): a burner registers on the same pass and is published with it.
do
  prototypes.entity=prototypes.entity or {}
  prototypes.entity.boiler={burner_prototype={effectivity=1}}
  local b={valid=true,type='boiler',name='boiler',unit_number=43,position={x=4,y=4},surface=surface,force=force,status=0}
  local ls,once={},true
  local C2=dofile('mod/agent-harness_0.1.0/census.lua'){state=function() return ls end,
    walk={every=function() return 1 end,due=function() return true end,start=function() return {} end,
      band=function() if once then once=false return {b} end end}}
  eq(C2.fuel_users(surface),nil)
  C2.tick(5000); C2.tick(5001); C2.tick(5002)
  ls.census.job.stage='done'; ls.census.job.base.x={}; C2.tick(5003)
  local users,as_of=C2.fuel_users(surface); eq(#users,1); eq(users[1],b); eq(as_of,5000)
end
print('census fuel users: ok')
-- Other planets' coarse maps (viewers craigNZ830, Foobator, d15 07:05: the live map was Nauvis only): the same pass,
-- each planet's grid made in steps after the walk; read with basemap surface= and listed with part planets.
do
  local gleba={name='gleba',index=4,planet={name='gleba'}}
  local function ent(name,t,x,y) return {valid=true,type=t,name=name,position={x=x,y=y},surface=gleba,force=force,status=0,get_recipe=function() return nil end} end
  local list={ent('biochamber','assembling-machine',11.5,10.5),ent('stone-furnace','furnace',30.5,10.5),ent('gun-turret','ammo-turret',31,11),ent('transport-belt','transport-belt',600,10),
    ent('stone-wall','wall',31.5,10.5),ent('stone-wall','wall',45.5,10.5),ent('gate','gate',46.5,10.5)}
  local ls,once={},true
  local C3=dofile('mod/agent-harness_0.1.0/census.lua'){state=function() return ls end,
    walk={every=function() return 1 end,due=function() return true end,start=function() return {} end,
      band=function() if once then once=false return list end end}}
  local kept,kept_get=game.surfaces,game.get_surface; game.surfaces={gleba}; game.get_surface=function() return gleba end
  local kept_protos=prototypes
  prototypes=setmetatable({entity={biochamber={tile_width=3,tile_height=3},['gun-turret']={tile_width=2,tile_height=2}}},{__index=kept_protos})
  for t=5000,5040 do C3.tick(t) end
  local r=C3.read({part='planets'})
  eq(r.ready,true); eq(#r.planets,1); eq(r.planets[1].name,'gleba'); eq(r.planets[1].buildings,7)
  local m=C3.read({part='basemap',surface='gleba'}).basemap
  eq(m.cell,8,'doubled until 590 tiles fit 128 cells'); eq(m.x0,8); eq(m.w,75)
  eq(m.rows[1]:sub(1,1),'A'); eq(m.rows[1]:sub(3,3),'D','the turret outranks the furnace in its cell')
  -- d22 batch75 AK4 (viewer Foobator: "can walls be a separate item?"): walls and gates W; a wall in the turret's cell
  -- leaves it D
  eq(m.rows[1]:sub(5,5),'W','a wall and a gate: W')
  -- d21 batch68 AD1 (viewer Aurora): its dense core as Nauvis's, each building's footprint (under 12 buildings: the
  -- whole extent, 8..608 x 8..16, at 4 tiles a cell to fit 160 cells)
  local k=m.core
  eq(k.cell,4); eq(k.x0,8); eq(k.y0,8); eq(k.w,150); eq(k.h,2)
  eq(k.rows[1]:sub(1,2),'AA','the 3x3 biochamber (tiles 10..12) over cells 8-12 and 12-16')
  eq(k.rows[1]:sub(6,6),'D','the 2x2 turret (30..32) outranks the furnace in its cell'); eq(k.rows[1]:sub(-1),'B')
  eq(k.rows[1]:sub(10,10),'W','the wall (45..46) and gate (46..47) in their own cell')
  eq(C3.read({part='basemap',surface='vulcanus'}).none,'no buildings of ours on vulcanus in the last pass')
  game.surfaces,game.get_surface,prototypes=kept,kept_get,kept_protos
end
print('census planets: ok')
list[1]=nil
list=C.silos{surface=surface,force=force}; eq(#list,1,'caller sorting cannot change the index')
target.valid=false; list=C.silos{surface=surface,force=force}; eq(#list,0)
target.valid=true; target.force=neutral; list=C.silos{surface=surface,force=force}; eq(#list,0)
target.force=force; target.surface={}; list=C.silos{surface=surface,force=force}; eq(#list,0)
print('census silo index: ok')

-- A hot reload can resume a pass made by the old runtime: do not publish only its remaining silos as complete.
target.surface=surface; first=true; localstate.census=nil
C.tick(8000); localstate.census.job.silos=nil; localstate.census.job.building_counts=nil
C.tick(8001); C.tick(8002)
eq(localstate.census.job.silos,nil)
localstate.census.job.stage='done'; localstate.census.job.base.x={}; C.tick(8003)
list,asof=C.silos{surface=surface,force=force}; eq(#list,0); eq(asof,nil)
eq(C.buildings(force),nil,'a pre-installation pass does not publish partial tier counts')
print('census silo index reload: ok')

-- Crop towers and their ghosts use the same sliced census pass, and dispatch
-- agriculture as a read without touching a character or launching a new scan.
do
  local built={valid=true,type='agricultural-tower',name='agricultural-tower',unit_number=43,position={x=10,y=0},surface=surface,force=force,
    status=0,get_inventory=function() return {get_contents=function() return {} end} end}
  local ghost={valid=true,type='entity-ghost',name='entity-ghost',ghost_name='agricultural-tower',ghost_type='agricultural-tower',
    position={x=20,y=0},surface=surface,force=force}
  local state2={};local pending=true
  local C2=dofile('mod/agent-harness_0.1.0/census.lua'){state=function() return state2 end,
    walk={every=function() return 1 end,due=function() return true end,start=function() return {} end,
      band=function() if pending then pending=false;return {built,ghost} end end}}
  C2.tick(9000);C2.tick(9001);C2.tick(9002)
  eq(#state2.census.job.towers[1],2)
  local rows,asof=C2.towers(force,surface);eq(asof,nil)
  state2.census.job.stage='done';state2.census.job.base.x={};C2.tick(9003)
  rows,asof=C2.towers(force,surface);eq(#rows,2);eq(asof,9000)
  storage.agent_harness.census=state2.census
  defines.inventory.agricultural_tower_input=98
  local view=grok('observe',{scope='agriculture',surface='nauvis'})
  eq(#view.towers,2);eq(view.towers[1].state,'built');eq(view.towers[2].state,'ghost')
  runtime.on_event{name=defines.events.on_entity_died,entity=built,tick=game.tick}
  built.valid=false
  view=grok('agriculture',{})
  eq(view.towers[1].state,'destroyed');eq(view.towers[1].position.x,10)
end
print('census agriculture: ok')
-- observe platform must dispatch without reading the caller's absent character.
do
  local bot=runtime.bots.record(runtime.bots.index_of('grok'))
  local saved=bot.character
  bot.character=nil;bot.travel={state='aboard',platform='Sunward'}
  local ps={valid=true,name='platform-test',index=17}
  ps.find_entities_filtered=function(q) assert(q.area and q.limit);return {} end
  ps.find_tiles_filtered=function(q) assert(q.area and q.name=='space-platform-foundation');return {} end
  force.platforms={{valid=true,name='Sunward',surface=ps,hub={position={x=0,y=0}}}}
  local view=grok('observe',{platform='Sunward',radius=16,tiles=true})
  eq(view.platform,'Sunward');eq(view.position.x,0);eq(view.player,nil)
  grok('queue_submit',{lane='remote',steps={{action='wait_ticks',args={ticks=2}},
    {action='observe',args={platform='Sunward',radius=16}}}})
  for _=1,4 do game.tick=game.tick+1;runtime.tick{tick=game.tick} end
  local q=grok('queue_status',{lane='remote'})
  eq(q.paused,false);eq(q.active,false);eq(#q.history,2);eq(q.history[2].ok,true)
  bot.character=saved;bot.travel=nil
end
print('bodiless platform observe: ok')
-- (d20 batch55 P1, viewer Aurora) A pass that fails: the last pass keeps its as_of (the tick it started), the read says
-- its age and the failure, and the next pass starts PERIOD after the failure.
do
  local st,boom={},nil
  local C3=dofile('mod/agent-harness_0.1.0/census.lua'){state=function() return st end,
    walk={every=function() return 1 end,due=function() return true end,start=function() return {} end,
      band=function() if boom then error(boom) end end}}
  local saved_tick,saved_surfaces=game.tick,game.surfaces
  game.surfaces={surface}
  game.tick=100000
  C3.tick(game.tick)
  st.census.job.stage='done'; st.census.job.base.x={}
  game.tick=game.tick+1; C3.tick(game.tick)
  local done=st.census.done
  eq(done.start,100000)
  game.tick=100000+1800; C3.tick(game.tick); assert(st.census.job,'the next pass')
  boom='band read broke'
  game.tick=game.tick+1; C3.tick(game.tick)
  eq(st.census.job,nil,'the pass ended'); eq(st.census.errors.count,1)
  eq(st.census.done,done); eq(done.start,100000,'the last pass keeps its as_of')
  local failed_at=game.tick
  game.tick=game.tick+600
  local r=C3.read{part='extras'}
  eq(r.as_of,100000); eq(r.age_s,math.floor((game.tick-100000)/60))
  eq(r.refresh_failed,string.format('the last refresh of the census pass failed 10s ago (%s); the census pass is from %ds ago',done.refresh_failed.error,r.age_s))
  assert(done.refresh_failed.error:find('band read broke',1,true))
  boom=nil
  game.tick=failed_at+1799; C3.tick(game.tick); eq(st.census.job,nil,'no pass within PERIOD of the failure')
  game.tick=game.tick+1; C3.tick(game.tick); assert(st.census.job,'the next pass after it')
  game.tick,game.surfaces=saved_tick,saved_surfaces
end
print('census failed pass: ok')

-- (d22 batch110 BT1: census.step made 14.8 KB of garbage a tick on the private copy) a pass over the real walk: a
-- building's position is the one its band's find read (one read), a car's is read again when it is read (it moved
-- since); an assembler's or furnace's recipe read once; each step's ctx starts with empty lookups; the player force and
-- the surface are read again once not valid. The facts are the ones the pass gave before.
do
  local saved={game.tick,game.surfaces,game.get_surface,game.forces,prototypes,defines.entity_status}
  local reads={}
  local function ent(id,fields,x,y)
    reads[id]={}
    local e=setmetatable({},{__index=function(_,k)
      reads[id][k]=(reads[id][k] or 0)+1
      if k=='position' then return {x=x,y=y} end
      if k=='raw' then return {x=x,y=y} end
      return fields[k]
    end})
    return e,function(nx,ny) x,y=nx,ny end
  end
  local gear={name='iron-gear-wheel',ingredients={{type='item',name='iron-plate',amount=2}}}
  local asm=ent('asm',{valid=true,type='assembling-machine',name='assembling-machine-1',status=1,direction=0,get_recipe=function() return gear end},10.5,10.5)
  local furnace=ent('furnace',{valid=true,type='furnace',name='electric-furnace',status=1,direction=0,get_recipe=function() return nil end,
    previous_recipe={name='iron-plate'}},20.5,20.5)
  local wall=ent('wall',{valid=true,type='wall',name='stone-wall',status=1,direction=0},3.5,3.5)
  local car,move_car=ent('car',{valid=true,type='car',name='car',status=1,direction=0},25.5,4.5)
  local all={asm,furnace,wall,car}
  local filters={}
  local sf={name='nauvis',index=1,valid=true}
  sf.find_entities_filtered=function(f)
    filters[#filters+1]={force=f.force,area=f.area and true}
    local out,a={},f.area
    for _,e in ipairs(all) do
      local p=e.raw
      if not a or (p.x+1.5>a[1][1] and p.x-1.5<a[2][1] and p.y+1.5>a[1][2] and p.y-1.5<a[2][2]) then out[#out+1]=e end
    end
    return out
  end
  local f1={name='player',valid=true}
  game.surfaces={sf}; game.get_surface=function() return sf end; game.forces={player=f1}
  prototypes={entity={},item={},get_entity_filtered=function() return {} end}
  defines.entity_status={working=1,low_power=2,no_power=3}
  local seen,fresh,dirty={},0,0
  local st={walk_box={[1]={left=0,right=0,top=0,bottom=0}}}
  local C=dofile('mod/agent-harness_0.1.0/census.lua'){state=function() return st end,observe_seen=function(e,t,pos,ctx)
    if not seen.tick or seen.tick~=game.tick then
      seen.tick=game.tick
      if next(ctx.vis)==nil and next(ctx.fog)==nil and next(ctx.belt)==nil then fresh=fresh+1 else dirty=dirty+1 end
      eq(ctx.p.force,game.forces.player); eq(ctx.p.surface,sf); eq(ctx.fog_prefix,'player|nauvis|'); eq(ctx.si,1)
    end
    ctx.vis[1],ctx.fog[1],ctx.belt[1]=true,true,true
    seen[t]={x=pos.x,y=pos.y}
  end}
  local t=20000
  game.tick=t; C.tick(t)
  local moved=false
  while not st.census.done and t<40000 do
    t=t+1; game.tick=t; C.tick(t)
    if not moved and st.census.job and st.census.job.list then move_car(26.5,8.5); moved=true end
  end
  assert(st.census.done,'the pass ended')
  local d=st.census.done
  eq(seen.wall.x,3.5); eq(seen.car.x,26.5,'the car read where it is now'); eq(seen.car.y,8.5)
  eq(reads.wall.position,1,'the wall: its band read its position, the census did not again')
  eq(reads.car.position,2,'the car: read by its band and again by the census')
  eq(reads.asm.get_recipe,1,'one recipe read an assembler'); eq(reads.furnace.get_recipe,1,'one recipe read a furnace')
  eq(reads.furnace.previous_recipe,1)
  eq(d.machines['assembling-machine-1|iron-gear-wheel'].working,1); eq(d.machines['electric-furnace|iron-plate'].working,1)
  eq(d.basemap.buildings,3,'assembler, furnace and wall on the map')
  eq(d.where.nauvis,4,'assembler, furnace, wall and car'); eq(d.building_counts[1].entities['assembling-machine-1'],1)
  assert(fresh>0); eq(dirty,0,'each step starts with empty lookups')
  for _,f in ipairs(filters) do eq(f.force,f1) end
  -- the next pass: the force read again once the one kept is not valid
  f1.valid=false
  local f2={name='player',valid=true}
  game.forces={player=f2}
  local n0=#filters
  t=t+2000
  while (not st.census.done or st.census.done.start<t-2000+1) and t<80000 do t=t+1; game.tick=t; C.tick(t) end
  assert(#filters>n0)
  for i=n0+1,#filters do eq(filters[i].force,f2,'the valid force') end
  game.tick,game.surfaces,game.get_surface,game.forces,prototypes,defines.entity_status=table.unpack(saved)
end
print('census BT1 one position and one recipe read, ctx fresh each step: ok')
