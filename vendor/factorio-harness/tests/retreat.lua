-- Run from repository root: lua tests/retreat.lua
-- Retreat (retreat.lua; operator 12:27, Astra after a tank loss and a death in shift12): move_to, shoot, kite and
-- vehicle drive with retreat {to, health_below, shield_below}, and the standing retreat_guard, through the runtime
-- against a fake engine.
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
local force={name='player',get_friend=function() return false end,get_cease_fire=function() return false end,chart=function() end,is_chunk_visible=function() return true end,is_chunk_charted=function() return true end,get_spawn_position=function() return {x=0,y=0} end}
local surface={name='nauvis',index=1}
local units=0
local function character(pos)
  local items={}
  units=units+1
  local c={valid=true,name='character',type='character',force=force,surface=surface,position=pos,unit_number=500+units,health=250,max_health=250,
    prototype={collision_box={left_top={x=-0.2,y=-0.2},right_bottom={x=0.2,y=0.2}},collision_mask={layers={player=true}}},
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
car.health=450; car.max_health=450
car.prototype={collision_box={left_top={x=-0.7,y=-1},right_bottom={x=0.7,y=1}},collision_mask={layers={car=true,player=true,train=true}}}
local asked={}
surface.request_path=function(a) asked[#asked+1]=a; return 900+#asked end
local function physics()
  local rs=car.riding_state
  if not rs then return end
  if rs.direction==defines.riding.direction.right then car.orientation=(car.orientation+0.01)%1
  elseif rs.direction==defines.riding.direction.left then car.orientation=(car.orientation-0.01)%1 end
  if rs.acceleration==defines.riding.acceleration.accelerating then car.speed=math.min(0.4,car.speed+0.01)
  elseif rs.acceleration==defines.riding.acceleration.braking then car.speed=math.max(0,car.speed-0.05)
  else car.speed=math.max(0,car.speed-0.002) end
  local a=car.orientation*2*math.pi
  car.position={x=car.position.x+math.sin(a)*car.speed,y=car.position.y-math.cos(a)*car.speed}
end

-- The standing guard: set, read, cleared; its arguments checked.
eq(astra('retreat_guard',{}).retreat_guard,false)
eq(astra('retreat_guard',{to={x=-20,y=0},health_below=0.5}).retreat_guard,'to (-20,0) at health under 50% (standing retreat_guard)')
eq(astra('status',{brief=true}).retreat_guard,'to (-20,0) at health under 50% (standing retreat_guard)')
eq(astra('retreat_guard',{}).retreat_guard,'to (-20,0) at health under 50% (standing retreat_guard)')
eq(astra('retreat_guard',{clear=true}).retreat_guard,false)
eq(astra('status',{brief=true}).retreat_guard,nil)
fails(function() astra('retreat_guard',{to={x=1,y=1},health_below=1.5}) end,'health_below is a fraction between 0 and 1')
fails(function() astra('retreat_guard',{clear=true,to={x=1,y=1}}) end,'clear goes alone')
fails(function() astra('retreat_guard',{health_below=0.3}) end,'retreat needs to:')
eq(astra('retreat_guard',{retreat_to={x=-5,y=5},shield_below=0.2}).retreat_guard,'to (-5,5) at shield under 20% (standing retreat_guard)')
astra('retreat_guard',{clear=true})

-- A walk with retreat: hit under 40%, it ends retreated and walks back to `to` at once; there, the walk back ends
-- retreated, saying why, from where and the health.
a_body.position={x=0,y=0}; a_body.health=250
local r=astra('move_to',{position={x=60,y=0},pathfind=false,retreat={to={x=-10,y=0},health_below=0.4}})
eq(r.retreat,'to (-10,0) at health under 40%')
advance(5); eq(astra('status').active.to.x,60)
a_body.position={x=20,y=0}; a_body.health=90
advance(5)
local act=astra('status').active
eq(act.kind,'move_to'); eq(act.to.x,-10)
assert(act.retreating:find('health 36% (90/250) under 40%; walking back to (-10,0)',1,true),act.retreating)
local last=astra('status').last
eq(last.outcome,'retreated'); eq(last.retreated.from.x,20); eq(last.retreated.health,'90/250')
a_body.position={x=-10,y=0}
advance(2)
last=astra('status').last
eq(last.outcome,'retreated'); eq(last.kind,'move_to')
assert(last.why:find('health 36% (90/250) under 40%; back at (-10,0)',1,true),last.why)
eq(last.retreated.to.x,-10); eq(last.retreated.health_now,'90/250')
eq(astra('status').active,false)
-- Already hurt when it starts, not hit since: no retreat (health under 40% but no lower than at the start).
a_body.health=80; a_body.position={x=20,y=0}
astra('move_to',{position={x=60,y=0},pathfind=false,retreat={to={x=-10,y=0}}})
advance(20)
eq(astra('status').active.to.x,60)
-- Hit again: it goes.
a_body.health=60
advance(5)
eq(astra('status').active.to.x,-10)
a_body.position={x=-10,y=0}; advance(2)
eq(astra('status').last.outcome,'retreated')
a_body.health=250
-- The standing guard applies to a walk without its own retreat; retreat=false skips it.
astra('retreat_guard',{to={x=-30,y=0},health_below=0.5})
a_body.position={x=0,y=0}
r=astra('move_to',{position={x=60,y=0},pathfind=false})
eq(r.retreat,'to (-30,0) at health under 50% (standing retreat_guard)')
a_body.health=100; advance(5)
eq(astra('status').active.to.x,-30); eq(astra('status').last.retreated.standing,true)
a_body.position={x=-30,y=0}; advance(2)
a_body.health=250
r=astra('move_to',{position={x=60,y=0},pathfind=false,retreat=false})
eq(r.retreat,nil)
a_body.health=100; advance(5)
eq(astra('status').active.to.x,60)
astra('stop',{}); a_body.health=250
-- shoot with the standing guard: hit under 50%, the guns stop (last_combat retreated) and it walks back.
a_body.get_inventory=function() return {get_item_count=function() return 10 end,is_empty=function() return false end} end
a_body.position={x=20,y=0}
local okshoot=pcall(astra,'shoot',{auto=true,ticks=300})
assert(okshoot,'shoot started')
if okshoot then
  a_body.health=100; advance(5)
  local lc=astra('status').last_combat
  eq(lc.outcome,'retreated'); assert(lc.why:find('health 40% (100/250) under 50%',1,true),lc.why)
  eq(astra('status').active.to.x,-30)
  a_body.position={x=-30,y=0}; advance(2)
end
a_body.get_inventory=nil; a_body.health=250
-- A queued walk with the standing guard: the retreat pauses the queue.
a_body.position={x=20,y=0}
astra('queue_submit',{steps={{action='move_to',args={position={x=60,y=0},pathfind=false}},{action='wait_ticks',args={ticks=10}}}})
advance(3)
eq(astra('status').active.to.x,60)
a_body.health=100; advance(5)
eq(astra('queue_status').paused,true)
eq(astra('status').active.to.x,-30)
a_body.position={x=-30,y=0}; advance(2)
eq(astra('status').last.outcome,'retreated')
astra('queue_cancel',{}); a_body.health=250
astra('retreat_guard',{clear=true})
-- A drive with retreat: the car's health under 40%, the drive ends retreated and the car is driven back to `to`.
car.position={x=3,y=0}; car.orientation=0.25; car.speed=0
a_body.position={x=1,y=0}
astra('vehicle',{position={x=3,y=0},enter=true})
asked={}
r=astra('vehicle',{drive={x=100,y=0},pathfind=false,retreat={to={x=-40,y=0},health_below=0.4}})
eq(r.retreat,'to (-40,0) at health under 40%')
for _=1,30 do physics(); advance(1) end
car.health=150
for _=1,5 do physics(); advance(1) end
act=astra('status').active
eq(act.kind,'drive')
assert(act.retreating:find('car health 33% (150/450) under 40%; driving the car back to (-40,0)',1,true),act.retreating)
last=astra('status').last
eq(last.outcome,'retreated'); eq(last.kind,'drive')
eq(#asked,1); eq(asked[1].goal.x,-40) -- the way back is asked for
-- Not on a dry run.
astra('vehicle',{drive={x=100,y=0},dry_run=true,retreat={to={x=-40,y=0}}})
astra('vehicle',{exit=true})
fails(function() astra('move_to',{position={x=1,y=1},retreat={to={x=1,y=1},shield_below=2}}) end,'shield_below is a fraction between 0 and 1')
fails(function() astra('move_to',{position={x=1,y=1},retreat='home'}) end,'retreat is {to: {x,y}')
print('retreat: ok')
