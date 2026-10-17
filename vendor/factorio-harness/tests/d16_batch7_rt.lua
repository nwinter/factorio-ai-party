-- Run from the harness root: lua tests/d16_batch7_rt.lua
-- d16 batch7 through the runtime against a fake engine (as tests/d15_batch5_g3.lua): stock over a whole surface (A1),
-- transfer from a belt (A2), the reply of a call that replaced a running action (A5), collect min_fresh (A7).
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

prototypes={item={['iron-plate']={name='iron-plate',type='item',get_spoil_ticks=function() return 0 end},
  ['pentapod-egg']={name='pentapod-egg',type='item',get_spoil_ticks=function() return 3600 end},
  nutrients={name='nutrients',type='item',get_spoil_ticks=function() return 3600 end}},entity={},recipe={},tile={}}

-- A1 (Sonnet 12:20: stock said 0 packs within 128 tiles while 2,500 sat in a requester elsewhere; Muse 14:08: told a
-- teammate 0 foundation while 209 sat elsewhere): with an item and no radius, total is the whole surface's (kept 10 s,
-- as_of says live or its age); the places listed stay within 128 tiles; covered says what was read.
do
  local kept=runtime.packaudit.planet_row
  local calls=0
  runtime.packaudit.planet_row=function(f,s,item) calls=calls+1; return {total=2500,networks=2500,pads=0,chests=0,silos=0,labs=0,line=item..' on '..s.name..': logistic networks 2500'} end
  local r=astra('stock',{item='iron-plate'})
  eq(r.total,2500); eq(r.within_radius.total,0); eq(r.within_radius.radius,128)
  assert(r.as_of:find('^live %(tick %d+%)'),r.as_of)
  assert(r.covered:find('total: the whole of nauvis',1,true),r.covered)
  assert(r.covered:find('places: our machine outputs and chests within 128 tiles of',1,true),r.covered)
  assert(r.summary:find('^2500 iron%-plate on nauvis as a whole'),r.summary)
  -- the same read within 10 s is reused, and says how old it is
  jump(120)
  r=astra('stock',{item='iron-plate'})
  eq(calls,1); eq(r.as_of,'2s ago (the same read within 10 s is reused)')
  -- with a radius: that circle only, no whole-surface read
  r=astra('stock',{item='iron-plate',radius=64})
  eq(calls,1); eq(r.total,0); eq(r.within_radius,nil); assert(r.covered:find('within 64 tiles',1,true),r.covered)
  runtime.packaudit.planet_row=kept
end
print('d16_batch7_rt A1 stock covers the whole surface: ok')

-- A2 (Grok 12:21: transfer from the egg belt said it held none while inspect showed eggs on it): refused, naming what
-- its lanes carry and pickup.
do
  local lanes={{{name='pentapod-egg',count=3,quality='normal'}},{{name='pentapod-egg',count=2,quality='normal'}}}
  local belt={valid=true,name='transport-belt',type='transport-belt',force=force,surface=surface,position={x=7.5,y=7.5},unit_number=4001,
    bounding_box={left_top={x=7,y=7},right_bottom={x=8,y=8}},prototype={},
    get_max_transport_line_index=function() return 2 end,get_transport_line=function(i) return {get_contents=function() return lanes[i] end} end,
    get_inventory=function() return nil end,get_output_inventory=function() return nil end}
  local find=surface.find_entities_filtered
  surface.find_entities_filtered=function(f)
    if f.position and math.abs(f.position.x-7.5)<0.6 and math.abs(f.position.y-7.5)<0.6 and not f.type then return {belt} end
    return find(f)
  end
  fails(function() astra('transfer',{position={x=7.5,y=7.5},item='pentapod-egg',direction='to_player',count=3}) end,
    'transport-belt at (7.5,7.5) is a belt: transfer takes from inventories, and a belt\'s items are on its lanes (it carries pentapod-egg 5 now); pickup {belt: true, position: {x: 7.5, y: 7.5}, radius: 1, items: ["pentapod-egg"]} takes them off')
  surface.find_entities_filtered=find
end
print('d16_batch7_rt A2 transfer from a belt names pickup: ok')

-- A5 (Haiku 13:50, Muse 14:08: a walk cut off by the next call read moved 0 with no sign it stopped): the call that
-- ends a running action says which and what it had done.
do
  astra('move_to',{position={x=200,y=5},pathfind=false})
  advance(2)
  local r=astra('move_to',{position={x=-50,y=5},pathfind=false})
  assert(r.replaced and r.replaced:find('^this call ended your running move_to; the walk to %(200,5%) stopped at'),tostring(r.replaced))
  -- said once: the next reply has none
  r=astra('status',{})
  eq(r.replaced,nil)
  astra('stop',{})
end
print('d16_batch7_rt A5 the replacing call says what it ended: ok')

-- B1 (Muse 12:20: empty ground read the same whether never charted or charted and empty now; Gemini 14:49: area boxes
-- went wrong): an inspect of empty ground says what the map says of its chunk; inspect {position, radius} reads the
-- square round it as area does.
do
  fails(function() astra('inspect',{position={x=6.5,y=6.5}}) end,'(chunk (0,0) is in sight now (tick ')
  -- nothing of ours there: area's refusal names the square read
  fails(function() astra('inspect',{position={x=6.5,y=6.5},radius=4}) end,'no entity of ours with its centre in (2.5,2.5)-(10.5,10.5)')
  fails(function() astra('inspect',{radius=4}) end,'radius goes with position')
end
print('d16_batch7_rt B1 empty ground and inspect radius: ok')

-- C4 (Sonnet 13:51): the same load_silo for N rockets in one call, as N queue steps.
do
  astra('queue_cancel',{})
  local r=astra('load_silo',{position={x=40.5,y=4.5},items={['iron-plate']=100},launch=true,platform='Swift',rockets=3})
  eq(r.rockets,3); assert(r.note:find('3 load_silo steps appended to your queue',1,true),r.note)
  local q=astra('queue_status',{args=true,pending=8})
  eq(q.pending_count,3); eq(q.pending[1].action,'load_silo'); eq(q.pending[3].label,'rocket 3 of 3'); eq(q.pending[2].args.rockets,nil)
  fails(function() astra('load_silo',{position={x=40.5,y=4.5},items={['iron-plate']=100},rockets=2}) end,'rockets goes with launch: true')
  astra('queue_cancel',{})
end
print('d16_batch7_rt C4 load_silo for N rockets: ok')
