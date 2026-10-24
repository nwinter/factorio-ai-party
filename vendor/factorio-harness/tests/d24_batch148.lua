-- d24 batch148 PT1 (Astra #2159): Astra's body lane read "a call of yours failed while your queue ran" every ~17 s with no
-- failing call of hers: the stream service read board_focus as the team's first bot (astra), and board_focus was neither
-- passive nor a read, so each read took over her character (dispatch_request's direct-call pause). Now board_focus is
-- passive, a request with `reader` (another process's read made as an agent) never touches the agent's queue or
-- character and takes reads only, a pause names its action and request id, and an interrupted item move is never
-- skipped. Run from the harness root: lua tests/d24_batch148.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
local function lacks(s,x) assert(not tostring(s):find(x,1,true),tostring(s)..' has '..x) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end

storage={agent_harness={active={}}}
defines={events={on_script_path_request_finished=10,on_entity_died=11,on_entity_damaged=12,on_console_chat=13,on_unit_group_finished_gathering=14},
  shooting={not_shooting=0,shooting_enemies=1},controllers={character=1,remote=27,spectator=2},direction={north=0},
  inventory={chest=1,character_main=1,character_guns=3,character_ammo=4},
  build_mode={normal=1},build_check_type={manual=1},flow_precision_index={five_seconds=0,one_minute=1}}
prototypes={item={['submachine-gun']={type='gun',attack_parameters={ammo_categories={'bullet'},range=18}},
  ['rocket-launcher']={type='gun',attack_parameters={ammo_categories={'rocket'},range=36}},
  ['firearm-magazine']={type='ammo',ammo_category={name='bullet'}},rocket={type='ammo',ammo_category={name='rocket'}},
  ['iron-plate']={type='item'}}}
local drawn={}
rendering={draw_text=function() local obj={valid=true}; obj.destroy=function() obj.valid=false end; drawn[#drawn+1]=obj; return obj end,
  get_object_by_id=function(id) return drawn[id] end}
remote={interfaces={}}
helpers={json_to_table=function(t) return t end}
local force={name='player',get_friend=function() return false end,get_cease_fire=function() return false end,chart=function() end,
  is_chunk_visible=function() return true end,is_chunk_charted=function() return true end,get_spawn_position=function() return {x=0,y=0} end}
local surface={name='nauvis',index=1}
local units=0
local function character(pos)
  units=units+1
  local c={valid=true,name='character',type='character',force=force,surface=surface,position=pos,unit_number=500+units,health=250,max_health=250,
    prototype={collision_box={left_top={x=-0.2,y=-0.2},right_bottom={x=0.2,y=0.2}},collision_mask={layers={player=true}}},
    driving=false,build_distance=10,reach_distance=10,character_running_speed=0.15,walking_state={walking=false},selected_gun_index=1}
  c.insert=function(s) return s.count end
  c.get_item_count=function() return 0 end
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
local players={}
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
  if not ok then
    if req.bot then pcall(runtime.stop_player,runtime.bots.index_of(req.bot)) end
    error(result,0)
  end
  return result
end
local function as(name) return function(action,args) return request{action=action,args=args or {},bot=name} end end
local seq=0
local function req(name,action,args,extra)
  seq=seq+1
  local r={id='req-'..seq,action=action,args=args or {},bot=name}
  for k,v in pairs(extra or {}) do r[k]=v end
  return request(r)
end
runtime.operator.bot_create('astra')
local function qs() return req('astra','queue_status',{}) end
local function plan() req('astra','queue_submit',{mode='replace',steps={{action='move_to',args={position={x=200,y=0},pathfind=false}},{action='wait_ticks',args={ticks=600}}}}); advance(3) end
plan()
eq(qs().paused,false)
-- the stream service's board_focus read as astra (reader stream), and astra's own board_focus read: neither pauses
req('astra','board_focus',{peek=true},{reader='stream'})
eq(qs().paused,false,'before: paused by a call of yours failed')
req('astra','board_focus',{})
eq(qs().paused,false,'board_focus moves no character')
-- a reader's read that fails pauses nothing either
fails(function() req('astra','observe',{scope='no-such-scope'},{reader='analyst'}) end,'')
eq(qs().paused,false,'a reader\'s failed read')
-- a reader request that would drive the character is refused, and pauses nothing
fails(function() req('astra','move_to',{position={x=5,y=5}},{reader='stream'}) end,'reader stream: move_to acts as the agent (it can drive the character); a reader request takes reads only')
eq(qs().paused,false)
-- astra's own direct move_to: the pause names it and its request id
req('astra','move_to',{position={x=-20,y=0},pathfind=false})
local q=qs()
eq(q.paused,true)
has(q.paused_why,'paused by your direct move_to call (request req-')
has(q.paused_why,'), which drives your character')
lacks(q.paused_why,'failed')
-- her failing direct call: named with its request id
req('astra','queue_resume',{}); advance(2)
local ok,err=pcall(req,'astra','move_to',{position={x=5,y=5},unsafe_goal='yes'})
assert(not ok)
local id='req-'..seq
q=qs()
has(q.paused_why,'your move_to call (request '..id..') failed while your queue ran (')
print('d24_batch148 PT1 reader requests, board_focus, the pause named: ok')

-- an interrupted item move: requeued at the head as it was when it had moved nothing; held, named, when it had moved some
do
  local factory=dofile('mod/agent-harness_0.1.0/scheduler.lua')
  local st={}
  local players={[1]={index=1}}
  local S=factory{state=function() return st end,player=function(i) return players[i] end,handlers={transfer=function() return {} end},
    busy=function() return true end,stop=function() end,stop_index=function() end,condition=function() return false end,validate_condition=function() end}
  local function setq(step) st.queues={[1]={pending={{id='job-2',action='wait_ticks',args={ticks=60}}},history={},revision=1,sequence=2,current=step,paused=false}} end
  local courier={id='job-36694',action='transfer',args={item='tungsten-plate',count=199,pick='first_with_stock',to={x=42.5,y=-24.5},walk=true}}
  -- Astra's courier, walking to its pick when interrupted: nothing moved; before: "not run again"
  setq(courier)
  S.pause(1,'paused by your direct move_to call (request r1), which drives your character')
  local Q=st.queues[1]
  eq(Q.pending[1].id,'job-36694','requeued at the head'); eq(Q.pending[1].args.count,199); eq(Q.pending[2].id,'job-2')
  local last=Q.history[#Q.history]
  eq(last.result.requeued,true); has(last.result.resumed_from,'requeued as it was: it had moved nothing (an item move is not skipped)')
  eq(last.result.not_requeued,nil); eq(Q.held,nil)
  has(last.result.paused_by,'paused by your direct move_to call (request r1)')
  -- a transfer that had moved 40 with no stops left to go on from: the lane is held with it named
  local step={id='job-7',action='transfer',args={item='iron-plate',count=100,position={x=1,y=1}},tour_left={positions={},done=1,total=1,got=40,item='iron-plate'}}
  setq(step)
  S.pause(1,'paused by your direct move_to call (request r2), which drives your character')
  Q=st.queues[1]
  eq(Q.pending[1].id,'job-2','not requeued')
  last=Q.history[#Q.history]
  has(last.result.not_requeued,'held: job-7 transfer was interrupted after moving 40; the rest of it is not known, so it is not run again; queue_resume runs the plan\'s next step')
  eq(Q.held.step,'job-7'); has(Q.paused_why.line,'held: job-7 transfer')
  eq(S.resume_direct(1),false,'a direct call\'s end does not resume a held lane')
end
print('d24_batch148 PT1 interrupted item moves: ok')
