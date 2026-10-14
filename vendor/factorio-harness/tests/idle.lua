-- Run from repository root: lua tests/idle.lua
-- The operator's idle report and tell (idle.lua, tells.lua): how long each character has stood, what it runs and
-- what waits unread for it; a fact-only tell from the operator that wakes a sleeper. Fake engine as tests/tells.lua.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
local function has(list,text)
  for _,line in ipairs(list or {}) do if line:find(text,1,true) then return line end end
  return nil
end
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
storage={agent_harness={active={}}}
defines={events={on_script_path_request_finished=10,on_entity_died=11,on_entity_damaged=12,on_console_chat=13,on_unit_group_finished_gathering=14},
  shooting={not_shooting=0,shooting_enemies=1},controllers={character=1,remote=27,spectator=2},direction={north=0},inventory={chest=1},
  build_mode={normal=1},build_check_type={manual=1},flow_precision_index={five_seconds=0,one_minute=1}}
local drawn={}
rendering={draw_text=function(t) local obj={id=#drawn+1,valid=true}; obj.destroy=function() obj.valid=false end; drawn[#drawn+1]=obj; return obj end,
  get_object_by_id=function(id) return drawn[id] end}
remote={interfaces={}}
helpers={json_to_table=function(t) return t end}
local force={name='player',chart=function() end,is_chunk_visible=function() return true end,is_chunk_charted=function() return true end,get_spawn_position=function() return {x=0,y=0} end}
local surface={name='nauvis',index=1}
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
game={tick=0,players=players,forces={player=force,enemy={name='enemy',get_evolution_factor=function() return 0 end,get_evolution_factor_by_time=function() return 0 end,
  get_evolution_factor_by_pollution=function() return 0 end,get_evolution_factor_by_killing_spawners=function() return 0 end}},
  get_player=function(i) assert(type(i)=='string' or i<=65536,'Given player value is too big'); if type(i)=='string' then for _,p in ipairs(players) do if p.name==i then return p end end return nil end return players[i] end,
  get_surface=function() return surface end,print=function() end,connected_players=players,
  get_pollution_statistics=function() return {input_counts={},output_counts={},get_flow_count=function() return 0 end} end}
local runtime=dofile('mod/agent-harness_0.1.0/runtime.lua')
local function advance(n) for _=1,n do tick=tick+1; game.tick=tick; runtime.tick{tick=tick} end end
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
local astra,sol,grok=as('astra'),as('sol'),as('grok')
local function op(action,args) return request{action=action,args=args or {},operator=true} end
runtime.operator.bot_create('astra'); runtime.operator.bot_create('sol'); runtime.operator.bot_create('grok')

local function report(name)
  for _,row in ipairs(op('idle_report',{}).agents) do if row.name==name then return row end end
end
astra('status'); sol('status')
advance(60*61)
local a=report('astra')
assert(a.standing_s>=59 and a.standing_s<=61,a.standing_s); eq(a.alive,true); eq(a.action,nil); eq(a.queue.state,'none')
eq(a.unread_chat,0); eq(a.unread_tells,0); eq(a.sleeping_s,nil)
eq(report('grok').standing_s,0) -- no request yet: no clock, not counted
-- work under 20 s does not end standing (a 100-tick walk); work that lasts does, and standing starts again after it
astra('walk',{direction='east',ticks=100}); advance(61)
a=report('astra'); assert(a.standing_s>=60,a.standing_s); eq(a.action,'walk') -- (61 s before it, still counted)
local ai=runtime.bots.index_of('astra')
advance(60)
storage.agent_harness.active[ai]={kind='walk',direction=0,until_tick=tick+60*30}; advance(60*25)
eq(report('astra').standing_s,0); eq(report('astra').action,'walk')
storage.agent_harness.active[ai]=nil; advance(60*3)
a=report('astra'); assert(a.standing_s>=1 and a.standing_s<=3,a.standing_s); eq(a.action,nil)
-- a wait is not work (shift07: Sonnet's back-to-back wait_ticks for 70 minutes, never nudged): standing goes on
-- (advance counts ticks: 60*12 is 12 s)
astra('wait_ticks',{ticks=54000}); advance(60*12)
a=report('astra'); assert(a.standing_s>=14,a.standing_s); eq(a.action,'wait_ticks'); assert(a.action_until_s>800,a.action_until_s)
astra('stop'); advance(60)
-- nor a queue held behind a direct wait (a plan runs after a direct command ends: Sonnet's loop3), nor a one-off
-- queue wait; a repeating plan resting between its cycles is work
local q={pending={{action='move_to',args={position={x=9,y=9}}}},history={},revision=1,paused=false}
storage.agent_harness.queues=storage.agent_harness.queues or {}
storage.agent_harness.queues[ai]=q
storage.agent_harness.active[ai]={kind='wait_ticks',until_tick=tick+60*600}; advance(60*25)
a=report('astra'); assert(a.standing_s>=25,a.standing_s); eq(a.queue.state,'running')
storage.agent_harness.active[ai]=nil; q.pending={}
q.current={action='wait_ticks',args={ticks=9000},until_tick=tick+9000}; advance(60*25)
assert(report('astra').standing_s>=50,'a one-off queue wait is not work')
q.current=nil; q.loop={{action='mine',args={}}}; q.interval=60*600; advance(60*25)
eq(report('astra').standing_s,0,'a repeating plan resting between cycles is work')
storage.agent_harness.queues[ai]=nil; advance(60)
-- a sleep with nothing running is standing (shift05: Sonnet's 25-minute sleeps), and the report shows the sleep
astra('sleep',{seconds=900}); advance(60*30)
a=report('astra'); assert(a.standing_s>=29,a.standing_s); assert(a.sleeping_s>=29 and a.sleep_left_s>800,a.sleep_left_s)
-- unread for it: chat, mentions, tells
sol('say',{text='@astra the copper line is down'})
grok('tell',{to='astra',text='need 40 plates'})
a=report('astra'); eq(a.unread_chat,1); eq(a.unread_tells,1); eq(a.unread_mentions,2)
-- the operator's tell: in the next reply's team tells, never in the game chat
local seq0=sol('chat',{since=0}).cursor
local r=op('tell',{to='astra',text='Operator: your character has stood idle for 30 min.'})
assert(r.seq>0); eq(r.to[1],'astra')
local t=astra('status').team.tells
assert(has(t,'operator, 0s ago: Operator: your character has stood idle for 30 min.'),t and t[1])
eq(#sol('chat',{since=seq0}).messages,0) -- not in the game chat
fails(function() op('tell',{to='nobody',text='x'}) end,'unknown agent nobody')
fails(function() op('tell',{to='astra',text=' '}) end,'text is required')
-- a sleeper woken by the operator's tell alone
sol('sleep',{seconds=600}); advance(60)
eq(sol('sleep_check',{peek=true}).woke,nil)
op('tell',{to='sol',text='facts'})
eq(sol('sleep_check',{peek=true}).woke,'told')
-- the operator reads every tell, its own included
local all=op('tells',{})
eq(all.tells[#all.tells].from,'operator')
-- no body (dead, or a bot in a cargo pod): not standing
grok('status'); advance(180); assert(report('grok').standing_s>=1)
runtime.bots.lookup(runtime.bots.index_of('grok')).character.valid=false; advance(60)
eq(report('grok').standing_s,0); eq(report('grok').alive,false)

-- Agent-minds study fixes (eng/minds-waits).
local si=runtime.bots.index_of('sol')
local S=storage.agent_harness
local sc=runtime.bots.lookup(si).character
prototypes={item={coal={name='coal'}}}
sol('status'); advance(60)
-- Fix 2: one definition of idle. The clock line counts a wait as idle, named apart (shift07: Sonnet and Haiku read
-- "character idle 0s of it (0%)" after every wait for an hour).
sol('wait_ticks',{ticks=600}); advance(60*5)
local clock=sol('status').clock
assert(clock:find('+5s since your last request, character idle 5s of it (100%, 5s of that in wait_ticks)',1,true),clock)
-- Fix 5: a tell or mention ends a direct wait (told|mentioned, with who); the wait reply's team block has it.
astra('tell',{to='sol',text='coal please'}); advance(31)
eq(S.active[si],nil,'the tell ended the wait'); eq(S.last[si].outcome,'told'); eq(S.last[si].why,'told by astra')
sol('wait_until',{['until']='item_count',item='coal',at_least=5,timeout=3600}); advance(60)
eq(S.active[si].kind,'wait_until')
astra('say',{text='@sol where is the coal'}); advance(31)
eq(S.last[si].outcome,'mentioned'); eq(S.last[si].why,'mentioned by astra')
-- a pending tell from before the wait does not end it
astra('tell',{to='sol',text='old news'}); sol('wait_ticks',{ticks=600}); advance(60*3)
eq(S.active[si].kind,'wait_ticks'); sol('stop'); sol('status')
-- a peek poll (fh --wait) learns that one arrived: inbox_tick
eq(sol('status',{peek=true}).inbox,nil)
astra('tell',{to='sol',text='more coal'})
local ib=sol('status',{peek=true}).inbox; eq(ib.tick,tick); eq(ib.woke,'told'); eq(ib.from,'astra')
-- an fyi tell (eng/minds-claims, tell --fyi) wakes nobody: it ends no wait
table.insert(S.mentions[si].list,{tell=999,tick=tick+1,from='grok',text='fyi',how='tell',fyi=true}); advance(1)
eq(sol('status',{peek=true}).inbox.tick,tick-1,'the fyi tell is skipped')
sol('status')
-- Fix 7: a direct wait refuses while the queue runs (Sonnet's "queue resume, wait_ticks 20000": 22 queued walks
-- interrupted, 0 jobs done); pause_queue=true pauses it as before; a paused queue is no reason to refuse.
local sq={pending={{action='move_to',args={position={x=9,y=9}}}},history={},revision=1,paused=false}
S.queues[si]=sq
fails(function() sol('wait_ticks',{ticks=600}) end,'wait_ticks would pause your queue (1 step): a direct wait stops the character')
fails(function() sol('wait_until',{['until']='crafting_done'}) end,'Use fh sleep SECONDS')
eq(sq.paused,false,'the refused wait left the queue running')
sq.order={name='refuel'}; sol('wait_ticks',{ticks=60}); eq(sq.paused,true,'a standing order is preempted, as by any own request')
sol('stop'); sq.order=nil; sq.paused=false
sol('wait_ticks',{ticks=60,pause_queue=true}); eq(sq.paused,true); eq(S.active[si].kind,'wait_ticks')
sol('stop'); sol('wait_until',{['until']='item_count',item='coal',at_least=0,pause_queue=true})  -- met at once; the condition takes no pause_queue
sol('wait_ticks',{ticks=60}); sol('stop'); S.queues[si]=nil
-- Fix 1: an operator tell rides on every reply (peeks, reads, waits) until the agent's next game action or message.
op('tell',{to='sol',text='your character has stood idle for 12 min'})
local o=sol('status',{peek=true}).operator
eq(#o,1); eq(o[1].text,'your character has stood idle for 12 min'); eq(o[1].ago_s,0)
eq(sol('status').operator[1].text,'your character has stood idle for 12 min','a read shows it again')
eq(sol('sleep',{seconds=5}).operator[1].ago_s,0,'a sleep shows it again')
eq(sol('sleep_check',{}).operator[1].ago_s,0)
eq(sol('chat',{since=0}).operator[1].ago_s,0,'a chat read shows it again')
eq(sol('wait_ticks',{ticks=60}).operator ~= nil,true,'a wait shows it again')
eq(sol('say',{text='on it'}).operator[1].text,'your character has stood idle for 12 min','the message shows it, once more')
eq(sol('status').operator,nil,'then it is gone')
op('tell',{to='sol',text='second'}); eq(sol('stop').operator[1].text,'second'); eq(sol('status').operator,nil,'a game action ends it too')
eq(astra('status').operator,nil,'only its own agent sees it')
-- Fix 2: standing ends on a game action that changed something, on a move to a new spot, on 20 s of work summed
-- over 2 minutes; not on reads, messages, waits or a game action that did nothing (Haiku's 35 empty feeds).
advance(60*30); assert(report('sol').standing_s>=29)
runtime.idle.request(si,'feed',{},{outcome='nothing_to_do',given=0}); advance(60)
runtime.idle.request(si,'transfer',{},{transferred=0}); advance(60)
assert(report('sol').standing_s>=31,'no effect, no end')
runtime.idle.request(si,'transfer',{},{transferred=40}); advance(60)
local row=report('sol'); assert(row.standing_s<=1,row.standing_s); eq(row.stand_ended.why,'transfer')
advance(60*20)
S.active[si]={kind='walk',direction=0,until_tick=tick+600}; advance(60*4)
sc.position={x=sc.position.x+6,y=sc.position.y}; S.active[si]=nil; advance(60*2)
row=report('sol'); assert(row.standing_s<=2,row.standing_s); eq(row.stand_ended.why,'moved')
advance(60*20)
S.active[si]={kind='walk',direction=0,until_tick=tick+600}; advance(60*4); S.active[si]=nil; advance(60)
assert(report('sol').standing_s>=24,'a walk that went nowhere is no move')
for _=1,4 do  -- 4 walks of 6 s in 2 minutes: 24 s of work
  S.active[si]={kind='walk',direction=0,until_tick=tick+60*6}; advance(60*6); S.active[si]=nil; advance(60*10)
end
row=report('sol'); assert(row.standing_s<=11,row.standing_s); eq(row.stand_ended.why,'worked')
-- What was counted, for the nudge's text: actions, reads, messages, sleeps and waits by kind, the shares of time.
local c=row.counted
eq(c.minutes,10); eq(c.actions,1); eq(c.no_effect,2); assert(c.reads>=1 and c.messages>=1,c.text)
assert(c.text:find('^last 10 min: 1 game action %(and 2 with no effect%), %d+ reads?, %d+ messages?; working %d+%%, asleep %d+%% %(sleep 600 x1, sleep 5 x1%), waiting %d+%% %(wait_ticks x%d, wait_until x%d%), standing %d+%%$'),c.text)
assert(c.busy_s>=24 and c.standing_s>0,c.text)

-- The agent's own review (selfview.lua, task-selfview): review and networks are reads (a running action goes on);
-- queue steps count; a failed request counts and fails as before; team.review comes every 2 game hours, on a reply
-- that is not a peek.
S.active[si]={kind='walk',direction=0,until_tick=tick+600}
local mh=sol('review')
eq(S.active[si].kind,'walk','a read leaves the walk running')
assert(mh.lines[1]:find('^review %(last %d+ min%): %d+ actions'),mh.lines[1]); assert(mh.counts.reads>=1); assert(mh.note)
eq(type(sol('networks').surfaces),'table')
sol('stop')
local before=sol('review').queue_steps
sol('queue_submit',{steps={{action='wait_ticks',args={ticks=60}},{action='wait_ticks',args={ticks=60}}}}); advance(200)
eq(sol('review').queue_steps,before+2,'each queue step started counts')
local failed0=sol('review').failed
fails(function() sol('configure',{position={x=999,y=999},recipe='nothing'}) end,'')
eq(sol('review').failed,failed0+1,'a failed request counts')
fails(function() sol('configure',{position={x=999,y=999},recipe='nothing',peek=true}) end,'')
eq(sol('review').failed,failed0+1,'a peek does not')
sol('queue_submit',{steps={{action='configure',args={position={x=999,y=999},recipe='nothing'}}}}); advance(5)
eq(sol('review').failed,failed0+2,'a failed queue step counts')
sol('queue_cancel',{})
S.selfview[si].shown=nil; S.selfview[si].since=tick
advance(2*60*60*60-10); eq((sol('status').team or {}).review,nil,'not before 2 hours')
advance(10)
eq((sol('status',{peek=true}).team or {}).review,nil,'a peek gets none')
local rv=sol('status').team.review
assert(rv and rv[1]:find('^review %(last 2h%): %d+ actions?'),rv and rv[1])
assert(has(rv,'failed: '),'the failures line'); assert(has(rv,'losses near your work: '))
eq((sol('status').team or {}).review,nil,'once per 2 hours')
-- The first reply of a shift carries the networks, one line each (networks.lua), next to researched_none_built.
local pstats={output_counts={['steam-engine']=1},get_flow_count=function() return 9e6/60 end}
local poles={}
for i=1,3 do poles[i]={valid=true,name='small-electric-pole',type='electric-pole',position={x=i*5,y=0},electric_network_id=4,electric_network_statistics=pstats} end
force.players={nick}; game.surfaces={surface}
surface.find_entities_filtered=function(f) return f.type=='electric-pole' and poles or {} end
advance(3*3700)  -- past the 60 s the networks view is kept; the pole map, then the view, each spread over a minute (walk.lua)
runtime.operator.shift_start()
local sh=sol('status').team.shift
assert(sh and sh.networks and sh.networks[1]:find('^nauvis electric #4 %(3 poles near %(10,0%)%): draw 9%.0 MW avg over'),sh and sh.networks and sh.networks[1])
eq(sh.retro,nil,'no previous shift on record')
-- The next shift's first reply carries the retro of this one.
advance(600); runtime.operator.shift_start()
local retro=sol('status').team.shift.retro
assert(retro and retro[1]:find('^retro: previous shift %(10s of game time%): research done: '),retro and retro[1])
assert(has(retro,'failed (team): '),'the team failures line'); assert(has(retro,'open board items: '))
print('idle: ok')
