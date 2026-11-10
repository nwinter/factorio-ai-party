-- Strict 2.1 recipe objects reject both removed category fields.
script={active_mods={base='2.1.24'}}
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

local function recipe(name,categories)
 return setmetatable({name=name,enabled=true,categories=categories,products={},ingredients={}}, {__index=function(_,k)
  assert(k~='category' and k~='additional_categories','removed category field '..k)
 end})
end
local r=recipe('multi',{'hand-crafting','crafting','electromagnetics'})
force.recipes={multi=r}
local proto={name='em-plant',type='assembling-machine',crafting_categories={electromagnetics=true}}
assert(runtime.recipe_for({force=force},proto,'multi')==r)
local P=dofile('mod/agent-harness_0.1.0/ports.lua'){}
assert(P.recipe(proto,r)==r)
proto.crafting_categories={chemistry=true}
local ok,err=pcall(runtime.recipe_for,{force=force},proto,'multi')
assert(not ok and tostring(err):find('hand-crafting, crafting, electromagnetics',1,true),tostring(err))
ok,err=pcall(P.recipe,proto,r)
assert(not ok and tostring(err):find('cannot make',1,true),tostring(err))
proto.crafting_categories={crafting=true}
ok=pcall(P.recipe,proto,recipe('none',{})); assert(not ok)
local old={name='old',enabled=true,category='chemistry',additional_categories={'crafting'}}
assert(P.recipe(proto,old)==old)
defines.wire_connector_id={circuit_red=1,circuit_green=2}
prototypes={quality={normal={level=0}}}
local e={name='em-plant',prototype=proto,force=force,get_circuit_network=function(w)
 if w==1 then return {signals={{signal={type='recipe',name='multi'},count=1}}} end
end}
local C=dofile('mod/agent-harness_0.1.0/circrecipe.lua'){}
assert(C.pick(e).recipe=='multi')
proto.crafting_categories={chemistry=true}; local pick=C.pick(e)
assert(pick.recipe==nil and pick.skipped[1].why=='not one em-plant makes')
print('port21 categories: runtime build/configure checks, ports and circuit selection; strict lists and 2.0 fallback passed')
-- Configure a solid-only 2.1 machine without reading the removed fluidbox field.
proto.crafting_categories={crafting=true}
local current
local machine=setmetatable({valid=true,name='em-plant',type='assembling-machine',force=force,surface=surface,position={x=5,y=5},
 prototype=proto,fluids_count=0,get_recipe=function() return current,{name='normal'} end,
 set_recipe=function(name) current=force.recipes[name];return {} end,get_control_behavior=function() return nil end,
 get_inventory=function() return nil end}, {__index=function(_,k) assert(k~='fluidbox','removed fluidbox') end})
surface.find_entities_filtered=function() return {machine} end
nick.can_reach_entity=function() return true end
nick.physical_surface=surface; nick.physical_position=nick.position
nick.get_main_inventory=nick.character.get_main_inventory
prototypes.item={};prototypes.recipe={multi=r};prototypes.entity={['em-plant']=proto}
local out=runtime.dispatch{player=1,action='configure',args={position={x=5,y=5},recipe='multi'}}
assert(out.recipe=='multi' and current==r)
-- Fast replacement checks both underground ends through the native 2.1 field.
local paired={valid=true,name='underground-belt',type='underground-belt',force=force,
  prototype={fast_replaceable_group='belt'},position={x=8.5,y=5.5}}
local entry=setmetatable({valid=true,name='underground-belt',type='underground-belt',force=force,
  prototype={fast_replaceable_group='belt'},underground_belt_neighbour=paired},
  {__index=function(_,k) assert(k~='neighbours','removed neighbours') end})
surface.find_entities_filtered=function() return {entry} end
local old,other=runtime.underground_pair_ends(surface,force,{name='fast-underground-belt',fast_replaceable_group='belt'},{x=5.5,y=5.5})
assert(old==entry and other==paired)
entry.underground_belt_neighbour=nil
assert(runtime.underground_pair_ends(surface,force,{name='fast-underground-belt',fast_replaceable_group='belt'},{x=5.5,y=5.5})==nil)

-- Native fluid configure refuses before mutation and explicitly drains only its own private store.
surface.find_entities_filtered=function() return {machine} end
local water=200;local cleared=0;local neighbor=50
machine.object_name='LuaEntity';machine.fluids_count=1
machine.get_fluid=function(i) assert(i==1);return water>0 and {name='water',amount=water} or nil end
machine.has_fluid_segment=function() return false end
machine.clear_fluid=function() cleared=cleared+1;local old=water;water=0;return {name='water',amount=old} end
machine.set_recipe=function(name) current=force.recipes[name];water=0;return {} end
local dry=recipe('dry',{'crafting'});force.recipes.dry=dry;prototypes.recipe.dry=dry
local ok,err=pcall(runtime.dispatch,{player=1,action='configure',args={position={x=5,y=5},recipe='dry'}})
assert(not ok and tostring(err):find('nothing changed',1,true));assert(water==200 and current==r and cleared==0)
out=runtime.dispatch{player=1,action='configure',args={position={x=5,y=5},recipe='dry',fluid='drain'}}
assert(out.recipe=='dry' and out.fluid_flushed.water==200 and cleared==1 and water==0 and neighbor==50)
print('port21 configure: native private-store refusal and drain passed')

-- A zero-slot weight-limited target inserts the actual stack (metadata retained), with a bounded partial move.
defines.inventory.rocket_silo_rocket=21
local source_stack={valid_for_read=true,name='tagged',quality={name='rare'},count=10,
 spoil_tick=9999,spoil_percent=.25,tags={label='same metadata'},health=.7}
local received
local target={index=21,insert=function(st) assert(st==source_stack);received={count=st.count,quality=st.quality,tags=st.tags,spoil_tick=st.spoil_tick};return 3 end}
local n=runtime.move_stacks({source_stack},target,function() return true end,4)
assert(n==3 and source_stack.count==7 and received.count==4 and received.quality.name=='rare' and received.tags.label=='same metadata' and received.spoil_tick==9999)
target.insert=function() error('insert refused') end
local ok=pcall(runtime.move_stacks,{source_stack},target,function() return true end,4)
assert(not ok and source_stack.count==7)
print('port21 cargo transfer: metadata, partial insertion, and failure conservation passed')
