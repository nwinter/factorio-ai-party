-- Run from the harness root: lua tests/d27_batch297.lua
-- d27 batch297 DR (Astra #2649, tick 74609990: a place_ghosts dry run read ok for a stack-inserter with configure
-- {filters mag, hand_size 16, wait_for_full_hand false}; the real call placed it and refused the whole configure for the
-- wait, and the platform built an unfiltered stack inserter that put rockets into a magazine buffer). An entry's
-- wait_for_full_hand and hand_size are checked before anything is placed, in the dry run and the real call alike, by
-- the functions configure runs; a configure asking for filters refused after placing removes the entity again.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
storage={agent_harness={active={}}}
defines={events={on_script_path_request_finished=10,on_entity_died=11,on_entity_damaged=12,on_console_chat=13,on_unit_group_finished_gathering=14,
  on_built_entity=15,on_player_mined_entity=16,on_robot_mined_entity=17,on_player_fast_transferred=18,on_gui_opened=19,on_gui_closed=20},
  shooting={not_shooting=0,shooting_enemies=1},controllers={character=1,remote=27,spectator=2},direction={north=0},inventory={chest=1},
  build_mode={normal=1},build_check_type={manual=1},flow_precision_index={five_seconds=0,one_minute=1}}
rendering={draw_text=function() return {valid=true,destroy=function() end} end,get_object_by_id=function() return nil end}
remote={interfaces={}}
helpers={json_to_table=function(t) return t end}
local force={name='player',inserter_stack_size_bonus=2,bulk_inserter_capacity_bonus=11,chart=function() end,is_chunk_visible=function() return true end,is_chunk_charted=function() return true end,get_spawn_position=function() return {x=0,y=0} end}
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
local vulcanus=new_surface('vulcanus',2,{planet={name='vulcanus'}})
new_surface('platform-1',3,{platform={name='Peregrine'}})
local nick={index=1,name='nick',valid=true,connected=true,controller_type=1,physical_controller_type=1,cheat_mode=false,driving=false,force=force,surface=nauvis,position={x=5,y=5},chat_color={r=1,g=1,b=1}}
nick.character=character(nauvis,{x=5,y=5})
local director={index=2,name='pog-director',valid=true,connected=true,controller_type=2,physical_controller_type=2,force=force,surface=nauvis,position={x=50,y=50}}
local players={nick,director}
for _,pl in ipairs(players) do pl.print=function() end end
local tick=0
game={tick=0,players=players,forces={player=force,enemy={name='enemy',get_evolution_factor=function() return 0 end,get_evolution_factor_by_time=function() return 0 end,
  get_evolution_factor_by_pollution=function() return 0 end,get_evolution_factor_by_killing_spawners=function() return 0 end}},
  get_player=function(i) assert(type(i)=='string' or i<=65536,'Given player value is too big'); if type(i)=='string' then for _,p in ipairs(players) do if p.name==i then return p end end return nil end return players[i] end,
  get_surface=function(n) return surfaces[n] end,print=function() end,connected_players=players,
  get_pollution_statistics=function() return {input_counts={},output_counts={},get_flow_count=function() return 0 end} end}
local runtime=dofile('mod/agent-harness_0.1.0/runtime.lua')
local function jump(n) tick=tick+n; game.tick=tick end
local function as(name) return function(action,args) return runtime.dispatch{action=action,args=args or {},bot=name} end end
local astra,sol,luna,opus=as('astra'),as('sol'),as('luna'),as('opus')
local function has(s,part) assert(type(s)=="string" and s:find(part,1,true),tostring(s).." lacks "..part) end
local function lacks(s,part) assert(not tostring(s):find(part,1,true),tostring(s).." has "..part) end
local function refused(fn) local ok,err=pcall(fn); assert(not ok,"should be refused"); return tostring(err) end
local function ins(name,own,bulk) return {name=name,type='inserter',inserter_stack_size_bonus=own,bulk=bulk,uses_inserter_stack_size_bonus=true,filter_count=5} end
prototypes={item={['firearm-magazine']={name='firearm-magazine'},rocket={name='rocket'},['stack-inserter']={name='stack-inserter'}},quality={normal={name='normal'}},recipe={},
  entity={['stack-inserter']=ins('stack-inserter',4,true),['bulk-inserter']=ins('bulk-inserter',0,true),['fast-inserter']=ins('fast-inserter',0,false),
    ['wooden-chest']={name='wooden-chest',type='container'}}}
prototypes.item['stack-inserter'].place_result=prototypes.entity['stack-inserter']
local p=game.players[1]
local ghosts={ghosts=true,force=force,platform='Resolute'}
local function entry(name,cfg) return {{name=name,position={x=-19.5,y=-58.5},direction='north',configure=cfg}} end

-- Astra's settings: refused before anything is placed (place_ghosts and its dry run run entryset.check first)
do
  local e=refused(function() runtime.entryset.check(entry('stack-inserter',{filters={'firearm-magazine'},hand_size=16,wait_for_full_hand=false}),ghosts) end)
  has(e,'entry 1 configure: ghost of stack-inserter (-19.5,-58.5) waits for a full hand')
  has(e,'nothing placed')
  -- a bulk inserter does not wait: true refused, false taken
  has(refused(function() runtime.entryset.check(entry('bulk-inserter',{filters={'rocket'},wait_for_full_hand=true}),ghosts) end),'ghost of bulk-inserter (-19.5,-58.5) does not wait for a full hand')
  runtime.entryset.check(entry('bulk-inserter',{filters={'rocket'},wait_for_full_hand=false}),ghosts)
  -- a valid stack inserter: unchanged (its own wait, its hand of 16 = 1 + 4 + the force's 11)
  runtime.entryset.check(entry('stack-inserter',{filters={'firearm-magazine'},hand_size=16,wait_for_full_hand=true}),ghosts)
  runtime.entryset.check(entry('stack-inserter',{filters={'firearm-magazine'},hand_size=16}),ghosts)
  runtime.entryset.check(entry('stack-inserter',{filter='firearm-magazine',hand_size=false}),ghosts)
  -- hand_size above its hand size now: refused before placing (it was refused only after, on the placed entity)
  has(refused(function() runtime.entryset.check(entry('stack-inserter',{filters={'firearm-magazine'},hand_size=17}),ghosts) end),'hand_size (1..16, its hand size now; 0 or false for none) out of range')
  has(refused(function() runtime.entryset.check(entry('fast-inserter',{hand_size=4}),ghosts) end),'hand_size (1..3,')
  has(refused(function() runtime.entryset.check(entry('wooden-chest',{hand_size=2}),ghosts) end),'hand_size applies to inserters (built or ghost); wooden-chest is a container')
  has(refused(function() runtime.entryset.check(entry('stack-inserter',{hand_size=16,recipe='x'}),ghosts) end),'nothing placed')
  -- build (an entity, not a ghost; the entry's item): the same refusal on the entity it builds
  local b=refused(function() runtime.entryset.check({{item='stack-inserter',position={x=1.5,y=1.5},configure={filters={'firearm-magazine'},wait_for_full_hand=false}}},{force=force}) end)
  has(b,'entry 1 configure: stack-inserter (1.5,1.5) waits for a full hand'); lacks(b,'ghost of')
  print('d27_batch297 DR entry configure checked before placing: ok')
end

-- the real call: a configure asking for filters refused after placing removes the entity; one not asking leaves it
do
  local call=runtime.scheduler_api.handlers.configure
  runtime.scheduler_api.handlers.configure=function() error('target must be in a visible chunk (remote view): (400.5,16.5) on nauvis is not visible to our force now',0) end
  local gone={}
  local ghost={valid=true,type='entity-ghost',name='entity-ghost',ghost_name='fast-inserter',position={x=400.5,y=16.5}}
  ghost.destroy=function() ghost.valid=false; gone[#gone+1]='ghost' end
  local built={valid=true,type='inserter',name='stack-inserter',position={x=1.5,y=1.5}}
  local at={}
  nauvis.find_entities_filtered=function(f) local k=f.position and (f.position.x..','..f.position.y) return at[k] or {} end
  at['400.5,16.5']={ghost}
  local rows,line,stats=runtime.entryset.apply(p,{{name='fast-inserter',position={x=400.5,y=16.5},configure={filters={'firearm-magazine'}}},
    {name='fast-inserter',position={x=402.5,y=16.5},configure={spoil_priority='fresh_first'}}},{ghosts=true},{})
  assert(gone[1]=='ghost' and not ghost.valid,'the ghost asking for filters is removed')
  assert(rows[1].removed=='its ghost removed' and rows[1].placed_without==nil,'row 1 removed')
  has(line,'(fast-inserter at (400.5,16.5) asked for filters: its ghost removed)')
  assert(rows[2].removed==nil and rows[2].placed_without[1]=='configure','a configure without filters leaves the ghost, as before')
  has(line,'(fast-inserter at (402.5,16.5) is placed without it)')
  assert(#stats.failed==2)
  -- a hand build: mined back into the inventory
  at['1.5,1.5']={built}
  p.mine_entity=function(e) e.valid=false; return true end
  local batch={rows={},set=0,failed={},wires={}}
  runtime.entryset.built(p,{position={x=1.5,y=1.5},configure={filters={'firearm-magazine'},hand_size=16}},3,batch,'stack-inserter')
  local out=runtime.entryset.built_result(p,batch,{},true)
  assert(not built.valid,'the built stack inserter is mined back')
  has(out.settings_line,'(stack-inserter at (1.5,1.5) asked for filters: mined back into your inventory)')
  assert(out.removed_unfiltered==1)
  has(out.summary,'1 entity removed again (a configure asking for filters refused)')
  runtime.scheduler_api.handlers.configure=call
  print('d27_batch297 DR a refused filter configure leaves no unfiltered entity: ok')
end
