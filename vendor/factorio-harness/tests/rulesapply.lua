-- Run from repository root: lua tests/rulesapply.lua
-- Ground rules where they apply (lessonbook.lua; d20 batch50 E1, viewer Foobator 08:58: rule 8, big mining drills for new
-- outposts; Haiku built an electric-mining-drill a minute into shift46). applies_to on ground_rule_add and ground_rule_edit;
-- a call naming one of those carries the rule in its reply, once per agent and rule per 10 game minutes.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
storage={agent_harness={active={}}}
defines={events={on_script_path_request_finished=10,on_entity_died=11,on_entity_damaged=12,on_console_chat=13,on_unit_group_finished_gathering=14},
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
local names={'astra','sol','luna','opus','kai','grok','mira'}
for _,n in ipairs(names) do runtime.operator.bot_create(n) end
astra('profile',{display_name='Astra',glyph='A',color='#9977ff'})
sol('profile',{display_name='Sol',glyph='S',color='#ffcb45'})
local haiku=as('haiku')
local known={['electric-mining-drill']={name='electric-mining-drill'},['burner-mining-drill']={name='burner-mining-drill'},['big-mining-drill']={name='big-mining-drill'},pumpjack={name='pumpjack'}}
prototypes={entity=known,item=known,recipe=known}
runtime.operator.bot_create('haiku')
local function bot(n) return runtime.bots.record(runtime.bots.index_of(n)) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
local function op(action,args) return runtime.dispatch{action=action,args=args,operator=true} end
local l=astra('lesson_add',{rule='new outposts: big drills',cause='ore patches drained by small drills',fix='big mining drills',item='big-mining-drill',evidence_tick=game.tick}).lesson
local r=astra('ground_rule_add',{text='Use big mining drills by default for new ore outposts. Ordinary drills require a recorded exception and an owned conversion task.',
  lessons={l.id},applies_to={'electric-mining-drill','burner-mining-drill'}})
local id=r.rule.id
eq(r.rules[1]:find('; applies to: electric-mining-drill, burner-mining-drill',1,true)~=nil,true)
local L=runtime.lessonbook
local rule='rule '..id..' (by astra) applies to electric-mining-drill: Use big mining drills by default for new ore outposts. Ordinary drills require a recorded exception and an owned conversion task.'
-- Haiku's dry run at 15:48:39: the rule; the build 24 s later: not again (once per 10 game minutes)
local hi=runtime.bots.index_of('haiku')
eq(L.applies(hi,'build',{item='electric-mining-drill',position={x=23.5,y=-13.5},dry_run=true})[1],rule)
jump(24*60)
eq(L.applies(hi,'build',{item='electric-mining-drill',position={x=23.5,y=-13.5}}),nil)
-- another agent gets it; the argument shapes each action takes
local ai=runtime.bots.index_of('astra')
eq(L.applies(ai,'place_ghosts',{entities={{name='burner-mining-drill',position={x=1,y=1}}}})[1]:find('applies to burner-mining-drill:',1,true)~=nil,true)
local fresh=function() storage.agent_harness.lessonbook.rule_shown={} end
fresh(); eq(#L.applies(ai,'craft',{recipes={{recipe='electric-mining-drill',count=4}}}),1)
fresh(); eq(#L.applies(ai,'requests',{set={['electric-mining-drill']={min=10}}}),1)
fresh(); eq(#L.applies(ai,'configure',{position={x=1,y=1},recipe='electric-mining-drill'}),1)
fresh(); eq(#L.applies(ai,'queue_submit',{steps={{action='build',args={item='electric-mining-drill',position={x=3,y=3}}}}}),1)
fresh(); eq(#L.applies(ai,'blueprint_place',{blueprint='0eNq...',position={x=0,y=0}},{placed={['electric-mining-drill']=8}}),1)
-- (Aurora 09:04) previews and batches: placements, a batch build, a blueprint, a paste preview; each rule once with the count
fresh(); eq(#L.applies(ai,'placements',{name='electric-mining-drill',near={x=0,y=0},radius=12}),1)
fresh(); eq(L.applies(ai,'build',{builds={{item='electric-mining-drill',position={x=1,y=1}},{item='electric-mining-drill',position={x=4,y=1}},
  {item='burner-mining-drill',position={x=7,y=1}},{item='transport-belt',position={x=9,y=1}}},dry_run=true})[1]:match('applies to ([^:]*):'),'electric-mining-drill x2, burner-mining-drill')
fresh(); eq(L.applies(ai,'blueprint_place',{blueprint='0eNq...',position={x=0,y=0},dry_run=true},{counts={['electric-mining-drill']=8,['transport-belt']=40}})[1]:match('applies to ([^:]*):'),'electric-mining-drill x8')
fresh(); eq(L.applies(ai,'paste',{position={x=0,y=0},dry_run=true},{entities={{name='electric-mining-drill'},{name='electric-mining-drill'},{name='pumpjack'}}})[1]:match('applies to ([^:]*):'),'electric-mining-drill x2')
fresh(); eq(L.applies(ai,'build',{item='big-mining-drill',position={x=3,y=3}}),nil) -- not named
fresh(); eq(L.applies(ai,'inspect',{name='electric-mining-drill'}),nil)            -- a read: not an applying action
-- after 10 game minutes, again
jump(36000)
eq(#L.applies(hi,'build',{item='electric-mining-drill',position={x=24,y=-10}}),1)
-- through a real reply: queue_submit's reply carries it
fresh()
local q=haiku('queue_submit',{steps={{action='walk',args={direction='north',ticks=10}},{action='craft',args={recipe='electric-mining-drill',count=1}}}})
eq(q.ground_rules[1]:find('rule '..id..' (by astra) applies to electric-mining-drill: ',1,true),1)
eq(haiku('queue_status',{}).ground_rules,nil)
-- edit: its writer, the operator, or anyone once astra has been quiet 20 min; [] clears
fails(function() haiku('ground_rule_edit',{id=id,applies_to={'pumpjack'}}) end,'only its writer (astra) or the operator changes rule '..id)
local e=astra('ground_rule_edit',{id=id,applies_to='electric-mining-drill'})
eq(e.was,'electric-mining-drill, burner-mining-drill'); eq(#e.rule.applies_to,1)
eq(op('ground_rule_edit',{id=id,applies_to={'electric-mining-drill','pumpjack'}}).rule.applies_to[2],'pumpjack')
jump(20*3600+60)
haiku('status',{brief=true})
eq(haiku('ground_rule_edit',{id=id,applies_to={}}).rule.applies_to,nil)
fails(function() astra('ground_rule_edit',{id=id}) end,'applies_to is required')
fails(function() astra('ground_rule_edit',{id=99,applies_to={}}) end,'no active ground rule #99')
eq(astra('ground_rules',{}).rules[1]:find('applies to',1,true),nil)
print('rulesapply: ok')
