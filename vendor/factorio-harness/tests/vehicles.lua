-- Run from repository root: lua tests/vehicles.lua
-- Vehicles (vehicles.lua) and the guard on a seated character, through the
-- runtime against a fake engine.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
local function has(list,text)
  for _,line in ipairs(list or {}) do if line:find(text,1,true) then return line end end
  return nil
end
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
storage={agent_harness={active={}}}
defines={events={on_script_path_request_finished=10,on_entity_died=11,on_entity_damaged=12,on_console_chat=13,on_unit_group_finished_gathering=14},
  shooting={not_shooting=0,shooting_enemies=1},controllers={character=1,remote=27,spectator=2},direction={north=0},inventory={chest=1},
  build_mode={normal=1},build_check_type={manual=1},flow_precision_index={five_seconds=0,one_minute=1}}
local drawn={}
rendering={draw_text=function(t) local obj={id=#drawn+1,valid=true}; obj.destroy=function() obj.valid=false end; drawn[#drawn+1]=obj; return obj end,
  get_object_by_id=function(id) return drawn[id] end}
remote={interfaces={}}
helpers={json_to_table=function(t) return t end}
local force={name='player',chart=function() end,is_chunk_visible=function() return true end,is_chunk_charted=function() return true end,get_spawn_position=function() return {x=0,y=0} end}
local surface={name='nauvis',index=1}
local units=0
local function character(pos)
  local items={}
  units=units+1
  local c={valid=true,name='character',type='character',force=force,surface=surface,position=pos,unit_number=500+units,health=250,
    driving=false,build_distance=10,reach_distance=10,character_running_speed=0.15,walking_state={walking=false}}
  local inv={get_item_count=function(q) return items[type(q)=='table' and q.name or q] or 0 end,find_item_stack=function() return nil end,
    get_contents=function() return {} end}
  c.items=items
  c.insert=function(s) items[s.name]=(items[s.name] or 0)+s.count; return s.count end
  c.get_main_inventory=function() return inv end
  c.get_item_count=function(n) return items[n] or 0 end
  c.can_reach_entity=function() return true end
  c.destroy=function() c.valid=false end
  return c
end
surface.find_non_colliding_position=function(_,origin) return origin end
surface.create_entity=function(args) if args.name=='character' then return character(args.position) end return {valid=true,name=args.name,position=args.position} end
surface.can_place_entity=function() return true end
surface.find_entities_filtered=function() return {} end
surface.get_total_pollution=function() return 0 end; surface.get_chunks=function() return function() end end; surface.get_pollution=function() return 0 end
surface.request_path=function() return 1 end
local nick={index=1,name='nick',valid=true,connected=true,controller_type=1,physical_controller_type=1,cheat_mode=false,driving=false,force=force,surface=surface,position={x=5,y=5},chat_color={r=1,g=1,b=1}}
nick.character=character({x=5,y=5})
local director={index=2,name='pog-director',valid=true,connected=true,controller_type=2,physical_controller_type=2,force=force,surface=surface,position={x=50,y=50}}
local players={nick,director}
for _,pl in ipairs(players) do pl.print=function() end end
local tick=0
game={tick=0,players=players,forces={player=force,enemy={name='enemy',get_evolution_factor=function() return 0 end,get_evolution_factor_by_time=function() return 0 end,
  get_evolution_factor_by_pollution=function() return 0 end,get_evolution_factor_by_killing_spawners=function() return 0 end}},
  -- As the engine: a bot's index is no player index.
  get_player=function(i) assert(type(i)=='string' or i<=65536,'Given player value is too big'); if type(i)=='string' then for _,p in ipairs(players) do if p.name==i then return p end end return nil end return players[i] end,
  get_surface=function() return surface end,print=function() end,connected_players=players,
  get_pollution_statistics=function() return {input_counts={},output_counts={},get_flow_count=function() return 0 end} end}
local runtime=dofile('mod/agent-harness_0.1.0/runtime.lua')
local function advance(n) for _=1,n do tick=tick+1; game.tick=tick; runtime.tick{tick=tick} end end
local function jump(n) tick=tick+n; game.tick=tick end
-- As control.lua does: a failed request stops its player unless the runtime
-- marked it passive.
local function request(req)
  local ok,result=pcall(runtime.dispatch,req)
  if not ok then
    local who=req.player or (req.bot==nil and 1 or nil)
    if req.bot then who=runtime.bots.index_of(req.bot) end
    if type(who)=='number' then pcall(runtime.stop_player,who) end
    error(result,0)
  end
  return result
end
local function as(name) return function(action,args) return request{action=action,args=args or {},bot=name} end end
local astra,sol,grok=as('astra'),as('sol'),as('grok')
local function op(action,args) return request{action=action,args=args or {},operator=true} end
runtime.operator.bot_create('astra'); runtime.operator.bot_create('sol'); runtime.operator.bot_create('grok')
astra('profile',{display_name='Astra',glyph='A',color='#9977ff'})
sol('profile',{display_name='Sunny',glyph='S',color='#ffcb45'})


-- Fakes: vehicles by position; a car that drives by its riding state.
defines.riding={acceleration={nothing=0,accelerating=1,braking=2,reversing=3},direction={left=0,straight=1,right=2}}
local world={}
surface.find_entities_filtered=function(f)
  local out={}
  if f.position then for _,e in ipairs(world) do if e.valid and math.abs(e.position.x-f.position.x)<1 and math.abs(e.position.y-f.position.y)<1 then out[#out+1]=e end end end
  return out
end
local function vehicle(name,type_,x,y)
  local v={valid=true,name=name,type=type_,position={x=x,y=y},force=force,speed=0,orientation=0.25}
  v.get_driver=function() return v.driver end
  v.get_passenger=function() return v.passenger end
  v.set_driver=function(c)
    if v.driver then v.driver.vehicle=nil; v.driver.driving=false end
    v.driver=c; if c then c.vehicle=v; c.driving=true end
  end
  v.set_passenger=function(c)
    if v.passenger then v.passenger.vehicle=nil; v.passenger.driving=false end
    v.passenger=c; if c then c.vehicle=v; c.driving=true end
  end
  world[#world+1]=v
  return v
end
local body=function(name) return runtime.lookup(runtime.bots.index_of(name)).character end
local a_body,s_body=body('astra'),body('sol')
a_body.position={x=0,y=0}; s_body.position={x=1,y=0}
local car=vehicle('car','car',3,0)

-- Get in: the driver's seat, then a passenger; on foot, vehicle reads false.
eq(astra('vehicle',{}).vehicle,false)
local r=astra('vehicle',{position={x=3,y=0},enter=true})
eq(r.vehicle.name,'car'); eq(r.vehicle.seat,'driver'); eq(car.driver,a_body)
r=sol('vehicle',{position={x=3,y=0},enter=true}); eq(r.vehicle.seat,'passenger')
fails(function() grok('vehicle',{position={x=3,y=0},enter=true}) end,'car is full')
-- Seated: what moves the body is refused and says how to get out; reads,
-- chat and the vehicle action still work.
fails(function() astra('move_to',{position={x=10,y=10}}) end,'vehicle {exit: true} gets out')
fails(function() astra('mine',{position={x=10,y=10}}) end,'vehicle {exit: true} gets out')
eq(astra('say',{text='driving!'}).seq~=nil,true)
eq(astra('vehicle',{}).vehicle.seat,'driver')
eq(astra('status').position~=nil,true)
fails(function() astra('vehicle',{position={x=3,y=0},enter=true}) end,'already in a vehicle')
-- Get out: the seat empties, the body acts again.
r=astra('vehicle',{exit=true}); eq(r.left,'car'); eq(r.vehicle,false); eq(car.driver,nil); eq(a_body.vehicle,nil)
eq(sol('vehicle',{exit=true}).left,'car'); eq(car.passenger,nil)
fails(function() astra('vehicle',{exit=true}) end,'not in a vehicle')
fails(function() astra('vehicle',{enter=true,exit=true,position={x=3,y=0}}) end,'give one of')

-- A train's locomotive has one seat.
local loco=vehicle('locomotive','locomotive',-3,0)
eq(astra('vehicle',{position={x=-3,y=0},enter=true}).vehicle.name,'locomotive')
fails(function() sol('vehicle',{position={x=-3,y=0},enter=true}) end,'its one seat has someone in it')
astra('vehicle',{exit=true})
-- Not a vehicle; too far.
local chest={valid=true,name='iron-chest',type='container',position={x=2,y=2},force=force}; world[#world+1]=chest
fails(function() astra('vehicle',{position={x=2,y=2},enter=true}) end,'iron-chest is not a vehicle you can get into')
local far=vehicle('tank','car',20,0)
fails(function() astra('vehicle',{position={x=20,y=0},enter=true}) end,'tank is 20.0 tiles away; get within 10 tiles')

-- A spidertron walks by itself, sent from outside.
local spider=vehicle('spidertron','spider-vehicle',4,4)
r=astra('vehicle',{position={x=4,y=4},go_to={x=40,y=40}}); eq(spider.autopilot_destination.x,40); eq(r.go_to.y,40)
fails(function() astra('vehicle',{position={x=3,y=0},go_to={x=1,y=1}}) end,'go_to is for a spidertron')

-- Drive a car to a position: steer, ease off, stop; the step simulates the car.
local function physics()
  local d=car.driver; local rs=d and d.riding_state
  if not rs then return end
  if rs.direction==defines.riding.direction.right then car.orientation=(car.orientation+0.01)%1
  elseif rs.direction==defines.riding.direction.left then car.orientation=(car.orientation-0.01)%1 end
  if rs.acceleration==defines.riding.acceleration.accelerating then car.speed=math.min(0.4,car.speed+0.01)
  elseif rs.acceleration==defines.riding.acceleration.braking then car.speed=math.max(0,car.speed-0.05)
  else car.speed=math.max(0,car.speed-0.002) end
  local a=car.orientation*2*math.pi
  car.position={x=car.position.x+math.sin(a)*car.speed,y=car.position.y-math.cos(a)*car.speed}
end
local blocked=false
local function drive_ticks(n) for _=1,n do if not blocked then physics() end; advance(1) end end
car.position={x=3,y=0}; car.orientation=0.25; car.speed=0
astra('vehicle',{position={x=3,y=0},enter=true})
r=astra('vehicle',{drive={x=60,y=20}}); eq(r.vehicle,'car'); eq(r.distance,60)
eq(astra('status').active.kind,'drive')
drive_ticks(1500)
local last=astra('status').last
eq(last.kind,'drive'); eq(last.outcome,'arrived')
assert(math.abs(car.position.x-60)<4 and math.abs(car.position.y-20)<4,car.position.x..','..car.position.y)
eq(a_body.riding_state.acceleration,defines.riding.acceleration.nothing)
-- A car that does not move (a wall): blocked after 3 seconds.
blocked=true
astra('vehicle',{drive={x=0,y=0}})
drive_ticks(200)
eq(astra('status').last.outcome,'blocked')
-- Only the driver drives; drive needs a car.
astra('vehicle',{exit=true})
car.position={x=3,y=0} -- (the fake character does not ride along; the game moves it with the car)
sol('vehicle',{position=car.position,enter=true}); astra('vehicle',{position=car.position,enter=true})
fails(function() astra('vehicle',{drive={x=1,y=1}}) end,'only the driver drives')
fails(function() grok('vehicle',{drive={x=1,y=1}}) end,'drive is for a car or tank you are in')
print('vehicles: ok')
