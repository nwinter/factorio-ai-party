-- Run from repository root: lua tests/d22_batch93b.lua
-- d22 batch93 BC2 (viewer Foobator 13:33: the camera on a spidertron firing rockets): status brief's vehicle_fire.
-- The fixture is tests/flush.lua's (a runtime with one player, Nick).
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
storage={agent_harness={active={}}}
defines={events={on_script_path_request_finished=10,on_entity_died=11},shooting={not_shooting=0,shooting_enemies=1},
  controllers={character=1,remote=27,spectator=2},direction={north=0,east=4},inventory={chest=1},build_mode={normal=1},
  build_check_type={manual=1},flow_precision_index={five_seconds=0,one_minute=1},input_action={flush_opened_entity_fluid=77}}
rendering={draw_text=function() return {valid=true,destroy=function() end} end,get_object_by_id=function() return nil end}
remote={interfaces={}}
helpers={json_to_table=function(t) return t end}
prototypes={item={},fluid={['sulfuric-acid']={},['heavy-oil']={},water={}}}
local visible=true
local force={name='player',chart=function() end,is_chunk_visible=function() return visible end,is_chunk_charted=function() return true end,
  get_spawn_position=function() return {x=0,y=0} end,recipes={}}
local surface={name='vulcanus',index=1}
-- Segments: id -> {fluid, amount, box}; a flush empties one (or one fluid).
local segments={
  [7]={fluid='sulfuric-acid',amount=1200,box={left_top={x=0,y=2},right_bottom={x=40,y=4}}},
  [8]={fluid='water',amount=300,box={left_top={x=50,y=0},right_bottom={x=52,y=6}}},
  [9]={fluid='heavy-oil',amount=900,box={left_top={x=48,y=2},right_bottom={x=50,y=8}}}}
local flushes={}
local function boxes(ids)
  local b={}
  for i,id in ipairs(ids) do local s=segments[id]; b[i]=s.amount>0 and {name=s.fluid,amount=s.amount/10} or nil end
  b.get_fluid_segment_id=function(i) return ids[i] end
  b.get_fluid_segment_contents=function(i) local s=segments[ids[i]]; return s.amount>0 and {[s.fluid]=s.amount} or {} end
  b.get_fluid_segment_extent_bounding_box=function(i) return segments[ids[i]].box end
  b.get_capacity=function(i) return 100 end
  b.flush=function(i,fluid)
    local s=segments[ids[i]]
    flushes[#flushes+1]={id=ids[i],fluid=fluid}
    -- (d22 batch91 BA2) as 2.0.77 does on a copy of world n: with no fluid named, nothing is flushed
    if s.amount==0 or fluid==nil or fluid~=s.fluid then return {} end
    local out={[s.fluid]=s.amount}; s.amount=0
    return out
  end
  setmetatable(b,{__len=function() return #ids end})
  return b
end
local function ent(name,x,y,ids,extra)
  local e={valid=true,name=name,type=name,position={x=x,y=y},force=force,surface=surface,fluidbox=boxes(ids)}
  for k,v in pairs(extra or {}) do e[k]=v end
  return e
end
local pipe=ent('pipe',3,3,{7})
local pipe2=ent('pipe',20,3,{7})
local chem=ent('chemical-plant',50,4,{8,9})
local far_pipe=ent('pipe',30,3,{7})
local wall=ent('stone-wall',4,4,{})
wall.fluidbox=nil
local all={pipe,pipe2,chem,far_pipe,wall}
surface.find_entities_filtered=function(f)
  local out={}
  for _,e in ipairs(all) do
    local ok=true
    if f.position then
      local d=((e.position.x-f.position.x)^2+(e.position.y-f.position.y)^2)^0.5
      ok=d<=(f.radius or 0.5)
    end
    if ok and f.area then local a=f.area; ok=e.position.x>=a.left_top.x and e.position.x<=a.right_bottom.x and e.position.y>=a.left_top.y and e.position.y<=a.right_bottom.y end
    if ok and f.name then ok=e.name==f.name end
    if ok and f.force then ok=e.force==f.force end
    if ok then out[#out+1]=e end
  end
  return out
end
surface.count_entities_filtered=function(f) return #surface.find_entities_filtered(f) end
surface.find_non_colliding_position=function(_,origin) return origin end
surface.can_place_entity=function() return true end
surface.get_total_pollution=function() return 0 end; surface.get_chunks=function() return function() end end; surface.get_pollution=function() return 0 end
surface.request_path=function() return 1 end
local function character(pos)
  local c={valid=true,name='character',type='character',force=force,surface=surface,position=pos,unit_number=100,health=250,
    driving=false,build_distance=10,reach_distance=10,character_running_speed=0.15,walking_state={walking=false}}
  local inv={get_item_count=function() return 0 end,find_item_stack=function() return nil end,get_contents=function() return {} end}
  c.get_main_inventory=function() return inv end
  c.get_item_count=function() return 0 end
  c.insert=function(s) return s.count end
  c.can_reach_entity=function(e) return e.position.x<25 end
  c.destroy=function() c.valid=false end
  c.prototype={collision_mask={layers={player=true}}}
  return c
end
surface.create_entity=function(args) if args.name=='character' then return character(args.position) end end
local nick={index=1,name='nick',valid=true,connected=true,controller_type=1,physical_controller_type=1,cheat_mode=false,driving=false,force=force,surface=surface,position={x=5,y=5},chat_color={r=1,g=1,b=1}}
nick.character=character({x=5,y=5}); nick.print=function() end
local players={nick}
local tick=0
game={tick=0,players=players,forces={player=force,enemy={name='enemy',get_evolution_factor=function() return 0 end,get_evolution_factor_by_time=function() return 0 end,
  get_evolution_factor_by_pollution=function() return 0 end,get_evolution_factor_by_killing_spawners=function() return 0 end}},
  get_player=function(i) if type(i)=='string' then for _,p in ipairs(players) do if p.name==i then return p end end return nil end return players[i] end,
  get_surface=function() return surface end,print=function() end,connected_players=players,
  get_pollution_statistics=function() return {input_counts={},output_counts={},get_flow_count=function() return 0 end} end}
local runtime=dofile('mod/agent-harness_0.1.0/runtime.lua')

defines.inventory.spider_ammo=13
-- Opus's spidertron 2 at (-370,-926.4) on a copy of world n's 12:04 autosave: four rocket launchers (36 tiles), 162
-- rockets; the nest's spawners, worms and biters around (-369,-943).
local guns={}
for i=1,4 do guns['spidertron-rocket-launcher-'..i]={attack_parameters={range=36}} end
local ammo={get_item_count=function() return 162 end}
local spider={valid=true,name='spidertron',type='spider-vehicle',unit_number=22844293,position={x=-370,y=-926.4},surface=surface,
  prototype={guns=guns},get_inventory=function(i) eq(i,13); return ammo end}
local enemies={}
for _,q in ipairs({{-369,-943},{-383,-960},{-366,-930},{-375,-950}}) do enemies[#enemies+1]={position={x=q[1],y=q[2]}} end
local asked
surface.find_entities_filtered=function(f) asked=f; return enemies end
local p={driving=true,vehicle=spider}
local r=runtime.vehicle_fire(p)
eq(r.vehicle,'spidertron'); eq(r.range,36); eq(r.ammo,162); eq(r.targets,4)
eq(asked.force,'enemy'); eq(asked.radius,36); eq(asked.limit,64); eq(asked.position.x,-370)
eq(r.farthest,math.floor(((13)^2+(33.6)^2)^0.5*10+0.5)/10); eq(r.nearest,math.floor(((4)^2+(3.6)^2)^0.5*10+0.5)/10)
eq(r.box.left_top.x,-383); eq(r.box.left_top.y,-960); eq(r.box.right_bottom.x,-366); eq(r.box.right_bottom.y,-930)
-- none in range: targets 0, no distances
enemies={}
r=runtime.vehicle_fire(p)
eq(r.targets,0); eq(r.farthest,nil); eq(r.box,nil)
-- not in a spidertron: nil (a car, on foot)
eq(runtime.vehicle_fire({driving=true,vehicle={valid=true,type='car',name='car'}}),nil)
eq(runtime.vehicle_fire({driving=false}),nil)
print('d22_batch93b BC2 vehicle_fire: ok')
