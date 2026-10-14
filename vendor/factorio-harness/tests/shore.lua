-- Run from repository root: lua tests/shore.lua
-- Valid placements near a refused build (shore.lua) through the runtime
-- against a fake engine: a lake east of x=10, an offshore pump that fits only
-- on its shore facing east, a boiler that fits only on land.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
storage={agent_harness={active={}}}
defines={events={on_script_path_request_finished=10,on_entity_died=11},shooting={not_shooting=0,shooting_enemies=1},
  controllers={character=1,remote=27,spectator=2},direction={north=0,east=4,south=8,west=12},inventory={chest=1},build_mode={normal=1},
  build_check_type={manual=1,manual_ghost=2},flow_precision_index={five_seconds=0,one_minute=1}}
rendering={draw_text=function() return {valid=true,destroy=function() end} end,get_object_by_id=function() return nil end}
remote={interfaces={}}
helpers={json_to_table=function(t) return t end}
prototypes={entity={
  ['offshore-pump']={name='offshore-pump',type='offshore-pump',tile_width=1,tile_height=2},
  boiler={name='boiler',type='boiler',tile_width=3,tile_height=2},
  ['stone-furnace']={name='stone-furnace',type='furnace',tile_width=2,tile_height=2}},item={}}
prototypes.item['offshore-pump']={name='offshore-pump',place_result=prototypes.entity['offshore-pump']}
local force={name='player',chart=function() end,is_chunk_visible=function() return true end,is_chunk_charted=function() return true end,get_spawn_position=function() return {x=0,y=0} end}
local surface={name='nauvis',index=1}
local function character(pos)
  local items={}
  local c={valid=true,name='character',type='character',force=force,surface=surface,position=pos,unit_number=100,
    driving=false,build_distance=10,reach_distance=10,character_running_speed=0.15,walking_state={walking=false}}
  local inv={get_item_count=function(q) return items[type(q)=='table' and q.name or q] or 0 end,
    find_item_stack=function(q)
      if (items[q.name] or 0)==0 then return nil end
      local stack={prototype={place_result=prototypes.entity[q.name]}}
      stack.clear=function() items[q.name]=0 end
      return setmetatable(stack,{__index=function(_,k) if k=='count' then return items[q.name] end end,
        __newindex=function(_,k,v) if k=='count' then items[q.name]=v end end})
    end,
    get_contents=function() return {} end}
  c.items=items
  c.insert=function(s) items[s.name]=(items[s.name] or 0)+s.count; return s.count end
  c.get_main_inventory=function() return inv end
  c.get_item_count=function(n) return items[n] or 0 end
  c.can_reach_entity=function() return true end
  c.destroy=function() c.valid=false end
  return c
end
-- Tiles: water at tile x>=10.
local water={name='water',prototype={collision_mask={layers={water_tile=true,item=true}}}}
local grass={name='grass-1',prototype={collision_mask={layers={ground_tile=true}}}}
local tile_queries=0
surface.find_tiles_filtered=function(f)
  -- The closed-in check after a build (pathing.lua) floods with the character's box: not the shore search.
  if f.collision_mask=='player' then return {} end
  tile_queries=tile_queries+1
  local out={}
  local lt,rb=f.area.left_top,f.area.right_bottom
  for x=math.floor(lt.x),math.ceil(rb.x)-1 do
    for y=math.floor(lt.y),math.ceil(rb.y)-1 do
      local t=x>=10 and water or grass
      if f.collision_mask==nil or (f.collision_mask=='water_tile' and t==water) then
        out[#out+1]={name=t.name,prototype=t.prototype,position={x=x,y=y}}
        if f.limit and #out>=f.limit then return out end
      end
    end
  end
  return out
end
-- The game's check: a pump on the shore facing east (centre x=10: land tile
-- 9, water tile 10); a boiler (3x2 facing north) with every tile on land.
local checks={}
local blocked_y={}
surface.can_place_entity=function(a)
  if a.name=='character' then return true end
  checks[#checks+1]=a
  local x,y=a.position.x,a.position.y
  if a.name=='offshore-pump' then return a.direction==4 and x==10 and y%1==0.5 and not blocked_y[y] end
  if a.name=='boiler' then return a.direction==0 and x%1==0.5 and y%1==0 and x+1.5<=10 end
  return false
end
local created={}
surface.create_entity=function(args)
  if args.name=='character' then return character(args.position) end
  local e={valid=true,name=args.name,position=args.position,direction=args.direction,force=args.force,type=prototypes.entity[args.name].type}
  created[#created+1]=e
  return e
end
surface.find_entities_filtered=function() return {} end
surface.find_non_colliding_position=function() return {x=3,y=0} end
surface.get_total_pollution=function() return 0 end; surface.get_chunks=function() return function() end end; surface.get_pollution=function() return 0 end
surface.request_path=function() return 1 end
local nick={index=1,name='nick',valid=true,connected=true,controller_type=1,physical_controller_type=1,cheat_mode=false,driving=false,force=force,surface=surface,position={x=50,y=50},chat_color={r=1,g=1,b=1}}
nick.character=character({x=50,y=50})
nick.print=function() end
local players={nick}
game={tick=0,players=players,forces={player=force,enemy={name='enemy',get_evolution_factor=function() return 0 end,get_evolution_factor_by_time=function() return 0 end,
  get_evolution_factor_by_pollution=function() return 0 end,get_evolution_factor_by_killing_spawners=function() return 0 end}},
  get_player=function(i) if type(i)=='string' then for _,p in ipairs(players) do if p.name==i then return p end end return nil end return players[i] end,
  get_surface=function() return surface end,print=function() end,connected_players=players,
  get_pollution_statistics=function() return {input_counts={},output_counts={},get_flow_count=function() return 0 end} end}
local runtime=dofile('mod/agent-harness_0.1.0/runtime.lua')
local function bot(action,args) return runtime.dispatch{action=action,args=args,bot='astra'} end
runtime.operator.bot_create('astra')
local c=storage.agent_harness.bots.by_name.astra.character
eq(c.position.x,3)
c.items['offshore-pump']=2; c.items.boiler=2; c.items['stone-furnace']=1
local function pump_checks() local n=0; for _,a in ipairs(checks) do if a.name=='offshore-pump' then n=n+1 end end return n end

-- A pump on dry land: the error lists the nearest valid placements, nearest
-- first, the asked direction first on a tie, with the game's manual check.
fails(function() bot('build',{item='offshore-pump',position={x=5,y=0}}) end,
  'nearest valid offshore-pump placements (game build check, within 12 tiles): (10,-0.5) east, (10,0.5) east, (10,-1.5) east')
eq(c.items['offshore-pump'],2)
for _,a in ipairs(checks) do eq(a.build_check_type,defines.build_check_type.manual); eq(a.force,force) end
-- Only shore candidates reach the game: far fewer than the 25x25x4 around.
assert(pump_checks()<60,pump_checks())
-- The suggestion builds; a build that fits does not search.
checks={}
local queries=tile_queries
local r=bot('build',{item='offshore-pump',position={x=10,y=0.5},direction='east'})
eq(r.consumed,1); eq(created[#created].name,'offshore-pump'); eq(created[#created].direction,4)
eq(pump_checks(),1); eq(tile_queries,queries)
-- A spot taken on the shore is skipped (the game says no there).
blocked_y[-0.5]=true
fails(function() bot('build',{item='offshore-pump',position={x=10,y=-0.5},direction='east'}) end,
  'within 12 tiles): (10,-1.5) east, (10,0.5) east, (10,-2.5) east')
blocked_y[-0.5]=nil
-- A direction as the number inspect prints (friction1300: Grok's build with direction 0 was refused): 4 is east.
c.items['offshore-pump']=c.items['offshore-pump']+1
r=bot('build',{item='offshore-pump',position={x=10,y=1.5},direction=4})
eq(r.consumed,1); eq(created[#created].direction,4)
fails(function() bot('build',{item='offshore-pump',position={x=10,y=1.5},direction=16}) end,
  'invalid direction: a compass name (north, east, south, west) or 0..15')

-- A boiler on water: the nearest positions where it fits facing north.
fails(function() bot('build',{item='boiler',position={x=10.5,y=5}}) end,
  'placement blocked by tiles: water (needs landfill, or a shore position: scan fields=fluids / grid ~ marks water); nearest positions where boiler fits facing north (game build check, within 6 tiles): (8.5,5) north, (8.5,4) north, (8.5,6) north')
-- A footprint with no water: the error is unchanged.
checks={}
local ok,err=pcall(bot,'build',{item='stone-furnace',position={x=5,y=3}})
assert(not ok and not err:find('nearest',1,true) and not err:find('fits',1,true),err)
eq(#checks,1)

-- Turrets: a blocked build lists the nearest spots within build reach where the game accepts one; a build out of
-- reach lists the valid spots within reach nearest the asked position. Here a gun turret fits on land 2+ tiles off y=0.
prototypes.entity['gun-turret']={name='gun-turret',type='ammo-turret',tile_width=2,tile_height=2}
prototypes.item['gun-turret']={name='gun-turret',place_result=prototypes.entity['gun-turret']}
c.items['gun-turret']=2
local can_place=surface.can_place_entity
surface.can_place_entity=function(a)
  if a.name=='gun-turret' then return a.position.x%1==0 and a.position.y%1==0 and a.position.x<=8 and math.abs(a.position.y)>=2 end
  return can_place(a)
end
fails(function() bot('build',{item='gun-turret',position={x=5,y=0}}) end,
  '; nearest spots where gun-turret fits within your build reach (game build check): (5,-2), (5,2), (4,-2)')
fails(function() bot('build',{item='gun-turret',position={x=3,y=30}}) end,
  'out of build reach: ')
fails(function() bot('build',{item='gun-turret',position={x=3,y=30}}) end,
  '; nearest spots where gun-turret fits within your build reach (game build check): (3,9), (2,9), (4,9); or walk closer (move_to) and build again')
eq(c.items['gun-turret'],2)
-- Other items out of reach: unchanged.
ok,err=pcall(bot,'build',{item='stone-furnace',position={x=3,y=30}})
assert(not ok and err:find('out of build reach',1,true) and not err:find('spots',1,true),err)
-- The suggestion builds.
eq(bot('build',{item='gun-turret',position={x=3,y=9}}).consumed,1)
surface.can_place_entity=can_place

-- placements: the same list without building, as long as asked (default 10), nearest first.
local p=bot('placements',{name='offshore-pump'})
eq(p.name,'offshore-pump'); eq(p.radius,12); eq(#p.placements,10); eq(p.count,10); eq(p.more,true)
eq(p.placements[1].position.x,10); eq(p.placements[1].position.y,-0.5); eq(p.placements[1].direction,'east')
assert(p.checked>=10 and p.checked<=200,p.checked)
p=bot('placements',{name='offshore-pump',limit=3})
eq(#p.placements,3); eq(p.placements[3].position.y,-1.5)
eq(c.items['offshore-pump'],1)
-- near is the centre (position too, as before).
p=bot('placements',{name='boiler',near={x=12,y=0},radius=4})
eq(p.radius,4); eq(p.near.x,12); eq(p.placements[1].position.x,8.5); eq(p.placements[1].direction,'north')
p=bot('placements',{name='boiler',position={x=12,y=0},radius=4})
eq(p.placements[1].position.x,8.5)
fails(function() bot('placements',{name='boiler',near={x=12,y=0},position={x=12,y=0}}) end,'near and position both name the centre')
-- Only the asked direction.
eq(#bot('placements',{name='offshore-pump',direction='north'}).placements,0)
-- No water around: no pump candidate, nothing checked.
p=bot('placements',{name='offshore-pump',near={x=-20,y=0}})
eq(#p.placements,0); eq(p.checked,0)
fails(function() bot('placements',{name='offshore-pump',radius=25}) end,'radius out of range')
fails(function() bot('placements',{name='offshore-pump',limit=51}) end,'limit out of range')
fails(function() bot('placements',{name='offshore-pump',direction='northeast'}) end,'direction is north, east, south or west')
-- A number as inspect prints it.
p=bot('placements',{name='offshore-pump',direction=4,limit=2})
eq(#p.placements,2); eq(p.placements[1].direction,'east')
eq(#bot('placements',{name='offshore-pump',direction=0}).placements,0)
fails(function() bot('placements',{name='offshore-pump',direction=2}) end,'direction is north, east, south or west (or 0, 4, 8, 12)')
fails(function() bot('placements',{name='boiler',separate='yes'}) end,'separate must be true or false')
fails(function() bot('placements',{name='boiler',powered=1}) end,'powered must be true or false')
fails(function() bot('placements',{name='nothing'}) end,'no entity or item named nothing')
fails(function() bot('placements',{}) end,'name is required')
fails(function() bot('placements',{name='boiler',size=3}) end,'size')
assert(runtime.dispatch{action='describe',args={},bot='astra'}.actions.placements.returns:find('nearest first',1,true))

-- The scan before the game check (Gemini 10:50: an accumulator at radius 16 found nothing in 400 checks): with
-- collision layers known, a position an entity or a water tile is in the way of never reaches the game, and a
-- building that does not turn is checked once per position, without a direction.
local building={layers={item=true,object=true,player=true,water_tile=true,is_object=true,is_lower_object=true}}
prototypes.entity.accumulator={name='accumulator',type='accumulator',tile_width=2,tile_height=2,supports_direction=false,
  collision_box={left_top={x=-0.9,y=-0.9},right_bottom={x=0.9,y=0.9}},collision_mask=building}
prototypes.entity['stone-furnace'].collision_mask=building
prototypes.entity['tree-01']={name='tree-01',type='tree',collision_mask={layers={item=true,object=true,player=true,water_tile=true,is_object=true,is_lower_object=true}}}
prototypes.entity['iron-ore']={name='iron-ore',type='resource',collision_mask={layers={resource=true}}}
water.prototype.collision_mask={layers={water_tile=true,item=true,player=true,resource=true,doodad=true,floor=true}}
local tq=surface.find_tiles_filtered
surface.find_tiles_filtered=function(f)
  if type(f.collision_mask)=='table' then
    local wants=false
    for _,l in ipairs(f.collision_mask) do if l=='water_tile' then wants=true end end
    return wants and tq{area=f.area,collision_mask='water_tile',limit=f.limit} or {}
  end
  return tq(f)
end
-- A furnace (2x2) at (2,2) and a tree at (-1.5,0.5) on land; ore under (0.5,-2.5) blocks nothing.
local scene={{valid=true,type='furnace',name='stone-furnace',bounding_box={left_top={x=1.1,y=1.1},right_bottom={x=2.9,y=2.9}}},
  {valid=true,type='tree',name='tree-01',bounding_box={left_top={x=-1.9,y=0.1},right_bottom={x=-1.1,y=0.9}}},
  {valid=true,type='resource',name='iron-ore',bounding_box={left_top={x=0.1,y=-2.9},right_bottom={x=0.9,y=-2.1}}},
  {valid=true,type='entity-ghost',name='entity-ghost',bounding_box={left_top={x=-0.9,y=-0.9},right_bottom={x=0.9,y=0.9}}}}
surface.find_entities_filtered=function(f) if f.area then return scene end return {} end
local asked={}
surface.can_place_entity=function(a)
  if a.name=='character' then return true end
  if a.name=='accumulator' then
    asked[#asked+1]=a
    local x,y=a.position.x,a.position.y
    -- the game: no water under it, clear of the furnace and the tree
    if x+1>10 then return false end
    if math.abs(x-2)<2 and math.abs(y-2)<2 then return false end
    if x>-3 and x<0 and y>-1 and y<2 then return false end
    return true
  end
  return can_place(a)
end
p=bot('placements',{name='accumulator',near={x=1,y=1},radius=3,limit=50})
assert(#p.placements>0)
eq(p.placements[1].direction,nil)
for _,s in ipairs(p.placements) do
  assert(not (math.abs(s.position.x-2)<2 and math.abs(s.position.y-2)<2),'on the furnace')
end
-- every position the game was asked passed (the scan ruled out the rest), each once
for _,a in ipairs(asked) do eq(a.direction,0) end
eq(#asked,#p.placements); eq(p.checked,#asked)
assert(p.blocked and p.blocked>0,tostring(p.blocked))
eq(p.more,nil)
-- the furnace and tree positions are in blocked, the ghost and ore are not: (0,0) (under the ghost) and (1,-2)
-- (over the ore) fit
local at={}
for _,s in ipairs(p.placements) do at[s.position.x..','..s.position.y]=true end
assert(at['0,0'] and at['1,-2'] and not at['2,2'] and not at['-1,1'])
-- separate (friction1300: Gemini built accumulators from one placements list, and the third was blocked by the
-- second, 1 tile apart): each spot overlaps none nearer in the list, so all of them can be built.
local all=p
asked={}
p=bot('placements',{name='accumulator',near={x=1,y=1},radius=3,limit=50,separate=true})
eq(p.separate,true); assert(#p.placements>1 and #p.placements<#all.placements,#p.placements)
assert(p.overlap and p.overlap>0,tostring(p.overlap))
for i,s in ipairs(p.placements) do
  for k=1,i-1 do
    local o=p.placements[k]
    assert(math.abs(s.position.x-o.position.x)>=2 or math.abs(s.position.y-o.position.y)>=2,
      'overlap: ('..s.position.x..','..s.position.y..') and ('..o.position.x..','..o.position.y..')')
  end
end
-- the nearest spot is the same; the game was asked about the listed spots only
eq(p.placements[1].position.x,all.placements[1].position.x); eq(p.placements[1].position.y,all.placements[1].position.y)
eq(#asked,#p.placements)
-- powered: a small pole of ours at (-2.5,-2.5) supplies -5..0 (supply area distance 2.5); an accumulator (2x2)
-- there needs a tile in it: centre x <= 0 and y <= 0. Another force's pole counts for nothing.
local pole={valid=true,type='electric-pole',name='small-electric-pole',position={x=-2.5,y=-2.5},force=force,quality={name='normal'},
  prototype={get_supply_area_distance=function(q) eq(q,'normal'); return 2.5 end}}
local theirs={valid=true,type='electric-pole',name='small-electric-pole',position={x=3.5,y=3.5},force={name='enemy'},quality={name='normal'},
  prototype={get_supply_area_distance=function() return 2.5 end}}
local find_entities=surface.find_entities_filtered
local pole_query
surface.find_entities_filtered=function(f)
  if f.type=='electric-pole' then
    pole_query=f
    local out={}
    for _,e in ipairs({pole,theirs}) do if e.force==f.force then out[#out+1]=e end end
    return out
  end
  return find_entities(f)
end
asked={}
p=bot('placements',{name='accumulator',near={x=1,y=1},radius=3,limit=50,powered=true})
eq(pole_query.force,force)
eq(p.powered,true); eq(p.poles,1); assert(p.unpowered and p.unpowered>0,tostring(p.unpowered))
assert(#p.placements>0)
for _,s in ipairs(p.placements) do assert(s.position.x<=0 and s.position.y<=0,'unpowered: '..s.position.x..','..s.position.y) end
local at0={}
for _,s in ipairs(p.placements) do at0[s.position.x..','..s.position.y]=true end
-- within 3 tiles of (1,1): (0,0), (0,-1), (-1,-1); (-1,0) is on the tree
eq(#p.placements,3); assert(at0['0,0'] and at0['0,-1'] and at0['-1,-1'],'powered spots')
eq(#asked,#p.placements)
-- both: powered spots that do not overlap
p=bot('placements',{name='accumulator',near={x=1,y=1},radius=3,limit=50,powered=true,separate=true})
for i,s in ipairs(p.placements) do
  assert(s.position.x<=0 and s.position.y<=0)
  for k=1,i-1 do
    local o=p.placements[k]
    assert(math.abs(s.position.x-o.position.x)>=2 or math.abs(s.position.y-o.position.y)>=2,'overlap')
  end
end
-- no pole near: nothing listed, every candidate counted as unpowered
pole.position={x=-60.5,y=-60.5}
p=bot('placements',{name='accumulator',near={x=1,y=1},radius=3,limit=50,powered=true})
eq(#p.placements,0); eq(p.poles,0); assert(p.unpowered>0)
surface.find_entities_filtered=find_entities
-- Water: a boiler beside the lake; positions with water under them are blocked, not checked.
checks={}
p=bot('placements',{name='boiler',near={x=9,y=-5},radius=3,direction='north',limit=50})
for _,a in ipairs(checks) do assert(a.position.x+1.5<=10,'checked over water: '..a.position.x) end
prototypes.entity.boiler.collision_mask=building
checks={}
p=bot('placements',{name='boiler',near={x=9,y=-5},radius=3,direction='north',limit=50})
for _,a in ipairs(checks) do assert(a.position.x+1.5<=10,'checked over water: '..a.position.x) end
assert(p.blocked and p.blocked>0)
-- Chunks our force does not see now are left out (unseen); the centre's chunk is seen.
force.is_chunk_visible=function(_,chunk) return chunk.x>=0 end
asked={}
p=bot('placements',{name='accumulator',near={x=1,y=1},radius=3,limit=50})
for _,s in ipairs(p.placements) do assert(s.position.x>=0,'unseen chunk: '..s.position.x) end
assert(p.unseen and p.unseen>0)
force.is_chunk_visible=function() return true end
-- By remote view: a centre out of sight in a chunk our force sees.
p=bot('placements',{name='accumulator',near={x=60,y=1},radius=2})
eq(p.by,'remote view')
-- A pump as 2.0.77 has it: 1x1, its own tile on land, water in the 2x3 tiles in front (tile_buildability_rules).
-- Only positions those rules allow reach the game: land tiles at x=9 facing east.
prototypes.entity['offshore-pump']={name='offshore-pump',type='offshore-pump',tile_width=1,tile_height=1,
  collision_box={left_top={x=-0.6,y=-1.05},right_bottom={x=0.6,y=0.3}},
  collision_mask={layers={is_lower_object=true,is_object=true,object=true,train=true}},
  tile_buildability_rules={
    {area={left_top={x=-0.4,y=-0.4},right_bottom={x=0.4,y=0.4}},required_tiles={layers={ground_tile=true}},colliding_tiles={layers={water_tile=true}}},
    {area={left_top={x=-1,y=-2},right_bottom={x=1,y=-1}},required_tiles={layers={water_tile=true}},colliding_tiles={layers={}}}}}
asked={}
surface.can_place_entity=function(a)
  if a.name=='character' then return true end
  if a.name=='offshore-pump' then asked[#asked+1]=a; return a.direction==4 and a.position.x==9.5 and a.position.y~=0.5 end
  return can_place(a)
end
scene={}
p=bot('placements',{name='offshore-pump',near={x=5,y=0},limit=5})
eq(#p.placements,5); eq(p.placements[1].position.x,9.5); eq(p.placements[1].position.y,-0.5); eq(p.placements[1].direction,'east')
for _,a in ipairs(asked) do eq(a.position.x,9.5); eq(a.direction,4) end
eq(p.checked,6)
-- A block all of colliding tiles (the lake, x>=16) is counted, never read tile by tile.
local reads=0
surface.count_tiles_filtered=function(f)
  local n=0
  local lt,rb=f.area.left_top,f.area.right_bottom
  for x=math.floor(lt.x),math.ceil(rb.x)-1 do for y=math.floor(lt.y),math.ceil(rb.y)-1 do if x>=10 then n=n+1 end end end
  return n
end
local find_tiles=surface.find_tiles_filtered
surface.find_tiles_filtered=function(f)
  if f.area and f.area.left_top.x>=10 then reads=reads+1 end
  return find_tiles(f)
end
asked={}
p=bot('placements',{name='accumulator',near={x=14,y=0},radius=6,limit=50})
eq(reads,0)
assert(p.blocked and p.blocked>0)
for _,a in ipairs(asked) do assert(a.position.x+1<=10,'over the lake: '..a.position.x) end
surface.count_tiles_filtered=nil; surface.find_tiles_filtered=find_tiles
print('shore: ok')
