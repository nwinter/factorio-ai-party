-- Run from repository root: lua tests/d28_batch310b.lua
-- (d28 batch310 item 5, viewer Aurora site 10:28: "another engineer's vehicle clear advances the route revision, but an
-- older spider_kite treats the empty route as arrival and can recreate its old route. Please make the old controller
-- yield on clear, same-target replacement and append, including delayed path results.") Two callers on one spidertron
-- through the runtime's dispatch (tests/d28_batch300.lua's fake engine): astra's spider_kite walking back to its
-- position yields at its next read when sol clears, replaces with the same target, or appends; it never writes its
-- route back, its path round water that comes later is not written, and the switches stay as they stand. On main the
-- kite took the cleared route as arrival and wrote its route again, and kept the route after a same-target go_to or an
-- append. A go_to's own path asked before another call's change is not written either. A retreat armed by the new
-- go_to still fires.
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

-- A spidertron: its route as the game keeps it, health and a grid with a shield.
local spider=vehicle('spidertron','spider-vehicle',4,4)
spider.unit_number=7001; spider.health=3000; spider.max_health=3000; spider.grid={shield=100,max_shield=100}
local spider_route={}
setmetatable(spider,{__index=function(_,k)
  if k=='autopilot_destinations' then local out={} for i,d in ipairs(spider_route) do out[i]=d end return out end
  if k=='autopilot_destination' then return spider_route[1] end
end,__newindex=function(t,k,v) if k=='autopilot_destination' then spider_route=v and {v} or {} else rawset(t,k,v) end end})
spider.add_autopilot_destination=function(pos) spider_route[#spider_route+1]={x=pos.x,y=pos.y} end
spider.get_spider_legs=function() return {} end
spider.get_fuel_inventory=function() return {is_empty=function() return false end} end
local lookups=0
game.get_entity_by_unit_number=function(u) lookups=lookups+1; if u==7001 then return spider end end
local function team(r) return r.team and r.team.spidertron_retreated end

rawset(spider,'prototype',{guns={{attack_parameters={range=36}}}})
spider.get_inventory=function() return {get_item_count=function() return 100 end,get_contents=function() return {{name='rocket',count=100}} end,is_empty=function() return false end} end
force.get_friend=function() return false end; force.get_cease_fire=function() return false end

local function last_of(who) return who('status',{}).last end
local function active_of(who) local a=who('status',{}).active; return a and a.kind or nil end
local function reset() spider_route={}; spider.position={x=4,y=4}; spider.health=3000; advance(120) end
local last
local function active_of(who) local a=who('status',{}).active; return a and a.kind or nil end
local function go(who,dest,ticks) return who('vehicle',{position={x=spider.position.x,y=spider.position.y},go_to=dest,wait=true,ticks=ticks or 18000}) end

-- water from x 40 to 60 (its legs step 14 tiles: a path is asked across it); path request ids count up
local wet_tile={valid=true,name='deepwater',collides_with=function(l) return l=='player' or l=='doodad' or l=='water_tile' end,prototype={collision_mask={layers={player=true,water_tile=true}}}}
local dry_tile={valid=true,name='grass-1',collides_with=function() return false end,prototype={collision_mask={layers={}}}}
surface.get_tile=function(x,y) if x>=40 and x<61 and y>-30 and y<30 then return wet_tile end return dry_tile end
local path_ids,asked=0,{}
surface.request_path=function(r) path_ids=path_ids+1; asked[path_ids]=r; return path_ids end
local function path_done(id,pts)
  local path={}
  for i,q in ipairs(pts) do path[i]={position={x=q[1],y=q[2]}} end
  runtime.on_event{name=defines.events.on_script_path_request_finished,id=id,path=path,tick=game.tick}
end
local function kite(dest) return astra('spider_kite',{vehicle=7001,position=dest,ticks=36000}) end
local function on() spider.vehicle_automatic_targeting_parameters={auto_target_with_gunner=false,auto_target_without_gunner=false} end

-- 1. sol clears astra's kite's route: the kite yields (route_changed naming sol, clear); the route stays empty
reset(); on()
kite({x=30,y=4}); advance(30)
eq(spider_route[1] and spider_route[1].x,30,'the kite walks back to its position')
sol('vehicle',{position={x=4,y=4},clear=true}); advance(30)
eq(active_of(astra),nil,'the kite ended'); last=last_of(astra)
eq(last.outcome,'route_changed'); assert(last.why:find('sol set its route (clear) after this spider_kite began: it yields',1,true),last.why)
eq(#spider_route,0,'its route never written back (on main the kite wrote (30,4) again)')
assert(last.targeting:find('switches left as they stand (another call took the spidertron over)',1,true),last.targeting)
eq(spider.vehicle_automatic_targeting_parameters.auto_target_with_gunner,true,'targeting as it stands')

-- 2. sol's go_to to the same target: the kite yields; sol's route stays
reset(); on()
kite({x=30,y=4}); advance(30)
sol('vehicle',{position={x=4,y=4},go_to={x=30,y=4}}); advance(30)
last=last_of(astra); eq(last.outcome,'route_changed'); assert(last.why:find('(go_to)',1,true),last.why)
eq(#spider_route,1); eq(spider_route[1].x,30)

-- 3. sol appends: the kite yields; the route stays as sol left it
reset(); on()
kite({x=30,y=4}); advance(30)
sol('vehicle',{position={x=4,y=4},go_to={x=-50,y=4},mode='append'}); advance(30)
last=last_of(astra); eq(last.outcome,'route_changed'); assert(last.why:find('(go_to append)',1,true),last.why)
eq(#spider_route,2); eq(spider_route[2].x,-50)

-- 4. a player empties it short of the kite's position: not arrival; the kite yields and writes nothing
reset(); on()
kite({x=30,y=4}); advance(30)
spider_route={}; advance(30)
last=last_of(astra); eq(last.outcome,'route_changed'); assert(last.why:find('emptied by another call or a player 26 tiles short of (30,4)',1,true),last.why)
eq(#spider_route,0)

-- 5. a delayed path: the kite's path round the water is asked; sol replaces the route (the same target) before it comes;
-- the path that comes after is not written, and sol's route stays
reset(); on()
kite({x=100,y=4}); advance(30)
local kid=path_ids
assert(asked[kid] and asked[kid].goal.x>60,'a path round the water asked for the kite')
sol('vehicle',{position={x=4,y=4},go_to={x=100,y=4},reuse=false})
local sol_route={} for i,q in ipairs(spider_route) do sol_route[i]=q end
path_done(kid,{{4,4},{4,40},{100,40},{100,4}})
eq(#spider_route,#sol_route,'the kite\'s late path not written over sol\'s route')
for i,q in ipairs(sol_route) do eq(spider_route[i].x,q.x); eq(spider_route[i].y,q.y) end
advance(30)
eq(last_of(astra).outcome,'route_changed')

-- 6. a go_to's own path asked, then another caller's clear and go_to to the same target with the store off before it
-- comes: the old result is not written; said to its asker
reset()
astra('vehicle',{position={x=4,y=4},go_to={x=100,y=4},reuse=false})
local aid=path_ids
sol('vehicle',{position={x=4,y=4},clear=true})
spider_route={{x=100,y=4}}  -- a player's click back to the same target, as sol's own route
runtime.spiderroute.claim(spider,'sol','go_to')
path_done(aid,{{4,4},{4,40},{100,40},{100,4}})
eq(#spider_route,1,'the old path not written'); eq(spider_route[1].x,100)
local ev=storage.agent_harness.spiderroute.events
assert(ev[#ev].text:find('the path round the water asked for astra came after sol set its route (go_to): not used; its route stays 1 target: (100,4)',1,true),ev[#ev].text)
eq(ev[#ev].to,'astra')

-- 7. the new controller's own retreat still fires: sol's go_to with its retreat after astra's kite yields
reset(); on()
kite({x=30,y=4}); advance(30)
sol('vehicle',{position={x=4,y=4},go_to={x=200,y=4},retreat={to={x=-20,y=0},health_below=0.5}}); advance(30)
eq(last_of(astra).outcome,'route_changed')
spider.health=1000; advance(60)
eq(spider_route[1].x,-20,'sol\'s retreat, armed with its go_to, fired')
sol('retreat_guard',{clear=true})
print('d28_batch310b ok')
