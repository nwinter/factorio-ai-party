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
fails(function() op('census',{part='everything'}) end,'part must be extras, snapshot, machines, basemap or planets')
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
  local list={ent('biochamber','assembling-machine',10.5,10.5),ent('stone-furnace','furnace',30.5,10.5),ent('gun-turret','ammo-turret',31,11),ent('transport-belt','transport-belt',600,10)}
  local ls,once={},true
  local C3=dofile('mod/agent-harness_0.1.0/census.lua'){state=function() return ls end,
    walk={every=function() return 1 end,due=function() return true end,start=function() return {} end,
      band=function() if once then once=false return list end end}}
  local kept,kept_get=game.surfaces,game.get_surface; game.surfaces={gleba}; game.get_surface=function() return gleba end
  for t=5000,5040 do C3.tick(t) end
  local r=C3.read({part='planets'})
  eq(r.ready,true); eq(#r.planets,1); eq(r.planets[1].name,'gleba'); eq(r.planets[1].buildings,4)
  local m=C3.read({part='basemap',surface='gleba'}).basemap
  eq(m.cell,8,'doubled until 590 tiles fit 128 cells'); eq(m.x0,8); eq(m.w,75)
  eq(m.rows[1]:sub(1,1),'A'); eq(m.rows[1]:sub(3,3),'D','the turret outranks the furnace in its cell')
  eq(C3.read({part='basemap',surface='vulcanus'}).none,'no buildings of ours on vulcanus in the last pass')
  game.surfaces,game.get_surface=kept,kept_get
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
