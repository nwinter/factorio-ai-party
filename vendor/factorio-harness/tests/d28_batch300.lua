-- Run from repository root: lua tests/d28_batch300.lua
-- d28 batch300 SR (viewer Aurora site:5308: "Could the Spidertron tests clear a waited route from another engineer?
-- ... Please check it ends promptly with route_changed."). Two callers on one spidertron through the runtime's
-- dispatch: astra's waited go_to (vehicle {go_to, wait: true}) ends route_changed at the next read after sol's clear,
-- go_to, append or spider_kite (naming sol, how and when) and after a route set outside the harness; on main a clear
-- or a spider_kite left it waiting to its timeout, and a player's route ended it "arrived" at the player's target.
-- arrived, retreated, route_emptied and a route the harness rewrites round water stay as they were. The fake engine is
-- tests/d24_batch189.lua's.
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
local function go(who,dest,ticks) return who('vehicle',{position={x=spider.position.x,y=spider.position.y},go_to=dest,wait=true,ticks=ticks or 18000}) end
local function reset() spider_route={}; spider.position={x=4,y=4}; spider.health=3000; advance(120) end

-- 1. sol clears astra's waited route: route_changed at the next read (a second), naming sol, clear and when
reset()
local r=go(astra,{x=200,y=4})
eq(active_of(astra),'spider_go'); assert(r.waiting:find('its route is set again'),r.waiting)
advance(120)
local t_clear=game.tick
sol('vehicle',{position={x=4,y=4},clear=true})
advance(60)
eq(active_of(astra),nil,'ended within a second of the clear, not at its 300 s timeout')
local last=last_of(astra)
eq(last.outcome,'route_changed'); eq(last.changed_by,'sol'); eq(last.changed_how,'clear'); eq(last.changed_tick,t_clear)
eq(last.why,'its route was set again by sol (clear) 2s after this go_to: no target: it stands')

-- 2. sol's go_to replaces it, 3. sol appends to it
reset(); go(astra,{x=200,y=4}); advance(120)
sol('vehicle',{position={x=4,y=4},go_to={x=-50,y=4}}); advance(60)
last=last_of(astra); eq(last.outcome,'route_changed'); eq(last.changed_by,'sol'); eq(last.changed_how,'go_to')
assert(last.why:find('by sol %(go_to%) 2s after this go_to: 1 target: %(%-50,4%)'),last.why)
reset(); go(astra,{x=200,y=4}); advance(120)
sol('vehicle',{position={x=4,y=4},go_to={x=300,y=4},mode='append'}); advance(60)
last=last_of(astra); eq(last.outcome,'route_changed'); eq(last.changed_how,'go_to append')

-- 4. two waits: sol's waited go_to ends astra's; sol's own wait goes on to its arrival
reset(); go(astra,{x=200,y=4}); advance(120)
go(sol,{x=-60,y=4}); advance(60)
eq(last_of(astra).outcome,'route_changed'); eq(last_of(astra).changed_by,'sol')
eq(active_of(sol),'spider_go','the new owner\'s wait goes on')
spider.position={x=-60,y=4}; spider_route={}; advance(120)
eq(last_of(sol).outcome,'arrived'); eq(last_of(sol).changed_by,nil)

-- 5. a route set outside the harness (a player's remote): route_changed, not "arrived" at the player's target
reset(); go(astra,{x=200,y=4}); advance(120)
spider_route={{x=-80,y=4}}; advance(60)
last=last_of(astra)
eq(last.outcome,'route_changed'); eq(last.changed_by,nil)
assert(last.why:find('^its route was set outside the harness\'s calls %(a player in the game, or another script%), seen 2s after this go_to: 1 target: %(%-80,4%)'),last.why)

-- 6. unchanged: its route rewritten round water (the same last target) walks on and arrives; a player's clear is
-- route_emptied; the guard's retreat is retreated
reset(); go(astra,{x=200,y=4}); advance(120)
spider_route={{x=100,y=30},{x=150,y=30},{x=200,y=4}}; advance(180)
eq(active_of(astra),'spider_go','its own target last: still walking')
spider.position={x=200,y=4}; spider_route={}; advance(120)
last=last_of(astra); eq(last.outcome,'arrived'); eq(last.why,'arrived at (200,4) (its route ended at (200,4))')
reset(); go(astra,{x=200,y=4}); advance(120)
spider_route={}; advance(60)
eq(last_of(astra).outcome,'route_emptied')
reset()
astra('vehicle',{position={x=4,y=4},go_to={x=200,y=4},wait=true,retreat={to={x=-20,y=0},health_below=0.5}}); advance(60)
spider.health=1000; advance(60)
eq(last_of(astra).outcome,'retreated'); eq(spider_route[1].x,-20)
astra('retreat_guard',{clear=true})

-- 7. sol's spider_kite takes the spidertron over: route_changed naming it (on main: waited to the timeout)
reset(); go(astra,{x=200,y=4},3600); advance(120)
sol('spider_kite',{vehicle=7001}); advance(60)
eq(active_of(astra),nil); last=last_of(astra)
eq(last.outcome,'route_changed'); eq(last.changed_by,'sol'); eq(last.changed_how,'spider_kite')
print('d28_batch300 ok')
