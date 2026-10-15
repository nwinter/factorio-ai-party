-- Run from repository root: lua tests/round2120e.lua
-- A loop with an end (Muse, 21:20: "a looping queue primitive (repeat steps until time or count) for hand-feeding loops
-- like provider-to-furnace refills, hit ~10 times tonight"): queue_repeat takes times and for_ticks through the
-- runtime's argument check; its brief reply and queue_status say how many rounds are left; at the end the queue is
-- empty, queue_status has loop_done and the next reply's team block says it once.
-- Fake engine and bot as tests/round0320a.lua.
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

eq(runtime.takes('queue_repeat','times'),true); eq(runtime.takes('queue_repeat','for_ticks'),true)
-- Muse's refill: three rounds of a 30-tick step, 60 ticks apart.
local r=grok('queue_repeat',{name='furnace refill',times=3,interval_ticks=60,steps={{action='wait_ticks',args={ticks=30}}}})
eq(r.repeating,true); eq(r.times,3); eq(r.rounds_left,2); eq(r.cycle,1)
advance(100)
local q=grok('queue_status')
eq(q.cycle,2); eq(q.rounds_left,1); eq(q.repeating,true)
advance(300)
q=grok('queue_status',{history='all'})
eq(q.repeating,false); eq(q.pending_count,0); eq(q.times,nil)
eq(q.loop_done.rounds,3); eq(q.loop_done.name,'furnace refill'); eq(q.loop_done.reason,'3 of 3 rounds run (times 3)')
eq(q.history[#q.history].action,'loop_done')
local rounds=0
for _,e in ipairs(q.history) do if e.action=='wait_ticks' and e.ok then rounds=rounds+1 end end
eq(rounds,3,'three rounds ran')
-- The team block of the next reply (here that queue_status) says it, once.
local team=q.team
local line=team and team.queue and team.queue[#team.queue]
eq(line,'queue furnace refill done after 3 rounds: 3 of 3 rounds run (times 3)')
team=grok('status').team
eq(team and team.queue,nil,'once')
-- for_ticks: the brief reply names the tick after which no round starts.
local start=game.tick
r=grok('queue_repeat',{for_ticks=600,interval_ticks=60,steps={{action='wait_ticks',args={ticks=30}}}})
eq(r.stops_tick,start+600); eq(r.loop_done,nil)
advance(800)
q=grok('queue_status')
eq(q.repeating,false); eq(q.loop_done.reason,string.format('no round starts at or after tick %d (for_ticks 600)',start+600))
-- 90 ticks a round (30 of step, 60 between): rounds start at +1, +92, ..., +547; the next would start at +638.
eq(q.loop_done.rounds,7)
fails(function() grok('queue_repeat',{times=0,steps={{action='wait_ticks',args={ticks=30}}}}) end,'times must be 1..10000 rounds')
fails(function() grok('queue_repeat',{for_ticks=10,steps={{action='wait_ticks',args={ticks=30}}}}) end,'for_ticks must be 60..432000')
print('round2120e: ok')
