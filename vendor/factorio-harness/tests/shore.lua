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

-- A boiler on water: the nearest positions where it fits facing north.
fails(function() bot('build',{item='boiler',position={x=10.5,y=5}}) end,
  'placement blocked by tiles: water (needs landfill, or a shore position: scan fields=fluids / grid ~ marks water); nearest positions where boiler fits facing north (game build check, within 6 tiles): (8.5,5) north, (8.5,4) north, (8.5,6) north')
-- A footprint with no water: the error is unchanged.
checks={}
local ok,err=pcall(bot,'build',{item='stone-furnace',position={x=5,y=3}})
assert(not ok and not err:find('nearest',1,true) and not err:find('fits',1,true),err)
eq(#checks,1)

-- placements: the same list without building.
local p=bot('placements',{name='offshore-pump'})
eq(p.name,'offshore-pump'); eq(p.radius,12); eq(#p.placements,3)
eq(p.placements[1].position.x,10); eq(p.placements[1].position.y,-0.5); eq(p.placements[1].direction,'east')
assert(p.checked>=3 and p.checked<=400,p.checked)
eq(c.items['offshore-pump'],1)
p=bot('placements',{name='boiler',position={x=12,y=0},radius=4})
eq(p.radius,4); eq(p.placements[1].position.x,8.5); eq(p.placements[1].direction,'north')
-- Only the asked direction.
eq(#bot('placements',{name='offshore-pump',direction='north'}).placements,0)
-- No water around: no pump candidate, nothing checked.
p=bot('placements',{name='offshore-pump',position={x=-20,y=0}})
eq(#p.placements,0); eq(p.checked,0)
fails(function() bot('placements',{name='offshore-pump',radius=17}) end,'radius out of range')
fails(function() bot('placements',{name='offshore-pump',direction='northeast'}) end,'direction is north, east, south or west')
fails(function() bot('placements',{name='nothing'}) end,'no entity or item named nothing')
fails(function() bot('placements',{}) end,'name is required')
fails(function() bot('placements',{name='boiler',size=3}) end,'size')
assert(runtime.dispatch{action='describe',args={},bot='astra'}.actions.placements.returns:find('at most 3',1,true))
print('shore: ok')
