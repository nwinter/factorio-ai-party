-- Run from repository root: lua tests/underpass.lua
-- Why an underground belt or pipe-to-ground is unpaired (underpass.lua):
-- Sol's Vulcanus pairs spanned lava (15:45); inspect and build replies say
-- so, and place_ghosts warns when a span crosses lava or empty space.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
storage={agent_harness={active={}}}
defines={events={on_script_path_request_finished=10,on_entity_died=11,on_entity_damaged=12,on_console_chat=13,on_unit_group_finished_gathering=14},
  shooting={not_shooting=0,shooting_enemies=1},controllers={character=1,remote=27,spectator=2},direction={north=0,east=4,south=8,west=12},
  inventory={chest=1},build_mode={normal=1},build_check_type={manual=1,manual_ghost=2},flow_precision_index={five_seconds=0,one_minute=1},
  entity_status={working=1}}
rendering={draw_text=function() return {valid=true,destroy=function() end} end,get_object_by_id=function() return nil end}
remote={interfaces={}}
helpers={json_to_table=function(t) return t end}
prototypes={entity={['underground-belt']={name='underground-belt',type='underground-belt',max_underground_distance=5,items_to_place_this={{name='underground-belt',count=1}}},
  ['pipe-to-ground']={name='pipe-to-ground',type='pipe-to-ground',max_underground_distance=10,items_to_place_this={{name='pipe-to-ground',count=1}}}},
  item={},tile={},recipe={}}
local force={name='player',chart=function() end,is_chunk_visible=function() return true end,is_chunk_charted=function() return true end,get_spawn_position=function() return {x=0,y=0} end}
local surface={name='vulcanus',index=1,valid=true}
-- Lava on Vulcanus: lava-hot at x=-217 y=73..75 and lava at x=-152..-150 y=84 (the 15:47 reads).
local lava={}
for y=73,75 do lava['-217,'..y]='lava-hot' end
for x=-152,-150 do lava[x..',84']='lava' end
lava['-100,9']='empty-space'
surface.get_tile=function(x,y)
  local name=lava[x..','..y]
  local layers=name=='empty-space' and {empty_space=true} or name and {lava_tile=true} or {ground_tile=true}
  return {name=name or 'volcanic-ash-flats',prototype={collision_mask={layers=layers}}}
end
local entities={}
local function under(name,x,y,dir,kind,partner)
  local e={valid=true,name=name,type=name,position={x=x,y=y},direction=dir,surface=surface,force=force,belt_to_ground_type=kind,
    get_fluid_contents=function() return {} end,bounding_box={left_top={x=x-0.5,y=y-0.5},right_bottom={x=x+0.5,y=y+0.5}},
    get_max_transport_line_index=function() return 2 end,get_transport_line=function() return {get_contents=function() return {} end} end,
    get_inventory=function() return nil end}
  e.neighbours=partner
  entities[#entities+1]=e
  return e
end
local function within(e,f)
  if f.position then
    local d=((e.position.x-f.position.x)^2+(e.position.y-f.position.y)^2)^0.5
    return d<=(f.radius or 0.5)
  end
  if f.area then local a=f.area; return e.position.x>=a.left_top.x and e.position.x<=a.right_bottom.x and e.position.y>=a.left_top.y and e.position.y<=a.right_bottom.y end
  return true
end
surface.find_entities_filtered=function(f)
  local out={}
  for _,e in ipairs(entities) do
    if e.valid and within(e,f) and (not f.type or e.type==f.type or (type(f.type)=='table')) and (not f.name or e.name==f.name)
      and (not f.ghost_name or e.ghost_name==f.ghost_name) then out[#out+1]=e end
  end
  return out
end
surface.count_entities_filtered=function(f) return #surface.find_entities_filtered(f) end
surface.find_non_colliding_position=function(_,o) return o end
surface.can_place_entity=function() return true end
surface.find_tiles_filtered=function() return {} end
surface.get_total_pollution=function() return 0 end; surface.get_chunks=function() return function() end end; surface.get_pollution=function() return 0 end
surface.request_path=function() return 1 end
surface.create_entity=function(a)
  if a.name=='character' then
    local c={valid=true,name='character',type='character',force=force,surface=surface,position=a.position,unit_number=900,health=250,
      driving=false,build_distance=10,reach_distance=10,character_running_speed=0.15,walking_state={walking=false}}
    local inv={get_item_count=function() return 0 end,find_item_stack=function() return nil end,get_contents=function() return {} end}
    c.insert=function(s) return s.count end; c.get_main_inventory=function() return inv end; c.get_item_count=function() return 0 end
    c.can_reach_entity=function() return true end; c.destroy=function() c.valid=false end
    return c
  end
  if a.name=='entity-ghost' then
    local g={valid=true,name='entity-ghost',type='entity-ghost',ghost_name=a.inner_name,ghost_type=prototypes.entity[a.inner_name].type,
      position=a.position,direction=a.direction or 0,surface=surface,force=force,to_be_deconstructed=function() return false end}
    entities[#entities+1]=g
    return g
  end
end
local nick={index=1,name='nick',valid=true,connected=true,controller_type=1,physical_controller_type=1,cheat_mode=false,driving=false,force=force,surface=surface,position={x=-210,y=75},chat_color={r=1,g=1,b=1}}
nick.print=function() end
local players={nick}
game={tick=0,players=players,forces={player=force,enemy={name='enemy',get_evolution_factor=function() return 0 end,get_evolution_factor_by_time=function() return 0 end,
  get_evolution_factor_by_pollution=function() return 0 end,get_evolution_factor_by_killing_spawners=function() return 0 end}},
  get_player=function(i) if type(i)=='string' then return nil end return players[i] end,
  get_surface=function() return surface end,print=function() end,connected_players=players,
  get_pollution_statistics=function() return {input_counts={},output_counts={},get_flow_count=function() return 0 end} end}
local runtime=dofile('mod/agent-harness_0.1.0/runtime.lua')
runtime.operator.bot_create('sol')
local function sol(action,args) return runtime.dispatch{action=action,args=args,bot='sol'} end
local why=runtime.underpass.why

-- Sol's first pair: input at (-216.5,72.5) and output at (-216.5,77.5), both flowing south, lava-hot between.
local i1=under('underground-belt',-216.5,72.5,8,'input')
local o1=under('underground-belt',-216.5,77.5,8,'output')
eq(why(i1),'it cannot pass under lava-hot at (-217,73), lava-hot at (-217,74), lava-hot at (-217,75); the output at (-216.5,77.5) is on the far side')
eq(why(o1),'it cannot pass under lava-hot at (-217,75), lava-hot at (-217,74), lava-hot at (-217,73); the input at (-216.5,72.5) is on the far side')
-- The second: east at y=84.5, lava from x=-152 to -150.
local i2=under('underground-belt',-152.5,84.5,4,'input')
local o2=under('underground-belt',-147.5,84.5,4,'output')
eq(why(i2),'it cannot pass under lava at (-152,84), lava at (-151,84), lava at (-150,84); the output at (-147.5,84.5) is on the far side')
-- inspect says it.
local body=runtime.bots.record(runtime.bots.index_of('sol')).character
body.position={x=-214,y=75}
local r=sol('inspect',{position={x=-216.5,y=72.5}})
eq(r.unpaired,true); eq(r.unpaired_why,why(i1))
-- A pair the game paired: nothing to say.
local i3=under('underground-belt',0.5,0.5,4,'input'); local o3=under('underground-belt',4.5,0.5,4,'output',i3); i3.neighbours=o3
body.position={x=2,y=2}
r=sol('inspect',{position={x=0.5,y=0.5}})
eq(r.paired_with.x,4.5); eq(r.unpaired_why,nil)
-- No lava, a partner in reach, still unpaired: said as it is.
local i4=under('underground-belt',0.5,10.5,4,'input'); under('underground-belt',3.5,10.5,4,'output')
eq(why(i4),'the output at (3.5,10.5) is in reach and the game did not pair them')
-- No partner in reach.
local i5=under('underground-belt',0.5,20.5,8,'input')
eq(why(i5),'no underground-belt output within 5 tiles south')
-- The nearest on the axis flows the other way.
local o6=under('underground-belt',30.5,0.5,4,'output'); under('underground-belt',27.5,0.5,12,'input')
eq(why(o6),'the nearest underground-belt on its axis, at (27.5,0.5), is an input flowing west')
-- Pipe-to-ground over empty space (facing north: it reaches south).
local p1=under('pipe-to-ground',-99.5,7.5,0,nil)
under('pipe-to-ground',-99.5,11.5,8,nil)
p1.type='pipe-to-ground'
eq(why(p1),'it cannot pass under empty-space at (-100,9); its partner at (-99.5,11.5) is on the far side')

-- place_ghosts warns about a span over lava, once per span.
entities={}
r=sol('place_ghosts',{entities={{name='underground-belt',position={x=-216.5,y=72.5},direction='south',type='input'},
  {name='underground-belt',position={x=-216.5,y=77.5},direction='south',type='output'},
  {name='underground-belt',position={x=10.5,y=0.5},direction='east',type='input'},
  {name='underground-belt',position={x=13.5,y=0.5},direction='east',type='output'}}})
eq(r.placed,4); eq(#r.underground_warnings,1)
eq(r.underground_warnings[1],'underground-belt input ghost at (-216.5,72.5) will stay unpaired: it cannot pass under lava-hot at (-217,73), lava-hot at (-217,74), lava-hot at (-217,75); the output at (-216.5,77.5) is still a ghost')
-- A ghost with no type is an input (the game's default), and is checked as one.
entities={}
r=sol('place_ghosts',{entities={{name='underground-belt',position={x=-152.5,y=84.5},direction='east'}}})
assert(r.underground_warnings[1]:find('lava at (-152,84)',1,true),r.underground_warnings[1])
print('underpass: ok')
