-- Run from repository root: lua tests/d25_batch217.lua
-- d25 batch217 QAB1 (Sol #2390: Nauvis network #243 has 7523 logistic robots; reservations and where_is read the
-- first 1024, so the robots taking bioflux from the landing pad at (52,54) to the requester at (-269.5,486.5) could
-- not be shown). reservations {position, from?, radius?}: one chest's or pad's own counts and the robots in the air
-- near it (and along the line from `from`) with an order there, found against those counts; sweep: true reads the
-- whole network across ticks. Read only.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..'\n  lacks: '..x) end
local function refused(fn) local ok,err=pcall(fn); assert(not ok,'should be refused'); return tostring(err) end
game={tick=1000}
defines={robot_order_type={pickup=0,repair=1,construct=2,deconstruct=3,deliver_items=4,upgrade=5,explode_cliff=6,deliver=7,pickup_items=8},inventory={chest=1,robot_cargo=2}}
prototypes={item={bioflux={name='bioflux'},['steel-plate']={name='steel-plate'}}}
local PICKUP,DELIVER=0,7
local force={name='player'}
local ln={valid=true,network_id=243,all_logistic_robots=3000,available_logistic_robots=1500,cells={}}
for x=-300,300,100 do for y=-100,500,100 do ln.cells[#ln.cells+1]={owner={position={x=x,y=y}},logistic_radius=25} end end
local function point(deliver,pickup,net) return {logistic_network=net,targeted_items_deliver=deliver or {},targeted_items_pickup=pickup or {}} end
local function chest(name,type,x,y,half,pts) return {valid=true,name=name,type=type,position={x=x,y=y},half=half,unit_number=math.random(1,1e6),get_logistic_point=function() return pts end} end
local Q={name='normal'}
-- the requester: 24 bioflux on the way (6 robots x 4); the pad: 16 reserved for pickup (4 robots), and its request from orbit
local T=chest('requester-chest','logistic-container',-269.5,486.5,0.5,{point({{name='bioflux',quality='normal',count=24}},nil,ln),point(nil,nil,ln)})
local P=chest('cargo-landing-pad','cargo-landing-pad',52,54,4,{point({{name='steel-plate',quality='normal',count=100}},nil,nil),point(nil,{{name='bioflux',quality='normal',count=16}},ln)})
local O=chest('requester-chest','logistic-container',144.5,-0.5,0.5,{point(nil,nil,ln)})
local robots,un={},0
local function robot(x,y,queue,cargo)
  un=un+1
  local r={valid=true,name='logistic-robot',type='logistic-robot',position={x=x,y=y},unit_number=un,robot_order_queue=queue}
  r.get_inventory=function() return {[1]=cargo and {valid_for_read=true,name=cargo,count=4,quality=Q} or {valid_for_read=false}} end
  robots[#robots+1]=r
  return r
end
local function bio(n) return {name=prototypes.item.bioflux,quality=Q} end
-- 1400 robots on other errands first (as the network lists them), within 64 tiles of the pad and elsewhere
for i=1,1400 do robot(-250+(i%500),-90+(i%580),{{type=PICKUP,target=O,target_item={name=prototypes.item['steel-plate'],quality=Q},target_count=4},{type=DELIVER,target=O}}) end
-- 3 going to pick bioflux up at the pad for the requester, near the pad
for i=1,3 do robot(52+i*5,40,{{type=PICKUP,target=P,target_item=bio(),target_count=4},{type=DELIVER,target=T,target_item=bio(),target_count=4}}) end
-- 2 carrying it, on the line from the pad to the requester
local mx,my=(52-269.5)/2,(54+486.5)/2
robot(mx,my,{{type=DELIVER,target=T,target_item=bio(),target_count=4}},'bioflux')
robot(mx+10,my-12,{{type=DELIVER,target=T,target_item=bio(),target_count=4}},'bioflux')
-- 1 going to the pad from far off (outside what a targeted read reads)
robot(290,480,{{type=PICKUP,target=P,target_item=bio(),target_count=4},{type=DELIVER,target=T,target_item=bio(),target_count=4}})
ln.logistic_robots=robots
local finds=0
local surface={name='nauvis',index=1,valid=true}
surface.find_entities_filtered=function(f)
  finds=finds+1
  local a=f.area
  local x0,y0,x1,y1=a[1][1],a[1][2],a[2][1],a[2][2]
  local out={}
  if f.type=='logistic-robot' then
    for _,r in ipairs(robots) do
      if r.valid and r.position.x>=x0 and r.position.x<=x1 and r.position.y>=y0 and r.position.y<=y1 then
        out[#out+1]=r
        if f.limit and #out>=f.limit then break end
      end
    end
    return out
  end
  local cx,cy=(x0+x1)/2,(y0+y1)/2
  for _,e in ipairs({T,P,O}) do if math.abs(e.position.x-cx)<=e.half and math.abs(e.position.y-cy)<=e.half then out[#out+1]=e end end
  return out
end
T.surface,P.surface=surface,surface
game.get_surface=function(n) return n=='nauvis' and surface or nil end
game.surfaces={[1]=surface,nauvis=surface}
local st={}
local R=dofile('mod/agent-harness_0.1.0/reservations.lua'){state=function() return st end}
local sol={index=1,surface=surface,force=force}
force.logistic_networks={nauvis={ln}}
-- the network read, as before: the first 1024 robots, none of them these
local nw=R.read(sol,{network=243,item='bioflux'})
eq(nw.robots,nil,'the first 1024 robots read hold none of them'); has(nw.lines[1],'(the first 1024 robots)')
-- the requester, from the pad: its own count, 20 of its 24 found on 5 robots, each with source and destination
local r=R.read(sol,{position={x=-269.5,y=486.5},from={x=52,y=54},item='bioflux'})
eq(r.entity.name,'requester-chest'); eq(r.network,243)
eq(r.on_the_way[1].item,'bioflux'); eq(r.on_the_way[1].count,24)
eq(r.found_on_the_way[1].count,20); eq(r.robots_found,5); eq(r.not_found_on_the_way[1],'bioflux 4')
has(r.lines[1],'requester-chest (-269.5,486.5), logistic #243 (bioflux): on the way here bioflux 24, reserved for pickup here none (its own counts); found bioflux 20 on its way')
has(r.lines[2],'on the way here and not found on the robots read: bioflux 4 (on robots outside what was read)')
local routes=table.concat(r.routes,'\n')
has(routes,'3 robots: 12 bioflux from cargo-landing-pad (52,54) to requester-chest (-269.5,486.5) (3 flying to pick it up at its source)')
has(routes,'2 robots: 8 bioflux from a source not kept to requester-chest (-269.5,486.5) (2 carrying it (a robot keeps no source once it has picked up))')
local carry
for _,x in ipairs(r.robots) do if x.state:find('carrying',1,true) then carry=x end end
eq(carry.source,nil); eq(carry.destination.name,'requester-chest'); has(carry.line,'4 bioflux from a source not kept to requester-chest (-269.5,486.5), carrying it')
assert(r.robots_read<=1024 and r.robots_read>5,'robots read: '..r.robots_read)
-- without from: only round the requester (none of them there)
local r0=R.read(sol,{position={x=-269.5,y=486.5}})
eq(r0.robots_found,0); eq(r0.not_found_on_the_way[1],'bioflux 24')
-- the pad: 16 reserved for pickup, 12 found on the 3 robots near it, each to the requester; its request from orbit apart
local pr=R.read(sol,{position={x=50,y=56}})
eq(pr.entity.name,'cargo-landing-pad'); eq(pr.reserved_for_pickup[1].count,16); eq(pr.found_for_pickup[1].count,12); eq(pr.not_found_for_pickup[1],'bioflux 4')
eq(pr.on_the_way[1],nil,'no robot brings the pad its request from orbit'); eq(pr.from_orbit[1].item,'steel-plate'); eq(pr.from_orbit[1].count,100)
has(table.concat(pr.lines,'\n'),'on the way to its point in no logistic network (a landing pad\'s request from platforms in orbit; no robot brings it): steel-plate 100')
has(pr.routes[1],'3 robots: 12 bioflux from cargo-landing-pad (52,54) to requester-chest (-269.5,486.5) (3 flying to pick it up here)')
-- the cap: past READ_MAX robots in the areas, said
R.READ_MAX=100
local rc=R.read(sol,{position={x=144.5,y=-0.5},radius=128})
eq(rc.robots_read,100); eq(rc.capped,true); has(rc.lines[1],'up to 100 robots: the rest there not read')
R.READ_MAX=1024
-- refused: nothing there, and with no world (the call, a queue step and dry_run)
has(refused(function() R.read(sol,{position={x=999,y=999}}) end),'no chest or landing pad of ours with logistic points at (999,999) on nauvis')
has(refused(function() R.check_point({position={x=1,y=1},radius=200}) end),'radius: 8..128 tiles (default 64)')
has(refused(function() R.check_point({position={x=1,y=1},from='pad'}) end),'from: {x, y}')
has(refused(function() R.check_point({position={x=1,y=1},network=243}) end),'no network')
has(refused(function() R.check_point({position={x=1,y=1},sweep=true,radius=64}) end),'sweep reads the whole network: no from or radius')
has(refused(function() R.check_point({sweep=2,item='bioflux'}) end),'sweep: N reads that sweep alone')
has(refused(function() R.check_point({from={x=1,y=1}}) end),'position: {x, y}')
R.check_point({position={x=1,y=1},from={x=2,y=2},radius=128,item='bioflux'})
print('d25_batch217 QAB1 targeted read: ok')

-- the sweep: every robot in the air across ticks, all 24 found, the far one too
do
  local s=R.read(sol,{position={x=-269.5,y=486.5},item='bioflux',sweep=true})
  eq(s.sweep.n,1); eq(s.sweep.state,'running'); has(s.line,'sweep 1: every logistic robot of logistic #243 in the air')
  local cols=s.sweep.columns
  -- one delivered while it reads: the count at its end is 20, at its start 24
  T.get_logistic_point()[1].targeted_items_deliver={{name='bioflux',quality='normal',count=20}}
  eq(R.read(sol,{sweep=1}).sweep.state,'running')
  local steps=0
  while not st.robot_sweeps.jobs[1].done do game.tick=game.tick+1; R.tick(); steps=steps+1; assert(steps<1000,'the sweep ends') end
  assert(steps>=cols,'a column a tick at most')
  local d=R.read(sol,{sweep=1})
  eq(d.sweep.state,'done'); eq(d.found_on_the_way[1].count,24); eq(d.not_found_on_the_way,nil); eq(d.robots_found,6)
  eq(d.robots_read,#robots,'each robot once')
  has(d.lines[1],'a sweep of '..cols..' columns over ticks')
  has(d.lines[1],'on the way here bioflux 20, reserved for pickup here none (its own counts at the sweep\'s end; at its start: on the way bioflux 24, reserved none)')
  eq(d.at_start.on_the_way[1].count,24); eq(d.on_the_way[1].count,20)
  -- one an agent: a new one replaces it; kept 10 min after it ends
  local s2=R.read(sol,{position={x=50,y=56},sweep=true})
  eq(s2.sweep.n,2); eq(st.robot_sweeps.jobs[1],nil)
  while not st.robot_sweeps.jobs[2].done do game.tick=game.tick+1; R.tick() end
  game.tick=game.tick+R.KEEP+1; R.tick()
  has(refused(function() R.read(sol,{sweep=2}) end),'no sweep 2 is kept')
  eq(st.robot_sweeps.active,nil,'no work a tick once none runs')
end
print('d25_batch217 QAB1 sweep: ok')

-- the runtime: a queue step and dry_run check it with no world
do
storage={agent_harness={active={}}}
defines.events={on_script_path_request_finished=10,on_entity_died=11,on_entity_damaged=12,on_console_chat=13,on_unit_group_finished_gathering=14,
  on_built_entity=15,on_player_mined_entity=16,on_robot_mined_entity=17,on_player_fast_transferred=18,on_gui_opened=19,on_gui_closed=20}
defines.shooting={not_shooting=0,shooting_enemies=1}; defines.controllers={character=1,remote=27,spectator=2}; defines.direction={north=0}
defines.build_mode={normal=1}; defines.build_check_type={manual=1}; defines.flow_precision_index={five_seconds=0,one_minute=1}
rendering={draw_text=function() return {valid=true,destroy=function() end} end,get_object_by_id=function() return nil end}
remote={interfaces={}}
helpers={json_to_table=function(t) return t end}
local f={name='player',chart=function() end,is_chunk_visible=function() return true end,is_chunk_charted=function() return true end,get_spawn_position=function() return {x=0,y=0} end}
local surfaces={}
local function character(sf,pos)
  local c={valid=true,name='character',type='character',force=f,surface=sf,position=pos,unit_number=900,health=250,
    driving=false,build_distance=10,reach_distance=10,character_running_speed=0.15,walking_state={walking=false}}
  local inv={get_item_count=function() return 0 end,find_item_stack=function() return nil end,get_contents=function() return {} end}
  c.insert=function(s) return s.count end
  c.get_main_inventory=function() return inv end
  c.get_item_count=function() return 0 end
  c.can_reach_entity=function() return true end
  c.destroy=function() c.valid=false end
  return c
end
local s={name='nauvis',index=1,valid=true,planet={name='nauvis'}}
s.find_non_colliding_position=function(_,origin) return origin end
s.create_entity=function(args) if args.name=='character' then return character(s,args.position) end return {valid=true,name=args.name,position=args.position} end
s.can_place_entity=function() return true end
s.find_entities_filtered=function() return {} end
s.count_entities_filtered=function() return 0 end
s.get_total_pollution=function() return 0 end; s.get_chunks=function() return function() end end; s.get_pollution=function() return 0 end
s.request_path=function() return 1 end
surfaces.nauvis=s; surfaces[1]=s
local nick={index=1,name='nick',valid=true,connected=true,controller_type=1,physical_controller_type=1,cheat_mode=false,driving=false,force=f,surface=s,position={x=5,y=5},chat_color={r=1,g=1,b=1},print=function() end}
nick.character=character(s,{x=5,y=5})
local players={nick}
game={tick=2000,players=players,forces={player=f,enemy={name='enemy',get_evolution_factor=function() return 0 end,get_evolution_factor_by_time=function() return 0 end,
  get_evolution_factor_by_pollution=function() return 0 end,get_evolution_factor_by_killing_spawners=function() return 0 end}},
  get_player=function(i) if type(i)=='string' then for _,p in ipairs(players) do if p.name==i then return p end end return nil end return players[i] end,
  get_surface=function(n) return surfaces[n] end,surfaces=surfaces,print=function() end,connected_players=players,
  get_pollution_statistics=function() return {input_counts={},output_counts={},get_flow_count=function() return 0 end} end}
local runtime=dofile('mod/agent-harness_0.1.0/runtime.lua')
runtime.operator.bot_create('sol')
local function plan(steps) return function() return runtime.dispatch{action='queue_submit',args={dry_run=true,steps=steps},bot='sol'} end end
local function check(fn) local ok,err=pcall(fn); return ok and 'ok' or tostring(err) end
has(check(plan({{action='reservations',args={position={x=1,y=2},radius=500}}})),'steps[1] (reservations): args: radius: 8..128 tiles (default 64)')
has(check(plan({{action='reservations',args={sweep=3,radius=64}}})),'sweep: N reads that sweep alone')
eq(check(plan({{action='reservations',args={position={x=1,y=2},from={x=40,y=2},item='bioflux'}}})),'ok')
has(check(function() return runtime.dispatch{action='reservations',args={position={x=1,y=2},radius=7},bot='sol'} end),'radius: 8..128')
end
print('d25_batch217 QAB1 runtime and queue checks: ok')
