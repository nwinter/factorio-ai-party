-- Run from repository root: lua tests/platformtiles.lua
-- deconstruct of platform foundation, through the runtime against a fake engine (platformtiles2; Astra, shift14
-- 21:55: a marked tile at (-2,8) on Sunward stayed marked for minutes): the reply plays every marked tile there out
-- by the game's rule (tilecheck.lua) and names those that wait, a dry run marks nothing, the platforms read and
-- inspect say the same.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,part) assert(type(s)=='string' and s:find(part,1,true),tostring(s)..' lacks '..part) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
storage={agent_harness={active={}}}
defines={events={on_script_path_request_finished=10,on_entity_died=11},shooting={not_shooting=0,shooting_enemies=1},
  controllers={character=1,remote=27,spectator=2},direction={north=0,east=4,south=8,west=12},
  inventory={chest=1,hub_main=21},build_mode={normal=1},build_check_type={manual=1,manual_ghost=2},
  flow_precision_index={five_seconds=0,one_minute=1},entity_status={working=1,marked_for_deconstruction=62},
  space_platform_state={waiting_at_station=6,paused=7}}
rendering={draw_text=function() return {valid=true,destroy=function() end} end,get_object_by_id=function() return nil end}
remote={interfaces={}}
helpers={json_to_table=function(t) return t end}
prototypes={entity={},item={['space-platform-foundation']={name='space-platform-foundation'}},recipe={},
  tile={['space-platform-foundation']={name='space-platform-foundation',mineable_properties={minable=true,products={{name='space-platform-foundation',amount=1}}}},
    ['empty-space']={name='empty-space',mineable_properties={minable=false}}}}
local force={name='player',chart=function() end,is_chunk_visible=function() return true end,is_chunk_charted=function() return true end,
  get_spawn_position=function() return {x=0,y=0} end,recipes={}}
local surface={name='nauvis',index=1}
-- The platform: foundation x -10..10, y -10..10 but for the holes; marks: the marked tiles, each with its proxy.
local psurf={name='platform-1',index=2}
local holes,marks,on_platform={},{},{}
local function k(x,y) return x..','..y end
local room=1000
local hub={valid=true,name='space-platform-hub',type='space-platform-hub',position={x=0,y=0},force=force,surface=psurf,direction=0,
  bounding_box={left_top={x=-2,y=-2},right_bottom={x=2,y=2}},get_fluid_contents=function() return {} end,
  get_logistic_sections=function() return nil end}
hub.get_inventory=function(i)
  if i==21 then return {valid=true,get_contents=function() return {} end,get_item_count=function() return 0 end,count_empty_stacks=function() return 5 end,
    get_insertable_count=function() return room end,is_empty=function() return true end} end
end
on_platform[1]=hub
local function solid(x,y) return x>=-10 and x<=10 and y>=-10 and y<=10 and not holes[k(x,y)] end
local function standing_on(x,y)
  for _,e in ipairs(on_platform) do
    local b=e.bounding_box
    if e.type~='deconstructible-tile-proxy' and b and b.left_top.x<x+1 and b.right_bottom.x>x and b.left_top.y<y+1 and b.right_bottom.y>y then return e end
  end
end
local function tile(x,y)
  local t={valid=true,position={x=x,y=y},name=solid(x,y) and 'space-platform-foundation' or 'empty-space'}
  t.prototype=prototypes.tile[t.name]
  t.to_be_deconstructed=function() return marks[k(x,y)]~=nil end
  t.order_deconstruction=function()
    if standing_on(x,y) then return nil end
    local proxy={valid=true,name='deconstructible-tile-proxy',type='deconstructible-tile-proxy',position={x=x+0.5,y=y+0.5},force=force,surface=psurf,
      direction=0,status=62,bounding_box={left_top={x=x,y=y},right_bottom={x=x+1,y=y+1}},get_inventory=function() return nil end,
      get_fluid_contents=function() return {} end,to_be_deconstructed=function() return true end,to_be_upgraded=function() return false end}
    marks[k(x,y)]=proxy; on_platform[#on_platform+1]=proxy
    return proxy
  end
  t.cancel_deconstruction=function()
    local proxy=marks[k(x,y)]; marks[k(x,y)]=nil
    for i,e in ipairs(on_platform) do if e==proxy then table.remove(on_platform,i); break end end
  end
  return t
end
psurf.get_tile=tile
psurf.find_tiles_filtered=function(f)
  local a=f.area
  local lt,rb=a.left_top or a[1],a.right_bottom or a[2]
  local x0,y0,x1,y1=math.floor(lt.x or lt[1]),math.floor(lt.y or lt[2]),math.ceil(rb.x or rb[1])-1,math.ceil(rb.y or rb[2])-1
  local names={}
  for _,n in ipairs(type(f.name)=='table' and f.name or {f.name}) do names[n]=true end
  local out={}
  for y=y0,y1 do for x=x0,x1 do local t=tile(x,y); if names[t.name] then out[#out+1]=t end end end
  return out
end
local function in_area(e,a)
  local lt,rb=a.left_top or a[1],a.right_bottom or a[2]
  return e.position.x>=(lt.x or lt[1]) and e.position.x<=(rb.x or rb[1]) and e.position.y>=(lt.y or lt[2]) and e.position.y<=(rb.y or rb[2])
end
local function types(f,e)
  if f.type==nil then return true end
  if type(f.type)=='string' then return e.type==f.type end
  for _,t in ipairs(f.type) do if e.type==t then return true end end
  return false
end
psurf.find_entities_filtered=function(f)
  local out={}
  for _,e in ipairs(on_platform) do
    local ok=types(f,e)
    if f.invert then ok=not ok end
    ok=ok and (f.name==nil or e.name==f.name) and (f.force==nil or e.force==f.force)
    if ok and f.to_be_deconstructed then ok=e.to_be_deconstructed and e.to_be_deconstructed() end
    if ok and f.area then
      local b=e.bounding_box
      local a=f.area
      local lt,rb=a.left_top or a[1],a.right_bottom or a[2]
      ok=b.left_top.x<(rb.x or rb[1]) and b.right_bottom.x>(lt.x or lt[1]) and b.left_top.y<(rb.y or rb[2]) and b.right_bottom.y>(lt.y or lt[2])
      if e.type=='deconstructible-tile-proxy' then ok=in_area(e,f.area) end
    end
    if ok and f.position then ok=math.abs(e.position.x-f.position.x)<=(f.radius or 0.5) and math.abs(e.position.y-f.position.y)<=(f.radius or 0.5) end
    if ok then out[#out+1]=e end
    if f.limit and #out>=f.limit then break end
  end
  return out
end
psurf.count_entities_filtered=function(f) return #psurf.find_entities_filtered(f) end
local platform={valid=true,name='Sunward',index=1,force=force,surface=psurf,hub=hub,state=6,space_location={name='nauvis'}}
psurf.platform=platform
force.platforms={platform}
local function character(pos)
  local c={valid=true,name='character',type='character',force=force,surface=surface,position=pos,unit_number=100,
    driving=false,build_distance=10,reach_distance=10,character_running_speed=0.15,walking_state={walking=false}}
  c.get_main_inventory=function() return {get_contents=function() return {} end,get_item_count=function() return 0 end,count_empty_stacks=function() return 10 end} end
  c.get_item_count=function() return 0 end
  c.insert=function(s) return s.count end
  c.can_reach_entity=function() return false end
  c.destroy=function() c.valid=false end
  return c
end
surface.find_entities_filtered=function() return {} end
surface.count_entities_filtered=function() return 0 end
surface.find_non_colliding_position=function() return {x=3,y=0} end
surface.create_entity=function(args) if args.name=='character' then return character(args.position) end end
surface.get_total_pollution=function() return 0 end; surface.get_chunks=function() return function() end end; surface.get_pollution=function() return 0 end
surface.request_path=function() return 1 end
local players={}
game={tick=0,players=players,forces={player=force,enemy={name='enemy',get_evolution_factor=function() return 0 end,get_evolution_factor_by_time=function() return 0 end,
  get_evolution_factor_by_pollution=function() return 0 end,get_evolution_factor_by_killing_spawners=function() return 0 end}},
  get_player=function(i) if type(i)=='string' then return nil end return players[i] end,
  get_surface=function(n) if n=='platform-1' or n==2 then return psurf end return surface end,print=function() end,connected_players=players,
  get_pollution_statistics=function() return {input_counts={},output_counts={},get_flow_count=function() return 0 end} end}
local runtime=dofile('mod/agent-harness_0.1.0/runtime.lua')
local function bot(action,args)
  local r=runtime.dispatch{action=action,args=args,bot='astra'}
  if type(r)=='string' then error(r,0) end
  return r
end
runtime.operator.bot_create('astra')
local function tiles_at(x,y) return {platform='Sunward',area={left_top={x=x,y=y},right_bottom={x=x+1,y=y+1}},tiles={'space-platform-foundation'}} end

-- 1. Astra's case: a tile whose four sides are foundation is marked, and waits; the reply says why.
local r=bot('deconstruct',tiles_at(-2,8))
eq(r.tiles_marked,1); eq(r.tiles_go,nil); eq(r.tiles_waiting,1)
eq(r.waiting[1],'(-1.5,8.5): none of its four side neighbours (north, east, south, west) is empty space: the hub removes a foundation tile only beside empty space')
-- A chain from the edge to it: the reply plays every marked tile on the platform out, in order.
for x=-9,-3 do bot('deconstruct',tiles_at(x,8)) end
r=bot('deconstruct',tiles_at(-10,8))
eq(r.tiles_waiting,nil)
eq(r.tiles_go,'9 marked tiles on the platform go, one at a time, each once a side neighbour is empty space, in this order: (-9.5,8.5), (-8.5,8.5), (-7.5,8.5), (-6.5,8.5), (-5.5,8.5), (-4.5,8.5), (-3.5,8.5), (-2.5,8.5), ...')
-- The platforms read and inspect say the same.
local row=bot('platforms',{platform='Sunward'}).platforms[1]
eq(row.tile_removals.marked,'9'); has(row.tile_removals.go,'9 marked tiles go, one at a time')
local ins=bot('inspect',{platform='Sunward',position={x=-9.5,y=8.5}})
eq(ins.name,'deconstructible-tile-proxy'); eq(ins.tile_wait,'marked for removal: nothing holds it; the hub removes it next')
ins=bot('inspect',{platform='Sunward',position={x=-1.5,y=8.5}})
eq(ins.tile_wait,'marked for removal: it goes once a tile beside it has gone (8 before it in the order the rule allows)')
bot('cancel_deconstruction',{platform='Sunward',area={left_top={x=-10,y=8},right_bottom={x=0,y=9}},tiles={'space-platform-foundation'}})
eq(next(marks),nil)

-- 2. Between two holes that do not meet round it: it would join them, and waits.
holes[k(3,-5)]=true; holes[k(5,-5)]=true
r=bot('deconstruct',tiles_at(4,-5))
eq(r.tiles_waiting,1); has(r.waiting[1],'(4.5,-4.5): its empty side neighbours (5.5,-4.5) and (3.5,-4.5) do not meet through the tiles round it')
bot('cancel_deconstruction',tiles_at(4,-5))

-- 3. The hub's room: two edge tiles, room for one.
room=1
bot('deconstruct',{platform='Sunward',area={left_top={x=10,y=0},right_bottom={x=11,y=2}},tiles={'space-platform-foundation'}})
row=bot('platforms',{platform='Sunward'}).platforms[1]
has(row.tile_removals.go,'1 marked tile goes'); eq(row.tile_removals.waiting[1],'(10.5,1.5): the hub has no room for space-platform-foundation')
room=1000
bot('cancel_deconstruction',{platform='Sunward',area={left_top={x=10,y=0},right_bottom={x=11,y=2}},tiles={'space-platform-foundation'}})

-- 4. A dry run marks nothing: what it would mark, what goes in turn and what waits; under an inserter the game refuses.
on_platform[#on_platform+1]={valid=true,name='fast-inserter',type='inserter',position={x=10.5,y=5.5},force=force,surface=psurf,
  bounding_box={left_top={x=10.1,y=5.1},right_bottom={x=10.9,y=5.9}},get_inventory=function() return nil end,get_fluid_contents=function() return {} end}
r=bot('deconstruct',{platform='Sunward',area={left_top={x=8,y=5},right_bottom={x=11,y=6}},tiles={'space-platform-foundation'},dry_run=true})
eq(r.dry_run,true); eq(r.mode,'dry_run'); eq(r.tiles_marked,nil); eq(r.tiles_would_mark,2); eq(r.refused.under_entity,1)
eq(next(marks),nil,'a dry run marks nothing')
-- (8,5) and (9,5): neither is beside empty space ((10,5) has the inserter): both wait.
eq(r.tiles_waiting,2); has(r.waiting[1],'none of its four side neighbours')
r=bot('deconstruct',{platform='Sunward',area={left_top={x=8,y=6},right_bottom={x=11,y=7}},tiles={'space-platform-foundation'},dry_run=true})
eq(r.tiles_would_mark,3); has(r.tiles_go,'3 marked tiles on the platform go')
fails(function() bot('cancel_deconstruction',{platform='Sunward',area={left_top={x=8,y=6},right_bottom={x=11,y=7}},tiles=true,dry_run=true}) end,'unknown argument dry_run for cancel_deconstruction')
fails(function() bot('deconstruct',{platform='Sunward',area={left_top={x=8,y=6},right_bottom={x=11,y=7}},tiles=true,dry_run='yes'}) end,'dry_run must be true or false')
print('platformtiles: ok')
