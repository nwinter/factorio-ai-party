-- d27 batch288 UG (Sol #2632): build replaced a fast underground pair's input at (63.5,142.5) with express, then its
-- other end (63.5,144.5) read "placement blocked by fast-underground-belt", and the belt was left an unpaired express
-- input and fast output. On a copy (2.0.77): can_place_entity takes no underground type and checks an input; over an
-- output end facing south, express facing south reads false, facing north true; create_entity {type: output, direction:
-- south} makes a south-flowing output that pairs; create_entity's own fast_replace replaces one end only. The harness
-- checked the output end facing south, so both the pair's other end (after the first) and entry 2 were refused. Now an
-- output end is checked facing the other way, the other end before either changes (refused: nothing changed), the first
-- end is put back when the second fails, and the build walks within reach of both ends.
-- Run from the harness root: lua tests/d27_batch288_rt.lua
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
defines.build_check_type.manual=1; defines.direction.south=8
prototypes=prototypes or {}; prototypes.entity=prototypes.entity or {}; prototypes.item=prototypes.item or {}
local express={name='express-underground-belt',type='underground-belt',fast_replaceable_group='transport-belt',max_underground_distance=9,
  collision_box={left_top={x=-0.4,y=-0.4},right_bottom={x=0.4,y=0.4}}}
local fastp={name='fast-underground-belt',type='underground-belt',fast_replaceable_group='transport-belt',max_underground_distance=7,
  collision_box={left_top={x=-0.4,y=-0.4},right_bottom={x=0.4,y=0.4}}}
prototypes.entity['express-underground-belt']=express; prototypes.entity['fast-underground-belt']=fastp
prototypes.item['express-underground-belt']={name='express-underground-belt',type='item',place_result=express}
-- Sol's first pair: a fast input at (63.5,142.5) and its output at (63.5,144.5), both facing south (8)
local inp={valid=true,name='fast-underground-belt',type='underground-belt',position={x=63.5,y=142.5},direction=8,belt_to_ground_type='input',force=force,prototype=fastp}
local out={valid=true,name='fast-underground-belt',type='underground-belt',position={x=63.5,y=144.5},direction=8,belt_to_ground_type='output',force=force,prototype=fastp}
inp.neighbours=out; out.neighbours=inp
local ents={inp,out}
surface.find_entities_filtered=function(f)
  local hits={}
  for _,e in ipairs(ents) do
    local ok=true
    if f.position then ok=math.abs(e.position.x-(f.position.x or f.position[1]))<=(f.radius or 0.01)+0.01 and math.abs(e.position.y-(f.position.y or f.position[2]))<=(f.radius or 0.01)+0.01 end
    if f.area then local a=f.area; local lt=a.left_top or a[1]; local rb=a.right_bottom or a[2]
      ok=e.position.x>=(lt.x or lt[1]) and e.position.x<=(rb.x or rb[1]) and e.position.y>=(lt.y or lt[2]) and e.position.y<=(rb.y or rb[2]) end
    if f.type and f.type~=e.type then ok=false end
    if ok then hits[#hits+1]=e end
  end
  return hits
end
local checks={}
local blocked={}
surface.can_place_entity=function(a) checks[#checks+1]=a; return not blocked[a.position.x..','..a.position.y] end
local p=nick
p.build_distance=10
p.position={x=60,y=145}
local held=4
p.get_main_inventory=function() return {get_item_count=function() return held end} end

-- the direction an underground end is checked at: an output facing south is checked as an input facing north
do
  eq(runtime.underground_check_direction('output',8),0); eq(runtime.underground_check_direction('output',4),12)
  eq(runtime.underground_check_direction('input',8),8); eq(runtime.underground_check_direction('output',nil),nil)
  print('UG an output end checked facing the other way: ok')
end

-- both ends in reach: the other end is checked (as an output, facing north) before either changes, and replaced with it
do
  checks={}
  local pair=runtime.underground_pair(p,express,{x=63.5,y=142.5},'express-underground-belt','normal')
  eq(pair.position.y,144.5); eq(pair.kind,'output'); eq(pair.direction,8); eq(pair.first.name,'fast-underground-belt'); eq(pair.first.kind,'input')
  eq(#checks,1); eq(checks[1].position.y,144.5); eq(checks[1].direction,0); eq(checks[1].name,'express-underground-belt')
  print('UG a pair within reach: the other end checked first, facing north: ok')
end

-- the other end blocked: refused before anything changes
do
  blocked['63.5,144.5']=true
  fails(function() runtime.underground_pair(p,express,{x=63.5,y=142.5},'express-underground-belt','normal') end,
    'fast-underground-belt (63.5,142.5) is one end of a pair with fast-underground-belt (63.5,144.5); the other end cannot take express-underground-belt: placement blocked')
  fails(function() runtime.underground_pair(p,express,{x=63.5,y=142.5},'express-underground-belt','normal') end,'; nothing was changed')
  blocked={}
  -- one item: refused as before, naming the two the pair takes
  held=1
  fails(function() runtime.underground_pair(p,express,{x=63.5,y=142.5},'express-underground-belt','normal') end,'you hold 1 express-underground-belt, the pair takes 2')
  held=4
  print('UG the other end blocked: refused, nothing changed: ok')
end

-- the walk: from where only the first end is in reach (Sol's first try: 11.1 tiles from the other), a spot within reach
-- of both, round their middle; both in reach: no walk
do
  p.position={x=56.9,y=135.6}
  local far=runtime.build_far(p,{item='express-underground-belt',position={x=63.5,y=142.5}},{})
  assert(far,'a walk')
  eq(far.point.x,63.5); eq(far.point.y,143.5); eq(far.walk_reach,8.75)
  assert(far.text:find('are replaced together: one is out of build reach',1,true),far.text)
  p.position={x=60,y=145}
  eq(runtime.build_far(p,{item='express-underground-belt',position={x=63.5,y=142.5}},{}),nil)
  -- an underground on empty ground: the build reach of its own spot, as before
  p.position={x=40,y=130}
  local plain=runtime.build_far(p,{item='express-underground-belt',position={x=70.5,y=130.5}},{})
  eq(plain.walk_reach,nil); eq(plain.point.x,70.5)
  print('UG the walk reaches both ends: ok')
end
game=nil
print('d27_batch288_rt UG: ok')
