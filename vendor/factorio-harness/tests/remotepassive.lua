-- Run from repository root: lua tests/remotepassive.lua
-- Calls that act on another surface or by remote view leave the character's action, its queue and a running standing
-- order alone (platform configure, remote-view configure, a refused platform call, planners); its own work in
-- reach still takes over. Fake engine as tests/orders.lua.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
local function has(s,text) assert(type(s)=='string' and s:find(text,1,true),'missing "'..text..'" in: '..tostring(s)) end
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
  local c={valid=true,name='character',type='character',force=force,surface=surface,position=pos,unit_number=500+units,health=250,max_health=250,
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
  get_player=function(i) assert(type(i)=='string' or i<=65536,'Given player value is too big'); if type(i)=='string' then for _,p in ipairs(players) do if p.name==i then return p end end return nil end return players[i] end,
  get_surface=function() return surface end,print=function() end,connected_players=players,
  get_pollution_statistics=function() return {input_counts={},output_counts={},get_flow_count=function() return 0 end} end}
local runtime=dofile('mod/agent-harness_0.1.0/runtime.lua')
local function advance(n) for _=1,n do tick=tick+1; game.tick=tick; runtime.tick{tick=tick} end end
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
local astra=as('astra')
local function op(action,args) return request{action=action,args=args or {},operator=true} end
runtime.operator.bot_create('astra')
local body=runtime.bots.lookup(runtime.bots.index_of('astra')).character
-- The character reaches 10 tiles, on its own surface.
body.can_reach_entity=function(e) return e.surface==body.surface and math.abs(e.position.x-body.position.x)<=10 and math.abs(e.position.y-body.position.y)<=10 end
local wait=function(ticks) return {action='wait_ticks',args={ticks=ticks}} end

-- Inserters with filter slots (configure filters): one in reach, one 25 tiles off in a visible chunk, one on a platform.
prototypes=prototypes or {}; prototypes.item=prototypes.item or {}; prototypes.item['iron-plate']={name='iron-plate'}
local psurf={name='platform-1',index=2,valid=true}
local world,on_platform={},{}
local function inserter(x,y,surf)
  local f={}
  local e={valid=true,name='fast-inserter',type='inserter',position={x=x,y=y},force=force,surface=surf or surface,filter_slot_count=5,
    inserter_filter_mode='whitelist',use_filters=false}
  e.set_filter=function(i,v) f[i]=v end
  e.get_filter=function(i) return f[i] and {name=f[i]} or nil end
  e.filters=f
  local list=surf==psurf and on_platform or world
  list[#list+1]=e
  return e
end
local function finder(list)
  return function(fl)
    local out={}
    if fl.position then for _,e in ipairs(list) do if e.valid and (not fl.name or e.name==fl.name) and math.abs(e.position.x-fl.position.x)<0.3 and math.abs(e.position.y-fl.position.y)<0.3 then out[#out+1]=e end end end
    return out
  end
end
surface.find_entities_filtered=finder(world); psurf.find_entities_filtered=finder(on_platform)
local sunward={valid=true,name='Sunward',index=1,force=force,surface=psurf}
psurf.platform=sunward; force.platforms={sunward}
local here_bot=body.position
local near=inserter(here_bot.x+2.5,here_bot.y+0.5)
local far=inserter(here_bot.x+25.5,here_bot.y+0.5)
local aboard=inserter(-2.5,-4.5,psurf)

local function queue() return astra('queue_status') end
-- A plan of long waits runs in the agent's own queue.
astra('queue_submit',{steps={wait(6000),wait(6000)}})
advance(2)
local q=queue(); eq(q.paused,false); assert(q.active,'the plan runs')
local step=q.active
-- configure on a platform (remote view): the plan keeps running, the filter is set.
local r=astra('configure',{platform='Sunward',position={x=-2.5,y=-4.5},filters={'iron-plate'}})
eq(r.filters[1],'iron-plate'); eq(aboard.filters[1],'iron-plate')
q=queue(); eq(q.paused,false); eq(q.active.id,step.id,'the same step goes on'); eq(q.active.started_tick,step.started_tick)
-- configure out of reach by remote view on the planet: the same.
astra('configure',{position=far.position,filters={'iron-plate'}})
eq(far.filters[1],'iron-plate'); eq(queue().paused,false)
-- A refused call on a platform (repair cannot reach one) stops nothing either.
fails(function() astra('repair',{platform='Sunward',position={x=-2.5,y=-4.5}}) end,'repair cannot reach a space platform')
eq(queue().paused,false)
-- configure in reach is the character's own work: it takes over, as before.
astra('configure',{position=near.position,filters={'iron-plate'}})
eq(near.filters[1],'iron-plate'); eq(queue().paused,true)
astra('queue_resume',{}); advance(1); eq(queue().paused,false)
-- Character work (a walk) takes over too.
astra('walk',{direction='north',ticks=10}); eq(queue().paused,true)
astra('queue_cancel',{}); advance(20)

-- A standing order runs; remote edits leave it running, character work holds it.
astra('order_set',{name='courier',steps={wait(6000)},interval_ticks=36000})
local function running() local s=astra('queue_status'); return s.order and s.order.name end
for _=1,2000 do if running()=='courier' then break end; advance(1) end
eq(running(),'courier')
astra('configure',{platform='Sunward',position={x=-2.5,y=-4.5},filters={}})
eq(running(),'courier'); eq(aboard.filters[1],nil)
astra('configure',{position=far.position,filters={}})
eq(running(),'courier')
astra('configure',{position=near.position,filters={}})
eq(running(),nil)
has(astra('status').orders,'courier resumes in 20 s (after your last action)')

-- Which calls stay out of the way: planners always; others when they name a platform or another surface,
-- or (configure) when the target is out of reach.
for _,name in ipairs({'paste','blueprint_place','blueprint_capture','copy','cut','belt_route','pipe_route','pole_route',
  'rail_route','train_stop','train',
  'place_ghosts','deconstruct','cancel_deconstruction','circuit_set','wire','requests','platform_schedule','flush'}) do
  eq(runtime.keeps(name),true,name)
end
for _,name in ipairs({'configure','build','transfer','move_to','mine','rotate','construct','feed'}) do eq(runtime.keeps(name),false,name) end
eq(runtime.keeps('configure',{platform='Sunward'}),true)
local me=runtime.lookup(runtime.bots.index_of('astra'))
eq(runtime.remote(me,'configure',{surface='vulcanus'}),true); eq(runtime.remote(me,'configure',{surface='nauvis'}),false)
eq(runtime.remote(me,'configure',{position=near.position}),false); eq(runtime.remote(me,'configure',{position=far.position}),true)
eq(runtime.remote(me,'transfer',{position=far.position}),false)
-- trace is a read, on a platform too (trace.lua through the platform= wrapper).
eq(runtime.keeps('trace'),true)
local paused=queue().paused
r=astra('trace',{platform='Sunward',position={x=-2.5,y=-4.5},forward=true})
eq(r.entity,'fast-inserter'); eq(r.note,'no inserter takes from it'); eq(queue().paused,paused)
print('remotepassive: ok')
