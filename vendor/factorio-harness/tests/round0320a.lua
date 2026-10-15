-- Run from repository root: lua tests/round0320a.lua
-- A mined-out resource tile (Grok 03:20: "A repeating mine should skip a mined-out tile and pick the next stone in
-- radius instead of stalling the whole loop. I hit that three times this shift on one patch (73.5,-54.5 then -55.5)").
-- Grok's step was mine {position, ticks=300}, no name; the stone tiles and the stand spot are Grok's shift09 ones.
-- Fake engine as tests/minerotate.lua: reach 2.7 to the box for ore.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
storage={agent_harness={active={}}}
defines={events={on_script_path_request_finished=10,on_entity_died=11,on_entity_damaged=12,on_console_chat=13,on_unit_group_finished_gathering=14},
  shooting={not_shooting=0,shooting_enemies=1},controllers={character=1,remote=27,spectator=2},direction={north=0},inventory={chest=1},
  build_mode={normal=1},build_check_type={manual=1},flow_precision_index={five_seconds=0,one_minute=1}}
local drawn={}
rendering={draw_text=function() local obj={id=#drawn+1,valid=true}; obj.destroy=function() obj.valid=false end; drawn[#drawn+1]=obj; return obj end,
  get_object_by_id=function(id) return drawn[id] end}
remote={interfaces={}}
helpers={json_to_table=function(t) return t end}
prototypes={item={stone={}},entity={stone={name='stone',type='resource'},['iron-chest']={name='iron-chest',type='container'}}}
local force={name='player',chart=function() end,is_chunk_visible=function() return true end,is_chunk_charted=function() return true end,
  get_spawn_position=function() return {x=0,y=0} end}
local neutral={name='neutral'}
local surface={name='nauvis',index=1}
local world={}
local function box_distance(pos,e)
  local b=e.bounding_box
  local dx=math.max(b.left_top.x-pos.x,0,pos.x-b.right_bottom.x)
  local dy=math.max(b.left_top.y-pos.y,0,pos.y-b.right_bottom.y)
  return (dx*dx+dy*dy)^0.5
end
local function dist(a,b) return ((a.x-b.x)^2+(a.y-b.y)^2)^0.5 end
surface.find_non_colliding_position=function(_,pos) return {x=math.floor(pos.x)+0.5,y=math.floor(pos.y)+0.5} end
surface.can_place_entity=function() return true end
surface.find_entities_filtered=function(f)
  local out={}
  for _,e in ipairs(world) do
    local near=f.position and ((f.radius and f.radius>=1) and dist(e.position,f.position)<=f.radius
      or math.abs(e.position.x-f.position.x)<0.3 and math.abs(e.position.y-f.position.y)<0.3)
    if e.valid and near and (not f.name or f.name==e.name) and (not f.type or f.type==e.type) then out[#out+1]=e end
  end
  return out
end
surface.get_total_pollution=function() return 0 end; surface.get_chunks=function() return function() end end; surface.get_pollution=function() return 0 end
surface.request_path=function() return 1 end
local function character(pos)
  local c={valid=true,name='character',type='character',force=force,surface=surface,position=pos,unit_number=501,health=250,max_health=250,
    driving=false,build_distance=10,reach_distance=10,resource_reach_distance=2.7,character_running_speed=0.15,walking_state={walking=false},
    prototype={mining_speed=0.5,collision_mask={layers={player=true}}}}
  local inv={get_item_count=function() return 0 end,find_item_stack=function() return nil end,get_contents=function() return {} end}
  c.get_main_inventory=function() return inv end
  c.get_item_count=function() return 0 end
  c.insert=function(s) return s.count end
  c.can_insert=function() return true end
  c.can_reach_entity=function(e) return box_distance(c.position,e)<=2.7 end
  -- One unit a cycle, as the engine's mine_entity on a resource.
  c.mine_entity=function(e) e.amount=e.amount-1; if e.amount<=0 then e.valid=false end; return not e.valid end
  c.destroy=function() c.valid=false end
  return c
end
surface.create_entity=function(args) if args.name=='character' then return character(args.position) end return {valid=true,name=args.name,position=args.position} end
local nick={index=1,name='nick',valid=true,connected=true,controller_type=1,physical_controller_type=1,cheat_mode=false,driving=false,force=force,surface=surface,position={x=5,y=5},chat_color={r=1,g=1,b=1}}
nick.character=character({x=5,y=5})
local players={nick}
for _,pl in ipairs(players) do pl.print=function() end end
local tick=0
game={tick=0,players=players,forces={player=force,enemy={name='enemy',get_evolution_factor=function() return 0 end,get_evolution_factor_by_time=function() return 0 end,
  get_evolution_factor_by_pollution=function() return 0 end,get_evolution_factor_by_killing_spawners=function() return 0 end}},
  get_player=function(i) if type(i)=='string' then for _,p in ipairs(players) do if p.name==i then return p end end return nil end return players[i] end,
  get_surface=function() return surface end,print=function() end,connected_players=players,
  get_pollution_statistics=function() return {input_counts={},output_counts={},get_flow_count=function() return 0 end} end}
local runtime=dofile('mod/agent-harness_0.1.0/runtime.lua')
local function advance(n) for _=1,n do tick=tick+1; game.tick=tick; runtime.tick{tick=tick} end end
local function request(req)
  local ok,result=pcall(runtime.dispatch,req)
  if not ok then error(result,0) end
  return result
end
runtime.operator.bot_create('grok')
local function grok(action,args) return request{action=action,args=args or {},bot='grok'} end
local body=runtime.bots.lookup(runtime.bots.index_of('grok')).character
for k,v in pairs(character({x=0,y=0})) do if type(v)=='function' and k~='destroy' then body[k]=v end end
body.prototype={mining_speed=0.5,collision_mask={layers={player=true}}}
body.can_reach_entity=function(e) return box_distance(body.position,e)<=2.7 end
local function stone(x,y,amount)
  local e={valid=true,name='stone',type='resource',position={x=x,y=y},force=neutral,amount=amount,minable=true,
    bounding_box={left_top={x=x-0.4,y=y-0.4},right_bottom={x=x+0.4,y=y+0.4}},
    prototype={mineable_properties={mining_time=1,products={{type='item',name='stone',amount=1}}}}}
  world[#world+1]=e
  return e
end
-- Grok's patch: (73.5,-54.5) nearly gone, (73.5,-55.5) and (72.5,-54.5) next to it, (79.5,-54.5) out of reach.
local a=stone(73.5,-54.5,2)
local b=stone(73.5,-55.5,50)
local c=stone(72.5,-54.5,50)
local far=stone(79.5,-54.5,50)
-- Grok stood at (72.2,-55.5) (journal 07:42): (73.5,-55.5) is 0.9 tiles off, (72.5,-54.5) 0.7.
body.position={x=72.2,y=-55.5}

-- 1. Grok's loop: mine the tile 300 ticks (two units at 120 ticks each), then the next cycle 60 ticks later.
grok('queue_repeat',{steps={{action='mine',args={position={x=73.5,y=-54.5},ticks=300}}},interval_ticks=60})
advance(300)
eq(a.valid,false,'the tile is mined out')
local h=grok('queue_status').history
eq(h[#h].ok,true); eq(h[#h].result.outcome,'target_mined')
-- Next cycle: the step's position is gone; the stone nearest the character in reach is mined instead, and said so.
advance(80)
local q=grok('queue_status')
eq(q.paused,false,'the loop goes on')
eq(q.active.action,'mine')
local accepted=q.active.result.instead
assert(accepted,'the step reply names the tile taken')
eq(accepted.name,'stone'); eq(accepted.mined_out.x,73.5); eq(accepted.mined_out.y,-54.5)
eq(accepted.position.x,72.5); eq(accepted.position.y,-54.5)
eq(accepted.line,'stone at (73.5,-54.5) is mined out; mining stone at (72.5,-54.5), 1.0 tiles from it')
advance(300)
eq(grok('status').last.instead,'stone at (73.5,-54.5) is mined out; mining stone at (72.5,-54.5), 1.0 tiles from it')
eq(c.amount<50,true,'the other tile is being mined')
grok('queue_cancel',{})

-- 2. A direct mine at a mined-out position: the same, from memory (no name given).
local r=grok('mine',{position={x=73.5,y=-54.5},ticks=60})
eq(r.instead.position.x,72.5)
grok('stop',{})
-- With name, a position never mined before is looked up too.
local d=stone(70.5,-56.5,5); d.valid=false
r=grok('mine',{position={x=70.5,y=-56.5},name='stone',ticks=60})
eq(r.instead.name,'stone'); assert(r.instead.position.x==72.5 or r.instead.position.x==73.5,tostring(r.instead.position.x))
grok('stop',{})

-- 3. Nothing in reach: the reach refusal names the nearest tile and a spot; nothing left: says so.
b.valid=false; c.valid=false
fails(function() grok('mine',{position={x=73.5,y=-54.5},walk=false}) end,'stone at (73.5,-54.5) is mined out; the nearest stone within 8 tiles is out of reach: entity is out of reach: stone at (79.5,-54.5)')
-- By default (autowalk.lua) the call walks into reach of that tile first; made there, it mines the nearest tile left.
r=grok('mine',{position={x=73.5,y=-54.5}})
eq(r.walking_for,'mine'); assert(r.walking:find('stone at (73.5,-54.5) is mined out; the nearest: stone (79.5,-54.5) is ',1,true),r.walking)
grok('stop',{})
fails(function() grok('mine',{position={x=73.5,y=-54.5},radius=4}) end,'stone at (73.5,-54.5) is mined out and no stone is left within 4 tiles of it')
fails(function() grok('mine',{position={x=73.5,y=-54.5},radius=40}) end,'radius')
-- radius widens the search: within it, a tile in reach is taken first.
body.position={x=78.2,y=-55.5}
r=grok('mine',{position={x=73.5,y=-54.5},radius=8,ticks=60})
eq(r.instead.position.x,79.5)
grok('stop',{})
far.valid=false

-- 4. A position nobody mined and no name: the plain error, unchanged; a building's position is never swapped.
fails(function() grok('mine',{position={x=60.5,y=-50.5}}) end,'entity not found at (60.5,-50.5)')
-- describe lists radius.
assert(grok('describe',{}).actions.mine.radius:find('mined out',1,true))

-- 5. repair over positions (Astra 03:42): a target in reach is repaired; one the character cannot walk to (this fake
-- never moves it) counts as not reached, and the tally says so.
local function furnace(x,y,health)
  local e={valid=true,name='stone-furnace',type='furnace',force=force,position={x=x,y=y},health=health,max_health=200,minable=true,
    bounding_box={left_top={x=x-0.9,y=y-0.9},right_bottom={x=x+0.9,y=y+0.9}},prototype={repair_speed_modifier=1}}
  world[#world+1]=e
  return e
end
body.can_reach_entity=function(e) return box_distance(body.position,e)<=(e.type=='resource' and 2.7 or 10) end
body.position={x=0.5,y=0.5}
local near=furnace(3,0,150)
local unreachable=furnace(25,0,100)
local whole=furnace(5,0,200)
local pack={valid_for_read=false,prototype={type='repair-tool',speed=2},name='repair-pack',durability=300}
local packs=1
body.cursor_stack={valid_for_read=false,swap_stack=function() pack.valid_for_read=true; pack.count=1; packs=0
  setmetatable(body.cursor_stack,{__index=pack}); body.cursor_stack.valid_for_read=nil; return true end}
pack.drain_durability=function(n) pack.durability=pack.durability-n end
pack.clear=function() pack.valid_for_read=false end
body.get_main_inventory().find_item_stack=function(name) if name=='repair-pack' and packs>0 then return {count=packs,prototype=pack.prototype} end end
body.get_main_inventory().insert=function(st) packs=packs+st.count; return st.count end
body.repair_state={repairing=false}
local rep=grok('repair',{positions={{x=25,y=0},{x=3,y=0},{x=5,y=0}},ticks=3000})
eq(rep.damaged,2); eq(rep.already_full,1)
advance(200)
eq(near.health,200)
-- The walk to (25,0) waits on a path this fake never answers: the time runs out with it left.
eq(grok('status').active.kind,'repair')
advance(2801)
local rl=grok('status').last
eq(rl.outcome,'timed_out'); eq(rl.repaired,1); eq(rl.already_full,1); eq(rl.left,1)
eq(rl.tally,'repaired 1, 1 already full, 1 left (timed_out)')
eq(unreachable.health,100)
-- The engine answers that no path leads there (each request of the pathing ladder): not reached, and the list ends.
grok('repair',{positions={{x=25,y=0}},ticks=3000})
for _=1,40 do
  advance(5)
  runtime.on_event{name=defines.events.on_script_path_request_finished,tick=tick,id=1,path=nil,try_again_later=false}
  if not grok('status').active then break end
end
rl=grok('status').last
eq(rl.outcome,'repair_completed'); eq(rl.unreached,1); eq(rl.repaired,0); eq(rl.tally,'repaired 0, 0 already full, 1 not reached')
print('round0320a: ok')
