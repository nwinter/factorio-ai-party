-- Run from repository root: lua tests/d25_batch215.lua
-- d25 batch215 QZ3 (Sol #2388: uptime {read: true, id: 'uptime@63906911'} gave Sol's 13-machine watch; Astra's
-- 41-machine watch began on the same tick, so its id was the same and Sol could not page it). A watch's id names its
-- owner, KIND@START_TICK/AGENT, for every measures kind (uptime, turret_tally, belt_flow, collector_tally,
-- asteroid_watch, signal_watch); uptime's read takes agent; an id with no agent reads the one watch begun on that
-- tick and two or more are refused, each named, the reader's own among them.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..'\n  lacks: '..x) end
local function refused(fn) local ok,err=pcall(fn); assert(not ok,'should be refused'); return tostring(err) end
game={tick=1000}
defines={inventory={assembling_machine_input=2,furnace_source=2,assembling_machine_output=3,furnace_result=3}}
local recipe={name='explosives',ingredients={{type='item',name='coal',amount=1},{type='item',name='sulfur',amount=1}}}
-- 54 chemical plants: Sol watches the first 13, Astra the other 41
local ms={}
for k=1,54 do
  local e={valid=true,name='chemical-plant',type='assembling-machine',position={x=k*4+0.5,y=10.5},products_finished=0,status='working'}
  e.get_recipe=function() return recipe,{name='normal'} end
  e.get_fluid_count=function() return 0 end
  e.get_inventory=function() return {get_item_count=function() return 5 end,get_contents=function() return {} end} end
  ms[k]=e
end
local st={}
local names={'sol','astra'}
local who=function(i) return names[i] end
local Ms=dofile('mod/agent-harness_0.1.0/measures.lua'){state=function() return st end,who_index=function(i) return who(i) end}
local api={state=function() return st end,remote_entity=function(_,t) for _,e in ipairs(ms) do if e.position.x==t.position.x then return e end end error('none') end,
  status_name=function(e) return e.status end,craftrate=function() return {crafts_per_min=30,productivity=0} end,who_index=function(i) return who(i) end,
  watch_id=function(kind,job,i) return Ms.id(kind,job,i) end}
local U=dofile('mod/agent-harness_0.1.0/uptime.lua')(api)
local sol,astra,luna={index=1},{index=2},{index=3}
local function at(from,to) local out={} for k=from,to do out[#out+1]={x=ms[k].position.x,y=10.5} end return out end
-- both begin on tick 1000 (aligned to a trial): their ids differ by owner
local s1=U.handler(sol,{positions=at(1,13),seconds=600})
local a1=U.handler(astra,{positions=at(14,54),seconds=600})
eq(s1.id,'uptime@1000/sol'); eq(a1.id,'uptime@1000/astra')
for _=1,3 do game.tick=game.tick+60; U.tick(game.tick) end
-- status work (measures.card) and the running watch (idle, sleep lines) give the same ids
eq(Ms.card(1)[1].id,'uptime@1000/sol'); eq(Ms.card(2)[1].id,'uptime@1000/astra')
eq((Ms.running(1)),'uptime@1000/sol'); eq((Ms.running(2)),'uptime@1000/astra')
has(Ms.card(2)[1].line,'uptime@1000/astra 41 machines')
-- the old form, two watches on that tick: refused with both named, the reader's own among them
local amb=refused(function() U.handler(sol,{read=true,id='uptime@1000'}) end)
has(amb,'uptime@1000: 2 watches began on tick 1000: uptime@1000/astra (41 machines), uptime@1000/sol (13 machines); give one of these ids, or agent')
has(refused(function() U.handler(astra,{read=true,id='uptime@1000'}) end),'2 watches began on tick 1000')
-- by id with the owner, or by agent: Sol pages Astra's 41 machines; its own watch unchanged
local sj,aj=st.uptime[1],st.uptime[2]
local p3=U.handler(sol,{read=true,id='uptime@1000/astra',page=3})
eq(p3.id,'uptime@1000/astra'); eq(p3.agent,'astra'); eq(p3.machines_total,41); eq(p3.pages,3); eq(#p3.machines,9); eq(p3.machines[9].index,41)
has(p3.line,'uptime watch uptime@1000/astra of astra (watching')
local pa=U.handler(sol,{read=true,agent='astra',page=1})
eq(pa.id,'uptime@1000/astra'); eq(pa.machines_total,41); eq(#pa.machines,16)
for _,n in ipairs({'Astra','@astra','pog-astra'}) do eq(U.handler(sol,{read=true,agent=n}).id,'uptime@1000/astra',n) end
eq(U.handler(sol,{read=true,id='uptime@1000/sol'}).machines_total,13)
eq(U.handler(sol,{read=true,agent='astra',id='uptime@1000/astra'}).machines_total,41)
eq(U.handler(sol,{read=true}).id,'uptime@1000/sol','no id, no agent: yours')
eq(st.uptime[1],sj); eq(st.uptime[2],aj); eq(sj.start,1000); eq(aj.start,1000)
-- refused: an id that is not that agent's, an agent with none, a tick with none
has(refused(function() U.handler(sol,{read=true,id='uptime@1000/astra',agent='sol'}) end),
  'no uptime watch uptime@1000/astra of agent sol is kept; kept: uptime@1000/astra (41 machines), uptime@1000/sol (13 machines)')
has(refused(function() U.handler(sol,{read=true,agent='luna'}) end),'no uptime watch of agent luna is kept; kept: uptime@1000/astra')
has(refused(function() U.handler(sol,{read=true,id='uptime@999'}) end),'no uptime watch uptime@999 is kept')
has(refused(function() U.handler(luna,{read=true}) end),'no uptime watch yet')
-- the old form still reads a watch that is the only one begun on its tick
game.tick=1500
eq(U.handler(astra,{positions=at(14,20),seconds=60}).id,'uptime@1500/astra')
eq(U.handler(sol,{read=true,id='uptime@1500'}).agent,'astra')
eq(U.handler(astra,{read=true,id='uptime@1000'}).id,'uptime@1000/sol')
-- a watch begun before this runtime (no id kept): named on its first read, the same id after
st.uptime[1].id=nil
eq(Ms.card(1)[1].id,'uptime@1000/sol'); eq(st.uptime[1].id,'uptime@1000/sol')
-- an owner with no name known: the tick form, not kept
st.uptime[3]={start=1200,until_tick=99999,next_tick=99999,samples=1,sampled=1200,machines={}}
eq(Ms.id('uptime',st.uptime[3],3),'uptime@1200'); eq(st.uptime[3].id,nil)
st.uptime[3]=nil
-- checked with no world, as at submit and in dry_run
has(refused(function() U.check_read({read=true,agent=5}) end),'agent: an agent\'s name')
has(refused(function() U.check_read({read=true,id='uptime@1000/'}) end),'"uptime@START_TICK/AGENT"')
has(refused(function() U.check_read({read=true,id='uptime@1000/a/b'}) end),'"uptime@START_TICK/AGENT"')
has(refused(function() U.check_read({id='uptime@1000/sol'}) end),'id and agent go with read: true')
has(refused(function() U.handler(sol,{agent='astra'}) end),'id and agent go with read: true')
U.check_read({read=true,id='uptime@1000/astra',agent='astra'})
print('d25_batch215 QZ3 uptime ids and agent: ok')

-- every measures kind: two agents' watches begun on one tick have different ids
do
  local s2={}
  local M2=dofile('mod/agent-harness_0.1.0/measures.lua'){state=function() return s2 end,who_index=function(i) return names[i] end}
  game.tick=5000
  local function jobs(i)
    return {
      uptime={start=4000,until_tick=9000,samples=2,sampled=4990,machines={{position={x=i,y=1},recipe='iron-plate',status={working=2}}}},
      turret_tally={start=4000,until_tick=9000,samples=2,sampled=4990,turrets={{position={x=i,y=5},k0=0,k1=0}}},
      belt_flow={start=4000,until_tick=9000,samples=2,sampled=4990,path_from={x=i,y=2},path_to={x=9,y=2},tiles=8,surface='nauvis',points={{left={{},{}}}}},
      collector_tally={start=4000,until_tick=9000,samples=2,sampled=4990,platform='Asterion',collectors={{taken=0,caught=0}}},
      asteroid_watch={start=4000,until_tick=9000,samples=2,sampled=4990,platform='Asterion',turrets={},nast=0},
      signal_watch={start=4000,until_tick=9000,samples=2,sampled=4990,scope='iron-plate on the red network #4',picks={}}}
  end
  for _,k in ipairs(M2.KINDS) do s2[k]={} end
  for i=1,2 do for k,j in pairs(jobs(i)) do s2[k][i]=j end end
  local seen={}
  for i=1,2 do
    local c=M2.card(i)
    eq(#c,#M2.KINDS,'every kind on the card')
    for _,r in ipairs(c) do
      eq(r.id,r.kind..'@4000/'..names[i]); assert(not seen[r.id],'one id twice: '..r.id); seen[r.id]=true
      has(r.line,r.id..' ')
    end
  end
  eq((M2.running(1)),'uptime@4000/sol'); eq((M2.running(2)),'uptime@4000/astra')
end
print('d25_batch215 QZ3 every watch kind: ok')

-- signal_watch's own replies name the owner too
do
  local s3={}
  local M3=dofile('mod/agent-harness_0.1.0/measures.lua'){state=function() return s3 end,who_index=function(i) return names[i] end}
  local S=dofile('mod/agent-harness_0.1.0/signalwatch.lua'){state=function() return s3 end,watch_id=function(kind,job,i) return M3.id(kind,job,i) end}
  local function job() return {start=4000,until_tick=9000,next_tick=9000,samples=1,missed=0,sampled=4000,picks={},stats={},gaps={},scope='x',name='decider-combinator',position={x=0,y=0},key='red'} end
  s3.signal_watch={job(),job()}
  local r1,r2=S.handler({index=1},{}),S.handler({index=2},{})
  eq(r1.id,'signal_watch@4000/sol'); eq(r2.id,'signal_watch@4000/astra'); has(r2.line,'signal_watch@4000/astra x:')
  eq(M3.card(2)[1].id,'signal_watch@4000/astra')
end
print('d25_batch215 QZ3 signal_watch: ok')

-- the runtime: names come from the agents, a queue step and dry_run check the read's agent and id
do
storage={agent_harness={active={}}}
defines={events={on_script_path_request_finished=10,on_entity_died=11,on_entity_damaged=12,on_console_chat=13,on_unit_group_finished_gathering=14,
  on_built_entity=15,on_player_mined_entity=16,on_robot_mined_entity=17,on_player_fast_transferred=18,on_gui_opened=19,on_gui_closed=20},
  shooting={not_shooting=0,shooting_enemies=1},controllers={character=1,remote=27,spectator=2},direction={north=0},inventory={chest=1},
  build_mode={normal=1},build_check_type={manual=1},flow_precision_index={five_seconds=0,one_minute=1}}
rendering={draw_text=function() return {valid=true,destroy=function() end} end,get_object_by_id=function() return nil end}
remote={interfaces={}}
helpers={json_to_table=function(t) return t end}
local force={name='player',chart=function() end,is_chunk_visible=function() return true end,is_chunk_charted=function() return true end,get_spawn_position=function() return {x=0,y=0} end}
local surfaces={}
local function character(surface,pos)
  local c={valid=true,name='character',type='character',force=force,surface=surface,position=pos,unit_number=500+#surfaces,health=250,
    driving=false,build_distance=10,reach_distance=10,character_running_speed=0.15,walking_state={walking=false}}
  local inv={get_item_count=function() return 0 end,find_item_stack=function() return nil end,get_contents=function() return {} end}
  c.insert=function(s) return s.count end
  c.get_main_inventory=function() return inv end
  c.get_item_count=function() return 0 end
  c.can_reach_entity=function() return true end
  c.destroy=function() c.valid=false end
  return c
end
local function new_surface(name,index,extra)
  local s={name=name,index=index,valid=true}
  for k,v in pairs(extra) do s[k]=v end
  s.find_non_colliding_position=function(_,origin) return origin end
  s.create_entity=function(args) if args.name=='character' then return character(s,args.position) end return {valid=true,name=args.name,position=args.position} end
  s.can_place_entity=function() return true end
  s.find_entities_filtered=function() return {} end
  s.count_entities_filtered=function() return 0 end
  s.get_total_pollution=function() return 0 end; s.get_chunks=function() return function() end end; s.get_pollution=function() return 0 end
  s.request_path=function() return 1 end
  surfaces[name]=s; surfaces[index]=s
  return s
end
local nauvis=new_surface('nauvis',1,{planet={name='nauvis'}})
local nick={index=1,name='nick',valid=true,connected=true,controller_type=1,physical_controller_type=1,cheat_mode=false,driving=false,force=force,surface=nauvis,position={x=5,y=5},chat_color={r=1,g=1,b=1}}
nick.character=character(nauvis,{x=5,y=5})
local players={nick}
for _,pl in ipairs(players) do pl.print=function() end end
game={tick=2000,players=players,forces={player=force,enemy={name='enemy',get_evolution_factor=function() return 0 end,get_evolution_factor_by_time=function() return 0 end,
  get_evolution_factor_by_pollution=function() return 0 end,get_evolution_factor_by_killing_spawners=function() return 0 end}},
  get_player=function(i) if type(i)=='string' then for _,p in ipairs(players) do if p.name==i then return p end end return nil end return players[i] end,
  get_surface=function(n) return surfaces[n] end,print=function() end,connected_players=players,
  get_pollution_statistics=function() return {input_counts={},output_counts={},get_flow_count=function() return 0 end} end}
local runtime=dofile('mod/agent-harness_0.1.0/runtime.lua')
local idx={}
for _,n in ipairs({'sol','astra'}) do runtime.operator.bot_create(n) end
for _,b in ipairs(runtime.bots.list()) do idx[b.name]=b.index end
local S=storage.agent_harness
S.uptime=S.uptime or {}
S.uptime[idx.sol]={start=1900,until_tick=99999,next_tick=99999,samples=1,sampled=1990,machines={}}
S.uptime[idx.astra]={start=1900,until_tick=99999,next_tick=99999,samples=1,sampled=1990,machines={}}
local function call(bot,action,args) return function() return runtime.dispatch{action=action,args=args or {},bot=bot} end end
local function result(fn) local r=fn(); return type(r)=='table' and r.result or r end
local function message(fn) return refused(fn) end
has(message(call('sol','uptime',{read=true,id='uptime@1900'})),'uptime@1900: 2 watches began on tick 1900: uptime@1900/astra (0 machines), uptime@1900/sol (0 machines)')
eq(result(call('sol','uptime',{read=true,agent='astra'})).id,'uptime@1900/astra')
eq(result(call('sol','uptime',{read=true,id='uptime@1900/astra'})).agent,'astra')
local w=result(call('astra','status',{brief=true,work=true})).watches
eq(w[1].id,'uptime@1900/astra')
local function plan(steps) return function() return runtime.dispatch{action='queue_submit',args={dry_run=true,steps=steps},bot='sol'} end end
local function check(fn) local ok,err=pcall(fn); return ok and 'ok' or tostring(err) end
has(check(plan({{action='uptime',args={read=true,agent=7}}})),'steps[1] (uptime): args: agent: an agent\'s name')
has(check(plan({{action='uptime',args={id='uptime@1900/astra'}}})),'id and agent go with read: true')
eq(check(plan({{action='uptime',args={read=true,agent='astra',page=2}}})),'ok')
end
print('d25_batch215 QZ3 runtime and queue checks: ok')
