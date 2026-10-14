-- Run from repository root: lua tests/water.lua
-- Water a character can walk through, apart from water it cannot cross (friction1300: Gemini read Fulgora's oil
-- ocean, which map and grid drew as water, as water it could not cross; on a copy of world n a character walked
-- across 6 tiles of oil-ocean-deep at half speed). The tiles' collision layers are 2.0.77's.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
storage={agent_harness={active={}}}
defines={events={on_script_path_request_finished=10,on_entity_died=11},shooting={not_shooting=0,shooting_enemies=1},
  controllers={character=1,remote=27,spectator=2},direction={north=0,east=4,south=8,west=12},inventory={chest=1},build_mode={normal=1},
  build_check_type={manual=1,manual_ghost=2},flow_precision_index={five_seconds=0,one_minute=1}}
rendering={draw_text=function() return {valid=true,destroy=function() end} end,get_object_by_id=function() return nil end}
remote={interfaces={}}
helpers={json_to_table=function(t) return t end}
local function mask(...) local l={} for _,k in ipairs({...}) do l[k]=true end return {layers=l} end
prototypes={entity={character={name='character',type='character',collision_mask=mask('is_object','player','train')}},item={},tile={
  ['grass-1']={name='grass-1',collision_mask=mask('ground_tile')},
  ['oil-ocean-shallow']={name='oil-ocean-shallow',collision_mask=mask('resource','water_tile')},
  ['oil-ocean-deep']={name='oil-ocean-deep',collision_mask=mask('rail_support','resource','water_tile')},
  ['water-shallow']={name='water-shallow',collision_mask=mask('floor','resource','water_tile')},
  deepwater={name='deepwater',collision_mask=mask('doodad','floor','item','player','resource','water_tile')},
  lava={name='lava',collision_mask=mask('doodad','item','lava_tile','player','rail','resource','water_tile')},
  ['out-of-map']={name='out-of-map',collision_mask=mask('doodad','floor','ground_tile','item','object','out_of_map','player','resource','water_tile')}}}
-- x 0..15 oil-ocean-shallow, 16..31 oil-ocean-deep (chunk 0: walkable), 32..63 deepwater (chunk 1), 64..95 lava
-- (chunk 2), grass elsewhere.
local function tile_at(x)
  if x>=0 and x<16 then return 'oil-ocean-shallow' elseif x>=16 and x<32 then return 'oil-ocean-deep'
  elseif x>=32 and x<64 then return 'deepwater' elseif x>=64 and x<96 then return 'lava' end
  return 'grass-1'
end
local function each_tile(area,fn)
  local lt,rb=area.left_top or area[1],area.right_bottom or area[2]
  local x0,y0=lt.x or lt[1],lt.y or lt[2]
  local x1,y1=rb.x or rb[1],rb.y or rb[2]
  for x=math.floor(x0),math.ceil(x1)-1 do for y=math.floor(y0),math.ceil(y1)-1 do fn(x,y,tile_at(x)) end end
end
local force={name='player',chart=function() end,is_chunk_visible=function() return true end,is_chunk_charted=function() return true end,
  get_spawn_position=function() return {x=0,y=0} end}
local surface={name='fulgora',index=1}
local counted={}
surface.count_tiles_filtered=function(f)
  local names={}
  for _,n in ipairs(type(f.name)=='table' and f.name or {f.name}) do names[n]=true end
  counted[#counted+1]=f.name
  local n=0
  each_tile(f.area,function(_,_,name) if names[name] then n=n+1 end end)
  return n
end
surface.find_tiles_filtered=function(f)
  local out={}
  each_tile(f.area,function(x,y,name)
    local layers=prototypes.tile[name].collision_mask.layers
    if f.collision_mask==nil or (f.collision_mask=='water_tile' and layers.water_tile) then out[#out+1]={name=name,position={x=x,y=y}} end
  end)
  return out
end
surface.find_entities_filtered=function() return {} end
surface.find_non_colliding_position=function() return {x=-40,y=16} end
surface.get_total_pollution=function() return 0 end; surface.get_chunks=function() return function() end end; surface.get_pollution=function() return 0 end
surface.request_path=function() return 1 end
local function character(pos)
  local items={}
  local c={valid=true,name='character',type='character',force=force,surface=surface,position=pos,unit_number=100,
    driving=false,build_distance=10,reach_distance=10,character_running_speed=0.15,walking_state={walking=false}}
  local inv={get_item_count=function(q) return items[type(q)=='table' and q.name or q] or 0 end,
    find_item_stack=function() return nil end,get_contents=function() return {} end}
  c.insert=function(st) items[st.name]=(items[st.name] or 0)+st.count; return st.count end
  c.get_main_inventory=function() return inv end
  c.get_item_count=function(n) return items[n] or 0 end
  c.can_reach_entity=function() return true end
  c.destroy=function() c.valid=false end
  return c
end
surface.create_entity=function(args) if args.name=='character' then return character(args.position) end end
local nick={index=1,name='nick',valid=true,connected=true,controller_type=1,physical_controller_type=1,cheat_mode=false,driving=false,force=force,surface=surface,position={x=-40,y=16},chat_color={r=1,g=1,b=1}}
nick.print=function() end
local players={nick}
game={tick=0,players=players,forces={player=force,enemy={name='enemy',get_evolution_factor=function() return 0 end,get_evolution_factor_by_time=function() return 0 end,
  get_evolution_factor_by_pollution=function() return 0 end,get_evolution_factor_by_killing_spawners=function() return 0 end}},
  get_player=function(i) if type(i)=='string' then for _,p in ipairs(players) do if p.name==i then return p end end return nil end return players[i] end,
  get_surface=function() return surface end,print=function() end,connected_players=players,
  get_pollution_statistics=function() return {input_counts={},output_counts={},get_flow_count=function() return 0 end} end}
local runtime=dofile('mod/agent-harness_0.1.0/runtime.lua')
local function bot(action,args) return runtime.dispatch{action=action,args=args,bot='gemini'} end
runtime.operator.bot_create('gemini')

-- Each tile by what a character can do there: its layers meet none of the character's (walkable), it is lava, or not.
eq(runtime.water_kind('oil-ocean-shallow'),'walkable'); eq(runtime.water_kind('oil-ocean-deep'),'walkable')
eq(runtime.water_kind('water-shallow'),'walkable'); eq(runtime.water_kind('deepwater'),'water'); eq(runtime.water_kind('lava'),'lava')
eq(runtime.water_kind('grass-1'),nil); eq(runtime.water_kind('out-of-map'),nil); eq(runtime.water_kind('no-such-tile'),nil)

-- map: walkable water, water and lava are regions of their own, each counted in tiles.
local r=bot('map',{position={x=40,y=16},radius=32,resources=false,enemies=false})
local by={}
for _,g in ipairs(r.regions) do by[g.name]=g end
eq(by['walkable water'].kind,'water'); eq(by['walkable water'].count,3*1024); eq(by['walkable water'].left,0); eq(by['walkable water'].right,32)
eq(by.water.kind,'water'); eq(by.water.count,3*1024); eq(by.water.left,32); eq(by.water.right,64)
eq(by.lava.kind,'lava'); eq(by.lava.count,3*1024); eq(by.lava.left,64)
assert(r.scope:find('walkable water: water tiles a character walks through',1,true),r.scope)
-- A chunk with no water is counted once (no count of its walkable tiles or lava).
counted={}
bot('map',{position={x=-100,y=16},radius=32,resources=false,enemies=false})
eq(#counted,9)

-- grid: ',' for water a character walks through, '~' for water it cannot cross; the legend names the tiles.
local g=bot('grid',{area={left_top={x=28,y=0},right_bottom={x=36,y=1}}})
eq(g.rows[1].row,',,,,~~~~')
eq(g.legend[','],'water a character walks through: oil-ocean-deep')
eq(g.legend['~'],'water a character cannot cross: deepwater')
g=bot('grid',{area={left_top={x=12,y=0},right_bottom={x=20,y=1}}})
eq(g.rows[1].row,',,,,,,,,')
eq(g.legend[','],'water a character walks through: oil-ocean-shallow, oil-ocean-deep')
eq(g.legend['~'],nil)
-- Lava stays '~'.
g=bot('grid',{area={left_top={x=62,y=0},right_bottom={x=66,y=1}}})
eq(g.rows[1].row,'~~~~'); eq(g.legend['~'],'water a character cannot cross: deepwater, lava')
-- With no character prototype to compare with, water is water (as before).
runtime.water_kinds=nil
prototypes.entity.character=nil
eq(runtime.water_kind('oil-ocean-shallow'),'water')
print('water: ok')
