-- Run from repository root: lua tests/d15_batch5_g3.lua
-- d15 batch5 G3 through the runtime against a fake engine (as tests/cliffs.lua): stock {network}, stock {item,
-- surface}, rates {recipe | item} across a surface, nearest_water.
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

-- stock {network} (Gemini 02:36): what one logistic network holds, by its number, largest first, with its robots.
do
  local contents={{name='iron-plate',quality='normal',count=400},{name='copper-plate',quality='normal',count=1200},{name='gear',quality='rare',count=5}}
  force.logistic_networks={nauvis={{network_id=96,get_contents=function() return contents end,all_logistic_robots=834,available_logistic_robots=710,all_construction_robots=50}}}
  local r=astra('stock',{network=96})
  eq(r.network,96); eq(r.items[1].name,'copper-plate'); eq(r.items[3].quality,'rare')
  eq(r.line,'logistic network #96 on nauvis holds copper-plate 1200, iron-plate 400, gear@rare 5')
  eq(r.robots,'834 logistic robots (710 idle), 50 construction robots')
  r=astra('stock',{network=96,limit=1}); eq(#r.items,1); eq(r.more,2); eq(r.line,'logistic network #96 on nauvis holds copper-plate 1200 (+2 more items)')
  eq(astra('stock',{network=96,item='iron-plate'}).line,'logistic network #96 on nauvis holds iron-plate 400')
  fails(function() astra('stock',{network=7}) end,'no logistic network #7 of ours on nauvis')
  fails(function() astra('stock',{network='96'}) end,'network is a logistic network number')
end
print('d15_batch5_g3 stock network: ok')

-- nearest_water (Opus 04:11): the nearest tile an offshore pump takes in charted chunks, past placements' 24 tiles.
do
  prototypes={item={},entity={},recipe={},tile={}}
  prototypes.tile={water={name='water',fluid={name='water'}},['grass-1']={name='grass-1'}}
  local water={}
  for x=130,133 do for y=0,3 do water[#water+1]={name='water',position={x=x,y=y}} end end
  local function inside(t,f)
    if f.area then
      local a=f.area
      return t.position.x>=a.left_top.x and t.position.x<a.right_bottom.x and t.position.y>=a.left_top.y and t.position.y<a.right_bottom.y
    end
    return ((t.position.x+0.5-f.position.x)^2+(t.position.y+0.5-f.position.y)^2)^0.5<=f.radius
  end
  surface.find_tiles_filtered=function(f)
    local out={}
    for _,t in ipairs(water) do if inside(t,f) then out[#out+1]=t end end
    return out
  end
  surface.count_tiles_filtered=function(f) return #surface.find_tiles_filtered(f) end
  local r=astra('nearest_water',{position={x=5,y=5}})
  eq(r.found,true); eq(r.tile,'water'); eq(r.fluid,'water'); eq(r.position.x,130.5); eq(r.position.y,3.5)
  eq(r.distance,125.5)
  assert(r.line:find('nearest water (water) at (130.5,3.5), 125.5 tiles from (5,5)',1,true),r.line)
  -- Out of the radius, or in a chunk not charted: not found.
  r=astra('nearest_water',{position={x=5,y=5},radius=100}); eq(r.found,false)
  assert(r.line:find('no tile an offshore pump takes within 100 tiles of (5,5)',1,true),r.line)
  local charted=force.is_chunk_charted
  force.is_chunk_charted=function(_,c) return c.x<4 end
  r=astra('nearest_water',{position={x=5,y=5}}); eq(r.found,false); assert(r.uncharted_chunks>0)
  force.is_chunk_charted=charted
  fails(function() astra('nearest_water',{radius=300}) end,'radius')
end
print('d15_batch5_g3 nearest_water: ok')

-- rates {recipe | item} with no area (Gemini 02:36): every crafter of ours on the surface set to that recipe, or to one
-- making the item, at most RATES_SURFACE; with item, the surface's statistics beside it.
do
  local function recipe(name,product,amount,ingredient)
    return {name=name,energy=0.5,productivity_bonus=0,prototype={maximum_productivity=3},ingredients={{type='item',name=ingredient,amount=1}},
      products={{type='item',name=product,amount=amount}}}
  end
  prototypes.recipe={['iron-gear-wheel']=recipe('iron-gear-wheel','iron-gear-wheel',1,'iron-plate'),['copper-cable']=recipe('copper-cable','copper-cable',2,'copper-plate')}
  prototypes.item={['iron-gear-wheel']={name='iron-gear-wheel'},['copper-cable']={name='copper-cable'}}
  defines.flow_precision_index.ten_minutes=2
  local function crafter(x,name)
    return {valid=true,name='assembling-machine-2',type='assembling-machine',force=force,surface=surface,position={x=x,y=0},unit_number=900+x,
      prototype={},crafting_speed=1,productivity_bonus=0,get_recipe=function() return prototypes.recipe[name] end}
  end
  local list={crafter(1,'iron-gear-wheel'),crafter(4,'iron-gear-wheel'),crafter(7,'copper-cable')}
  local kept=surface.find_entities_filtered
  local asked
  surface.find_entities_filtered=function(f) asked=f; return list end
  force.get_item_production_statistics=function() return {get_flow_count=function(f) return f.category=='input' and 1200 or 300 end} end
  local r=astra('rates',{recipe='iron-gear-wheel'})
  eq(asked.force,force); eq(r.machines,2); eq(r.per,'minute'); eq(r.surface,'nauvis'); eq(r.scope,'2 crafters on nauvis set to iron-gear-wheel')
  r=astra('rates',{item='copper-cable'})
  eq(r.machines,1); eq(r.scope,'1 crafter on nauvis set to a recipe making copper-cable')
  eq(#r.rows,1,'the copper-plate row is left out'); eq(r.rows[1].item,'copper-cable'); eq(r.rows[1].produced,240); eq(r.rows_other,1)
  eq(r.statistics,'copper-cable on nauvis, the game\'s statistics over 10 min: made 120/min, used 30/min')
  runtime.RATES_SURFACE=1
  r=astra('rates',{recipe='iron-gear-wheel'})
  eq(r.machines,2); eq(r.machines_read,1); eq(r.scope,'2 crafters on nauvis set to iron-gear-wheel (the first 1 read)')
  runtime.RATES_SURFACE=512
  fails(function() astra('rates',{recipe='nope'}) end,'recipe must be a recipe name')
  surface.find_entities_filtered=kept
end
print('d15_batch5_g3 rates across a surface: ok')

-- stock {item, surface}: one planet's whole stock of an item as freight_audit counts it (packaudit.planet_row).
do
  local kept,kg=runtime.packaudit.planet_row,game.get_surface
  local platform={name='platform-3',platform={}}
  game.get_surface=function(n) return n=='nauvis' and surface or n=='platform-3' and platform or nil end
  runtime.packaudit.planet_row=function(f,s,item) return {total=840,networks=600,pads=40,chests=200,line=item..' on '..s.name..': 840'} end
  local r=astra('stock',{item='copper-cable',surface='nauvis'})
  eq(r.total,840); eq(r.surface,'nauvis'); eq(r.line,'copper-cable on nauvis: 840'); assert(r.note:find('supply {item, surface}',1,true))
  fails(function() astra('stock',{surface='nauvis'}) end,'stock {surface} takes item')
  -- A platform's surface is read whole (d16 batch7 A1).
  platform.find_entities_filtered=function(f) assert(f.position==nil and f.radius==nil,'a platform is read whole'); return {} end
  r=astra('stock',{item='copper-cable',surface='platform-3'})
  eq(r.total,0); eq(r.covered,'every machine output and chest of ours on platform-3')
  runtime.packaudit.planet_row,game.get_surface=kept,kg
end
print('d15_batch5_g3 stock on a surface: ok')
