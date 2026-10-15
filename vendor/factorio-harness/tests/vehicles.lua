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
  local types
  if f.type then types={}; for _,t in ipairs(type(f.type)=='table' and f.type or {f.type}) do types[t]=true end end
  if f.position then for _,e in ipairs(world) do if e.valid and (not types or types[e.type]) and math.abs(e.position.x-f.position.x)<1 and math.abs(e.position.y-f.position.y)<1 then out[#out+1]=e end end end
  return out
end
local function vehicle(name,type_,x,y)
  local v={valid=true,name=name,type=type_,position={x=x,y=y},force=force,speed=0,orientation=0.25,surface=surface}
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

-- A train's locomotive has one seat; the rail under it does not make the
-- target ambiguous (live check: "ambiguous target: locomotive and straight-rail").
local loco=vehicle('locomotive','locomotive',-3,0)
world[#world+1]={valid=true,name='straight-rail',type='straight-rail',position={x=-3,y=0},force=force}
eq(astra('vehicle',{position={x=-3,y=0},enter=true}).vehicle.name,'locomotive')
fails(function() sol('vehicle',{position={x=-3,y=0},enter=true}) end,'its one seat has someone in it')
astra('vehicle',{exit=true})
-- Not a vehicle; too far.
local chest={valid=true,name='iron-chest',type='container',position={x=2,y=2},force=force}; world[#world+1]=chest
fails(function() astra('vehicle',{position={x=2,y=2},enter=true}) end,'no vehicle at (2,2)')
-- The seat is read back from the vehicle: a seat the game refused is an error, not a pretend ride.
local stubborn=vehicle('car','car',-1,2); stubborn.set_driver=function() end
fails(function() astra('vehicle',{position={x=-1,y=2},enter=true}) end,'the game did not seat the character in car (its driver seat holds nobody)')
eq(astra('vehicle',{}).vehicle,false); stubborn.valid=false
local far=vehicle('tank','car',20,0)
fails(function() astra('vehicle',{position={x=20,y=0},enter=true}) end,'tank is 20.0 tiles away; get within 10 tiles')

-- A spidertron walks by itself, sent from outside.
local spider=vehicle('spidertron','spider-vehicle',4,4)
spider.add_autopilot_destination=function(pos) spider.autopilot_destination=pos end
local tank_empty=true
spider.get_fuel_inventory=function() return {is_empty=function() return tank_empty end} end
r=astra('vehicle',{position={x=4,y=4},go_to={x=40,y=40}}); eq(spider.autopilot_destination.x,40); eq(r.go_to.y,40)
assert(r.note:find('no fuel',1,true),r.note) -- said, since it will not walk
tank_empty=false; eq(astra('vehicle',{position={x=4,y=4},go_to={x=41,y=40}}).note,nil)
fails(function() astra('vehicle',{position={x=3,y=0},go_to={x=1,y=1}}) end,'go_to is for a spidertron')

-- Drive a car to a position: steer, ease off, stop; the step simulates the car.
local function physics()
  local rs=car.riding_state -- the car's own riding state (what a bot driver can set)
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
r=astra('vehicle',{drive={x=60,y=20},pathfind=false}); eq(r.vehicle,'car'); eq(r.distance,60); eq(r.pathfinding,false)
eq(astra('status').active.kind,'drive')
drive_ticks(1500)
local last=astra('status').last
eq(last.kind,'drive'); eq(last.outcome,'arrived')
assert(math.abs(car.position.x-60)<4 and math.abs(car.position.y-20)<4,car.position.x..','..car.position.y)
eq(car.riding_state.acceleration,defines.riding.acceleration.nothing)
-- A car that does not move (a wall): blocked after 3 seconds.
blocked=true
astra('vehicle',{drive={x=0,y=0},pathfind=false})
drive_ticks(200)
eq(astra('status').last.outcome,'blocked')
-- The engine's path for the car's box (Opus, shift09 03:20: a tank driven
-- straight at its target got stuck on cliffs): it waits for the path, then
-- steers along it, around what the straight line would hit.
blocked=false
car.prototype={collision_box={left_top={x=-0.7,y=-1},right_bottom={x=0.7,y=1}},collision_mask={layers={car=true,player=true,train=true}}}
local asked={}
surface.request_path=function(a) asked[#asked+1]=a; return 900+#asked end
car.position={x=60,y=20}; car.orientation=0.25; car.speed=0
r=astra('vehicle',{drive={x=100,y=20}})
eq(r.pathfinding,true); eq(r.avoid_enemies,'worms (range + 4), spawners (40 tiles + 4) and areas under attack now (24 tiles + 4)')
-- first as wide as its diagonal plus a tile (1.22 + 0.5 for a 1.4 by 2.0 car)
eq(#asked,1); assert(math.abs(asked[1].bounding_box[2][1]-1.7207)<0.001,asked[1].bounding_box[2][1]); eq(asked[1].collision_mask.layers.car,true); eq(asked[1].entity_to_ignore,car); eq(asked[1].radius,4)
drive_ticks(30); eq(car.position.x,60) -- no path yet: it waits
runtime.on_event{name=10,id=901,path={{position={x=60,y=20}},{position={x=70,y=5}},{position={x=90,y=5}},{position={x=100,y=20}}}}
local lowest=20
for _=1,1500 do physics(); advance(1); lowest=math.min(lowest,car.position.y); if not astra('status').active then break end end
last=astra('status').last
eq(last.outcome,'arrived'); eq(last.path_length,56)
assert(lowest<9,'went along the path north of the straight line: lowest y '..lowest)
assert(math.abs(car.position.x-100)<4 and math.abs(car.position.y-20)<4,car.position.x..','..car.position.y)
-- Stuck on the way: backs up once with a fresh path, then ends blocked naming what is in front.
asked={}
r=astra('vehicle',{drive={x=140,y=20}})
runtime.on_event{name=10,id=901,path={{position={x=100,y=20}},{position={x=140,y=20}}}}
blocked=true
drive_ticks(95)
eq(car.riding_state.acceleration,defines.riding.acceleration.reversing) -- backing up
drive_ticks(60)
eq(#asked,2) -- a new path from where it stopped
runtime.on_event{name=10,id=902,path={{position={x=100,y=20}},{position={x=140,y=20}}}}
drive_ticks(100)
last=astra('status').last
eq(last.outcome,'blocked')
assert(last.why:find('again after backing off once',1,true) and last.why:find('in front: nothing that collides',1,true),last.why)
assert(last.backed_up:find('backed off and asked for a new path',1,true),last.backed_up)
-- No path for the car's turning room, nor to open ground near the target, nor for its length or width:
-- unreachable, saying so (drivesafe: the turning room first, then near the target, then narrower).
blocked=false; asked={}
astra('vehicle',{drive={x=100,y=90}})
runtime.on_event{name=10,id=901}
eq(#asked,2); assert(math.abs(asked[2].bounding_box[2][1]-1.7207)<0.001); eq(asked[2].radius,8) -- open ground within 8
runtime.on_event{name=10,id=902}
eq(#asked,3); eq(asked[3].radius,13) -- within 13
runtime.on_event{name=10,id=903}
eq(#asked,4); eq(asked[4].bounding_box[2][1],1) -- as wide as it is long
runtime.on_event{name=10,id=904}
eq(#asked,5); eq(asked[5].bounding_box[2][1],0.7) -- as wide as it is wide
runtime.on_event{name=10,id=905}
drive_ticks(1)
last=astra('status').last
eq(last.outcome,'unreachable'); eq(last.why,'no path for the car (1.4 by 2.0 tiles) to (100,90)')
fails(function() astra('vehicle',{drive={x=1,y=1},pathfind='yes'}) end,'pathfind must be true or false')
fails(function() astra('vehicle',{drive={x=1,y=1},reverse=1}) end,'reverse must be true or false')
-- Units are no block (Astra, shift10 04:10: a drive into an attack group ended
-- blocked and left the tank surrounded): pressed against biters only, the
-- throttle stays down and the drive goes on; they count as rammed.
local area_finds={}
local plain_find=surface.find_entities_filtered
surface.find_entities_filtered=function(f) if f.area then return area_finds end return plain_find(f) end
local biter={valid=true,name='medium-biter',type='unit',unit_number=7001,position={x=0,y=0},prototype={collision_mask={layers={player=true}}}}
car.position={x=100,y=90}; car.orientation=0.25; car.speed=0
asked={}
astra('vehicle',{drive={x=140,y=90}})
runtime.on_event{name=10,id=901,path={{position={x=100,y=90}},{position={x=140,y=90}}}}
blocked=true; area_finds={biter}
drive_ticks(200)
eq(astra('status').active.kind,'drive') -- no back-up, not blocked
eq(car.riding_state.acceleration,defines.riding.acceleration.accelerating)
eq(#asked,1)
-- A unit hit by the car (its impact damage) counts too, once each.
runtime.on_event{name=12,entity={valid=true,name='small-biter',type='unit',unit_number=7002,position={x=1,y=1}},cause=car,final_damage_amount=30}
runtime.on_event{name=12,entity={valid=true,name='small-biter',type='unit',unit_number=7002,position={x=1,y=1}},cause=car,final_damage_amount=30}
blocked=false; area_finds={}
drive_ticks(600)
last=astra('status').last
eq(last.outcome,'arrived'); eq(last.rammed,2)
-- A wall is: backed off once, then blocked.
local wall={valid=true,name='stone-wall',type='wall',position={x=0,y=0},prototype={collision_mask={layers={player=true,object=true}}}}
asked={}
astra('vehicle',{drive={x=180,y=90}})
runtime.on_event{name=10,id=901,path={{position={x=140,y=90}},{position={x=180,y=90}}}}
blocked=true; area_finds={wall}
drive_ticks(95)
eq(car.riding_state.acceleration,defines.riding.acceleration.reversing)
drive_ticks(60)
runtime.on_event{name=10,id=902,path={{position={x=140,y=90}},{position={x=180,y=90}}}}
drive_ticks(100)
last=astra('status').last
eq(last.outcome,'blocked'); eq(last.rammed,nil)
-- reverse: rear first, the reverse pedal; backing off an obstacle uses the forward one.
blocked=false; area_finds={}
local function physics_r()
  local rs=car.riding_state
  if not rs then return end
  if rs.direction==defines.riding.direction.right then car.orientation=(car.orientation+0.01)%1
  elseif rs.direction==defines.riding.direction.left then car.orientation=(car.orientation-0.01)%1 end
  if rs.acceleration==defines.riding.acceleration.accelerating then car.speed=math.min(0.4,car.speed+0.01)
  elseif rs.acceleration==defines.riding.acceleration.reversing then car.speed=math.max(-0.2,car.speed-0.01)
  elseif rs.acceleration==defines.riding.acceleration.braking then car.speed=car.speed>0 and math.max(0,car.speed-0.05) or math.min(0,car.speed+0.05)
  else car.speed=car.speed*0.99 end
  local a=car.orientation*2*math.pi
  car.position={x=car.position.x+math.sin(a)*car.speed,y=car.position.y-math.cos(a)*car.speed}
end
car.position={x=140,y=90}; car.orientation=0.25; car.speed=0 -- facing east
asked={}
r=astra('vehicle',{drive={x=110,y=90},reverse=true}) -- behind it
eq(r.reverse,true)
runtime.on_event{name=10,id=901,path={{position={x=140,y=90}},{position={x=110,y=90}}}}
local turned_most=0
for _=1,900 do physics_r(); advance(1); turned_most=math.max(turned_most,math.abs(((car.orientation-0.25)+0.5)%1-0.5)); if not astra('status').active then break end end
last=astra('status').last
eq(last.outcome,'arrived'); eq(last.reverse,true)
assert(turned_most<0.05,'backed straight there without turning round: '..turned_most)
assert(math.abs(car.position.x-110)<4,car.position.x)
-- drivesafe (Astra, operator 12:06: a tank drive crushed 7 of our oil entities, a pumpjack among them): our
-- entities as boxes the fake finds by area and force.
local ours={}
local function our(name,x,y,hw,hh)
  local e={valid=true,name=name,type='pipe',force=force,position={x=x,y=y},unit_number=7000+#ours,
    bounding_box={left_top={x=x-(hw or 0.3),y=y-(hh or 0.3)},right_bottom={x=x+(hw or 0.3),y=y+(hh or 0.3)}},
    prototype={collision_mask={layers={player=true,object=true}}}}
  ours[#ours+1]=e
  return e
end
local function corners(a) local lt,rb=a[1] or a.left_top,a[2] or a.right_bottom; return lt[1] or lt.x,lt[2] or lt.y,rb[1] or rb.x,rb[2] or rb.y end
surface.find_entities_filtered=function(f)
  if f.area then
    local l,t,r,b=corners(f.area)
    local out={}
    for _,e in ipairs(ours) do
      local bb=e.bounding_box
      if e.valid and bb.right_bottom.x>=l and bb.left_top.x<=r and bb.right_bottom.y>=t and bb.left_top.y<=b and (f.force==nil or f.force==e.force) then out[#out+1]=e end
    end
    return out
  end
  return plain_find(f)
end
-- Whether the car's turned box (1.4 by 2.0) overlaps a box: separating axes.
local function overlaps(bb)
  local o=car.orientation*2*math.pi
  local fx,fy,rx,ry=math.sin(o),-math.cos(o),math.cos(o),math.sin(o)
  local cs={}
  for _,s in ipairs{{1,1},{1,-1},{-1,1},{-1,-1}} do cs[#cs+1]={x=car.position.x+fx*s[1]+rx*0.7*s[2],y=car.position.y+fy*s[1]+ry*0.7*s[2]} end
  local function sep(ax,ay,list1,list2)
    local a1,b1,a2,b2=math.huge,-math.huge,math.huge,-math.huge
    for _,q in ipairs(list1) do local d=q.x*ax+q.y*ay; a1=math.min(a1,d); b1=math.max(b1,d) end
    for _,q in ipairs(list2) do local d=q.x*ax+q.y*ay; a2=math.min(a2,d); b2=math.max(b2,d) end
    return b1<a2 or b2<a1
  end
  local bc={{x=bb.left_top.x,y=bb.left_top.y},{x=bb.right_bottom.x,y=bb.left_top.y},{x=bb.left_top.x,y=bb.right_bottom.y},{x=bb.right_bottom.x,y=bb.right_bottom.y}}
  for _,ax in ipairs{{1,0},{0,1},{fx,fy},{rx,ry}} do if sep(ax[1],ax[2],cs,bc) then return false end end
  return true
end
local function drive_watch(n,watch)
  local touched=false
  for _=1,n do physics_r(); advance(1); for _,e in ipairs(watch or ours) do if overlaps(e.bounding_box) then touched=true end end; if not astra('status').active then break end end
  return touched
end
-- Straight at one of ours: it brakes to stop 0.5 tiles short and ends blocked naming it, never touching it.
ours={}; our('pipe',230.5,90.5)
car.position={x=200,y=90.5}; car.orientation=0.25; car.speed=0
astra('vehicle',{drive={x=260,y=90.5},pathfind=false})
eq(drive_watch(900),false)
last=astra('status').last
eq(last.outcome,'blocked'); assert(last.why:find('to spare our pipe (230.5,90.5)',1,true),last.why); eq(last.spared,'pipe (230.5,90.5)')
assert(car.position.x>226,'it got close: '..car.position.x)
-- Turning at a crawl with ours within its corners' sweep: the wheel stays straight until it is clear.
ours={}; our('pipe',100.5,91.8)
car.position={x=100,y=90.5}; car.orientation=0.25; car.speed=0
astra('vehicle',{drive={x=70,y=90.5},pathfind=false})
advance(1); eq(car.riding_state.direction,defines.riding.direction.straight)
eq(drive_watch(900),false)
-- A narrow path past ours is not taken: no turning-room path (nor near the target), the length and width paths pass
-- our pipe within the turning room: unreachable, naming it.
ours={}; our('pipe',150.5,95.5)
car.position={x=120,y=90.5}; car.orientation=0.25; car.speed=0
asked={}
astra('vehicle',{drive={x=180,y=90.5}})
for id=901,903 do runtime.on_event{name=10,id=id} end
eq(#asked,4); eq(asked[4].bounding_box[2][1],1)
local squeeze={{position={x=120,y=90.5}},{position={x=150,y=94.3}},{position={x=180,y=90.5}}}
runtime.on_event{name=10,id=904,path=squeeze}
eq(#asked,5); eq(asked[5].bounding_box[2][1],0.7) -- the length path passed it: the width next
runtime.on_event{name=10,id=905,path=squeeze}
advance(1)
last=astra('status').last
eq(last.outcome,'unreachable')
assert(last.why:find("no path keeps the car's turning room",1,true) and last.why:find('the path for its width passes our pipe (150.5,95.5) 0.',1,true),last.why)
-- None by it: the turning room near the target is taken, and the drive stops at its end (stopped_short).
ours={}
car.position={x=120,y=90.5}; car.orientation=0.25; car.speed=0
asked={}
astra('vehicle',{drive={x=180,y=90.5}})
runtime.on_event{name=10,id=901}
eq(asked[2].radius,8)
runtime.on_event{name=10,id=902,path={{position={x=120,y=90.5}},{position={x=150,y=90.5}},{position={x=174,y=90.5}}}}
eq(drive_watch(1500),false)
last=astra('status').last
eq(last.outcome,'arrived'); eq(last.plan,'turning room, near the target')
assert(last.stopped_short:find('6.0 tiles from (180,90.5)',1,true),last.stopped_short)
assert(math.abs(car.position.x-174)<2,'stopped at the path end: '..car.position.x)
-- Parked beside ours (the turning box collides there): the plan starts at the nearest spot where it fits, and the
-- path begins where the car stands.
ours={}; our('pipe',121,91.6)
car.position={x=120,y=90.5}; car.orientation=0.25; car.speed=0
asked={}
r=astra('vehicle',{drive={x=150,y=90.5},dry_run=true})
eq(r.dry_run,true)
assert(asked[1].start.x~=120 or asked[1].start.y~=90.5,'started elsewhere')
local lead=asked[1].start
runtime.on_event{name=10,id=901,path={{position=lead},{position={x=150,y=90.5}}}}
advance(1)
last=astra('status').last
eq(last.outcome,'previewed'); eq(car.position.x,120)
assert(last.preview.path:find('^%(120,90.5%) '),last.preview.path); eq(last.preview.plan,'turning room')
assert(last.preview.touches:find('^pipe %(121,91.5%) [01]%.%d tiles$'),last.preview.touches) -- beside it as it drives off
assert(last.preview.nearest_ours:find('pipe (121,91.5), ',1,true),last.preview.nearest_ours)
-- A dry run straight at the target: the line and what it would touch.
ours={}; our('pipe',140.5,90.5)
astra('vehicle',{drive={x=160,y=90.5},pathfind=false,dry_run=true})
advance(1)
last=astra('status').last
eq(last.outcome,'previewed'); eq(last.preview.touches,'pipe (140.5,90.5) 0.0 tiles'); eq(car.position.x,120)
fails(function() astra('vehicle',{drive={x=160,y=90.5},dry_run='yes'}) end,'dry_run must be true or false')
ours={}
surface.find_entities_filtered=plain_find
-- Only the driver drives; drive needs a car.
astra('vehicle',{exit=true})
car.position={x=3,y=0} -- (the fake character does not ride along; the game moves it with the car)
sol('vehicle',{position=car.position,enter=true}); astra('vehicle',{position=car.position,enter=true})
fails(function() astra('vehicle',{drive={x=1,y=1}}) end,'only the driver drives')
fails(function() grok('vehicle',{drive={x=1,y=1}}) end,'drive is for a car or tank you are in')
-- Vehicle guns (shift09 00:00, Opus and Astra: shoot refused in a tank, a
-- tank lost at a nest): the gunner fires the vehicle's selected gun from its
-- ammo slots, aimed at the entity it selects; drive goes on meanwhile.
astra('vehicle',{exit=true}); sol('vehicle',{exit=true})
defines.shooting.shooting_selected=2
defines.inventory.car_ammo=3; defines.inventory.spider_ammo=3; defines.inventory.character_ammo=4
prototypes={item={['cannon-shell']={type='ammo',ammo_category={name='cannon-shell'}},['explosive-cannon-shell']={type='ammo',ammo_category={name='cannon-shell'}},
  ['firearm-magazine']={type='ammo',ammo_category={name='bullet'}},['flamethrower-ammo']={type='ammo',ammo_category={name='flamethrower'}},['iron-plate']={type='item'}},entity={}}
local function stack(name,count)
  local st={quality={name='normal'}}
  local function set(n,c) st.name=n; st.count=c; st.valid_for_read=n~=nil and c>0 end
  set(name,count or 0)
  st.clear=function() set(nil,0) end
  st.transfer_stack=function(src)
    if st.valid_for_read and st.name~=src.name then return false end
    set(src.name,(st.valid_for_read and st.count or 0)+src.count); src.clear(); return true
  end
  return st
end
local function inventory(list)
  local inv={}
  for i,x in ipairs(list) do inv[i]=stack(x[1],x[2]) end
  local mt={__len=function() return #list end}
  inv.get_contents=function() local out={} for i=1,#list do local st=inv[i] if st.valid_for_read then out[#out+1]={name=st.name,count=st.count,quality='normal'} end end return out end
  inv.find_item_stack=function(name) for i=1,#list do if inv[i].valid_for_read and inv[i].name==name then return inv[i] end end end
  inv.insert=function(it) for i=1,#list do local st=inv[i] if not st.valid_for_read or st.name==it.name then st.name=it.name; st.count=(st.valid_for_read and st.count or 0)+it.count; st.valid_for_read=true; return it.count end end return 0 end
  inv.get_item_count=function(n) local c=0 for i=1,#list do if inv[i].valid_for_read and (not n or inv[i].name==n) then c=c+inv[i].count end end return c end
  return setmetatable(inv,mt)
end
local GUNS={{name='tank-cannon',attack_parameters={ammo_categories={'cannon-shell'},range=30}},{name='tank-machine-gun',attack_parameters={ammo_categories={'bullet'},range=20}},
  {name='tank-flamethrower',attack_parameters={ammo_categories={'flamethrower'},range=9}}}
local tank=vehicle('tank','car',6,0)
tank.prototype={indexed_guns=GUNS,collision_box={left_top={x=-0.9,y=-1.3},right_bottom={x=0.9,y=1.3}},collision_mask={layers={car=true,player=true,train=true}}}
tank.ammo=inventory({{'cannon-shell',10},{'firearm-magazine',20},{nil,0}})
tank.get_inventory=function(id) return id==3 and tank.ammo or nil end
tank.selected_gun_index=1; tank.driver_is_gunner=false
local enemy_force={name='enemy'}
force.get_friend=function() return false end; force.get_cease_fire=function() return false end
game.forces.enemy.get_friend=function() return false end
local wall={valid=true,name='stone-wall',type='wall',position={x=6.5,y=-20.5},force=enemy_force,health=350}
world[#world+1]=wall
-- find by area/radius too (the target at a position, the auto scan)
local find=surface.find_entities_filtered
surface.find_entities_filtered=function(f)
  if f.radius and f.position then
    local out={}
    for _,e in ipairs(world) do
      local d=((e.position.x-f.position.x)^2+(e.position.y-f.position.y)^2)^0.5
      local okf=true
      if f.force then okf=false; for _,x in ipairs(type(f.force)=='table' and f.force[1] and f.force or {f.force}) do if e.force==x or (type(x)=='table' and e.force and x.name==e.force.name) then okf=true end end end
      local okt=true
      if f.type then okt=false; for _,t in ipairs(type(f.type)=='table' and f.type or {f.type}) do if e.type==t then okt=true end end end
      if e.valid and d<=f.radius and okf and okt then out[#out+1]=e end
    end
    return out
  end
  return find(f)
end
a_body.position={x=5,y=0}
a_body.items['explosive-cannon-shell']=nil
local main=inventory({{'explosive-cannon-shell',8},{nil,0},{nil,0}})
a_body.get_main_inventory=function() return main end
local own_ammo=inventory({{'firearm-magazine',30}})
a_body.get_inventory=function(id) return id==4 and own_ammo or nil end
astra('vehicle',{position={x=6,y=0},enter=true})
-- The machine gun at the wall: slot 2, its ammo, the target and the guns in the reply.
r=astra('shoot',{position={x=6.5,y=-20.5},gun='tank-machine-gun',ticks=60})
eq(r.vehicle,'tank'); eq(r.seat,'driver'); eq(r.gun,'tank-machine-gun'); eq(r.gun_slot,2); eq(r.range,20); eq(tank.selected_gun_index,2)
eq(r.guns[2],'2 tank-machine-gun: 20 firearm-magazine (range 20) selected'); eq(r.guns[3],'3 tank-flamethrower: no ammo (range 9)')
eq(r.target,'stone-wall at (6.5,-20.5), 20.5 tiles from the tank')
eq(r.out_of_range,'tank-machine-gun reaches 20 tiles; the target is 20.5 away')
advance(1)
eq(a_body.selected,wall); eq(a_body.shooting_state.state,2); eq(a_body.shooting_state.position.y,-20.5)
eq(astra('status').combat.gun,'tank-machine-gun')
tank.ammo[2].count=17
wall.valid=false; advance(1)
local lc=astra('status').last_combat
eq(lc.outcome,'target_destroyed'); eq(lc.ammo_used,3); eq(lc.gun,'tank-machine-gun'); eq(lc.guns[2],'2 tank-machine-gun: 17 firearm-magazine (range 20) selected')
eq(a_body.shooting_state.state,0); eq(a_body.selected,nil)
-- ammo= picks the cannon and swaps its shells for the kind asked, from the inventory.
wall.valid=true
r=astra('shoot',{position={x=6.5,y=-20.5},ammo='explosive-cannon-shell',ticks=60})
eq(r.gun_slot,1); eq(r.equipped,'loaded 10 cannon-shell back to your inventory; 8 explosive-cannon-shell from your inventory to gun slot 1')
eq(tank.ammo[1].name,'explosive-cannon-shell'); eq(main.get_item_count('cannon-shell'),10)
-- An empty slot is loaded from the character's own ammo slots when the inventory has none.
tank.ammo[2].clear()
r=astra('shoot',{position={x=6.5,y=-20.5},gun_slot=2,ticks=60})
eq(r.equipped,'loaded 30 firearm-magazine from your ammo slots to gun slot 2'); eq(own_ammo.get_item_count(),0)
-- Nothing for the flamethrower anywhere.
fails(function() astra('shoot',{position={x=6.5,y=-20.5},gun='tank-flamethrower'}) end,'no ammunition for tank-flamethrower (gun slot 3: flamethrower) in tank or in your inventory')
fails(function() astra('shoot',{position={x=6.5,y=-20.5},gun='tank-rocket'}) end,'no gun tank-rocket on this vehicle (guns: tank-cannon, tank-machine-gun, tank-flamethrower)')
fails(function() astra('shoot',{position={x=6.5,y=-20.5},ammo='iron-plate'}) end,'fits none of this vehicle')
fails(function() astra('shoot',{position={x=12,y=12}}) end,'nothing at (12,12) to aim at')
-- auto: the nearest enemy in the gun's range, selected each scan.
local biter={valid=true,name='small-biter',type='unit',position={x=6,y=-10},force=game.forces.enemy,health=15}
world[#world+1]=biter
r=astra('shoot',{auto=true,gun='tank-machine-gun',ticks=120})
advance(1); eq(a_body.selected,biter); eq(a_body.shooting_state.state,2)
-- Driving while firing: the drive is the action, the gun the combat channel.
car.valid=false
local rode=astra('vehicle',{drive={x=6,y=-30}}); eq(rode.vehicle,'tank')
eq(astra('status').active.kind,'drive'); eq(astra('status').combat.auto,true)
advance(1); eq(a_body.shooting_state.state,2)
-- Out of the seat: the shot ends.
astra('vehicle',{exit=true}); advance(1)
eq(astra('status').last_combat.outcome,'left_vehicle')
-- The passenger works the guns only when driver_is_gunner is off; on foot gun/ammo are refused.
tank.driver_is_gunner=true
astra('vehicle',{position={x=6,y=0},enter=true}); sol('vehicle',{position={x=6,y=0},enter=true})
fails(function() sol('shoot',{auto=true}) end,'the driver works the guns of tank (driver_is_gunner true)')
tank.driver_is_gunner=false
eq(sol('shoot',{auto=true,ticks=10}).seat,'passenger')
fails(function() astra('shoot',{auto=true}) end,'the passenger works the guns of tank (driver_is_gunner false)')
astra('vehicle',{exit=true}); sol('vehicle',{exit=true})
fails(function() grok('shoot',{auto=true,ammo='cannon-shell'}) end,'gun and ammo pick a vehicle')
-- The vehicle read lists its guns.
eq(astra('vehicle',{position={x=6,y=0},enter=true}).vehicle.guns[1],'1 tank-cannon: 8 explosive-cannon-shell (range 30)')

-- Drive with combat (Astra, operator 08:34: shoot runs at most 600 ticks while a drive runs a minute or more): the
-- guns on auto for the whole drive, stopping with it; rounds fired and kills in last.
prototypes.item['firearm-magazine'].magazine_size=10
tank.selected_gun_index=2
tank.ammo[2].name='firearm-magazine'; tank.ammo[2].count=20; tank.ammo[2].valid_for_read=true
biter.valid=true
r=astra('vehicle',{drive={x=6,y=-60},combat=true,ticks=5,pathfind=false})
eq(r.combat.gun,'tank-machine-gun'); eq(r.combat.gun_slot,2)
eq(astra('status').combat.auto,true); eq(astra('status').active.kind,'drive')
advance(1); eq(a_body.selected,biter); eq(a_body.shooting_state.state,2)
-- two magazines fired, the biter killed by the tank's gun; the drive's time runs out
tank.ammo[2].count=18
runtime.on_event{name=defines.events.on_entity_died,entity=biter,cause=tank}
biter.valid=false
advance(5)
last=astra('status').last
eq(last.kind,'drive'); eq(last.outcome,'timed_out'); eq(last.shots,20); eq(last.kills,1); eq(last.kills_by_name,'1 small-biter')
advance(1); eq(astra('status').last_combat.outcome,'drive_ended'); eq(astra('status').last_combat.kills,1)
eq(a_body.shooting_state.state,0)
-- A gun out of ammo mid-drive: the drive goes on, its last still counts what was fired.
r=astra('vehicle',{drive={x=6,y=-60},combat=true,ticks=5,pathfind=false})
tank.ammo[2].clear(); main=inventory({{nil,0}}); own_ammo=inventory({{nil,0}})
advance(1); eq(astra('status').last_combat.outcome,'out_of_ammo'); eq(astra('status').active.kind,'drive')
advance(5); last=astra('status').last
eq(last.shots,180); eq(last.kills,0); eq(last.combat_ended,'out_of_ammo')
astra('vehicle',{exit=true})

-- Remote driving (operator 08:32, a viewer via Astra: to cut character deaths): one of our cars or tanks in view,
-- driven by remote view while the character stays where it is.
local rcar=vehicle('car','car',30,0); rcar.unit_number=9001
rcar.prototype={collision_box={left_top={x=-0.7,y=-1},right_bottom={x=0.7,y=1}},collision_mask={layers={car=true,player=true,train=true}}}
game.get_entity_by_unit_number=function(n) for _,e in ipairs(world) do if e.valid and e.unit_number==n then return e end end end
a_body.position={x=0,y=0}; s_body.position={x=29,y=0}
r=astra('vehicle',{drive={x=60,y=0},remote=true,vehicle=9001,pathfind=false})
eq(r.remote,'by remote view: car (30,0), unit_number 9001; your character stays at (0,0)')
advance(1)
eq(rcar.riding_state.acceleration,defines.riding.acceleration.accelerating); eq(a_body.position.x,0); eq(a_body.vehicle,nil)
eq(astra('status').active.kind,'drive')
-- Its driver seat is taken: another agent's remote drive is refused, and one getting in takes the passenger seat.
fails(function() sol('vehicle',{drive={x=60,y=0},remote=true,vehicle=9001}) end,'car (30,0): astra drives it remotely')
eq(sol('vehicle',{position={x=30,y=0},enter=true}).vehicle.seat,'passenger')
sol('vehicle',{exit=true})
-- Someone in the driver seat ends it, and so does leaving the chunks our force sees.
rcar.driver=s_body; advance(1)
last=astra('status').last
eq(last.outcome,'driver_seated'); eq(last.remote,true); assert(last.vehicle:find('^car, unit_number 9001, at %('),last.vehicle)
assert(last.why:find("sol's character got into its driver seat",1,true),last.why)
eq(rcar.riding_state.acceleration,defines.riding.acceleration.braking)
rcar.driver=nil
astra('vehicle',{drive={x=60,y=0},remote=true,vehicle={x=30,y=0},pathfind=false})
local seen_fn=force.is_chunk_visible
force.is_chunk_visible=function() return false end
advance(31)
last=astra('status').last
eq(last.outcome,'out_of_coverage'); assert(last.why:find('left the chunks our force sees',1,true),last.why)
-- Refused, as the game refuses: out of view (naming the nearest coverage), a driver seated, not ours, not a car.
fails(function() astra('vehicle',{drive={x=60,y=0},remote=true,vehicle=9001}) end,'car (30,0) is in no chunk our force sees now (radar coverage or a character\'s sight): remote driving needs it in view; no chunk within 256 tiles')
force.is_chunk_visible=seen_fn
rcar.driver=s_body
fails(function() astra('vehicle',{drive={x=60,y=0},remote=true,vehicle=9001}) end,"car (30,0): its driver seat holds sol's character")
rcar.driver=nil
rcar.force={name='other'}
fails(function() astra('vehicle',{drive={x=60,y=0},remote=true,vehicle=9001}) end,'car (30,0) is not ours')
rcar.force=force
spider.unit_number=9002
fails(function() astra('vehicle',{drive={x=60,y=0},remote=true,vehicle=9002}) end,'remote drive is for a car or tank; a spidertron walks by itself')
fails(function() astra('vehicle',{drive={x=60,y=0},remote=true,vehicle=12345}) end,'no vehicle has unit_number 12345')
fails(function() astra('vehicle',{drive={x=60,y=0},remote=true}) end,'remote drive needs vehicle')
fails(function() astra('vehicle',{remote=true,vehicle=9001}) end,'remote goes with drive')
-- Its guns stay silent by remote view: the game fires them for a gunner seated in it or a player driving it remotely.
fails(function() astra('vehicle',{drive={x=60,y=0},remote=true,vehicle=9001,combat=true}) end,'a remote drive cannot fire its guns')
fails(function() astra('shoot',{auto=true,vehicle=9001}) end,'an agent fires a vehicle\'s guns only seated in it')
-- A vehicle's equipment grid (operator 09:13, a viewer via Astra): insert, list and remove there, in reach or seated.
do
  local g={width=6,height=8,equipment={},shield=0,max_shield=0,available_in_batteries=0,battery_capacity=0}
  g.put=function(args)
    if #g.equipment>=2 then return nil end
    local e={name=args.name,position=args.position or {x=#g.equipment*2,y=0},shape={width=2,height=2},quality={name='normal'},prototype={take_result={name=args.name}}}
    g.equipment[#g.equipment+1]=e; return e
  end
  g.get=function(pos) for _,e in ipairs(g.equipment) do if e.position.x==pos.x and e.position.y==pos.y then return e end end end
  g.take=function(args) for i,e in ipairs(g.equipment) do if e==args.equipment then table.remove(g.equipment,i); return {name=e.name,quality='normal',count=1} end end end
  tank.grid=g; tank.unit_number=9100
  local held={['energy-shield-equipment']=3}
  local inv={find_item_stack=function(q)
      local name=type(q)=='table' and q.name or q
      if not held[name] or held[name]==0 then return nil end
      local st={name=name,quality='normal',prototype={place_as_equipment_result={name=name}}}
      return setmetatable(st,{__newindex=function(t,k,v) if k=='count' then held[name]=v else rawset(t,k,v) end end,__index=function(t,k) if k=='count' then return held[name] end end})
    end,
    can_insert=function() return true end,insert=function(it) held[it.name]=(held[it.name] or 0)+it.count; return it.count end}
  a_body.get_main_inventory=function() return inv end
  if a_body.vehicle then astra('vehicle',{exit=true}) end
  r=astra('equipment',{vehicle=9100,operation='insert',item='energy-shield-equipment'})
  eq(r.inserted,'energy-shield-equipment'); eq(r.where,'tank (6,0), unit_number 9100'); eq(r.grid.equipment,'energy-shield-equipment*1'); eq(held['energy-shield-equipment'],2)
  r=astra('equipment',{vehicle={x=6,y=0}})
  eq(r.grid,'6x8'); eq(#r.rows,1); eq(r.rows[1].position.x,0); eq(r.free_cells,44)
  r=astra('equipment',{vehicle=9100,operation='insert',item='energy-shield-equipment'}); eq(r.grid.equipment,'energy-shield-equipment*2')
  -- Full: says how much room is left.
  fails(function() astra('equipment',{vehicle=9100,operation='insert',item='energy-shield-equipment'}) end,'energy-shield-equipment does not fit in tank (6,0), unit_number 9100 6x8 (40 free cells)')
  r=astra('equipment',{vehicle=9100,operation='remove',position={x=0,y=0}})
  eq(r.removed,'energy-shield-equipment'); eq(r.grid.equipment,'energy-shield-equipment*1'); eq(held['energy-shield-equipment'],2)
  -- Seated in it, the same; a car has no grid.
  astra('vehicle',{position={x=6,y=0},enter=true})
  eq(astra('equipment',{vehicle=9100}).where,'tank (6,0), unit_number 9100 (seated)')
  astra('vehicle',{exit=true})
  rcar.valid=true
  fails(function() astra('equipment',{vehicle=9001,operation='list'}) end,'car (30,0) has no equipment grid')
  fails(function() astra('equipment',{operation='bogus'}) end,'operation must be insert, remove or list')
end
print('vehicles: ok')
