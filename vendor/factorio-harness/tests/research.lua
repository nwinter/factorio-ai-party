-- Run from repository root: lua tests/research.lua
-- Research news in each agent's team block (once) and in board events, who
-- queued each technology, the research queue's times, and the team plan
-- (board_plan), through the runtime against a fake engine.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
local function has(list,text)
  for _,line in ipairs(list or {}) do if line:find(text,1,true) then return line end end
  return nil
end
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
storage={agent_harness={active={}}}
defines={events={on_script_path_request_finished=10,on_entity_died=11,on_entity_damaged=12,on_console_chat=13,on_unit_group_finished_gathering=14,
    on_research_finished=40,on_research_queued=41},
  shooting={not_shooting=0,shooting_enemies=1},controllers={character=1,remote=27,spectator=2},direction={north=0},inventory={chest=1},
  build_mode={normal=1},build_check_type={manual=1},flow_precision_index={five_seconds=0,one_minute=1,ten_minutes=2}}
local drawn={}
rendering={draw_text=function(t) local obj={id=#drawn+1,valid=true}; obj.destroy=function() obj.valid=false end; drawn[#drawn+1]=obj; return obj end,
  get_object_by_id=function(id) return drawn[id] end}
remote={interfaces={}}
helpers={json_to_table=function(t) return t end}
-- Science packs made per name in the last 10 minutes (category input).
local made={['automation-science-pack']=300,['logistic-science-pack']=200}
local stats={get_flow_count=function(a) assert(a.category=='input' and a.count==true); return made[a.name] or 0 end}
local force={name='player',chart=function() end,is_chunk_visible=function() return true end,is_chunk_charted=function() return true end,
  get_spawn_position=function() return {x=0,y=0} end,get_item_production_statistics=function() return stats end}
local surface={name='nauvis',index=1}
local red,green,blue={name='automation-science-pack',amount=1},{name='logistic-science-pack',amount=1},{name='chemical-science-pack',amount=1}
local function tech(name,count,energy,ingredients,effects)
  return {name=name,valid=true,force=force,enabled=true,researched=false,prerequisites={},research_unit_count=count,research_unit_energy=energy,
    research_unit_ingredients=ingredients,saved_progress=0,prototype={effects=effects or {}}}
end
local techs={
  ['logistic-robotics']=tech('logistic-robotics',300,1800,{red,green},{{type='unlock-recipe',recipe='roboport'},
    {type='unlock-recipe',recipe='logistic-robot'},{type='unlock-recipe',recipe='storage-chest'}}),
  ['mining-productivity-1']=tech('mining-productivity-1',250,3600,{red,green},{{type='mining-drill-productivity-bonus',modifier=0.1}}),
  ['steel-axe']=tech('steel-axe',50,1800,{red},{{type='character-mining-speed',modifier=1}}),
  ['oil-processing']=tech('oil-processing',100,1800,{red,green},{{type='unlock-recipe',recipe='pumpjack'},{type='unlock-recipe',recipe='oil-refinery'}}),
  ['sulfur-processing']=tech('sulfur-processing',150,1800,{red,green,blue},{{type='unlock-recipe',recipe='sulfur'}}),
  ['planet-discovery-vulcanus']=tech('planet-discovery-vulcanus',1000,3600,{red,green},{{type='unlock-space-location',space_location='vulcanus'},
    {type='unlock-recipe',recipe='a'},{type='unlock-recipe',recipe='b'},{type='unlock-recipe',recipe='c'},{type='unlock-recipe',recipe='d'},
    {type='unlock-recipe',recipe='e'},{type='unlock-recipe',recipe='f'},{type='unlock-recipe',recipe='g'},{type='unlock-recipe',recipe='h'}}),
}
force.technologies=techs
force.research_progress=0
-- As the engine: the queue takes names or technologies and reads back technologies; its head is the current research.
local queue={}
setmetatable(force,{__index=function(_,k) if k=='research_queue' then return queue end end,
  __newindex=function(t,k,v)
    if k~='research_queue' then return rawset(t,k,v) end
    queue={}
    for i,x in ipairs(v) do queue[i]=type(x)=='string' and techs[x] or x end
    rawset(t,'current_research',queue[1])
  end})
force.add_research=function(t)
  for _,x in ipairs(queue) do if x==t then return false end end
  queue[#queue+1]=t; rawset(force,'current_research',queue[1]); return true
end
local units=0
local function character(pos)
  local items={}
  units=units+1
  local c={valid=true,name='character',type='character',force=force,surface=surface,position=pos,unit_number=500+units,health=250,
    driving=false,build_distance=10,reach_distance=10,character_running_speed=0.15,walking_state={walking=false}}
  local inv={get_item_count=function(q) return items[type(q)=='table' and q.name or q] or 0 end,find_item_stack=function() return nil end,
    get_contents=function() return {} end}
  c.items=items
  c.insert=function(s) items[s.name]=(items[s.name] or 0)+s.count; return s.count end
  c.get_main_inventory=function() return inv end
  c.get_item_count=function(n) return items[n] or 0 end
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
local nick={index=1,name='nick',valid=true,connected=true,controller_type=1,physical_controller_type=1,cheat_mode=false,driving=false,force=force,surface=surface,position={x=5,y=5},chat_color={r=1,g=1,b=1}}
nick.character=character({x=5,y=5})
local director={index=2,name='pog-director',valid=true,connected=true,controller_type=2,physical_controller_type=2,force=force,surface=surface,position={x=50,y=50}}
local players={nick,director}
for _,pl in ipairs(players) do pl.print=function() end end
local tick=0
game={tick=0,players=players,surfaces={nauvis=surface},forces={player=force,enemy={name='enemy',get_evolution_factor=function() return 0 end,get_evolution_factor_by_time=function() return 0 end,
  get_evolution_factor_by_pollution=function() return 0 end,get_evolution_factor_by_killing_spawners=function() return 0 end}},
  get_player=function(i) assert(type(i)=='string' or i<=65536,'Given player value is too big'); if type(i)=='string' then for _,p in ipairs(players) do if p.name==i then return p end end return nil end return players[i] end,
  get_surface=function() return surface end,print=function() end,connected_players=players,
  get_pollution_statistics=function() return {input_counts={},output_counts={},get_flow_count=function() return 0 end} end}
local runtime=dofile('mod/agent-harness_0.1.0/runtime.lua')
local function advance(n) for _=1,n do tick=tick+1; game.tick=tick; runtime.tick{tick=tick} end end
local function jump(n) tick=tick+n; game.tick=tick end
local function request(req)
  local ok,result=pcall(runtime.dispatch,req)
  if not ok then
    local who=req.player or (req.bot==nil and 1 or nil)
    if req.bot then who=runtime.bots.index_of(req.bot) end
    if type(who)=='number' then pcall(runtime.stop_player,who) end
    error(result,0)
  end
  return result
end
local function as(name) return function(action,args) return request{action=action,args=args or {},bot=name} end end
local astra,sol=as('astra'),as('sol')
local function op(action,args) return request{action=action,args=args or {},operator=true} end
runtime.operator.bot_create('astra'); runtime.operator.bot_create('sol')
astra('profile',{display_name='Astra',glyph='A',color='#9977ff'})
sol('profile',{display_name='Sunny',glyph='S',color='#ffcb45'})
local function finish(name,by_script)
  local t=techs[name]
  t.researched=true
  for k,q in ipairs(force.research_queue) do if q==t then table.remove(force.research_queue,k); break end end
  force.current_research=force.research_queue[1]; force.research_progress=0
  runtime.on_event{name=defines.events.on_research_finished,tick=game.tick,research=t,by_script=by_script}
end
local function team(r) return r.team and r.team.research end

-- Who queued what: the acting agent through research; the player through the game's own queue.
astra('research',{technology='logistic-robotics'})
sol('research',{research_queue={'oil-processing'},append=true})
runtime.on_event{name=defines.events.on_research_queued,tick=game.tick,research=techs['steel-axe'],force=force,player_index=1}
force.research_queue[#force.research_queue+1]=techs['steel-axe']
-- A queueing by script names nobody and changes nothing.
runtime.on_event{name=defines.events.on_research_queued,tick=game.tick,research=techs['oil-processing'],force=force}
local q=astra('research')
eq(q.current,'logistic-robotics')
eq(q.entries[1].name,'logistic-robotics'); eq(q.entries[1].queued_by,'astra')
eq(q.entries[2].name,'oil-processing'); eq(q.entries[2].queued_by,'sol')
eq(q.entries[3].name,'steel-axe'); eq(q.entries[3].queued_by,'nick')
eq(q.entries[1].packs,'automation-science-pack+logistic-science-pack')
-- No throughput yet: no times, and it says why.
eq(q.entries[1].done_in,nil); assert(q.throughput:find('not measured yet',1,true),q.throughput)
-- Re-queueing something already queued does not change who queued it.
sol('research',{technology='logistic-robotics'})
eq(astra('research').entries[1].queued_by,'astra')

-- Throughput: progress over the last samples (every 10 s). logistic-robotics: 300 units x 1800 = 540000 work.
-- 10% per 60 s -> 54000 work per 3600 ticks = 15 per tick.
force.current_research=techs['logistic-robotics']
for k=0,6 do force.research_progress=0.1*k/6; advance(600) end
q=astra('research')
assert(q.throughput:find('measured over the last 1m00s',1,true),q.throughput)
-- 90% left: 486000 / 15 = 32400 ticks = 9 min; then oil-processing 180000 / 15 = 12000 ticks -> 12m20s total.
eq(q.entries[1].done_in,'9m00s'); eq(q.entries[1].progress,10)
eq(q.entries[2].done_in,'12m20s')
-- Saved progress counts for an entry that is not running.
techs['oil-processing'].saved_progress=0.5
eq(astra('research').entries[2].done_in,'10m40s')
-- An entry that needs a pack the current research does not use, and that nobody made in 10 minutes, stops the clock.
force.research_queue[#force.research_queue+1]=techs['sulfur-processing']
q=astra('research')
eq(q.entries[4].waits_for,'chemical-science-pack (none made in 10 min)'); eq(q.entries[4].done_in,nil)
eq(q.clock_stops_at,'sulfur-processing')
made['chemical-science-pack']=40
q=astra('research'); eq(q.entries[4].waits_for,nil); eq(q.clock_stops_at,nil); assert(q.entries[4].done_in)
table.remove(force.research_queue)

-- A first reply looks back ten minutes; nothing finished yet, so no research lines.
eq(team(astra('status')),nil); eq(team(sol('status')),nil)
-- A technology finishes: each agent's next reply carries it once.
jump(180*60)
finish('logistic-robotics')
jump(185*60-180*60)
local line=has(team(astra('status')),'research done: logistic-robotics')
eq(line,'research done: logistic-robotics, unlocks: roboport, logistic-robot, storage-chest (5s ago)')
eq(team(astra('status')),nil)
assert(has(team(sol('chat',{})),'research done: logistic-robotics'))
eq(team(sol('status')),nil)
-- Directors get no team block.
eq(request{action='status',args={},player=2}.team,nil)
-- It is a board event too (by research, no item), and nobody gets it as a board line.
local ev=astra('board_events',{}).events
local last=ev[#ev]
eq(last.by,'research'); eq(last.kind,'research'); eq(last.title,'logistic-robotics'); eq(last.change,'done'); eq(last.id,nil)
eq(last.text,'unlocks: roboport, logistic-robot, storage-chest')
-- research_done lists what finished, newest first, with who queued it.
local done=sol('research_done').done
eq(done[1].name,'logistic-robotics'); eq(done[1].queued_by,'astra'); eq(done[1].unlocks[2],'logistic-robot')
-- Modifiers and space locations read as effects; long lists are cut.
finish('mining-productivity-1')
finish('planet-discovery-vulcanus')
local lines=team(astra('status'))
assert(has(lines,'research done: mining-productivity-1, unlocks: mining-drill-productivity-bonus +10%'),table.concat(lines,'\n'))
assert(has(lines,'research done: planet-discovery-vulcanus, unlocks: travel to vulcanus, a, b, c, d, e, f, g, +1 more'),table.concat(lines,'\n'))
-- More than four at once: the rest are counted.
for k=1,5 do
  local name='automation-'..k
  techs[name]=tech(name,10,60,{red})
  finish(name)
end
lines=team(sol('status'))
eq(#lines,5); eq(lines[5],'+3 more finished: research_done')
-- A new agent's first reply looks back ten minutes only.
runtime.operator.bot_create('luna')
jump(11*60*60)
eq(team(request{action='status',args={},bot='luna'}),nil)
finish('steel-axe',true)
assert(has(team(request{action='status',args={},bot='luna'}),'research done: steel-axe, unlocks: character-mining-speed +1'))
-- A fault in the research news never stops the runtime: it is counted.
runtime.on_event{name=defines.events.on_research_finished,tick=game.tick,research={valid=true,name='broken'}}
eq(storage.agent_harness.research_errors.count,1)
eq(storage.agent_harness.runtime_fault,nil)

-- The team plan: one item, goals plus a line per agent.
local r=astra('board_plan')
eq(r.plan,false); assert(r.note:find('board_plan {goals}',1,true))
r=astra('board_plan',{goals='Robots by hour 3; oil next'})
eq(r.plan.goals,'Robots by hour 3; oil next'); eq(r.changed,true)
r=sol('board_plan',{doing='oil: pumpjacks at the north field'})
eq(r.plan.doing[1],'sol: oil: pumpjacks at the north field')
r=sol('board_plan',{agent='Astra',doing='roboports along the bus'})
eq(r.plan.doing[2],'astra: roboports along the bus (set by sol)')
assert(r.plan.edited:find('by sol',1,true))
-- Each agent hears of an edit once, in its team block; a line written for me is mine.
local seen=astra('status').team.board
assert(has(seen,'team plan edited by sol: astra: roboports along the bus'),table.concat(seen or {},'\n'))
assert(has(seen,'team plan edited by sol: sol: oil: pumpjacks'),table.concat(seen or {},'\n'))
seen=astra('status').team
assert(not (seen and has(seen.board,'team plan edited')))
-- My own edits are not news to me.
seen=sol('status').team
assert(not (seen and has(seen.board,'team plan edited by sol')))
-- The plan shows on the board read, not as a row; a filtered read for mine leaves it out.
local b=astra('board')
eq(b.plan.goals,'Robots by hour 3; oil next'); eq(#b.plan.doing,2)
for _,i in ipairs(b.items) do assert(i.kind~='plan') end
eq(astra('board',{mine=true}).plan,nil)
eq(astra('board',{kind='plan'}).plan.id,b.plan.id)
-- Clearing: "" removes a line or the goals.
r=sol('board_plan',{doing=''})
eq(#r.plan.doing,1); eq(r.plan.doing[1],'astra: roboports along the bus (set by sol)')
r=sol('board_plan',{goals=''})
eq(r.plan.goals,nil)
eq(sol('board_plan',{goals=''}).changed,false)
-- One plan: never posted, no status or owner changes, notes fine.
fails(function() sol('board_post',{kind='plan',title='x'}) end,'the team plan is one item')
fails(function() sol('board_update',{id=b.plan.id,status='done'}) end,'the team plan changes with board_plan')
sol('board_update',{id=b.plan.id,note='see notes.md'})
fails(function() sol('board_plan',{agent='astra'}) end,'agent goes with doing')
fails(function() sol('board_plan',{agent='nobody',doing='x'}) end,'unknown agent nobody')
fails(function() sol('board_plan',{goals=5}) end,'goals must be a string')
r=sol('board_plan',{goals=string.rep('g',700)}); eq(#r.plan.goals,600)
-- The operator reads and edits it too, and has no line of its own.
eq(op('board_plan',{}).plan.goals,string.rep('g',600))
fails(function() op('board_plan',{doing='x'}) end,'the operator has no line')
op('board_plan',{agent='luna',doing='scout south'})
-- The board event of an edit carries the plan kind for the stream.
ev=astra('board_events',{}).events
eq(ev[#ev].kind,'plan'); eq(ev[#ev].change,'edited'); eq(ev[#ev].owner,'luna')
-- describe lists the new actions.
local d=runtime.dispatch{action='describe'}
assert(d.actions.board_plan and d.actions.research_done)
assert(d.actions.research.technology:find('queued_by',1,true))
-- The plan survives pruning.
for i=1,310 do sol('board_post',{kind='task',title='t'..i,owner='sol'}) end
eq(storage.agent_harness.board.count,300)
eq(astra('board').plan.goals,string.rep('g',600))

-- Without on_research_finished (a runtime deployed before the server restarts with the new control.lua), the 10 s
-- sample announces a technology that left the head of the queue researched, once; a levelled one by its level.
local function polled(name) local n=0; for _,e in ipairs(storage.agent_harness.research_news.list) do if e.name==name then n=n+1 end end return n end
techs['electric-energy-accumulators']=tech('electric-energy-accumulators',150,1800,{red,green},{{type='unlock-recipe',recipe='accumulator'}})
force.research_queue={'electric-energy-accumulators'}
advance(600)
techs['electric-energy-accumulators'].researched=true
force.research_queue={}
eq(polled('electric-energy-accumulators'),0)
advance(600)
eq(polled('electric-energy-accumulators'),1)
local news=storage.agent_harness.research_news.list
eq(news[#news].polled,true)
assert(has(team(sol('status')),'research done: electric-energy-accumulators, unlocks: accumulator'))
advance(1200); eq(polled('electric-energy-accumulators'),1)
-- With the event, the sample adds nothing.
techs['defender']=tech('defender',100,1800,{red,green},{{type='unlock-recipe',recipe='defender-capsule'}})
force.research_queue={'defender'}
advance(600)
finish('defender')
advance(1200)
eq(polled('defender'),1); eq(news[#news].polled,nil)
-- A levelled technology: the same name at the head, one level up.
techs['mining-productivity-3']=tech('mining-productivity-3',500,3600,{red,green},{{type='mining-drill-productivity-bonus',modifier=0.1}})
techs['mining-productivity-3'].level=3
force.research_queue={'mining-productivity-3'}
advance(600)
techs['mining-productivity-3'].level=4
advance(600)
eq(polled('mining-productivity-3'),1)
-- A technology dropped from the queue unresearched is not announced.
techs['automobilism']=tech('automobilism',100,1800,{red,green})
force.research_queue={'automobilism'}
advance(600)
force.research_queue={}
advance(600)
eq(polled('automobilism'),0)

-- Shifts: shift_start (start-team, a resumed world); each agent's first reply of the shift carries a shift block once.
prototypes={entity={roboport={},['solar-panel']={},accumulator={},['requester-chest']={},['buffer-chest']={},pumpjack={},['oil-refinery']={}}}
local built={['solar-panel']=12,pumpjack=3}
surface.count_entities_filtered=function(a) assert(a.force==force and a.limit==1); return math.min(built[a.name] or 0,1) end
techs['construction-robotics']=tech('construction-robotics',100,1800,{red,green})
techs['construction-robotics'].researched=true
techs['solar-energy']=tech('solar-energy',100,1800,{red,green}); techs['solar-energy'].researched=true
techs['logistic-system']=tech('logistic-system',100,1800,{red,green})
techs['oil-processing'].researched=true
-- No shift yet (a fresh world): no block.
eq((astra('status').team or {}).shift,nil)
local astra_last=game.tick
jump(3600)
-- Research done while astra was away (the board plan has goals and astra's line, set earlier).
techs['steel-axe'].researched=false
finish('steel-axe')
jump(60)
local started=runtime.operator.shift_start()
eq(started.shift,1)
jump(120)
local shift=astra('board',{kind='claim'}).team.shift
eq(shift.shift,'shift 1, started 2s ago')
eq(shift.plan_goals,string.rep('g',600))
eq(shift.your_plan_line,'roboports along the bus')
-- steel-axe from the research news; the three set researched above with no event come from the snapshot taken at
-- the runtime's first sample (the news first, then the snapshot's extras by name).
eq(shift.research_since_your_last_shift,'steel-axe, construction-robotics, oil-processing, solar-energy')
-- logistic-robotics and construction-robotics share roboports; solar panels and pumpjacks are built; logistic-system
-- is not researched; accumulators were researched above and none is built.
eq(shift.researched_none_built,'roboports (logistic-robotics, construction-robotics); accumulators (electric-energy-accumulators)')
-- Once per shift; peeks and directors get none and leave it for later.
eq((astra('status').team or {}).shift,nil)
eq((request{action='status',args={},player=2}.team or {}).shift,nil)
eq((request{action='chat',args={peek=true},bot='sol'}.team or {}).shift,nil)
local sol_shift=sol('status').team.shift
-- sol's last request came before defender and mining-productivity-3 finished too.
assert(sol_shift and sol_shift.your_plan_line==nil and sol_shift.research_since_your_last_shift=='defender, mining-productivity-3, steel-axe, construction-robotics, oil-processing, solar-energy',
  sol_shift and sol_shift.research_since_your_last_shift)
-- Built since: gone from the list. The next shift counts research from each agent's last request.
built.roboport=1
runtime.operator.shift_start()
shift=astra('status').team.shift
eq(shift.shift,'shift 2, started 0s ago'); eq(shift.research_since_your_last_shift,nil)
eq(shift.researched_none_built,'accumulators (electric-energy-accumulators)')
-- No events needed: shift_start snapshots force.technologies, so a technology researched with no event and never at
-- the head of the queue (a server whose control.lua predates the research events) still shows; one the agent was
-- told about in a reply before the shift does not repeat.
finish('logistic-system')
assert(has(team(astra('status')),'research done: logistic-system'))
techs['railway']=tech('railway',75,1800,{red,green}); techs['railway'].researched=true
jump(60)
runtime.operator.shift_start()
shift=astra('status').team.shift
eq(shift.shift,'shift 3, started 0s ago')
eq(shift.research_since_your_last_shift,'railway')
-- The first sample of a freshly deployed runtime takes a base snapshot too.
local snaps=storage.agent_harness.research_snaps.player
eq(#snaps,4) -- the first sample's, then shifts 1, 2 and 3
-- The number is the one start-team passes (the resumed-from chain, as the stream hosts count); without one, one more.
eq(runtime.operator.shift_start(9).shift,9)
eq(astra('status').team.shift.shift,'shift 9, started 0s ago')
eq(runtime.operator.shift_start().shift,10)
eq(runtime.operator.shift_start('x').shift,11)
-- A start that repeats a number still gives each agent the block once.
runtime.operator.shift_start(11)
eq(astra('status').team.shift.shift,'shift 11, started 0s ago')
-- A fault in the shift block never fails the reply: it is counted.
local errors=(storage.agent_harness.research_errors or {}).count or 0
runtime.operator.shift_start()
local saved=surface.count_entities_filtered
surface.count_entities_filtered=function() error('engine hiccup') end
local reply=astra('status')
eq((reply.team or {}).shift,nil); eq(storage.agent_harness.research_errors.count,errors+1)
surface.count_entities_filtered=saved
print('research: ok')
