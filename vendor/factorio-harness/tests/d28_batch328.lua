-- d28 batch328 SC (Astra, board #2725, d28 21:00: "R12 iron-chest dryrun passed but actualplace79326730/79327131 failed
-- vague placement blocked after oldfeedremoved; chest forbidden space." Proposal: "Check surface build conditions in
-- dry_run and actual placement; name gravity restriction instead of footprint."). Run from the harness root:
-- lua tests/d28_batch328.lua
-- An entity's surface_conditions against the surface's properties, named before the footprint check (placement_error:
-- build, place_ghosts, their dry runs, blueprints), cached per prototype and per surface; load_silo's dry run names the
-- items the destination platform refuses.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end

storage={agent_harness={active={}}}
defines={events={on_script_path_request_finished=10,on_entity_died=11,on_entity_damaged=12,on_console_chat=13,on_unit_group_finished_gathering=14},
  shooting={not_shooting=0,shooting_enemies=1},controllers={character=1,remote=27,spectator=2},direction={north=0},
  inventory={chest=1,character_main=1,character_guns=3,character_ammo=4},
  build_mode={normal=1},build_check_type={manual=1},flow_precision_index={five_seconds=0,one_minute=1}}
prototypes={item={['submachine-gun']={type='gun',attack_parameters={ammo_categories={'bullet'},range=18}},
  ['rocket-launcher']={type='gun',attack_parameters={ammo_categories={'rocket'},range=36}},
  ['firearm-magazine']={type='ammo',ammo_category={name='bullet'}},rocket={type='ammo',ammo_category={name='rocket'}},
  ['iron-plate']={type='item'}}}
local drawn={}
rendering={draw_text=function() local obj={valid=true}; obj.destroy=function() obj.valid=false end; drawn[#drawn+1]=obj; return obj end,
  get_object_by_id=function(id) return drawn[id] end}
remote={interfaces={}}
helpers={json_to_table=function(t) return t end}
local force={name='player',get_friend=function() return false end,get_cease_fire=function() return false end,chart=function() end,
  is_chunk_visible=function() return true end,is_chunk_charted=function() return true end,get_spawn_position=function() return {x=0,y=0} end}
local surface={name='nauvis',index=1}
local units=0
local function character(pos)
  units=units+1
  local c={valid=true,name='character',type='character',force=force,surface=surface,position=pos,unit_number=500+units,health=250,max_health=250,
    prototype={collision_box={left_top={x=-0.2,y=-0.2},right_bottom={x=0.2,y=0.2}},collision_mask={layers={player=true}}},
    driving=false,build_distance=10,reach_distance=10,character_running_speed=0.15,walking_state={walking=false},selected_gun_index=1}
  c.insert=function(s) return s.count end
  c.get_item_count=function() return 0 end
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
local players={}
local tick=0
game={tick=0,players=players,forces={player=force,enemy={name='enemy',get_evolution_factor=function() return 0 end,get_evolution_factor_by_time=function() return 0 end,
  get_evolution_factor_by_pollution=function() return 0 end,get_evolution_factor_by_killing_spawners=function() return 0 end}},
  get_player=function(i) if type(i)=='string' then for _,p in ipairs(players) do if p.name==i then return p end end return nil end return players[i] end,
  get_surface=function() return surface end,print=function() end,connected_players=players,
  get_pollution_statistics=function() return {input_counts={},output_counts={},get_flow_count=function() return 0 end} end}
local runtime=dofile('mod/agent-harness_0.1.0/runtime.lua')

local BIG=1.7976931348623157e308
local reads={conds=0,prop=0}
local function proto(name,conds)
  return setmetatable({name=name,type='container',collision_box={left_top={x=-0.35,y=-0.35},right_bottom={x=0.35,y=0.35}}},
    {__index=function(_,k) if k=='surface_conditions' then reads.conds=reads.conds+1; return conds end end})
end
local chest=proto('iron-chest',{{property='gravity',min=0.1,max=BIG}})
local silo=proto('rocket-silo',{{property='pressure',min=1,max=BIG}})
local belt=proto('transport-belt',nil)
local odd=proto('odd-thing',{{property='magnetic-field',min=-BIG,max=50}})
local band=proto('band-thing',{{property='pressure',min=100,max=600}})
local found=0
local plat={valid=true,index=22,name='platform-22',platform={name='Resolute'},
  get_property=function(n) reads.prop=reads.prop+1; return ({gravity=0,pressure=0,['magnetic-field']=0})[n] end,
  find_entities_filtered=function() found=found+1; return {} end,find_tiles_filtered=function() return {} end}
local nauvis={valid=true,index=1,name='nauvis',planet={name='nauvis'},
  get_property=function(n) return ({gravity=10,pressure=1000,['magnetic-field']=90})[n] end}
local fulgora={valid=true,index=3,name='fulgora',planet={name='fulgora'},
  get_property=function(n) return ({gravity=8,pressure=800,['magnetic-field']=99})[n] end}
game.tick=100

eq(runtime.surface_block(plat,chest),'iron-chest cannot be placed on Resolute: needs gravity >= 0.1, this surface has 0')
eq(runtime.surface_block(plat,silo),'rocket-silo cannot be placed on Resolute: needs pressure >= 1, this surface has 0')
eq(runtime.surface_block(nauvis,chest),nil,'gravity 10 meets it')
eq(runtime.surface_block(plat,belt),nil,'no conditions')
eq(runtime.surface_block(fulgora,odd),'odd-thing cannot be placed on fulgora: needs magnetic-field <= 50, this surface has 99')
eq(runtime.surface_block(fulgora,band),'band-thing cannot be placed on fulgora: needs pressure between 100 and 600, this surface has 800')
-- cached: a prototype's conditions read once, a surface's property once a game minute
local c0,p0=reads.conds,reads.prop
for _=1,50 do runtime.surface_block(plat,chest) end
eq(reads.conds,c0,'conditions read once per prototype'); eq(reads.prop,p0,'a property read once a minute')
game.tick=100+3600
runtime.surface_block(plat,chest)
eq(reads.prop,p0+1,'read again after a minute')

-- placement: named first, before any footprint search ("nothing found in the footprint" before)
local text=runtime.placement_error({surface=plat,force=force},chest,{x=-19.5,y=-56.5},0,false)
eq(text,'placement blocked: iron-chest cannot be placed on Resolute: needs gravity >= 0.1, this surface has 0')
eq(found,0,'no footprint search')
local t2=runtime.placement_error({surface=plat,force=force},belt,{x=-19.5,y=-56.5},0,false)
assert(not t2:find('cannot be placed on',1,true) and found>0,t2)

-- load_silo: the items the destination platform refuses
prototypes.item['iron-chest']={type='item',place_result=chest}
prototypes.item['transport-belt']={type='item',place_result=belt}
local un=runtime.rocketload.unplaceable(plat,{{name='iron-chest',count=1},{name='transport-belt',count=5},{name='iron-plate',count=9}})
eq(#un,1); eq(un[1],'iron-chest cannot be placed on Resolute: needs gravity >= 0.1, this surface has 0')
eq(runtime.rocketload.unplaceable(nauvis,{{name='iron-chest',count=1}}),nil)
print('d28_batch328 surface conditions: named before the footprint, cached, load_silo notes: ok')
