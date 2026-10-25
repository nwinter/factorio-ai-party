-- Run from repository root: lua tests/d24_batch189.lua
-- d24 batch189 QAE1 (viewer Aurora site:4814): retreat_guard for a spidertron sent by vehicle go_to or ridden. The
-- fake engine is tests/vehicles.lua's.
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

-- No guard: a spidertron with a route is never read for one (the 30-tick pass looks only at those with a guard).
local r=astra('vehicle',{position={x=4,y=4},go_to={x=200,y=4}})
eq(r.retreat,nil,'no guard, no retreat line')
advance(30); lookups=0; runtime.spiderroute.guard_tick(); eq(lookups,0,'no guard: no lookup')

-- The standing retreat_guard watches it: health under 50% and lower than when sent replaces its route by one to `to`.
astra('retreat_guard',{to={x=-20,y=0},health_below=0.5})
r=astra('vehicle',{position={x=4,y=4},go_to={{x=200,y=4},{x=300,y=4}}})
has(r.retreat,'to (-20,0) at health under 50% (standing retreat_guard), read every 30 ticks')
advance(30); eq(spider_route[1].x,200,'full health: the route kept')
spider.health=1400; spider.position={x=20,y=4}
advance(30)
eq(#spider_route,1); eq(spider_route[1].x,-20); eq(spider_route[1].y,0)
local rec=team(astra('status',{}))
assert(rec and rec[1],'said in the next reply')
rec=rec[1]
eq(rec.unit_number,7001); eq(rec.why,'spidertron health 46% (1400/3000) under 50%'); eq(rec.from.x,20); eq(rec.health,'1400/3000')
eq(rec.shield,'100/100'); eq(rec.to.x,-20); eq(rec.replaced[1],'(200,4)'); eq(rec.replaced[2],'(300,4)'); eq(rec.route_line,'1 target: (-20,0)')
eq(rec.guard,'standing retreat_guard')
eq(team(astra('status',{})),nil,'said once')
local st=astra('status',{})
has(st.spidertrons[1],'spidertron #7001 at (20,4): 1 target: (-20,0); retreated 0s ago (standing retreat_guard: spidertron health 46% (1400/3000) under 50%) from (20,4), health 1400/3000, shield 100/100; its route became 1 target: (-20,0)')
-- once: hit again on the way back, the route stays
spider.health=900; advance(60); eq(#spider_route,1); eq(team(astra('status',{})),nil)
eq(astra('vehicle',{position={x=20,y=4}}).retreated.why,'spidertron health 46% (1400/3000) under 50%')

-- Sent again it is armed again, from its health then (30%): only a further fall triggers.
spider.health=900
r=astra('vehicle',{position={x=20,y=4},go_to={x=200,y=4}})
advance(60); eq(spider_route[1].x,200,'no fall since sent')
spider.health=800; advance(30); eq(spider_route[1].x,-20)
has(team(astra('status',{}))[1].why,'health 26% (800/3000)')

-- A go_to's own retreat wins (the grid's shield here); its line says so.
spider.health=3000
r=astra('vehicle',{position={x=20,y=4},go_to={x=200,y=4},retreat={to={x=-30,y=4},shield_below=0.3}})
has(r.retreat,'to (-30,4) at shield under 30%, read every 30 ticks')
spider.health=1000; advance(30); eq(spider_route[1].x,200,'its own retreat looks at the shield only')
spider.grid.shield=20; advance(30); eq(spider_route[1].x,-30)
rec=team(astra('status',{}))[1]
eq(rec.guard,'the go_to\'s retreat'); eq(rec.why,'spidertron shield 20% (20/100) under 30%'); eq(rec.shield,'20/100')
spider.grid.shield=100; spider.health=3000

-- retreat: false: nothing watches it.
r=astra('vehicle',{position={x=20,y=4},go_to={x=200,y=4},retreat=false})
eq(r.retreat,nil); spider.health=100; advance(60); eq(spider_route[1].x,200)
spider.health=3000

-- clear: the standing guard and the go_to retreats of the spidertrons this agent sent.
r=astra('vehicle',{position={x=20,y=4},go_to={x=200,y=4},retreat={to={x=-30,y=4},health_below=0.5}})
r=astra('retreat_guard',{clear=true})
eq(r.retreat_guard,false); eq(r.spidertrons,'1 spidertron go_to retreat cleared')
spider.health=100; advance(60); eq(spider_route[1].x,200,'cleared: nothing watches it')
r=astra('vehicle',{position={x=20,y=4},go_to={x=210,y=4}}); eq(r.retreat,nil)
advance(60); lookups=0; runtime.spiderroute.guard_tick(); eq(lookups,0,'no guard left: no lookup')
spider.health=3000

-- Ridden: the rider's standing guard watches it when its sender has none; both hear it.
s_body.position={x=18,y=4}
sol('vehicle',{position={x=20,y=4},enter=true})
sol('retreat_guard',{to={x=-40,y=0},health_below=0.6})
r=astra('vehicle',{position={x=20,y=4},go_to={x=220,y=4}})
has(r.retreat,'to (-40,0) at health under 60% (standing retreat_guard) (sol rides it)')
spider.health=1500; advance(30); eq(spider_route[1].x,-40)
rec=team(sol('status',{}))[1]; eq(rec.guard,'sol\'s standing retreat_guard (riding it)')
eq(team(astra('status',{}))[1].guard,'sol\'s standing retreat_guard (riding it)')
-- the route over: the entry goes; status still says the retreat for 10 minutes
spider_route={}; advance(60)
has(astra('status',{}).spidertrons[1],'spidertron #7001 at (20,4): no target: it stands; retreated')
jump(36000); advance(1); eq(astra('status',{}).spidertrons,nil)
print('d24_batch189 ok')
