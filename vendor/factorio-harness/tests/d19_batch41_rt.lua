-- Run from the harness root: lua tests/d19_batch41_rt.lua
-- d19 batch41 through the runtime against a fake engine (the scaffold of tests/d17_batch18_rt.lua).
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

-- A1 (Sonnet, shift40 07:51: ingredient_gap {all, area} on Nauvis failed "attempt to index local 'e' (a nil value)"): a
-- short ingredient's donors from stock.scan hold ground stacks (no entity) and may hold a chest gone invalid. The ground
-- stack spares what it holds under its own name; the invalid chest is passed over; a requester spares only over its
-- request.
do
  local gone={valid=false}
  setmetatable(gone,{__index=function(_,k) if k~='valid' then error('LuaEntity was invalid',0) end end})
  local req={valid=true,name='requester-chest',type='logistic-container',position={x=14.5,y=4.5},prototype={logistic_mode='requester'},
    get_logistic_point=function() return {targeted_items_pickup={},filters={{name='iron-plate',count=30}}} end}
  defines.logistic_member_index={logistic_container=0}
  local scan={places={
    {name='2 stacks on the ground',position={x=3,y=4},count=40,distance=2,ground=true},
    {entity=gone,name='iron-chest',position={x=6.5,y=4.5},count=100,distance=4},
    {entity=req,name='requester-chest',position={x=14.5,y=4.5},count=50,distance=9}}}
  local line=runtime.where_kept(nick,'iron-plate',30,scan)
  eq(line,'enough at 2 stacks on the ground (3,4) 2 tiles, 40 free')
  line=runtime.where_kept(nick,'iron-plate',60,scan)
  eq(line,'some at 2 stacks on the ground (3,4) 2 tiles, 40 free; requester-chest (14.5,4.5) 9 tiles, 20 free over its request')
  -- through ingredient_gap: a machine whose donor search errors keeps its row, the others read
  local G=runtime.gap
  defines.inventory.assembling_machine_input=2
  prototypes={recipe={gear={ingredients={{type='item',name='iron-plate',amount=2}}}},item={}}
  local function asm(x,held) return {valid=true,name='assembling-machine-2',type='assembling-machine',position={x=x,y=0.5},force=force,surface=surface,
    get_recipe=function() return {name='gear'} end,get_inventory=function() return {get_item_count=function() return held end} end,fluidbox={},status=1} end
  local a1,a2=asm(0.5,0),asm(4.5,0)
  force.logistic_networks={}
  local calls=0
  surface.find_entities_filtered=function(f)
    if f.area then return {a1,a2} end
    calls=calls+1
    if calls==1 then error("attempt to index local 'e' (a nil value)",0) end
    return {}
  end
  local r=G.read(nick,{all=true,area={left_top={x=-10,y=-10},right_bottom={x=10,y=10}}})
  eq(r.read,2); eq(r.short,2)
  assert(r.machines[1].ingredients[1].donors:find('donors not read',1,true),r.machines[1].ingredients[1].donors)
  eq(r.machines[2].ingredients[1].donors,'none of ours to spare within 128 tiles or in a logistic network on nauvis')
  surface.find_entities_filtered=function() return {} end
end
print('d19_batch41_rt A1 donors: ground stacks, invalid holders, a failed search: ok')
