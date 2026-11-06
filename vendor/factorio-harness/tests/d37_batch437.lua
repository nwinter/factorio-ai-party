-- #2915: completed collector tally cross-reads, including a resting owner and a caller measuring now.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
local function refused(fn, text) local ok,err=pcall(fn); assert(not ok,'expected refusal'); has(err,text) end
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
local function call(action,args) local r=runtime.dispatch{action=action,args=args or {},bot='sol'}; return r.result or r end
local function read(args) args.collection=true; return call('platform_supply',args).tally end
local function done(start,finish,caught)
  return {start=start,until_tick=finish,platform='Asterion',next_tick=finish,result={done=true,start_tick=start,end_tick=finish,
    platform='Asterion',caught=caught,line='caught '..caught,collectors={{caught=caught}},by_type={{name='oxide-asteroid-chunk',caught=caught}}}}
end
local caller={start=2000,until_tick=6000,platform='Elsewhere',samples=1,collectors={},mixed={}}
local target=done(1000,1600,91)
S.collector_tally={[idx.sol]=caller,[idx.astra]=target}
-- Actual rest registration, with no live platform available for cross-reads.
runtime.rests.operator.rest{agent='astra',until_clock='18:00',until_s=3600,reason='quota'}
local rest=runtime.rests.get('astra')
local r=read{agent='@PoG-ASTRA'}
eq(r.agent,'astra'); eq(r.id,'collector_tally@1000/astra'); eq(r.start_tick,1000); eq(r.end_tick,1600)
eq(r.platform,'Asterion'); eq(r.caught,91); eq(r.mixed,nil); has(r.line,'ticks 1000-1600')
eq(read{id=r.id}.caught,91); eq(read{id='collector_tally@1000'}.agent,'astra')
eq(read{agent='astra',platform='Asterion'}.caught,91)
eq(target.read_tick,nil); eq(target.id,nil); eq(target.result.agent,nil); eq(caller.call,nil); eq(caller.read_tick,nil)
eq(S.collector_tally[idx.sol],caller); eq(S.collector_tally[idx.astra],target); eq(runtime.rests.get('astra'),rest)
refused(function() read{agent='nobody'} end,'no completed collector_tally of agent nobody')
refused(function() read{id='collector_tally@999/astra'} end,'no completed collector_tally')
refused(function() read{id='collector_tally@1000/astra',agent='sol'} end,'no completed collector_tally')
refused(function() read{agent='astra',platform='Elsewhere'} end,'no completed collector_tally')
refused(function() read{agent='sol'} end,'no completed collector_tally')
for _,args in ipairs{{agent=''},{agent='@pog-'},{agent=3},{id=''},{id='collector_tally@1000/'},{id='uptime@1000/astra'},
  {agent='astra',seconds=10},{agent='astra',reason='replace'},{agent='astra',fuel=true}} do
  local ok=pcall(function() read(args) end); eq(ok,false,'malformed or mutating selector refused')
end
refused(function() call('platform_supply',{agent='astra'}) end,'agent and id go with collection: true')
S.collector_tally[idx.sol]=done(1000,1600,3)
refused(function() read{id='collector_tally@1000'} end,'ambiguous collector_tally')
eq(read{id='collector_tally@1000',agent='astra'}.caught,91)
S.collector_tally[idx.sol]=caller
local function plan(args) return call('queue_submit',{dry_run=true,steps={{action='platform_supply',args=args}}}) end
plan{collection=true,agent='astra'}
refused(function() plan{collection=true,agent='astra',seconds=10} end,'seconds, reason and fuel')
refused(function() plan{collection=true,id='bad'} end,'collector_tally@START_TICK/AGENT')
local desc=call('describe',{}).actions.platform_supply
has(desc.agent,'newest completed'); has(desc.id,'survive rest')
-- Default behavior still marks only the caller's own completed result read.
eq(runtime.collectreach.tally({index=idx.astra},{name='Asterion'}),target.result)
eq(target.read_tick,game.tick); eq(runtime.collectreach.tally({index=idx.sol},{name='Asterion'}),nil)
-- Real start/tick path: a watch completes while resting, survives a new watch and bounded retention.
prototypes={asteroid_chunk={},item={}}
defines.inventory.asteroid_collector_output=1
local col={valid=true,name='asteroid-collector',position={x=0,y=0},direction=0,prototype={collection_box_offset=5},quality={name='normal'},
  filter_slot_count=0,get_inventory=function() return {get_contents=function() return {} end,get_item_count=function() return 0 end} end}
local surface={index=7,find_entities_filtered=function(f) return f.type=='asteroid-collector' and {col} or {} end}
local pl={valid=true,name='Asterion',surface=surface,force=force,speed=0,find_asteroid_chunks_filtered=function() return {} end}
game.surfaces={[7]=surface}; game.tick=3000
local C=runtime.collectreach
C.start({index=idx.astra},pl,10)
local active=S.collector_tally[idx.astra]
eq(#active.kept,1); eq(read{agent='astra'}.caught,91); eq(read{id='collector_tally@1000/astra'}.caught,91)
refused(function() read{id='collector_tally@3000/astra'} end,'no completed collector_tally')
-- Exclude caller's intentionally skeletal running fixture from sampling.
S.collector_tally[idx.sol]=nil
game.tick=3600; C.tick(game.tick)
eq(read{agent='astra'}.start_tick,3000); eq(read{agent='astra'}.end_tick,3600)
eq(runtime.rests.get('astra'),rest); eq(active.read_tick,nil)
for n=1,5 do
  game.tick=4000+n*1000; C.start({index=idx.astra},pl,10)
  game.tick=game.tick+600; C.tick(game.tick)
end
eq(#S.collector_tally[idx.astra].kept,4)
eq(read{agent='astra'}.start_tick,9000)
refused(function() read{id='collector_tally@1000/astra'} end,'no completed collector_tally')
eq(read{id='collector_tally@5000/astra'}.start_tick,5000)
print('d37_batch437 completed collector tally cross-read, rest, retention, ownership and queue validation: ok')
