-- Run from repository root: lua mod/tests/runtime_test.lua
local assertions=0
local function eq(a,b,message) assertions=assertions+1; assert(a==b,(message or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function fails(fn,pattern)
  local ok,err=pcall(fn); eq(ok,false,'expected error'); assert(tostring(err):find(pattern,1,true),tostring(err))
end
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
storage={agent_harness={active={}}}
defines={events={on_script_path_request_finished=10,on_entity_died=11},shooting={not_shooting=0,shooting_enemies=1},controllers={character=1,remote=27},direction={north=0},inventory={chest=1},build_mode={normal=1},flow_precision_index={five_seconds=0,one_minute=1}}
local p={index=1,valid=true,connected=true,controller_type=1,physical_controller_type=1,character={valid=true},position={x=0,y=0},cheat_mode=false,driving=false}
p.force={name='player',is_chunk_visible=function() return true end,is_chunk_charted=function() return true end,get_spawn_position=function() return {x=0,y=0} end}
p.surface={name='nauvis'}
p.character.prototype={collision_mask={layers={player=true}}}
local path_requests={}
p.surface.request_path=function(args) path_requests[#path_requests+1]=args; return #path_requests end
p.can_reach_entity=function() return true end
local flying={}
p.create_local_flying_text=function(args) flying[#flying+1]=args.text end
local tick=0
local evolution=0.25
local enemy_evolution={name='enemy',get_evolution_factor=function() return evolution end,get_evolution_factor_by_time=function() return 0.2 end,
  get_evolution_factor_by_pollution=function() return 0.04 end,get_evolution_factor_by_killing_spawners=function() return 0.01 end}
local pollution_stats={input_counts={},output_counts={},get_flow_count=function() return 0 end}
game={tick=tick,get_player=function(index) if index==1 then return p end end,forces={enemy=enemy_evolution},
  get_pollution_statistics=function() return pollution_stats end}
p.surface.index=1; p.surface.get_total_pollution=function() return 0 end; p.surface.get_chunks=function() return function() end end; p.surface.get_pollution=function() return 0 end
p.surface.find_entities_filtered=function() return {} end
local runtime=dofile('mod/agent-harness_0.1.0/runtime.lua')
local function call(action,args) return runtime.dispatch{action=action,args=args,player=1} end
local function advance(n)
  for _=1,n do tick=tick+1; game.tick=tick; runtime.tick{tick=tick} end
end
call('walk',{direction='east',ticks=2})
eq(call('status').active.kind,'walk')
advance(1); eq(p.walking_state.walking,true); eq(p.walking_state.direction,4)
advance(1); eq(p.walking_state.walking,true)
advance(1); eq(p.walking_state.walking,false); eq(call('status').active,false)
eq(call('status').last.outcome,'duration_elapsed')
-- brief: what fh --wait polls, without the factory, threat or alert scans.
do
  local b=call('status',{brief=true,peek=true})
  eq(b.brief,true); eq(b.last.outcome,'duration_elapsed'); eq(b.active,false); eq(b.combat,false); eq(b.alive,true)
  eq(b.factory,nil); eq(b.evolution,nil); eq(b.warnings,nil); eq(b.tick,tick)
  -- The fluid check is kept per surface: status alternating between two surfaces scans each once per 10 s.
  local pipe_scans=0
  local home=p.surface
  local find=home.find_entities_filtered
  local function counting(f) if type(f.type)=='table' and f.type[1]=='pipe' then pipe_scans=pipe_scans+1 end return find(f) end
  home.find_entities_filtered=counting
  local away=setmetatable({index=2,name='vulcanus',find_entities_filtered=counting},{__index=home})
  -- (home was checked by the status calls above, within the 10 s)
  for _=1,4 do p.surface=away; call('status'); p.surface=home; call('status') end
  eq(pipe_scans,1)
  for _,fc in pairs(storage.agent_harness.fluid_checks) do fc.tick=fc.tick-600 end -- 10 s later
  for _=1,4 do p.surface=away; call('status'); p.surface=home; call('status') end
  eq(pipe_scans,3)
  home.find_entities_filtered=find
end
-- Tick steering uses actual position, tolerates speed changes, and stops safely.
call('move_to',{position={x=10,y=0},pathfind=false})
advance(1); eq(p.walking_state.direction,4)
p.position={x=9.8,y=0}; advance(1)
eq(call('status').last.outcome,'arrived'); eq(p.walking_state.walking,false)
eq(call('status').last.target.x,10)
eq(call('status').last.on_belt,nil); eq(call('status').on_belt,nil)
-- Arriving on a belt (shift08: Grok's arrivals on the y=-27.5 belt carried it
-- off): move_to steps to the nearest free tile without a belt and says so;
-- status says a belt carries the character for as long as it stands on one.
do
local belt={valid=true,name='fast-transport-belt',direction=0}
local belt_area
local function on_belt_tile(area) return area[1][1]==9 and area[1][2]==0 end
p.surface.find_entities_filtered=function(f)
  if f.area and f.type and f.limit==1 and on_belt_tile(f.area) then belt_area=f.area; return {belt} end
  return {}
end
call('move_to',{position={x=10,y=0},pathfind=false}); advance(1); advance(1)
eq(call('status').active.kind,'move_to'); eq(p.walking_state.direction,14) -- off the belt: northwest to (9.5,-0.5)
p.position={x=9.5,y=-0.4}; advance(1)
eq(call('status').last.outcome,'arrived'); eq(call('status').last.on_belt,nil)
eq(call('status').last.off_belt,'arrived on a fast-transport-belt; stepped to (9.5,-0.5), the nearest free tile without a belt (none within the arrival radius)')
-- Standing on one: status says it carries the character.
p.position={x=9.8,y=0}
local note='standing on a fast-transport-belt facing north: it carries you; step off to stay put'
eq(call('status').on_belt,note); eq(belt_area[1][1],9); eq(belt_area[2][2],1)
p.driving=true; eq(call('status').on_belt,nil); p.driving=false
p.surface.find_entities_filtered=function() return {} end
eq(call('status').on_belt,nil)
end
p.position={x=0,y=0}
-- Stuck in place: sidestep on each stall, give up after the stall budget.
call('move_to',{position={x=10,y=0},pathfind=false}); advance(9)
eq(p.walking_state.walking,true); eq(p.walking_state.direction==4,false) -- sidestep, not east
advance(200)
eq(call('status').last.outcome,'blocked'); eq(p.walking_state.walking,false); eq(call('status').last.stalls,16)
call('move_to',{position={x=10,y=0},ticks=1,pathfind=false}); advance(2)
eq(call('status').last.outcome,'timed_out')
call('move_to',{position={x=0.3,y=0},tolerance=0.25,pathfind=false})
advance(1); p.position={x=0.6,y=0}; advance(1); p.position={x=0,y=0}; advance(1)
eq(call('status').last.outcome,'arrived_near'); eq(p.walking_state.walking,false)
-- Back-and-forth far from the goal is handled as a stall (sidestep), not an outcome.
call('move_to',{position={x=30,y=0},pathfind=false})
for i=1,12 do p.position={x=i%2*0.3,y=0}; advance(1) end
eq(call('status').active.kind,'move_to'); eq(p.walking_state.direction==4,false); call('stop',{})
p.position={x=0,y=0}
-- Moving every tick without getting closer (a belt carrying the character back
-- over a cycle of 3 spots) is still a stall: it sidesteps, then gives up.
call('move_to',{position={x=30,y=0},pathfind=false})
for i=1,89 do p.position={x=(i%3)*0.2,y=0}; advance(1) end
eq(call('status').active.kind,'move_to'); eq(p.walking_state.direction,4) -- still heading east
p.position={x=0.4,y=0}; advance(1); p.position={x=0,y=0}; advance(1)
eq(p.walking_state.direction==4,false) -- sidestep after 90 ticks without progress
for i=1,2000 do p.position={x=(i%3)*0.2,y=0}; advance(1) end
eq(call('status').last.outcome,'blocked'); eq(call('status').last.no_progress>=1,true)
-- The status watchdog flags an active walk that neither progresses nor moves.
call('move_to',{position={x=30,y=0},pathfind=false,ticks=3000})
for i=1,700 do p.position={x=(i%3)*0.2,y=(i%5)*0.2}; advance(1) end
local stuck=call('status')
assert(stuck.active and stuck.active.stuck_s and stuck.active.stuck_s>=10,'stuck_s expected')
assert(stuck.warnings and stuck.warnings[1]:find('likely physically stuck',1,true),'stuck warning expected')
call('stop',{})
p.position={x=0,y=0}
-- A goal inside an entity: stuck beside it counts as arrived_near, not blocked.
call('move_to',{position={x=1.5,y=0},pathfind=false}); advance(7)
eq(call('status').active.kind,'move_to'); advance(1); eq(call('status').last.outcome,'arrived_near')
-- within widens the arrival radius up to 10 tiles.
call('move_to',{position={x=8,y=0},within=9}); advance(1)
eq(call('status').last.outcome,'arrived')
-- Pathfinding: wait for the engine path and its belt-free twin, follow
-- waypoints, replan when stuck; failures climb the ladder (pathing.lua).
p.position={x=0,y=0}
eq(call('move_to',{position={x=10,y=10}}).pathfinding,true)
local request=path_requests[#path_requests-1]
eq(request.goal.x,10); eq(request.entity_to_ignore,p.character); eq(request.bounding_box[1][1],-0.35)
do
  local twin=path_requests[#path_requests]
  eq(twin.collision_mask.layers.transport_belt,true); eq(twin.collision_mask.layers.player,true); eq(request.collision_mask.layers.transport_belt,nil)
end
advance(1); eq(p.walking_state.walking,false)
runtime.on_event{name=10,id=#path_requests-1,path={{position={x=0,y=5}},{position={x=10,y=10}}}}
advance(1); eq(p.walking_state.walking,false) -- the twin has not answered yet
runtime.on_event{name=10,id=#path_requests,path=nil} -- no way off belts: the walk's own path
advance(1); eq(p.walking_state.direction,8) -- south toward the first waypoint
advance(1); eq(p.walking_state.direction,8) -- hysteresis holds the heading
p.position={x=0,y=4.8}; advance(1); eq(p.walking_state.direction,6) -- next waypoint: southeast
local before=#path_requests; advance(30); eq(#path_requests,before+2) -- third stall: replan, with its twin
eq(path_requests[#path_requests-1].radius>request.radius,true) -- wider radius
-- Both fail: the character's own box from the nearest free tile centre, then
-- the half-tile grid, then the quarter-tile grid with a wider goal.
local padded=path_requests[#path_requests-1]
p.surface.find_non_colliding_position=function(name,pos,radius,precision,tile_centre)
  eq(tile_centre,true); return {x=math.floor(pos.x)+0.5,y=math.floor(pos.y)+0.5}
end
runtime.on_event{name=10,id=#path_requests-1,path=nil}; runtime.on_event{name=10,id=#path_requests,path=nil}
do
  local own=path_requests[#path_requests]
  eq(own.bounding_box[1][1],-0.2); eq(own.radius,padded.radius); eq(own.start.x,math.floor(p.position.x)+0.5); eq(own.path_resolution_modifier,nil)
end
runtime.on_event{name=10,id=#path_requests,path=nil}
eq(path_requests[#path_requests].path_resolution_modifier,1); eq(path_requests[#path_requests].start.x,p.position.x)
eq(path_requests[#path_requests].pathfind_flags.no_break,false)
runtime.on_event{name=10,id=#path_requests,path=nil}
eq(path_requests[#path_requests].path_resolution_modifier,2); eq(path_requests[#path_requests].radius,padded.radius+3)
-- None found a route; open ground around (not closed in), so one wide request
-- says where it can get to, and the walk ends unreachable.
runtime.on_event{name=10,id=#path_requests,path=nil}
eq(path_requests[#path_requests].radius>padded.radius+3,true)
advance(1); eq(p.walking_state.walking,false); eq(call('status').active.kind,'move_to')
runtime.on_event{name=10,id=#path_requests,path={{position={x=0,y=4.8}},{position={x=6,y=6}}}}
advance(1)
do
  local gave=call('status').last
  eq(gave.outcome,'unreachable'); eq(gave.nearest_reachable.x,6); eq(gave.reachable_gap,5.7); eq(gave.paths_failed,4)
  eq(gave.why,'no path for the character to (10,10) on the tile, half- or quarter-tile grid')
end
-- A target on ungenerated ground: the pathfinder knows none of it, so steer directly as before.
p.surface.is_chunk_generated=function() return false end
call('move_to',{position={x=10,y=10}})
runtime.on_event{name=10,id=#path_requests-1,path=nil}; runtime.on_event{name=10,id=#path_requests,path=nil}
for _=1,3 do runtime.on_event{name=10,id=#path_requests,path=nil} end
p.position={x=5,y=10}; advance(1); eq(p.walking_state.direction,4) -- direct fallback
p.position={x=9.9,y=10}; advance(1); eq(call('status').last.outcome,'arrived'); eq(call('status').last.steered,'without a path: ungenerated')
p.surface.is_chunk_generated=nil
-- Stale path results for replaced actions are ignored.
runtime.on_event{name=10,id=1,path={{position={x=99,y=99}}}}
-- Destroyed player buildings become status alerts; enemies do not.
runtime.on_event{name=11,tick=tick,entity={valid=true,name='stone-furnace',position={x=1,y=2},force={name='player'}}}
runtime.on_event{name=11,tick=tick,entity={valid=true,name='small-biter',position={x=1,y=2},force={name='enemy'}}}
local alerts=call('status').alerts
eq(alerts.losses['stone-furnace'],1); eq(alerts.losses['small-biter'],nil)
-- The stream's read: brief with the same alerts and where the body is, and no surface scan at all.
do
  local scans,find=0,p.surface.find_entities_filtered
  p.surface.find_entities_filtered=function(f) scans=scans+1; return find(f) end
  local b=call('status',{brief=true,alerts=true,peek=true})
  eq(b.alerts.losses['stone-furnace'],1); eq(b.alerts.latest[1],alerts.latest[1]); eq(b.surface,'nauvis'); eq(b.connected,true)
  eq(b.factory,nil); eq(b.enemies,nil); eq(scans,0)
  eq(call('status',{brief=true,peek=true}).alerts,nil)
  fails(function() call('status',{alerts=true}) end,'alerts is an option of brief')
  p.surface.find_entities_filtered=find
end
-- A wipe larger than any entry cap is counted whole, per area, and pushed once
-- on the next reply of any kind.
for i=1,80 do runtime.on_event{name=11,tick=tick,cause={valid=true,name='small-biter'},entity={valid=true,name=i<=16 and 'electric-mining-drill' or 'transport-belt',position={x=200+i%10,y=-90},force={name='player'}}} end
-- Losses ride in the reply's team alerts.
local function loss_line(reply)
  for _,line in ipairs(reply.team and reply.team.alerts or {}) do if line:find('^losses #%d+ ') then return line end end
end
local pushed=call('status')
assert(loss_line(pushed):find(' in (200,-90)-(209,-90) 80 destroyed: 64 transport-belt, 16 electric-mining-drill by 80 small-biter',1,true),loss_line(pushed))
eq(pushed.alerts.losses['transport-belt'],64); eq(pushed.alerts.losses['electric-mining-drill'],16)
eq(loss_line(call('queue_status')),nil)
-- A loss 10 tiles away joins the raid; its running total comes at most once a game minute (shift 5: every growth
-- was a new line).
runtime.on_event{name=11,tick=tick,entity={valid=true,name='inserter',position={x=205,y=-80},force={name='player'}}}
eq(loss_line(call('queue_status')),nil)
tick=tick+3600; game.tick=tick
local grown=loss_line(call('queue_status'))
assert(grown:find(' in (200,-90)-(209,-80) continue: 81 destroyed (+1 since you were told): ',1,true),grown)
eq(loss_line(call('queue_status')),nil)
-- A cell quiet for 5 minutes, or a new shift, starts a new incident; the old
-- one stays in status alerts with since (shake5: a raid total grew across two shifts).
;(function()
  local start=tick-3600 -- the furnace and the raid, before the minute waited above
  tick=tick+5*3600+1; game.tick=tick
  runtime.on_event{name=11,tick=tick,entity={valid=true,name='inserter',position={x=206,y=-80},force={name='player'}}}
  local line=loss_line(call('queue_status'))
  assert(line:find('^losses #%d+ in %(206,%-80%) 1 destroyed: 1 inserter'),line)
  local closed=runtime.operator.shift_start(); eq(closed.ok,true); eq(closed.incidents_closed,3)
  runtime.on_event{name=11,tick=tick,entity={valid=true,name='inserter',position={x=207,y=-80},force={name='player'}}}
  line=loss_line(call('queue_status'))
  assert(line:find(' in (207,-80) 1 destroyed',1,true),line)
  local history=call('status',{since=start-1}).alerts
  eq(#history.latest,4); eq(history.losses.inserter,3); eq(history.losses['transport-belt'],64)
  eq(#call('status').alerts.latest,2) -- the last 5 minutes: the two new incidents
end)()
-- Past 64 incidents the oldest is dropped. The new incident must have its tick before that comparison (shake10:
-- a long world reached 64, every loss in a new area failed in the tick and quarantined the runtime for 80 minutes).
;(function()
  for i=1,70 do runtime.on_event{name=11,tick=tick,entity={valid=true,name='wall',position={x=5000+i*64,y=5000},force={name='player'}}} end
  local alerts=call('status',{since=0}).alerts
  assert(alerts and alerts.losses,'status alerts after 70 new areas')
  eq(#storage.agent_harness.losses,64)
  for _,i in ipairs(storage.agent_harness.losses) do assert(i.last,'every incident has its last tick') end
  -- A save from before the fix may hold an incident without `last`: it must not break the tick or status.
  storage.agent_harness.losses[1].last=nil
  runtime.on_event{name=11,tick=tick,entity={valid=true,name='wall',position={x=9000,y=9000},force={name='player'}}}
  assert(call('status',{since=0}).alerts.losses,'status alerts with a pre-fix incident')
end)()
-- Hits in the last 10 s lead status warnings, with where and by what.
defines.events.on_entity_damaged=12
runtime.on_event{name=12,tick=tick,entity={valid=true,name='gun-turret',position={x=40,y=40},force={name='player'}},force={name='enemy'},cause={valid=true,name='small-biter'},final_damage_amount=5}
local attacked=call('status').warnings[1]
assert(attacked:find('under attack near (48,48): gun-turret x1 hit 1 times by small-biter, 0s ago',1,true),attacked)
tick=tick+601; game.tick=tick; eq(call('status').warnings,nil)
call('queue_submit',{steps={{action='walk',args={direction='east',ticks=10}}}})
advance(1)
game.take_screenshot=function() end
call('screenshot',{path='queue.png'})
eq(call('queue_status').paused,false); eq(call('status').active.kind,'walk')
call('queue_cancel',{})
call('queue_submit',{steps={{action='move_to',args={position={x=2,y=0},pathfind=false}},{action='walk',args={direction='north',ticks=10}}}})
advance(1); eq(call('queue_status').active.action,'move_to')
eq(#call('queue_status').pending,1)
p.position={x=2,y=0}; advance(1)
eq(call('queue_status').active.action,'walk')
call('queue_cancel',{}); p.position={x=0,y=0}
-- A plan submitted during a direct walk waits for it instead of acting mid-walk.
call('walk',{direction='east',ticks=3})
call('queue_submit',{steps={{action='walk',args={direction='north',ticks=3}}}})
advance(1); eq(call('queue_status').after_direct,'walk'); eq(#call('queue_status').pending,1); eq(p.walking_state.direction,4)
advance(3); eq(call('queue_status').after_direct,nil); eq(call('status').active.direction,0)
-- A plan step's own timed action (wait=false) does not hold up the next step.
call('queue_cancel',{})
call('queue_submit',{steps={{action='walk',args={direction='east',ticks=30},wait=false},{action='wait_ticks',args={ticks=5}}}})
advance(1); eq(call('queue_status').active.action,'wait_ticks'); eq(call('status').active.kind,'walk')
call('queue_cancel',{})
-- status names a paused plan that still holds steps, and why it stopped.
call('queue_submit',{steps={{action='rotate',args={position={x=1,y=0}}},{action='walk',args={direction='north',ticks=3},label='after'}}})
advance(1)
local paused_warning=call('status').warnings[1]
assert(paused_warning:find('queue: paused with 1 pending step (first: job-',1,true),paused_warning)
assert(paused_warning:find(' walk [after]); paused when job-',1,true),paused_warning)
assert(paused_warning:find(' rotate failed: entity not found at (1,0): nothing within 3 tiles; target an',1,true),paused_warning)
assert(paused_warning:find('radius=3); queue resume runs them',1,true),paused_warning)
assert(call('queue_status').last_failure.result.reason:find('entity not found at (1,0)',1,true))
call('queue_cancel',{})
eq(call('status').warnings,nil)
fails(function() call('walk',{direction='east',ticks=601}) end,'ticks out of range')
p.cheat_mode=true; fails(function() call('walk',{direction='east'}) end,'cheat mode'); p.cheat_mode=false
call('walk',{direction='north',ticks=10}); p.connected=false; advance(1)
eq(storage.agent_harness.active[1],nil); eq(p.walking_state.walking,false); p.connected=true
p.character.prototype.mining_speed=0.5; p.force.manual_mining_speed_modifier=0
local ore={valid=true,name='iron-ore',type='resource',position={x=1,y=0},force={name='neutral'},minable=true,amount=3,
  prototype={mineable_properties={mining_time=1,products={{type='item',name='iron-ore'}}}}}
local room=true
p.can_insert=function(item) return room or item.name~='iron-ore' end
p.surface.find_entities_filtered=function() return {ore} end
-- Resources yield one unit per hand-mining cycle (mining_time 1 at speed 0.5 is 120 ticks) through
-- mine_entity, which returns false while ore remains, so success is judged by the amount.
p.mine_entity=function(e) e.amount=e.amount-1; if e.amount==0 then e.valid=false end; return false end
call('mine',{position=ore.position,ticks=600})
eq(call('status').active.target.name,'iron-ore')
advance(119); eq(ore.amount,3); advance(1); eq(ore.amount,2)
advance(120); eq(ore.amount,1)
advance(120); eq(ore.valid,false)
local last=call('status').last; eq(last.outcome,'target_mined'); eq(last.mined,3)
-- Resource mining idles silently when the product has no room; say so.
ore.valid=true; ore.amount=5; call('mine',{position=ore.position,ticks=10}); advance(1); room=false; advance(1)
last=call('status').last; eq(last.outcome,'inventory_full'); eq(last.blocked_item,'iron-ore'); room=true
-- Space Age hard-solid ore: the character's resource categories decide, before anything stops.
p.character.prototype.resource_categories={['basic-solid']=true}
ore.prototype.resource_category='hard-solid'; ore.name='tungsten-ore'
fails(function() call('mine',{position=ore.position,ticks=10}) end,'tungsten-ore is hard-solid: a character cannot mine it by hand')
ore.prototype.resource_category='basic-solid'; ore.name='iron-ore'
call('mine',{position=ore.position,ticks=1}); advance(2)
p.character.prototype.resource_categories=nil; ore.prototype.resource_category=nil
-- Non-resources wait out the hand-mining time, then mine once through the engine.
p.character.prototype.mining_speed=0.5; p.force.manual_mining_speed_modifier=0
local tree={valid=true,name='tree-01',type='tree',position={x=1,y=1},force={name='neutral'},minable=true,
  prototype={mineable_properties={mining_time=0.5,products={{type='item',name='wood'}}}}}
p.surface.find_entities_filtered=function() return {tree} end
local mined={}
p.mine_entity=function(e,force) mined[#mined+1]=force; return true end
local started=call('mine',{position=tree.position,ticks=1}).until_tick
eq(started,tick+60) -- extended to the 60 tick hand-mining time
advance(59); eq(#mined,0); eq(call('status').active.kind,'mine')
advance(1); eq(mined[1],false); eq(call('status').last.outcome,'target_mined')
-- A timed target that vanishes early was not mined by the character.
call('mine',{position=tree.position}); tree.valid=false; advance(1)
eq(call('status').last.outcome,'target_lost'); eq(#mined,1); tree.valid=true
-- The engine refusing with room left means the entity is not hand-minable
-- (a stump, remnant); with no room it is inventory_full.
p.mine_entity=function() return false end
call('mine',{position=tree.position}); advance(60)
eq(call('status').last.outcome,'not_minable'); eq(call('status').active,false)
assert(call('status').last.error:find('refused to mine tree-01',1,true))
local can_insert=p.can_insert; p.can_insert=function() return false end
call('mine',{position=tree.position}); advance(60)
eq(call('status').last.outcome,'inventory_full'); eq(call('status').last.blocked_item,'wood')
p.can_insert=can_insert
-- Building must return the borrowed stack after a rejected placement.
local function stack(name,count)
  local s={name=name,count=count,valid_for_read=count>0,quality={name='normal'},prototype={place_result={type='container'}}}
  s.swap_stack=function(other)
    s.name,other.name=other.name,s.name
    s.count,other.count=other.count,s.count
    s.valid_for_read,other.valid_for_read=other.valid_for_read,s.valid_for_read
    return true
  end
  s.transfer_stack=function(other,amount)
    if s.valid_for_read and s.name~=other.name then return false end
    local moved=math.min(amount,other.count,100-s.count)
    s.name=other.name; s.count=s.count+moved; s.valid_for_read=s.count>0
    other.count=other.count-moved; other.valid_for_read=other.count>0
    return moved==amount
  end
  return s
end
local wood=stack('wooden-chest',3); local main={wood}
main.find_item_stack=function() return wood end
main.get_item_count=function(f) local n=0; for _,s in ipairs(main) do if s.valid_for_read and s.name==f.name then n=n+s.count end end; return n end
p.get_main_inventory=function() return main end
p.cursor_stack=stack(nil,0); p.build_distance=10
p.can_build_from_cursor=function() return false end
-- A refused placement says what is in the footprint: a tree (clearable by
-- ghosts+construct), the character itself, or water tiles; else a hint.
local footprint,tiles={},{}
p.surface.find_entities_filtered=function(a) return a.area and footprint or {} end
p.surface.find_tiles_filtered=function() return tiles end
footprint={{valid=true,type='tree',name='tree-02',position={x=2.1,y=0.3}},p.character}
p.character.type='character'; p.character.position={x=2,y=0}
fails(function() call('build',{item='wooden-chest',position={x=2,y=0}}) end,
  'placement blocked by tree-02 (2.1,0.3), the character standing on the footprint (move off it first); mine it, or place_ghosts (marks it) + construct (clears it)')
-- Someone else's character is named.
footprint={{valid=true,type='character',name='character',position={x=2,y=0.2},player={valid=true,name='pog-sol'}}}
fails(function() call('build',{item='wooden-chest',position={x=2,y=0}}) end,
  "placement blocked by pog-sol's character standing at (2.0,0.2) (ask them to move, or build elsewhere)")
p.character.type=nil; p.character.position=nil
eq(wood.count,3); eq(p.cursor_stack.valid_for_read,false)
footprint={}; tiles={{name='water',prototype={collision_mask={layers={water_tile=true}}}},{name='water',prototype={collision_mask={layers={water_tile=true}}}}}
fails(function() call('build',{item='wooden-chest',position={x=2,y=0}}) end,'placement blocked by tiles: water (needs landfill')
tiles={{name='grass-1',prototype={collision_mask={layers={ground_tile=true}}}}}
fails(function() call('build',{item='wooden-chest',position={x=2,y=0}}) end,'placement blocked (nothing found in the footprint')
p.surface.find_tiles_filtered=nil
p.can_build_from_cursor=function() return true end
local placed
p.surface.find_entities_filtered=function() return placed and {placed} or {} end
p.build_from_cursor=function()
  p.cursor_stack.count=p.cursor_stack.count-1
  placed={valid=true,name='wooden-chest',type='container',position={x=2.5,y=0.5},force=p.force}
end
fails(function() call('build',{item='wooden-chest',position={x=20,y=0}}) end,'position is out of build reach: (20,0) is 20.0 tiles from the character at (0.0,0.0), build reach 10')
fails(function() call('build',{item='wooden-chest',position={x=40,y=0}}) end,'position is outside local visible area: (40,0) is 40.0 tiles from the character')
local built=call('build',{item='wooden-chest',position={x=2,y=0}})
eq(built.consumed,1); eq(built.entity.position.x,2.5); eq(built.entity.position.y,0.5)
eq(wood.count,2); eq(p.cursor_stack.valid_for_read,false)
-- Batches share defaults, return placed positions, and fail at the first failure
-- (so plan on_fail policies see it); earlier entries stay built.
local build_single,single_placed=p.build_from_cursor,placed
p.build_from_cursor=function(args)
  p.cursor_stack.count=p.cursor_stack.count-1
  placed={valid=true,name='wooden-chest',type='container',position={x=args.position.x+.5,y=.5},force=p.force}
end
p.can_build_from_cursor=function(args) return args.position.x~=8 end
wood.count=5
fails(function() call('build',{item='wooden-chest',builds={{position={x=4,y=0}},{position={x=6,y=0}},{position={x=8,y=0}},{position={x=9,y=0}}}}) end,
  'build 3/4 failed after 2 built: placement blocked')
eq(wood.count,3); eq(p.cursor_stack.valid_for_read,false)
-- skip_failed lists the blocked entry and builds the rest (shake3: Grok, Astra).
wood.count=5
local skipped=call('build',{item='wooden-chest',skip_failed=true,builds={{position={x=4,y=0}},{position={x=8,y=0}},{position={x=9,y=0}}}})
eq(skipped.built,2); eq(skipped.placed[2].x,9.5); eq(#skipped.failed,1); eq(skipped.failed[1].index,2); eq(skipped.failed[1].position.x,8)
assert(skipped.failed[1].error:find('placement blocked',1,true),skipped.failed[1].error); eq(wood.count,3)
wood.count=3
-- The engine refills the hand from inventory after the last item; that still counts as consumed.
local spare=stack('wooden-chest',4); main[2]=spare
p.build_from_cursor=function(args)
  p.cursor_stack.count=p.cursor_stack.count-1
  if p.cursor_stack.count==0 then p.cursor_stack.count=1; spare.count=spare.count-1 end
  placed={valid=true,name='wooden-chest',type='container',position={x=args.position.x+.5,y=.5},force=p.force}
end
wood.count=1; eq(call('build',{item='wooden-chest',position={x=7,y=0}}).consumed,1); eq(spare.count+wood.count,4)
main[2]=nil
p.build_from_cursor=build_single; p.can_build_from_cursor=function() return true end; wood.count=2; placed=single_placed
-- Building on the same entity must not invoke native rotation/no-op placement.
wood.prototype.place_result.name='wooden-chest'
fails(function()call('build',{item='wooden-chest',position={x=2.5,y=.5},direction='east'})end,'target already contains')
eq(wood.count,2); eq(p.cursor_stack.valid_for_read,false)
wood.prototype.place_result.type='transport-belt';wood.prototype.place_result.name='wooden-chest'
fails(function()call('build',{item='wooden-chest',position={x=2,y=0},direction='east'})end,'target already contains')
eq(wood.count,2);eq(p.cursor_stack.valid_for_read,false)
wood.prototype.place_result.type='container'
wood.prototype.place_result.name=nil
-- Factorio reports false when swapping two empty stacks after the last item.
wood.count=1
local swap=p.cursor_stack.swap_stack
p.cursor_stack.swap_stack=function(other)
  if not p.cursor_stack.valid_for_read and not other.valid_for_read then return false end
  return swap(other)
end
p.build_from_cursor=function() p.cursor_stack.count=0; p.cursor_stack.valid_for_read=false end
eq(call('build',{item='wooden-chest',position={x=2,y=0}}).consumed,1)
eq(p.cursor_stack.valid_for_read,false)
-- While the game is tick-paused (turn mode between actions) the engine refuses
-- every cursor build, so build places directly and never touches the cursor.
wood.count=2; wood.valid_for_read=true; wood.prototype.place_result.name='wooden-chest'
wood.clear=function() wood.count=0; wood.valid_for_read=false end
game.tick_paused=true
p.can_build_from_cursor=function() error('cursor building must not be used while paused') end
p.build_from_cursor=p.can_build_from_cursor
defines.build_check_type=defines.build_check_type or {manual=1}
p.surface.find_entities_filtered=function(f) if f.ghost_name or f.area then return {} end return placed and {placed} or {} end
local paused_created
p.surface.can_place_entity=function(a) eq(a.build_check_type,defines.build_check_type.manual); return a.position.x~=9 end
p.surface.create_entity=function(a) eq(a.player,p); paused_created={valid=true,name=a.name,type='container',position=a.position,force=p.force}; return paused_created end
local paused_build=call('build',{item='wooden-chest',position={x=8,y=0}})
eq(paused_build.consumed,1); eq(paused_build.entity.position.x,8); eq(wood.count,1); eq(p.cursor_stack.valid_for_read,false)
fails(function() call('build',{item='wooden-chest',position={x=9,y=0}}) end,'placement blocked')
eq(wood.count,1)
game.tick_paused=false; p.surface.can_place_entity=nil; p.surface.create_entity=nil
wood.prototype.place_result.name=nil; wood.count=1
p.build_from_cursor=function() p.cursor_stack.count=0; p.cursor_stack.valid_for_read=false end
p.can_build_from_cursor=function() return true end
-- transfer_stack amount must preserve exact requested counts and metadata path.
local input=stack('iron-plate',20); main={input}
local output=stack(nil,0)
local chest={valid=true,name='wooden-chest',type='container',position={x=1,y=0},force=p.force}
chest.get_inventory=function() return setmetatable({output,valid=true},{}) end
p.surface.find_entities_filtered=function() return {chest} end
local result=call('transfer',{position=chest.position,inventory='chest',item='iron-plate',count=7,direction='to_entity'})
eq(result.transferred,7); eq(input.count,13); eq(output.count,7)
eq(flying[#flying],'-7 [item=iron-plate]')
-- A put by hand is a haul for the agent's own hour (selfview.lua my_hour).
do
  local h=storage.agent_harness.selfview[p.index].hauls
  eq(h[#h].item,'iron-plate'); eq(h[#h].name,'wooden-chest'); eq(h[#h].to.x,1); eq(h[#h].items,7)
end
-- Request #69: a slot that takes more than asked (the engine merging a
-- stack) must not drive the next call's amount below 1, which the engine
-- refuses ("Given amount value(-1) too small"); up_to already met moves 0.
do
  local src=stack('firearm-magazine',60); main={src}
  main.get_item_count=function(f) return src.valid_for_read and src.name==f.name and src.count or 0 end
  local greedy=stack('firearm-magazine',5)
  local plain=stack('firearm-magazine',5)
  greedy.transfer_stack=function(other,amount)
    assert(amount>=1,'Given amount value('..amount..') too small')
    local moved=math.min(other.count,amount+3) -- takes more than asked
    greedy.count=greedy.count+moved; other.count=other.count-moved; other.valid_for_read=other.count>0
    return true
  end
  local inner=plain.transfer_stack
  plain.transfer_stack=function(other,amount) assert(amount>=1,'Given amount value('..amount..') too small'); return inner(other,amount) end
  local box={valid=true,name='wooden-chest',type='container',position={x=1,y=0},force=p.force}
  local slots={greedy,plain,valid=true}
  slots.get_item_count=function(f) local n=0; for _,s in ipairs(slots) do if s.valid_for_read and s.name==f.name then n=n+s.count end end; return n end
  box.get_inventory=function() return slots end
  p.surface.find_entities_filtered=function() return {box} end
  local r=call('transfer',{position=box.position,inventory='chest',item='firearm-magazine',count=2,direction='to_entity'})
  eq(r.transferred,5) -- what the engine moved, reported as moved
  r=call('transfer',{position=box.position,inventory='chest',item='firearm-magazine',count=50,keep=20,up_to=10,direction='to_entity'})
  eq(r.transferred,0); eq(r.at_up_to,true)
  r=call('transfer',{position=box.position,inventory='chest',item='firearm-magazine',count=50,keep=60,direction='to_entity'})
  eq(r.transferred,0)
  -- Request #124: a silo with automatic requests on takes no cargo by hand;
  -- the refusal names the setting and how to turn it off.
  defines.inventory.rocket_silo_rocket=defines.inventory.rocket_silo_rocket or 21
  local cargo=stack(nil,0)
  cargo.transfer_stack=function() return false end -- the engine refuses
  local held={cargo,valid=true}
  held.get_item_count=function() return 0 end
  local silo={valid=true,name='rocket-silo',type='rocket-silo',position={x=1,y=0},force=p.force,use_transitional_requests=true}
  silo.get_inventory=function() return held end
  p.surface.find_entities_filtered=function() return {silo} end
  r=call('transfer',{position=silo.position,inventory='rocket_silo_rocket',item='firearm-magazine',count=10,direction='to_entity'})
  eq(r.transferred,0); eq(r.entity_full.auto_requests,true)
  assert(r.entity_full.note:find('auto_requests=false',1,true),r.entity_full.note)
  silo.use_transitional_requests=false
  r=call('transfer',{position=silo.position,inventory='rocket_silo_rocket',item='firearm-magazine',count=10,direction='to_entity'})
  eq(r.entity_full.auto_requests,nil)
  -- Coverage: a module goes into a machine's module slots with no inventory
  -- named (the item's kind picks them), as a player's click does; a beacon too.
  local saved_prototypes=prototypes
  prototypes=prototypes or {}; prototypes.item=prototypes.item or {}
  prototypes.item['speed-module']={name='speed-module',type='module'}
  defines.inventory.assembling_machine_modules=defines.inventory.assembling_machine_modules or 31
  defines.inventory.beacon_modules=defines.inventory.beacon_modules or 32
  local mod_src=stack('speed-module',4); main={mod_src}
  main.get_item_count=function(f) return mod_src.valid_for_read and mod_src.name==f.name and mod_src.count or 0 end
  local function machine(type_,inv_id)
    local slots={stack(nil,0),stack(nil,0),valid=true}
    slots.get_item_count=function(f) local n=0; for _,s2 in ipairs(slots) do if s2.valid_for_read and s2.name==f.name then n=n+s2.count end end; return n end
    slots.can_insert=function() return true end
    local m={valid=true,name=type_,type=type_,position={x=1,y=0},force=p.force,slots=slots}
    m.get_inventory=function(id) if id==inv_id then return slots end end
    return m
  end
  local asm=machine('assembling-machine',defines.inventory.assembling_machine_modules)
  p.surface.find_entities_filtered=function() return {asm} end
  r=call('transfer',{position=asm.position,item='speed-module',count=2,direction='to_entity'})
  eq(r.transferred,2); eq(r.inventory,'assembling_machine_modules'); eq(asm.slots[1].name,'speed-module')
  local beacon=machine('beacon',defines.inventory.beacon_modules)
  p.surface.find_entities_filtered=function() return {beacon} end
  r=call('transfer',{position=beacon.position,item='speed-module',count=2,direction='to_entity'})
  eq(r.transferred,2); eq(r.inventory,'beacon_modules')
  -- Inspect gives the module inventory's index (blueprint item requests name it).
  asm.slots.index=4
  asm.slots.get_contents=function() return {{name='speed-module',count=2,quality='normal'}} end
  asm.get_module_inventory=function() return asm.slots end
  asm.get_fluid_contents=function() return {} end
  asm.get_recipe=function() return nil end
  p.surface.find_entities_filtered=function() return {asm} end
  local mods=call('inspect',{position=asm.position}).modules
  eq(mods.inventory_index,4); eq(mods.slots,2); eq(mods.contents[1].name,'speed-module'); eq(mods.contents[1].count,2)
  asm.get_module_inventory=function() return nil end
  eq(call('inspect',{position=asm.position}).modules,nil)
  prototypes=saved_prototypes
  main={input}
end
-- Omitted items take everything from the inferred output inventory; batches
-- report each entity and keep going past one that fails.
local function inv(...)
  local t={...}; t.valid=true
  t.get_item_count=function(f) local n=0; for _,s in ipairs(t) do if s.valid_for_read and s.name==f.name then n=n+s.count end end; return n end
  return t
end
defines.inventory.fuel,defines.inventory.furnace_source,defines.inventory.furnace_result=2,3,4
local function furnace(x,result)
  local slots={[2]=inv(stack('coal',2)),[3]=inv(stack(nil,0)),[4]=inv(result)}
  local f={valid=true,name='stone-furnace',type='furnace',position={x=x,y=0},force=p.force,slots=slots}
  f.get_inventory=function(i) return slots[i] end
  f.get_fuel_inventory=function() return slots[2] end
  return f
end
local f1,f2=furnace(3,stack('iron-plate',5)),furnace(4,stack('copper-plate',3))
p.surface.find_entities_filtered=function(f) return {f.position.x==3 and f1 or f2} end
main=inv(stack(nil,0),stack(nil,0),stack(nil,0))
local batch=call('transfer',{positions={{x=3,y=0},{x=4,y=0},{x=40,y=0}},direction='to_player'})
eq(batch.transferred,8); eq(batch.items[1].name,'iron-plate'); eq(batch.items[2].count,3)
eq(batch.entities[2].transferred,3); assert(batch.entities[3].error:find('outside local visible area'))
eq(f1.slots[2][1].count,2); eq(main[1].count,5); eq(flying[#flying],'+3 [item=copper-plate]')
prototypes={item={coal={fuel_value=4000000},['iron-ore']={fuel_value=0}}}
main=inv(stack('coal',10),stack('iron-ore',10))
local fuel=call('transfer',{position={x=3,y=0},item='coal',count=4,direction='to_entity'})
eq(fuel.inventory,'fuel'); eq(f1.slots[2][1].count,6)
eq(call('transfer',{position={x=3,y=0},item='iron-ore',count=4,direction='to_entity'}).inventory,'furnace_source')
eq(f1.slots[3][1].count,4)
eq(call('transfer',{position={x=3,y=0},item='coal',count=6,direction='to_player'}).inventory,'fuel')
eq(main[1].count,12); eq(f1.slots[2][1].valid_for_read,false)
fails(function() call('transfer',{position={x=3,y=0},direction='to_entity'}) end,'item is required')
fails(function() call('transfer',{positions={{x=3,y=0}},unit_number=7,direction='to_player'}) end,'unit_number per entry')
-- An omitted direction follows where the item is; held on both sides it must be given.
fails(function() call('transfer',{position={x=3,y=0},item='iron-ore',count=2}) end,'direction is required (to_entity|to_player): the character holds 6 iron-ore and the target holds 4')
local given_coal=call('transfer',{position={x=3,y=0},item='coal',count=2})
eq(given_coal.direction,'to_entity'); eq(given_coal.inventory,'fuel'); eq(f1.slots[2][1].count,2); eq(main[1].count,10)
local kept_main=main
main=inv(stack(nil,0),stack(nil,0))
local taken_ore=call('transfer',{position={x=3,y=0},item='iron-ore',count=4})
eq(taken_ore.direction,'to_player'); eq(taken_ore.transferred,4); eq(main[1].name,'iron-ore')
eq(call('transfer',{position={x=3,y=0}}).direction,'to_player')
fails(function() call('transfer',{position={x=3,y=0},item='iron-plate'}) end,'holds 0 iron-plate and the target holds 0')
fails(function() call('transfer',{position={x=3,y=0},item='coal',direction='sideways'}) end,'direction must be to_entity or to_player')
main=kept_main; main[1].count=12; f1.slots[2][1].count,f1.slots[2][1].valid_for_read=0,false
-- Courier tools (shift08: Grok, Luna, Sonnet, Muse). up_to=true moves what there is and says how short it fell; a
-- short or empty source is never an error.
do
  local saved_main,saved_find,saved_prototypes=main,p.surface.find_entities_filtered,prototypes
  main=inv(stack('iron-ore',3),stack(nil,0),stack(nil,0))
  f1.slots[3][1].count,f1.slots[3][1].valid_for_read=0,false
  p.surface.find_entities_filtered=function(f) return {f.position.x==3 and f1 or f2} end
  local r=call('transfer',{position={x=3,y=0},item='iron-ore',count=5,direction='to_entity',up_to=true})
  eq(r.moved,3); eq(r.short.asked,5); eq(r.short.moved,3); eq(r.short.reason,'source_short'); eq(f1.slots[3][1].count,3)
  r=call('transfer',{position={x=3,y=0},item='iron-ore',count=5,direction='to_entity',up_to=true})
  eq(r.moved,0); eq(r.short.reason,'none_held')
  fails(function() call('transfer',{position={x=3,y=0},item='iron-ore',count=5,direction='to_entity'}) end,'no iron-ore in inventory')
  -- Enough held: no short.
  main=inv(stack('iron-ore',10),stack(nil,0))
  r=call('transfer',{position={x=3,y=0},item='iron-ore',count=2,direction='to_entity',up_to=true})
  eq(r.moved,2); eq(r.short,nil)
  -- Taking: fewer in the source than asked, then none at all; the direction inferred works too.
  main=inv(stack(nil,0),stack(nil,0))
  r=call('transfer',{position={x=3,y=0},item='iron-ore',count=50,direction='to_player',up_to=true})
  eq(r.moved,5); eq(r.short.asked,50); eq(r.short.reason,'source_short')
  r=call('transfer',{position={x=3,y=0},item='iron-ore',count=50,direction='to_player',up_to=true})
  eq(r.moved,0); eq(r.short.reason,'source_empty')
  -- A batch: asked per entity, summed.
  main=inv(stack('iron-ore',3),stack(nil,0))
  r=call('transfer',{positions={{x=3,y=0},{x=4,y=0}},item='iron-ore',count=2,direction='to_entity',up_to=true})
  eq(r.moved,3); eq(r.short.asked,4); eq(r.short.reason,'source_short')
  -- No direction and the item on neither side: a short too (without up_to it stays an error).
  main=inv(stack(nil,0),stack(nil,0))
  r=call('transfer',{position={x=3,y=0},item='copper-plate',count=4,up_to=true})
  eq(r.moved,0); eq(r.short.asked,4); eq(r.short.reason,'none_held')
  fails(function() call('transfer',{position={x=3,y=0},item='copper-plate',count=4}) end,'direction is required')
  -- A number keeps its meaning (the target cap); anything else is refused.
  fails(function() call('transfer',{position={x=3,y=0},item='iron-ore',up_to='yes',direction='to_entity'}) end,'up_to must be a number')
  -- collect up_to: an empty source is a short, not a failure.
  f2.slots[4][1].count,f2.slots[4][1].valid_for_read=0,false
  f1.slots[4][1].count,f1.slots[4][1].valid_for_read=0,false
  main=inv(stack(nil,0),stack(nil,0))
  r=call('collect',{positions={{x=4,y=0}},up_to=true})
  eq(r.moved,0); eq(r.short.asked,'all'); eq(r.short.reason,'source_empty')
  fails(function() call('collect',{up_to=5}) end,'up_to must be true')

  -- feed with a recipe over a machine list: each ingredient for N crafts per machine, one call; loaded and short per
  -- machine; a machine set to another recipe is listed as such.
  defines.inventory.assembling_machine_input=defines.inventory.assembling_machine_input or 5
  prototypes={item={inserter={},['transport-belt']={}},recipe={['logistic-science-pack']={name='logistic-science-pack',
    ingredients={{type='item',name='inserter',amount=1},{type='item',name='transport-belt',amount=1}}},
    ['iron-gear-wheel']={name='iron-gear-wheel',ingredients={{type='item',name='iron-plate',amount=2}}}}}
  local function assembler(x,recipe)
    local slots=inv(stack(nil,0),stack(nil,0))
    local m={valid=true,name='assembling-machine-2',type='assembling-machine',position={x=x,y=5},force=p.force,slots=slots}
    m.get_inventory=function(id) if id==defines.inventory.assembling_machine_input then return slots end end
    m.get_recipe=function() return recipe and {name=recipe} or nil end
    return m
  end
  local a1,a2,a3=assembler(1,'logistic-science-pack'),assembler(2,'logistic-science-pack'),assembler(3,'iron-gear-wheel')
  local machines={[1]=a1,[2]=a2,[3]=a3}
  p.surface.find_entities_filtered=function(f) return {machines[f.position and f.position.x]} end
  main=inv(stack('inserter',15),stack('transport-belt',30))
  r=call('feed',{recipe='logistic-science-pack',crafts=10,positions={{x=1,y=5},{x=2,y=5},{x=3,y=5}}})
  eq(r.entities[1].loaded.inserter,10); eq(r.entities[1].loaded['transport-belt'],10); eq(r.entities[1].short,nil)
  eq(r.entities[2].loaded.inserter,5); eq(r.entities[2].short.inserter,5); eq(r.entities[2].short['transport-belt'],nil)
  eq(r.entities[3].recipe,'iron-gear-wheel'); eq(r.entities[3].loaded,nil)
  eq(r.transferred,35); eq(r.held.inserter,0); eq(r.held['transport-belt'],10)
  -- Again: topped up to the crafts asked, so the first takes nothing more; the second still lacks inserters.
  main=inv(stack('inserter',2),stack('transport-belt',2))
  r=call('feed',{recipe='logistic-science-pack',crafts=10,positions={{x=1,y=5},{x=2,y=5}}})
  eq(r.entities[1].loaded,nil); eq(r.entities[1].short,nil)
  eq(r.entities[2].loaded.inserter,2); eq(r.entities[2].short.inserter,3)
  fails(function() call('feed',{recipe='nope',positions={{x=1,y=5}}}) end,'unknown recipe nope')
  fails(function() call('feed',{crafts=2,positions={{x=1,y=5}}}) end,'crafts goes with recipe')
  fails(function() call('feed',{recipe='logistic-science-pack',items={'inserter'},positions={{x=1,y=5}}}) end,'recipe or items')
  fails(function() call('feed',{recipe='logistic-science-pack',item='inserter',positions={{x=1,y=5}}}) end,'recipe or items (or item)')

  -- inspect over positions: one call, results in order; a miss is its position and error.
  a1.get_fluid_contents=function() return {} end; a2.get_fluid_contents=a1.get_fluid_contents
  for _,m in ipairs({a1,a2}) do m.slots.get_contents=function() return {} end end
  local batch=call('inspect',{positions={{x=1,y=5},{x=2,y=5},{x=40,y=5}}})
  eq(batch.count,3); eq(batch.entities[1].name,'assembling-machine-2'); eq(batch.entities[2].position.x,2)
  eq(batch.entities[3].position.x,40); assert(batch.entities[3].error,'a miss carries its error')
  -- Both at once run as one list, position first (Muse, shift08).
  local both=call('inspect',{position={x=1,y=5},positions={{x=2,y=5}}})
  eq(both.count,2); eq(both.entities[1].position.x,1); assert(both.corrected:find('position and positions are one list',1,true),both.corrected)
  main,p.surface.find_entities_filtered,prototypes=saved_main,saved_find,saved_prototypes
  for _,f in ipairs({f1,f2}) do f.slots[3][1].count,f.slots[3][1].valid_for_read=0,false end
end
-- A silo takes rocket parts' ingredients as input and anything else as rocket cargo.
defines.inventory.assembling_machine_input,defines.inventory.rocket_silo_rocket=5,7
local silo_input,silo_cargo=inv(stack(nil,0)),inv(stack(nil,0))
silo_input.can_insert=function(it) return it.name=='rocket-fuel' end
silo_cargo.can_insert=function() return true end
local silo={valid=true,name='rocket-silo',type='rocket-silo',position={x=3,y=0},force=p.force}
silo.get_inventory=function(i) return ({[5]=silo_input,[7]=silo_cargo})[i] end
silo.get_fuel_inventory=function() return nil end
local find_before=p.surface.find_entities_filtered
p.surface.find_entities_filtered=function() return {silo} end
prototypes.item['space-platform-starter-pack']={fuel_value=0}; prototypes.item['rocket-fuel']={fuel_value=100}
main=inv(stack('space-platform-starter-pack',1),stack('rocket-fuel',5))
eq(call('transfer',{position={x=3,y=0},item='space-platform-starter-pack'}).inventory,'rocket_silo_rocket'); eq(silo_cargo[1].count,1)
eq(call('transfer',{position={x=3,y=0},item='rocket-fuel',count=5,direction='to_entity'}).inventory,'assembling_machine_input'); eq(silo_input[1].count,5)
-- A silo's trash slots, where the game puts cargo loaded by hand once automatic
-- requests are on: inspect lists them; transfer takes them, named or all; nothing goes in.
do
  defines.inventory.rocket_silo_trash=9
  local function listing(t)
    t.get_contents=function() local out={}; for _,s in ipairs(t) do if s.valid_for_read then out[#out+1]={name=s.name,count=s.count,quality='normal'} end end; return out end
    t.is_empty=function() return #t.get_contents()==0 end
    return t
  end
  local silo_trash=listing(inv(stack('space-platform-foundation',40),stack('solar-panel',7),stack('inserter',1)))
  listing(silo_input); listing(silo_cargo)
  silo.get_inventory=function(i) return ({[5]=silo_input,[7]=silo_cargo,[9]=silo_trash})[i] end
  silo.get_fluid_contents=function() return {} end
  local seen=call('inspect',{position={x=3,y=0}})
  eq(seen.trash,'40 space-platform-foundation, 7 solar-panel, 1 inserter (in rocket_silo_trash, put there by the game; take: transfer {position, direction=to_player, inventory=rocket_silo_trash}, item= for one kind)')
  eq(seen.inventories.rocket_silo_trash[1].count,40)
  local kept=main
  main=inv(stack(nil,0),stack(nil,0),stack(nil,0),stack(nil,0))
  local took=call('transfer',{position={x=3,y=0},item='solar-panel'})
  eq(took.direction,'to_player'); eq(took.inventory,'rocket_silo_trash'); eq(took.transferred,7)
  took=call('transfer',{position={x=3,y=0},direction='to_player'})
  eq(took.inventory,'rocket_silo_trash'); eq(took.transferred,41); eq(main[2].name,'space-platform-foundation')
  eq(call('inspect',{position={x=3,y=0}}).trash,nil)
  -- Empty trash slots: taking everything uses the silo's own inventories.
  eq(call('transfer',{position={x=3,y=0},direction='to_player'}).inventory,'assembling_machine_input')
  fails(function() call('transfer',{position={x=3,y=0},item='solar-panel',inventory='rocket_silo_trash',direction='to_entity'}) end,'rocket_silo_trash is take-only (direction=to_player)')
  defines.inventory.rocket_silo_trash=nil; main=kept
end
-- A rocket lifts 1000 kg; the game takes more by script and then refuses the
-- launch (shift04 07:17: 1060 kg aboard). Only what fits goes in; inspect
-- shows the weight.
do
  local weights={['space-platform-foundation']=20000,['firearm-magazine']=10000,['gun-turret']=20000,['solar-panel']=20000}
  for name,w in pairs(weights) do prototypes.item[name]=prototypes.item[name] or {}; prototypes.item[name].weight=w end
  local cargo=inv(stack('space-platform-foundation',30),stack('firearm-magazine',28),stack('gun-turret',4),stack(nil,0))
  cargo.get_contents=function() local out={}; for _,s in ipairs(cargo) do if s.valid_for_read then out[#out+1]={name=s.name,count=s.count,quality='normal'} end end; return out end
  silo.get_inventory=function(i) return ({[5]=silo_input,[7]=cargo})[i] end
  eq(call('inspect',{position={x=3,y=0}}).rocket_weight,'960/1000 kg')
  local kept=main
  main=inv(stack('solar-panel',5))
  local r=call('transfer',{position={x=3,y=0},item='solar-panel',count=5,inventory='rocket_silo_rocket',direction='to_entity'})
  eq(r.transferred,2); eq(cargo[4].count,2); eq(main[1].count,3); eq(r.rocket_weight,'1000/1000 kg')
  eq(r.weight_limited.requested,5); eq(r.weight_limited.fits,2)
  eq(r.weight_limited.note,'a rocket lifts 1000 kg: 2 of 5 solar-panel (20 kg each) fit')
  fails(function() call('transfer',{position={x=3,y=0},item='solar-panel',count=1,inventory='rocket_silo_rocket',direction='to_entity'}) end,
    'the rocket is full by weight (1000/1000 kg of its lift): no solar-panel (20 kg each) fits')
  eq(main[1].count,3)
  -- Under the lift: no note.
  cargo[1].count=29
  r=call('transfer',{position={x=3,y=0},item='solar-panel',count=1,inventory='rocket_silo_rocket',direction='to_entity'})
  eq(r.transferred,1); eq(r.weight_limited,nil); eq(r.rocket_weight,'1000/1000 kg')
  for name in pairs(weights) do prototypes.item[name].weight=nil end
  main=kept
end
p.surface.find_entities_filtered=find_before; main=kept_main
-- Items merge into a partial stack of the same item before taking an empty slot.
main=inv(stack(nil,0),stack('coal',5))
f1.slots[2][1].count=3; f1.slots[2][1].valid_for_read=true
eq(call('transfer',{position={x=3,y=0},item='coal',count=3,direction='to_player'}).transferred,3)
eq(main[2].count,8); eq(main[1].valid_for_read,false)
-- total caps a batch, filled in order, and is echoed back.
main=inv(stack('coal',50))
local capped=call('transfer',{positions={{x=3,y=0},{x=4,y=0}},item='coal',count=5,total=7,inventory='fuel',direction='to_entity'})
eq(capped.transferred,7); eq(capped.total,7); eq(capped.entities[1].transferred,5); eq(capped.entities[2].transferred,2)
eq(call('transfer',{positions={{x=3,y=0},{x=4,y=0}},item='coal',total=3,inventory='fuel',direction='to_entity'}).entities[1].transferred,3)
fails(function() call('transfer',{positions={{x=3,y=0}},total=3,direction='to_player'}) end,'total requires item')
-- A full character inventory is named, not reported as a quiet partial move.
main=inv(stack('iron-plate',100))
f1.slots[4][1].name,f1.slots[4][1].count,f1.slots[4][1].valid_for_read='iron-plate',9,true
local full=call('transfer',{position={x=3,y=0},direction='to_player'}).inventory_full
eq(full.requested,9); eq(full.got,0); eq(full.blocked_item,'iron-plate')
local stuck=call('transfer',{positions={{x=3,y=0},{x=4,y=0}},direction='to_player'})
eq(stuck.inventory_full.blocked_item,'iron-plate'); eq(stuck.unchanged,1); eq(#stuck.entities,1)
f1.slots[4][1].count,f1.slots[4][1].valid_for_read=0,false; f2.slots[2][1].count=2
-- A recipe change returns contents and interrupted ingredients like a player's,
-- spilling what does not fit; held fluid needs force.
defines.inventory.assembling_machine_input,defines.inventory.assembling_machine_output=5,6
local plate_stack=stack('iron-plate',6)
local gear_stack=stack('iron-gear-wheel',3)
plate_stack.clear=function() plate_stack.count=0; plate_stack.valid_for_read=false end
gear_stack.clear=function() gear_stack.count=0; gear_stack.valid_for_read=false end
local current_recipe={name='iron-gear-wheel'}
local am={valid=true,name='assembling-machine-1',type='assembling-machine',position={x=3,y=0},force=p.force,fluidbox={},
  prototype={crafting_categories={crafting=true}}}
local am_slots={[5]=inv(plate_stack),[6]=inv(gear_stack)}
am.get_inventory=function(i) return am_slots[i] end
am.get_recipe=function() return current_recipe end
am.set_recipe=function(name) current_recipe={name=name}; return {{name='iron-plate',count=2,quality='normal'}} end
p.surface.find_entities_filtered=function() return {am} end
p.force.recipes={['iron-gear-wheel']={name='iron-gear-wheel',enabled=true,category='crafting'},
  ['copper-cable']={name='copper-cable',enabled=true,category='crafting'},
  ['sulfur']={name='sulfur',enabled=true,category='chemistry'}}
local given,spills={},{}
p.insert=function(item) given[#given+1]=item.name..':'..item.count; return item.name=='iron-gear-wheel' and 1 or item.count end
p.surface.spill_item_stack=function(args) spills[#spills+1]=args.stack.name..':'..args.stack.count end
eq(call('configure',{position=am.position,recipe='iron-gear-wheel'}).unchanged,true)
fails(function() call('configure',{position=am.position,recipe='sulfur'}) end,'incompatible')
local changed=call('configure',{position=am.position,recipe='copper-cable'})
eq(changed.recipe,'copper-cable'); eq(changed.returned['iron-plate'],8); eq(changed.returned['iron-gear-wheel'],3)
eq(changed.spilled['iron-gear-wheel'],2); eq(table.concat(spills,','),'iron-gear-wheel:2')
eq(plate_stack.valid_for_read,false); eq(gear_stack.valid_for_read,false)
am.fluidbox={{name='water',amount=10}}
fails(function() call('configure',{position=am.position,recipe='iron-gear-wheel'}) end,'force=true')
eq(call('configure',{position=am.position,recipe='iron-gear-wheel',force=true}).recipe,'iron-gear-wheel')
-- Out of reach, remote view changes an empty machine's recipe but not a stocked one's.
am.fluidbox={}
p.can_reach_entity=function() return false end
for _,slots in pairs(am_slots) do slots.is_empty=function() return not slots[1].valid_for_read end end
local remote_change=call('configure',{position=am.position,recipe='copper-cable'})
eq(remote_change.recipe,'copper-cable'); eq(remote_change.remote,true)
plate_stack.name,plate_stack.count,plate_stack.valid_for_read='iron-plate',4,true
fails(function() call('configure',{position=am.position,recipe='iron-gear-wheel'}) end,'remote recipe change: the machine at (3,0) holds items')
p.can_reach_entity=function() return true end
eq(call('configure',{position=am.position,recipe='iron-gear-wheel'}).remote,nil)
-- Filters go on filtering inserters, not machines without slots.
local set_filters={}
prototypes.item['stone-brick']={type='item'}
local fi={valid=true,name='fast-inserter',type='inserter',position={x=3,y=0},force=p.force,filter_slot_count=5,inserter_filter_mode='whitelist'}
fi.set_filter=function(i,f) set_filters[i]=f or false end
p.surface.find_entities_filtered=function() return {fi} end
local filtered=call('configure',{position=fi.position,filters={'stone-brick'},filter_mode='whitelist'})
eq(filtered.filters[1],'stone-brick'); eq(set_filters[1],'stone-brick'); eq(set_filters[2],false); eq(fi.use_filters,true)
fails(function() call('configure',{position=fi.position,filters={'not-an-item'}}) end,'unknown item')
fails(function() call('configure',{position=fi.position,filters={'stone-brick'},recipe='sulfur'}) end,'not both')
fi.filter_slot_count=0
fails(function() call('configure',{position=fi.position,filters={'stone-brick'}}) end,'no filter slots')
-- refuel tops every reachable burner up to count; collect empties outputs.
p.reach_distance=10
p.surface.find_entities_filtered=function(f) eq(f.force,p.force); return {f2,f1} end
main=inv(stack('coal',7),stack(nil,0),stack(nil,0))
f1.slots[2][1].name,f1.slots[2][1].count,f1.slots[2][1].valid_for_read='coal',4,true
local refuel=call('refuel',{count=5})
eq(refuel.transferred,4); eq(f1.slots[2][1].count,5); eq(f2.slots[2][1].count,5)
eq(refuel.entities[1].position.x,3) -- nearest first
local again=call('refuel',{count=5}); eq(again.transferred,0); eq(again.unchanged,2); eq(#again.entities,0)
-- A fuel slot holding another fuel refuses this one: the reply names it.
do
f2.slots[2][1].name='wood'
p.surface.find_entities_filtered=function() return {f2} end
local mixed=call('transfer',{position=f2.position,item='coal',inventory='fuel',count=2,direction='to_entity'})
eq(mixed.transferred,0); eq(mixed.entity_full.holding,'wood'); assert(mixed.entity_full.note:find('fuel slot holds wood',1,true),mixed.entity_full.note)
f2.slots[2][1].name='coal'
p.surface.find_entities_filtered=function(f) eq(f.force,p.force); return {f2,f1} end
end
f1.slots[4][1].name,f1.slots[4][1].count,f1.slots[4][1].valid_for_read='iron-plate',9,true
-- A stocked chest in reach is a feed chest until told otherwise: collect
-- leaves it alone by default (and says so), takes from it with chests=true
-- or when its position is named.
local feed_slots=inv(stack('copper-plate',40)); feed_slots.is_empty=function() return feed_slots[1].count==0 end
local feed={valid=true,name='wooden-chest',type='container',position={x=5,y=0},force=p.force,get_inventory=function(i) return i==defines.inventory.chest and feed_slots or nil end}
p.surface.find_entities_filtered=function(f)
  local out={}
  local types=type(f.type)=='table' and f.type or {f.type}
  for _,e in ipairs({f2,f1,feed}) do
    if f.type==nil then
      if f.position and e.position.x==f.position.x then out[#out+1]=e end
    else
      for _,t in ipairs(types) do if e.type==t then out[#out+1]=e end end
    end
  end
  return out
end
local collected=call('collect',{})
eq(collected.transferred,9); eq(collected.items[1].name,'iron-plate'); eq(collected.unchanged,1)
eq(collected.chests_skipped,1); eq(feed_slots[1].count,40)
eq(call('collect',{item='copper-plate'}).chests_skipped,1); eq(feed_slots[1].count,40)
main=inv(stack(nil,0),stack(nil,0),stack(nil,0))
eq(call('collect',{positions={{x=5,y=0}}}).transferred,40); eq(feed_slots[1].count,0)
feed_slots[1].count,feed_slots[1].valid_for_read=40,true
main=inv(stack(nil,0),stack(nil,0),stack(nil,0))
local with_chests=call('collect',{chests=true})
eq(with_chests.transferred,40); eq(with_chests.chests_skipped,nil); eq(feed_slots[1].count,0)
-- want: hold N, taking only the difference, in a queue too (shake2 and shake3:
-- Opus's plans failed with "unknown argument want for collect").
do
  feed_slots[1].count,feed_slots[1].valid_for_read=40,true
  main=inv(stack('copper-plate',15),stack(nil,0),stack(nil,0))
  local topped=call('collect',{item='copper-plate',positions={{x=5,y=0}},want=25})
  eq(topped.transferred,10); eq(feed_slots[1].count,30)
  local enough=call('collect',{item='copper-plate',positions={{x=5,y=0}},want=20})
  eq(enough.transferred,0); eq(enough.held,25); eq(feed_slots[1].count,30)
  call('queue_cancel',{})
  call('queue_submit',{steps={{action='collect',args={item='copper-plate',positions={{x=5,y=0}},want=40}}}})
  advance(1)
  eq(feed_slots[1].count,15)
  local h=call('queue_status').history; eq(h[#h].action,'collect'); eq(h[#h].ok,true)
  fails(function() call('collect',{positions={{x=5,y=0}},want=5}) end,'want needs item')
  fails(function() call('collect',{item='copper-plate',want=5,count=5}) end,'not both')
  call('queue_cancel',{})
end
p.surface.find_entities_filtered=function(f) eq(f.force,p.force); return {f2,f1} end
main=inv(stack('coal',7),stack(nil,0),stack(nil,0))
fails(function() call('refuel',{fuel='iron-ore'}) end,'fuel must be')
-- feed gives each machine what it takes by hand (fuel, recipe ingredients,
-- science packs) up to count, keeping a reserve; nothing is taken out.
do
defines.inventory.lab_input=9
prototypes.item['automation-science-pack']={}; prototypes.item['copper-plate']={}
f1.get_recipe=function() return {ingredients={{type='item',name='iron-ore',amount=1}}} end
local lab_slots=inv(stack(nil,0))
local lab={valid=true,name='lab',type='lab',position={x=6,y=0},force=p.force,prototype={lab_inputs={'automation-science-pack'}},get_inventory=function(i) return i==9 and lab_slots or nil end}
p.surface.find_entities_filtered=function() return {lab,f1,f2} end
main=inv(stack('coal',3),stack('iron-ore',30),stack('automation-science-pack',12))
eq(f1.slots[2][1].count,5)
local fed=call('feed',{count=20,keep=2})
eq(fed.transferred,31); eq(fed.items['iron-ore'],20); eq(fed.items['automation-science-pack'],10); eq(fed.items.coal,1)
eq(f1.slots[3][1].count,20); eq(f1.slots[2][1].count,6); eq(f2.slots[2][1].count,5); eq(lab_slots[1].count,10)
eq(fed.held['iron-ore'],10); eq(fed.held.coal,2); eq(#fed.entities,2); eq(fed.entities[1].name,'stone-furnace'); eq(fed.entities[2].gave['automation-science-pack'],10)
eq(fed.unchanged,1)
local nothing=call('feed',{items={'copper-plate'}})
eq(nothing.transferred,0); assert(nothing.nothing_moved:find('nothing given: none of the 3 machines wants an item',1,true),nothing.nothing_moved)
-- item: one name, as transfer takes it (Grok); count is the target each machine holds.
local one=call('feed',{item='iron-ore',count=25})
eq(one.transferred,5); eq(one.items['iron-ore'],5); eq(one.items.coal,nil); eq(f1.slots[3][1].count,25); eq(one.held['iron-ore'],5)
fails(function() call('feed',{item='nope'}) end,'unknown item nope')
-- No coal carried: the reply says so and what the furnaces hold (agent-minds
-- study: Haiku's 35 empty feeds); the third identical one in 7 min says so too.
main=inv(stack('iron-ore',10),stack(nil,0),stack(nil,0))
local nocoal=call('feed',{items={'coal'}})
eq(nocoal.transferred,0); eq(nocoal.nothing_moved,'nothing given: you carry 0 coal; 2 machines hold 5-6')
eq(nocoal.repeated,nil); eq(call('feed',{items={'coal'}}).repeated,nil)
eq(call('feed',{items={'coal'}}).repeated,'feed 3 times in 7 min with nothing moved (same target and item)')
fails(function() call('feed',{fuel='iron-ore'}) end,'fuel must be')
fails(function() call('feed',{items={'nope'}}) end,'unknown item nope')
-- With a radius, feed walks a tour through the machines that want something
-- held, and ends early once nothing wanted is left.
main=inv(stack('iron-ore',5))
f1.slots[3][1].count,f1.slots[3][1].valid_for_read=0,false
local tour=call('feed',{radius=20,items={'iron-ore'}})
eq(tour.places,1); eq(call('status').active.kind,'gather'); advance(1)
local toured=call('status').last
eq(toured.outcome,'topped_up'); eq(toured.op,'feed'); eq(toured.given,5); eq(toured.items['iron-ore'],5); eq(f1.slots[3][1].count,5)
eq(call('feed',{radius=20,items={'iron-ore'}}).places,0); advance(1); eq(call('status').last.outcome,'nothing_to_do')
f1.get_recipe=nil
end
p.surface.find_entities_filtered=function(f) eq(f.force,p.force); return {f2,f1} end
main=inv(stack('coal',7),stack(nil,0),stack(nil,0))
-- Ammo goes to a turret's ammo inventory; rearm tops up turrets in reach.
defines.inventory.turret_ammo=7
prototypes.item['firearm-magazine']={type='ammo',fuel_value=0}
local mag_slot=stack(nil,0)
local turret={valid=true,name='gun-turret',type='ammo-turret',position={x=5,y=0},force=p.force}
turret.get_inventory=function(i) if i==7 then return inv(mag_slot) end end
p.surface.find_entities_filtered=function() return {turret} end
main=inv(stack('firearm-magazine',30))
eq(call('transfer',{position=turret.position,item='firearm-magazine',count=5,direction='to_entity'}).inventory,'turret_ammo'); eq(mag_slot.count,5)
local rearmed=call('rearm',{count=10}); eq(rearmed.transferred,5); eq(mag_slot.count,10); eq(main[1].count,20)
fails(function() call('rearm',{ammo='coal'}) end,'ammo must be')
-- Crafted ammo lands in the gun ammo slots; rearm draws there after the
-- main inventory, and holding none at all fails instead of reading as unchanged.
defines.inventory.character_ammo=8
local slot_ammo=stack('firearm-magazine',15)
p.get_inventory=function(i) if i==8 then return inv(slot_ammo) end end
main=inv(stack(nil,0)); mag_slot.count=0; mag_slot.valid_for_read=false; mag_slot.name=nil
rearmed=call('rearm',{count=10}); eq(rearmed.transferred,10); eq(slot_ammo.count,5)
mag_slot.count=0; mag_slot.valid_for_read=false; mag_slot.name=nil
slot_ammo.count=0; slot_ammo.valid_for_read=false; slot_ammo.name=nil
fails(function() call('rearm',{count=10}) end,'no firearm-magazine in inventory or ammo slots; 1 target(s) want more: (5,0) has 0')
fails(function() call('transfer',{position=turret.position,item='firearm-magazine',count=5,direction='to_entity'}) end,'no firearm-magazine in inventory or ammo slots; the target has 0')
-- Short of ammo the hand-crafting queue will deliver: rearm waits for it,
-- counted as waiting on hand crafting, then feeds.
p.force.recipes=p.force.recipes or {}
p.force.recipes['firearm-magazine']={name='firearm-magazine',enabled=true,energy=1,products={{type='item',name='firearm-magazine',amount=1}}}
p.crafting_queue={{index=1,recipe='firearm-magazine',count=10}}
local awaiting=call('rearm',{count=10})
eq(awaiting.awaiting_craft.need,10); eq(awaiting.awaiting_craft.crafting,10); eq(call('status').active.kind,'feed')
call('status'); advance(30); eq(mag_slot.valid_for_read,false)
assert(call('status').clock:find('waiting on hand crafting',1,true))
slot_ammo.name,slot_ammo.count,slot_ammo.valid_for_read='firearm-magazine',10,true; p.crafting_queue=nil
advance(11)
local fed=call('status').last
eq(fed.kind,'feed'); eq(fed.outcome,'fed'); eq(fed.result.transferred,10); eq(mag_slot.count,10)
-- In a plan the step holds the queue until the crafts land.
mag_slot.count,mag_slot.valid_for_read,mag_slot.name=0,false,nil
p.crafting_queue={{index=1,recipe='firearm-magazine',count=10}}
call('queue_cancel',{}); call('queue_submit',{steps={{action='rearm',args={count=10}},{action='wait_ticks',args={ticks=50}}},mode='replace'}); call('queue_resume',{})
advance(20); eq(call('queue_status').active.action,'rearm')
slot_ammo.name,slot_ammo.count,slot_ammo.valid_for_read='firearm-magazine',10,true; p.crafting_queue=nil
advance(12)
local qs=call('queue_status'); local h=qs.history[#qs.history]
eq(qs.active.action,'wait_ticks'); eq(h.action,'rearm'); eq(h.ok,true); eq(h.result.outcome,'fed'); eq(mag_slot.count,10)
call('queue_cancel',{})
p.get_inventory=nil
call('walk',{direction='west',ticks=10}); runtime.stop_all()
eq(call('status').active,false); eq(call('status').last.outcome,'interrupted')
-- Explicit offline attachment is required; combat remains active during movement.
p.connected=false
fails(function() call('walk',{direction='east'}) end,'join a graphical Factorio client')
fails(function() call('attach',{offline=true}) end,'join a graphical Factorio client')
p.connected=true
call('attach',{})
-- shoot fires real ammo from the ammo slots: none is an error, not a silent no-op.
local ammo_left=0
p.get_inventory=function() return {get_item_count=function() return ammo_left end,get_contents=function() return {} end} end
fails(function() call('shoot',{position={x=3,y=0},ticks=4}) end,'no ammunition in the ammo slots')
ammo_left=10
eq(call('shoot',{position={x=3,y=0},ticks=4}).ammo,10)
call('walk',{direction='east',ticks=2})
advance(1); eq(p.walking_state.walking,true); eq(p.shooting_state.state,1)
advance(2); eq(p.walking_state.walking,false); eq(p.shooting_state.state,1)
advance(2); eq(p.shooting_state.state,0); eq(call('status').active,false)
eq(call('status').last_combat.outcome,'duration_elapsed'); eq(call('status').last_combat.ammo_used,0)
-- What the engine spent is reported (shake2: Grok saw "unchanged" and
-- concluded shoot spent nothing); empty slots end the shooting.
call('shoot',{position={x=3,y=0},ticks=30}); advance(2); ammo_left=7; advance(2)
eq(p.shooting_state.state,1); ammo_left=0; advance(1)
eq(p.shooting_state.state,0); eq(call('status').combat,false)
eq(call('status').last_combat.outcome,'out_of_ammo'); eq(call('status').last_combat.ammo_used,10)
ammo_left=10
call('detach'); p.connected=false; fails(function() call('walk',{direction='east'}) end,'join a graphical Factorio client')
-- Direct intervention cancels queued controls while preserving pending work.
p.connected=true
do
-- pickup needs an item on the ground in reach (shake5): it takes it and
-- last reports picked; with none in reach it is refused.
local saved_find,saved_insert=p.surface.find_entities_filtered,p.insert
local ground={valid=true,type='item-entity',name='item-on-ground',position={x=0,y=0},stack={valid_for_read=true,name='coal',count=2}}
ground.destroy=function() ground.valid=false end
p.surface.find_entities_filtered=function(f) if f.type=='item-entity' then return ground.valid and {ground} or {} end return saved_find(f) end
local got={}; p.insert=function(s) got[s.name]=(got[s.name] or 0)+s.count; return s.count end
call('queue_submit',{steps={{action='walk',args={direction='east',ticks=20}},{action='wait_ticks',args={ticks=5}}}})
advance(1); eq(call('queue_status').active.action,'walk')
call('pickup',{ticks=1})
eq(call('queue_status').paused,true); eq(call('queue_status').active,false)
eq(storage.agent_harness.active[1].kind,'pickup'); eq(#call('queue_status').pending,1)
advance(1); eq(p.picking_state==true,false) -- the engine's pickup would go uncounted
advance(1)
eq(got.coal,2); eq(ground.valid,false); eq(call('status').last.picked.coal,2)
fails(function() call('pickup',{}) end,'nothing to pick up within 1 tiles of')
-- A step toward an absolute goal is requeued at the head when interrupted.
call('queue_cancel',{})
call('queue_submit',{steps={{action='move_to',args={position={x=50,y=0},pathfind=false}},{action='wait_ticks',args={ticks=5}}}})
advance(1); eq(call('queue_status').active.action,'move_to')
ground.valid=true
call('pickup',{ticks=30})
local requeued=call('queue_status'); eq(#requeued.pending,2); eq(requeued.pending[1].action,'move_to')
advance(8); eq(call('status').last.outcome,'picked_up') -- done once nothing is left in reach
call('queue_cancel',{})
p.surface.find_entities_filtered,p.insert=saved_find,saved_insert
end
-- on_fail goto keeps the plan running after the failed step's controls stop.
call('queue_submit',{steps={{action='rotate',args={position={x=99,y=99}},on_fail='goto:out'},{action='walk',args={direction='east',ticks=5}},{action='wait_ticks',args={ticks=50},label='out'}}})
advance(2); local jumped=call('queue_status')
eq(jumped.paused,false); eq(jumped.active.action,'wait_ticks')
call('queue_cancel',{}); call('queue_submit',{steps={{action='wait_ticks',args={ticks=5}}},start=false})
-- Every reply carries game-time feedback: time since the last request and idle share.
assert(call('status').clock:find('since your last request',1,true))
-- Standing still for hand-crafted items is its own bucket, not hidden as busy.
storage.agent_harness.active[1]={kind='awaiting',awaiting_craft=true,until_tick=tick+200}
advance(120); storage.agent_harness.active[1]=nil
local waited=call('status').clock
assert(waited:find('character idle 0s of it (0%), waiting on hand crafting 2s of it (100%)',1,true),waited)
assert(not call('status').clock:find('waiting on',1,true))
advance(2); eq(call('status').active,false)
-- Commands that never drive the character leave a running queue alone.
call('queue_cancel',{})
call('queue_submit',{steps={{action='walk',args={direction='east',ticks=20}}}})
advance(1); pcall(call,'research_next',{technologies={}}) -- the handler's own error is irrelevant here
eq(call('queue_status').paused,false); eq(call('queue_status').active.action,'walk')
call('queue_cancel',{}); call('queue_submit',{steps={{action='wait_ticks',args={ticks=5}}},start=false})
-- Enemy queries run at 10Hz while normal shooting input stays at 60Hz.
local enemy={name='enemy'}
game.forces={p.force,enemy,enemy=enemy_evolution}
p.force.get_friend=function() return false end; p.force.get_cease_fire=function() return false end
local scans=0
p.surface.find_entities_filtered=function(filter)
  scans=scans+1; eq(filter.limit,256)
  return {{valid=true,position={x=2,y=0},force=enemy}}
end
call('shoot',{auto=true,ticks=12})
advance(3); eq(scans,1)
runtime=dofile('mod/agent-harness_0.1.0/runtime.lua') -- simulate saved source reconstruction during on_load
advance(3); eq(scans,1); eq(p.shooting_state.state,1)
advance(6); eq(scans,2); eq(p.shooting_state.state,1)
advance(1); eq(p.shooting_state.state,0)
-- One observation exposes small queue/combat summaries without queue history.
p.surface.find_entities_filtered=function() return {} end
main.get_contents=function() return {} end
p.get_inventory=function() return {get_contents=function() return {} end} end
local observation=call('observe',{})
eq(observation.queue.pending,1); eq(observation.queue.paused,true)
eq(observation.queue.history,nil); eq(observation.combat,false)
-- inventory: the character's inventories on their own, a read that leaves
-- the running action alone (shake2: `call inventory` failed 15 times).
do
  local kept=main
  main={{valid_for_read=true,name='iron-plate',count=50},{valid_for_read=false}}
  main.get_contents=function() return {{name='iron-plate',quality='normal',count=50}} end
  main.count_empty_stacks=function() return 1 end
  defines.inventory.character_guns,defines.inventory.character_ammo,defines.inventory.character_armor=2,3,4
  p.get_inventory=function(id) return {get_contents=function() return id==3 and {{name='firearm-magazine',quality='normal',count=10}} or {} end} end
  call('walk',{direction='east',ticks=5})
  local held=call('inventory',{})
  eq(held.inventory[1].name,'iron-plate'); eq(held.inventory[1].count,50); eq(held.ammo[1].count,10); eq(#held.guns,0)
  eq(held.free,'free=1/2'); assert(held.clock,'inventory carries the clock line')
  eq(call('status').active.kind,'walk'); call('stop',{})
  fails(function() call('inventory',{item='iron-plate'}) end,'unknown argument item for inventory')
  defines.inventory.character_guns,defines.inventory.character_ammo,defines.inventory.character_armor=nil,nil,nil
  p.get_inventory=function() return {get_contents=function() return {} end} end
  main=kept
end
-- Resource summaries must not crowd structures out of a small entity budget.
local function resource(name,x,y,amount)
  return {valid=true,type='resource',name=name,position={x=x,y=y},amount=amount,force={name='neutral'}}
end
local belt={valid=true,type='transport-belt',name='transport-belt',position={x=5,y=0},force=p.force}
p.surface.find_entities_filtered=function() return {
  resource('copper-ore',0.5,0.5,10),resource('copper-ore',1.5,0.5,20),
  resource('copper-ore',8.5,0.5,30),resource('iron-ore',0.5,1.5,40),belt,
  resource('copper-ore',100.5,0.5,999),
} end
local compact=call('observe',{limit=1})
eq(#compact.entities,1); eq(compact.entities[1].name,'transport-belt')
eq(compact.truncated,false); eq(#compact.resource_patches,3)
eq(compact.resource_patches[1].tiles,2); eq(compact.resource_patches[1].amount,30)
eq(compact.resource_patches[1].left,0); eq(compact.resource_patches[1].right,2)
local detailed=call('observe',{resources='tiles',limit=1})
eq(detailed.entities[1].name,'copper-ore'); eq(detailed.truncated,true)
eq(detailed.resource_patches,nil)
local none=call('observe',{resources='none'})
eq(#none.entities,1); eq(none.resource_patches,nil)
fails(function()call('observe',{resources='invalid'})end,'resources must be')
-- Scheduler failure cleanup must retain the exact path failure/resume record.
prototypes={item={['transport-belt']={place_result={name='transport-belt',type='transport-belt'}}}}
p.position={x=0,y=0}; p.build_distance=6
p.surface.find_entities_filtered=function() return {{valid=true,name='transport-belt',direction=0,force=p.force}} end
call('queue_cancel',{})
call('queue_submit',{steps={{action='build_path',args={points={{x=.5,y=.5},{x=5.5,y=.5}}}}}})
advance(2)
local failure=call('status').last
local failed_queue=call('queue_status')
eq(failure.kind,'build_path'); eq(failure.outcome,'build_failed'); eq(failure.next_index,1)
eq(failed_queue.paused,true); eq(failed_queue.history[#failed_queue.history].result.completion.next_index,1)
assert(failure.error:find('existing belt'))
-- Cancellation before the first placement leaves no controller running.
call('build_path',{points={{x=.5,y=.5},{x=5.5,y=.5}}})
-- the stream director's look-ahead: the path's bounds, once
do local ab=call('status').active.bounds; eq(ab.left,0.5); eq(ab.right,5.5); eq(ab.top,0.5); eq(ab.bottom,0.5) end
call('stop',{}); advance(1)
eq(call('status').active,false); eq(call('status').last.kind,'build_path'); eq(call('status').last.next_index,1)
-- Map queries never read uncharted chunks or entities spilling across edges.
prototypes.tile={}
p.force.is_chunk_charted=function(_,chunk)return chunk.x==0 and chunk.y==0 end
local map_reads=0
p.surface.find_entities_filtered=function(filter)
  map_reads=map_reads+1
  eq(filter.area[1][1],0);eq(filter.area[1][2],0)
  if filter.type=='resource' then return {
    {name='iron-ore',position={x=1.5,y=1.5},amount=10},
    {name='iron-ore',position={x=32.5,y=1.5},amount=999},
  } end
  return {{position={x=31.5,y=1.5}},{position={x=32.5,y=1.5}}}
end
local map=call('observe',{scope='map',radius=32,water=false})
eq(map_reads,2);eq(#map.regions,2)
for _,region in ipairs(map.regions)do eq(region.count,1);assert(region.right<=32);if region.kind=='resource'then eq(region.amount,10)end end
assert(map.scope:find('charted'))
-- Craft batches attempt every entry; craftable is a read-only observe scope.
p.surface.find_entities_filtered=function() return {} end
p.force.recipes={['iron-gear-wheel']={enabled=true,category='crafting'},pipe={enabled=true,category='crafting'},
  ['iron-plate']={enabled=true,category='smelting'},rocket={enabled=false,category='crafting'}}
local have={['iron-gear-wheel']=4,pipe=0,['iron-plate']=9}
p.begin_crafting=function(r) return math.min(r.count,have[r.recipe]) end
p.get_craftable_count=function(name) return have[name] end
p.character.prototype.crafting_categories={crafting=true}
prototypes.entity=prototypes.entity or {}
prototypes.entity['assembling-machine-2']={name='assembling-machine-2',crafting_categories={crafting=true},get_crafting_speed=function() return 0.75 end}
local crafted=call('craft',{recipes={{recipe='iron-gear-wheel',count=3},{recipe='rocket'},{recipe='iron-gear-wheel',count=2},{recipe='pipe',count=1}}})
eq(crafted.started['iron-gear-wheel'],5); eq(crafted.started.pipe,0); eq(crafted.errors.rocket,'recipe is unavailable')
eq(crafted.no_assembler,nil); eq(crafted.blocks,nil) -- no assembler unlocked, short queue
-- A machine-only recipe says so (shake3: Grok's engine-unit read "not hand-craftable now").
p.force.recipes['engine-unit']={enabled=true,category='advanced-crafting'}
eq(call('craft',{recipes={{recipe='engine-unit',count=1}}}).errors['engine-unit'],
  'engine-unit (category advanced-crafting) cannot be hand-crafted by a character; an assembling machine can make it (configure recipe=engine-unit, then feed it)')
p.force.recipes['engine-unit']=nil
-- A long hand craft states the backlog and what an unlocked assembler would take.
p.force.recipes['assembling-machine-2']={enabled=true}
p.force.recipes['iron-gear-wheel'].energy=0.5; p.force.recipes['iron-gear-wheel'].products={{type='item',name='iron-gear-wheel',amount=1}}
have['iron-gear-wheel']=100
p.crafting_queue={{index=1,recipe='iron-gear-wheel',count=100}}
crafted=call('craft',{recipe='iron-gear-wheel',count=100})
eq(crafted.no_assembler['iron-gear-wheel'],'none of our assemblers is set to iron-gear-wheel; one assembling-machine-2 makes these 100 in ~67s without the character')
assert(crafted.blocks:find('~50s of hand crafting queued (this: ~50s)',1,true),crafted.blocks)
p.crafting_queue=nil; p.force.recipes['assembling-machine-2']=nil; have['iron-gear-wheel']=4
-- Our machines already hold the product: a covered craft is refused unless forced.
local find_before_stock=p.surface.find_entities_filtered
local gear_out={get_item_count=function(f) return f.name=='iron-gear-wheel' and 200 or 0 end}
local gear_machine={valid=true,name='assembling-machine-2',type='assembling-machine',position={x=12,y=5},
  get_output_inventory=function() return gear_out end,get_recipe=function() return {products={{type='item',name='iron-gear-wheel'}}} end}
p.surface.find_entities_filtered=function(f) return f.radius and {gear_machine} or {} end
have['iron-gear-wheel']=100
fails(function() call('craft',{recipe='iron-gear-wheel',count=100}) end,'not crafted: 200 iron-gear-wheel held by our factory (200 in 1 assembling-machine-2); nearest 200 at (12,5) 13 tiles away; collect item=iron-gear-wheel radius=15 gathers it; or pass force=true')
local forced=call('craft',{recipe='iron-gear-wheel',count=100,force=true})
eq(forced.started,100); assert(forced.stock['iron-gear-wheel']:find('200 iron-gear-wheel held',1,true))
-- A short craft (under 3 s of hand time) goes ahead and just names the stock.
eq(call('craft',{recipe='iron-gear-wheel',count=2}).started,2)
local batch_refused=call('craft',{recipes={{recipe='iron-gear-wheel',count=50}}})
eq(batch_refused.started['iron-gear-wheel'],nil); assert(batch_refused.errors['iron-gear-wheel']:find('not crafted',1,true))
-- collect with a radius walks the stock back: here the machine is in reach.
local gear_slots=inv(stack('iron-gear-wheel',30))
gear_out.get_item_count=gear_slots.get_item_count
gear_machine.force=p.force
gear_machine.get_inventory=function(i) return i==defines.inventory.assembling_machine_output and gear_slots or nil end
local main_before_collect=main
main=inv(stack(nil,0),stack(nil,0))
p.can_reach_entity=function() return true end
prototypes.item['iron-gear-wheel']={fuel_value=0}
local trip=call('collect',{item='iron-gear-wheel',radius=20,count=25})
eq(trip.stock,30); eq(trip.places,1); eq(call('status').active.kind,'gather')
advance(1)
local gathered=call('status').last
eq(gathered.outcome,'collected'); eq(gathered.got,25); eq(gathered.item,'iron-gear-wheel'); eq(main[1].count,25)
fails(function() call('collect',{item='iron-gear-wheel',ticks=60}) end,'ticks applies to collect with radius')
-- Without an item (Gemini): every assembler and furnace output in the radius, all items; inputs and fuel stay.
do
  local function listing(t)
    t.get_contents=function() local out={}; for _,s in ipairs(t) do if s.valid_for_read then out[#out+1]={name=s.name,count=s.count,quality='normal'} end end; return out end
    return t
  end
  listing(gear_slots)
  local gear_output=gear_machine.get_output_inventory
  gear_machine.get_output_inventory=function() return gear_slots end
  local result,source,fuel=listing(inv(stack('iron-plate',7))),listing(inv(stack('iron-ore',9))),listing(inv(stack('coal',3)))
  local by={[defines.inventory.furnace_result]=result,[defines.inventory.furnace_source]=source,[defines.inventory.fuel]=fuel}
  local smelter={valid=true,name='stone-furnace',type='furnace',position={x=3,y=2},force=p.force,
    get_output_inventory=function() return result end,get_inventory=function(i) return by[i] end,get_fuel_inventory=function() return fuel end}
  local idle_out=listing(inv(stack(nil,0)))
  local idle={valid=true,name='assembling-machine-1',type='assembling-machine',position={x=6,y=2},force=p.force,
    get_output_inventory=function() return idle_out end,get_inventory=function() return idle_out end}
  local asked
  p.surface.find_entities_filtered=function(f) asked=f.type; return f.radius and {gear_machine,smelter,idle} or {} end
  main=inv(stack(nil,0),stack(nil,0),stack(nil,0))
  local all=call('collect',{radius=20})
  eq(all.items,'all'); eq(all.stock,12); eq(all.places,2); eq(asked[1],'assembling-machine'); eq(asked[2],'furnace'); eq(#asked,2)
  advance(1)
  local took=call('status').last
  eq(took.outcome,'collected'); eq(took.got,12); eq(took.items['iron-gear-wheel'],5); eq(took.items['iron-plate'],7)
  eq(gear_slots[1].valid_for_read,false); eq(result[1].valid_for_read,false); eq(source[1].count,9); eq(fuel[1].count,3)
  -- Nothing left: nothing_collected, and the reply says so.
  local none=call('collect',{radius=20,up_to=true})
  eq(none.places,0); eq(none.note,'no assembler or furnace output in radius holds anything')
  advance(1); eq(call('status').last.outcome,'nothing_collected')
  -- count caps the total.
  result[1].name,result[1].count,result[1].valid_for_read='iron-plate',7,true
  call('collect',{radius=20,count=4}); advance(1)
  eq(call('status').last.got,4); eq(result[1].count,3)
  fails(function() call('collect',{radius=20,chests=true}) end,'takes machine outputs only; name an item to take from chests')
  fails(function() call('collect',{radius=20,types={'container'}}) end,'types may be assembling-machine and furnace')
  fails(function() call('collect',{radius=20,quality='rare'}) end,'quality goes with item')
  -- A repeating sweep: round 1 takes the 3 plates left, round 2 finds nothing; its line reaches the team block once.
  call('queue_repeat',{name='sweep',interval_ticks=60,steps={{action='collect',args={radius=20,up_to=true}}}})
  advance(5); eq(result[1].valid_for_read,false)
  advance(70)
  local team=call('status').team
  eq(team and team.queue and team.queue[1],'queue sweep round 2: 1 of 1 steps short: collect nothing_collected')
  advance(70); eq((call('status').team or {}).queue,nil)
  call('queue_cancel',{})
  gear_machine.get_output_inventory=gear_output
end
main=main_before_collect
p.surface.find_entities_filtered=find_before_stock; have['iron-gear-wheel']=4
-- A craft that starts short says which raw ingredient ran out, through intermediates.
p.force.recipes['iron-gear-wheel'].ingredients={{type='item',name='iron-plate',amount=2}}
local pipe_recipe=p.force.recipes.pipe
p.force.recipes.pipe={name='pipe',enabled=true,category='crafting',energy=0.5,ingredients={{type='item',name='iron-gear-wheel',amount=1},{type='item',name='copper-plate',amount=1}},products={{type='item',name='pipe',amount=1}}}
main_before_collect=main
main=inv(stack('iron-plate',3),stack('iron-gear-wheel',1))
have.pipe=0
local short_craft=call('craft',{recipe='pipe',count=3})
eq(short_craft.started,0); eq(short_craft.short,'copper-plate short 3 (held 0), iron-plate short 1 (held 3)')
main=main_before_collect; p.force.recipes.pipe=pipe_recipe; p.force.recipes['iron-gear-wheel'].ingredients=nil
local craftable=call('observe',{scope='craftable'}).craftable
eq(craftable['iron-gear-wheel'],4); eq(craftable.pipe,nil); eq(craftable['iron-plate'],nil)
craftable=call('observe',{scope='craftable',recipes={'pipe','rocket'}}).craftable
eq(craftable.pipe,0); eq(craftable.rocket,0)
eq(call('observe',{scope='craftable',recipes={'iron-plate'}}).craftable['iron-plate'],0) -- smelting is not by hand
fails(function() call('observe',{scope='craftable',recipes={'nope'}}) end,'unknown recipe')
fails(function() call('observe',{scope='bogus'}) end,'unknown observe scope')
fails(function() call('observe',{scope='craftable',names={'pipe'}}) end,'unknown argument names for craftable; valid: recipes')
-- supply is a read-only observe scope with its own arguments (supply.lua has its own tests).
do
  local sup=call('observe',{scope='supply',item='transport-belt'})
  eq(sup.item,'transport-belt'); assert(sup.where and sup.counted and sup.flow,'supply reply')
end
fails(function() call('observe',{scope='supply',item='transport-belt',radius=5}) end,'radius needs near')
fails(function() call('observe',{scope='supply',item='transport-belt',pack='x'}) end,'unknown argument pack for supply; valid: item, near, radius, surface')
fails(function() call('observe',{scope='supply',item='nope'}) end,'item must be an item name')
-- nearest sorts by distance, skips fogged chunks and the character itself.
p.position={x=0,y=0}
p.force.is_chunk_visible=function(_,chunk) return chunk.x<1 end
local rock=function(x,y,name) return {valid=true,name=name or 'rock-big',position={x=x,y=y}} end
p.surface.find_entities_filtered=function(f)
  eq(f.radius,64); eq(f.name,'rock-big')
  return {rock(10,0),p.character,rock(40,0),rock(-3,4),rock(1,1)}
end
local near=call('observe',{scope='nearest',name='rock-big',radius=64,limit=2})
eq(near.total,3); eq(#near.entities,2); eq(near.entities[1].position.x,1); eq(near.entities[1].distance,1.4)
eq(near.entities[2].distance,5); eq(near.entities[1].name,nil)
p.surface.find_entities_filtered=function() return {rock(2,0,'rock-huge')} end
eq(call('observe',{scope='nearest',type='simple-entity'}).entities[1].name,'rock-huge')
fails(function() call('observe',{scope='nearest'}) end,'name or type')
-- A name that is not a prototype lists the matching ones (shake4: "Unknown
-- entity name: tree" for Sol and Gemini); a type name says to filter by type.
;(function()
  local saved_entity=prototypes.entity
  prototypes.entity={['huge-rock']={type='simple-entity'},['big-rock']={type='simple-entity'},['tree-01']={type='tree'},['tree-02']={type='tree'},['dead-tree-desert']={type='tree'}}
  p.surface.find_entities_filtered=function(f)
    for _,n in ipairs(type(f.name)=='table' and f.name or {f.name}) do if not prototypes.entity[n] then error('Unknown entity name: '..n) end end
    return {}
  end
  fails(function() call('observe',{scope='nearest',name='tree'}) end,'tree is not an entity name; matching names: dead-tree-desert, tree-01, tree-02; tree is an entity type: filter with type instead')
  fails(function() call('observe',{scope='nearest',name='rock-huge'}) end,'rock-huge is not an entity name; matching names: huge-rock')
  fails(function() call('observe',{entity_names={'stone-rock'}}) end,'stone-rock is not an entity name')
  eq(call('observe',{scope='nearest',name='huge-rock'}).total,0)
  prototypes.entity=saved_entity
end)()
-- Up to 128 tiles; nothing found says why (only charted ground counts: little after a landing).
p.surface.find_entities_filtered=function(f) eq(f.radius,128); return {} end
do
  local none=call('observe',{scope='nearest',name='coal',radius=128})
  eq(none.total,0); assert(none.note:find('walk out to explore',1,true),none.note)
end
fails(function() call('observe',{scope='nearest',name='coal',radius=129}) end,'radius out of range')
-- Research queue replacement keeps order, honours queued prerequisites and
-- reports what the engine did not accept; front makes a tech active.
local function tech(name,researched,prerequisites)
  return {name=name,enabled=true,researched=researched,prerequisites=prerequisites or {},prototype={}}
end
local techs={automation=tech('automation',true),logistics=tech('logistics'),optics=tech('optics'),turrets=tech('turrets')}
techs.electronics=tech('electronics',false,{automation=techs.automation,logistics=techs.logistics})
techs.lamp=tech('lamp',false,{optics=techs.optics})
p.force.technologies=techs
local research_queue={}
setmetatable(p.force,{
  __index=function(_,key) if key=='research_queue' then return research_queue end end,
  __newindex=function(t,key,value)
    if key~='research_queue' then return rawset(t,key,value) end
    research_queue={}
    for i=1,math.min(#value,3) do research_queue[i]=techs[value[i]] end -- engine cap
  end})
local replaced=call('research',{research_queue={'electronics','logistics','automation','nope','optics','lamp','turrets'}})
-- Unresearched prerequisites go in ahead of what needs them, like the game GUI.
eq(table.concat(replaced.queue,','),'logistics,electronics,optics')
eq(table.concat(replaced.added_prerequisites.electronics,','),'logistics')
eq(table.concat(replaced.skipped,','),'automation: already_researched,nope: unknown')
eq(table.concat(replaced.pending,','),'lamp,turrets')
-- Putting one in front keeps the names still waiting for room.
local front=call('research',{technology='turrets',front=true})
eq(table.concat(front.queue,','),'turrets,logistics,electronics'); eq(front.skipped,nil); eq(table.concat(front.pending,','),'optics,lamp')
-- A plain research_queue replaces the waiting names too.
eq(call('research',{research_queue={}}).pending,nil)
-- A front research_queue keeps the rest of the queue behind it; append goes after.
research_queue={techs.logistics,techs.optics}
local ahead=call('research',{research_queue={'turrets'},front=true})
eq(table.concat(ahead.queue,','),'turrets,logistics,optics'); eq(ahead.skipped,nil)
research_queue={techs.logistics}
eq(table.concat(call('research',{research_queue={'turrets','logistics'},append=true}).queue,','),'logistics,turrets')
-- No arguments reports the current research and queue instead of refusing.
p.force.current_research=techs.logistics; p.force.research_progress=0.25
local report=call('research',{})
eq(report.current,'logistics'); eq(report.progress,0.25); eq(table.concat(report.queue,','),'logistics,turrets')
p.force.current_research=nil
eq(call('research',{}).current,false)
fails(function() call('research',{technology='nope'}) end,'unknown technology nope')
fails(function() call('research',{front=true}) end,'technology or research_queue is required')
fails(function() call('research',{research_queue={},front=true,append=true}) end,'not both')
-- Pending entries are fed in once the engine queue has room.
research_queue={techs.logistics,techs.optics,techs.turrets}
eq(table.concat(call('research',{research_queue={'lamp'},append=true}).pending,','),'lamp')
research_queue={techs.optics,techs.turrets}
game.forces.player=p.force; p.force.valid=true
advance(60)
eq(table.concat(call('research',{research_queue={},append=true}).queue,','),'optics,turrets,lamp')
-- In front, a technology brings its missing prerequisites ahead of it.
local lamp_front=call('research',{technology='lamp',front=true})
eq(table.concat(lamp_front.queue,','),'optics,lamp,turrets'); eq(table.concat(lamp_front.added_prerequisites.lamp,','),'optics')
fails(function() call('research',{research_queue={first='optics'}}) end,'array')
techs.optics.prototype.research_trigger={type='craft-item',item={name='iron-plate'},count=50}
fails(function() call('research',{technology='optics',front=true}) end,'trigger_unlocked (craft 50 iron-plate)')
p.force.technologies=setmetatable({},{__index=techs,__pairs=function() return next,techs,nil end})
local listed=call('technologies',{available=true}).entries
p.force.technologies=techs
local by_name={}
for _,entry in ipairs(listed) do by_name[entry.name]=entry end
eq(by_name.optics.trigger,'craft 50 iron-plate'); eq(by_name.optics.count,nil); eq(by_name.automation,nil); eq(by_name.lamp,nil)
techs.optics.prototype.research_trigger=nil
-- Front on an empty queue, or a queue the engine refuses, uses add_research.
local added
p.force.add_research=function(t) added=t.name; research_queue={t}; return true end
research_queue={}; eq(call('research',{technology='optics',front=true}).queued,true); eq(added,'optics')
-- Appending a lone technology may lean on prerequisites already queued.
research_queue={techs.optics}; eq(call('research',{technology='lamp'}).queued,true); eq(added,'lamp')
-- A lone technology the full engine queue refuses waits for room instead of vanishing.
p.force.add_research=function() return false end
research_queue={techs.logistics,techs.optics,techs.lamp}
local waited=call('research',{technology='turrets'})
eq(table.concat(waited.queue,','),'logistics,optics,lamp'); eq(table.concat(waited.pending,','),'turrets')
call('research',{research_queue={}})
-- Views centre on any charted position; fogged chunks keep only map-drawn entities.
setmetatable(p.force,nil)
p.force.is_chunk_visible=function(_,chunk) return chunk.x==0 end
p.force.is_chunk_charted=function(_,chunk) return chunk.x<=1 and chunk.y==0 end
local enemy_force={name='enemy'}
local function ent(name,type,x,y,extra)
  local e={valid=true,name=name,type=type,position={x=x,y=y},force=p.force,prototype={collision_mask={layers={object=true}}},
    bounding_box={left_top={x=x-0.5,y=y-0.5},right_bottom={x=x+0.5,y=y+0.5}}}
  for k,v in pairs(extra or {}) do e[k]=v end
  return e
end
local neutral={name='neutral'}
local world={
  ent('boiler','boiler',40.5,2.5,{health=100,max_health=200,get_fuel_inventory=function() return {get_contents=function() return {{name='coal',count=49}} end} end}),
  ent('small-biter','unit',41,3,{force=enemy_force}),
  ent('spitter-spawner','unit-spawner',44,6,{force=enemy_force,health=335,max_health=350}),
  ent('copper-ore','resource',42.5,1.5,{force=neutral,amount=100}),
  ent('copper-ore','resource',43.5,1.5,{force=neutral,amount=50}),
  ent('iron-ore','resource',45.5,1.5,{force=neutral,amount=70}),
}
p.surface.find_entities_filtered=function(f)
  local out={}
  for _,e in ipairs(world) do
    local ok=(not f.type or f.type==e.type) and (not f.name or f.name==e.name)
    if f.area then ok=ok and e.position.x>=f.area.left_top.x and e.position.x<=f.area.right_bottom.x and e.position.y>=f.area.left_top.y and e.position.y<=f.area.right_bottom.y end
    if f.position then local r=(f.radius or 0)+0.2; ok=ok and math.abs(e.position.x-f.position.x)<=r and math.abs(e.position.y-f.position.y)<=r end
    if ok then out[#out+1]=e end
  end
  return out
end
p.surface.find_tiles_filtered=function() return {{position={x=46.5,y=1.5}}} end
fails(function() call('observe',{position={x=100,y=0}}) end,'charted chunk')
local remote=call('observe',{position={x=42,y=2},radius=8,resources='none'})
local seen={}; for _,e in ipairs(remote.entities) do seen[e.name]=true end
eq(seen.boiler,true); eq(seen['spitter-spawner'],true); eq(seen['small-biter'],nil)
local scan=call('observe',{scope='scan',area={left_top={x=40,y=0},right_bottom={x=48,y=8}},fields={'hp','fuel'},ore='runs'})
eq(scan.total,2); eq(scan.entities[1].name,'boiler'); eq(scan.entities[1].hp,'100/200'); eq(scan.entities[1].fuel,'coal*49')
-- The spawner sits in a charted but fogged chunk: its live health stays hidden.
eq(scan.entities[2].hp,nil); eq(scan.entities[2].fuel,nil)
world[#world+1]=ent('medium-worm-turret','turret',10,3,{force=enemy_force,health=90,max_health=100,prototype={attack_parameters={range=30}}})
local worm=call('observe',{scope='scan',area={left_top={x=8,y=0},right_bottom={x=12,y=8}},fields={'hp','range'}}).entities[1]
eq(worm.hp,'90/100'); eq(worm.range,30)
table.remove(world)
eq(scan.ore.legend.C,'copper-ore'); eq(scan.ore.legend.I,'iron-ore'); eq(scan.ore.rows[1].y,1)
eq(scan.ore.rows[1].runs,'C:42..43 I:45..45')
local grid=call('observe',{scope='scan',area={left_top={x=42,y=0},right_bottom={x=48,y=7}},type='unit-spawner',ore='grid'})
eq(grid.total,1); eq(grid.ore.origin.x,42); eq(grid.ore.rows[2].row,'CC.I~.'); eq(grid.ore.rows[6].row,'.##...')
eq(grid.ore.totals[1].amount,150)
eq(call('observe',{scope='scan',position={x=44,y=4},radius=3}).entities[1].name,'spitter-spawner')
fails(function() call('observe',{scope='scan',fields={'bogus'}}) end,'unknown field')
-- positions picks just the entities on those tiles; views reject arguments they would ignore.
local picked=call('observe',{scope='scan',positions={{x=40.5,y=2.5},{x=42.5,y=1.5},{x=40.5,y=2.5}},type='boiler'})
eq(picked.total,1); eq(picked.entities[1].name,'boiler')
fails(function() call('observe',{scope='scan',positions={{x=40.5,y=2.5}},radius=4}) end,'positions replaces')
fails(function() call('observe',{scope='grid',positions={{x=40.5,y=2.5}}}) end,'unknown argument positions for grid; valid: area, platform, position, radius')
fails(function() call('observe',{fields={'hp'}}) end,'unknown argument fields for observe')
-- Grid: one character per tile, legend for every character used; hidden units stay out.
world[#world+1]=ent('transport-belt','transport-belt',47.5,2.5,{direction=4})
world[#world+1]=ent('underground-belt','underground-belt',47.5,3.5,{direction=4,belt_to_ground_type='input'})
local g=call('observe',{scope='grid',area={left_top={x=40,y=0},right_bottom={x=48,y=8}}})
eq(g.origin.x,40); eq(#g.rows,8); eq(g.ruler,'|       ')
eq(g.rows[2].row,'..cc.i~.'); eq(g.rows[3].row,'B......>'); eq(g.rows[4].row,'.......U'); eq(g.rows[7].row,'...NN...')
eq(g.legend.c,'copper-ore'); eq(g.legend.U,'underground-belt input'); eq(g.legend.B,'boiler')
table.remove(world); table.remove(world)
-- rates and bottleneck travel as observe scopes and validate their selection.
fails(function() call('observe',{scope='rates'}) end,'area or positions')
fails(function() call('observe',{scope='bottleneck',area={left_top={x=0,y=0},right_bottom={x=500,y=1}}}) end,'at most 192x192')
fails(function() call('observe',{scope='rates',per='hour',area={left_top={x=0,y=0},right_bottom={x=1,y=1}}}) end,'per must be')
-- construct defaults to the last paste and reports missing items in status.
fails(function() call('construct',{}) end,'no earlier paste')
storage.agent_harness.last_paste={[1]={left=40,top=0,right=41,bottom=1}}
local g={valid=true,type='entity-ghost',ghost_name='lab',position={x=40.5,y=0.5},direction=0,force=p.force,quality={name='normal'},
  ghost_prototype={items_to_place_this={{name='lab',count=1}}}}
p.surface.find_entities_filtered=function(f) if f.type=='tree' or (type(f.type)=='table' and f.type[1]~='entity-ghost') or f.radius then return {} end eq(f.area.left_top.x,39.5); return {g} end
main=inv(); p.position={x=40,y=3}
eq(call('construct',{}).total,1)
do local cb=call('status').active.bounds; eq(cb.left,39.5); eq(cb.top<=0.5,true); eq(cb.right>=41,true) end
advance(1)
local done=call('status').last
eq(done.kind,'construct'); eq(done.outcome,'incomplete'); eq(done.missing.lab,1); eq(done.built,0)
-- An area with nothing to build or mine completes at once, so plans continue.
p.surface.find_entities_filtered=function() return {} end
local empty=call('construct',{}); eq(empty.total,0); eq(empty.outcome,'nothing_to_do')
eq(storage.agent_harness.active[1],nil); eq(call('status').last.outcome,'nothing_to_do'); eq(call('status').last.built,0)
-- kite walks and shoots in one tick: back away from close units, focus the
-- nest when units sit in the band, and finish clear with kills reported.
p.position={x=0,y=0}; p.force.is_chunk_visible=function() return true end
p.character.health,p.character.max_health,p.character.type=250,250,'character'
local magazines=10
p.get_inventory=function() return {get_item_count=function() return magazines end,get_contents=function() return {} end} end
game.forces={p.force,enemy_force,enemy=enemy_evolution}
local biter={valid=true,type='unit',name='small-biter',position={x=5,y=0},force=enemy_force}
local nest={valid=true,type='unit-spawner',name='biter-spawner',position={x=0,y=10},force=enemy_force}
local foes={biter,nest}
p.surface.find_entities_filtered=function() local out={}; for _,e in ipairs(foes) do if e.valid then out[#out+1]=e end end; return out end
call('kite',{})
advance(1)
eq(p.walking_state.walking,true); eq(p.walking_state.direction,12) -- west, away from the biter
eq(p.shooting_state.position,biter.position)
biter.position={x=9,y=0}; advance(6)
eq(p.shooting_state.position,nest.position); eq(p.walking_state.walking,false)
runtime.on_event{name=11,tick=tick,entity=biter,cause=p.character}
biter.valid=false; magazines=8; advance(1)
eq(p.shooting_state.position,nest.position)
nest.valid=false; advance(1)
local kited=call('status').last
eq(kited.kind,'kite'); eq(kited.outcome,'clear'); eq(kited.kills,1); eq(kited.ammo_used,2); eq(p.shooting_state.state,0)
foes={{valid=true,type='unit',name='small-biter',position={x=3,y=0},force=enemy_force}}
call('kite',{}); p.character.health=90; advance(1)
do
local low=call('status').last
eq(low.outcome,'low_health'); eq(low.why,'health 36% fell below min_health 40%'); eq(low.ammo_left,8); eq(low.enemies_left,1)
-- Request #57: with a retreat point, low health walks there while still
-- firing at the nearest unit, and ends retreated, saying why.
p.character.health=250
call('kite',{retreat={x=-20,y=0}}); p.character.health=90; advance(1)
eq(call('status').active.kind,'kite')
eq(p.walking_state.walking,true); eq(p.walking_state.direction,12) -- west, toward the retreat point
eq(p.shooting_state.state,1); eq(p.shooting_state.position.x,3) -- still firing at the biter
p.position={x=-18,y=0}; advance(1)
local back=call('status').last
eq(back.outcome,'retreated'); eq(back.retreated_from,'low_health'); eq(back.ammo_left,8)
eq(back.why,'health 36% fell below min_health 40%; retreating to (-20,0)')
p.position={x=0,y=0}; p.character.health=250
-- move_to combat: the combat channel fires while walking and ends with the walk.
local walk=call('move_to',{position={x=6,y=0},pathfind=false,combat=true})
eq(walk.combat.auto,true); eq(walk.combat.radius,20); eq(walk.combat.ammo,8)
eq(storage.agent_harness.combat[1].auto,true)
p.position={x=6,y=0}; advance(2)
eq(call('status').last.outcome,'arrived')
eq(storage.agent_harness.combat[1],nil); eq(storage.agent_harness.last_combat[1].outcome,'move_ended')
fails(function() call('move_to',{position={x=6,y=0},combat=40}) end,'combat radius')
end
magazines=0; fails(function() call('kite',{}) end,'no ammunition')
fails(function() call('move_to',{position={x=1,y=0},combat=true}) end,'combat needs ammunition')
-- Poles: a placed pole wires into every other network in reach; wire joins
-- or splits two reachable poles; power summarises networks in an area.
defines.wire_connector_id={pole_copper=5}; defines.entity_status={working=1,no_power=2,low_power=3}
defines.flow_precision_index={five_seconds=0,one_minute=1}
local world={}
local function dist(a,b) return ((a.x-b.x)^2+(a.y-b.y)^2)^0.5 end
local function pole(x,id)
  local e={valid=true,type='electric-pole',name='small-electric-pole',position={x=x,y=0.5},force=p.force,surface=p.surface,unit_number=100+x,
    electric_network_id=id,quality={name='normal'},prototype={get_max_wire_distance=function() return 7.5 end},links={}}
  local c=setmetatable({owner=e},{__index=function(_,k)
    if k=='connections' then local out={}; for o in pairs(e.links) do out[#out+1]={target=o.connector} end; return out end end})
  e.connector=c
  c.can_wire_reach=function(o) return dist(e.position,o.owner.position)<=7.5 end
  c.is_connected_to=function(o) return e.links[o.owner]==true end
  c.connect_to=function(o,reach_check)
    eq(reach_check,false)
    local old=o.owner.electric_network_id
    for _,q in ipairs(world) do if q.electric_network_id==old then q.electric_network_id=e.electric_network_id end end
    e.links[o.owner]=true; o.owner.links[e]=true; return true
  end
  c.disconnect_from=function(o) e.links[o.owner]=nil; o.owner.links[e]=nil; o.owner.electric_network_id=9; return true end
  e.get_wire_connector=function() return c end
  e.electric_network_statistics={input_counts={['assembling-machine-1']=1},output_counts={['steam-engine']=1},
    get_flow_count=function(f) return f.category=='input' and 1250 or 5000 end}
  world[#world+1]=e
  return e
end
p.surface.find_entities_filtered=function(f)
  local out={}
  for _,e in ipairs(world) do
    local ok=e.valid and (not f.type or e.type==f.type) and (not f.name or e.name==f.name)
    if f.radius then ok=ok and dist(e.position,f.position)<=f.radius end
    if f.area then ok=ok and e.position.x>=f.area.left_top.x and e.position.x<=f.area.right_bottom.x end
    if ok then out[#out+1]=e end
  end
  return out
end
p.position={x=5,y=3}; p.force.is_chunk_visible=function() return true end
local a,b,c2,d=pole(0.5,1),pole(6.5,1),pole(10.5,2),pole(20.5,3)
a.links[b]=true; b.links[a]=true
local poles=stack('small-electric-pole',3); poles.prototype.place_result={type='electric-pole',name='small-electric-pole'}
main={poles}; main.find_item_stack=function() return poles end
main.get_item_count=function() return poles.valid_for_read and poles.count or 0 end
p.cursor_stack=stack(nil,0); p.can_build_from_cursor=function() return true end
p.build_from_cursor=function(args)
  p.cursor_stack.count=p.cursor_stack.count-1; p.cursor_stack.valid_for_read=p.cursor_stack.count>0
  local new=pole(args.position.x,1) -- the engine's own auto-connect joined network 1
  new.links[b]=true; b.links[new]=true
end
local pb=call('build',{item='small-electric-pole',position={x=4.5,y=0.5}})
eq(pb.consumed,1); eq(pb.networks_joined,1); eq(c2.electric_network_id,1); eq(d.electric_network_id,3)
-- wire: both poles in reach or, by remote view (2.0), ours in a visible chunk; a wire long enough.
eq(call('wire',{from={x=10.5,y=0.5},to={x=6.5,y=0.5}}).already,nil)
eq(call('wire',{from={x=10.5,y=0.5},to={x=6.5,y=0.5}}).already,true)
fails(function() call('wire',{from={x=10.5,y=0.5},to={x=20.5,y=0.5}}) end,'does not reach')
fails(function() call('wire',{from={x=10.5,y=0.5},to={x=10.5,y=0.5}}) end,'same pole')
local cut=call('wire',{from={x=6.5,y=0.5},to={x=10.5,y=0.5},disconnect=true})
eq(cut.disconnected,true); eq(cut.split,true)
p.can_reach_entity=function(e) return e~=d end
fails(function() call('wire',{from={x=10.5,y=0.5},to={x=20.5,y=0.5}}) end,'does not reach')
p.can_reach_entity=function() return true end
-- power: per-network poles and kW, unpowered and unconnected machines.
local function machine(x,id,status)
  local e={valid=true,type='assembling-machine',name='assembling-machine-1',position={x=x,y=2},force=p.force,
    electric_network_id=id,status=status,prototype={electric_energy_source_prototype={}}}
  world[#world+1]=e
end
machine(2,1,defines.entity_status.no_power); machine(3,1,defines.entity_status.working); machine(30,nil,nil)
local pw=call('observe',{scope='power',area={left_top={x=-1,y=-5},right_bottom={x=40,y=5}}})
eq(#pw.networks,3); eq(pw.networks[1].id,1); eq(pw.networks[1].poles,3); eq(pw.networks[1].unpowered,1)
eq(pw.networks[1].production_kw,300); eq(pw.networks[1].consumption_kw,75); eq(pw.networks[1].producers[1].name,'steam-engine')
eq(#pw.unpowered,2); eq(pw.unpowered[2].status,'unconnected'); eq(pw.unpowered_total,nil)
eq(#call('observe',{scope='power',area={left_top={x=-1,y=-5},right_bottom={x=40,y=5}},limit=1}).unpowered,1)
-- A pole the engine left unconnected (its own network) joins every network in reach: no orphans.
p.build_from_cursor=function(args)
  p.cursor_stack.count=p.cursor_stack.count-1; p.cursor_stack.valid_for_read=p.cursor_stack.count>0
  pole(args.position.x,7)
end
p.position={x=14,y=3}; local orphan=call('build',{item='small-electric-pole',position={x=15.5,y=0.5}}); p.position={x=5,y=3}
eq(orphan.networks_joined,2); eq(d.electric_network_id,world[#world].electric_network_id); eq(c2.electric_network_id,world[#world].electric_network_id)
-- Poles built in one tick still report one stale network id; wires decide.
-- A pole next to an unwired pole of the "same" network still joins it.
p.build_from_cursor=function(args)
  p.cursor_stack.count=p.cursor_stack.count-1; p.cursor_stack.valid_for_read=p.cursor_stack.count>0
  pole(args.position.x,d.electric_network_id)
end
poles.count=2; poles.valid_for_read=true
local lone=pole(30.5,d.electric_network_id)
p.position={x=27,y=3}
eq(call('build',{item='small-electric-pole',position={x=26.5,y=0.5}}).networks_joined,2) -- d's group and the lone pole
eq(world[#world].links[lone],true)
p.position={x=5,y=3}
-- Map view (remote controller): p.position follows the camera, so movement,
-- reach and building act on the character entity instead.
defines.build_check_type={manual=1}
local body=p.character
body.position={x=0,y=0}; body.build_distance=10; body.reach_distance=10; body.surface=p.surface
body.can_reach_entity=function() return true end
p.controller_type=defines.controllers.remote; p.position={x=900,y=900}; p.walking_state=nil
call('walk',{direction='east',ticks=1}); advance(1)
eq(body.walking_state.walking,true); eq(body.walking_state.direction,4); eq(p.walking_state,nil)
eq(call('status').position.x,0)
-- Status inventory reads come from the character, not the map-view player.
defines.entity_status=defines.entity_status or {working=1}
defines.flow_precision_index.ten_minutes=2
p.force.get_item_production_statistics=function() return pollution_stats end
p.surface.find_entities_filtered=function() return {} end
local function slots(n,free) return setmetatable({count_empty_stacks=function() return free end},{__len=function() return n end,__index=function() return {valid_for_read=false} end}) end
body.get_main_inventory=function() return slots(80,7) end
p.get_main_inventory=function() return slots(10,1) end
local seen=call('status'); eq(seen.survey_error,nil); eq(seen.inv,'free=7/80')
local chests=stack('iron-chest',2); chests.prototype.place_result={type='container',name='iron-chest'}
chests.clear=function() chests.count=0; chests.valid_for_read=false end
body.get_main_inventory=function() return {find_item_stack=function() return chests end} end
p.cursor_stack=stack('iron-plate',5) -- the user's map-view cursor is left alone
local created
p.surface.find_entities_filtered=function() return {} end
p.surface.can_place_entity=function(a) eq(a.build_check_type,1); return a.position.x~=3 end
p.surface.create_entity=function(a)
  eq(a.player,p); created={valid=true,name=a.name,type='container',position=a.position,force=p.force}; return created
end
local mv=call('build',{item='iron-chest',position={x=2,y=0}})
eq(mv.consumed,1); eq(chests.count,1); eq(created.position.x,2); eq(p.cursor_stack.count,5)
fails(function() call('build',{item='iron-chest',position={x=3,y=0}}) end,'placement blocked')
eq(chests.count,1)
local ghost_chest={valid=true,name='entity-ghost',ghost_name='iron-chest',position={x=5,y=0},force=p.force}
ghost_chest.revive=function() ghost_chest.valid=false; return {},{valid=true,name='iron-chest',type='container',position={x=5,y=0},force=p.force} end
p.surface.find_entities_filtered=function(f) return f.ghost_name and ghost_chest.valid and {ghost_chest} or {} end
eq(call('build',{item='iron-chest',position={x=5,y=0}}).entity.position.x,5)
eq(ghost_chest.valid,false); eq(chests.valid_for_read,false)
-- Undergrounds: the exit is made when an unpaired entrance flowing the same
-- way sits upstream in range (regression: both ends came out as inputs);
-- opposite-flow undergrounds are skipped; an explicit type wins. Results
-- show the end, its flow and its partner. The same direct placement is used
-- outside map view, where cursor building made inputs only.
local ug_proto={name='underground-belt',type='underground-belt',max_underground_distance=5}
local ugs=stack('underground-belt',10); ugs.prototype.place_result=ug_proto
ugs.clear=function() ugs.count=0; ugs.valid_for_read=false end
body.get_main_inventory=function() return {find_item_stack=function() return ugs end} end
local entrance={valid=true,name='underground-belt',type='underground-belt',position={x=-3.5,y=-27.5},direction=12,belt_to_ground_type='input',force=p.force}
local reverse={valid=true,name='underground-belt',type='underground-belt',position={x=-4.5,y=-27.5},direction=4,belt_to_ground_type='output',force=p.force}
local made_ug
p.surface.find_entities_filtered=function(f)
  if f.type~='underground-belt' then return {} end
  local out={}
  for _,e in ipairs({entrance,reverse}) do if math.abs(e.position.x-f.position.x)<0.5 and math.abs(e.position.y-f.position.y)<0.5 then out[#out+1]=e end end
  return out
end
p.surface.can_place_entity=function() return true end
p.surface.create_entity=function(a)
  made_ug={valid=true,name=a.name,type='underground-belt',position=a.position,direction=a.direction,belt_to_ground_type=a.type or 'input',force=p.force}
  if made_ug.belt_to_ground_type=='output' then made_ug.neighbours=entrance; entrance.neighbours=made_ug end
  return made_ug
end
body.position={x=-4,y=-28}
local exit=call('build',{item='underground-belt',position={x=-5.5,y=-27.5},direction='west'})
eq(made_ug.belt_to_ground_type,'output'); eq(exit.entity.underground,'output'); eq(exit.entity.flow,'west'); eq(exit.entity.paired_with.x,-3.5)
entrance.neighbours=nil
eq(call('build',{item='underground-belt',position={x=-5.5,y=-27.5},direction='east'}).entity.unpaired,true) -- flowing the other way
eq(made_ug.belt_to_ground_type,'input')
eq(call('build',{item='underground-belt',position={x=-5.5,y=-27.5},direction='west',type='input'}).entity.underground,'input')
fails(function() call('build',{item='underground-belt',position={x=-5.5,y=-27.5},type='exit'}) end,'input|output')
p.controller_type=1; p.position={x=-4,y=-28}; p.get_main_inventory=body.get_main_inventory
entrance.neighbours=nil
eq(call('build',{item='underground-belt',position={x=-5.5,y=-27.5},direction='west'}).entity.underground,'output')
p.controller_type=defines.controllers.remote
p.physical_controller_type=defines.controllers.remote
fails(function() call('walk',{direction='east',ticks=1}) end,'living survival character')
p.physical_controller_type=1; p.controller_type=1
-- Ghosts go anywhere charted without items; blocked or unknown entries are
-- reported per index and construct defaults to the placed bounds.
defines.build_check_type.manual_ghost=2
prototypes.entity={['gun-turret']={items_to_place_this={{name='gun-turret',count=1}}},['big-rock']={}}
p.force.is_chunk_charted=function(_,c) return c.x<5 end
local ghosts={}
p.surface.can_place_entity=function(a) eq(a.build_check_type,2); eq(a.forced,true); return a.position.x~=40 end
p.surface.create_entity=function(a)
  eq(a.name,'entity-ghost'); eq(a.player,p); ghosts[#ghosts+1]=a.inner_name
  return {valid=true,position={x=a.position.x+1,y=a.position.y+1}}
end
local placed=call('place_ghosts',{entities={{name='gun-turret',position={x=100,y=100}},{name='gun-turret',position={x=40,y=0}},
  {name='big-rock',position={x=0,y=0}},{name='gun-turret',position={x=500,y=0}},{name='gun-turret',position={x=10,y=4},direction='east'}}})
eq(placed.placed,2); eq(#placed.failed,3); eq(placed.failed[1].index,2); eq(placed.failed[1].error,'placement blocked')
assert(placed.failed[2].error:find('not a placeable')); eq(placed.failed[3].error,'position is not charted')
eq(placed.bounds.left,11); eq(placed.bounds.bottom,101); eq(storage.agent_harness.last_paste[1].right,101)
-- A ghost goes over trees and rocks and marks them, though the engine's check
-- refuses them (shake3: "placement blocked by tree-08" from place_ghosts),
-- and over a stump, which stays until the build (out of reach here); anything
-- else in the footprint still refuses it.
do
  local can,find=p.surface.can_place_entity,p.surface.find_entities_filtered
  local tree={valid=true,type='tree',name='tree-08',minable=true,position={x=60.2,y=0.3}}
  tree.to_be_deconstructed=function() return tree.marked==true end
  tree.order_deconstruction=function(_,who) assert(who==nil or who==p); tree.marked=true; return true end
  local stump={valid=true,type='corpse',name='tree-02-stump',position={x=59.8,y=0}}
  stump.destroy=function() stump.valid=false end
  local chest={valid=true,type='container',name='wooden-chest',position={x=60,y=0}}
  local inside={tree,stump}
  p.surface.can_place_entity=function() return false end
  p.surface.find_entities_filtered=function(a)
    if a.type=='corpse' then return stump.valid and {stump} or {} end
    if a.area then return inside end
    return {}
  end
  ghosts={}
  local over=call('place_ghosts',{entities={{name='gun-turret',position={x=60,y=0}}}})
  eq(over.placed,1); eq(over.failed,nil); eq(ghosts[1],'gun-turret'); eq(over.obstacles_marked,1)
  eq(stump.valid,true); eq(tree.marked,true)
  inside={tree,chest}
  local refused=call('place_ghosts',{entities={{name='gun-turret',position={x=60,y=0}}}})
  eq(refused.placed,0); assert(refused.failed[1].error:find('wooden-chest',1,true),refused.failed[1].error)
  -- A force's own plant (a Gleba farm) is not an obstacle to mark.
  inside={{valid=true,type='plant',name='yumako-tree',minable=true,force=p.force,position={x=60,y=0}}}
  eq(call('place_ghosts',{entities={{name='gun-turret',position={x=60,y=0}}}}).placed,0)
  -- Tile buildability rules (shift06 14:26: asteroid collectors skipped "on
  -- verified empty floor"): the broken rule, not "nothing found" or the
  -- empty space the collector's front needs.
  inside={}
  local get_tile,find_tiles=p.surface.get_tile,p.surface.find_tiles_filtered
  local ground,space={layers={ground_tile=true}},{layers={empty_space=true}}
  prototypes.entity['asteroid-collector']={name='asteroid-collector',items_to_place_this={{name='asteroid-collector',count=1}},
    collision_box={left_top={x=-1.4,y=-1.4},right_bottom={x=1.4,y=1.4}},
    tile_buildability_rules={{area={left_top={x=-1.4,y=-0.4},right_bottom={x=1.4,y=1.4}},required_tiles=ground,colliding_tiles=space},
      {area={left_top={x=-1.4,y=-4.4},right_bottom={x=1.4,y=-0.6}},required_tiles=space,colliding_tiles=ground}}}
  p.surface.get_tile=function(_,y) return y>=-2 and {name='space-platform-foundation',prototype={collision_mask=ground}}
    or {name='empty-space',prototype={collision_mask=space}} end
  p.surface.find_tiles_filtered=function() return {{name='empty-space',prototype={collision_mask=space}}} end
  local ruled=call('place_ghosts',{entities={{name='asteroid-collector',position={x=60.5,y=0.5}}}})
  eq(ruled.placed,0); eq(ruled.failed[1].name,'asteroid-collector'); eq(ruled.failed[1].position.x,60.5)
  local err=ruled.failed[1].error
  assert(err:find('breaks its tile rule 2 facing north: tiles x 59..61, y %-4..%-1 need empty_space and must not be ground_tile; 6 of 12 do not %(space%-platform%-foundation at %(59,%-2%)%)'),err)
  assert(not err:find('needs landfill',1,true),err)
  p.surface.get_tile,p.surface.find_tiles_filtered=get_tile,find_tiles
  p.surface.can_place_entity,p.surface.find_entities_filtered=can,find
end
-- repeat stamps the list count times, shifted each time; failures carry their copy.
ghosts={}
local row=call('place_ghosts',{entities={{name='gun-turret',position={x=10,y=0}}},['repeat']={count=4,dx=10}})
eq(row.placed,3); eq(#row.copies,4); eq(row.failed[1].copy,4); eq(row.failed[1].error,'placement blocked')
eq(row.copies[2].position.x,20); eq(row.bounds.right,31); eq(storage.agent_harness.last_paste[1].right,31)
fails(function() call('place_ghosts',{entities={{name='gun-turret',position={x=0,y=0}}},['repeat']={count=2}}) end,'nonzero dx')
-- dry_run=true (dryrun.lua) places nothing and is a read: the running walk
-- goes on; a queue step with dry_run=true gets the same check.
do
  local get_tile=p.surface.get_tile
  p.surface.get_tile=function() return {name='grass-1',prototype={collision_mask={layers={ground_tile=true}}}} end
  local turret=prototypes.entity['gun-turret']
  local plain_turret={}
  for k,v in pairs(turret) do plain_turret[k]=v end
  turret.tile_width=2; turret.tile_height=2; turret.collision_mask={layers={object=true}}
  turret.collision_box={left_top={x=-0.7,y=-0.7},right_bottom={x=0.7,y=0.7}}
  ghosts={}
  call('walk',{direction='east',ticks=100})
  local dry=call('place_ghosts',{entities={{name='gun-turret',position={x=10,y=0}},{name='gun-turret',position={x=40,y=0}}},dry_run=true})
  eq(dry.dry_run,true); eq(dry.action,'place_ghosts'); eq(#ghosts,0,'a dry run places nothing')
  eq(dry.entities[1].index,2); eq(dry.entities[1].status,'blocked'); eq(dry.summary,'1 placeable, 1 blocked (of 2)')
  eq(call('status').active.kind,'walk','a dry run leaves the walk going')
  local shifted=call('place_ghosts',{entities={{name='gun-turret',position={x=10,y=0}}},['repeat']={count=4,dx=10},dry_run=true})
  eq(shifted.checked,4); eq(shifted.entities[1].index,'4.1'); eq(#ghosts,0)
  fails(function() call('place_ghosts',{entities={{name='gun-turret',position={x=10,y=0}}},facing='east',dry_run=true}) end,'unknown argument facing for place_ghosts')
  fails(function() call('build',{item='gun-turret',position={x=3,y=0},dry_run='true'}) end,'dry_run must be true or false')
  eq(call('status').active.kind,'walk','a failed dry run stops nothing')
  -- A paste dry run checks where the blueprint lands (blueprints.lua plan, stubbed here); with an entry
  -- the game refuses now, a normal paste places nothing at all.
  local real_plan=runtime.paste_plan
  runtime.paste_plan=function(_,a)
    return {entities={{index=1,name='gun-turret',position={x=a.position.x,y=0},direction=0},{index=2,name='gun-turret',position={x=40,y=0},direction=0}},
      tiles={},slot='bp',mode='normal',origin_at={x=a.position.x,y=0},center_at={x=a.position.x,y=0}}
  end
  local pd=call('paste',{position={x=10,y=0},dry_run=true})
  eq(pd.action,'paste'); eq(pd.paste.slot,'bp'); eq(#ghosts,0); eq(pd.summary,'1 placeable, 1 blocked (of 2)')
  assert(pd.paste_note:find('all or nothing: with 1 entry the game refuses there now',1,true),pd.paste_note)
  local rp=call('paste',{position={x=10,y=0},['repeat']={count=2,dx=4},dry_run=true})
  eq(rp.checked,4); eq(rp.entities[#rp.entities].index,'2.2'); assert(rp.entities[#rp.entities].why:find('collides with planned #1.2',1,true))
  eq(call('paste',{position={x=10,y=0},dryrun=true}).action,'paste','dryrun is dry_run')
  runtime.paste_plan=real_plan
  call('stop',{})
  call('queue_submit',{steps={{action='place_ghosts',args={entities={{name='gun-turret',position={x=10,y=0}}},dry_run=true}}}})
  advance(3)
  eq(#ghosts,0,'a queued dry run places nothing')
  call('queue_cancel',{})
  -- Fluid ports before building: a chemical plant on sulfur opens one input per fluid, closes its outputs.
  local function c(dir,pos) return {flow_direction='input',direction=dir,connection_type='normal',positions=pos} end
  prototypes.entity['chemical-plant']={name='chemical-plant',type='assembling-machine',tile_width=3,tile_height=3,crafting_categories={chemistry=true},
    fluidbox_prototypes={{production_type='input',pipe_connections={c(0,{{x=-1,y=-1},{x=1,y=-1},{x=1,y=1},{x=-1,y=1}})}},
      {production_type='input',pipe_connections={c(0,{{x=1,y=-1},{x=1,y=1},{x=-1,y=1},{x=-1,y=-1}})}},
      {production_type='output',pipe_connections={c(8,{{x=-1,y=1},{x=-1,y=-1},{x=1,y=-1},{x=1,y=1}})}},
      {production_type='output',pipe_connections={c(8,{{x=1,y=1},{x=-1,y=1},{x=-1,y=-1},{x=1,y=-1}})}}}}
  prototypes.recipe=prototypes.recipe or {}
  prototypes.recipe.sulfur={name='sulfur',category='chemistry',ingredients={{type='fluid',name='water'},{type='fluid',name='petroleum-gas'}},products={{type='item',name='sulfur'}}}
  local pr=call('ports',{name='chemical-plant',position={x=10,y=0},recipe='sulfur'})
  eq(pr.position.x,10.5); eq(#pr.ports,2); eq(pr.ports[1].fluid,'water'); eq(pr.ports[1].joins.x,9.5); eq(pr.ports[1].joins.y,-1.5); eq(pr.ports[1].direction,'north')
  eq(pr.ports[2].fluid,'petroleum-gas'); eq(#pr.closed,2); eq(pr.recipe,'sulfur')
  eq(call('ports',{name='chemical-plant',position={x=10,y=0}}).note,'the recipe decides which ports open and the fluid of each: pass recipe')
  fails(function() call('ports',{name='chemical-plant',position={x=10,y=0},recipe='no-such'}) end,'unknown recipe no-such')
  p.surface.get_tile=get_tile
  prototypes.entity['gun-turret']=plain_turret
end
-- pole_route lays pole ghosts from A to B within wire reach, shifting a
-- blocked spot sideways, reusing a pole already on the line, and counting
-- what is held; dry_run only plans.
do
prototypes.entity['small-electric-pole']={name='small-electric-pole',type='electric-pole',items_to_place_this={{name='small-electric-pole',count=1}},max_wire_distance=7.5,
  collision_box={left_top={x=-0.15,y=-0.15},right_bottom={x=0.15,y=0.15}}}
prototypes.item['small-electric-pole']={place_result=prototypes.entity['small-electric-pole']}
local own_pole={valid=true,name='small-electric-pole',position={x=12.5,y=0.5},force=p.force}
p.surface.find_entities_filtered=function(f)
  if f.name=='small-electric-pole' and f.position and math.abs(f.position.x-12.5)<=1.1 and math.abs(f.position.y-0.5)<=1.1 then return {own_pole} end
  return {}
end
p.surface.can_place_entity=function(a) return not (a.position.x==18.5 and a.position.y==0.5) and not (a.position.x==18.5 and a.position.y==1.5) end
p.get_main_inventory=function() return {get_item_count=function() return 3 end} end
local plan=call('pole_route',{from={x=0.5,y=0.5},to={x=30.5,y=0.5},dry_run=true})
eq(plan.spacing,7); eq(plan.poles,5); eq(plan.reused,1); eq(plan.failed,nil); eq(plan.short,2); eq(plan.held,3)
-- 30 tiles at spacing 7 is 5 even legs of 6; the pole at 12.5 is reused.
eq(plan.positions[1].x,0.5); eq(plan.positions[2].x,6.5); eq(plan.positions[3].x,18.5); eq(plan.positions[3].y,-0.5) -- shifted past the blocked tiles
eq(plan.positions[4].x,24.5); eq(plan.positions[5].x,30.5)
ghosts={}
local laid=call('pole_route',{from={x=0.5,y=0.5},to={x=30.5,y=0.5}})
eq(laid.placed,5); eq(#ghosts,5); eq(ghosts[1],'small-electric-pole'); assert(laid.note:find('craft 2 more small-electric-pole',1,true))
fails(function() call('pole_route',{from={x=0,y=0},to={x=1,y=0},item='gun-turret'}) end,'must place an electric pole')
fails(function() call('pole_route',{from={x=0,y=0},to={x=1,y=0},spacing=9}) end,'beyond the wire reach')
end
-- belt_route plans around obstacles and places the line as ghosts, with
-- underground ends typed; dry_run only plans; missing items are counted.
prototypes.entity['transport-belt']={name='transport-belt',type='transport-belt',items_to_place_this={{name='transport-belt',count=1}},
  related_underground_belt={name='underground-belt',type='underground-belt',max_underground_distance=5}}
prototypes.entity['underground-belt']={name='underground-belt',type='underground-belt',items_to_place_this={{name='underground-belt',count=1}}}
local made={}
p.surface.find_entities_filtered=function() return {} end
p.surface.can_place_entity=function(a) return a.position.x~=3.5 end
p.surface.create_entity=function(a) made[#made+1]=a; return {valid=true,position=a.position} end
p.get_main_inventory=function() return {get_item_count=function(n) return n=='transport-belt' and 1 or 0 end} end
local plan=call('belt_route',{from={x=0,y=0},to={x=6,y=0},dry_run=true})
eq(plan.dry_run,true); eq(#made,0); eq(plan.missing['underground-belt'],2); eq(plan.entities,nil)
local routed=call('belt_route',{from={x=0,y=0},to={x=6,y=0}})
eq(routed.placed,routed.tiles); eq(routed.route,plan.route); eq(storage.agent_harness.last_paste[1].right,6.5)
local kinds={}
for _,a in ipairs(made) do if a.type then kinds[#kinds+1]=a.type..'@'..a.position.x end end
eq(table.concat(kinds,','),'input@0.5,output@5.5')
assert(call('place_ghosts',{entities={{name='transport-belt',position={x=0,y=0},type='input'}}}).failed[1].error:find('underground belts only',1,true))
-- pipe_route: the same flow for fluids; pipe-to-ground ends face their open
-- side (entrance back along the line, exit onward).
local function pipe_connection(direction,extra)
  local c={direction=direction,connection_type='normal',flow_direction='input-output',positions={{x=0,y=0},{x=0,y=0},{x=0,y=0},{x=0,y=0}}}
  for k,v in pairs(extra or {}) do c[k]=v end
  return c
end
prototypes.entity.pipe={name='pipe',type='pipe',items_to_place_this={{name='pipe',count=1}},
  fluidbox_prototypes={{pipe_connections={pipe_connection(0),pipe_connection(4),pipe_connection(8),pipe_connection(12)},volume=100}}}
prototypes.entity['pipe-to-ground']={name='pipe-to-ground',type='pipe-to-ground',items_to_place_this={{name='pipe-to-ground',count=1}},
  fluidbox_prototypes={{pipe_connections={pipe_connection(0),pipe_connection(8,{connection_type='underground',max_underground_distance=10})},volume=100}}}
made={}
p.get_main_inventory=function() return {get_item_count=function(n) return n=='pipe' and 1 or 0 end} end
local piped=call('pipe_route',{from={x=0,y=0},to={x=6,y=0},dry_run=true})
eq(piped.dry_run,true); eq(#made,0); eq(piped.missing['pipe-to-ground'],2); eq(piped.missing.pipe,piped.items.pipe-1); eq(piped.placed,nil)
local laid=call('pipe_route',{from={x=0,y=0},to={x=6,y=0},details=true})
eq(laid.placed,laid.tiles); eq(laid.route,piped.route); eq(#laid.entities,laid.tiles); eq(storage.agent_harness.last_paste[1].right,6.5)
kinds={}
for _,a in ipairs(made) do if a.inner_name=='pipe-to-ground' then kinds[#kinds+1]=a.direction..'@'..a.position.x end end
eq(#kinds,2); assert(kinds[1]:match('^12@') and kinds[2]:match('^4@'),table.concat(kinds,','))
fails(function() call('pipe_route',{from={x=0,y=0},to={x=6,y=0},lane='left'}) end,'unknown argument lane for pipe_route')
-- scan fields=fluids: contents and connections of each fluidbox.
local pump={valid=true,name='offshore-pump',type='offshore-pump',position={x=0.5,y=0.5},force=p.force,surface=p.surface,
  fluidbox={{name='water',amount=100},get_capacity=function() return 100 end,get_pipe_connections=function()
    return {{flow_direction='output',connection_type='normal',position={x=0.5,y=0.5},target_position={x=0.5,y=-0.5},
      target={object_name='LuaFluidBox',owner={name='pipe',type='pipe',position={x=0.5,y=-0.5}}}}} end}}
p.surface.find_entities_filtered=function() return {pump} end
eq(call('observe',{scope='scan',area={left_top={x=0,y=0},right_bottom={x=1,y=1}},fields='fluids'}).entities[1].fluids,'water 100/100 out 0.5,-0.5=pipe')
p.surface.find_entities_filtered=function() return {} end
-- Unknown arguments fail loudly with the valid keys; cancel_craft takes a recipe.
fails(function() call('walk',{direction='east',tick=5}) end,'unknown argument tick for walk; valid: direction, ticks')
fails(function() call('queue_submit',{steps={{action='walk',args={dir='east'}}}}) end,'unknown argument dir for walk')
local cancels={}
p.crafting_queue={{index=1,recipe='copper-cable',count=12,prerequisite=true},{index=2,recipe='lab',count=5},{index=3,recipe='lab',count=4}}
p.cancel_crafting=function(c) cancels[#cancels+1]=c.index..':'..c.count end
eq(call('cancel_craft',{recipe='lab',count=6}).cancelled,6); eq(table.concat(cancels,','),'3:4,2:2')
fails(function() call('cancel_craft',{recipe='iron-chest'}) end,'no queued crafts')
-- Status shows the hand-crafting queue and the time it still needs.
p.force.recipes={lab={energy=2},['copper-cable']={energy=0.5}}
p.character.character_crafting_speed_modifier=0; p.force.manual_crafting_speed_modifier=0; p.crafting_queue_progress=0.5
eq(call('status').crafting,'9 items, ~24s left, head=copper-cable x12')
-- inspect shows an inserter's pickup/drop tiles with what stands there, and
-- a fluid entity's connection points: where each joins, its flow, its partner.
do
local belt={valid=true,name='transport-belt',type='transport-belt',position={x=2.5,y=1.5},force=p.force}
local ins={valid=true,name='inserter',type='inserter',position={x=2.5,y=0.5},force=p.force,direction=0,health=150,max_health=150,
  pickup_position={x=2.5,y=-0.5},drop_position={x=2.5,y=1.7},get_inventory=function() return nil end,get_fluid_contents=function() return {} end}
ins.surface={find_entities_filtered=function(f) return f.position.y==1.7 and {belt} or {} end}
local pump={valid=true,name='offshore-pump',type='offshore-pump',position={x=10.5,y=0.5},force=p.force,direction=4,health=150,max_health=150,
  get_inventory=function() return nil end,get_fluid_contents=function() return {water=0} end}
local joined={valid=true,name='pipe',position={x=9.5,y=0.5}}
pump.fluidbox={{name='water',amount=0},get_pipe_connections=function(i)
  return {{position={x=10.5,y=0.5},target_position={x=9.5,y=0.5},flow_direction='output',connection_type='normal',target={object_name='LuaFluidBox',owner=joined}}}
end,get_capacity=function() return 100 end}
p.position={x=5,y=0}; p.can_reach_entity=function() return true end
p.surface.find_entities_filtered=function(f)
  if f.position and f.position.x==2.5 then return {ins} elseif f.position and f.position.x==10.5 then return {pump} end
  return {}
end
local seen=call('inspect',{position=ins.position})
eq(seen.pickup.y,-0.5); eq(seen.drop.y,1.5); eq(seen.io,'2.5,-0.5 -> 2.5,1.7 transport-belt')
local fc=call('inspect',{position=pump.position}).fluid_connections
eq(#fc,1); eq(fc[1].flow,'output'); eq(fc[1].at.x,10.5); eq(fc[1].joins.x,9.5); eq(fc[1].joins.y,0.5); eq(fc[1].direction,'west'); eq(fc[1].connected_to,'pipe'); eq(fc[1].fluid,'water')
eq(call('inspect',{position=ins.position}).fluid_connections,nil)
-- Any tile of a building picks it; an empty tile says what is near (shake3:
-- 23 of Gemini's inspect misses were a tile off a pole, inserter or belt).
;(function()
  local find=p.surface.find_entities_filtered
  local am={valid=true,name='assembling-machine-1',type='assembling-machine',position={x=20.5,y=0.5},half=1.5,force=p.force,direction=0,
    health=300,max_health=300,get_inventory=function() return nil end,get_fluid_contents=function() return {} end,get_recipe=function() return nil end}
  local pole={valid=true,name='small-electric-pole',type='electric-pole',position={x=24.5,y=0.5},half=0.5,force=p.force}
  local world={am,pole}
  -- Engine semantics: with radius, centres in the circle; without, boxes covering the point.
  p.surface.find_entities_filtered=function(f)
    local out={}
    for _,e in ipairs(world) do
      local dx,dy=math.abs(e.position.x-f.position.x),math.abs(e.position.y-f.position.y)
      if ((f.radius and (dx*dx+dy*dy)^0.5<=f.radius) or (not f.radius and dx<e.half and dy<e.half)) and (not f.name or f.name==e.name) then out[#out+1]=e end
    end
    return out
  end
  eq(call('inspect',{position={x=21.5,y=1.5}}).name,'assembling-machine-1')
  eq(call('inspect',{position={21.5,1.5}}).name,'assembling-machine-1') -- [x,y] as the engine takes it
  fails(function() call('inspect',{position={x=25.5,y=0.5}}) end,
    'entity not found at (25.5,0.5): nearest small-electric-pole (24.5,0.5) 1.0 tiles; target an entity\'s position as scan lists it (observe scope=scan position={x=25.5,y=0.5} radius=3)')
  fails(function() call('inspect',{position={x=30.5,y=0.5}}) end,'entity not found at (30.5,0.5): nothing within 3 tiles')
  world={pole,{valid=true,name='wooden-chest',type='container',position={x=24.5,y=0.5},half=0.5,force=p.force}}
  fails(function() call('inspect',{position={x=24.5,y=0.5}}) end,'ambiguous target: small-electric-pole and wooden-chest at (24.5,0.5); specify name or unit_number')
  -- An item on the ground on a chest's tile does not make the chest ambiguous
  -- (shake3: Grok's transfers until the item was picked up); alone, it is the target.
  local chest={valid=true,name='wooden-chest',type='container',position={x=24.5,y=0.5},half=0.5,force=p.force,get_inventory=function() return nil end,get_fluid_contents=function() return {} end}
  local item={valid=true,name='item-on-ground',type='item-entity',position={x=24.6,y=0.4},half=0.2,force=p.force,get_inventory=function() return nil end,get_fluid_contents=function() return {} end}
  world={chest,item}
  eq(call('inspect',{position={x=24.5,y=0.5}}).name,'wooden-chest')
  world={item}
  eq(call('inspect',{position={x=24.5,y=0.5}}).name,'item-on-ground')
  -- A flying robot or anything unselectable over a chest yields to the chest (Sol, shift08); name or unit_number
  -- still picks it, and alone it is the target.
  local robot={valid=true,name='logistic-robot',type='logistic-robot',position={x=24.55,y=0.45},half=0.3,force=p.force,unit_number=77,
    get_inventory=function() return nil end,get_fluid_contents=function() return {} end}
  local flash={valid=true,name='flash',type='simple-entity',position={x=24.5,y=0.5},half=0.2,force=p.force,prototype={selectable_in_game=false}}
  world={robot,chest,flash}
  eq(call('inspect',{position={x=24.5,y=0.5}}).name,'wooden-chest')
  eq(call('inspect',{position={x=24.5,y=0.5},unit_number=77}).name,'logistic-robot')
  eq(call('inspect',{position={x=24.5,y=0.5},name='logistic-robot'}).name,'logistic-robot')
  world={robot}
  eq(call('inspect',{position={x=24.5,y=0.5}}).name,'logistic-robot')
  -- A drill's drop tile and what it drops into (sapilot board #4).
  local drill={valid=true,name='burner-mining-drill',type='mining-drill',position={x=30,y=0},half=1,force=p.force,direction=0,
    drop_position={x=29.7,y=-1.3},drop_target=chest,get_inventory=function() return nil end,get_fluid_contents=function() return {} end}
  drill.surface={find_entities_filtered=function(f) return f.position.y==-1.3 and {chest} or {} end}
  world={drill}
  local seen=call('inspect',{position={x=30,y=0}})
  eq(seen.drop.x,29.5); eq(seen.drop.y,-1.5); eq(seen.drop_into,'wooden-chest'); eq(seen.io,'-> 29.7,-1.3 wooden-chest'); eq(seen.pickup_position,nil)
  -- Ore under a drill's footprint: inspect takes the drill, mine still means the ore
  -- (the ore here is not hand-mineable, so the error shows which was picked).
  drill.minable=true
  world={drill,{valid=true,name='iron-ore',type='resource',position={x=30.5,y=0.5},half=0.5,minable=false,force={name='neutral'}}}
  eq(call('inspect',{position={x=30.5,y=0.5}}).name,'burner-mining-drill')
  fails(function() call('mine',{position={x=30.5,y=0.5}}) end,'entity is not mineable')
  -- A roboport and a logistic chest: their logistic network and a roboport's own cell (Luna, 22:53: a coverage gap
  -- told apart from a busy fleet); a logistic chest outside every logistic area has none.
  local cell={owner={valid=true,position={x=20,y=0}},logistic_radius=25,construction_radius=55,charging_robots={},to_charge_robots={},
    charging_robot_count=0,to_charge_robot_count=0,stationed_logistic_robot_count=2,stationed_construction_robot_count=1}
  local net={network_id=12,cells={cell},all_logistic_robots=10,available_logistic_robots=2,all_construction_robots=5,available_construction_robots=1}
  local port={valid=true,name='roboport',type='roboport',position={x=20,y=0},half=2,force=p.force,logistic_cell=cell,logistic_network=net,
    get_inventory=function() return nil end,get_fluid_contents=function() return {} end}
  local box={valid=true,name='requester-chest',type='logistic-container',position={x=24.5,y=6.5},half=0.5,force=p.force,logistic_network=net,
    get_inventory=function() return nil end,get_fluid_contents=function() return {} end}
  local far={valid=true,name='passive-provider-chest',type='logistic-container',position={x=30.5,y=6.5},half=0.5,force=p.force,
    get_inventory=function() return nil end,get_fluid_contents=function() return {} end}
  world={port,box,far,chest}
  local ln=call('inspect',{position={x=20,y=0}}).logistic_network
  eq(ln.id,12); eq(ln.logistic_robots.working,8); eq(ln.port.stationed.logistic,2)
  eq(ln.line,'logistic #12: 1 roboport, logistic area (-5,-25)-(45,25), construction area (-35,-55)-(75,55); logistic robots 10: 2 idle, 8 working, 0 charging, 0 waiting to charge; construction robots 5: 1 idle, 4 working, 0 charging, 0 waiting to charge')
  eq(call('inspect',{position={x=24.5,y=6.5}}).logistic_network.id,12)
  eq(call('inspect',{position={x=30.5,y=6.5}}).logistic_network.none,'in no logistic network: no roboport\'s logistic area covers it')
  eq(call('inspect',{position={x=24.5,y=0.5}}).logistic_network,nil,'not on other entities')
  p.surface.find_entities_filtered=find
end)()
-- wait_until as a direct call: met at once returns met; otherwise a timed
-- action that ends met (checked every 10 ticks) or timed_out.
p.crafting_queue_size=0
eq(call('wait_until',{['until']='crafting_done'}).outcome,'met')
p.crafting_queue_size=2
local waiting=call('wait_until',{['until']='crafting_done',timeout=100})
eq(waiting.until_tick,game.tick+100); eq(waiting.condition,'crafting_done'); eq(waiting.saw,'2 crafts queued')
eq(call('status').active.kind,'wait_until'); eq(call('status').active.condition,'crafting_done')
advance(5); p.crafting_queue_size=0; advance(4); eq(call('status').active.kind,'wait_until')
advance(1); eq(call('status').active,false)
local waited=call('status').last; eq(waited.kind,'wait_until'); eq(waited.outcome,'met'); eq(waited.saw,'0 crafts queued')
prototypes.item['iron-plate']=prototypes.item['iron-plate'] or {}
p.get_main_inventory=function() return {get_item_count=function(f) return (f=='iron-plate' or type(f)=='table' and f.name=='iron-plate') and 3 or 0 end} end
call('wait_until',{['until']='item_count',item='iron-plate',at_least=10,timeout=30})
advance(31); waited=call('status').last; eq(waited.outcome,'timed_out'); eq(waited.saw,'iron-plate 3')
fails(function() call('wait_until',{['until']='nope'}) end,'until must be one of')
fails(function() call('wait_until',{['until']='crafting_done',timeout=0}) end,'timeout')
-- In a function: the main chunk is at Lua's 200-local limit.
;(function()
-- wait_until runs up to 15 minutes (54000 ticks).
p.crafting_queue_size=2
eq(call('wait_until',{['until']='crafting_done',timeout=54000}).until_tick,game.tick+54000)
fails(function() call('wait_until',{['until']='crafting_done',timeout=54001}) end,'timeout (1..54000 ticks) out of range')
-- wait_ticks is a direct timed action too.
local idle=call('wait_ticks',{ticks=5}); eq(idle.until_tick,game.tick+5)
eq(call('status').active.kind,'wait_ticks'); eq(call('status').last.outcome,'replaced')
advance(6); eq(call('status').active,false); eq(call('status').last.outcome,'duration_elapsed')
-- inspect is a read: anything in sight, no reach needed; in_reach says so.
p.can_reach_entity=function() return false end
local far=call('inspect',{position=ins.position}); eq(far.in_reach,false); eq(far.io,'2.5,-0.5 -> 2.5,1.7 transport-belt')
fails(function() call('rotate',{position=ins.position}) end,'out of reach')
p.can_reach_entity=function() return true end
-- build short of an item the hand-craft queue is making waits for it, then builds.
p.force.recipes={lab={products={{name='lab',amount=1}},energy=2}}
p.crafting_queue={{recipe='lab',count=1}}; p.crafting_queue_progress=0
local pending=call('build',{item='lab',position={x=1,y=0}})
eq(pending.awaiting_craft.item,'lab'); eq(pending.awaiting_craft.crafting,1)
eq(call('status').active.kind,'feed')
p.crafting_queue={}; advance(10)
-- The rerun build fails here (the fake inventory never received the lab).
eq(call('status').last.outcome,'failed')
-- Corpses: transfer takes their items (never mine_entity), and an emptied corpse goes.
defines.inventory.character_corpse=9
local loot=stack('iron-plate',20)
local slots=inv(loot); slots.is_empty=function() return not loot.valid_for_read end
local corpse={valid=true,name='character-corpse',type='character-corpse',position={x=2,y=2},force={name='neutral'}}
corpse.get_inventory=function(i) eq(i,9); return slots end
corpse.destroy=function() corpse.valid=false end
local bag=inv(stack(nil,0),stack(nil,0))
p.get_main_inventory=function() return bag end
p.surface.find_entities_filtered=function() return {corpse} end
local took=call('transfer',{position=corpse.position,direction='to_player'})
eq(took.transferred,20); eq(took.inventory,'character_corpse'); eq(took.corpse_removed,true); eq(corpse.valid,false)
end)()
end
-- Space Age spoilage in status: spoilable stacks grouped per item and quality,
-- stalest freshness first; nothing reported when nothing spoils.
do
  local normal,rare={name='normal'},{name='rare'}
  local function stack(name,count,spoiled,quality)
    return {valid_for_read=true,name=name,count=count,quality=quality or normal,spoil_percent=spoiled,
      prototype={get_spoil_ticks=function() return spoiled and 3600 or 0 end}}
  end
  local slots={stack('yumako',10,0.2),stack('iron-plate',50),stack('yumako',5,0.5),stack('jellynut',3,0.1,rare),{valid_for_read=false}}
  slots.valid=true
  local saved=p.get_main_inventory
  p.get_main_inventory=function() return setmetatable(slots,{__len=function() return 5 end}) end
  eq(call('status').spoiling,'yumako*15 50% jellynut@rare*3 90%')
  slots[1],slots[3],slots[4]=stack('coal',1),stack('coal',1),stack('coal',1)
  eq(call('status').spoiling,nil)
  p.get_main_inventory=saved
end
-- Human players (players.lua): described, answered without a character, and a failure stops nothing.
do
  local d=call('describe').actions
  eq(d.players~=nil and d.votes~=nil and d.vote~=nil and d.restore~=nil,true)
  eq(d.vote.kind,'mute, unmute, kick, ban or trust')
  game.players={p}
  local saved=p.character; p.character=nil
  eq(#call('players',{}).players,1)
  p.character=saved; call('walk',{direction='east',ticks=600})
  local ok=pcall(call,'vote',{kind='kick',player='nobody',reason='x'}); eq(ok,false)
  eq(call('status').active.kind,'walk'); call('stop',{})
  -- The operator reaches votes_pending, votes and vote_close through dispatch (tools/players.py, viewers.py).
  local open=runtime.dispatch{action='votes_pending',args={},operator=true}
  eq(#open.votes,0); eq(#runtime.dispatch{action='votes',args={},operator=true}.muted,0)
  eq(pcall(runtime.dispatch,{action='vote_close',args={id=99,outcome='failed'},operator=true}),false)
  game.players=nil
end
-- paste and blueprint_place take a mode (forced paste: blueprints.lua); an unknown argument still fails.
for _,action in ipairs({'paste','blueprint_place'}) do
  eq(pcall(runtime.check_args,action,{position={x=0,y=0},mode='forced'}),true)
  eq(pcall(runtime.check_args,action,{anchor='hub',mode='forced'}),true)
  eq(pcall(runtime.check_args,action,{position={x=0,y=0},forced=true}),false)
end
-- cargo (cargo.lua): a list or what a chest holds, weighed against a rocket's lift and slots; a read.
-- (A function of its own: this chunk is near Lua's 200 locals.)
;(function()
  local find,items,uc,quality,silo=p.surface.find_entities_filtered,prototypes.item,prototypes.utility_constants,prototypes.quality,prototypes.entity['rocket-silo']
  defines.inventory.chest=defines.inventory.chest or 1
  defines.inventory.rocket_silo_rocket=defines.inventory.rocket_silo_rocket or 21
  prototypes.item={thruster={weight=200000,stack_size=10},['cargo-bay']={weight=100000,stack_size=10},['iron-plate']={weight=1000,stack_size=100}}
  prototypes.utility_constants={rocket_lift_weight=1000000}
  prototypes.quality={normal={},rare={}}
  prototypes.entity['rocket-silo']={get_inventory_size=function() return 20 end}
  local w=call('cargo',{items={thruster=3,['cargo-bay']=5}})
  eq(w.total_kg,1100); eq(w.fewest,2); eq(w.rockets,2); eq(w.items[1].name,'thruster'); eq(w.lift,'1000 kg and 20 cargo slots a rocket')
  local q=call('cargo',{items={{name='iron-plate',count=50,quality='rare'}}})
  eq(q.items[1].quality,'rare'); eq(q.total_kg,50)
  local chest={valid=true,name='steel-chest',type='container',position={x=1.5,y=0.5},force=p.force}
  chest.get_inventory=function(i) eq(i,defines.inventory.chest)
    return {valid=true,get_contents=function() return {{name='iron-plate',count=1200,quality='normal'}} end} end
  p.surface.find_entities_filtered=function(f) if f.position then return {chest} end return {} end
  local c=call('cargo',{position={x=1.5,y=0.5}})
  eq(c.total_kg,1200); eq(c.rockets,2); eq(c.from.inventory,'chest'); eq(c.split[1].items,'iron-plate*1000')
  fails(function() call('cargo',{items={nope=1}}) end,'unknown item nope')
  fails(function() call('cargo',{items={thruster=0}}) end,'count of thruster out of range')
  fails(function() call('cargo',{}) end,'cargo takes items')
  fails(function() call('cargo',{items={thruster=1},position={x=1.5,y=0.5}}) end,'one of them')
  chest.get_inventory=function() return {valid=true,get_contents=function() return {} end} end
  fails(function() call('cargo',{position={x=1.5,y=0.5}}) end,'holds nothing in chest')
  p.surface.find_entities_filtered=find
  prototypes.item,prototypes.utility_constants,prototypes.quality,prototypes.entity['rocket-silo']=items,uc,quality,silo
end)()
print('runtime: '..assertions..' assertions passed')
