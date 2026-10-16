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
p.character.surface=p.surface
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
game={tick=tick,get_player=function(index) if index==1 then return p end end,forces={player=p.force,enemy=enemy_evolution},
  get_pollution_statistics=function() return pollution_stats end}
p.surface.index=1; p.surface.get_total_pollution=function() return 0 end; p.surface.get_chunks=function() return function() end end; p.surface.get_pollution=function() return 0 end
p.surface.find_entities_filtered=function() return {} end
local runtime=dofile('mod/agent-harness_0.1.0/runtime.lua')
local function call(action,args) return runtime.dispatch{action=action,args=args,player=1} end
assert(runtime.dispatch{operator=true,action='factory_digest',args={}}.scope:find('no new scan',1,true))
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
-- (near=false: the walk ends unreachable where nothing leads, naming the spot; without it the walk goes there, below)
eq(call('move_to',{position={x=10,y=10},near=false}).pathfinding,true)
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
  -- Its end is within build reach and has room to turn: named as a build spot (Grok, shift10 06:20).
  eq(gave.build_spot.x,6); eq(gave.build_spot_note,'(6,6) is reachable and within build reach of (10,10): 5.7 tiles (build reach 10)'); eq(gave.build_spot_squeeze,nil)
end
-- friction2 (Gemini's (-50,75) five times, each followed by a move_to to the spot the reply named; Haiku stood in reach
-- already and the exit stopped its && chain): by default the walk goes on to that spot once and ends arrived_near there.
p.position={x=0,y=4.8}
call('move_to',{position={x=10,y=10}})
runtime.on_event{name=10,id=#path_requests-1,path=nil}; runtime.on_event{name=10,id=#path_requests,path=nil}
for _=1,3 do runtime.on_event{name=10,id=#path_requests,path=nil} end
advance(1)
runtime.on_event{name=10,id=#path_requests,path={{position={x=0,y=4.8}},{position={x=6,y=6}}}}
advance(1)
eq(call('status').active.kind,'move_to')
runtime.on_event{name=10,id=#path_requests-1,path={{position={x=0,y=4.8}},{position={x=6,y=6}}}}
runtime.on_event{name=10,id=#path_requests,path={{position={x=0,y=4.8}},{position={x=6,y=6}}}}
p.position={x=6,y=6}; advance(2)
do
  local near=call('status').last
  eq(near.outcome,'arrived_near'); eq(near.target.x,10); eq(near.build_spot,nil)
  eq(near.near_walk,'no path led to (10,10) (no path for the character to (10,10) on the tile, half- or quarter-tile grid); walked to (6,6) instead, ended 5.7 tiles from it, a spot within build reach of it the give-up found')
end
fails(function() call('move_to',{position={x=10,y=10},near='yes'}) end,'near must be true or false')
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
  -- alerts without brief runs as the brief status (round1650d: Astra's {inventory, machines: false, alerts: false})
  local nb=call('status',{alerts=true,peek=true})
  eq(nb.brief,true); assert(tostring(nb.corrected):find('alerts goes with brief: brief=true',1,true),tostring(nb.corrected))
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
local last
do
  -- (The ore lands in the inventory: counted here for last.moved.)
  local ores_held=0
  local item_count=p.get_item_count
  p.get_item_count=function(n) if n=='iron-ore' then return ores_held end return item_count(n) end
  p.mine_entity=function(e) e.amount=e.amount-1; ores_held=ores_held+1; if e.amount==0 then e.valid=false end; return false end
  local mined=call('mine',{position=ore.position,ticks=600})
  -- A move over time (operator 08:01): moved 0 so far, timed, the line now.
  eq(mined.moved,0); assert(mined.timed,'timed')
  eq(call('status').active.target.name,'iron-ore')
  advance(119); eq(ore.amount,3); advance(1); eq(ore.amount,2)
  advance(120); eq(ore.amount,1)
  advance(120); eq(ore.valid,false)
  last=call('status').last; eq(last.outcome,'target_mined'); eq(last.mined,3)
  eq(last.moved,3); assert(last.inv:find('held: iron-ore 3',1,true),last.inv)
  p.get_item_count=item_count
  p.mine_entity=function(e) e.amount=e.amount-1; if e.amount==0 then e.valid=false end; return false end
end
-- mine {count} (Grok, d15 06:20: 200 coal took a 50-round queue at 600 ticks a call): units of a resource in one call;
-- a tile mined out goes on with the nearest tile of it in reach; the count reached ends it mined.
do
  local ore2={valid=true,name='iron-ore',type='resource',position={x=2,y=0},force={name='neutral'},minable=true,amount=10,
    prototype=ore.prototype}
  ore.valid=true; ore.amount=2
  local kept_find=p.surface.find_entities_filtered
  p.surface.find_entities_filtered=function(f) if f.type=='resource' and f.name then local out={} for _,o in ipairs({ore,ore2}) do if o.valid then out[#out+1]=o end end return out end return {ore} end
  local r=call('mine',{position=ore.position,count=4})
  eq(r.count,4); eq(r.cycle_ticks,120); assert(r.until_tick>=tick+4*120,'time for the count')
  advance(240); eq(ore.valid,false); eq(call('status').active.kind,'mine')
  advance(240); eq(ore2.amount,8)
  last=call('status').last; eq(last.outcome,'mined'); eq(last.mined,4); eq(last.count,4)
  -- none of it left in reach: target_mined, short
  ore.valid=true; ore.amount=1; ore2.valid=false
  call('mine',{position=ore.position,count=3}); advance(120)
  last=call('status').last; eq(last.outcome,'target_mined'); eq(last.mined,1); eq(last.why,'mined 1 of 3: no iron-ore left in reach')
  ore.valid=true; ore.amount=3
  fails(function() call('mine',{position=ore.position,count=3,ticks=60}) end,'count and ticks')
  p.surface.find_entities_filtered=kept_find
  ore.valid=true; ore.amount=3
end
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
  'placement blocked by tree-02 (2.1,0.3), the character standing on the footprint (move off it first); it needs the tree mined first (mine it, or place_ghosts marks it and construct clears it)')
-- Someone else's character is named.
footprint={{valid=true,type='character',name='character',position={x=2,y=0.2},player={valid=true,name='pog-sol'}}}
fails(function() call('build',{item='wooden-chest',position={x=2,y=0}}) end,
  "placement blocked by pog-sol's character standing at (2.0,0.2) (ask them to move, or build elsewhere)")
p.character.type=nil; p.character.position=nil
eq(wood.count,3); eq(p.cursor_stack.valid_for_read,false)
footprint={}; tiles={{name='water',prototype={collision_mask={layers={water_tile=true}}}},{name='water',prototype={collision_mask={layers={water_tile=true}}}}}
fails(function() call('build',{item='wooden-chest',position={x=2,y=0}}) end,'placement blocked by tiles: water (needs landfill')
-- Sol, shift09 01:38: a build over its own ghost on tiles it cannot stand on (Gleba wetland) names the tiles, never
-- the ghost it would revive ("placement blocked by ghost medium-electric-pole" at the pole's own position).
wood.prototype.place_result.name='wooden-chest'
footprint={{valid=true,type='entity-ghost',ghost_name='wooden-chest',position={x=2,y=0}},{valid=true,type='tile-ghost',ghost_name='landfill',position={x=2.5,y=0.5}}}
tiles={{name='wetland-blue-slime',prototype={collision_mask={layers={water_tile=true,floor=true,resource=true}}}}}
do
  local ok,err=pcall(call,'build',{item='wooden-chest',position={x=2,y=0}})
  assert(not ok and tostring(err):find('placement blocked by tiles: wetland-blue-slime (needs landfill',1,true) and not tostring(err):find('ghost',1,true),tostring(err))
end
-- Lava (Sonnet, shift19): the tile first, not the research.
;(function()
  footprint={}
  tiles={{name='lava-hot',prototype={collision_mask={layers={lava_tile=true}}}}}
  local ok,err=pcall(call,'build',{item='wooden-chest',position={x=2,y=0}})
  assert(not ok and tostring(err):find('placement blocked by tiles: lava-hot (unbuildable: lava',1,true) and not tostring(err):find('shore',1,true),tostring(err))
end)()
-- On a platform (Astra, shift19): empty space under it holding foundation tile ghosts not built yet is said so.
;(function()
  p.surface.platform={name='Starling'}
  footprint={{valid=true,type='tile-ghost',ghost_name='space-platform-foundation',position={x=2.5,y=0.5}}}
  tiles={{name='empty-space',prototype={collision_mask={layers={empty_space=true}}}}}
  local ok,err=pcall(call,'build',{item='wooden-chest',position={x=2,y=0}})
  assert(not ok and tostring(err):find('placement blocked by tiles: empty-space under it, with tile ghosts of space-platform-foundation at (2,0) not built yet',1,true)
    and not tostring(err):find('shore',1,true),tostring(err))
  p.surface.platform=nil
end)()
-- Another entity's ghost on the footprint still blocks, and is named.
footprint={{valid=true,type='entity-ghost',ghost_name='iron-chest',position={x=2,y=0}}}
fails(function() call('build',{item='wooden-chest',position={x=2,y=0}}) end,'placement blocked by ghost iron-chest (2,0)')
wood.prototype.place_result.name=nil
footprint={}; tiles={{name='grass-1',prototype={collision_mask={layers={ground_tile=true}}}}}
fails(function() call('build',{item='wooden-chest',position={x=2,y=0}}) end,'placement blocked (nothing found in the footprint')
p.surface.find_tiles_filtered=nil
p.can_build_from_cursor=function() return true end
local placed
p.surface.find_entities_filtered=function() return placed and {placed} or {} end
p.build_from_cursor=function()
  p.cursor_stack.count=p.cursor_stack.count-1
  placed={valid=true,name='wooden-chest',type='container',position={x=2.5,y=0.5},force=p.force}
end
fails(function() call('build',{item='wooden-chest',position={x=20,y=0},walk=false}) end,'position is out of build reach: (20,0) is 20.0 tiles from the character at (0.0,0.0), build reach 10')
fails(function() call('build',{item='wooden-chest',position={x=40,y=0},walk=false}) end,'position is outside local visible area: (40,0) is 40.0 tiles from the character')
-- Out of reach by default (autowalk.lua): within 32 tiles a walk into build reach first; past them refused, naming the
-- call that walks.
;(function()
  local r=call('build',{item='wooden-chest',position={x=20,y=0}})
  eq(r.walking_for,'build'); eq(r.walking,'(20,0) is 20.0 tiles from you, build reach 10: walking into reach first (walk: false refuses instead)')
  eq(call('status').active.kind,'move_to'); eq(call('status').active.walking_for,'build'); call('stop',{})
  eq(call('status').last.not_made,'build was not made: the walk into reach of (20,0) ended stopped')
  -- The walk arrives within build reach: the build is made there; last names the walk and holds the build's reply.
  call('build',{item='wooden-chest',position={x=20,y=0}})
  p.position={x=12,y=0}; advance(2)
  local last=call('status').last
  eq(call('status').active,false); eq(last.kind,'build'); eq(last.outcome,'done'); eq(last.result.consumed,1)
  eq(last.walked,'walked from (0,0) to (12,0) first, into reach of (20,0)')
  wood.count=wood.count+1; p.position={x=0,y=0}; placed=nil
  -- As a queue step the step waits for the walk and the build, then the plan goes on.
  call('queue_submit',{steps={{action='build',args={item='wooden-chest',position={x=20,y=0}}},{action='wait_ticks',args={ticks=1}}}})
  advance(2)
  local q=call('queue_status',{history=2})
  eq(q.active.action,'build'); eq(call('status').active.walking_for,'build')
  p.position={x=12,y=0}; advance(4)
  q=call('queue_status',{history=2})
  eq(q.pending_count,0); eq(q.history[#q.history].action,'wait_ticks'); eq(q.history[#q.history-1].action,'build'); eq(q.history[#q.history-1].ok,true)
  wood.count=wood.count+1; p.position={x=0,y=0}; placed=nil
  fails(function() call('build',{item='wooden-chest',position={x=40,y=0}}) end,
    'position is outside local visible area: (40,0) is 40.0 tiles from the character at (0.0,0.0) (limit 32 tiles, in a visible chunk; move_to within 30 tiles first); 40.0 tiles is past the 32 a call walks by default: build {"item":"wooden-chest","position":{"x":40,"y":0},"walk":true} walks there first')
end)()
local built=call('build',{item='wooden-chest',position={x=2,y=0}})
eq(built.consumed,1); eq(built.entity.position.x,2.5); eq(built.entity.position.y,0.5)
eq(wood.count,2); eq(p.cursor_stack.valid_for_read,false); eq(built.closed_in,nil)
-- A build that closes the character in says so, naming what filled the last
-- gap (pathing.lua closed_by; Gemini, shift09: a placement trapped the character).
;(function()
  local closed_by=runtime.pathing.closed_by
  runtime.pathing.closed_by=function(_,_,half,list)
    eq(half,0.2); eq(list[1],placed)
    return {region={closed=true,tiles=10,x0=1,y0=1,x1=3,y1=3,by={'wooden-chest'}},gaps={placed}}
  end
  placed=nil
  local walled=call('build',{item='wooden-chest',position={x=2,y=0}})
  eq(walled.closed_in,'the character is closed in now where it stands (0,0): the last gap out was where wooden-chest (2.5,0.5) now stands; '..
    'the area (1,1)-(3,3) (about 10 tiles) has no gap the character (0.4 tiles wide) fits through; around it: wooden-chest; '..
    'mine {"position":{"x":2.5,"y":0.5}} takes wooden-chest back and opens a way out')
  runtime.pathing.closed_by=closed_by
  wood.count=2
end)()
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
-- The entries built before a failing one stay: the refusal says what they closed (friction2: Gemini's 19:25 batch failed
-- after 2 built, and those 2 had closed the last gap out with no word of it; the dry runs had named them).
;(function()
  local closed_by=runtime.pathing.closed_by
  runtime.pathing.closed_by=function(_,_,_,list)
    eq(#list,2)
    return {region={closed=true,tiles=6,x0=3,y0=-1,x1=7,y1=1,by={'wooden-chest'}},gaps={list[2]}}
  end
  wood.count=5
  fails(function() call('build',{item='wooden-chest',builds={{position={x=4,y=0}},{position={x=6,y=0}},{position={x=8,y=0}}}}) end,
    '; the character is closed in now where it stands (0,0): the last gap out was where wooden-chest (6.5,0.5) now stands; the area (3,-1)-(7,1)')
  runtime.pathing.closed_by=closed_by
  wood.count=3
end)()
-- Real place_ghosts: ghosts that, once built, close the character in where it stands, as the dry run says it of a plan
-- (friction2: Gemini's dry runs named the last gap out, the real calls said nothing). Walls and pipes stretch toward their
-- neighbours once built (the dry run's joined pieces); a gate opens for the character; ghosts 16+ tiles off are left out.
;(function()
  local closes_in,joined=runtime.pathing.closes_in,runtime.dryrun.joined_pieces
  local seen
  runtime.pathing.closes_in=function(_,start,half,boxes)
    seen=boxes; eq(start.x,p.position.x); eq(half,0.2)
    return {region={closed=true,tiles=2,x0=0,y0=0,x1=1,y1=1,by={'stone-wall'}},gaps={boxes[1]},around={boxes[1],boxes[2]}}
  end
  runtime.dryrun.joined_pieces=function(_,_,recs) eq(#recs,2); return {{0,0,1,1,'stone-wall',recs[1],ids={recs[1],recs[2]}}} end
  local function ghost(name,type_,x,y)
    return {valid=true,type='entity-ghost',ghost_type=type_,ghost_name=name,direction=0,position={x=x,y=y},
      bounding_box={left_top={x=x-0.29,y=y-0.29},right_bottom={x=x+0.29,y=y+0.29}},
      ghost_prototype={type=type_,collision_mask={layers={player=true,object=true}}}}
  end
  local here=p.position
  local note=runtime.ghosts_close_in(p,{ghost('stone-wall','wall',here.x+1,here.y),ghost('stone-wall','wall',here.x-1,here.y),
    ghost('gate','gate',here.x,here.y+1),ghost('stone-wall','wall',here.x+40,here.y)})
  eq(#seen,3,'two wall ghosts and one joined piece')
  eq(note,string.format('once built, these ghosts close the character in where it stands (%g,%g): the last gap out is where stone-wall ghost (%g,%g) stands; '..
    'the area (0,0)-(1,1) (about 2 tiles) has no gap the character (0.4 tiles wide) fits through; around it: stone-wall',here.x,here.y,here.x+1,here.y))
  runtime.pathing.closes_in=function() return nil end
  eq(runtime.ghosts_close_in(p,{ghost('stone-wall','wall',here.x+1,here.y)}),nil)
  runtime.pathing.closes_in=function() return {already=true,region={}} end
  eq(runtime.ghosts_close_in(p,{ghost('stone-wall','wall',here.x+1,here.y)}),nil,'closed in already: not this call')
  eq(runtime.ghosts_close_in(p,{}),nil)
  runtime.pathing.closes_in,runtime.dryrun.joined_pieces=closes_in,joined
end)()
-- skip_failed lists the blocked entry and builds the rest (shake3: Grok, Astra).
wood.count=5
local skipped=call('build',{item='wooden-chest',skip_failed=true,builds={{position={x=4,y=0}},{position={x=8,y=0}},{position={x=9,y=0}}}})
eq(skipped.built,2); eq(skipped.placed[2].x,9.5); eq(#skipped.failed,1); eq(skipped.failed[1].index,2); eq(skipped.failed[1].position.x,8)
assert(skipped.failed[1].error:find('placement blocked',1,true),skipped.failed[1].error); eq(wood.count,3)
-- all (Muse, shift13): the same as skip_failed, with each row's item and a summary.
;(function()
wood.count=5
local every=call('build',{item='wooden-chest',all=true,builds={{position={x=4,y=0}},{position={x=8,y=0}},{position={x=9,y=0}}}})
eq(every.built,2); eq(#every.failed,1); eq(every.failed[1].index,2); eq(every.failed[1].item,'wooden-chest')
eq(every.summary,'2 of 3 built; 1 not built (failed)'); eq(wood.count,3)
fails(function() call('build',{item='wooden-chest',all='yes',builds={{position={x=4,y=0}}}}) end,'all must be true or false')
-- Without it, the refusal names the entries not tried.
wood.count=5
fails(function() call('build',{item='wooden-chest',builds={{position={x=4,y=0}},{position={x=8,y=0}},{position={x=9,y=0}},{position={x=10,y=0}}}}) end,
  'build 2/4 failed after 1 built: placement blocked')
fails(function() call('build',{item='wooden-chest',builds={{position={x=8,y=0}},{position={x=9,y=0}},{position={x=10,y=0}}}}) end,
  '; entries 2-3 were not tried (all: true tries every entry)')
fails(function() call('build',{item='wooden-chest',builds={{position={x=4,y=0}},{position={x=8,y=0}},{position={x=9,y=0}}}}) end,
  '; entry 3 was not tried (all: true tries every entry)')
-- An entry blocked by one this batch placed says which (Muse: a pole inside the assembler's footprint).
eq(runtime.own_blockers('placement blocked by medium-electric-pole (20.5,64.5)',{{name='medium-electric-pole',position={x=20.5,y=64.5},index=1}}),
  'placement blocked by medium-electric-pole (20.5,64.5); medium-electric-pole (20.5,64.5) is entry 1 of this batch')
eq(runtime.own_blockers('placement blocked by tree-01 (3,4), medium-electric-pole (20.5,64.5)',{{name='medium-electric-pole',position={x=20.5,y=64.5},index=4}}),
  'placement blocked by tree-01 (3,4), medium-electric-pole (20.5,64.5); medium-electric-pole (20.5,64.5) is entry 4 of this batch')
eq(runtime.own_blockers('placement blocked by tree-01 (3,4)',{{name='medium-electric-pole',position={x=20.5,y=64.5},index=1}}),'placement blocked by tree-01 (3,4)')
eq(runtime.own_blockers('item is not in main inventory',{{name='medium-electric-pole',position={x=20.5,y=64.5},index=1}}),'item is not in main inventory')
end)()
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
-- build with recipe (Sonnet, shift12 13:50: one call, as configure after): checked before anything is placed, set once
-- it stands; a recipe the machine does not make, one not available, or a machine that takes none: refused, nothing
-- built. A batch gives the call's recipe to its entries that place an assembling machine. And an inserter's reply says
-- in words which side it picks up from and drops to.
;(function()
  local saved_place,saved_recipes,saved_find=wood.prototype.place_result,p.force.recipes,p.surface.find_entities_filtered
  local machine={type='assembling-machine',name='assembling-machine-1',crafting_categories={crafting=true,['advanced-crafting']=true}}
  wood.prototype.place_result=machine
  p.force.recipes={['iron-gear-wheel']={name='iron-gear-wheel',enabled=true,category='crafting'},sulfur={name='sulfur',enabled=true,category='chemistry'},
    locked={name='locked',enabled=false,category='crafting'}}
  local made={}
  local now
  p.surface.find_entities_filtered=function() return now and {now} or {} end
  p.build_from_cursor=function(args)
    p.cursor_stack.count=p.cursor_stack.count-1
    local m={valid=true,name=machine.name,type=machine.type,position={x=args.position.x+.5,y=.5},force=p.force,prototype=machine,fluidbox={}}
    m.set_recipe=function(r) m.recipe=r; return {} end
    m.get_recipe=function() return m.recipe and {name=m.recipe} or nil end
    made[#made+1]=m; now=m
  end
  wood.count=4
  local r=call('build',{item='wooden-chest',position={x=4,y=0},recipe='iron-gear-wheel'})
  eq(r.recipe,'iron-gear-wheel'); eq(made[1].recipe,'iron-gear-wheel'); eq(wood.count,3)
  fails(function() call('build',{item='wooden-chest',position={x=6,y=0},recipe='sulfur'}) end,
    'recipe sulfur (category chemistry) is not one assembling-machine-1 makes (its categories: advanced-crafting, crafting)')
  fails(function() call('build',{item='wooden-chest',position={x=6,y=0},recipe='locked'}) end,'recipe locked is unavailable')
  eq(#made,1,'nothing built for a refused recipe'); eq(wood.count,3)
  local saved_prototypes=prototypes
  prototypes={item={['wooden-chest']={place_result=machine}},entity={}}
  r=call('build',{item='wooden-chest',recipe='iron-gear-wheel',builds={{position={x=6,y=0}},{position={x=8,y=0}}}})
  eq(made[2].recipe,'iron-gear-wheel'); eq(made[3].recipe,'iron-gear-wheel')
  -- A later placement refuses: the first entry's configure already ran.
  wood.count=3
  local canbuild=p.can_build_from_cursor
  local apply_entry=runtime.entryset.built
  runtime.entryset.built=function(...) local a={...};apply_entry(...);assert(#a[4].failed==0,table.concat(a[4].failed,'; ')) end
  p.can_build_from_cursor=function(a)
    if a.position.x==10 then eq(made[#made].recipe,'iron-gear-wheel','configured before the later placement check');return false end
    return true
  end
  fails(function() call('build',{item='wooden-chest',builds={
    {position={x=4,y=0},configure={recipe='iron-gear-wheel'}},{position={x=10,y=0}}}}) end,'build 2/2 failed after 1 built')
  eq(made[#made].recipe,'iron-gear-wheel')
  p.can_build_from_cursor=canbuild
  runtime.entryset.built=apply_entry
  prototypes=saved_prototypes
  wood.prototype.place_result={type='furnace',name='stone-furnace'}
  fails(function() call('build',{item='wooden-chest',position={x=6,y=0},recipe='iron-gear-wheel'}) end,
    'recipe: stone-furnace (type furnace) takes no recipe; only assembling machines (assemblers, foundries, chemical plants and the like) do')
  -- An inserter facing east picks up from the east and drops to the west, in words (the engine's points).
  local arm={type='inserter',name='inserter'}
  wood.prototype.place_result=arm
  p.build_from_cursor=function(args)
    p.cursor_stack.count=p.cursor_stack.count-1
    now={valid=true,name='inserter',type='inserter',position={x=args.position.x+.5,y=.5},direction=4,force=p.force,prototype=arm,
      pickup_position={x=args.position.x+1.5,y=.5},drop_position={x=args.position.x-.5,y=.7}}
  end
  wood.count=2
  r=call('build',{item='wooden-chest',position={x=10,y=0},direction='east'})
  eq(r.entity.inserter,'direction east: picks up from its east side at (11.5,0.5), drops to its west side at (9.5,0.5) (items move west)')
  wood.prototype.place_result,p.force.recipes,p.surface.find_entities_filtered=saved_place,saved_recipes,saved_find
  p.build_from_cursor=build_single; wood.count=2; placed=single_placed
end)()
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
-- A rail planner's curve takes 3 rails, as the game charges it (2.0's items_to_place_this); with fewer held it is refused.
do
local saved_prototypes=prototypes
prototypes={entity={['curved-rail-a']={name='curved-rail-a',type='curved-rail-a',items_to_place_this={{name='rail',count=3}},
  collision_box={left_top={x=-0.7,y=-2.5},right_bottom={x=0.7,y=2.5}}}},item={}}
local rail=stack('rail',4); rail.prototype={rails={{name='straight-rail'},{name='curved-rail-a'}}}
local saved_main=main
main={rail}; main.find_item_stack=function() return rail end
main.get_item_count=function(f) return f.name=='rail' and rail.count or 0 end
main.remove=function(f) eq(f.name,'rail'); rail.count=rail.count-f.count; return f.count end
local r3=call('build',{item='rail',entity='curved-rail-a',position={x=1,y=0},direction='north'})
eq(r3.consumed,3); eq(rail.count,1)
fails(function() call('build',{item='rail',entity='curved-rail-a',position={x=5,y=0},direction='north'}) end,'curved-rail-a takes 3 rail; you hold 1')
eq(rail.count,1)
main=saved_main; prototypes=saved_prototypes
end
-- A held ramp uses direct placement even while ticks run, and revives the
-- ghost construct supplies. Refusals consume none; snapped centres match ghosts.
do
  local saved_main,saved_prototypes=main,prototypes
  local saved_find=p.surface.find_entities_filtered
  local proto={name='rail-ramp',type='rail-ramp',items_to_place_this={{name='rail-ramp',count=1}}}
  local ramp=stack('rail-ramp',2);ramp.prototype={place_result=proto}
  ramp.clear=function() ramp.count=0;ramp.valid_for_read=false end
  main={ramp};main.find_item_stack=function() return ramp end
  main.get_item_count=function(f) return f.name=='rail-ramp' and ramp.count or 0 end
  prototypes={entity={['rail-ramp']=proto},item={['rail-ramp']=ramp.prototype}}
  game.tick_paused=false
  local ghost={valid=true,name='entity-ghost',ghost_name='rail-ramp',position={x=1,y=0},force=p.force}
  ghost.revive=function(a)
    eq(a.raise_revive,true);ghost.valid=false
    return {},{valid=true,name='rail-ramp',type='rail-ramp',position=ghost.position,force=p.force}
  end
  p.surface.find_entities_filtered=function(f) return f.ghost_name and ghost.valid and {ghost} or {} end
  eq(call('build',{item='rail-ramp',position={x=0,y=-1},direction=3}).consumed,1)
  eq(ghost.valid,false);eq(ramp.count,1)
  fails(function() call('build',{item='rail-ramp',position={x=9,y=0}}) end,'placement blocked')
  eq(ramp.count,1)
  local made=call('build',{item='rail-ramp',position={x=4,y=0},direction='north'})
  eq(made.consumed,1);eq(made.entity.position.x,5);eq(ramp.count,0)
  p.surface.find_entities_filtered=saved_find
  main,prototypes=saved_main,saved_prototypes
end
-- Entity batches are explicitly refused, before walking or selecting a target.
fails(function() call('mine',{positions={{x=1,y=0},{x=2,y=0}}}) end,'mine positions and area require tiles: true (laid tiles only); entity mining takes one position {x,y} per call or queue step')
fails(function() call('mine',{area={{0,0},{2,2}}}) end,'mine positions and area require tiles: true')
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
  -- Gleba (Sol, shift09: "entity has no transferable inventory"): seeds go into an agricultural tower's input.
  defines.inventory.agricultural_tower_input=defines.inventory.agricultural_tower_input or 33
  defines.inventory.agricultural_tower_output=defines.inventory.agricultural_tower_output or 34
  prototypes.item['yumako-seed']={name='yumako-seed',type='item'}
  do
    local seeds=stack('yumako-seed',10); main={seeds}
    main.get_item_count=function(f) return seeds.valid_for_read and seeds.name==f.name and seeds.count or 0 end
    local tower=machine('agricultural-tower',defines.inventory.agricultural_tower_input)
    p.surface.find_entities_filtered=function() return {tower} end
    r=call('transfer',{position=tower.position,item='yumako-seed',count=4,direction='to_entity'})
    eq(r.transferred,4); eq(r.inventory,'agricultural_tower_input'); eq(tower.slots[1].name,'yumako-seed')
    r=call('transfer',{position=tower.position,inventory='agricultural_tower_input',item='yumako-seed',count=1,direction='to_entity'})
    eq(r.transferred,1)
  end
  main={mod_src}
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
eq(batch.entities[2].moved,3); assert(batch.entities[3].error:find('outside local visible area'))
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
  -- A rocket silo's fixed rocket-part recipe (d15 batch5 A4, Muse twice: "no recipe set").
  prototypes.recipe['rocket-part']={name='rocket-part',ingredients={{type='item',name='inserter',amount=1},{type='item',name='transport-belt',amount=1}}}
  local silo=assembler(4,'rocket-part'); silo.name='rocket-silo'; silo.type='rocket-silo'
  machines[4]=silo
  main=inv(stack('inserter',20),stack('transport-belt',20))
  r=call('feed',{recipe='rocket-part',crafts=5,positions={{x=4,y=5}}})
  eq(r.entities[1].loaded.inserter,5); eq(r.entities[1].loaded['transport-belt'],5)
  prototypes.item['iron-plate']={}
  main=inv(stack('iron-plate',20),stack(nil,0))
  r=call('feed',{item='iron-plate',positions={{x=4,y=5}}})
  eq(r.nothing_moved,'nothing given: the rocket silo\'s rocket-part recipe takes none of what was named; feed fills a rocket silo\'s rocket-part ingredients; its rocket cargo: load_silo, or transfer {inventory: "rocket_silo_rocket"}')
  fails(function() call('feed',{recipe='nope',positions={{x=1,y=5}}}) end,'unknown recipe nope')
  fails(function() call('feed',{crafts=2,positions={{x=1,y=5}}}) end,'crafts goes with recipe')
  fails(function() call('feed',{recipe='logistic-science-pack',items={'inserter'},positions={{x=1,y=5}}}) end,'recipe or items')
  fails(function() call('feed',{recipe='logistic-science-pack',item='inserter',positions={{x=1,y=5}}}) end,'recipe or items (or item)')

  -- One cargo landing pad per planet (d15 batch5 A5, Astra 02:03): the refusal names the pad there.
  do
    local padproto={type='cargo-landing-pad',name='cargo-landing-pad'}
    local fulgora={name='fulgora',find_entities_filtered=function(f) if f.type=='cargo-landing-pad' then return {{position={x=-20,y=30},force=p.force}} end return {} end}
    eq(runtime.one_pad(fulgora,p.force,padproto,{x=69,y=189}),'one cargo landing pad per planet (the game\'s rule): one, ours stands at (-20,30) on fulgora')
    eq(runtime.one_pad(fulgora,p.force,padproto,{x=-20,y=30}),nil,'the pad itself')
    eq(runtime.one_pad(fulgora,p.force,{type='container'}),nil,'other entities')
    local empty={name='vulcanus',find_entities_filtered=function(f) if f.ghost_type then return {{position={x=1,y=2},force=p.force}} end return {} end}
    eq(runtime.one_pad(empty,p.force,padproto,{x=9,y=9}),'one cargo landing pad per planet (the game\'s rule): a ghost of one, ours stands at (1,2) on vulcanus')
  end
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
  -- Each spoilable item's spread, per inventory (Sol, 22:25).
  silo_trash[1].spoil_tick=game.tick+600; silo_trash[1].spoil_percent=0.5
  eq(call('inspect',{position={x=3,y=0}}).freshness[1],'rocket_silo_trash: space-platform-foundation*40: spoiled 50%, 50% by count; '
    ..'under 25% 0, 25-50% 0, 50-75% 40, 75%+ 0; spoil within 10 min 40, 30 min 40, 60 min 40')
  silo_trash[1].spoil_tick=nil
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
-- Luna 12:20 (a 50/50/50 kit went into the rocket cargo instead of the recipe input): a silo's inventories by transfer
-- name in inspect, with what each holds and one call each; parts and cargo are aliases; a rocket-part ingredient put
-- into the cargo says where it went; a name the silo does not take lists those it does.
do
  local function listing(t)
    t.get_contents=function() local out={}; for _,s in ipairs(t) do if s.valid_for_read then out[#out+1]={name=s.name,count=s.count,quality='normal'} end end; return out end
    t.is_empty=function() return #t.get_contents()==0 end
    t.can_insert=function() return true end
    return t
  end
  local kept_get,before=silo.get_inventory,main
  local input,cargo=listing(inv(stack(nil,0),stack(nil,0))),listing(inv(stack(nil,0),stack(nil,0)))
  silo.get_inventory=function(i) return ({[5]=input,[7]=cargo})[i] end
  silo.get_recipe=function() return {name='rocket-part',ingredients={{type='item',name='processing-unit',amount=1},{type='item',name='rocket-fuel',amount=1}}} end
  prototypes.item['processing-unit']=prototypes.item['processing-unit'] or {fuel_value=0}
  main=inv(stack('processing-unit',50),stack('rocket-fuel',5),stack('space-platform-starter-pack',1))
  local r=call('transfer',{position={x=3,y=0},item='processing-unit',count=50,direction='to_entity',inventory='parts'})
  eq(r.transferred,50); eq(r.inventory,'assembling_machine_input'); eq(input[1].name,'processing-unit'); eq(r.cargo_note,nil)
  r=call('transfer',{position={x=3,y=0},item='rocket-fuel',count=2,direction='to_entity',inventory='cargo'})
  eq(r.transferred,2); eq(r.inventory,'rocket_silo_rocket'); eq(cargo[1].name,'rocket-fuel')
  eq(r.cargo_note,'2 rocket-fuel went into rocket_silo_rocket (cargo), which goes up with the rocket; rocket-fuel is a rocket-part ingredient, and the rocket-part recipe takes its ingredients from assembling_machine_input (parts)')
  -- the full name works as before and says the same; other cargo has no note
  r=call('transfer',{position={x=3,y=0},item='rocket-fuel',count=1,direction='to_entity',inventory='rocket_silo_rocket'})
  eq(r.inventory,nil,'echoed only for an alias or an inferred name'); assert(r.cargo_note:find('^1 rocket%-fuel went'),r.cargo_note)
  r=call('transfer',{position={x=3,y=0},item='space-platform-starter-pack',count=1,direction='to_entity',inventory='cargo'})
  eq(r.transferred,1); eq(r.cargo_note,nil)
  -- taking back by alias
  r=call('transfer',{position={x=3,y=0},item='rocket-fuel',direction='to_player',inventory='cargo'})
  eq(r.transferred,3); eq(r.inventory,'rocket_silo_rocket')
  -- a name the silo does not take
  fails(function() call('transfer',{position={x=3,y=0},item='rocket-fuel',count=1,direction='to_entity',inventory='fuel'}) end,
    'inventory is not applicable to this entity type: fuel; rocket-silo takes inventory ')
  local ok,err=pcall(call,'transfer',{position={x=3,y=0},item='rocket-fuel',count=1,direction='to_entity',inventory='fuel'})
  assert(not ok and tostring(err):find('assembling_machine_input',1,true) and tostring(err):find('cargo (= rocket_silo_rocket), parts (= assembling_machine_input)',1,true),tostring(err))
  -- a parts or cargo alias on another entity is no name it has
  fails(function() call('transfer',{position={x=3,y=0},item='rocket-fuel',count=1,direction='to_entity',inventory='parts_bin'}) end,'unsupported inventory name: parts_bin; rocket-silo takes inventory ')
  -- inspect: the rows
  local seen=call('inspect',{position={x=3,y=0}})
  local rows=seen.silo_inventories
  eq(rows[1].inventory,'assembling_machine_input'); eq(rows[1].alias,'parts'); eq(rows[1].holds,'processing-unit*50')
  eq(rows[1].what,"the rocket-part recipe's ingredients (processing-unit, rocket-fuel): the silo crafts rocket parts from them")
  eq(rows[1].example,[[fh call transfer --args '{"count":50,"direction":"to_entity","inventory":"assembling_machine_input","item":"processing-unit","position":{"x":3,"y":0}}']])
  eq(rows[2].inventory,'rocket_silo_rocket'); eq(rows[2].alias,'cargo'); eq(rows[2].holds,'space-platform-starter-pack*1')
  assert(rows[2].what:find("^the rocket's cargo: it goes up with the rocket at launch"),rows[2].what)
  eq(rows[3],nil,'no trash inventory here')
  silo.get_inventory,main,silo.get_recipe=kept_get,before,nil
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
  -- Astra 10:50: inspect says a built rocket plainly, parts and rocket_ready side by side, and the last launch.
  do
    local kept_def=defines.rocket_silo_status
    defines.rocket_silo_status=kept_def or {building_rocket=0,create_rocket=1,rocket_ready=7,launch_started=14}
    silo.rocket_silo_status,silo.rocket_parts=7,0
    local si=call('inspect',{position={x=3,y=0}})
    eq(si.rocket_ready,true); assert(si.next_parts:find('^0/'),si.next_parts); eq(si.parts,nil)
    assert(si.rocket:find("^rocket built %((%d+)/%1 parts%) and ready to launch, not launched; parts for the rocket after it 0/%1; no launch seen$"),si.rocket)
    assert(si.built_parts and si.built_parts:find('^(%d+)/%1$'),tostring(si.built_parts))
    silo.rocket_silo_status,silo.rocket_parts=nil,nil; defines.rocket_silo_status=kept_def
  end
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
eq(capped.transferred,7); eq(capped.total,7); eq(capped.entities[1].moved,5); eq(capped.entities[2].moved,2)
eq(call('transfer',{positions={{x=3,y=0},{x=4,y=0}},item='coal',total=3,inventory='fuel',direction='to_entity'}).entities[1].moved,3)
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
local am={surface=p.surface,valid=true,name='assembling-machine-1',type='assembling-machine',position={x=3,y=0},force=p.force,fluidbox={},
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
call('queue_cancel',{}); call('queue_submit',{steps={{action='wait_ticks',args={ticks=1000}}}}); advance(1)
local remote_change=call('configure',{position=am.position,recipe='copper-cable'})
eq(remote_change.recipe,'copper-cable'); eq(remote_change.remote,true)
eq(call('queue_status').paused,false); eq(call('queue_status').active.action,'wait_ticks')
plate_stack.name,plate_stack.count,plate_stack.valid_for_read='iron-plate',4,true
fails(function() call('configure',{position=am.position,recipe='iron-gear-wheel',walk=false}) end,'assembling_machine_input holds items')
-- By default the character walks into reach first and changes it there (autowalk.lua): the call is character work.
;(function()
  am.bounding_box={left_top={x=1.5,y=-1.5},right_bottom={x=4.5,y=1.5}}
  local r=call('configure',{position=am.position,recipe='iron-gear-wheel'})
  eq(r.walking_for,'configure'); eq(call('queue_status').paused,true)
  assert(r.walking:find('the machine holds items or is mid-craft, which come back to you only in reach: assembling-machine-1 (3,0) is ',1,true),r.walking)
  eq(call('status').active.walking_for,'configure'); call('stop',{})
  am.bounding_box=nil
end)()
p.can_reach_entity=function() return true end
eq(call('configure',{position=am.position,recipe='iron-gear-wheel'}).remote,nil)
-- Freshness/autowalk merge: an aboard proxy throws on body reads, yet configure remains remote.
do
  local nobody=setmetatable({surface=p.surface,force=p.force},{__index=function() error('aboard with no body',0) end})
  eq(runtime.remote(nobody,'configure',{surface=p.surface.name,position=am.position,modules={'productivity-module'}}),true)
  eq(runtime.remote(nobody,'configure',{platform='Sunward',position=am.position,modules={'productivity-module'}}),true)
end

-- A turret's priority targets and Ignore unprioritised targets (Astra, shift12 15:02: Sunward's rocket turrets on big
-- asteroids only), built and ghost. The fake keeps slots as 2.0.77 does: a set past the end appends; a cleared slot
-- leaves a gap that get_priority_target reads as nil and priority_targets skips; trailing gaps shrink the list.
do
  local saved_find,saved_entity,saved_filtered=p.surface.find_entities_filtered,prototypes.entity,prototypes.get_entity_filtered
  local enemies={['big-metallic-asteroid']={type='asteroid'},['big-carbonic-asteroid']={type='asteroid'},['big-oxide-asteroid']={type='asteroid'},
    ['medium-biter']={type='unit'}}
  prototypes.entity=setmetatable({},{__index=function(_,k) return enemies[k] or (saved_entity and saved_entity[k]) end})
  prototypes.get_entity_filtered=function(f) local out={}; for name,e in pairs(enemies) do if e.type==f[1].type then out[name]=e end end; return out end
  local function turret(name,type_,pos,ghost)
    local slots,n={},0
    local t={valid=true,name=ghost and 'entity-ghost' or name,type=ghost and 'entity-ghost' or type_,ghost_name=ghost and name or nil,
      ghost_type=ghost and type_ or nil,position=pos,force=p.force,ignore_unprioritised_targets=false,health=100,max_health=100,
      get_fluid_contents=function() return {} end}
    t.get_priority_target=function(i) if i<1 or i>n then error('Index out of bounds.') end; return slots[i] and {name=slots[i]} or nil end
    t.set_priority_target=function(i,nm)
      if nm==nil then
        if i<=n then slots[i]=nil; while n>0 and slots[n]==nil do n=n-1 end end
        return
      end
      if i>n then n=n+1; slots[n]=nm else slots[i]=nm end
    end
    t.length=function() return n end
    return setmetatable(t,{__index=function(_,k)
      if k=='priority_targets' then local l={}; for i=1,n do if slots[i] then l[#l+1]={name=slots[i]} end end; return l end
    end})
  end
  local rocket=turret('rocket-turret','ammo-turret',{x=6,y=0})
  local ghost=turret('gun-turret','ammo-turret',{x=9,y=0},true)
  local box={valid=true,name='iron-chest',type='container',position={x=12,y=0},force=p.force}
  local at={[6]=rocket,[9]=ghost,[12]=box}
  p.surface.find_entities_filtered=function(f) local x=f.position and math.floor(f.position.x+0.5); return x and at[x] and {at[x]} or {} end
  local r=call('configure',{position={x=6,y=0},priority_targets={'big-metallic-asteroid','big-carbonic-asteroid','big-oxide-asteroid'},ignore_unprioritised=true})
  eq(#r.priority_targets,3); eq(r.priority_targets[3],'big-oxide-asteroid'); eq(r.ignore_unprioritised,true); eq(rocket.ignore_unprioritised_targets,true)
  eq(r.targeting,'priority targets: big-metallic-asteroid, big-carbonic-asteroid, big-oxide-asteroid (in this order); ignore unprioritised targets: on')
  -- A gap left by the game's own clearing: the list is written whole from slot 1.
  rocket.set_priority_target(2,nil); eq(rocket.length(),3)
  r=call('configure',{position={x=6,y=0},priority_targets={'big-oxide-asteroid'}})
  eq(rocket.length(),1); eq(r.priority_targets[1],'big-oxide-asteroid'); eq(r.ignore_unprioritised,true,'left as it was')
  r=call('configure',{position={x=6,y=0},priority_targets={},ignore_unprioritised=false})
  eq(rocket.length(),0); eq(#r.priority_targets,0); eq(r.targeting,'priority targets: none; ignore unprioritised targets: off')
  eq(#call('configure',{position={x=6,y=0},priority_targets=false}).priority_targets,0)
  -- A ghost takes them as its turret would.
  r=call('configure',{position={x=9,y=0},priority_targets={'medium-biter'},ignore_unprioritised=true})
  eq(r.ghost,true); eq(r.name,'gun-turret'); eq(r.priority_targets[1],'medium-biter'); eq(ghost.ignore_unprioritised_targets,true)
  -- inspect reads them back.
  local seen=call('inspect',{position={x=9,y=0}})
  eq(seen.priority_targets[1],'medium-biter'); eq(seen.ignore_unprioritised,true)
  eq(seen.targeting,'priority targets: medium-biter (in this order); ignore unprioritised targets: on')
  -- An unknown name, something else than a turret, and a recipe beside them are refused, nothing changed.
  fails(function() call('configure',{position={x=9,y=0},priority_targets={'big-asteroid'}}) end,
    'unknown entity big-asteroid in priority_targets; names like it: big-carbonic-asteroid, big-metallic-asteroid, big-oxide-asteroid')
  eq(ghost.length(),1)
  fails(function() call('configure',{position={x=12,y=0},priority_targets={'medium-biter'}}) end,'iron-chest (type container) has no priority targets')
  fails(function() call('configure',{position={x=6,y=0},priority_targets={'medium-biter'},recipe='iron-gear-wheel'}) end,'go alone')
  fails(function() call('configure',{position={x=6,y=0},ignore_unprioritised='yes'}) end,'ignore_unprioritised must be true or false')
  -- Several at once: a row per turret, the one that fails with its error.
  r=call('configure',{positions={{x=6,y=0},{x=9,y=0},{x=12,y=0}},priority_targets={'big-metallic-asteroid'},ignore_unprioritised=true})
  eq(r.configured,2); eq(r.failed,1); eq(r.turrets[1].priority_targets[1],'big-metallic-asteroid'); eq(r.turrets[2].ghost,true)
  assert(r.turrets[3].error:find('has no priority targets',1,true),r.turrets[3].error)
  fails(function() call('configure',{positions={{x=6,y=0}},recipe='iron-gear-wheel'}) end,'positions goes with priority_targets')
  p.surface.find_entities_filtered,prototypes.entity,prototypes.get_entity_filtered=saved_find,saved_entity,saved_filtered
end
-- A storage chest's filter (Astra 18:58: removed modules had no storage chest to go to) and a splitter's priorities and
-- filter (Muse 19:50: a plate split could not favour the steel branch), built and ghost, in configure and inspect. The
-- fakes keep what 2.0.77 keeps on a copy of world n: a storage chest's filter reads back as prototypes; a ghost keeps it
-- for the chest it becomes and reads nil (a blueprint of it holds it); a splitter's filter reads {name, quality,
-- comparator}.
do
  local saved_find,saved_inv,saved_item,saved_quality=p.surface.find_entities_filtered,game.create_inventory,prototypes.item,prototypes.quality
  local extra={['efficiency-module']={name='efficiency-module',type='module'},coal={name='coal',type='item'},['iron-plate']={name='iron-plate',type='item'},
    ['copper-plate']={name='copper-plate',type='item'}}
  prototypes.item=setmetatable({},{__index=function(_,k) return extra[k] or (saved_item and saved_item[k]) end})
  prototypes.quality=setmetatable({},{__index=function(_,k) if k=='normal' or k=='rare' then return {name=k} end return saved_quality and saved_quality[k] end})
  local function proto_of(name) return setmetatable({},{__index=function(_,k) if k=='name' then return name end end}) end
  local function chest(pos,ghost,mode)
    local c={valid=true,name=ghost and 'entity-ghost' or 'storage-chest',type=ghost and 'entity-ghost' or 'logistic-container',ghost_name=ghost and 'storage-chest' or nil,
      ghost_type=ghost and 'logistic-container' or nil,position=pos,force=p.force,health=100,max_health=100,surface=p.surface,
      bounding_box={left_top={x=pos.x-0.4,y=pos.y-0.4},right_bottom={x=pos.x+0.4,y=pos.y+0.4}},get_fluid_contents=function() return {} end}
    local proto={name='storage-chest',type='logistic-container',logistic_mode=mode or 'storage'}
    if ghost then c.ghost_prototype=proto else c.prototype=proto end
    local held
    return setmetatable(c,{__index=function(_,k)
      if k=='storage_filter' then return (not ghost and held) and {name=proto_of(held.name),quality=proto_of(held.quality)} or nil end
      if k=='held' then return held end
    end,__newindex=function(t,k,v) if k=='storage_filter' then held=v else rawset(t,k,v) end end})
  end
  local function splitter(pos,dir,ghost)
    local sp={valid=true,name=ghost and 'entity-ghost' or 'splitter',type=ghost and 'entity-ghost' or 'splitter',ghost_name=ghost and 'splitter' or nil,
      ghost_type=ghost and 'splitter' or nil,position=pos,direction=dir,force=p.force,health=100,max_health=100,
      splitter_input_priority='none',splitter_output_priority='none',get_fluid_contents=function() return {} end,
      get_max_transport_line_index=function() return 0 end}
    local filter
    return setmetatable(sp,{__index=function(_,k) if k=='splitter_filter' then return filter and {name=filter.name,quality=filter.quality or 'normal',comparator='='} or nil end end,
      __newindex=function(t,k,v) if k=='splitter_filter' then filter=v else rawset(t,k,v) end end})
  end
  local store,gstore,provider=chest({x=20.5,y=0.5}),chest({x=22.5,y=0.5},true),chest({x=24.5,y=0.5},false,'active-provider')
  local sp,gsp=splitter({x=27,y=0.5},0),splitter({x=31.5,y=1},4,true)
  local at={[20]=store,[22]=gstore,[24]=provider,[27]=sp,[31]=gsp}
  p.surface.find_entities_filtered=function(f) local x=f.position and math.floor(f.position.x); return x and at[x] and {at[x]} or {} end
  -- A ghost's filter from a blueprint of it (request_filters, as 2.0.77 writes it).
  game.create_inventory=function()
    local stack={}
    stack.create_blueprint=function(a) stack.ents={{name='storage-chest',position=gstore.position,
      request_filters=gstore.held and {sections={{index=1,filters={{index=1,name=gstore.held.name,quality=gstore.held.quality,comparator='=',count=0}}}}} or nil}} end
    stack.get_blueprint_entities=function() return stack.ents end
    return {insert=function() end,destroy=function() end,[1]=stack}
  end
  local r=call('configure',{position={x=20.5,y=0.5},storage_filter='efficiency-module'})
  eq(r.storage_filter,'efficiency-module'); eq(r.storage_filter_before,'none'); eq(store.held.name,'efficiency-module')
  eq(call('inspect',{position={x=20.5,y=0.5}}).storage_filter,'efficiency-module')
  r=call('configure',{position={x=20.5,y=0.5},storage_filter={name='iron-plate',quality='rare'}})
  eq(r.storage_filter,'iron-plate@rare'); eq(r.storage_filter_before,'efficiency-module')
  -- filters with one name on a storage chest is its one filter slot; false or "none" clears it.
  eq(call('configure',{position={x=20.5,y=0.5},filters={'copper-plate'}}).storage_filter,'copper-plate')
  eq(call('configure',{position={x=20.5,y=0.5},storage_filter=false}).storage_filter,'none'); eq(store.held,nil)
  fails(function() call('configure',{position={x=20.5,y=0.5},filters={'iron-plate','copper-plate'}}) end,'a storage chest has one filter slot')
  fails(function() call('configure',{position={x=20.5,y=0.5},storage_filter='iron-plat'}) end,'storage_filter: unknown item iron-plat')
  fails(function() call('configure',{position={x=24.5,y=0.5},storage_filter='iron-plate'}) end,'storage-chest (24.5,0.5) is not a storage chest')
  -- A ghost: kept for the chest it becomes, read back from a blueprint of it.
  r=call('configure',{position={x=22.5,y=0.5},storage_filter='efficiency-module'})
  eq(r.ghost,true); eq(r.storage_filter,'efficiency-module'); eq(gstore.held.name,'efficiency-module')
  eq(call('inspect',{position={x=22.5,y=0.5}}).storage_filter,'efficiency-module')
  -- A splitter: a filter with output priority none is refused; with a side, the line names the tiles.
  fails(function() call('configure',{position={x=27,y=0.5},filter='iron-plate'}) end,
    'splitter (27,0.5): a filter sends its items to the output priority side and the other items to the other side; with output priority none it does nothing')
  eq(sp.splitter_output_priority,'none')
  r=call('configure',{position={x=27,y=0.5},output_priority='left',filter='iron-plate'})
  eq(r.output_priority,'left'); eq(r.filter,'iron-plate'); eq(r.input_priority,'none')
  eq(r.line,'input priority: none (both inputs alike); output priority: left; filter: iron-plate to the left output (26.5,-0.5) only, other items to the right output (27.5,-0.5)')
  eq(r.before,'input priority: none (both inputs alike); output priority: none (items split evenly)')
  r=call('configure',{position={x=27,y=0.5},input_priority='right'})
  eq(r.line,'input priority: right (the right input (27.5,1.5) first, the other when it has none); output priority: left; filter: iron-plate to the left output (26.5,-0.5) only, other items to the right output (27.5,-0.5)')
  local seen=call('inspect',{position={x=27,y=0.5}})
  eq(seen.splitter.input_priority,'right'); eq(seen.splitter.filter,'iron-plate'); eq(seen.filters,nil)
  r=call('configure',{position={x=27,y=0.5},filter=false,output_priority='right'})
  eq(r.filter,'none'); eq(r.line,'input priority: right (the right input (27.5,1.5) first, the other when it has none); output priority: right (the right output (27.5,-0.5) first, the other when it is full)')
  -- A filter set some other way while output priority is none: inspect says it does nothing.
  sp.splitter_output_priority='none'; sp.splitter_filter={name='coal'}
  eq(call('inspect',{position={x=27,y=0.5}}).splitter.line,'input priority: right (the right input (27.5,1.5) first, the other when it has none); output priority: none (items split evenly); filter: coal (does nothing while output priority is none)')
  fails(function() call('configure',{position={x=27,y=0.5},output_priority='middle'}) end,'output_priority is left, right or none')
  fails(function() call('configure',{position={x=20.5,y=0.5},output_priority='left'}) end,"input_priority, output_priority and filter are a splitter's settings; storage-chest (20.5,0.5) is a logistic-container")
  -- A ghost facing east: left is north; filters with one name is its filter.
  r=call('configure',{position={x=31.5,y=1},output_priority='right',filters={'coal'},input_priority='left'})
  eq(r.ghost,true); eq(r.line,'input priority: left (the left input (30.5,0.5) first, the other when it has none); output priority: right; filter: coal to the right output (32.5,1.5) only, other items to the left output (32.5,0.5)')
  p.surface.find_entities_filtered,game.create_inventory,prototypes.item,prototypes.quality=saved_find,saved_inv,saved_item,saved_quality
end
-- A refused configure stops nothing (Astra 11:01, twice: configure with surface=nauvis, her own surface, failed and
-- paused her queue): its target and checks run before the queue would stop; surface naming the character's own surface
-- is the same as none (out of reach: remote view, the queue goes on).
do
  local function queue_walking()
    call('queue_cancel',{}); call('queue_submit',{steps={{action='walk',args={direction='east',ticks=200}}}}); advance(1)
    eq(call('queue_status').paused,false)
  end
  local saved_platforms,saved_get=p.force.platforms,game.get_surface
  p.force.platforms=p.force.platforms or {}
  game.get_surface=function(n) if n==p.surface.name then return p.surface end end
  queue_walking()
  fails(function() call('configure',{position=am.position,recipe='rocket-part',surface=p.surface.name}) end,'recipe is unavailable')
  eq(call('queue_status').paused,false)
  fails(function() call('configure',{position=am.position,recipe='rocket-part'}) end,'recipe is unavailable')
  eq(call('queue_status').paused,false)
  p.can_reach_entity=function() return false end
  plate_stack.valid_for_read=false
  eq(call('configure',{position=am.position,recipe='copper-cable',surface=p.surface.name}).remote,true)
  eq(call('queue_status').paused,false)
  p.can_reach_entity=function() return true end
  -- In reach, a configure that acts still takes over from the queue, as before.
  eq(call('configure',{position=am.position,recipe='iron-gear-wheel'}).recipe,'iron-gear-wheel')
  eq(call('queue_status').paused,true)
  call('queue_cancel',{})
  p.force.platforms,game.get_surface=saved_platforms,saved_get
end
-- An entity ghost takes a recipe and filters as its entity would (Astra 12:20: configure on a 75-ghost Starling layout
-- found only the foundation tile ghosts); a tile ghost under it never takes its place as the target; name may be what
-- the ghost builds.
do
  local ghost_recipe
  local g={valid=true,name='entity-ghost',type='entity-ghost',ghost_name='assembling-machine-2',ghost_type='assembling-machine',
    position={x=6,y=0},force=p.force,ghost_prototype={crafting_categories={crafting=true}}}
  g.get_recipe=function() return ghost_recipe end
  g.set_recipe=function(name) ghost_recipe={name=name}; return {} end
  local tg={valid=true,name='tile-ghost',type='tile-ghost',ghost_name='space-platform-foundation',position={x=6.5,y=0.5},force=p.force}
  local filters_set,mode={},'whitelist'
  local ig={valid=true,name='entity-ghost',type='entity-ghost',ghost_name='fast-inserter',ghost_type='inserter',position={x=8.5,y=0.5},force=p.force,
    filter_slot_count=5,use_filters=false}
  ig.set_filter=function(i,name) filters_set[i]=name end
  ig.get_filter=function(i) return filters_set[i] and {name=filters_set[i],quality='normal'} or nil end
  -- (its spoil priority takes only the underscore spelling here: the call tries fresh-first, then fresh_first)
  local spoil='none'
  setmetatable(ig,{__index=function(_,k) if k=='inserter_filter_mode' then return mode elseif k=='inserter_spoil_priority' then return spoil end end,
    __newindex=function(t,k,v)
      if k=='inserter_filter_mode' then mode=v
      elseif k=='inserter_spoil_priority' then if v:find('-',1,true) then error('Unknown spoil priority: '..v) end spoil=v
      else rawset(t,k,v) end
    end})
  local saved_find=p.surface.find_entities_filtered
  p.surface.find_entities_filtered=function(f)
    local out={}
    for _,e in ipairs({tg,g,ig}) do
      local near=not f.position or (math.abs(e.position.x-f.position.x)<=(f.radius or 0.6)+0.5 and math.abs(e.position.y-f.position.y)<=(f.radius or 0.6)+0.5)
      if near and (not f.name or e.name==f.name) and (not f.ghost_name or e.ghost_name==f.ghost_name) and (not f.type or e.type==f.type) then out[#out+1]=e end
    end
    return out
  end
  p.can_reach_entity=function() return true end
  local r=call('configure',{position={x=6,y=0},recipe='iron-gear-wheel'})
  eq(r.recipe,'iron-gear-wheel'); eq(r.ghost,'assembling-machine-2'); eq(ghost_recipe.name,'iron-gear-wheel')
  fails(function() call('configure',{position={x=6,y=0},recipe='sulfur'}) end,'incompatible')
  r=call('configure',{position={x=6,y=0},name='assembling-machine-2',recipe='copper-cable'})
  eq(r.recipe,'copper-cable'); eq(ghost_recipe.name,'copper-cable')
  local had_plate=prototypes.item['iron-plate']
  prototypes.item['iron-plate']=had_plate or {name='iron-plate',type='item'}
  r=call('configure',{position={x=8.5,y=0.5},name='fast-inserter',filters={'iron-plate'}})
  eq(r.ghost,'fast-inserter'); eq(filters_set[1],'iron-plate'); eq(ig.use_filters,true)
  -- Spoil priority on an inserter ghost (Sol, 18:15): read back as the game stores it.
  r=call('configure',{position={x=8.5,y=0.5},name='fast-inserter',spoil_priority='fresh_first'})
  eq(r.spoil_priority,'fresh_first'); eq(r.spoil_priority_before,'none'); eq(r.ghost,'fast-inserter')
  fails(function() call('configure',{position={x=6,y=0},spoil_priority='fresh_first'}) end,'spoil_priority applies to inserters')
  prototypes.item['iron-plate']=had_plate
  -- By remote view too (out of reach): the ghost, not the tile ghost under it.
  p.can_reach_entity=function() return false end
  r=call('configure',{position={x=6,y=0},recipe='iron-gear-wheel'})
  eq(r.ghost,'assembling-machine-2'); eq(r.remote,true); eq(ghost_recipe.name,'iron-gear-wheel')
  p.can_reach_entity=function() return true end
  p.surface.find_entities_filtered=saved_find
end
-- Filters go on filtering inserters, not machines without slots.
local set_filters={}
prototypes.item['stone-brick']={type='item'}
local fi={valid=true,name='fast-inserter',type='inserter',position={x=3,y=0},force=p.force,filter_slot_count=5,inserter_filter_mode='whitelist'}
fi.set_filter=function(i,f) set_filters[i]=f or false end
fi.get_filter=function(i) return set_filters[i] and {name=set_filters[i]} or nil end
p.surface.find_entities_filtered=function() return {fi} end
local filtered=call('configure',{position=fi.position,filters={'stone-brick'},filter_mode='whitelist'})
eq(filtered.filters[1],'stone-brick'); eq(set_filters[1],'stone-brick'); eq(set_filters[2],false); eq(fi.use_filters,true)
fails(function() call('configure',{position=fi.position,filters={'not-an-item'}}) end,'unknown item')
fails(function() call('configure',{position=fi.position,filters={'stone-brick'},recipe='sulfur'}) end,'not both')
-- A built inserter's spoil priority, with its filters in the same call; an unknown value is refused.
do
  fi.inserter_spoil_priority='none'
  local sp=call('configure',{position=fi.position,spoil_priority='spoiled-first',filters={'stone-brick'}})
  eq(sp.spoil_priority,'spoiled-first'); eq(sp.spoil_priority_before,'none'); eq(sp.filters[1],'stone-brick')
  fails(function() call('configure',{position=fi.position,spoil_priority='freshest'}) end,'spoil_priority is none, fresh_first or spoiled_first')
end
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
-- Burners that hold fuel get none unless asked (Gemini 03:20): the furnaces keep their 5 coal.
eq(fed.transferred,30); eq(fed.items['iron-ore'],20); eq(fed.items['automation-science-pack'],10); eq(fed.items.coal,nil)
eq(f1.slots[3][1].count,20); eq(f1.slots[2][1].count,5); eq(f2.slots[2][1].count,5); eq(lab_slots[1].count,10)
eq(fed.held['iron-ore'],10); eq(fed.held.coal,nil); eq(#fed.entities,2); eq(fed.entities[1].name,'stone-furnace'); eq(fed.entities[2].gave['automation-science-pack'],10)
eq(fed.entities[1].fuel,'coal 5'); eq(fed.entities[2].fuel,nil)
eq(fed.unchanged,1)
-- fuel=true tops every burner up to fuel_count (from what is held above keep).
local topped=call('feed',{fuel=true,keep=2})
eq(topped.items.coal,1); eq(f1.slots[2][1].count,6); eq(topped.entities[1].fuel,'coal 6')
main[1].count=3
local nothing=call('feed',{items={'copper-plate'}})
eq(nothing.transferred,0); assert(nothing.nothing_moved:find('nothing given: none of the 3 machines wants an item',1,true),nothing.nothing_moved)
assert(nothing.nothing_moved:find('2 burners hold fuel (coal 5-6): fuel is added to a burner with none, or with fuel=true or fuel=NAME',1,true),nothing.nothing_moved)
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
-- position + radius: the radius's centre, as rearm and refuel take it (Muse, d15 06:28: feed refused it).
do
  local kf,centre=p.surface.find_entities_filtered,nil
  p.surface.find_entities_filtered=function(f) if f.radius and f.radius>=1 and not centre then centre=f.position end return kf(f) end
  eq(call('feed',{position={x=50,y=60},radius=20,items={'iron-ore'}}).places,0); eq(centre.x,50); eq(centre.y,60); advance(1)
  centre=nil; call('refuel',{position={x=40,y=30},radius=20,count=1}); eq(centre.x,40); advance(1)
  p.surface.find_entities_filtered=kf
end
-- feed over an area with more than 64 machines: one walking tour (Opus, d15 06:20: refused 3 times that day).
do
  local kf=p.surface.find_entities_filtered
  local many={}
  for i=1,65 do many[i]={valid=true,name='lab',type='lab',position={x=i,y=40},force=p.force,unit_number=5000+i,prototype={lab_inputs={'automation-science-pack'}},
    get_inventory=function() return inv(stack(nil,0)) end} end
  p.surface.find_entities_filtered=function(f) if f.area then return many end return kf(f) end
  local r=call('feed',{area={left_top={x=0,y=30},right_bottom={x=70,y=50}},items={'iron-ore'}})
  eq(r.area_targets,65); eq(r.area_tour,'65 machines in the area (over 64): fed as one walking tour, as radius does')
  eq(r.nothing,'nothing in the area wants what you hold (65 machines of those kinds there)'); eq(r.places,0)
  advance(1); eq(call('status').last.outcome,'nothing_to_do')
  p.surface.find_entities_filtered=kf
end
-- A rearm/refuel tour out of it with stops left ends out_of_items only while one of them still wants it (Haiku, d15
-- 07:50); else topped_up (runtime.tour_wants).
do
  local full=inv(stack('coal',10)); local low=inv(stack('coal',2))
  local function burner(i) return {valid=true,get_fuel_inventory=function() return i end,get_inventory=function(k) return k==defines.inventory.fuel and i or nil end} end
  eq(runtime.tour_wants(burner(full),{op='refuel',item='coal',count=5}),false)
  eq(runtime.tour_wants(burner(low),{op='refuel',item='coal',count=5}),true)
end
-- Round 03:20. Fakes: furnaces at (3,0) and (4,0), boilers at (1..3,3); a point finds what stands there.
local function boiler(x,count)
  local fuel=inv(stack('coal',count))
  local b={valid=true,name='boiler',type='boiler',position={x=x,y=3},force=p.force,unit_number=900+x,fuel=fuel}
  b.get_inventory=function(i) return i==defines.inventory.fuel and fuel or nil end
  b.get_fuel_inventory=function() return fuel end
  return b
end
local b1,b2,b3=boiler(1,2),boiler(2,0),boiler(3,10)
local function typed(f,e)
  if type(f.type)=='table' then for _,t in ipairs(f.type) do if t==e.type then return true end end return false end
  return f.type==nil or f.type==e.type
end
p.surface.find_entities_filtered=function(f)
  local out={}
  for _,e in ipairs({f1,f2,b1,b2,b3}) do
    if typed(f,e) and (not (f.position and (f.radius or 0)<1) or (e.position.x==f.position.x and e.position.y==f.position.y)) then out[#out+1]=e end
  end
  return out
end
-- Gemini (shift09 10:20): furnaces burning solid fuel, no coal carried: the ore goes in without fuel ("you carry 0 coal"
-- before); the row names what its fuel slots hold.
prototypes.item['solid-fuel']={fuel_value=12000000}; prototypes.item['iron-plate']={}
local fs=f1.slots[2][1]; fs.name,fs.count,fs.valid_for_read='solid-fuel',3,true
main=inv(stack('iron-ore',30),stack(nil,0),stack(nil,0))
local ore=call('feed',{positions={{x=3,y=0}}})
eq(ore.items['iron-ore'],15); eq(ore.items.coal,nil); eq(ore.entities[1].fuel,'solid-fuel 3'); eq(ore.nothing_moved,nil); eq(fs.count,3)
-- A furnace that never smelted (no recipe yet) takes nothing unnamed; the reply says so, with what it would smelt.
prototypes.recipe={['steel-plate']={name='steel-plate',category='smelting',ingredients={{type='item',name='iron-plate',amount=5}}}}
f2.prototype={crafting_categories={smelting=true}}
main=inv(stack('iron-plate',40),stack(nil,0),stack(nil,0))
main.get_contents=function() return {{name='iron-plate',count=40,quality='normal'}} end
local unnamed=call('feed',{positions={{x=4,y=0}}})
eq(unnamed.transferred,0); eq(unnamed.entities[1].got,'nothing'); eq(unnamed.entities[1].fuel,'coal 5')
eq(unnamed.nothing_moved,'nothing given: none of the 1 machines wants an item (no recipe set, or not a machine feed fills); '
  ..'1 furnace with no recipe yet (nothing smelted there) takes only items named in items or item; you carry iron-plate 40 that they smelt; '
  ..'1 burner holds fuel (coal 5): fuel is added to a burner with none, or with fuel=true or fuel=NAME')
-- Named, it goes into the source slot as a player puts it there.
local named=call('feed',{positions={{x=4,y=0}},item='iron-plate'})
eq(named.items['iron-plate'],20); eq(f2.slots[3][1].name,'iron-plate'); eq(f2.slots[3][1].count,20)
-- A burner with empty fuel slots gets fuel unasked.
local f2s=f2.slots[2][1]; f2s.count,f2s.valid_for_read=0,false
main=inv(stack('coal',5),stack(nil,0),stack(nil,0))
local empty=call('feed',{positions={{x=4,y=0}}})
eq(empty.items.coal,5); eq(empty.entities[1].fuel,'coal 5')
-- Haiku 03:20: one call tops up every boiler in an area from the inventory; each boiler has a row (what it got, its
-- fuel after); fuel=true tops up the ones that hold some too.
main=inv(stack('coal',50),stack(nil,0),stack(nil,0))
local area={left_top={x=0,y=2},right_bottom={x=4,y=4}}
local boilers=call('feed',{area=area,types={'boiler'}})
eq(boilers.area_targets,3); eq(boilers.items.coal,10); eq(b2.fuel[1].count,10); eq(b1.fuel[1].count,2)
eq(#boilers.entities,3); eq(boilers.entities[1].got,'nothing'); eq(boilers.entities[1].fuel,'coal 2')
eq(boilers.entities[2].gave.coal,10); eq(boilers.entities[3].fuel,'coal 10')
local topped_all=call('feed',{area=area,types={'boiler'},fuel=true})
eq(topped_all.items.coal,8); eq(b1.fuel[1].count,10)
eq(topped_all.entities[1].gave.coal,8); eq(topped_all.entities[1].fuel,'coal 10'); eq(topped_all.entities[2].got,'nothing'); eq(topped_all.entities[3].got,'nothing')
-- One standing-order registration takes from its named chest, then tops up two furnace areas.
;(function()
  local find,old_main,old_orders=p.surface.find_entities_filtered,main,storage.agent_harness.orders
  local old_clock=storage.agent_harness.clocks
  local old_counts={f1.slots[2][1].count,f2.slots[2][1].count}
  local old_names={f1.slots[2][1].name,f2.slots[2][1].name}
  local a,b=f1.slots[2],f2.slots[2]
  local ac,bc=a.get_item_count,b.get_item_count
  a.get_item_count=function(q) return q and ac(q) or a[1].count end
  b.get_item_count=function(q) return q and bc(q) or b[1].count end
  f1.burner={}; f2.burner={}
  for _,f in ipairs({f1,f2}) do f.slots[2][1].name='coal'; f.slots[2][1].count=1; f.slots[2][1].valid_for_read=true end
  main=inv(stack(nil,0),stack(nil,0),stack(nil,0))
  local source=inv(stack('coal',100))
  local chest={valid=true,name='iron-chest',type='container',position={x=8,y=0},force=p.force,
    get_inventory=function(id) return id==defines.inventory.chest and source or nil end}
  p.surface.find_entities_filtered=function(q)
    if q.position and (q.radius or 0)<1 then
      for _,e in ipairs({f1,f2,chest}) do if e.position.x==q.position.x then return {e} end end
      return {}
    end
    if q.area then
      local lt=q.area.left_top or q.area[1]; local rb=q.area.right_bottom or q.area[2]
      local out={}
      for _,e in ipairs({f1,f2}) do if e.position.x>=lt.x and e.position.x<=rb.x then out[#out+1]=e end end
      return out
    end
    return {f1,f2}
  end
  call('order_set',{name='test-fueled',when={['until']='fuel_below',count=5,position={x=3,y=0},radius=10},
    cooldown_ticks=300,max_ticks=3600,steps={
      {action='transfer',args={position={x=8,y=0},direction='to_player',item='coal',count=40,up_to=40,walk=true}},
      {action='feed',args={area={left_top={x=2,y=-1},right_bottom={x=3.5,y=1}},types={'furnace'},fuel='coal',fuel_count=20,walk=true}},
      {action='feed',args={area={left_top={x=3.5,y=-1},right_bottom={x=5,y=1}},types={'furnace'},fuel='coal',fuel_count=20,walk=true}}}})
  -- A recent request keeps orders enabled; no further driving call is needed.
  storage.agent_harness.clocks=storage.agent_harness.clocks or {}
  storage.agent_harness.clocks[1]={call_tick=game.tick,idle=0}
  call('orders_resume',{hold_s=0}); advance(120)
  eq(f1.slots[2][1].count,20); eq(f2.slots[2][1].count,20); eq(source[1].count,60)
  advance(400); eq(source[1].count,60,'a satisfied trigger does not take another chest load')
  call('order_remove',{name='test-fueled'}); call('queue_cancel',{})
  p.surface.find_entities_filtered,main,storage.agent_harness.orders,storage.agent_harness.clocks=find,old_main,old_orders,old_clock
  a.get_item_count,b.get_item_count=ac,bc; f1.burner,f2.burner=nil,nil
  for i,f in ipairs({f1,f2}) do f.slots[2][1].count=old_counts[i]; f.slots[2][1].name=old_names[i] end
end)()
-- The same as a walking tour (radius): last names each stop.
b1.fuel[1].count=4; b3.fuel[1].count=7
call('feed',{radius=20,types={'boiler'},fuel=true}); advance(1)
local tour_last=call('status').last
eq(tour_last.op,'feed'); eq(tour_last.given,9); eq(#tour_last.entities,2)
eq(tour_last.entities[1].gave.coal,6); eq(tour_last.entities[1].fuel,'coal 10'); eq(tour_last.entities[2].gave.coal,3)
-- Haiku, 07:55: feed with up_to skips a boiler whose fuel slot holds the other fuel, without the whole call warning;
-- it was counted as "at count already" (shift10: "4 machines hold 0-29 coal, at count 10 already").
do
  local s2=b2.fuel[1]
  local kept_b1,kept_b3,kept_main=b1.fuel[1].count,b3.fuel[1].count,main
  local kept_s2={s2.name,s2.count,s2.valid_for_read}
  s2.name,s2.count,s2.valid_for_read='solid-fuel',4,true
  b1.fuel[1].count,b3.fuel[1].count=10,10
  main=inv(stack('coal',40),stack(nil,0),stack(nil,0))
  local only=call('feed',{positions={{x=2,y=3}},item='coal',up_to=true})
  eq(only.transferred,0); eq(only.nothing_moved,nil); eq(only.entities[1].other_fuel,true); eq(only.entities[1].fuel,'solid-fuel 4')
  eq(only.other_fuel,'1 burner holds another fuel in every fuel slot (solid-fuel 4): no slot for coal')
  -- without up_to it is said as the reason nothing moved
  eq(call('feed',{positions={{x=2,y=3}},item='coal'}).nothing_moved,'nothing given: 1 burner holds another fuel in every fuel slot (solid-fuel 4): no slot for coal')
  -- beside full ones: the full ones are the warning, the other fuel apart
  local full=call('feed',{positions={{x=1,y=3},{x=2,y=3},{x=3,y=3}},item='coal',up_to=true})
  eq(full.nothing_moved,'nothing given: 2 machines hold 10 coal, at count 10 already; 1 burner holds another fuel in every fuel slot (solid-fuel 4): no slot for coal')
  -- one that wants coal gets it; the other-fuel one is skipped, no warning
  b1.fuel[1].count=4
  local mixed=call('feed',{positions={{x=1,y=3},{x=2,y=3}},item='coal',up_to=true})
  eq(mixed.transferred,6); eq(mixed.nothing_moved,nil); eq(mixed.other_fuel,'1 burner holds another fuel in every fuel slot (solid-fuel 4): no slot for coal')
  eq(s2.name,'solid-fuel'); eq(s2.count,4)
  -- a walking tour leaves it out: only b1 (at 4 again) is visited
  b1.fuel[1].count=4
  local tour=call('feed',{radius=20,types={'boiler'},item='coal',up_to=true})
  eq(tour.places,1); eq(tour.nothing_moved,nil); eq(tour.other_fuel,'1 burner holds another fuel in every fuel slot (solid-fuel 4): no slot for coal')
  advance(1)
  eq(call('status').last.given,6)
  s2.name,s2.count,s2.valid_for_read=kept_s2[1],kept_s2[2],kept_s2[3]
  b1.fuel[1].count,b3.fuel[1].count,main=kept_b1,kept_b3,kept_main
end
-- Round 00:20: up_to survives feed completion for CLI --wait / wait; strict feeds still run short.
do
  local was_main,was_find=main,p.surface.find_entities_filtered
  local n1,n3=b1.fuel[1].count,b3.fuel[1].count
  for _,allowed in ipairs({true,false}) do
    main=inv(stack('coal',1)); b1.fuel[1].count=1; b3.fuel[1].count=1
    p.surface.find_entities_filtered=function() return {b1,b3} end
    call('feed',{radius=20,types={'boiler'},item='coal',up_to=allowed and true or nil})
    advance(3)
    local last=call('status').last
    eq(last.outcome,'out_of_items'); eq(last.moved,1); eq(last.short_allowed,allowed and true or nil)
  end
  main,p.surface.find_entities_filtered=was_main,was_find
  b1.fuel[1].count,b3.fuel[1].count=n1,n3
end
-- Area feed uses one tour across successive reach groups, without another feed call.
;(function()
  local was_reach,was_main,was_pos=p.can_reach_entity,main,p.position
  local x2,x3=b2.position.x,b3.position.x
  b2.position.x,b3.position.x=24,48; p.position={x=0,y=3}
  local old={b1.fuel[1].count,b2.fuel[1].count,b3.fuel[1].count}
  main=inv(stack('coal',60)); for _,b in ipairs({b1,b2,b3}) do b.fuel[1].count=1 end
  local group=1
  p.can_reach_entity=function(e) return e==b1 or (group>=2 and e==b2) or (group>=3 and e==b3) end
  local r=call('feed',{area={left_top={x=0,y=2},right_bottom={x=50,y=4}},types={'boiler'},fuel='coal',walk=true,ticks=600})
  eq(r.area_targets,3); eq(r.places,3); eq(r.out_of_reach,2); eq(r.until_tick,game.tick+600)
  advance(1); eq(b1.fuel[1].count,10); eq(b2.fuel[1].count,1); eq(call('status').active.kind,'gather')
  group=2; p.position={x=24,y=3}; advance(1); eq(b2.fuel[1].count,10); eq(b3.fuel[1].count,1); eq(call('status').active.kind,'gather')
  group=3; p.position={x=48,y=3}; advance(1)
  local last=call('status').last
  eq(last.outcome,'topped_up'); eq(last.visited,3); eq(last.moved,27); eq(#last.entities,3); eq(b3.fuel[1].count,10)
  p.can_reach_entity,main,p.position=was_reach,was_main,was_pos
  b2.position.x,b3.position.x=x2,x3
  for i,b in ipairs({b1,b2,b3}) do b.fuel[1].count=old[i] end
end)()
-- A rejected submit leaves the repeating job running even after bootstrap failure cleanup.
do
  call('queue_repeat',{name='plate-haul',steps={{action='wait_until',args={['until']='item_count',item='iron-plate',at_least=10000}}}})
  advance(1)
  local before=call('queue_status')
  fails(function() call('queue_submit',{steps={{action='wait_ticks',args={ticks=1}}}}) end,'repeating job "plate-haul"')
  runtime.stop_player(1)
  local after=call('queue_status')
  eq(after.revision,before.revision); eq(after.paused,false); eq(after.active.id,before.active.id)
  call('queue_cancel',{})
end
-- transfer {walk=true} (Haiku, 06:20: solid fuel into a boiler out of reach, in one call): the call walks into reach
-- first (a tour, as feed and collect), then transfers; all in reach, it transfers at once.
do
  local reach_was=p.can_reach_entity
  local far={[b3]=true}
  p.can_reach_entity=function(e) return not far[e] end
  b3.fuel[1].count=5
  main=inv(stack('coal',30),stack(nil,0),stack(nil,0))
  local w=call('transfer',{position={x=3,y=3},item='coal',count=12,inventory='fuel',direction='to_entity',walk=true})
  eq(w.op,'transfer'); eq(w.places,1); eq(w.out_of_reach,1); eq(w.direction,'to_entity'); eq(call('status').active.kind,'gather')
  far={}  -- arrived in reach
  advance(1)
  local wl=call('status').last
  eq(wl.outcome,'transferred'); eq(wl.op,'transfer'); eq(wl.transferred,12); eq(wl.items.coal,12); eq(wl.direction,'to_entity')
  eq(wl.entities[1].moved,12); eq(b3.fuel[1].count,17); eq(main[1].count,18)
  -- all in reach: the plain transfer, at once
  local now=call('transfer',{position={x=1,y=3},item='coal',count=2,inventory='fuel',direction='to_entity',walk=true})
  eq(now.transferred,2); eq(now.op,nil); eq(b1.fuel[1].count,12)
  -- takes from two, one out of reach; the direction inferred (only the boilers hold coal)
  main=inv(stack(nil,0),stack(nil,0),stack(nil,0))
  far={[b2]=true}
  local take=call('transfer',{positions={{x=1,y=3},{x=2,y=3}},item='coal',count=4,inventory='fuel',walk=true})
  eq(take.direction,'to_player'); eq(take.places,2); eq(take.out_of_reach,1)
  far={}; advance(1)
  local tl=call('status').last
  eq(tl.outcome,'transferred'); eq(tl.transferred,8); eq(#tl.entities,2); eq(main[1].count,8)
  -- nothing to give: refused before walking; up_to=true: a short instead
  far={[b3]=true}
  main=inv(stack(nil,0),stack(nil,0),stack(nil,0))
  fails(function() call('transfer',{position={x=3,y=3},item='solid-fuel',count=5,direction='to_entity',walk=true}) end,'no solid-fuel in inventory; nothing to give at 1 place')
  local short=call('transfer',{position={x=3,y=3},item='solid-fuel',count=5,direction='to_entity',walk=true,up_to=true})
  eq(short.transferred,0); eq(short.short.reason,'none_held')
  fails(function() call('transfer',{position={x=3,y=3},item='coal',direction='to_player',ticks=60}) end,'ticks applies with walk')
  fails(function() call('transfer',{position={x=3,y=3},item='coal',direction='to_player',walk='yes'}) end,'walk must be true or false')
  fails(function() call('transfer',{positions={{x=3,y=3}},item='coal',total=5,direction='to_player',walk=true}) end,'total does not go with walk')
  -- never reached (the fake engine's paths fail): nothing moved, outcome unreached
  local u=call('transfer',{position={x=3,y=3},item='coal',count=1,inventory='fuel',direction='to_player',walk=true})
  eq(u.places,1)
  advance(600)
  local ul=call('status').last
  eq(ul.outcome,'unreached'); eq(ul.transferred,0); eq(ul.unreached,1)
  -- as a queue step: the step runs while the tour walks (out of reach when it starts, in reach a tick later), and
  -- its outcome counts as done
  main=inv(stack('coal',10),stack(nil,0),stack(nil,0))
  local looks=0
  p.can_reach_entity=function(e) if e==b3 then looks=looks+1; return looks>1 end return true end
  call('queue_submit',{steps={{action='transfer',args={position={x=3,y=3},item='coal',count=3,inventory='fuel',direction='to_entity',walk=true}}}})
  advance(3)
  local qs=call('queue_status',{})
  local h=qs.history[#qs.history]
  eq(h.action,'transfer'); eq(h.ok,true); eq(h.result.outcome,'transferred'); eq(b3.fuel[1].count,20)
  p.can_reach_entity=reach_was
end
fails(function() call('feed',{fuel=1}) end,'fuel must be a fuel item, true or false')
prototypes.recipe=nil; f2.prototype=nil
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
-- The gun that fires (Sol, d15 07:50): the selected slot, its ammo slot and count, its range, and why nothing would fire.
do
  defines.inventory.character_guns=defines.inventory.character_guns or 41; defines.inventory.character_ammo=defines.inventory.character_ammo or 42
  local GI,AI=defines.inventory.character_guns,defines.inventory.character_ammo
  prototypes.item.pistol={attack_parameters={range=15}}; prototypes.item['rocket-launcher']={attack_parameters={range=36}}
  local function slot(name,count) return {valid_for_read=name~=nil,name=name,count=count or 0} end
  local guns={slot('pistol'),slot('rocket-launcher'),slot(nil)}
  local ammo={slot('firearm-magazine',10),slot(nil),slot(nil)}
  ammo.get_item_count=function() return 10 end; ammo.get_contents=function() return {} end
  local kept=p.get_inventory
  p.get_inventory=function(i) if i==GI then return guns elseif i==AI then return ammo end return kept(i) end
  p.character.selected_gun_index=2
  local r=call('shoot',{position={x=3,y=0},ticks=4})
  eq(r.gun.slot,2); eq(r.gun.name,'rocket-launcher'); eq(r.gun.count,0); eq(r.gun.range,36)
  eq(r.no_compatible_ammo,'gun slot 2 (rocket-launcher) has nothing in ammo slot 2; slot 1 pistol has firearm-magazine*10 (gun_slot picks it)')
  advance(5); eq(call('status').last_combat.why_none:sub(1,19),'no_compatible_ammo:')
  r=call('shoot',{position={x=30,y=0},ticks=4,gun_slot=1})
  eq(r.gun.slot,1); eq(r.gun.ammo,'firearm-magazine'); eq(r.gun.count,10); eq(r.out_of_range,'pistol reaches 15 tiles; the target is '..string.format('%.1f',math.sqrt((30-p.position.x)^2+p.position.y^2))..' away')
  advance(5)
  p.get_inventory=kept; p.character.selected_gun_index=1
end
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
local requeued=call('queue_status'); eq(requeued.pending_count,2); eq(requeued.pending[1].action,'move_to')
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
  local trash_id,kept_cursor=defines.inventory.character_trash,p.cursor_stack
  defines.inventory.character_guns,defines.inventory.character_ammo,defines.inventory.character_armor,defines.inventory.character_trash=2,3,4,8
  -- Gemini, 06:20: one small reply: short item lines, the armor's equipment, trash slots and the cursor.
  local suit={valid_for_read=true,name='modular-armor',count=1,grid={get_contents=function() return {{name='solar-panel-equipment',quality='normal',count=3},{name='personal-roboport-equipment',quality='normal',count=1}} end}}
  local by={[3]={{name='firearm-magazine',quality='normal',count=10}},[4]={{name='modular-armor',quality='normal',count=1}},[8]={{name='iron-plate',quality='uncommon',count=308}}}
  p.get_inventory=function(id) local x={get_contents=function() return by[id] or {} end}; if id==4 then x[1]=suit end; return x end
  p.cursor_stack={valid_for_read=true,name='transport-belt',count=50,quality={name='normal'}}
  call('walk',{direction='east',ticks=5})
  local held=call('inventory',{})
  eq(held.inventory,'iron-plate*50'); eq(held.ammo,'firearm-magazine*10'); eq(held.guns,'empty'); eq(held.armor,'modular-armor*1')
  eq(held.equipment,'solar-panel-equipment*3 personal-roboport-equipment*1'); eq(held.trash,'iron-plate@uncommon*308')
  eq(held.cursor,'transport-belt*50')
  eq(held.free,'free=1/2'); assert(held.clock,'inventory carries the clock line')
  -- full=true: the stacks as lists, as before
  local whole=call('inventory',{full=true})
  eq(whole.inventory[1].name,'iron-plate'); eq(whole.inventory[1].count,50); eq(whole.ammo[1].count,10); eq(#whole.guns,0)
  eq(whole.trash[1].count,308); eq(whole.equipment[1].name,'solar-panel-equipment')
  -- status {inventory=true}: the same in one line, brief or full; without it, no line
  local line='main iron-plate*50 (free=1/2); ammo firearm-magazine*10; armor modular-armor*1 with solar-panel-equipment*3 personal-roboport-equipment*1; trash iron-plate@uncommon*308; cursor transport-belt*50'
  eq(call('status',{brief=true,inventory=true}).inventory,line)
  eq(call('status',{brief=true}).inventory,nil)
  -- a ghost in hand; nothing in hand; no trash, no armor
  p.cursor_stack={valid_for_read=false}; p.cursor_ghost={name={name='assembling-machine-2'},quality={name='normal'}}
  eq(call('inventory',{}).cursor,'ghost of assembling-machine-2')
  p.cursor_ghost=nil; by[8]=nil; by[4]=nil; suit.valid_for_read=false
  held=call('inventory',{})
  eq(held.cursor,nil); eq(held.trash,nil); eq(held.equipment,nil); eq(held.armor,'empty')
  eq(call('status',{brief=true,inventory=true}).inventory,'main iron-plate*50 (free=1/2); ammo firearm-magazine*10')
  eq(call('status').active.kind,'walk'); call('stop',{})
  fails(function() call('inventory',{item='iron-plate'}) end,'unknown argument item for inventory')
  fails(function() call('inventory',{full='yes'}) end,'full must be true or false')
  -- boilers (networks.lua; tests/networks.lua) is a read every agent can call
  local d=call('describe',{})
  assert(d.actions.boilers.returns:find('feeder',1,true)); assert(d.actions.status.inventory)
  assert(runtime.is_read('boilers') and runtime.is_read('inventory'))
  defines.inventory.character_guns,defines.inventory.character_ammo,defines.inventory.character_armor,defines.inventory.character_trash=nil,nil,nil,trash_id
  p.get_inventory=function() return {get_contents=function() return {} end} end
  p.cursor_stack=kept_cursor
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
eq(crafted.started['iron-gear-wheel'],5); eq(crafted.started.pipe,nil); assert(crafted.nothing_queued.pipe:find('^nothing was queued for pipe: '),crafted.nothing_queued.pipe); eq(crafted.errors.rocket,'recipe is unavailable')
-- Crafts land in the inventory as each finishes (operator 08:01): moved 0 now, timed says when, the line now.
eq(crafted.moved,0); assert(crafted.timed:find('^crafts land in your inventory as each finishes'),crafted.timed)
eq(crafted.no_assembler,nil); eq(crafted.blocks,nil) -- no assembler unlocked, short queue
-- An ingredient still in the hand-craft queue (Astra 11:01: 75 electronic circuits queued, then laser turrets made
-- 20 more): up to the shortfall the queued crafts are cancelled first, so the game crafts them again as this craft's
-- own ingredients, none extra; any it does not use go back in the queue.
do
  local saved={begin=p.begin_crafting,cancel=p.cancel_crafting,inv=p.get_main_inventory,queue=p.crafting_queue}
  p.force.recipes['electronic-circuit']={enabled=true,category='crafting',energy=0.5,products={{type='item',name='electronic-circuit',amount=1}},
    ingredients={{type='item',name='iron-plate',amount=1},{type='item',name='copper-cable',amount=3}}}
  p.force.recipes['laser-turret']={enabled=true,category='crafting',energy=20,products={{type='item',name='laser-turret',amount=1}},
    ingredients={{type='item',name='steel-plate',amount=20},{type='item',name='electronic-circuit',amount=20},{type='item',name='battery',amount=12}}}
  local held={['steel-plate']=20,battery=12,['electronic-circuit']=0}
  p.get_main_inventory=function() return {get_item_count=function(f) return held[type(f)=='table' and f.name or f] or 0 end} end
  local queue={{index=1,recipe='electronic-circuit',count=75}}
  p.crafting_queue=queue
  local cancels,can_start={},true
  p.cancel_crafting=function(c) cancels[#cancels+1]=c.index..':'..c.count; queue[c.index].count=queue[c.index].count-c.count end
  -- As the engine: what the inventory lacks is crafted first, as the parent's own (prerequisite) entries.
  p.begin_crafting=function(r)
    if r.recipe=='laser-turret' then
      if not can_start then return 0 end
      local short=20*r.count-held['electronic-circuit']
      if short>0 then queue[#queue+1]={index=#queue+1,recipe='electronic-circuit',count=short,prerequisite=true} end
      queue[#queue+1]={index=#queue+1,recipe='laser-turret',count=r.count}
      return r.count
    end
    queue[#queue+1]={index=#queue+1,recipe=r.recipe,count=r.count}
    return r.count
  end
  local made=call('craft',{recipe='laser-turret',count=1})
  eq(made.started,1); eq(cancels[1],'1:20'); eq(queue[1].count,55); eq(queue[2].count,20); eq(queue[2].prerequisite,true)
  eq(made.from_queue['electronic-circuit'],'20 of the 75 queued go into laser-turret (the game crafts them again as its ingredients: none extra)')
  -- The craft cannot start (the game started none): the cancelled ones go back in the queue.
  queue={{index=1,recipe='electronic-circuit',count=75}}; p.crafting_queue=queue; cancels={}; can_start=false
  made=call('craft',{recipe='laser-turret',count=1})
  eq(made.started,0); eq(queue[1].count,55); eq(queue[2].recipe,'electronic-circuit'); eq(queue[2].count,20); eq(queue[2].prerequisite,nil)
  eq(made.from_queue['electronic-circuit'],'0 of the 75 queued go into laser-turret (the game crafts them again as its ingredients: none extra); 20 not used, queued again as before')
  -- Enough held already: the queue is left alone.
  queue={{index=1,recipe='electronic-circuit',count=75}}; p.crafting_queue=queue; cancels={}; can_start=true; held['electronic-circuit']=20
  made=call('craft',{recipe='laser-turret',count=1})
  eq(#cancels,0); eq(made.from_queue,nil); eq(queue[1].count,75)
  p.begin_crafting,p.cancel_crafting,p.get_main_inventory,p.crafting_queue=saved.begin,saved.cancel,saved.inv,saved.queue
  p.force.recipes['electronic-circuit'],p.force.recipes['laser-turret']=nil,nil
end
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
fails(function() call('craft',{recipe='iron-gear-wheel',count=100}) end,'not crafted: 200 iron-gear-wheel held by our factory (200 in 1 assembling-machine-2); nearest 200 at (12,5) 13 tiles away; collect item=iron-gear-wheel radius=15 gathers it; craft force=true')
-- Existing on_fail: skip continues after a real stock refusal; no chest is
-- silently drained. Requesters in the journal were feeding other machines.
;(function()
  local find=p.surface.find_entities_filtered
  local oldqueues,oldactive=storage.agent_harness.queues,storage.agent_harness.active
  storage.agent_harness.queues={};storage.agent_harness.active={}
  local chest={valid=true,name='requester-chest',type='logistic-container',position={x=20.5,y=59.5},
    get_inventory=function() return gear_out end}
  p.surface.find_entities_filtered=function(f) return f.radius and {chest} or {} end
  local ok,err=pcall(call,'craft',{recipe='iron-gear-wheel',count=100})
  eq(ok,false);assert(err:find('requester-chest (20.5,59.5) holds 200',1,true),err)
  for _,part in ipairs({'abort (default) pauses','skip continues','goto:<label>','skipping does not acquire items'}) do assert(err:find(part,1,true),err) end
  call('queue_submit',{steps={{action='craft',args={recipe='iron-gear-wheel',count=100},on_fail='skip'},
    {action='wait_ticks',args={ticks=1}}}})
  advance(30)
  local q=call('queue_status',{history='all'})
  eq(q.paused,false);eq(q.pending_count,0);eq(q.history[1].ok,false);eq(q.history[2].ok,true)
  eq(gear_out.get_item_count{name='iron-gear-wheel'},200,'stock was only read')
  storage.agent_harness.queues,storage.agent_harness.active=oldqueues,oldactive
  p.surface.find_entities_filtered=find
end)()
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
-- Hand hauling (hauling.lua), read as the operator: totals over every agent, as differences from here.
local H={}
function H.read()
  local t={items=0,calls=0,direct_items=0,direct_calls=0,queue_items=0,queue_calls=0,order_items=0,order_calls=0}
  for _,row in ipairs(runtime.dispatch{action='hauling',args={},operator=true}.agents) do
    for k in pairs(t) do t[k]=t[k]+row[k] end
  end
  return t
end
H[0]=H.read()
-- loadout (loadout.lua; Nick, 08:55): an operator read listed in describe, a row per agent.
do
  local agents=runtime.board.agents
  runtime.board.agents=function() return {{index=1,name='nick'}} end  -- (this fake game has no game.players)
  local lo=runtime.dispatch{action='loadout',args={},operator=true}
  runtime.board.agents=agents
  eq(#lo.agents,1); eq(lo.agents[1].name,'nick'); eq(lo.agents[1].alive,true); assert(lo.tick and lo.agents[1].items,'loadout rows')
  local reads=runtime.dispatch{action='describe',args={},player=1}.operator_reads
  local listed=false
  for _,r in ipairs(reads) do listed=listed or r=='loadout' end
  assert(listed,'describe lists loadout')
end
-- A hauling hook that throws fails no request (every hook runs under pcall).
do
  local begin,done=runtime.hauling.begin,runtime.hauling.done
  runtime.hauling.begin=function() error('hauling broke') end
  runtime.hauling.done=function() error('hauling broke') end
  eq(type(call('status')),'table')
  runtime.hauling.begin,runtime.hauling.done=begin,done
end
local trip=call('collect',{item='iron-gear-wheel',radius=20,count=25})
eq(trip.stock,30); eq(trip.places,1); eq(call('status').active.kind,'gather')
advance(1)
local gathered=call('status').last
eq(gathered.outcome,'collected'); eq(gathered.got,25); eq(gathered.item,'iron-gear-wheel'); eq(main[1].count,25)
-- A direct walking collect: one direct call, its 25 items, though they moved on a tick after the request.
H[1]=H.read()
eq(H[1].items-H[0].items,25); eq(H[1].direct_items-H[0].direct_items,25); eq(H[1].direct_calls-H[0].direct_calls,1)
eq(H[1].calls-H[0].calls,1); eq(H[1].queue_items-H[0].queue_items,0)
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
  -- The total line (Muse): moved per item, places touched of the total.
  eq(took.tally,'moved 7 iron-plate, 5 iron-gear-wheel; 2 of 2 places touched')
  -- Two places, one call.
  local haul2=H.read()
  eq(haul2.items-H[1].items,12); eq(haul2.direct_calls-H[1].direct_calls,1)
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
  call('queue_repeat',{name='sweep',interval_ticks=60,steps={{action='collect',args={radius=20},on_fail='skip'}}})
  advance(5); eq(result[1].valid_for_read,false)
  advance(70)
  local team=call('status').team
  eq(team and team.queue and team.queue[1],'queue sweep round 2: 1 of 1 steps short: collect nothing_collected')
  advance(70); eq((call('status').team or {}).queue,nil)
  call('queue_cancel',{})
  -- The sweep's 3 plates were a queue step's: one queue call; rounds that took nothing count no call. The 4 of
  -- collect {count=4} before it were direct.
  local haul3=H.read()
  eq(haul3.queue_items-haul2.queue_items,3); eq(haul3.queue_calls-haul2.queue_calls,1)
  eq(haul3.direct_items-haul2.direct_items,4); eq(haul3.items-haul2.items,7); eq(haul3.order_items-haul2.order_items,0)
  -- With up_to=true the plan allowed for the short (Grok, shift10): no line, while its history says short.
  result[1].name,result[1].count,result[1].valid_for_read='iron-plate',3,true
  call('queue_repeat',{name='sweep2',interval_ticks=60,steps={{action='collect',args={radius=20,up_to=true}}}})
  advance(5); eq(result[1].valid_for_read,false)
  advance(70)
  -- (its first round that moved nothing says so once, d15: the shorts it allowed for are no line of their own)
  eq((call('status').team or {}).queue[1],'queue sweep2 round 2 moved nothing (1 item-moving step; 1 round in a row)')
  advance(70)
  eq((call('status').team or {}).queue,nil)
  local h=call('queue_status',{}).history
  local last_step=h[#h].action=='round' and h[#h-1] or h[#h]
  eq(last_step.ok,true); eq(last_step.result.short,true)
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
-- radius alone: around the character (round1650d: Grok, twice in shift13).
eq(call('observe',{scope='supply',item='transport-belt',radius=5}).item,'transport-belt')
fails(function() call('observe',{scope='supply',item='transport-belt',pack='x'}) end,'unknown argument pack for supply; valid: item, near, radius, surface')
fails(function() call('observe',{scope='supply',item='nope'}) end,'item must be an item or fluid name')
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
-- (a type is checked against the prototypes' types first: Astra, shift12 15:10)
prototypes.entity['test-rock']={name='test-rock',type='simple-entity'}
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
prototypes.entity['test-spawner']={name='test-spawner',type='unit-spawner'}; prototypes.entity['test-boiler']={name='test-boiler',type='boiler'}
local grid=call('observe',{scope='scan',area={left_top={x=42,y=0},right_bottom={x=48,y=7}},type='unit-spawner',ore='grid'})
eq(grid.total,1); eq(grid.ore.origin.x,42); eq(grid.ore.rows[2].row,'CC.I~.'); eq(grid.ore.rows[6].row,'.##...')
eq(grid.ore.totals[1].amount,150)
eq(call('observe',{scope='scan',position={x=44,y=4},radius=3}).entities[1].name,'spitter-spawner')
fails(function() call('observe',{scope='scan',fields={'bogus'}}) end,'unknown field')
-- Astra, shift12 15:10: type electric-mining-drill (an entity name) scanned empty, and nine drills looked lost. A type
-- the game does not know is refused with what it names instead, or the types like it (scan, nearest, inspect area).
;(function()
  prototypes.entity['electric-mining-drill']={name='electric-mining-drill',type='mining-drill'}
  local area={left_top={x=42,y=0},right_bottom={x=48,y=7}}
  fails(function() call('observe',{scope='scan',area=area,type='electric-mining-drill'}) end,
    'unknown entity type electric-mining-drill: it is an entity name (its type is mining-drill): name electric-mining-drill, or type mining-drill')
  fails(function() call('observe',{scope='scan',area=area,type='drill'}) end,'unknown entity type drill; types like it: mining-drill')
  fails(function() call('observe',{scope='nearest',type={'boiler','spawners'}}) end,'unknown entity type spawners; types like it: unit-spawner')
  fails(function() call('observe',{scope='scan',area=area,type='gizmo'}) end,'unknown entity type gizmo; types are names such as assembling-machine')
  eq(call('observe',{scope='scan',area=area,type='mining-drill'}).total,0,'a known type with nothing there: an empty result')
  fails(function() call('inspect',{area=area,types={'electric-mining-drill'}}) end,'unknown entity type electric-mining-drill: it is an entity name')
  prototypes.entity['electric-mining-drill']=nil
end)()
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
-- Accumulators in the area read now, per network (Astra, shift14 22:50: the networks view's sum stood still at dusk).
do
  local n=#world
  for i,j in ipairs({1e6,4e6}) do
    world[#world+1]={valid=true,type='accumulator',name='accumulator',position={x=4+i,y=2},force=p.force,electric_network_id=1,
      energy=j,electric_buffer_size=5e6,prototype={electric_energy_source_prototype={}}}
  end
  -- The lines come from the networks read, with the view's age; fresh goes to it.
  local kept_read,asked=runtime.networks.read,nil
  runtime.networks.read=function(_,b) asked=b; return {as_of='40s ago',surfaces={{electric={{id=1,line='nauvis electric #1: ...'},{id=99,line='other'}}}}} end
  local whole=call('observe',{scope='power',area={left_top={x=-1,y=-5},right_bottom={x=40,y=5}}})
  eq(#whole.lines,1); eq(whole.lines_as_of,'40s ago (the networks view; its accumulator part read now)'); eq(asked.fresh,nil)
  local acc=whole.networks[1]
  eq(acc.accumulators,2); eq(acc.acc_mj,5); eq(acc.acc_max_mj,10); eq(acc.acc_pct,50); eq(acc.unpowered,1)
  world[n+1].energy=0
  eq(call('observe',{scope='power',area={left_top={x=-1,y=-5},right_bottom={x=40,y=5}},fresh=true}).networks[1].acc_pct,40)
  eq(asked.fresh,true)
  runtime.networks.read=kept_read
  fails(function() call('observe',{scope='power',area={left_top={x=-1,y=-5},right_bottom={x=40,y=5}},fresh='yes'}) end,'fresh must be true or false')
  while #world>n do table.remove(world) end
end
-- Generators by state and boilers (Sol, d15 09:20: a 94 MW grid gave about 40 MW, its boilers dry).
do
  local n=#world
  local function engine(x,status)
    world[#world+1]={valid=true,type='generator',name='steam-engine',position={x=x,y=3},force=p.force,electric_network_id=1,status=status,
      prototype={electric_energy_source_prototype={},get_max_power_output=function() return 15000 end}}
  end
  engine(11,defines.entity_status.working); engine(12,defines.entity_status.working); engine(13,defines.entity_status.no_input_fluid or 77)
  world[#world+1]={valid=true,type='boiler',name='boiler',position={x=14,y=3},force=p.force,status=defines.entity_status.no_fuel or 78,prototype={}}
  local kept=runtime.machine_status
  runtime.machine_status=function(e) if e.type=='boiler' then return 'no_fuel' end return e.status==defines.entity_status.working and 'working' or 'no_input_fluid' end
  local r=call('observe',{scope='power',area={left_top={x=-1,y=-5},right_bottom={x=40,y=5}}})
  local g=r.networks[1].generators
  eq(g.count,3); eq(g.nameplate_kw,2700); eq(g.working_kw,1800); eq(g.stopped_kw,900); eq(g.stopped[1],'1 steam-engine no_input_fluid')
  assert(r.networks[1].supply_line:find('nameplate 2.7 MW; working now 1.8 MW',1,true),r.networks[1].supply_line)
  eq(r.boilers,'boilers in the area: 1 (1 no_fuel)')
  runtime.machine_status=kept
  while #world>n do table.remove(world) end
end
-- On a platform by name or index (Astra, 13:10): its surface, 64 tiles round its hub unless an area is given.
do
  local kept=p.force.platforms
  p.force.platforms={{valid=true,name='Starling',index=3,surface=p.surface,hub={valid=true,position={x=0,y=0}}}}
  for _,which in ipairs({'Starling',3}) do
    local pp=call('observe',{scope='power',platform=which})
    eq(pp.platform,'Starling'); eq(#pp.networks,3); eq(#pp.unpowered,2)
  end
  fails(function() call('observe',{scope='power',platform='Nope'}) end,'no platform named Nope')
  -- A network with no pole in the area (Astra, 14:05: Starling's 475): listed from its machines, without figures.
  local n=#world
  machine(6,475,defines.entity_status.low_power); machine(8,475,defines.entity_status.working)
  local pp=call('observe',{scope='power',platform='Starling'})
  local lone
  for _,x in ipairs(pp.networks) do if x.id==475 then lone=x end end
  assert(lone,'network 475 listed'); eq(lone.poles,0); eq(lone.entities,2); eq(lone.unpowered,1)
  eq(lone.note,'no pole of ours in the area: the game gives a network\'s statistics through its poles')
  while #world>n do table.remove(world) end
  p.force.platforms=kept
end
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
body.get_main_inventory=function() return {find_item_stack=function() return chests end,get_item_count=function(f) return f.name=='iron-chest' and chests.count or 0 end} end
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
body.get_main_inventory=function() return {find_item_stack=function() return ugs end,get_item_count=function(f) return f.name=='underground-belt' and ugs.count or 0 end} end
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
eq(exit.entity.belt,'moves items west to (-6.5,-27.5) (no belt takes them there: they stop at its end); fed underground from (-3.5,-27.5)')
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
-- A turret ghost requests ammo (turretammo.lua; Astra, shift10: turrets rebuilt empty and destroyed again): the
-- call's ammo, an entry's own (false: none); the reply counts the requests; a bad ammo argument fails the call, or
-- just its entry.
do
  local entity_protos,item_protos,filtered=prototypes.entity,prototypes.item,prototypes.get_item_filtered
  local can,create,net=p.surface.can_place_entity,p.surface.create_entity,p.surface.find_logistic_network_by_position
  local gun={name='gun-turret',type='ammo-turret',items_to_place_this={{name='gun-turret',count=1}},attack_parameters={ammo_categories={'bullet'}},
    automated_ammo_count=10,get_inventory_size=function() return 1 end}
  prototypes.entity={['gun-turret']=gun}
  prototypes.item={['firearm-magazine']={type='ammo',order='a',stack_size=200,ammo_category={name='bullet'}},['iron-plate']={type='item'}}
  prototypes.get_item_filtered=function() return {['firearm-magazine']=prototypes.item['firearm-magazine']} end
  local made={}
  p.surface.can_place_entity=function() return true end
  p.surface.find_logistic_network_by_position=function() return nil end
  p.surface.create_entity=function(a)
    local g={valid=true,type='entity-ghost',ghost_type='ammo-turret',ghost_name=a.inner_name,ghost_prototype=gun,position=a.position,
      surface=p.surface,force=p.force,insert_plan={}}
    made[#made+1]=g; return g
  end
  local r=call('place_ghosts',{entities={{name='gun-turret',position={x=10,y=4}},{name='gun-turret',position={x=12,y=4},ammo=false}},ammo={count=30}})
  eq(r.placed,2); eq(#r.ammo_requests,1); eq(r.ammo_requests[1].item,'firearm-magazine'); eq(r.ammo_requests[1].count,30)
  eq(r.ammo_requests[1].ghosts,1); eq(r.ammo_requests[1].network_holds,nil)
  eq(made[1].insert_plan[1].items.in_inventory[1].count,30); eq(#made[2].insert_plan,0)
  eq(call('place_ghosts',{entities={{name='gun-turret',position={x=10,y=4}}}}).ammo_requests[1].count,10,'the default count')
  fails(function() call('place_ghosts',{entities={{name='gun-turret',position={x=10,y=4}}},ammo='iron-plate'}) end,'not an ammo item: iron-plate')
  local bad=call('place_ghosts',{entities={{name='gun-turret',position={x=14,y=4},ammo='iron-plate'},{name='gun-turret',position={x=16,y=4}}}})
  eq(bad.placed,1); assert(bad.failed[1].error:find('not an ammo item',1,true),bad.failed[1].error)
  -- An assembling machine ghost takes its recipe in the same call (checked first: a refused one places nothing).
  local am={name='assembling-machine-2',type='assembling-machine',items_to_place_this={{name='assembling-machine-2',count=1}},crafting_categories={crafting=true}}
  prototypes.entity['assembling-machine-2']=am
  local saved_recipes=p.force.recipes
  p.force.recipes={['iron-gear-wheel']={name='iron-gear-wheel',enabled=true,category='crafting'},sulfur={name='sulfur',enabled=true,category='chemistry'}}
  p.surface.create_entity=function(a)
    local g={valid=true,type='entity-ghost',ghost_type=prototypes.entity[a.inner_name].type,ghost_name=a.inner_name,ghost_prototype=prototypes.entity[a.inner_name],
      position=a.position,surface=p.surface,force=p.force,insert_plan={}}
    g.set_recipe=function(r) g.recipe=r; return {} end
    g.get_recipe=function() return g.recipe and {name=g.recipe} or nil end
    made[#made+1]=g; return g
  end
  local before=#made
  r=call('place_ghosts',{entities={{name='assembling-machine-2',position={x=20.5,y=4.5},recipe='iron-gear-wheel'},
    {name='assembling-machine-2',position={x=24.5,y=4.5},recipe='sulfur'},{name='gun-turret',position={x=28,y=4},recipe='iron-gear-wheel'}}})
  eq(r.placed,1); eq(r.recipes['iron-gear-wheel'],1); eq(made[before+1].recipe,'iron-gear-wheel'); eq(#made,before+1)
  eq(r.failed[1].error,'recipe sulfur (category chemistry) is not one assembling-machine-2 makes (its categories: crafting)')
  eq(r.failed[2].error,'recipe: gun-turret (type ammo-turret) takes no recipe; only assembling machines (assemblers, foundries, chemical plants and the like) do')
  p.force.recipes=saved_recipes
  prototypes.entity,prototypes.item,prototypes.get_item_filtered=entity_protos,item_protos,filtered
  p.surface.can_place_entity,p.surface.create_entity,p.surface.find_logistic_network_by_position=can,create,net
end
-- Placed belt ghosts: the last one says where it moves items, read once the call's ghosts stand (beltflow.lua;
-- Grok, shift11: a belt facing south read as feeding the tile at lower y).
;(function()
  local entity_protos=prototypes.entity
  local can,create,find=p.surface.can_place_entity,p.surface.create_entity,p.surface.find_entities_filtered
  local belt={name='transport-belt',type='transport-belt',items_to_place_this={{name='transport-belt',count=1}}}
  prototypes.entity={['transport-belt']=belt}
  local made={}
  p.surface.can_place_entity=function() return true end
  p.surface.create_entity=function(a)
    local g={valid=true,name='entity-ghost',type='entity-ghost',ghost_type='transport-belt',ghost_name=a.inner_name,ghost_prototype=belt,
      position=a.position,direction=a.direction,surface=p.surface,force=p.force}
    made[#made+1]=g; return g
  end
  p.surface.find_entities_filtered=function(f)
    local out={}
    if type(f.type)=='table' and f.area and f.area[1] then
      for _,g in ipairs(made) do
        if g.position.x>=f.area[1][1] and g.position.x<=f.area[2][1] and g.position.y>=f.area[1][2] and g.position.y<=f.area[2][2] then out[#out+1]=g end
      end
    end
    return out
  end
  local r=call('place_ghosts',{entities={{name='transport-belt',position={x=20.5,y=4.5},direction='south'},{name='transport-belt',position={x=20.5,y=5.5},direction='south'}}})
  eq(r.placed,2,r.failed and r.failed[1].error); eq(r.last_belt,'transport-belt (20.5,5.5): moves items south to (20.5,6.5); fed from (20.5,4.5)')
  prototypes.entity=entity_protos
  p.surface.can_place_entity,p.surface.create_entity,p.surface.find_entities_filtered=can,create,find
end)()
-- Settings on place_ghosts entries (entryset.lua; Sol, shift13 19:50: a bio cell took about 10 configure and wire
-- round trips): argument names checked before anything is placed; set after every entry stands, by the real
-- configure; a refused setting is that entry's row and its ghost stays.
;(function()
  local entity_protos=prototypes.entity
  local can,create,find=p.surface.can_place_entity,p.surface.create_entity,p.surface.find_entities_filtered
  local am={name='assembling-machine-2',type='assembling-machine',items_to_place_this={{name='assembling-machine-2',count=1}},crafting_categories={crafting=true}}
  prototypes.entity={['assembling-machine-2']=am}
  local saved_recipes=p.force.recipes
  p.force.recipes={['iron-gear-wheel']={name='iron-gear-wheel',enabled=true,category='crafting'},sulfur={name='sulfur',enabled=true,category='chemistry'}}
  local made={}
  p.surface.can_place_entity=function() return true end
  p.surface.create_entity=function(a)
    local g={valid=true,name='entity-ghost',type='entity-ghost',ghost_type='assembling-machine',ghost_name=a.inner_name,ghost_prototype=am,
      position=a.position,surface=p.surface,force=p.force}
    g.set_recipe=function(r) g.recipe=r; return {} end
    g.get_recipe=function() return g.recipe and {name=g.recipe} or nil end
    made[#made+1]=g; return g
  end
  p.surface.find_entities_filtered=function(f)
    local out={}
    for _,g in ipairs(made) do
      if f.position and math.abs(g.position.x-f.position.x)<=(f.radius or 0.5) and math.abs(g.position.y-f.position.y)<=(f.radius or 0.5)
        and (f.name==nil or f.name==g.name) and (f.ghost_name==nil or f.ghost_name==g.ghost_name) then out[#out+1]=g end
    end
    return out
  end
  fails(function() call('place_ghosts',{entities={{name='assembling-machine-2',position={x=20.5,y=4.5},circuit={bogus=1}}}}) end,'unknown argument bogus for circuit_set')
  fails(function() call('place_ghosts',{entities={{name='assembling-machine-2',position={x=20.5,y=4.5},configure={position={x=1,y=1},recipe='iron-gear-wheel'}}}}) end,
    'entry 1: configure takes the entry\'s position')
  eq(#made,0,'refused before anything is placed')
  local dry=call('place_ghosts',{dry_run=true,entities={{name='assembling-machine-2',position={x=20.5,y=4.5},configure={recipe='iron-gear-wheel'}}}})
  eq(dry.settings_planned[1].would_set,'configure (recipe)'); eq(#made,0)
  local r=call('place_ghosts',{entities={{name='assembling-machine-2',position={x=20.5,y=4.5},configure={recipe='iron-gear-wheel'}},
    {name='assembling-machine-2',position={x=24.5,y=4.5},configure={recipe='sulfur'}},{name='assembling-machine-2',position={x=28.5,y=4.5}}}})
  eq(r.placed,3); eq(made[1].recipe,'iron-gear-wheel'); eq(made[2].recipe,nil); eq(#r.settings,2)
  eq(r.settings[1].configure,'set'); eq(r.settings[2].index,2); eq(r.settings[2].configure,'recipe incompatible with machine')
  eq(r.settings_line,'settings: 1 set, 1 refused: entry 2 configure: recipe incompatible with machine')
  -- build: a single build's own settings and a batch's entries, checked before anything is built.
  fails(function() call('build',{item='assembling-machine-2',position={x=30.5,y=4.5},circuit={bogus=1}}) end,'unknown argument bogus for circuit_set')
  fails(function() call('build',{builds={{item='assembling-machine-2',position={x=30.5,y=4.5}},{item='assembling-machine-2',position={x=34.5,y=4.5},
    wires={{to={x=30.5,y=4.5},colour='red'}}}}}) end,'entry 2 wire 1: {to {x,y}, color red|green')
  eq(#made,3,'nothing built')
  p.force.recipes=saved_recipes
  prototypes.entity=entity_protos
  p.surface.can_place_entity,p.surface.create_entity,p.surface.find_entities_filtered=can,create,find
end)()
;(function()
  -- place_ghosts, its dry run and scan on another planet by remote view (Astra 12:33: laying out a Vulcanus chain while
  -- Sonnet builds there by hand; in 2.0 a player places ghosts on another planet from the map).
  local entity_protos,get_surface,platforms,charted=prototypes.entity,game.get_surface,p.force.platforms,p.force.is_chunk_charted
  local belt={name='transport-belt',type='transport-belt',items_to_place_this={{name='transport-belt',count=1}},
    collision_box={left_top={x=-0.4,y=-0.4},right_bottom={x=0.4,y=0.4}},collision_mask={layers={item=true,object=true}},
    tile_width=1,tile_height=1}
  prototypes.entity={['transport-belt']=belt}
  local made,standing={},{}
  local vulcanus={name='vulcanus',index=3,valid=true}
  vulcanus.get_tile=function(x,y) return {name='volcanic-ash-light',position={x=x,y=y},prototype={collision_mask={layers={ground_tile=true}}},
    collides_with=function() return false end} end
  vulcanus.find_entities_filtered=function(f)
    local out={}
    for _,e in ipairs(standing) do if not f.type or f.type==e.type or (type(f.type)=='table') then out[#out+1]=e end end
    return out
  end
  vulcanus.count_entities_filtered=function(f) return #vulcanus.find_entities_filtered(f) end
  vulcanus.can_place_entity=function() return true end
  vulcanus.create_entity=function(a)
    local g={valid=true,name='entity-ghost',type='entity-ghost',ghost_type='transport-belt',ghost_name=a.inner_name,ghost_prototype=belt,
      position=a.position,direction=a.direction,surface=vulcanus,force=p.force}
    made[#made+1]=g; return g
  end
  game.get_surface=function(name) if name=='vulcanus' then return vulcanus end end
  p.force.platforms={}
  p.force.is_chunk_charted=function(sf,c) if sf==vulcanus then return c.x==0 and c.y==0 end return charted(sf,c) end
  local r=call('place_ghosts',{surface='vulcanus',entities={{name='transport-belt',position={x=5.5,y=5.5},direction='east'}}})
  eq(r.placed,1); eq(#made,1); eq(made[1].surface,vulcanus); eq(made[1].position.x,5.5)
  r=call('place_ghosts',{surface='vulcanus',entities={{name='transport-belt',position={x=50.5,y=5.5}}}})
  eq(r.placed,0); eq(r.failed[1].error,'position is not charted','charted chunks of that planet')
  -- The dry run checks there and places nothing.
  local dry=call('place_ghosts',{surface='vulcanus',dry_run=true,entities={{name='transport-belt',position={x=6.5,y=5.5},direction='east'}}})
  eq(dry.dry_run,true); eq(#made,1,'nothing placed')
  fails(function() call('place_ghosts',{surface='vulcanus',platform='Sunward',entities={{name='transport-belt',position={x=6.5,y=5.5}}}}) end,
    'give platform or surface, not both')
  -- preflight's platform is where the rocket goes, as launch's (Astra, shift14 03:09 and 04:24: refused here): the
  -- call reaches the silo lookup there.
  for _,name in ipairs({'preflight','launch'}) do
    fails(function() call(name,{surface='vulcanus',platform='Sunward',position={x=5.5,y=5.5}}) end,'no entity of ours at (5.5,5.5) on vulcanus')
  end
  -- scan there: centred on a place there.
  standing[1]={valid=true,name='transport-belt',type='transport-belt',position={x=5.5,y=5.5},direction=4,force=p.force,surface=vulcanus}
  local sc=call('scan',{surface='vulcanus',position={x=5,y=5},radius=4})
  eq(sc.entities[1].name,'transport-belt')
  -- A cargo pod container: where it stands and what it holds, unasked (Sonnet, shift14 22:50).
  standing[2]={valid=true,name='cargo-pod-container',type='container',position={x=6.5,y=6.5},force=p.force,surface=vulcanus,
    get_inventory=function() return {get_contents=function() return {{name='advanced-circuit',count=1945,quality='normal'}} end} end}
  sc=call('scan',{surface='vulcanus',position={x=5,y=5},radius=4})
  eq(sc.entities[2].name,'cargo-pod-container'); eq(sc.entities[2].position.x,6.5); eq(sc.entities[2].holds,'advanced-circuit*1945')
  standing[2]=nil
  fails(function() call('scan',{surface='vulcanus'}) end,'scan with surface needs position, area or positions there')
  -- deconstruct marks there too (Sol, 23:13: marks on a planet from a platform).
  standing[1].minable=true; standing[1].order_deconstruction=function() standing[1].marked=true; return true end
  local find=vulcanus.find_entities_filtered
  vulcanus.find_entities_filtered=function(f) if f.invert then return standing end return find(f) end
  local dc=call('deconstruct',{surface='vulcanus',area={left_top={x=0,y=0},right_bottom={x=10,y=10}}})
  eq(dc.changed,1); eq(standing[1].marked,true)
  vulcanus.find_entities_filtered=find
  prototypes.entity,game.get_surface,p.force.platforms,p.force.is_chunk_charted=entity_protos,get_surface,platforms,charted
end)()
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
  turret.name='gun-turret'; turret.tile_width=2; turret.tile_height=2; turret.collision_mask={layers={object=true}}
  turret.collision_box={left_top={x=-0.7,y=-0.7},right_bottom={x=0.7,y=0.7}}
  local turret_item=prototypes.item['gun-turret']
  prototypes.item['gun-turret']={name='gun-turret',place_result=turret}
  ghosts={}
  call('walk',{direction='east',ticks=100})
  local dry=call('place_ghosts',{entities={{name='gun-turret',position={x=10,y=0}},{name='gun-turret',position={x=40,y=0}}},dry_run=true})
  eq(dry.dry_run,true); eq(dry.action,'place_ghosts'); eq(#ghosts,0,'a dry run places nothing')
  eq(dry.entities[1].index,2); eq(dry.entities[1].status,'blocked'); eq(dry.summary,'1 placeable, 1 blocked (of 2)')
  eq(call('status').active.kind,'walk','a dry run leaves the walk going')
  local shifted=call('place_ghosts',{entities={{name='gun-turret',position={x=10,y=0}}},['repeat']={count=4,dx=10},dry_run=true})
  eq(shifted.checked,4); eq(shifted.entities[1].index,'4.1'); eq(#ghosts,0)
  -- A recipe with an entry: the dry run makes the real call's check (Sonnet, shift12 13:50).
  ;(function()
    local saved_am,saved_recipes=prototypes.entity['assembling-machine-2'],p.force.recipes
    prototypes.entity['assembling-machine-2']={name='assembling-machine-2',type='assembling-machine',tile_width=3,tile_height=3,collision_mask={layers={object=true}},
      collision_box={left_top={x=-1.2,y=-1.2},right_bottom={x=1.2,y=1.2}},items_to_place_this={{name='assembling-machine-2',count=1}},crafting_categories={crafting=true}}
    p.force.recipes={['iron-gear-wheel']={name='iron-gear-wheel',enabled=true,category='crafting'},sulfur={name='sulfur',enabled=true,category='chemistry'}}
    local dr=call('place_ghosts',{entities={{name='assembling-machine-2',position={x=10.5,y=0.5},recipe='iron-gear-wheel'},
      {name='assembling-machine-2',position={x=14.5,y=0.5},recipe='sulfur'}},dry_run=true})
    eq(dr.recipes['iron-gear-wheel'],1); eq(#ghosts,0); assert(dr.summary:find('; 1 refused for the recipe',1,true),dr.summary)
    eq(dr.recipes_refused[1],'entry 2 assembling-machine-2: recipe sulfur (category chemistry) is not one assembling-machine-2 makes (its categories: crafting)')
    prototypes.entity['assembling-machine-2'],p.force.recipes=saved_am,saved_recipes
  end)()
  fails(function() call('place_ghosts',{entities={{name='gun-turret',position={x=10,y=0}}},facing='east',dry_run=true}) end,'unknown argument facing for place_ghosts')
  fails(function() call('build',{item='gun-turret',position={x=3,y=0},dry_run='true'}) end,'dry_run must be true or false')
  -- A build dry run names the entry the batch stops at.
  local ghost_engine=p.surface.can_place_entity
  defines.build_check_type.manual=0
  p.surface.can_place_entity=function(a) eq(a.build_check_type,0); eq(a.forced,nil); return true end
  local px,py=math.floor(p.position.x),math.floor(p.position.y)
  local far=call('build',{builds={{item='gun-turret',position={x=px+2,y=py}},{item='gun-turret',position={x=px+30,y=py}}},dry_run=true})
  eq(far.materials[1].item,'gun-turret');eq(far.materials[1].need,2)
  eq(far.action,'build'); assert(far.build_note:find('entry #2 (out of reach: ',1,true),far.build_note)
  -- Entries naming what to place by name (round1820a, Opus 00:42: 12 drills refused "item is required"): name is item.
  do
    local named=call('build',{builds={{name='gun-turret',position={x=px+2,y=py}},{name='gun-turret',position={x=px+30,y=py}}},dry_run=true})
    eq(named.action,'build'); assert(named.build_note:find('entry #2 (out of reach: ',1,true),named.build_note)
    assert(tostring(named.corrected):find('(name is item)',1,true),tostring(named.corrected))
  end
  p.surface.can_place_entity=ghost_engine
  -- A plan past the bounds is refused before any check.
  local twenty={}
  for i=1,20 do twenty[i]={name='gun-turret',position={x=10+2*i,y=0}} end
  fails(function() call('place_ghosts',{entities=twenty,['repeat']={count=64,dx=0,dy=2},dry_run=true}) end,'a dry run checks at most 1024 entities')
  eq(call('status').active.kind,'walk','a failed dry run stops nothing')
  -- A paste dry run checks where the blueprint lands (blueprints.lua plan, stubbed here); with an entry
  -- the game refuses now, a normal paste places nothing at all.
  local real_plan=runtime.paste_plan
  runtime.paste_plan=function(_,a)
    return {entities={{index=1,name='gun-turret',position={x=a.position.x,y=0},direction=0},{index=2,name='gun-turret',position={x=40,y=0},direction=0}},
      tiles={},slot='bp',mode='normal',origin_at={x=a.position.x,y=0},center_at={x=a.position.x,y=0}}
  end
  local ghost_check=p.surface.can_place_entity
  -- A normal paste asks the engine without forced (it marks nothing).
  p.surface.can_place_entity=function(a) eq(a.build_check_type,2); eq(a.forced,nil); return a.position.x~=40 end
  local pd=call('paste',{position={x=10,y=0},dry_run=true})
  eq(pd.action,'paste'); eq(pd.paste.slot,'bp'); eq(#ghosts,0); eq(pd.summary,'1 placeable, 1 blocked (of 2)')
  assert(pd.paste_note:find('all or nothing: with 1 entry the game refuses there now',1,true),pd.paste_note)
  local rp=call('paste',{position={x=10,y=0},['repeat']={count=2,dx=4},dry_run=true})
  eq(rp.checked,4); eq(rp.entities[#rp.entities].index,'2.2'); assert(rp.entities[#rp.entities].why:find('collides with planned #1.2',1,true))
  eq(call('paste',{position={x=10,y=0},dryrun=true}).action,'paste','dryrun is dry_run')
  p.surface.can_place_entity=function(a) eq(a.build_check_type,2); eq(a.forced,true); return a.position.x~=40 end
  eq(call('paste',{position={x=10,y=0},mode='forced',dry_run=true}).summary,'1 placeable, 1 blocked (of 2)','forced asks with forced')
  p.surface.can_place_entity=ghost_check
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
  prototypes.item['gun-turret']=turret_item
end
-- Rail ramp refusals list the same entire footprint as the dry run, including
-- entries after the old four-blocker/16-search-result limits.
;(function()
  local surface, old_proto = p.surface, prototypes.entity['rail-ramp']
  local find,can,get,create = surface.find_entities_filtered,surface.can_place_entity,surface.get_tile,surface.create_entity
  local ramp={name='rail-ramp',type='rail-ramp',items_to_place_this={{name='rail-ramp',count=1}},
    collision_box={left_top={x=-1.59765625,y=-7.59765625},right_bottom={x=1.59765625,y=7.59765625}},
    collision_mask={layers={object=true,is_object=true,rail=true}}}
  prototypes.entity['rail-ramp']=ramp
  local collisions={}
  for i=1,20 do collisions[#collisions+1]={valid=true,name='iron-ore',type='resource',position={x=-43,y=106}} end
  for i=1,6 do
    local e={valid=true,name=i==6 and 'medium-electric-pole' or 'accumulator',type=i==6 and 'electric-pole' or 'accumulator',
      position={x=-43.5,y=97.5+i},force=p.force,prototype={collision_mask={layers={object=true}}}}
    e.to_be_deconstructed=function() return i==1 end
    collisions[#collisions+1]=e
  end
  collisions[#collisions+1]={valid=true,name='cliff-fulgora',type='cliff',position={x=-38,y=102.5},
    prototype={collision_mask={layers={is_object=true}}}}
  surface.find_entities_filtered=function(f)
    if f.type then return {} end
    if f.area then
      eq(f.limit,nil,'ramp footprint search is complete')
      return collisions
    end
    return {}
  end
  local gate_calls=0
  surface.can_place_entity=function(a)
    gate_calls=gate_calls+1
    eq(a.name,'rail-ramp');eq(a.position.x,-43);eq(a.position.y,106);eq(a.direction,8)
    eq(a.forced,true);eq(a.build_check_type,defines.build_check_type.manual_ghost)
    return false
  end
  surface.get_tile=function() return {name='grass-1',prototype={collision_mask={layers={ground_tile=true}}}} end
  surface.create_entity=function() error('refused ramp must not place anything') end
  local args={entities={{name='rail-ramp',position={x=-44,y=105},direction=11}}}
  local preview=call('dry_run',{action='place_ghosts',args=args})
  eq(preview.entities[1].status,'blocked');eq(#preview.entities[1].collisions,7)
  eq(preview.entities[1].asked.x,-44);eq(preview.entities[1].direction,'south')
  local result=call('place_ghosts',args)
  eq(result.placed,0)
  local message=result.failed[1].error
  for _,text in ipairs({'medium-electric-pole (-43.5,103.5)','cliff-fulgora (-38,102.5)','marked for deconstruction; still present'}) do
    assert(message:find(text,1,true),message)
    assert(preview.entities[1].why:find(text,1,true),preview.entities[1].why)
  end
  assert(not message:find('iron-ore',1,true),message)
  eq(gate_calls,2,'preview and placement use the same gate')
  surface.find_entities_filtered,surface.can_place_entity,surface.get_tile,surface.create_entity=find,can,get,create
  prototypes.entity['rail-ramp']=old_proto
end)()
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
-- Sol, shift09 01:38: 5 of 16 medium poles on Gleba wetland. The forced ghost check takes a pole there once the force
-- has landfill (a player's forced placement lays landfill under it), and a lone script ghost was never built. pole_route
-- now takes a dry spot within 2 tiles first, else lays the landfill tile ghost under the pole and says so.
do
local WET={layers={water_tile=true,floor=true,resource=true}}
prototypes.tile=prototypes.tile or {}
prototypes.tile['wetland-blue-slime']={name='wetland-blue-slime',collision_mask=WET}
prototypes.tile['grass-1']={name='grass-1',collision_mask={layers={ground_tile=true}}}
prototypes.tile['landfill']={name='landfill',collision_mask={layers={ground_tile=true}}}
prototypes.entity['medium-electric-pole']={name='medium-electric-pole',type='electric-pole',items_to_place_this={{name='medium-electric-pole',count=1}},
  max_wire_distance=9,collision_box={left_top={x=-0.15,y=-0.15},right_bottom={x=0.15,y=0.15}},
  collision_mask={layers={water_tile=true,object=true,item=true,player=true}}}
prototypes.item['medium-electric-pole']={place_result=prototypes.entity['medium-electric-pole']}
prototypes.item['landfill']={place_as_tile_result={result=prototypes.tile['landfill'],condition={layers={ground_tile=true}}}}
-- Wetland: a 1x3 patch at x 8 (y -1..1) a 2-tile shift avoids, and a band at x 16..20 it cannot.
local function wet(x,y) return (x==8 and y>=-1 and y<=1) or (x>=16 and x<=20) end
local made={}
p.surface.get_tile=function(x,y)
  local name=wet(math.floor(x),math.floor(y)) and 'wetland-blue-slime' or 'grass-1'
  for _,m in ipairs(made) do if m.name=='tile-ghost' and m.laid and math.floor(m.position.x)==math.floor(x) and math.floor(m.position.y)==math.floor(y) then name='landfill' end end
  return {valid=true,name=name,prototype=prototypes.tile[name]}
end
p.surface.find_entities_filtered=function(f)
  local out={}
  for _,m in ipairs(made) do
    if f.type=='tile-ghost' and m.name=='tile-ghost' and f.position and math.abs(m.position.x-f.position.x)<0.2 and math.abs(m.position.y-f.position.y)<0.2 then
      out[#out+1]={valid=true,type='tile-ghost',ghost_name=m.inner_name,position=m.position}
    end
  end
  return out
end
p.surface.can_place_entity=function() return true end -- the forced ghost check, with landfill unlocked, takes all of it
p.surface.create_entity=function(a) made[#made+1]=a; return {valid=true,position=a.position,type=a.name,ghost_type='electric-pole',ghost_name=a.inner_name,destroy=function() end} end
p.get_main_inventory=function() return {get_item_count=function(n) return n=='medium-electric-pole' and 10 or 0 end} end
local plan=call('pole_route',{from={x=0.5,y=0.5},to={x=24.5,y=0.5},item='medium-electric-pole',dry_run=true})
eq(plan.spacing,8); eq(plan.poles,4)
eq(plan.positions[2].x,8.5); eq(plan.positions[2].y,2.5) -- the patch: shifted 2 tiles to a dry spot
eq(plan.positions[3].x,16.5); eq(plan.positions[3].y,0.5) -- the band: no dry spot within 2 tiles
eq(plan.tiles_under.landfill,1); eq(plan.tiles_short.landfill,1); eq(#made,0)
eq(plan.tiles_note,'1 pole with no dry spot within 2 tiles stands on wetland-blue-slime: 1 landfill under it, which the real call lays as tile ghosts for construct to build first')
local laid=call('pole_route',{from={x=0.5,y=0.5},to={x=24.5,y=0.5},item='medium-electric-pole'})
eq(laid.placed,4)
local tile_ghosts={}
for i,m in ipairs(made) do if m.name=='tile-ghost' then tile_ghosts[#tile_ghosts+1]={i=i,m=m} end end
eq(#tile_ghosts,1); eq(tile_ghosts[1].m.inner_name,'landfill'); eq(tile_ghosts[1].m.position.x,16.5); eq(tile_ghosts[1].m.position.y,0.5)
-- the landfill ghost goes down before the pole ghost on it
local pole_i
for i,m in ipairs(made) do if m.name=='entity-ghost' and m.position.x==16.5 then pole_i=i end end
assert(pole_i and tile_ghosts[1].i<pole_i)
-- place_ghosts the same way: a pole on the band gets its landfill ghost and a note
made={}
local pg=call('place_ghosts',{entities={{name='medium-electric-pole',position={x=18.5,y=4.5}}}})
eq(pg.placed,1); eq(pg.tiles_laid.landfill,1)
eq(pg.tiles_note,'1 ghost stands on wetland-blue-slime: 1 landfill tile ghost laid under it, which construct builds first (it takes the items from your inventory)')
-- with landfill not researched the ghost is refused, naming the tile (a tree on the spot let the check through)
local recipes=p.force.recipes
p.force.recipes={landfill={enabled=false}}
made={}
pg=call('place_ghosts',{entities={{name='medium-electric-pole',position={x=18.5,y=4.5}}}})
eq(pg.placed,0); eq(pg.failed[1].error,'placement blocked by tiles: wetland-blue-slime at (18.5,4.5) (needs landfill (not researched))'); eq(#made,0)
p.force.recipes=recipes
p.surface.get_tile=nil
end
-- belt_route plans around obstacles and places the line as ghosts, with
-- underground ends typed; dry_run only plans; missing items are counted.
prototypes.entity['transport-belt']={name='transport-belt',type='transport-belt',items_to_place_this={{name='transport-belt',count=1}},
  related_underground_belt={name='underground-belt',type='underground-belt',max_underground_distance=5}}
prototypes.entity['underground-belt']={name='underground-belt',type='underground-belt',items_to_place_this={{name='underground-belt',count=1}}}
local made={ghosts={}}
p.surface.find_entities_filtered=function(f)
  -- (the search for belts and belt ghosts around the last belt ghost placed: last_belt)
  local out={}
  if type(f.type)=='table' and f.area and f.area[1] then
    for _,g in ipairs(made.ghosts) do
      if g.position.x>=f.area[1][1] and g.position.x<=f.area[2][1] and g.position.y>=f.area[1][2] and g.position.y<=f.area[2][2] then out[#out+1]=g end
    end
  end
  return out
end
p.surface.can_place_entity=function(a) return a.position.x~=3.5 end
p.surface.create_entity=function(a)
  made[#made+1]=a
  local proto=prototypes.entity[a.inner_name]
  made.ghosts[#made.ghosts+1]={valid=true,type='entity-ghost',ghost_type=proto and proto.type,ghost_name=a.inner_name,ghost_prototype=proto,
    position=a.position,direction=a.direction,belt_to_ground_type=a.type,surface=p.surface,force=p.force}
  return made.ghosts[#made.ghosts]
end
p.get_main_inventory=function() return {get_item_count=function(n) return n=='transport-belt' and 1 or 0 end} end
local plan=call('belt_route',{from={x=0,y=0},to={x=6,y=0},dry_run=true})
eq(plan.dry_run,true); eq(#made,0); eq(plan.missing['underground-belt'],2); eq(plan.entities,nil)
local routed=call('belt_route',{from={x=0,y=0},to={x=6,y=0}})
eq(routed.placed,routed.tiles); eq(routed.route,plan.belt_route.route); eq(routed.route,'E2 uE3 E1'); eq(plan.summary,'5 placeable (of 5)'); eq(storage.agent_harness.last_paste[1].right,6.5)
local kinds={}
for _,a in ipairs(made) do if a.type then kinds[#kinds+1]=a.type..'@'..a.position.x end end
eq(table.concat(kinds,','),'input@2.5,output@5.5')
eq(routed.last_belt,'transport-belt (6.5,0.5): moves items east to (7.5,0.5); fed from (5.5,0.5)')
p.surface.find_entities_filtered=function() return {} end
p.surface.create_entity=function(a) made[#made+1]=a; return {valid=true,position=a.position} end
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
-- Astra 08:19: a pipe ghost at an end with pumps=true failed 'Unknown entity name: pipe(ghost)' (the ghost's label went
-- into a find). The fake finds as the engine does: an unknown name is an error.
do
  local find=p.surface.find_entities_filtered
  local ghost={valid=true,type='entity-ghost',name='entity-ghost',ghost_name='pipe',ghost_type='pipe',ghost_prototype=prototypes.entity.pipe,
    position={x=6.5,y=0.5},direction=0,force=p.force,unit_number=4242,bounding_box={left_top={x=6.2,y=0.2},right_bottom={x=6.8,y=0.8}}}
  local function names(v) return type(v)=='table' and v or {v} end
  p.surface.find_entities_filtered=function(f)
    for _,n in ipairs(names(f.name or {})) do assert(prototypes.entity[n],'Unknown entity name: '..n) end
    for _,n in ipairs(names(f.ghost_name or {})) do assert(prototypes.entity[n],'Unknown entity name: '..n) end
    local named=f.ghost_name or f.type=='entity-ghost'
    local here=f.position and math.abs(f.position.x-6.5)<=0.5 and math.abs(f.position.y-0.5)<=0.5
    if (named and not f.position) or here or (f.area and not f.name) then return {ghost} end
    return {}
  end
  local r=call('pipe_route',{from={x=0,y=0},to={x=6.5,y=0.5},pumps=true,dry_run=true})
  eq(r.joins.to.name,'pipe'); eq(r.joins.to.ghost,true); eq(r.segment_extent,7)
  p.surface.find_entities_filtered=find
  -- A dry run with a waypoint plans leg 2 off leg 1's tiles: back west along y=0 (W8 alone) is taken. (East of the
  -- fake's blocked column x=3.)
  local legs=call('pipe_route',{from={x=5,y=0},to={x=4,y=0},waypoints={{x=11,y=0}},undergrounds=false,dry_run=true})
  eq(legs.legs,2); assert(legs.route:find('^E7 | ') and not legs.route:find('| W8',1,true),legs.route)
  eq(legs.note,'dry_run plans the legs in order, each kept off the tiles of the legs before it')
end
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
-- The engine's targets: the belt it drops onto; nothing at its pickup point.
ins.drop_target=belt
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
eq(seen.pickup.y,-0.5); eq(seen.drop.y,1.5); eq(seen.io,'2.5,-0.5 (no pickup target) -> 2.5,1.7 transport-belt')
eq(seen.io_warning,'no pickup target'); eq(seen.drop_target,'transport-belt (2.5,1.5)'); eq(seen.pickup_target,nil)
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
  -- Every call that resolves a position takes the building under a robot, by remote view too (Astra 07:05: requests
  -- at (12.5,12.5) took a logistic robot, "has no logistic requests"). The robot sits on the point itself, first in
  -- the list: the nearest-first remote pick took it.
  local requester={valid=true,name='requester-chest',type='logistic-container',position={x=24.5,y=0.5},half=0.5,force=p.force,unit_number=78,
    get_inventory=function() return nil end,get_fluid_contents=function() return {} end,
    get_logistic_sections=function() return {sections={},sections_count=0} end}
  robot.position={x=24.5,y=0.5}
  robot.get_item_count=function() return 40 end
  requester.get_item_count=function() return 3 end
  world={robot,requester}
  local req=call('requests',{position={x=24.5,y=0.5}})
  assert(tostring(req.target):find('^requester%-chest at %(24.5,0.5%)'),tostring(req.target))
  -- Out of reach, by remote view: the same.
  p.can_reach_entity=function() return false end
  req=call('requests',{position={x=24.5,y=0.5}})
  assert(tostring(req.target):find('^requester%-chest'),tostring(req.target))
  -- circuit_set and configure resolve the chest, in reach and by remote view (their refusals name it).
  fails(function() call('circuit_set',{position={x=24.5,y=0.5},read={contents=true}}) end,'requester-chest')
  p.can_reach_entity=function() return true end
  fails(function() call('circuit_set',{position={x=24.5,y=0.5},read={contents=true}}) end,'requester-chest')
  -- wait_until item_count over the tile counts the chest, not the robot's cargo.
  prototypes.item=prototypes.item or {}; prototypes.item.coal=prototypes.item.coal or {fuel_value=4000000}
  local w=call('wait_until',{['until']='item_count',item='coal',positions={{x=24.5,y=0.5}},at_least=3,timeout=60})
  eq(w.saw,'coal 3 in 1 entities')
  -- Named, the robot is still the target.
  eq(call('inspect',{position={x=24.5,y=0.5},name='logistic-robot'}).name,'logistic-robot')
  robot.position={x=24.55,y=0.45}
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
-- Hub stock gates direct waits, sleeping, queued waits and guards through the same condition.
;(function()
  call('queue_cancel',{})
  local platforms,hub_id=p.force.platforms,defines.inventory.hub_main
  defines.inventory.hub_main=987
  local landed=0
  p.force.platforms={{valid=true,name='Freight',hub={valid=true,get_inventory=function(id)
    eq(id,987); return {get_item_count=function(item) eq(item,'coal'); return landed end}
  end}}}
  local c={['until']='item_count',platform='Freight',item='coal',at_least=50}
  call('wait_until',c); advance(10); eq(call('status').active.kind,'wait_until')
  landed=50; advance(10); eq(call('status').last.outcome,'met')
  landed=0; call('sleep',{seconds=60,condition=c}); eq(call('sleep_check',{}).woke,nil)
  landed=50; eq(call('sleep_check',{}).woke,'condition')
  landed=0
  call('queue_submit',{mode='replace',steps={{action='wait_until',args=c}}})
  advance(10); eq(call('queue_status').active.action,'wait_until')
  landed=50; advance(10); eq(call('queue_status').active,false)
  landed=0
  call('queue_submit',{mode='replace',steps={{action='wait_ticks',args={ticks=600}}},guards={{when=c}}})
  advance(10); eq(call('queue_status').paused,false)
  landed=50; advance(10); eq(call('queue_status').paused,true)
  call('queue_cancel',{})
  landed=0
  call('queue_submit',{lane='remote',steps={{action='wait_until',args=c}}})
  call('walk',{direction='east',ticks=100})
  advance(12)
  local body_action=storage.agent_harness.active[1]
  eq(body_action.kind,'walk');eq(call('queue_status',{lane='remote'}).active.action,'wait_until')
  landed=50;advance(10)
  local rq=call('queue_status',{lane='remote'})
  eq(rq.active,false);eq(rq.history[#rq.history].result.outcome,'met')
  eq(storage.agent_harness.active[1],body_action)
  fails(function() call('queue_submit',{lane='remote',steps={{action='wait_until',args={['until']='item_count',item='coal',at_least=1}}}}) end,'steps[1]')
  call('stop',{});call('queue_cancel',{lane='remote'})
  p.force.platforms,defines.inventory.hub_main=platforms,hub_id
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
local far=call('inspect',{position=ins.position}); eq(far.in_reach,false); eq(far.io,'2.5,-0.5 (no pickup target) -> 2.5,1.7 transport-belt')
fails(function() call('rotate',{position=ins.position,walk=false}) end,'out of reach')
-- By default it walks into reach first (autowalk.lua).
ins.bounding_box={left_top={x=2.15,y=-0.35},right_bottom={x=2.85,y=0.35}}
local turn=call('rotate',{position=ins.position}); eq(turn.walking_for,'rotate'); call('stop',{})
ins.bounding_box=nil
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
-- A batch short of two items the queue makes waits for both (Sol, shift12 13:50: it waited for the first only,
-- placed 3 entries and failed on the next, still crafting).
p.force.recipes.inserter={products={{name='inserter',amount=1}},energy=0.5}
p.crafting_queue={{recipe='lab',count=2},{recipe='inserter',count=1}}
pending=call('build',{builds={{item='lab',position={x=1,y=0}},{item='inserter',position={x=4,y=0}},{item='lab',position={x=6,y=0}}}})
eq(pending.awaiting_craft.item,'lab'); eq(#pending.awaiting_craft.items,2)
eq(pending.awaiting_craft.items[1].need,2); eq(pending.awaiting_craft.items[2].item,'inserter'); eq(pending.awaiting_craft.items[2].crafting,1)
-- The labs are done, the inserter still crafts: it keeps waiting.
p.crafting_queue={{recipe='inserter',count=1}}; advance(10)
eq(call('status').active.kind,'feed')
p.crafting_queue={}; advance(10)
eq(call('status').active,false); eq(call('status').last.outcome,'failed')
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
  -- A team library entry by name, placed by its saved anchor (blueprints.lua).
  eq(pcall(runtime.check_args,action,{name='smelter-row',position={x=0,y=0},anchor='saved',dry_run=true}),true)
end
-- The team blueprint library (operator 00:50): its actions' arguments, and the operator read through dispatch.
eq(pcall(runtime.check_args,'blueprint_save',{name='row',area={left_top={x=0,y=0},right_bottom={x=4,y=4}},description='d',anchor={x=1,y=1},tiles=true}),true)
eq(pcall(runtime.check_args,'blueprint_save',{name='row',positions={{x=1,y=1}}}),true)
eq(pcall(runtime.check_args,'blueprint_save',{name='row',blueprint='0eNq...'}),false)
eq(pcall(runtime.check_args,'blueprint_rename',{name='row',new_name='row2'}),true)
eq(pcall(runtime.check_args,'blueprint_list',{name='row'}),true)
eq(pcall(runtime.check_args,'blueprint_delete',{name='row'}),true)
eq(pcall(runtime.check_args,'blueprint_export',{name='row',layout=true}),true)
do
  local lib=runtime.dispatch{action='blueprint_library',args={},operator=true}
  eq(type(lib.revision),'number'); eq(type(lib.entries),'table')
  eq(call('describe').actions.blueprint_save.name~=nil,true)
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
-- ores (ores.lua): every resource patch on the charted map through dispatch, a read that leaves the walk running;
-- its aliases; surface= names another planet (no distance from the caller there).
;(function()
  local find,entities,platforms,get_surface,at=p.surface.find_entities_filtered,prototypes.entity,p.force.platforms,game.get_surface,p.position
  local chunks,surfaces,forces,charted,count=p.surface.get_chunks,game.surfaces,game.forces,p.force.is_chunk_charted,p.surface.count_entities_filtered
  p.position={x=0,y=0}
  prototypes.entity=setmetatable({['iron-ore']={type='resource',mineable_properties={products={{type='item',name='iron-ore'}}}}},{__index=entities})
  local function ore(x,y,amount) return {valid=true,name='iron-ore',type='resource',position={x=x+0.5,y=y+0.5},amount=amount} end
  local function one_chunk(x,y) return function() local done=false; return function() if not done then done=true; return {x=x,y=y} end end end end
  p.surface.find_entities_filtered=function(f) if f.type=='resource' then return {ore(10,-5,500),ore(11,-5,500)} end return {} end
  p.surface.get_chunks=one_chunk(0,-1)
  p.surface.count_entities_filtered=function(f) return #p.surface.find_entities_filtered(f) end
  local vulcanus={name='vulcanus',index=2,get_chunks=one_chunk(-1,-1),find_entities_filtered=function(f) if f.type=='resource' then return {ore(-5,-5,700)} end return {} end}
  vulcanus.count_entities_filtered=function(f) return #vulcanus.find_entities_filtered(f) end
  game.surfaces=setmetatable({nauvis=p.surface,vulcanus=vulcanus},{__index=function(_,k) return ({p.surface,vulcanus})[k] end})
  game.forces=setmetatable({player=p.force},{__index=forces})
  -- The caller's chunk is always charted (a character charts around itself).
  p.force.is_chunk_charted=function(s,c) if s==vulcanus then return c.x==0 and c.y==0 or c.x==-1 and c.y==-1 end return c.x==0 and (c.y==-1 or c.y==0) end
  storage.agent_harness.ores,storage.agent_harness.ores_busy=nil,nil
  call('walk',{direction='east',ticks=600})
  local r=call('ores',{})
  eq(r.count,1); eq(r.patches[1].tiles,2); eq(r.patches[1].amount,1000); eq(r.patches[1].distance,11); eq(r.patches[1].direction,'E')
  assert(r.survey:find('^2 charted chunks read; the last pass began'),r.survey)
  eq(call('status').active.kind,'walk'); call('stop',{})
  -- Two charted chunks: the first call's own budget read them all, so the harness tick has nothing to do.
  eq(storage.agent_harness.ores_busy,nil); eq(call('ores',{}).count,1)
  local named=call('ores',{name='iron-ore',limit=5})
  assert(named.corrected and named.corrected:find('name is resource',1,true),tostring(named.corrected)); eq(named.count,1)
  fails(function() call('ores',{resource='iron-plate'}) end,'iron-plate is not a resource; resources: iron-ore')
  fails(function() call('ores',{radius=5}) end,'unknown argument radius for ores')
  p.force.platforms={}
  game.get_surface=function(name) if name=='vulcanus' then return vulcanus end end
  local v=call('ores',{surface='vulcanus'})
  eq(v.surface,'vulcanus'); eq(v.patches[1].amount,700); eq(v.patches[1].distance,nil); eq(v.from,nil)
  eq(call('ores',{surface='vulcanus',position={x=-5,y=0}}).patches[1].distance,4)
  fails(function() call('ores',{surface='aquilo'}) end,'no surface named aquilo; planets and surfaces: nauvis, vulcanus')
  advance(2); eq(storage.agent_harness.ores_busy,nil)
  p.surface.find_entities_filtered,prototypes.entity,p.force.platforms,game.get_surface,p.position=find,entities,platforms,get_surface,at
  p.surface.get_chunks,game.surfaces,game.forces,p.force.is_chunk_charted,p.surface.count_entities_filtered=chunks,surfaces,forces,charted,count
  storage.agent_harness.ores,storage.agent_harness.ores_busy=nil,nil
end)()
-- Replies (00:20 round): transfer's direction named any way on a requester, car trunk or wagon (Haiku); an out of
-- reach target's distance, reach and a spot that reaches it (Haiku); inspect's holds and requests lines (Muse); and
-- the tally closing a transfer over several targets (Muse).
;(function()
  local find,getmain,reach,free=p.surface.find_entities_filtered,p.get_main_inventory,p.can_reach_entity,p.surface.find_non_colliding_position
  local at,dist=p.position,p.reach_distance
  defines.inventory.chest=defines.inventory.chest or 1
  defines.inventory.car_trunk=defines.inventory.car_trunk or 41
  defines.inventory.cargo_wagon=defines.inventory.cargo_wagon or 42
  local function box(name,type_,x,id,...)
    local slots=inv(...)
    slots.can_insert=function() return true end
    slots.get_contents=function() local out={}; for _,s in ipairs(slots) do if s.valid_for_read then out[#out+1]={name=s.name,count=s.count,quality='normal'} end end; return out end
    slots.count_empty_stacks=function() local n=0; for _,s in ipairs(slots) do if not s.valid_for_read then n=n+1 end end; return n end
    local e={valid=true,name=name,type=type_,position={x=x,y=0},force=p.force,slots=slots,get_fluid_contents=function() return {} end}
    e.get_inventory=function(i) if i==defines.inventory[id] then return slots end end
    return e
  end
  local req=box('requester-chest','logistic-container',2,'chest',stack('iron-plate',40),stack(nil,0),stack(nil,0),stack(nil,0))
  req.prototype={logistic_mode='requester'}
  req.get_logistic_sections=function() return {sections_count=1,get_section=function()
    return {is_manual=true,active=true,filters={{value={name='iron-plate'},min=100},{value={name='coal'},min=50}}} end} end
  local car=box('car','car',4,'car_trunk',stack('wood',3),stack(nil,0))
  local wagon=box('cargo-wagon','cargo-wagon',6,'cargo_wagon',stack('stone',7),stack(nil,0),stack(nil,0),stack(nil,0))
  wagon.slots.get_bar=function() return 3 end
  local big=box('iron-chest','container',8,'chest',stack('a',1),stack('b',9),stack('c',3),stack('d',8),stack('e',2),stack('f',7),stack('g',5),stack(nil,0))
  local far=box('wooden-chest','container',20,'chest',stack(nil,0))
  local world={req,car,wagon,big,far}
  p.surface.find_entities_filtered=function(f)
    local out={}
    for _,e in ipairs(world) do
      if f.position and math.abs(e.position.x-f.position.x)<0.6 and math.abs(e.position.y-f.position.y)<0.6 and (not f.name or f.name==e.name) then out[#out+1]=e end
    end
    return out
  end
  local bag=inv(stack('iron-plate',60),stack(nil,0),stack(nil,0),stack(nil,0))
  p.get_main_inventory=function() return bag end
  p.can_reach_entity=function(e) return e.position.x<10 end
  p.position={x=0,y=0}; p.reach_distance=10
  -- inspect: what a chest, trunk or wagon holds in one line; a requester's asks with what it holds of each.
  local seen=call('inspect',{position=req.position})
  eq(seen.holds,'iron-plate*40; 1 of 4 slots'); eq(seen.requests,'iron-plate 40/100, coal 0/50')
  eq(call('inspect',{position=wagon.position}).holds,'stone*7; 1 of 4 slots (limited to 2)')
  eq(call('inspect',{position=big.position}).holds,'b*9 d*8 f*7 g*5 c*3 e*2 +1 more; 7 of 8 slots')
  local rows=call('inspect',{positions={car.position,req.position}}).entities
  eq(rows[1].holds,'wood*3; 1 of 2 slots'); eq(rows[1].requests,nil); eq(rows[2].requests,'iron-plate 40/100, coal 0/50')
  -- Held on both sides, an omitted direction is still asked for; to_entity given as the target puts.
  fails(function() call('transfer',{position=req.position,item='iron-plate',count=10}) end,'direction is required')
  local put=call('transfer',{to_entity=req.position,item='iron-plate',count=10})
  eq(put.transferred,10); eq(req.slots[1].count,50); eq(bag[1].count,50)
  eq(put.corrected,'transfer {"count":10,"direction":"to_entity","item":"iron-plate","position":{"x":2,"y":0}} (to_entity={x,y} is direction="to_entity" position=...)')
  -- from_entity over a car trunk and a wagon takes everything; the reply closes with its tally.
  local took=call('transfer',{from_entity={car.position,wagon.position}})
  eq(took.transferred,10); eq(car.slots[1].valid_for_read,false); eq(wagon.slots[1].valid_for_read,false)
  eq(took.tally,'moved 3 wood, 7 stone; 2 of 2 targets touched')
  assert(took.corrected:find('from_entity={x,y} is direction="to_player" positions=...',1,true),took.corrected)
  -- direction named the other way round, and to_entity=true beside the same direction.
  eq(call('transfer',{position=car.position,item='iron-plate',count=2,direction='from_player'}).transferred,2); eq(car.slots[1].name,'iron-plate')
  eq(call('transfer',{position=car.position,item='iron-plate',count=2,direction='to_entity',to_entity=true}).transferred,2)
  eq(call('transfer',{position=car.position,item='iron-plate',direction='take'}).transferred,4)
  -- Out of reach with walk: false: how far, the reach, and a free spot that reaches it; nothing walks.
  p.surface.find_non_colliding_position=function(_,pos) return {x=math.floor(pos.x)+0.5,y=math.floor(pos.y)+0.5} end
  fails(function() call('transfer',{position=far.position,item='iron-plate',count=1,direction='to_entity',walk=false}) end,
    'entity is out of reach: wooden-chest at (20,0) is 20.0 tiles away (to its edge), reach 10; in reach from (10.5,0.5)')
  eq(call('status').active,false)
  -- By default (autowalk.lua) it walks there first, as walk: true does, and says so.
  local walking=call('transfer',{position=far.position,item='iron-plate',count=1,direction='to_entity'})
  eq(walking.op,'transfer'); eq(walking.out_of_reach,1)
  eq(walking.walking,'wooden-chest (20,0) is 20.0 tiles away (to its edge), reach 10: walking into reach first (walk: false refuses instead)')
  eq(call('status').active.kind,'gather'); call('stop',{})
  local several=call('transfer',{positions={req.position,far.position},item='iron-plate',count=5,direction='to_entity'})
  eq(several.walking,'1 of 2 places are out of reach (the farthest: wooden-chest (20,0) is 20.0 tiles away (to its edge), reach 10): walking to them first, nearest first (walk: false refuses instead)')
  call('stop',{})
  -- Several targets, one failing: the tally names the moved total, the targets touched and the failure.
  local spread=call('transfer',{positions={req.position,big.position,far.position},item='iron-plate',count=5,direction='to_entity',walk=false})
  eq(spread.transferred,10)
  eq(spread.tally,'moved 10 iron-plate; 2 of 3 targets touched; short: 1 failed (entity is out of reach: wooden-chest at (20,0) is 20.0 tiles away (to its edge), reach 10; in reach from (10.5,0.5))')
  -- One target: no tally.
  eq(call('transfer',{position=req.position,item='iron-plate',count=1,direction='to_entity'}).tally,nil)
  -- The tally's other shorts.
  eq(runtime.tally{moved={},targets=4,touched=1,unreached=2,errors=1,noun='places'},'moved nothing; 1 of 4 places touched; short: 2 not reached, 1 failed')
  eq(runtime.tally{moved={{name='coal',count=5}},targets=3,rows={{transferred=5},{transferred=0,full=true}},none_held=1,full_item='coal'},
    'moved 5 coal; 1 of 3 targets touched; short: your inventory full of coal, 1 full, 1 wanting more you hold none of')
  p.surface.find_entities_filtered,p.get_main_inventory,p.can_reach_entity,p.surface.find_non_colliding_position=find,getmain,reach,free
  p.position,p.reach_distance=at,dist
end)()
;(function()
  -- place_ghosts lists an inserter ghost with nothing on its pickup or drop point (targets.lua); inspect of
  -- that ghost reads the same; one with a chest on both points is not listed.
  local can,create,find,entities,tile=p.surface.can_place_entity,p.surface.create_entity,p.surface.find_entities_filtered,prototypes.entity,p.surface.get_tile
  local charted,at=p.force.is_chunk_charted,p.position
  prototypes.entity={inserter={type='inserter',items_to_place_this={{name='inserter',count=1}},inserter_pickup_position={0,-1},inserter_drop_position={0,1.2}}}
  p.force.is_chunk_charted=function() return true end
  p.position={x=0,y=0}
  local made,chests={},{}
  local function chest(x,y) chests[#chests+1]={valid=true,name='iron-chest',type='container',position={x=x,y=y}} end
  chest(6.5,-0.5); chest(6.5,1.5)
  p.surface.can_place_entity=function() return true end
  p.surface.create_entity=function(a)
    local g={valid=true,name='entity-ghost',type='entity-ghost',ghost_type='inserter',ghost_name=a.inner_name,ghost_prototype=prototypes.entity[a.inner_name],
      position={x=a.position.x,y=a.position.y},direction=a.direction or 0,surface=p.surface,force=p.force,
      get_fluid_contents=function() return {} end,get_inventory=function() return nil end}
    made[#made+1]=g
    return g
  end
  p.surface.find_entities_filtered=function(f)
    local out={}
    if f.position then
      for _,e in ipairs(chests) do if math.abs(e.position.x-f.position.x)<=0.35 and math.abs(e.position.y-f.position.y)<=0.35 then out[#out+1]=e end end
      for _,g in ipairs(made) do if f.position.x==g.position.x and f.position.y==g.position.y then out[#out+1]=g end end
    end
    return out
  end
  p.surface.get_tile=function() return {name='grass-1',valid=true} end
  -- check_inserters (Luna, d15): a bad inserter refuses the call before anything is placed; all good, the rows ride along.
  local okc,errc=pcall(call,'place_ghosts',{check_inserters=true,entities={{name='inserter',position={x=2.5,y=0.5}},{name='inserter',position={x=6.5,y=0.5}}}})
  assert(not okc and tostring(errc):find('check_inserters: 1 of 2 inserters would not work; nothing placed: #1 inserter (2.5,0.5): no pickup target, no drop target',1,true),tostring(errc))
  eq(#made,0)
  local rc=call('place_ghosts',{check_inserters=true,entities={{name='inserter',position={x=6.5,y=0.5}}}})
  eq(rc.placed,1); eq(rc.inserter_check[1].ok,true); eq(rc.inserter_check[1].name,'inserter')
  for i=#made,1,-1 do made[i]=nil end
  local r=call('place_ghosts',{entities={{name='inserter',position={x=2.5,y=0.5}},{name='inserter',position={x=6.5,y=0.5}}}})
  eq(r.placed,2); eq(#r.inserters_without_target,1); eq(r.inserters_without_target[1].position.x,2.5)
  eq(r.inserters_without_target[1].missing,'no pickup target, no drop target'); eq(r.inserters_without_target[1].drop,'none: the ground at (2.5,1.5)')
  local seen=call('inspect',{position={x=2.5,y=0.5}})
  eq(seen.io_warning,'no pickup target, no drop target'); eq(seen.pickup_target,'none: the ground at (2.5,-0.5)')
  local good=call('inspect',{position={x=6.5,y=0.5}})
  eq(good.io_warning,nil); eq(good.pickup_target,'iron-chest (6.5,-0.5)'); eq(good.drop_target,'iron-chest (6.5,1.5)')
  p.surface.can_place_entity,p.surface.create_entity,p.surface.find_entities_filtered,prototypes.entity,p.surface.get_tile=can,create,find,entities,tile
  p.force.is_chunk_charted,p.position=charted,at
end)()
;(function()
  -- A just-built inserter (Astra, shift10 13:44: the reply said "no drop target" where inspect a moment later showed
  -- the furnace). The engine sets its targets a tick later, so the build reply reads what stands on its points, on
  -- the engine's 1/256 grid (targets.lua): a long-handed inserter at (31.5,130.5) facing east drops at x 29.30078125,
  -- the left edge of the stone furnace's box at (30,130), where the engine targets the furnace.
  local find,getmain,cursor,can,build,charted,at,tile=p.surface.find_entities_filtered,p.get_main_inventory,p.cursor_stack,
    p.can_build_from_cursor,p.build_from_cursor,p.force.is_chunk_charted,p.position,p.surface.get_tile
  local proto={name='long-handed-inserter',type='inserter',inserter_pickup_position={0,-2},inserter_drop_position={0,2.2},
    collision_box={left_top={x=-0.15,y=-0.15},right_bottom={x=0.15,y=0.15}}}
  -- Boxes as the engine holds them: the furnace's 0.7 is 0.69921875 (179/256).
  local furnace={valid=true,name='stone-furnace',type='furnace',position={x=30,y=130},force=p.force,half=179/256}
  local chest={valid=true,name='iron-chest',type='container',position={x=33.5,y=130.5},force=p.force,half=0.4}
  local made={}
  local held=stack('long-handed-inserter',2); held.prototype={place_result=proto}
  local inv={held}; inv.find_item_stack=function() return held end
  inv.get_item_count=function(f) return f.name==held.name and held.valid_for_read and held.count or 0 end
  p.get_main_inventory=function() return inv end
  p.cursor_stack=stack(nil,0)
  p.force.is_chunk_charted=function() return true end
  p.position={x=31,y=127}
  p.can_build_from_cursor=function() return true end
  p.build_from_cursor=function(a)
    p.cursor_stack.count=p.cursor_stack.count-1; p.cursor_stack.valid_for_read=p.cursor_stack.count>0
    -- No pickup_target or drop_target: the engine has none in the tick the inserter is built.
    made[#made+1]={valid=true,name=proto.name,type='inserter',prototype=proto,position={x=a.position.x,y=a.position.y},
      direction=a.direction,force=p.force,surface=p.surface,half=0.15,
      pickup_position={x=a.position.x+2,y=a.position.y},drop_position={x=a.position.x-563/256,y=a.position.y},
      get_inventory=function() return nil end,get_fluid_contents=function() return {} end}
  end
  p.surface.find_entities_filtered=function(f)
    local out={}
    if not f.position then return out end
    local all={furnace,chest}
    for _,e in ipairs(made) do all[#all+1]=e end
    for _,e in ipairs(all) do
      local dx,dy=math.abs(e.position.x-f.position.x),math.abs(e.position.y-f.position.y)
      local hit=f.radius and dx*dx+dy*dy<=f.radius*f.radius or not f.radius and dx<=e.half and dy<=e.half
      if hit and (not f.name or f.name==e.name) and (not f.type or f.type==e.type) then out[#out+1]=e end
    end
    return out
  end
  p.surface.get_tile=function() return {name='grass-1',valid=true} end
  -- The unrounded drop point, 31.5-2.2, lies just outside the furnace's box.
  eq(#p.surface.find_entities_filtered{position={x=31.5-2.2,y=130.5}},0)
  local r=call('build',{item='long-handed-inserter',position={x=31.5,y=130.5},direction='east'})
  eq(r.consumed,1); eq(r.entity.name,'long-handed-inserter'); eq(made[1].drop_target,nil)
  eq(r.entity.io_warning,nil,'the furnace on its drop point and the chest on its pickup point are its targets')
  -- One a tile south: nothing on either point, and the reply says so.
  local south=call('build',{item='long-handed-inserter',position={x=31.5,y=131.5},direction='east'})
  eq(south.entity.position.y,131.5); eq(south.entity.io_warning,'no pickup target, no drop target')
  -- A batch of 18 with nothing around them: the first 16 listed, and the count of all, as place_ghosts gives them.
  held.name,held.count,held.valid_for_read=proto.name,20,true; p.cursor_stack=stack(nil,0)
  p.position={x=43.5,y=109}
  local column={}
  for i=0,17 do column[#column+1]={position={x=i<9 and 40.5 or 46.5,y=105.5+i%9}} end
  local batch=call('build',{item='long-handed-inserter',direction='east',builds=column})
  eq(batch.built,18); eq(#batch.inserters_without_target,16); eq(batch.inserters_without_target_count,18)
  eq(batch.inserters_without_target[1].missing,'no pickup target, no drop target')
  -- 16 or fewer: no count.
  held.count=2; p.cursor_stack=stack(nil,0)
  local pair=call('build',{item='long-handed-inserter',direction='east',builds={{position={x=43.5,y=105.5}},{position={x=43.5,y=112.5}}}})
  eq(#pair.inserters_without_target,2); eq(pair.inserters_without_target_count,nil)
  p.surface.find_entities_filtered,p.get_main_inventory,p.cursor_stack,p.can_build_from_cursor,p.build_from_cursor=find,getmain,cursor,can,build
  p.force.is_chunk_charted,p.position,p.surface.get_tile=charted,at,tile
end)()
;(function()
  -- Personal logistics (trash.lua; Astra 01:53: two hauls lost to auto-trash): a take over the request max says how
  -- many go to trash; up_to=true stops at the max; keep_max refuses the take.
  local find,getmain,reach,at=p.surface.find_entities_filtered,p.get_main_inventory,p.can_reach_entity,p.position
  local get_rp,get_inv=p.character.get_requester_point,p.character.get_inventory
  defines.inventory.chest=defines.inventory.chest or 1
  defines.inventory.character_trash=defines.inventory.character_trash or 8
  local function contents(slots)
    slots.get_contents=function() local out={}; for _,st in ipairs(slots) do if st.valid_for_read then out[#out+1]={name=st.name,count=st.count,quality='normal'} end end; return out end
    return slots
  end
  local slots=contents(inv(stack('iron-plate',100),stack('iron-plate',100),stack('iron-plate',100),stack('iron-plate',100)))
  local chest={valid=true,name='iron-chest',type='container',position={x=2.5,y=0.5},force=p.force,get_inventory=function() return slots end,get_fluid_contents=function() return {} end}
  p.surface.find_entities_filtered=function(f) if f.position and math.abs(f.position.x-2.5)<0.6 then return {chest} end return {} end
  local bag=contents(inv(stack(nil,0),stack(nil,0),stack(nil,0),stack(nil,0),stack(nil,0),stack(nil,0)))
  p.get_main_inventory=function() return bag end
  p.can_reach_entity=function() return true end
  p.position={x=0,y=0}
  local rp={enabled=true,trash_not_requested=false,filters={{name='iron-plate',quality='normal',max_count=100}}}
  p.character.get_requester_point=function() return rp end
  p.character.get_inventory=function() return {get_insertable_count=function() return 1000 end,is_empty=function() return true end,get_contents=function() return {} end} end
  fails(function() call('transfer',{position=chest.position,item='iron-plate',direction='to_player',keep_max=true}) end,
    'keep_max: nothing taken; 400 iron-plate would put you 300 over your request max (100)')
  eq(bag.get_item_count{name='iron-plate'},0,'nothing moved')
  local capped=call('transfer',{position=chest.position,item='iron-plate',direction='to_player',up_to=true})
  eq(capped.transferred,100); eq(capped.left_at_max,'300 iron-plate (your request max 100) left in the source'); eq(capped.trash,nil)
  local over=call('transfer',{position=chest.position,item='iron-plate',direction='to_player',count=50})
  eq(over.transferred,50); eq(over.trash[1],'50 iron-plate taken; your request max is 100: 50 go to trash')
  fails(function() call('transfer',{position=chest.position,item='iron-plate',direction='to_player',keep_max='yes'}) end,'keep_max must be true or false')
  -- Personal logistics off: no lines, no cap.
  rp.enabled=false
  eq(call('transfer',{position=chest.position,item='iron-plate',direction='to_player',count=10}).trash,nil)
  p.surface.find_entities_filtered,p.get_main_inventory,p.can_reach_entity,p.position=find,getmain,reach,at
  p.character.get_requester_point,p.character.get_inventory=get_rp,get_inv
end)()
-- area on feed, collect and transfer (Muse 02:03: "I hand-feed the same 5 ADV + 2 cable machines every few minutes all
-- shift"): the machines with their centre in the area become the positions; inspect shows how full each output is.
;(function()
  local find,getmain,reach,at=p.surface.find_entities_filtered,p.get_main_inventory,p.can_reach_entity,p.position
  local recipes,items,status=prototypes.recipe,prototypes.item,defines.entity_status
  prototypes.recipe={['advanced-circuit']={name='advanced-circuit',ingredients={{type='item',name='copper-cable',amount=4}}},
    ['copper-cable']={name='copper-cable',ingredients={{type='item',name='copper-plate',amount=1}}}}
  prototypes.item={['copper-cable']={name='copper-cable',stack_size=200},['copper-plate']={name='copper-plate',stack_size=100},
    ['advanced-circuit']={name='advanced-circuit',stack_size=200},['iron-plate']={name='iron-plate',stack_size=100}}
  defines.entity_status={working=1,full_output=29}
  local IN,OUT=defines.inventory.assembling_machine_input,defines.inventory.assembling_machine_output
  local machines={}
  local function machine(x,y,recipe,product,count)
    local input,output=inv(stack(nil,0),stack(nil,0)),inv(stack(product,count or 0))
    output[1].prototype={stack_size=prototypes.item[product].stack_size}
    input.can_insert=function() return true end
    for _,t in ipairs({input,output}) do
      t.get_contents=function() local list={}; for _,s in ipairs(t) do if s.valid_for_read then list[#list+1]={name=s.name,count=s.count,quality='normal'} end end; return list end
    end
    local m={valid=true,name='assembling-machine-2',type='assembling-machine',position={x=x,y=y},force=p.force,unit_number=900+#machines,
      status=1,crafting_progress=0.5,get_fluid_contents=function() return {} end,input=input,output=output}
    m.get_inventory=function(i) if i==IN then return input end if i==OUT then return output end end
    m.get_output_inventory=function() return output end
    m.get_recipe=function() return {name=recipe} end
    machines[#machines+1]=m
    return m
  end
  for i=1,5 do machine(2*i+0.5,0.5,'advanced-circuit','advanced-circuit',3) end
  local cable1,cable2=machine(2.5,4.5,'copper-cable','copper-cable',180),machine(4.5,4.5,'copper-cable','copper-cable',200)
  cable2.status=29
  local outside=machine(40.5,0.5,'advanced-circuit','advanced-circuit',3)
  p.surface.find_entities_filtered=function(f)
    local out={}
    for _,m in ipairs(machines) do
      local inside
      if f.area then
        inside=m.position.x+1.5>=f.area.left_top.x and m.position.x-1.5<=f.area.right_bottom.x and m.position.y+1.5>=f.area.left_top.y and m.position.y-1.5<=f.area.right_bottom.y
      elseif f.position then inside=math.abs(m.position.x-f.position.x)<0.3 and math.abs(m.position.y-f.position.y)<0.3 end
      if inside and (not f.unit_number or f.unit_number==m.unit_number) then out[#out+1]=m end
    end
    return out
  end
  local bag=inv(stack('copper-cable',100),stack('iron-plate',50))
  for i=3,12 do bag[i]=stack(nil,0) end
  p.get_main_inventory=function() return bag end
  p.can_reach_entity=function(e) return e.position.x<20 end
  p.position={x=0,y=0}
  local area={left_top={x=0,y=-1},right_bottom={x=12,y=6}}
  -- feed with a recipe: the 5 ADV machines get 8 cable each; the 2 cable machines are counted apart; the one outside
  -- the area is untouched.
  local fed=call('feed',{area=area,recipe='advanced-circuit',crafts=2})
  eq(fed.area_targets,7); eq(fed.transferred,40); eq(fed.other_recipe,2); eq(#fed.entities,5); eq(fed.items['copper-cable'],40)
  eq(machines[1].input[1].count,8); eq(outside.input[1].valid_for_read,false); eq(bag[1].count,60)
  -- collect: every output in the area; the tally closes it.
  local took=call('collect',{area=area})
  eq(took.area_targets,7); eq(took.transferred,15+180+200)
  assert(took.tally:find('7 of 7 targets touched',1,true),took.tally)
  eq(outside.output[1].count,3)
  -- transfer by area with types: iron plate into each.
  machines[1].input[2]=stack(nil,0)
  local put=call('transfer',{area={left_top={x=0,y=3},right_bottom={x=6,y=6}},types={'assembling-machine'},item='iron-plate',count=5,direction='to_entity',inventory='assembling_machine_input'})
  eq(put.area_targets,2); eq(put.transferred,10)
  -- Refusals: area with positions, an empty area, too big, more than 64.
  fails(function() call('feed',{area=area,positions={{x=2.5,y=0.5}}}) end,'give area, positions, position or radius: one of them')
  fails(function() call('collect',{area={left_top={x=100,y=100},right_bottom={x=110,y=110}}}) end,'no furnace, assembling-machine of ours with its centre in (100,100)-(110,110)')
  fails(function() call('collect',{area={left_top={x=0,y=0},right_bottom={x=200,y=10}}}) end,'at most 128x128')
  -- inspect: output fullness per product, full when the machine stopped for it.
  cable1.output[1].count,cable1.output[1].valid_for_read=180,true; cable2.output[1].count,cable2.output[1].valid_for_read=200,true
  local rows=call('inspect',{positions={cable1.position,cable2.position,machines[1].position}}).entities
  eq(rows[1].output_fill,'copper-cable 180/200 (90%)'); eq(rows[2].output_fill,'copper-cable 200/200 (100%), full'); eq(rows[3].output_fill,'empty')
  p.surface.find_entities_filtered,p.get_main_inventory,p.can_reach_entity,p.position=find,getmain,reach,at
  prototypes.recipe,prototypes.item,defines.entity_status=recipes,items,status
end)()
;(function()
  -- A full drop's pods that wait for a hatch run on their own channel (space.lua, runtime drop_jobs_tick):
  -- the character's action is untouched, a queue step waits for them, status shows drop_pending then last_drop.
  local st=storage.agent_harness
  local job={kind='drop',platform={valid=false},planet='vulcanus',surface='vulcanus',pods={{items={{name='coal',quality='normal',count=50}}}},
    sent={{pod=1,drop=3,items='iron-plate*1000',slots=10}},short={},moved={['iron-plate@normal']=1000},
    want={{name='iron-plate',quality='normal',count=1000},{name='coal',quality='normal',count=50}},until_tick=game.tick+600}
  st.drop_jobs={[1]=job}
  local brief=call('status',{brief=true})
  eq(brief.drop_pending.pods_sent,1); eq(brief.drop_pending.pods_left,1); eq(brief.last_drop,nil)
  game.tick=game.tick+10-(game.tick%10)
  runtime.drop_jobs_tick(game.tick)
  eq(st.drop_jobs[1],nil)
  brief=call('status',{brief=true})
  eq(brief.drop_pending,nil); eq(brief.last_drop.outcome,'failed'); eq(brief.last_drop.why,'the platform or its hub is gone')
  eq(brief.last_drop.result.not_sent,'coal*50'); eq(brief.last_drop.result.dropped[1],'iron-plate*1000')
  st.drop_jobs=nil; st.last_drop=nil
end)()
;(function()
  -- inspect over an area (Gemini, shift10): one compact row per chest or machine of ours in sight, reading order.
  local find,at,vis=p.surface.find_entities_filtered,p.position,p.force.is_chunk_visible
  -- inspect reads in sight or by remote view in a chunk our force sees (read_sight): chunk x 1 (the far chest) is dark.
  p.force.is_chunk_visible=function(_,ch) return ch.x<1 end
  local inv_defs={chest=defines.inventory.chest,assembling_machine_input=defines.inventory.assembling_machine_input,
    assembling_machine_output=defines.inventory.assembling_machine_output}
  defines.inventory.chest=defines.inventory.chest or 1; defines.inventory.assembling_machine_input=902; defines.inventory.assembling_machine_output=903
  local function inv(list,size)
    local t={valid=true}
    t.get_contents=function() return list end
    t.is_empty=function() return #list==0 end
    t.count_empty_stacks=function() return size-#list end
    t.get_bar=function() return size+1 end
    setmetatable(t,{__len=function() return size end})
    return t
  end
  local function chest(x,y,list) return {valid=true,name='iron-chest',type='container',position={x=x,y=y},force=p.force,
    get_inventory=function(i) if i==defines.inventory.chest then return inv(list,32) end end} end
  local a=chest(2.5,1.5,{{name='iron-plate',count=150,quality='normal'},{name='coal',count=20,quality='normal'}})
  local b=chest(1.5,1.5,{})
  local c={valid=true,name='assembling-machine-2',type='assembling-machine',position={x=1.5,y=4.5},force=p.force,status=1,
    get_recipe=function() return {name='electronic-circuit'} end,
    get_inventory=function(i) if i==902 then return inv({{name='copper-cable',count=8,quality='normal'}},4) elseif i==903 then return inv({},1) end end}
  local far=chest(60.5,1.5,{})
  local list={a,b,c,far}
  p.position={x=0,y=0}
  p.surface.find_entities_filtered=function(f) if f.area and f.force then return list end return {} end
  local r=call('inspect',{area={left_top={x=0,y=0},right_bottom={x=64,y=10}}})
  eq(r.count,3); eq(r.entities[1].position.x,1.5); eq(r.entities[2].position.x,2.5); eq(r.entities[3].name,'assembling-machine-2')
  eq(r.entities[1].holds,'empty; 0 of 32 slots'); eq(r.entities[2].holds,'iron-plate*150 coal*20; 2 of 32 slots')
  eq(r.entities[3].holds,'in: copper-cable*8'); eq(r.entities[3].recipe,'electronic-circuit'); eq(r.entities[1].status_name,nil,'a chest has none')
  eq(r.not_in_sight,'1 more in the area in chunks our force does not see now (radar coverage or a character\'s sight lights a chunk)')
  -- compact (Muse, shift13: ~10 inspects over positions read as tables or JSON): one line per entity, the same
  -- reading order; health where the entity has it.
  c.health=320; c.max_health=350; a.health=200; a.max_health=200
  local short=call('inspect',{area={left_top={x=0,y=0},right_bottom={x=64,y=10}},compact=true})
  eq(short.entities,nil); eq(short.count,3); eq(#short.lines,3)
  eq(short.lines[1],'iron-chest (1.5,1.5): empty; 0 of 32 slots')
  eq(short.lines[2],'iron-chest (2.5,1.5): health 200/200; holds iron-plate*150 coal*20; 2 of 32 slots')
  eq(short.lines[3],'assembling-machine-2 (1.5,4.5): health 320/350; recipe electronic-circuit; in: copper-cable*8')
  -- Over positions, in the order given; an entry that fails is its position and why.
  p.surface.find_entities_filtered=function(f)
    if f.area and f.force then return list end
    local out={}
    for _,e in ipairs(f.position and list or {}) do
      if math.abs(e.position.x-f.position.x)<=(f.radius or 0.5) and math.abs(e.position.y-f.position.y)<=(f.radius or 0.5) then out[#out+1]=e end
    end
    return out
  end
  -- An inserter: its hand; a pole (no inventory): no holds.
  local ins={valid=true,name='inserter',type='inserter',position={x=3.5,y=4.5},force=p.force,health=150,max_health=150,
    held_stack={valid_for_read=true,name='copper-cable',count=2},get_inventory=function() return nil end}
  local pole={valid=true,name='small-electric-pole',type='electric-pole',position={x=4.5,y=4.5},force=p.force,health=100,max_health=100,
    get_inventory=function() return nil end}
  list[#list+1]=ins; list[#list+1]=pole
  short=call('inspect',{positions={c.position,a.position,{x=20,y=20},ins.position,pole.position},compact=true})
  eq(short.count,5); eq(short.lines[1],'assembling-machine-2 (1.5,4.5): health 320/350; recipe electronic-circuit; in: copper-cable*8')
  eq(short.lines[2],'iron-chest (2.5,1.5): health 200/200; holds iron-plate*150 coal*20; 2 of 32 slots')
  assert(short.lines[3]:find('^%(20,20%): '),short.lines[3])
  eq(short.lines[4],'inserter (3.5,4.5): health 150/150; hand: copper-cable*2')
  eq(short.lines[5],'small-electric-pole (4.5,4.5): health 100/100')
  list[#list]=nil; list[#list]=nil
  -- One position: one line.
  short=call('inspect',{position=a.position,compact=true})
  eq(short.count,1); eq(short.lines[1],'iron-chest (2.5,1.5): health 200/200; holds iron-plate*150 coal*20; 2 of 32 slots')
  fails(function() call('inspect',{position=a.position,compact='yes'}) end,'compact must be true or false')
  p.surface.find_entities_filtered=function(f) if f.area and f.force then return list end return {} end
  fails(function() call('inspect',{area={left_top={x=0,y=0},right_bottom={x=200,y=10}}}) end,'at most 128x128')
  fails(function() call('inspect',{area={left_top={x=0,y=0},right_bottom={x=9,y=9}},position={x=1,y=1}}) end,'give area, positions or position: one of them')
  fails(function() call('inspect',{position={x=1.5,y=1.5},types={'container'}}) end,'types goes with area')
  list={far}
  fails(function() call('inspect',{area={left_top={x=0,y=0},right_bottom={x=64,y=10}}}) end,'no chest or machine of ours with its centre in (0,0)-(64,10) in a chunk our force sees now (1 in chunks it does not')
  list={}
  for i=1,65 do list[i]=chest(i%30+0.5,math.floor(i/30)+0.5,{}) end
  fails(function() call('inspect',{area={left_top={x=0,y=0},right_bottom={x=31,y=3}}}) end,'65 entities in the area; at most 64')
  p.surface.find_entities_filtered,p.position,p.force.is_chunk_visible=find,at,vis
  for k,v in pairs(inv_defs) do defines.inventory[k]=v end
end)()
;(function()
  -- Build and ghost replies: logistic chests outside every roboport's area (networks.lua), entrances fed from the side.
  local coverage=runtime.networks.coverage
  runtime.networks.coverage=function(_,_,pos) return pos.x>100 and 'outside logistic coverage: nearest roboport (0,0), 75 tiles from its area' or nil end
  local s={find_entities_filtered=function(f)
    if f.type=='underground-belt' then return {{valid=true,name='underground-belt',type='underground-belt',position={x=6.5,y=84.5},direction=0,belt_to_ground_type='input'}} end
    return {}
  end}
  local far={valid=true,type='logistic-container',name='requester-chest',position={x=120.5,y=0.5},surface=s,force=p.force}
  local near={valid=true,type='logistic-container',name='requester-chest',position={x=10.5,y=0.5},surface=s,force=p.force}
  local ghost={valid=true,type='entity-ghost',ghost_type='logistic-container',ghost_name='buffer-chest',position={x=130.5,y=0.5},surface=s,force=p.force}
  local ins={valid=true,type='inserter',name='inserter',position={x=7.5,y=84.5},drop_position={x=6.3,y=84.5},direction=4,surface=s,force=p.force}
  local cover,side=runtime.build_notes(p,{far,near,ghost,ins})
  eq(#cover,2); eq(cover[1],'requester-chest (120.5,0.5): outside logistic coverage: nearest roboport (0,0), 75 tiles from its area')
  eq(cover[2]:match('^buffer%-chest %(130.5,0.5%): outside') ~= nil,true,'a ghost by its ghost name')
  eq(#side,1); eq(side[1]:match('^inserter %(7.5,84.5%) drops onto underground%-belt %(6.5,84.5%), an entrance flowing north, from its east side') ~= nil,true)
  eq(select(1,runtime.build_notes(p,{near})),nil); eq(select(2,runtime.build_notes(p,{near})),nil)
  runtime.networks.coverage=coverage
end)()
;(function()
  -- inspect by remote view (Astra, operator 04:57): on our own surface the map shows every entity in a chunk our
  -- force sees, as the game's remote view does; an action still needs the character's sight.
  local chest={valid=true,name='iron-chest',type='container',position={x=3.5,y=0.5},force=p.force,health=200,max_health=200,status=nil,
    get_fluid_contents=function() return {} end,get_inventory=function() return nil end,get_output_inventory=function() return nil end,
    electric_network_id=nil,energy=0}
  local find,at,vis=p.surface.find_entities_filtered,p.position,p.force.is_chunk_visible
  p.surface.find_entities_filtered=function(f) if f.position and math.abs(f.position.x-3.5)<1 and math.abs(f.position.y-0.5)<1 then return {chest} end return {} end
  p.position={x=3,y=0}
  eq(call('inspect',{position={x=3.5,y=0.5}}).by,nil) -- in sight
  p.position={x=200,y=0}
  local seen=call('inspect',{position={x=3.5,y=0.5}})
  eq(seen.by,'remote view'); eq(seen.name,'iron-chest')
  fails(function() call('build',{item='wooden-chest',position={x=4.5,y=0.5}}) end,'outside local visible area')
  -- The action's target is in coverage: its refusal names none.
  local ok,err=pcall(call,'build',{item='wooden-chest',position={x=4.5,y=0.5}})
  eq(ok,false); eq(tostring(err):find('nearest radar coverage',1,true),nil)
  -- Not in any chunk our force sees: refused, naming the nearest radar coverage.
  p.force.is_chunk_visible=function(_,c) return c.x==3 and c.y==0 end
  eq(call('inspect',{position={x=3.5,y=0.5}}).by,'last seen memory')
  fails(function() call('build',{item='wooden-chest',position={x=4.5,y=0.5}}) end,'move_to within 30 tiles first); the nearest radar coverage (or a character\'s sight) is chunk (96,0)-(127,31), 92 tiles away')
  p.force.is_chunk_visible=function() return false end
  eq(call('inspect',{position={x=3.5,y=0.5}}).by,'last seen memory')
  p.surface.find_entities_filtered,p.position,p.force.is_chunk_visible=find,at,vis
end)()
;(function()
  -- place_ghosts with a tile ghost where a Gleba tree stands (Sol, shift10: a slipstack kept landfill out): the tree
  -- is marked for deconstruction first, as the game's ghost placement marks it, and the reply says so.
  local find,can,create=p.surface.find_entities_filtered,p.surface.can_place_entity,p.surface.create_entity
  local tiles,items=prototypes.tile,prototypes.item
  prototypes.tile=prototypes.tile or {}; prototypes.item=prototypes.item or {}
  local saved_tile,saved_item=prototypes.tile.landfill,prototypes.item.landfill
  prototypes.tile.landfill={name='landfill',collision_mask={layers={ground_tile=true}}}
  prototypes.item.landfill=nil
  local tree={valid=true,name='slipstack',type='tree',minable=true,force={name='neutral'},position={x=10.06,y=10.06},
    prototype={collision_mask={layers={object=true,ground_tile=true}}}}
  tree.to_be_deconstructed=function() return tree.marked==true end
  tree.order_deconstruction=function() tree.marked=true; return true end
  tree.cancel_deconstruction=function() tree.marked=nil; return true end
  p.surface.find_entities_filtered=function(f) if f.area then return {tree} end return {} end
  p.surface.can_place_entity=function(a) if a.name=='tile-ghost' then return tree.marked==true end return can(a) end
  local made={}
  p.surface.create_entity=function(a) if a.name=='tile-ghost' then local g={valid=true,type='tile-ghost',ghost_name=a.inner_name,position=a.position}; made[#made+1]=g; return g end return create(a) end
  local r=call('place_ghosts',{entities={{name='landfill',position={x=10.5,y=10.5}}}})
  eq(r.placed,1); eq(tree.marked,true); eq(#made,1); eq(r.obstacles_marked,1)
  eq(r.tile_obstacles_marked,'marked for deconstruction where tile ghosts go: slipstack (10.1,10.1); construct mines them before it lays the tiles')
  -- Something else there (not a minable tree or rock): refused, named, and nothing marked.
  tree.marked=nil; tree.minable=false
  r=call('place_ghosts',{entities={{name='landfill',position={x=10.5,y=10.5}}}})
  eq(r.placed,0); eq(r.failed[1].error,'tile placement blocked by slipstack at (10.1,10.1)'); eq(tree.marked,nil)
  p.surface.find_entities_filtered,p.surface.can_place_entity,p.surface.create_entity=find,can,create
  prototypes.tile.landfill,prototypes.item.landfill=saved_tile,saved_item
  prototypes.tile,prototypes.item=tiles,items
end)()
;(function()
  -- via (Opus, operator 06:26: worm detours took 5-6 chained move_tos a trip): points walked in order in one call,
  -- each leg its own walk; a via point counts as reached within 1 tile.
  call('queue_cancel',{}); call('stop',{})
  p.position={x=0,y=0}
  local r=call('move_to',{position={x=10,y=0},via={{x=3,y=0},{3,3}},pathfind=false})
  eq(r.via,2); eq(r.legs,3); eq(r.position.x,10)
  advance(1); eq(call('status').active.leg,'1 of 3'); eq(call('status').active.to.x,3)
  p.position={x=2.2,y=0}; advance(1)
  eq(call('status').active.leg,'2 of 3'); eq(call('status').active.to.y,3)
  p.position={x=3,y=2.5}; advance(1)
  eq(call('status').active.leg,'3 of 3'); eq(call('status').active.to.x,10)
  p.position={x=9.8,y=0}; advance(1)
  local last=call('status').last
  eq(last.outcome,'arrived'); eq(last.target.x,10); eq(#last.legs,3)
  eq(last.legs[1].outcome,'arrived'); eq(last.legs[1].to.x,3); eq(last.legs[2].to.y,3); eq(last.legs[3].outcome,'arrived'); eq(last.legs[3].to.x,10)
  -- A leg that does not arrive ends the walk with its outcome; the rest are not walked.
  call('move_to',{position={x=10,y=0},via={{x=3,y=0},{x=3,y=3}},pathfind=false,ticks=5})
  advance(7)
  last=call('status').last
  eq(last.outcome,'timed_out'); eq(last.target.x,10); eq(last.legs[1].outcome,'timed_out'); eq(last.legs[1].to.x,3)
  eq(last.legs[2].outcome,'not walked'); eq(last.legs[3].outcome,'not walked'); eq(last.legs[3].to.x,10)
  -- The limit (round1820a, Opus: 400-tile via trips timed out at the fixed 3600 ticks four times while walking fine):
  -- ticks as given, else scaled to the planned route, said in limit and in the why of a timeout.
  eq(last.limit,'5 ticks (0s), as given')
  assert(last.why:find('time ran out at (9.8,0), 0.2 tiles from the target: its limit, 5 ticks (0s), as given, ran out on leg 1 of 3 (to (3,0))',1,true),last.why)
  p.position={x=0,y=0}
  local kept_speed=p.character_running_speed
  p.character_running_speed=0.15
  r=call('move_to',{position={x=400,y=0},via={{x=200,y=100},{x=300,y=-100}},pathfind=false})
  -- 223.6 + 223.6 + 141.4 = 588.6 tiles; at 0.15 tiles a tick, 1.5 times that and 600 ticks more: 6487.
  eq(r.limit,'6487 ticks (1m48s) for the planned route, 589 tiles in straight lines through the via points at 0.15 tiles a tick')
  eq(r.until_tick-game.tick,6487)
  call('stop',{})
  r=call('move_to',{position={x=10,y=0},pathfind=false})
  eq(r.limit,'3600 ticks (1m00s)'); call('stop',{})
  p.character_running_speed=kept_speed
  fails(function() call('move_to',{position={x=10,y=0},via={}}) end,'via takes 1..16 points')
  fails(function() call('move_to',{position={x=10,y=0},via={{x=600,y=0}}}) end,'via point 1 (600,0) must be within 512 tiles of the point before it')
  -- waypoints is read as via.
  r=call('move_to',{position={x=10,y=0},waypoints={{x=3,y=0}},pathfind=false}); eq(r.via,1); call('stop',{})
  -- A queue step paused after its first via point goes on from the second.
  p.position={x=0,y=0}
  call('queue_submit',{steps={{action='move_to',args={position={x=10,y=0},via={{x=3,y=0},{x=3,y=3}},pathfind=false}}}})
  advance(1); eq(call('status').active.leg,'1 of 3')
  p.position={x=2.5,y=0}; advance(1); eq(call('status').active.leg,'2 of 3')
  call('walk',{direction='north',ticks=2})
  local q=call('queue_status')
  eq(q.paused,true); eq(q.pending[1].action,'move_to'); eq(#q.pending[1].args.via,1); eq(q.pending[1].args.via[1].y,3)
  call('queue_cancel',{}); call('stop',{})
  p.position={x=0,y=0}
end)()
;(function()
  -- move_to target (Astra, operator 07:55: a walk that ended unreachable while already within transfer reach of its
  -- target broke an && chain): walk until within reach of the entity's box, arriving there.
  call('queue_cancel',{}); call('stop',{})
  local chest={valid=true,name='iron-chest',type='container',position={x=20.5,y=0.5},unit_number=777,force=p.force,surface=p.surface,
    bounding_box={left_top={x=20.15,y=0.15},right_bottom={x=20.85,y=0.85}}}
  local find,reach,get,bd,rd=p.surface.find_entities_filtered,p.can_reach_entity,game.get_entity_by_unit_number,p.build_distance,p.reach_distance
  p.surface.find_entities_filtered=function(f)
    if f.position and not f.radius and f.position.x>=20 and f.position.x<21 and f.position.y>=0 and f.position.y<1 then return {chest} end
    if f.position and f.radius and math.abs(f.position.x-20.5)<=f.radius and math.abs(f.position.y-0.5)<=f.radius then return {chest} end
    return {}
  end
  -- the engine's reach: 10 tiles to the box
  p.reach_distance=10; p.build_distance=10
  local engine_reach=true
  p.can_reach_entity=function(e) return engine_reach and runtime.box_distance(p.position,e)<=10 end
  game.get_entity_by_unit_number=function(n) return n==777 and chest or nil end
  p.position={x=0,y=0}
  local r=call('move_to',{target={position={x=20.2,y=0.8}},pathfind=false})
  eq(r.target.name,'iron-chest'); eq(r.target.unit_number,777); eq(r.reach,'transfer reach 10'); eq(r.in_reach,false); eq(r.position.x,20.5)
  advance(1); eq(call('status').active.kind,'move_to')
  p.position={x=10.5,y=0.5}; advance(1) -- 9.65 tiles to its box: within reach, arrived
  local last=call('status').last
  eq(last.outcome,'arrived'); eq(last.target.x,20.5); eq(last.reach,'iron-chest (20.5,0.5): 9.6 tiles to its box (transfer reach 10)')
  -- Stopped in reach on a belt: the nearest free tile without one that is still within reach (before: one within the
  -- arrival radius of the target's centre, 4 tiles further in on a copy of world n).
  local plain=p.surface.find_entities_filtered
  p.surface.find_entities_filtered=function(f)
    if f.type and f.area then
      local x,y=math.floor(f.area[1][1]+0.01),math.floor(f.area[1][2]+0.01)
      return (x==10 and y==0) and {{valid=true,name='transport-belt',type='transport-belt'}} or {}
    end
    return plain(f)
  end
  p.position={x=0,y=0}
  call('move_to',{target={unit_number=777},pathfind=false})
  advance(1)
  p.position={x=10.5,y=0.5}; advance(1)
  eq(call('status').active.kind,'move_to')
  local nav0=storage.agent_harness.active[1]
  local so=nav0.step_off
  eq(((so.x-10.5)^2+(so.y-0.5)^2)^0.5,1,'the next tile')
  assert(runtime.box_distance(so,chest)<=9.75,'still within reach')
  p.position={x=so.x,y=so.y}; advance(1)
  last=call('status').last
  eq(last.outcome,'arrived'); eq(last.off_belt,string.format('arrived on a transport-belt; stepped to (%g,%g), the nearest free tile without a belt within reach of the target',so.x,so.y))
  p.surface.find_entities_filtered=plain
  p.position={x=10.5,y=0.5}
  -- Already within reach: arrives on the first tick, without walking.
  r=call('move_to',{target={unit_number=777},pathfind=false}); eq(r.in_reach,true)
  advance(1); eq(call('status').last.outcome,'arrived'); eq(call('status').last.reach_note,nil)
  -- reach in tiles, to the box: 2 means within 1.75.
  call('move_to',{target={position={x=20.5,y=0.5}},reach=2,pathfind=false})
  advance(1); eq(call('status').active.kind,'move_to')
  p.position={x=18.3,y=0.5}; advance(1); eq(call('status').active.kind,'move_to') -- 1.85 to its box
  p.position={x=18.5,y=0.5}; advance(1); eq(call('status').last.outcome,'arrived'); eq(call('status').last.reach,'iron-chest (20.5,0.5): 1.6 tiles to its box (reach 2)')
  r=call('move_to',{target={position={x=20.5,y=0.5}},reach='build',pathfind=false}); eq(r.reach,'build reach 10'); call('stop',{})
  -- Build reach to the centre, as build measures the position it builds at (friction2, Sol 14:43: arrived 9.7 tiles from
  -- a chest's edge, and the build there failed at 10.1 from its centre): 9.65 to the box is not yet within it.
  p.position={x=0,y=0}
  call('move_to',{target={position={x=20.5,y=0.5}},reach='build',pathfind=false})
  advance(1); p.position={x=10.5,y=0.5}; advance(1); eq(call('status').active.kind,'move_to')
  p.position={x=10.8,y=0.5}; advance(1)
  eq(call('status').last.outcome,'arrived'); eq(call('status').last.reach,'iron-chest (20.5,0.5): 9.7 tiles to its centre (build reach 10)')
  -- A point's reach (move_to {position, reach}; Sol 18:56: target needs an entity, to stand in build reach of an empty
  -- spot): within reach of the point less a quarter tile.
  p.position={x=0,y=0}
  r=call('move_to',{position={x=30,y=0.5},reach=3,pathfind=false}); eq(r.reach,'reach 3')
  advance(1); p.position={x=27,y=0.5}; advance(1); eq(call('status').active.kind,'move_to')
  p.position={x=27.3,y=0.5}; advance(1)
  last=call('status').last
  eq(last.outcome,'arrived'); eq(last.reach,'(30,0.5): 2.7 tiles (reach 3)'); eq(last.target.x,30)
  p.position={x=0,y=0}
  r=call('move_to',{position={x=30,y=0.5},reach='build',pathfind=false}); eq(r.reach,'build reach 10'); eq(r.in_reach,false); call('stop',{})
  p.position={x=25,y=0.5}
  r=call('move_to',{position={x=30,y=0.5},reach='build',pathfind=false}); eq(r.in_reach,true)
  advance(1); eq(call('status').last.outcome,'arrived')
  -- A walk that ends another way while within reach counts as arrived (the engine refusing reach on the walk's own ticks).
  p.position={x=10.5,y=0.5}; engine_reach=false
  call('move_to',{target={unit_number=777},pathfind=false,ticks=2})
  advance(2); eq(call('status').active.kind,'move_to')
  engine_reach=true; advance(1)
  last=call('status').last
  eq(last.outcome,'arrived'); eq(last.reach_note,'within its reach already when the walk ended timed_out')
  -- Refused: both position and target, reach alone, within with target, a bad reach, nothing there, no such unit.
  fails(function() call('move_to',{position={x=1,y=1},target={unit_number=777}}) end,'give position or target, not both')
  fails(function() call('move_to',{reach=3}) end,'reach goes with target (an entity: {position={x,y}} or {unit_number=N}) or position (a point)')
  fails(function() call('move_to',{target={unit_number=777},within=2}) end,'with reach, reach says how near')
  fails(function() call('move_to',{position={x=1,y=1},reach='hand'}) end,'reach is build, transfer or a number of tiles 0.5..64 (to the point)')
  fails(function() call('move_to',{target={unit_number=777},reach='hand'}) end,'reach is build, transfer or a number of tiles')
  fails(function() call('move_to',{target={position={x=40.5,y=0.5}}}) end,'entity not found at (40.5,0.5)')
  fails(function() call('move_to',{target={unit_number=5}}) end,'the game finds no entity by unit_number 5 alone (only vehicles and the like); give its position too: target={position={x,y},unit_number=5}')
  -- position and unit_number: that entity on the tile.
  r=call('move_to',{target={position={x=20.5,y=0.5},unit_number=777},pathfind=false}); eq(r.target.unit_number,777); call('stop',{})
  fails(function() call('move_to',{target={position={x=20.5,y=0.5},unit_number=778}}) end,'entity not found at (20.5,0.5)')
  -- A plain {x,y} target without reach is the position it always was.
  r=call('move_to',{target={x=3,y=0},pathfind=false}); eq(r.target,nil); eq(r.position.x,3); call('stop',{})
  -- No path within reach (every request fails): the give-up's spot within reach is walked to, and arrived at.
  p.position={x=0,y=0}
  local n0=#path_requests
  call('move_to',{target={unit_number=777}})
  for _=1,4 do
    runtime.on_event{name=10,id=#path_requests-1,path=nil}; runtime.on_event{name=10,id=#path_requests,path=nil}
  end
  -- the near probe: its end (12,0.5) is 8.15 tiles from the box, within reach and in the open
  runtime.on_event{name=10,id=#path_requests,path={{position={x=0,y=0}},{position={x=12,y=0.5}}}}
  advance(1)
  local nav=storage.agent_harness.active[1]
  eq(nav.kind,'move_to'); eq(nav.reach_walk.to.x,12); eq(nav.position.x,12)
  runtime.on_event{name=10,id=#path_requests-1,path={{position={x=0,y=0}},{position={x=12,y=0.5}}}}; runtime.on_event{name=10,id=#path_requests,path=nil}
  p.position={x=11.5,y=0.5}; advance(1)
  last=call('status').last
  eq(last.outcome,'arrived'); assert(last.reach_walk:find('walked toward (12,0.5), a spot within reach',1,true),last.reach_walk)
  assert(#path_requests>=n0+8,'the ladder, the near probe and the walk to the spot were asked')
  p.surface.find_entities_filtered,p.can_reach_entity,game.get_entity_by_unit_number,p.build_distance,p.reach_distance=find,reach,get,bd,rd
  p.position={x=0,y=0}
end)()
;(function()
  -- Every example call runs as written (Luna, shift11: fh help launch / transfer; operator 10:50 item 6): the runtime's
  -- own (describe's examples, printed by fh help) and every `fh call ACTION --args '{...}'` in docs/usage.md and
  -- agent/team.md go through the argument check, and the alias fixer finds nothing to correct in them.
  local function decode(text)
    local i=1
    local function ws() i=text:find('[^%s]',i) or #text+1 end
    local value
    local function str()
      local out,j={},i+1
      while true do
        local c=text:sub(j,j)
        if c=='"' then i=j+1; return table.concat(out) end
        if c=='\\' then local n=text:sub(j+1,j+1); out[#out+1]=({n='\n',t='\t',r='\r'})[n] or n; j=j+2
        else out[#out+1]=c; j=j+1 end
        assert(j<=#text+1,'unterminated string')
      end
    end
    value=function()
      ws()
      local c=text:sub(i,i)
      if c=='{' then
        local t={}; i=i+1; ws()
        if text:sub(i,i)=='}' then i=i+1; return t end
        while true do
          ws(); local k=str(); ws(); assert(text:sub(i,i)==':','expected :'); i=i+1
          t[k]=value(); ws()
          local d=text:sub(i,i); i=i+1
          if d=='}' then return t end
          assert(d==',','expected , or } at '..i)
        end
      elseif c=='[' then
        local t={}; i=i+1; ws()
        if text:sub(i,i)==']' then i=i+1; return t end
        while true do
          t[#t+1]=value(); ws()
          local d=text:sub(i,i); i=i+1
          if d==']' then return t end
          assert(d==',','expected , or ]')
        end
      elseif c=='"' then return str()
      elseif text:sub(i,i+3)=='true' then i=i+4; return true
      elseif text:sub(i,i+4)=='false' then i=i+5; return false
      elseif text:sub(i,i+3)=='null' then i=i+4; return nil
      else
        local num=text:match('^-?%d+%.?%d*[eE]?[-+]?%d*',i)
        assert(num and #num>0,'bad value at '..i..': '..text:sub(i,i+10))
        i=i+#num; return tonumber(num)
      end
    end
    return value()
  end
  local checked={}
  local check
  check=function(where,action,args)
    local ok,err=pcall(runtime.check_args,action,args)
    assert(ok,where..': '..action..' '..runtime.aliases.encode(args)..': '..tostring(err))
    local _,_,fix=runtime.aliases.fix(action,args,runtime.takes)
    assert(fix==nil,where..': '..action..' '..runtime.aliases.encode(args)..' is not as the runtime takes it: '..table.concat(fix and fix.notes or {},'; '))
    checked[#checked+1]=action
    -- queue steps inside (order_set, queue_submit, queue_repeat): each step too
    for i,step in ipairs(type(args.steps)=='table' and args.steps or {}) do
      if type(step)=='table' and type(step.action)=='string' then check(where..' step '..i,step.action,step.args or {}) end
    end
  end
  local d=call('describe')
  local n=0
  for name,schema in pairs(d.actions) do
    for i,ex in ipairs(schema.examples or {}) do n=n+1; check('describe '..name..' example '..i,name,ex) end
  end
  assert(d.actions.launch.examples and d.actions.transfer.examples,'launch and transfer carry examples')
  local docs,found=0,0
  for _,path in ipairs({'docs/usage.md','../../agent/team.md'}) do
    -- (the compacted-module run works in a copy without the docs: describe's examples only there)
    local f=io.open(path)
    local text=f and f:read('a') or ''
    if f then f:close(); found=found+1 end
    for action,json in text:gmatch("fh call ([%w_]+) %-%-args '(%b{})'") do
      assert(d.actions[action],path..': fh call '..action..' is no action')
      -- placeholders: a bare N is a number
      local args=decode((json:gsub('([:%[,]%s*)N([,%]}])','%11%2')))
      docs=docs+1; check(path,action,args)
    end
  end
  assert(n>=20 and (found==0 or docs>=15),'examples checked: '..n..' in describe, '..docs..' in the docs')
end)()
;(function()
  -- Forms the docs give (take-and-give, requests set as a map; friction3: Haiku and Grok read "warning: corrected" on
  -- each): a quiet fix sets no corrected on success; any other note still does.
  local fix=runtime.aliases.fix
  runtime.aliases.fix=function(action,args) return action,args,{notes={'a documented form'},call=action..' {}',quiet=true} end
  eq(call('status',{}).corrected,nil)
  runtime.aliases.fix=function(action,args) return action,args,{notes={'x is y'},call=action..' {}'} end
  eq(call('status',{}).corrected,'status {} (x is y)')
  runtime.aliases.fix=fix
end)()
;(function()
  -- Argument refusals name the form that works, with the caller's own values (Muse, Luna, shift11; operator 11:02).
  -- Two places, to take from and to give to (friction2: Grok's from_entity and to_entity, refused as unknown arguments
  -- three times): the call runs as the pick courier and says so (here the item is unknown to the fake game).
  fails(function() call('transfer',{from_entity={x=52.5,y=45.5},to_entity={x=65.5,y=14.5},item='agricultural-science-pack',count=1000}) end,
    [=[[ran as transfer {"count":1000,"item":"agricultural-science-pack","pick":"first_with_stock","positions":[{"x":52.5,"y":45.5}],"to":{"x":65.5,"y":14.5}}: from_entity and to_entity without pick: a take there and a give at to_entity (pick="first_with_stock")]]=])
  -- to on another entity than position's (Muse 17:18:55 named the silo twice; on its own tiles the call runs as a
  -- give there): a move between the two, which pick makes.
  fails(function() call('transfer',{position={x=15.5,y=59.5},item='rocket-fuel',count=50,direction='to_entity',to={x=30.5,y=60.5},inventory='rocket_silo_rocket'}) end,
    [[to goes with pick (pick + positions + item or items + to: take at the first listed place holding it, give at to); for this call: fh call transfer --args '{"count":50,"item":"rocket-fuel","pick":"first_with_stock","positions":[{"x":15.5,"y":59.5}],"to":{"x":30.5,"y":60.5}}']])
  -- items: one item a call.
  fails(function() call('transfer',{position={x=35.5,y=35.5},direction='to_player',items={pipe=16,['small-electric-pole']=8}}) end,
    [[for this call: fh call transfer --args '{"count":16,"direction":"to_player","item":"pipe","position":{"x":35.5,"y":35.5}}' (transfer moves one item a call: 2 named, one call each; or pick with items, the first a place holds)]])
  -- Another action's unknown argument: its example.
  fails(function() call('technologies',{pack='electromagnetic-science-pack'}) end,
    [[unknown argument pack for technologies; valid: available, limit, prefix; e.g. fh call technologies --args '{"prefix":"automation"}']])
  -- A range says the range and the value.
  fails(function() call('nearest',{name='iron-ore',radius=500}) end,[[radius out of range: a whole number 1..128, got 500; e.g. fh call nearest --args '{"name":"iron-ore","radius":64}']])
  -- launch without its silo (Luna 17:43): the silos there, a ready rocket first, and the call.
  local find=p.surface.find_entities_filtered
  defines.rocket_silo_status=defines.rocket_silo_status or {building_rocket=1,rocket_ready=9}
  local proto={rocket_parts_required=50}
  p.surface.find_entities_filtered=function(f)
    if f.type=='rocket-silo' then
      return {{valid=true,name='rocket-silo',position={x=14.5,y=140.5},rocket_silo_status=defines.rocket_silo_status.building_rocket,rocket_parts=12,prototype=proto},
        {valid=true,name='rocket-silo',position={x=65.5,y=14.5},rocket_silo_status=defines.rocket_silo_status.rocket_ready,rocket_parts=0,prototype=proto}}
    end
    return find(f)
  end
  fails(function() call('launch',{platform='Sunward'}) end,
    [[launch takes the silo: position (or unit_number); e.g. fh call launch --args '{"platform":"Sunward","position":{"x":65.5,"y":14.5}}'; silos on ]])
  fails(function() call('launch',{platform='Sunward'}) end,[[: rocket-silo (65.5,14.5) rocket ready; rocket-silo (14.5,140.5) building_rocket, parts 12/50]])
  p.surface.find_entities_filtered=find
end)()
-- Gemini 12:20: Fulgora's sky on the networks read's Fulgora row (lightning.lua M.sky), and in status there with the
-- bolts near the character.
;(function()
  local s=p.surface
  local kept_read,kept_get,kept_planet=runtime.networks.read,game.get_surface,s.planet
  local fields={'daytime','darkness','ticks_per_day','dusk','evening','morning','dawn','freeze_daytime','count_entities_filtered'}
  local kept={}
  for _,k in ipairs(fields) do kept[k]=s[k] end
  s.planet={name='fulgora'}
  s.daytime,s.darkness,s.ticks_per_day,s.dusk,s.evening,s.morning,s.dawn,s.freeze_daytime=0.5,0.85,10800,0.25,0.45,0.55,0.75,false
  s.count_entities_filtered=function(f) eq(f.type,'lightning'); return 3 end
  local other={name='nauvis-2',planet={name='nauvis'}}
  game.get_surface=function(n) if n==s.name then return s end if n=='nauvis-2' then return other end end
  runtime.networks.read=function() return {surfaces={{surface=s.name,electric={},logistic={}},{surface='nauvis-2',electric={},logistic={}}},as_of='0s ago'} end
  local r=call('networks',{})
  eq(r.surfaces[1].storm.state,'storm'); eq(r.surfaces[1].storm.phase,'full dark'); eq(r.surfaces[1].storm.dawn_in_s,45)
  eq(r.surfaces[1].storm.bolts_near,nil,'the read is the surface\'s, no character'); eq(r.surfaces[2].storm,nil)
  local st=call('status',{})
  eq(st.storm.state,'storm'); eq(st.storm.bolts_near,3)
  assert(st.storm.line:find('^fulgora sky: storm, full dark %(darkness 0%.85; lightning%); brightening in 9s, dawn %(clear%) in 45s; 3 lightning bolts within 64 tiles of you now'),st.storm.line)
  s.planet=nil
  eq(call('status',{}).storm,nil,'not on Fulgora')
  runtime.networks.read,game.get_surface,s.planet=kept_read,kept_get,kept_planet
  for _,k in ipairs(fields) do s[k]=kept[k] end
end)()
-- shift12 15:20 (rocketload.lua): launch's min_cargo guard before the game is asked, load_silo waiting for its rocket
-- as a timed action and then loading in that tick, a queue dry run that queues nothing; describe has them.
;(function()
  local d=call('describe',{})
  assert(d.actions.load_silo and d.actions.preflight,'load_silo and preflight described')
  assert(d.actions.launch.min_cargo and d.actions.launch.arrived and d.actions.queue_submit.dry_run,'launch min_cargo and arrived, queue_submit dry_run')
  local kept_find,kept_main,kept_rss,kept_pos,kept_platforms=p.surface.find_entities_filtered,main,defines.rocket_silo_status,p.position,p.force.platforms
  defines.rocket_silo_status=defines.rocket_silo_status or {building_rocket=1,rocket_ready=9}
  defines.inventory.rocket_silo_rocket=defines.inventory.rocket_silo_rocket or 21
  local RR=defines.inventory.rocket_silo_rocket
  prototypes.item['agricultural-science-pack']=prototypes.item['agricultural-science-pack'] or {}
  local ag=prototypes.item['agricultural-science-pack']
  local kept_w,kept_s=ag.weight,ag.stack_size
  ag.weight,ag.stack_size=1000,200
  local function listing(t)
    t.get_contents=function() local out={}; for _,s in ipairs(t) do if s.valid_for_read then out[#out+1]={name=s.name,count=s.count,quality='normal'} end end; return out end
    t.is_empty=function() return #t.get_contents()==0 end
    t.can_insert=function() return true end
    return t
  end
  local cargo=listing(inv(stack('agricultural-science-pack',60),stack(nil,0),stack(nil,0)))
  local silo={valid=true,name='rocket-silo',type='rocket-silo',position={x=5.5,y=5.5},force=p.force,surface=p.surface,unit_number=77,
    rocket_silo_status=defines.rocket_silo_status.rocket_ready,rocket_parts=0,prototype={rocket_parts_required=50},use_transitional_requests=false}
  local rocket_there=true
  silo.get_inventory=function(i) if i==RR and rocket_there then return cargo end end
  local kept_gmi=p.get_main_inventory
  p.get_main_inventory=function() return main end
  p.position={x=0,y=0}; p.force.platforms={}
  p.surface.find_entities_filtered=function(f) if f.type=='rocket-silo' or f.position then return {silo} end return {} end
  -- launch: min_cargo short is refused in this tick, before the game is asked; met, the launch goes on (here to a
  -- platform that is not there, refused by launch itself).
  fails(function() call('launch',{position=silo.position,platform='Nowhere',min_cargo={['agricultural-science-pack']=100}}) end,
    'launch refused at tick '..tick..', nothing launched: min_cargo not met: agricultural-science-pack 60 of 100 (40 short); the rocket holds agricultural-science-pack*60')
  cargo[1].count=100
  fails(function() call('launch',{position=silo.position,platform='Nowhere',min_cargo={['agricultural-science-pack']=100}}) end,'no platform named Nowhere')
  -- load_silo: no rocket yet, a timed action (kind feed) until there is one, then the load in that tick.
  rocket_there=false
  for i=1,3 do cargo[i]=stack(nil,0) end
  main=inv(stack('agricultural-science-pack',90),stack(nil,0))
  main.get_contents=function() return {{name='agricultural-science-pack',count=main[1].count,quality='normal'}} end
  local r=call('load_silo',{position=silo.position,items={['agricultural-science-pack']=90},chests=false})
  eq(r.waiting.why,'no rocket to load yet'); assert(r.until_tick==tick+3600,tostring(r.until_tick))
  eq(call('status',{}).active.kind,'feed')
  advance(25); eq(call('status',{}).active.kind,'feed','still no rocket')
  rocket_there=true; advance(15)
  local st=call('status',{})
  eq(st.active,false); eq(st.last.outcome,'fed'); eq(st.last.result.loaded[1].loaded,90); eq(st.last.result.complete,true)
  eq(cargo[1].count,90); eq(main[1].count,0)
  -- A delivery near the old deadline extends the wait before timeout is
  -- tested; status and completion carry its measured rate and idle window.
  do
    rocket_there=false;silo.rocket_parts=45
    local w=call('load_silo',{position=silo.position,items={['agricultural-science-pack']=1},chests=false,ticks=60})
    local a=storage.agent_harness.active[1]
    advance(40);silo.rocket_parts=46
    advance(21)
    local active=call('status').active
    eq(active.kind,'feed');eq(active.silo_wait.parts_added,1)
    assert(active.silo_wait.idle_window_s>1)
    assert(active.silo_wait.parts_per_min>0)
    a.await_silo.give_up=tick+20
    a.until_tick=tick+20
    silo.rocket_parts=47
    advance(21)
    local ended=call('status').last
    eq(ended.outcome,'timed_out');eq(ended.silo_wait.gives_up_tick,tick-1)
    eq(ended.silo_wait.parts_added,2)
  end
  -- Sonnet, shift14 22:50 (re-issued 3 times as the wait ran out each minute through the build): while the silo makes
  -- parts the wait goes on; ticks with no new part ends it.
  do
    rocket_there=false; silo.rocket_parts=0
    main[1]=stack('agricultural-science-pack',10)
    local w=call('load_silo',{position=silo.position,items={['agricultural-science-pack']=10},chests=false,ticks=60})
    assert(w.waiting.note:find('^waits while the silo makes parts: the idle window starts at 1s'),w.waiting.note)
    eq(w.gives_up_tick,tick+216000)
    for k=1,12 do advance(4); silo.rocket_parts=k*4; advance(3) end  -- 84 ticks, a part every 7
    eq(call('status',{}).active.kind,'feed','past its 60 ticks while parts came')
    advance(80)
    local stl=call('status',{})
    eq(stl.active,false); eq(stl.last.outcome,'timed_out','no new part for 60 ticks')
    silo.rocket_parts=0; rocket_there=true; main[1]=stack(nil,0)
  end
  -- With launch to a platform that does not exist: refused before anything is loaded (the platform is read first;
  -- Sonnet, shift17 19:15).
  main[1]=stack('agricultural-science-pack',10)
  local aboard_before=cargo[1].valid_for_read and cargo[1].count or 0
  fails(function() call('load_silo',{position=silo.position,items={['agricultural-science-pack']=100},to_total=true,chests=false,launch=true,platform='Nowhere'}) end,
    'no platform named Nowhere')
  eq(cargo[1].valid_for_read and cargo[1].count or 0,aboard_before,'nothing loaded'); eq(main[1].count,10)
  call('load_silo',{position=silo.position,items={['agricultural-science-pack']=100},to_total=true,chests=false})
  eq(cargo[1].count,100)
  -- Astra 18:33 (tick 9965693) and 23:53, Gemini 18:21: with the game's item stacks (quality a LuaQualityPrototype,
  -- userdata) load_silo matched nothing and said held 0. Your own inventory (chests=false), as a queue step (Astra's
  -- followed a wait_until item_count) and as a direct call; it fails on the rocketload.lua before the fix (0 of 50).
  local qn=io.tmpfile(); debug.setmetatable(qn,{__index={name='normal'}})
  local function game_stack(name,n) local s=stack(name,n); s.quality=qn; return s end
  for i=1,3 do cargo[i]=stack(nil,0) end
  main=inv(game_stack('agricultural-science-pack',80),stack(nil,0))
  main.get_contents=function() return {{name='agricultural-science-pack',count=main[1].count,quality='normal'}} end
  call('queue_cancel',{})
  call('queue_submit',{steps={{action='load_silo',args={position=silo.position,items={['agricultural-science-pack']=50},chests=false}}}})
  advance(3)
  local qs=call('queue_status',{history=2})
  local last=qs.history[#qs.history]
  eq(last.action,'load_silo'); eq(last.ok,true,'the queued load_silo step')
  eq(last.result.loaded[1].loaded,50); eq(last.result.loaded[1].from,'you 50')
  eq(cargo[1].count,50); eq(main[1].count,30)
  -- the same as a direct call
  r=call('load_silo',{position=silo.position,items={['agricultural-science-pack']=30},chests=false})
  eq(r.loaded[1].loaded,30); eq(r.complete,true); eq(cargo[1].count,80); eq(main[1].count,0)
  -- none held: the why says what you held
  main[1]=game_stack('agricultural-science-pack',0)
  r=call('load_silo',{position=silo.position,items={['agricultural-science-pack']=5},chests=false})
  eq(r.loaded[1].why,'you held 0; chests not read (chests=false)')
  -- A queue dry run: the cargo before the launch step, queued nothing.
  cargo[1].count=60
  local before=call('queue_status',{}).revision
  local dr=call('queue_submit',{dry_run=true,steps={{action='wait_until',args={['until']='rocket_ready',position=silo.position}},
    {action='launch',args={position=silo.position,platform='Nowhere',min_cargo={['agricultural-science-pack']=100}}}}})
  eq(dr.dry_run,true); eq(dr.queued,false); eq(dr.steps,2)
  eq(dr.launches[1].step,2); eq(dr.launches[1].cargo,'agricultural-science-pack*60')
  eq(dr.launches[1].would_refuse[1],'min_cargo not met: agricultural-science-pack 60 of 100 (40 short)')
  eq(call('queue_status',{}).revision,before,'nothing queued')
  fails(function() call('queue_submit',{dry_run='yes',steps={}}) end,'dry_run must be true or false')
  -- A step's arguments checked at submit as the live call reads them (Sol, shift17 19:06): modules (a map too), by, and
  -- a transfer of an item with no direction.
  fails(function() call('queue_submit',{dry_run=true,steps={{action='configure',args={position=silo.position,modules={['agricultural-science-pack']=2}}}}}) end,
    'steps[1] (configure): args: not a module: agricultural-science-pack')
  fails(function() call('queue_submit',{steps={{action='configure',args={position=silo.position,modules={'agricultural-science-pack'}}}}}) end,'not a module')
  fails(function() call('queue_submit',{dry_run=true,steps={{action='configure',args={position=silo.position,by='robot'}}}}) end,'by is hand')
  fails(function() call('queue_submit',{dry_run=true,steps={{action='transfer',args={position=silo.position,item='agricultural-science-pack',count=5}}}}) end,
    'steps[1] (transfer): args: a queued transfer of an item needs direction: to_entity (from your inventory into the target) or to_player')
  fails(function() call('queue_submit',{dry_run=true,steps={{action='transfer',args={position=silo.position,item='agricultural-science-pack',direction='in'}}}}) end,
    'direction must be to_entity or to_player')
  eq(call('queue_submit',{dry_run=true,steps={{action='transfer',args={position=silo.position,item='agricultural-science-pack',count=5,direction='to_entity'}}}}).steps,1)
  eq(call('queue_status',{}).revision,before,'nothing queued')
  -- walk with from (Luna, shift14 21:20: 930 agricultural science packs from a provider 64 tiles from the silo took four
  -- walks and several calls): a chest out of reach; one timed tour takes there and loads at the silo.
  local chest={valid=true,name='iron-chest',type='container',position={x=40.5,y=5.5},force=p.force,surface=p.surface,unit_number=78}
  local held_inv=inv(stack('agricultural-science-pack',100),stack('agricultural-science-pack',50))
  chest.get_inventory=function(i) if i==defines.inventory.chest then return held_inv end end
  p.surface.find_entities_filtered=function(f)
    if f.position and math.abs(f.position.x-40.5)<1 then return {chest} end
    if f.type=='rocket-silo' or f.position then return {silo} end
    return {}
  end
  for i=1,3 do cargo[i]=stack(nil,0) end
  main=inv(stack(nil,0),stack(nil,0))
  main.get_contents=function() local out={}; for _,s in ipairs(main) do if s.valid_for_read then out[#out+1]={name=s.name,count=s.count,quality='normal'} end end; return out end
  local reach_was=p.can_reach_entity
  local far={[chest]=true}
  p.can_reach_entity=function(e) return not far[e] end
  r=call('load_silo',{position=silo.position,items={['agricultural-science-pack']=120},from={x=40.5,y=5.5},walk=true})
  eq(r.op,'load_silo'); eq(r.walk,true); eq(r.needs,'agricultural-science-pack 120 (you hold 0)'); eq(r.trip,'1 chest, then the silo')
  eq(#r.legs,2); eq(r.legs[1].name,'iron-chest'); eq(r.legs[2].name,'rocket-silo'); eq(call('status',{}).active.kind,'gather')
  far={}; advance(1)
  st=call('status',{})
  eq(st.active,false); eq(st.last.outcome,'loaded'); eq(st.last.loaded,120); eq(st.last.taken,120); eq(st.last.trips,1)
  eq(st.last.stops[1].taken,120); eq(st.last.stops[2].loaded,120); eq(st.last.moved,120)
  eq(cargo[1].count+(cargo[2].count or 0),120); eq(held_inv.get_item_count{name='agricultural-science-pack'},30)
  -- as a queue step: loaded is a success
  for i=1,3 do cargo[i]=stack(nil,0) end
  far={[chest]=true}
  call('queue_cancel',{})
  call('queue_submit',{steps={{action='load_silo',args={position=silo.position,items={['agricultural-science-pack']=20},from={x=40.5,y=5.5},walk=true}}}})
  advance(1); far={}; advance(3)
  local qh=call('queue_status',{history=1}).history
  eq(qh[#qh].action,'load_silo'); eq(qh[#qh].ok,true,'the queued walking load_silo step'); eq(cargo[1].count,20)
  held_inv[1]=stack('agricultural-science-pack',30); held_inv[2]=stack(nil,0)
  -- the chest and the silo in reach: the load at once, as without walk (standing between them)
  p.position={x=22,y=5}
  r=call('load_silo',{position=silo.position,items={['agricultural-science-pack']=30},from={x=40.5,y=5.5},walk=true})
  eq(r.complete,true); eq(r.loaded[1].loaded,30); eq(r.op,nil)
  -- nothing in the chest: refused, nothing walked
  far={[chest]=true}
  fails(function() call('load_silo',{position=silo.position,items={['agricultural-science-pack']=10},from={x=40.5,y=5.5},walk=true}) end,
    'nothing walked: the rocket still needs agricultural-science-pack 10 (you hold 0) and the chests in from hold none of it (iron-chest (40.5,5.5) holds 0 agricultural-science-pack)')
  fails(function() call('load_silo',{position=silo.position,items={['agricultural-science-pack']=10},walk=true}) end,'walk goes with from')
  -- fresh_first (Luna, shift14 22:50): for an item that spoils, the least spoiled stacks of you and the chests first,
  -- each moved whole; fresh_first=false: you first, then the chests.
  do
    far={}
    for i=1,3 do cargo[i]=stack(nil,0) end
    local kept_spoil=ag.get_spoil_ticks
    ag.get_spoil_ticks=function() return 3600*60 end
    local function aged(n,pct) local s=stack('agricultural-science-pack',n); s.spoil_percent=pct; s.spoil_tick=game.tick+(1-pct)*3600*60; return s end
    main=inv(aged(50,0.6),stack(nil,0))
    main.get_contents=function() local out={}; for _,s in ipairs(main) do if s.valid_for_read then out[#out+1]={name=s.name,count=s.count,quality='normal'} end end; return out end
    held_inv[1]=aged(50,0.3); held_inv[2]=aged(50,0.1)
    r=call('load_silo',{position=silo.position,items={['agricultural-science-pack']=80},from={x=40.5,y=5.5}})
    eq(r.loaded[1].loaded,80); eq(r.loaded[1].order,'fresh first'); eq(r.loaded[1].from,'iron-chest (40.5,5.5) 80')
    eq(r.loaded[1].freshness:match('^[^;]*'),'agricultural-science-pack*80: spoiled 10-30%, 18% by count')
    eq(held_inv[2].count,0,'the 10% stack first'); eq(held_inv[1].count,20,'then 30 of the 30% one'); eq(main[1].count,50,'yours (60%) stays')
    -- fresh_first=false: you first
    for i=1,3 do cargo[i]=stack(nil,0) end
    r=call('load_silo',{position=silo.position,items={['agricultural-science-pack']=60},from={x=40.5,y=5.5},fresh_first=false})
    eq(r.loaded[1].order,nil); eq(r.loaded[1].from,'you 50, iron-chest (40.5,5.5) 10'); eq(main[1].count,0)
    eq(r.loaded[1].freshness:match('^[^;]*'),'agricultural-science-pack*60: spoiled 30-60%, 55% by count')
    ag.get_spoil_ticks=kept_spoil
    held_inv[1]=stack(nil,0); held_inv[2]=stack(nil,0)
  end
  p.can_reach_entity=reach_was
  -- A launch before the rocket is built names its parts (Grok, shift14 21:20).
  silo.rocket_silo_status=defines.rocket_silo_status.building_rocket; silo.rocket_parts=35
  fails(function() call('launch',{position=silo.position,platform='Nowhere'}) end,', building the rocket: parts 35/50')
  silo.rocket_silo_status=defines.rocket_silo_status.rocket_ready; silo.rocket_parts=0
  p.surface.find_entities_filtered,main,defines.rocket_silo_status,p.position,p.force.platforms=kept_find,kept_main,kept_rss,kept_pos,kept_platforms
  ag.weight,ag.stack_size=kept_w,kept_s; p.get_main_inventory=kept_gmi
end)()
-- Nick 15:50 (efficiency.lua): production credited to who built the machine. An operator read listed in describe and
-- an operator seed; a machine the agent builds is in the log under its name; the review shows the line.
;(function()
  local reads=runtime.dispatch{action='describe',args={},player=1}.operator_reads
  local listed=false
  for _,r in ipairs(reads) do listed=listed or r=='efficiency' end
  assert(listed,'efficiency is an operator read')
  local kept_ts=table_size
  table_size=table_size or function(t) local n=0; for _ in pairs(t) do n=n+1 end; return n end
  prototypes.entity['assembling-machine-2']=prototypes.entity['assembling-machine-2'] or {}
  local kept_type=prototypes.entity['assembling-machine-2'].type
  prototypes.entity['assembling-machine-2'].type='assembling-machine'
  local e={valid=true,name='assembling-machine-2',type='assembling-machine',position={x=8.5,y=8.5},surface=p.surface,unit_number=4242}
  local before=runtime.dispatch{action='efficiency',args={},operator=true}.logged
  runtime.efficiency.built(runtime.board.who(p),e)
  local r=runtime.dispatch{action='efficiency',args={},operator=true}
  eq(r.logged.units,before.units+1); eq(r.logged.spots,before.spots+1); assert(r.team and r.agents and r.walk,'team, agents, walk')
  local seed=runtime.dispatch{action='efficiency_seed',args={rows={{unit=77,by='opus',tick=1}}},operator=true}
  eq(seed.units,1)
  -- the review carries the agent's line once its machines have a record
  local lines=runtime.selfview.review(p)
  local found=false
  for _,l in ipairs(lines) do found=found or l:find('^machines you built made %d+ items this shift')~=nil end
  assert(found,table.concat(lines,' | '))
  prototypes.entity['assembling-machine-2'].type=kept_type
  table_size=kept_ts
end)()
-- Grok, shift13 18:20 (beltpick.lua): pickup {belt: true, item, count} takes items off belt lanes; item and count go with
-- belt; a queued pickup that ends picked_up is a success (it counted as a failed step, and standing orders' pickups with it).
;(function()
  local kept_find=p.surface.find_entities_filtered
  p.surface.find_entities_filtered=function() return {} end
  fails(function() call('pickup',{belt=true,item='iron-plate',position={x=0,y=0},radius=3}) end,'no iron-plate on our belts in (-3,-3)-(3,3): no belt of ours there')
  fails(function() call('pickup',{item='iron-plate',position={x=0,y=0}}) end,'item and count go with belt=true')
  fails(function() call('pickup',{belt='yes',item='iron-plate'}) end,'belt must be true')
  p.surface.find_entities_filtered=kept_find
  local kept_pick,kept_tick=runtime.beltpick.pickup,runtime.beltpick.tick
  local ticks_seen=0
  runtime.beltpick.pickup=function(pp,a)
    storage.agent_harness.active[pp.index]={kind='pickup',belt=true,items={a.item},count=a.count,taken=0,until_tick=game.tick+600,picked={}}
    return {until_tick=game.tick+600}
  end
  runtime.beltpick.tick=function(_,action)
    ticks_seen=ticks_seen+1
    if ticks_seen>=3 then action.taken=action.count; action.picked={['iron-plate']=action.count}; return 'picked_up' end
  end
  call('queue_cancel',{})
  call('queue_submit',{steps={{action='pickup',args={belt=true,item='iron-plate',count=5,position={x=0,y=0}}}}})
  advance(6)
  local qs=call('queue_status',{history=1})
  local last=qs.history[#qs.history]
  eq(last.action,'pickup'); eq(last.ok,true,'picked_up is a success'); eq(last.result.outcome,'picked_up')
  eq(call('status',{}).last.belt.taken,5)
  runtime.beltpick.pickup,runtime.beltpick.tick=kept_pick,kept_tick
end)()
-- Shift14: default equip hit a loaded pistol slot twice before index=2 worked.
;(function()
  local old_get,old_main=p.get_inventory,p.get_main_inventory
  local old_gun,old_ammo,old_armor=defines.inventory.character_guns,defines.inventory.character_ammo,defines.inventory.character_armor
  defines.inventory.character_guns,defines.inventory.character_ammo,defines.inventory.character_armor=2,3,4
  local gun_slots={stack('pistol',1),stack(nil,0),stack(nil,0)}
  local ammo_slots={stack('firearm-magazine',10),stack(nil,0),stack(nil,0)}
  local armor_slots={stack('light-armor',1)}
  local source=stack('rocket-launcher',1)
  p.get_inventory=function(id) return id==2 and gun_slots or id==3 and ammo_slots or armor_slots end
  p.get_main_inventory=function() return {find_item_stack=function(name) return source.valid_for_read and source.name==name and source or nil end} end
  local occupied_attempts=0
  gun_slots[1].swap_stack=function() occupied_attempts=occupied_attempts+1; return false end
  local r=call('equip',{slot='gun',item='rocket-launcher'})
  eq(r.index,2); eq(gun_slots[1].name,'pistol'); eq(gun_slots[2].name,'rocket-launcher'); eq(occupied_attempts,0)
  source=stack('rocket',20)
  local ammo_swap=ammo_slots[2].swap_stack
  ammo_slots[2].swap_stack=function(other) return gun_slots[2].name=='rocket-launcher' and ammo_swap(other) end
  r=call('equip',{slot='ammo',item='rocket'}); eq(r.index,2); eq(ammo_slots[1].name,'firearm-magazine')
  -- Empty incompatible slots are skipped, without changing either stack.
  source=stack('piercing-rounds-magazine',10)
  ammo_slots[2]=stack(nil,0); ammo_slots[2].swap_stack=function() return false end
  r=call('equip',{slot='ammo',item='piercing-rounds-magazine'}); eq(r.index,3); eq(ammo_slots[2].valid_for_read,false)
  -- An explicit index never redirects to another slot.
  source=stack('rocket-launcher',1)
  fails(function() call('equip',{slot='gun',item='rocket-launcher',index=1}) end,'gun slot 1 (holds pistol)')
  eq(occupied_attempts,1); eq(source.name,'rocket-launcher'); eq(source.count,1); eq(gun_slots[3].valid_for_read,false)
  fails(function() call('equip',{slot='gun',item='rocket-launcher',index=4}) end,'index')
  -- No empty compatible slot: preserve the historical slot-1 swap fallback.
  gun_slots[3].swap_stack=function() return false end
  fails(function() call('equip',{slot='gun',item='rocket-launcher'}) end,'nothing moved')
  eq(source.count,1)
  source=stack('heavy-armor',1)
  r=call('equip',{slot='armor',item='heavy-armor'}); eq(r.index,1); eq(source.name,'light-armor')
  -- d15 (Sol 07:50): a gun already in a gun slot is selected; an occupied slot swaps when the main inventory has room.
  source=stack(nil,0)
  r=call('equip',{slot='gun',item='rocket-launcher'}); eq(r.selected,'rocket-launcher'); eq(r.index,2); eq(p.character.selected_gun_index,2)
  local held={}
  source=stack('submachine-gun',1)
  p.get_main_inventory=function() return {find_item_stack=function(name) return source.valid_for_read and source.name==name and source or nil end,
    can_insert=function() return true end,insert=function(st) held[st.name]=(held[st.name] or 0)+st.count; return st.count end,
    remove=function(st) held[st.name]=(held[st.name] or 0)-st.count; return st.count end} end
  local g1=gun_slots[1]
  g1.clear=function() g1.name,g1.count,g1.valid_for_read=nil,0,false end
  g1.transfer_stack=function(o) g1.name,g1.count,g1.valid_for_read=o.name,o.count,true; o.name,o.count,o.valid_for_read=nil,0,false; return true end
  g1.set_stack=function(st) g1.name,g1.count,g1.valid_for_read=st.name,st.count,true end
  r=call('equip',{slot='gun',item='submachine-gun',index=1})
  eq(r.index,1); eq(g1.name,'submachine-gun'); eq(held.pistol,1); eq(r.replaced,'pistol*1 (to your inventory)'); eq(p.character.selected_gun_index,1)
  p.get_inventory,p.get_main_inventory=old_get,old_main
  defines.inventory.character_guns,defines.inventory.character_ammo,defines.inventory.character_armor=old_gun,old_ammo,old_armor
end)()


;(function()
  -- outputs_only never falls through to fuel, even if an output drains during a walk.
  call('queue_cancel',{}); call('stop',{})
  local saved={main=main,find=p.surface.find_entities_filtered,reach=p.can_reach_entity,pos=p.position}
  local output,fuel=inv(stack(nil,0)),inv(stack('coal',9))
  local e={valid=true,name='stone-furnace',type='furnace',force=p.force,position={x=20,y=0},
    get_output_inventory=function() return output end,get_fuel_inventory=function() return fuel end}
  e.get_inventory=function(id) if id==defines.inventory.furnace_result then return output elseif id==defines.inventory.fuel then return fuel end end
  p.surface.find_entities_filtered=function(f) return f.position and {e} or {} end
  p.can_reach_entity=function() return math.abs(p.position.x-20)<=10 end
  main=inv(stack(nil,0),stack(nil,0)); p.position={x=15,y=0}
  local r=call('collect',{position=e.position,item='coal',outputs_only=true,up_to=true})
  eq(r.transferred,0); eq(fuel[1].count,9)
  r=call('collect',{positions={e.position},items={'coal'},pick='first_with_stock',outputs_only=true})
  eq(r.picked,'none'); eq(fuel[1].count,9)
  r=call('collect',{radius=32,item='coal',outputs_only=true})
  eq(r.stock,0); advance(1); eq(fuel[1].count,9)
  p.position={x=0,y=0}
  call('collect',{position=e.position,item='coal',outputs_only=true,walk=true,up_to=true,avoid_enemies=false})
  advance(1); p.position={x=15,y=0}; advance(2)
  eq(fuel[1].count,9); eq(call('status').last.outcome,'nothing_collected')
  output[1]=stack('coal',3)
  r=call('collect',{position=e.position,item='coal',outputs_only=true})
  eq(r.transferred,3); eq(fuel[1].count,9)
  main=saved.main; p.surface.find_entities_filtered=saved.find; p.can_reach_entity=saved.reach; p.position=saved.pos
end)()

;(function()
  -- feed cleanup runs at the walked-to stop, before the input is topped up.
  call('queue_cancel',{});call('stop',{})
  local saved={main=main,get_main=p.get_main_inventory,find=p.surface.find_entities_filtered,reach=p.can_reach_entity,pos=p.position,burnt=defines.inventory.burnt_result}
  p.get_main_inventory=function() return main end
  defines.inventory.burnt_result=83
  prototypes.item['iron-ore']={type='item',name='iron-ore'}
  prototypes.item.spoilage={type='item',name='spoilage'}
  local function listing(t)
    t.get_contents=function() local out={} for _,st in ipairs(t) do if st.valid_for_read then out[#out+1]={name=st.name,count=st.count,quality=st.quality.name} end end return out end
    return t
  end
  local source=listing(inv(stack('spoilage',4)))
  local output=listing(inv(stack('spoilage',3)))
  local fuel=listing(inv(stack('spoilage',2)))
  local burnt=listing(inv(stack('spoilage',5)))
  local slots={[defines.inventory.furnace_source]=source,[defines.inventory.furnace_result]=output,[defines.inventory.fuel]=fuel,[83]=burnt}
  local recipe={name='iron-plate',ingredients={{type='item',name='iron-ore',amount=1}},products={{type='item',name='iron-plate',amount=1}}}
  local e={valid=true,name='stone-furnace',type='furnace',position={x=20,y=0},force=p.force,
    get_recipe=function() return recipe end,get_inventory=function(id) return slots[id] end,get_fuel_inventory=function() return fuel end,
    get_burnt_result_inventory=function() return burnt end}
  p.surface.find_entities_filtered=function(f) return f.position and {e} or {} end
  p.can_reach_entity=function() return math.abs(p.position.x-20)<=10 end
  main=listing(inv(stack('iron-ore',10),stack(nil,0),stack(nil,0)))
  p.position={x=0,y=0}
  local r=call('feed',{position=e.position,item='iron-ore',count=3,clear_spoilage=true,avoid_enemies=false})
  eq(call('status').active.kind,'gather');eq(source[1].name,'spoilage','no remote clearing')
  advance(1);p.position={x=15,y=0};advance(2)
  eq(source[1].name,'iron-ore');eq(source[1].count,3);eq(output[1].valid_for_read,false);eq(fuel[1].valid_for_read,false);eq(burnt[1].valid_for_read,false)
  local last=call('status').last
  eq(#last.entities[1].cleared,4);eq(last.given,3);eq(main.get_item_count{name='spoilage'},14)
  -- With no supply left, a dirty-only stop is still selected by a radius tour.
  main=listing(inv(stack(nil,0),stack(nil,0)))
  output[1]=stack('spoilage',2);p.position={x=15,y=0}
  call('feed',{radius=32,items={'iron-ore'},clear_spoilage=true,avoid_enemies=false})
  advance(2);eq(output[1].valid_for_read,false);eq(call('status').last.entities[1].cleared[1].taken,2)
  -- A later dirty stop keeps the tour going even with no top-up items carried.
  local other_output=listing(inv(stack('spoilage',3)))
  local other={valid=true,name='stone-furnace',type='furnace',force=p.force,position={x=40,y=0},get_recipe=function() return recipe end,
    get_inventory=function(id) if id==defines.inventory.furnace_result then return other_output end end}
  output[1]=stack('spoilage',2);main=listing(inv(stack(nil,0),stack(nil,0)));p.position={x=0,y=0}
  p.surface.find_entities_filtered=function(f) return f.position and {f.position.x==40 and other or e} or {} end
  p.can_reach_entity=function(target) return math.abs(p.position.x-target.position.x)<=10 end
  call('feed',{positions={e.position,other.position},items={'iron-ore'},clear_spoilage=true,walk=true,avoid_enemies=false})
  advance(1);p.position={x=15,y=0};advance(2);eq(call('status').active.kind,'gather')
  p.position={x=35,y=0};advance(2)
  eq(other_output[1].valid_for_read,false);eq(#call('status').last.entities,2);eq(main.get_item_count{name='spoilage'},5)
  main=saved.main;p.surface.find_entities_filtered=saved.find;p.can_reach_entity=saved.reach;p.position=saved.pos;defines.inventory.burnt_result=saved.burnt;p.get_main_inventory=saved.get_main
end)()
;(function()
  -- Construct's material-only preview is a read: no marking, walking or crafting.
  call('queue_cancel',{});call('stop',{})
  local saved={find=p.surface.find_entities_filtered,main=main,get_main=p.get_main_inventory}
  p.get_main_inventory=function() return main end
  local ghost={valid=true,type='entity-ghost',force=p.force,position={x=1,y=1},ghost_name='iron-chest',
    ghost_prototype={items_to_place_this={{name='iron-chest',count=2}}}}
  p.surface.find_entities_filtered=function(f) return f.limit==1025 and {ghost} or {} end
  main=inv(stack('iron-chest',1))
  call('queue_submit',{steps={{action='wait_ticks',args={ticks=100}}}});advance(1)
  local r=call('construct',{area={left_top={x=0,y=0},right_bottom={x=2,y=2}},dry_run=true})
  eq(r.materials[1].need,2);eq(r.materials[1].missing,1);eq(r.dry_run,true)
  eq(call('queue_status').paused,false);eq(call('queue_status').active.action,'wait_ticks')
  call('queue_cancel',{});call('stop',{})
  main=saved.main;p.surface.find_entities_filtered=saved.find;p.get_main_inventory=saved.get_main
end)()

-- Remote plans use a separate channel through the real dispatch boundary.
;(function()
  call('queue_cancel',{})
  call('queue_submit',{lane='remote',steps={{action='wait_ticks',args={ticks=8}},{action='describe'}}})
  call('walk',{direction='east',ticks=100})
  advance(2)
  local action=storage.agent_harness.active[1]
  eq(action.kind,'walk'); eq(action.queued,nil)
  local r=call('status',{brief=true})
  eq(r.queues.remote.active.action,'wait_ticks'); eq(r.queues.body.paused,true)
  call('walk',{direction='west',ticks=100})
  action=storage.agent_harness.active[1]
  advance(10)
  local q=call('queue_status',{lane='remote'})
  eq(q.paused,false); eq(q.active,false); eq(q.history[#q.history].action,'describe')
  eq(storage.agent_harness.active[1],action); eq(action.queued,nil)
  fails(function() call('queue_submit',{lane='remote',steps={{action='walk',args={direction='east',ticks=1}}}}) end,'steps[1]')
  eq(storage.agent_harness.active[1],action)
  call('queue_repeat',{lane='remote',steps={{action='wait_ticks',args={ticks=100}}}})
  advance(1); call('queue_cancel',{lane='remote'})
  eq(storage.agent_harness.active[1],action)
  eq(call('queue_status',{}).lanes.remote.paused,true)
  call('stop',{})
end)()
;(function()
  -- Actual runtime wiring retains the shared planner's facts for a failed feed stop.
  call('stop',{})
  local reach,probe,report=p.can_reach_entity,runtime.margin_probe.tick,runtime.avoid.report
  p.can_reach_entity=function() return false end
  runtime.margin_probe.tick=function() return false end
  runtime.avoid.report=function(out) out.why='fixture corridor blocked';out.smaller_margins={largest_verified_margin=2,line='largest verified margin 2 tiles'} end
  local pos={x=p.position.x+40,y=p.position.y}
  local e={valid=true,position=pos,name='iron-chest'}
  storage.agent_harness.active[1]={kind='gather',op='feed',item='coal',targets={{entity=e,position=pos}},index=1,got=0,visited=0,want=math.huge,
    until_tick=game.tick+600,avoid_mode={pad=4},nav={position=pos,tolerance=7,path_state='unsafe',foes={}}}
  advance(1)
  local a=storage.agent_harness.active[1]
  eq(a.route_failures[1].smaller_margins.largest_verified_margin,2)
  assert(a.first_unreached:find('fixture corridor blocked; largest verified margin 2 tiles',1,true))
  advance(1)
  eq(call('status',{brief=true}).last.route_failures[1].smaller_margins.largest_verified_margin,2)
  p.can_reach_entity,runtime.margin_probe.tick,runtime.avoid.report=reach,probe,report
end)()
;(function()
  -- The runtime carries entry circuit/wire settings into the platform preview.
  local check,platform,find,pump=runtime.dryrun.check,p.surface.platform,p.surface.find_entities_filtered,prototypes.entity.pump
  runtime.dryrun.check=function() return {summary='fixture placement preview'},{},{} end
  p.surface.platform={force=p.force,name='fixture-platform'}
  p.surface.find_entities_filtered=function() return {} end
  prototypes.entity.pump={type='pump',name='pump'}
  local r=call('dry_run',{action='place_ghosts',args={entities={{name='pump',position={x=1,y=1},circuit={enable='signal-D = 0'}}}}})
  assert(r.pump_circuits[1]:find('no red or green wire declared',1,true))
  runtime.dryrun.check,p.surface.platform,p.surface.find_entities_filtered,prototypes.entity.pump=check,platform,find,pump
end)()
-- Every field the d15 conditions take passes argument checks in each place a condition goes (Sol 10:01: a queue step
-- wait_until {until: platform_built, platform, entities: true} was refused as an unknown argument).
;(function()
  local conds={{['until']='platform_built',platform='Wayfarer',entities=true},
    {['until']='produced',item='iron-plate',at_least=5,positions={{x=1,y=1}}},{['until']='produced',at_least=1,position={x=1,y=1}}}
  local function no_unknown(fn,where)
    local ok,err=pcall(fn)
    assert(ok or not tostring(err):find('unknown argument',1,true),where..': '..tostring(err))
  end
  for i,c in ipairs(conds) do
    local step={}; for k,v in pairs(c) do step[k]=v end; step.timeout=3600
    no_unknown(function() runtime.check_args('wait_until',step) end,'check_args '..i)
    no_unknown(function() call('queue_submit',{start=false,steps={{action='wait_until',args=step}}}) end,'queue step '..i)
    no_unknown(function() call('queue_submit',{start=false,steps={},guards={{when=c}}}) end,'guard '..i)
    no_unknown(function() call('wait_until',step) end,'direct '..i)
    call('queue_cancel',{})
  end
  -- the other arguments the d15 batch added, each through the same check
  for _,c in ipairs({{'load_silo',{up_to=true}},{'refuel',{from_radius=128}},{'queue_edit',{id='job-1',to=1}},{'circuit_set',{set_requests=true}},
      {'requests',{remove={'coal'},force=true}},{'board',{projects='compact'}},{'board_post',{blocked_by={1},parent=1,open_steps=true}},
      {'board_update',{take_step=1,release_step=1,open_steps=true,blocked_by={},parent=false}},{'fuel_budget',{surface='nauvis'}},{'platform_endurance',{platform='Wayfarer',route={'nauvis'}}},{'artillery',{position={x=1,y=1},radius=300,surface='nauvis'}},{'sleep',{seconds=5,wake_on_urgent={radius=12}}},{'wait_ticks',{ticks=60,wake_on_urgent={radius=12}}},{'configure',{position={x=1,y=1},auto_targeting=false}},
      {'mine',{count=5}},{'feed',{position={x=1,y=1},radius=5}},{'queue_submit',{mode='pending'}},{'pickup',{belt=true,to={x=1,y=1}}},{'refuel',{feed_chests=true}},{'placements',{platform='Starling',name='cargo-bay'}},{'build',{check_inserters=true}},{'place_ghosts',{check_inserters=true}}}) do
    no_unknown(function() runtime.check_args(c[1],c[2]) end,'check_args '..c[1])
  end
end)()
;(function()
  -- An urgent radius rides on a direct wait (Grok, d15 14:07).
  local r=call('wait_ticks',{ticks=60,wake_on_urgent={radius=12}})
  eq(storage.agent_harness.active[1].urgent.radius,12)
  call('stop',{})
  local ok,err=pcall(call,'wait_ticks',{ticks=60,wake_on_urgent={radius=500}})
  assert(not ok and tostring(err):find('radius is 1..200',1,true),tostring(err))
end)()
;(function()
  -- The way walked, offered back to a refused walk (Haiku, d15 07:50).
  local kept=p.position
  local act={trail_pts={{x=0,y=0}},surface_name=p.surface.name}
  for i=1,10 do runtime.trail_point(act,{x=i*10,y=0}) end
  eq(#act.trail_pts,11)
  p.position={x=100,y=0}
  runtime.walked_record(1,act,'arrived')
  local back=runtime.walked_back(1,{x=98,y=1},{x=2,y=0},p.surface.name)
  assert(back and back.via[1].x==90 and back.via[#back.via].x==10,'reversed points')
  assert(back.line:find('you walked from (0,0) to (100,0)',1,true),back.line)
  eq(runtime.walked_back(1,{x=50,y=40},{x=2,y=0},p.surface.name),nil,'not where it ended')
  eq(runtime.walked_back(1,{x=98,y=1},{x=60,y=60},p.surface.name),nil,'not toward where it started')
  runtime.walked_record(1,{trail_pts={{x=0,y=0}},surface_name='x'},'blocked')
  p.position=kept
end)()
;(function()
  -- Cargo bay attachment and the tile grid (Astra, d15 07:50: "nothing found" for a bay that fit its cleared footprint).
  local hub={valid=true,type='space-platform-hub',name='space-platform-hub',position={x=0,y=0},bounding_box={left_top={x=-4,y=-4},right_bottom={x=4,y=4}}}
  local fake={surface={find_entities_filtered=function() return {hub} end},force=p.force}
  local bay={name='cargo-bay',type='cargo-bay',tile_width=4,tile_height=4,collision_box={left_top={x=-1.9,y=-1.9},right_bottom={x=1.9,y=1.9}}}
  local w=runtime.attach_why(fake,bay,{x=10,y=0},0)
  assert(w:find('a cargo bay joins the platform hub or another cargo bay edge to edge; its box (8,-2)-(12,2) touches none; the nearest: space-platform-hub (0,0), box (-4,-4)-(4,4), 4 tiles from its edge',1,true),w)
  w=runtime.attach_why(fake,bay,{x=6,y=0},0)
  assert(w:find('touches space-platform-hub (0,0), and the game still refuses it there',1,true),w)
  w=runtime.attach_why(fake,bay,{x=6.5,y=0},0)
  assert(w:find('off the tile grid: a 4x4 cargo-bay centres on tile edges (x 6 or 7, y 0)',1,true),w)
  eq(runtime.attach_why(fake,{name='chest',type='container',tile_width=1,tile_height=1},{x=1.5,y=1.5},0),nil)
end)()
-- A walking tour's progress in status active (d15 batch3 item 7; Muse, Luna).
;(function()
  local keep=runtime.lookup
  runtime.lookup=function() return {character={valid=true,position={x=0,y=0}}} end
  local tgt={{position={x=3,y=4},name='a'},{position={x=6,y=8},entity={valid=true,name='steel-chest'}},{position={x=6,y=20}}}
  eq(runtime.tour_progress(1,{kind='gather',targets=tgt,index=2,got=40,item='iron-plate'}),
    'stop 2 of 3 (steel-chest (6,8)), 10 tiles to it, 22 tiles left in all; moved 40 iron-plate so far')
  eq(runtime.tour_progress(1,{kind='gather',targets=tgt,index=1,got=50,taken=50,legs={{},{}}}),
    'leg 1 of 3 (a (3,4)), 5 tiles to it, 22 tiles left in all; took 50, delivered 0')
  runtime.lookup=keep
end)()
-- d15 F8 (Grok): an item the machine's recipe takes goes to its recipe input, not its fuel slot (nutrients into a
-- biochamber making pentapod eggs).
;(function()
  defines.inventory.fuel=defines.inventory.fuel or 41; defines.inventory.assembling_machine_input=defines.inventory.assembling_machine_input or 42
  prototypes.item.nutrients={fuel_value=2000000,type='item'}; prototypes.item['bioflux']={fuel_value=6000000,type='item'}
  local function inv() return {valid=true,can_insert=function() return true end} end
  local fuel,input=inv(),inv()
  local bio={name='biochamber',type='assembling-machine',position={x=5.5,y=5.5},
    get_recipe=function() return {name='pentapod-egg',ingredients={{type='item',name='nutrients',amount=30},{type='item',name='pentapod-egg',amount=1}}} end,
    get_fuel_inventory=function() return fuel end,
    get_inventory=function(id) if id==defines.inventory.fuel then return fuel elseif id==defines.inventory.assembling_machine_input then return input end end}
  eq(runtime.accepts_text(bio,{item='nutrients'}),'yes: biochamber (5.5,5.5) takes nutrients into assembling_machine_input','recipe ingredient to the input')
  eq(runtime.accepts_text(bio,{item='bioflux'}),'yes: biochamber (5.5,5.5) takes bioflux into fuel','a fuel the recipe does not take')
  eq(runtime.accepts_text(bio,{item='nutrients',inventory='fuel'}),'yes: biochamber (5.5,5.5) takes nutrients into fuel','inventory fuel named')
end)()
print('runtime: '..assertions..' assertions passed')
