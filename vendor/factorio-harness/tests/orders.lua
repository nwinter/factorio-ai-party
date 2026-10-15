-- Run from repository root: lua tests/orders.lua
-- Standing orders (orders.lua, scheduler.lua run_order): a default routine and triggered orders run in the agent's
-- own queue while its character is free; its own requests preempt them and they resume after; the orders line on
-- every reply; limits; failures switch an order off; the stream and idle report fields. Fake engine as tests/idle.lua.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
local function has(s,text) assert(type(s)=='string' and s:find(text,1,true),'missing "'..text..'" in: '..tostring(s)) end
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
  local c={valid=true,name='character',type='character',force=force,surface=surface,position=pos,unit_number=500+units,health=250,max_health=250,
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
local astra,sol=as('astra'),as('sol')
local function op(action,args) return request{action=action,args=args or {},operator=true} end
runtime.operator.bot_create('astra'); runtime.operator.bot_create('sol')
local body=runtime.bots.lookup(runtime.bots.index_of('astra')).character
local function report(name)
  for _,row in ipairs(op('idle_report',{}).agents) do if row.name==name then return row end end
end
local function running() local q=astra('queue_status'); return q.order and q.order.name,q end
-- advance until the named order runs (or n ticks pass)
local function until_running(name,n)
  for _=1,n or 3000 do if running()==name then return end; advance(1) end
  error('order '..name..' never ran')
end
local wait=function(ticks) return {action='wait_ticks',args={ticks=ticks}} end

-- No orders: no line.
astra('status'); sol('status')
eq(astra('status').orders,nil)

-- A default routine: two steps, run while the character is free, `hold` (20 s) after the agent's own last action.
local r=astra('order_set',{name='patrol',steps={wait(300),{action='walk',args={direction='east',ticks=30}}},interval_ticks=36000})
eq(r.order.name,'patrol'); eq(r.order.state,'ready'); eq(#r.list,1); eq(r.order.interval_ticks,36000)
astra('walk',{direction='north',ticks=10}); advance(15)
has(astra('status').orders,'orders: start in ') -- held after the walk
advance(600)
eq(running(),nil)
until_running('patrol',1300)
assert(tick>=1200,'started before the hold: '..tick)
local line=astra('status').orders
has(line,'orders: patrol running (default routine), step 1/2')
-- the stream's brief status and the operator's idle report
local brief=astra('status',{brief=true})
eq(brief.order.name,'patrol'); eq(brief.order.steps,2)
advance(60) -- the standing clock is kept once a second
local row=report('astra'); eq(row.orders.running,'patrol'); eq(row.orders.set,1); eq(row.standing_s,0); eq(row.queue.state,'running')
-- reads, chat and board posts never preempt
astra('say',{text='feeding the line'}); astra('chat',{}); astra('orders'); astra('tell',{to='sol',text='on the line'})
eq(running(),'patrol')

-- The agent's own request preempts at once; the order keeps its remaining steps and resumes after.
advance(10)
astra('walk',{direction='west',ticks=60})
local name,q=running()
eq(name,nil); eq(#q.pending,0) -- the queue is the agent's again
has(astra('status').orders,'patrol waits for your walk, resumes after')
advance(70)
has(astra('status').orders,'patrol resumes in ')
until_running('patrol',1300)
name,q=running()
eq(q.order.reason,'resumed'); eq(q.order.steps,1) -- the interrupted wait is relative, so it is not repeated; the walk is left
advance(40)
eq(running(),nil)
local list=astra('orders').list
eq(list[1].runs,1); has(list[1].state,'next in ')
has(astra('status').orders,'waiting (patrol next in ')

-- A trigger: health below half. It runs while the condition holds, then waits its cooldown.
r=astra('order_set',{name='heal',when={['until']='health_below',fraction=0.5},steps={wait(60)},priority=7,cooldown_ticks=300})
eq(r.order.priority,7); eq(r.order.cooldown_ticks,300)
advance(180)
eq(running(),nil) -- full health: not holding
has(astra('status').orders,'waiting (1 trigger not holding; patrol next in ')
body.health=100
until_running('heal',200)
has(astra('status').orders,'heal running (health 40%), step 1/1')
advance(70)
eq(running(),nil)
has(astra('orders').list[2].state,'cooling ')
until_running('heal',400) -- still holding after the cooldown
advance(70)
body.health=250
advance(600)
eq(running(),nil)
eq(astra('orders').list[2].runs,2)

-- A holding trigger stops a running order of lower priority (the default counts 0); that one resumes after.
astra('order_set',{name='patrol',steps={wait(900),{action='walk',args={direction='east',ticks=30}}},interval_ticks=36000})
until_running('patrol',200)
body.health=100
until_running('heal',200)
eq(astra('orders').list[1].state,'resumes when free')
body.health=250
advance(70)
until_running('patrol',200)
eq(astra('queue_status').order.reason,'resumed')

-- The agent's queue calls preempt too: its own plan runs; the order waits for it and the hold.
astra('queue_submit',{steps={wait(30)}})
name,q=running()
eq(name,nil); eq(q.pending[1].action,'wait_ticks'); eq(q.pending[1].order,nil)
has(astra('status').orders,'patrol waits for your queue, resumes after')
advance(40)
has(astra('status').orders,'patrol resumes in ')
-- queue_edit refuses while an order runs (queue_cancel stops it)
until_running('patrol',1300)
local rev=astra('queue_status').revision
fails(function() astra('queue_edit',{expected_revision=rev,index=1,remove=0,steps={wait(5)}}) end,'a standing order (patrol) is running')
astra('queue_cancel',{})
eq(running(),nil)
advance(120)
eq(running(),nil) -- queue_cancel is the agent's own move: the hold applies

-- orders_pause stops a running order and starts none; orders_resume sets the hold.
until_running('patrol',1300)
r=astra('orders_pause',{})
eq(r.paused,true); eq(running(),nil)
has(astra('status').orders,'orders: paused (orders_resume)')
advance(1500)
eq(running(),nil)
r=astra('orders_resume',{hold_s=1})
eq(r.hold_s,1)
until_running('patrol',200)
astra('orders_pause',{seconds=2})
has(astra('status').orders,'paused for 2 s')
until_running('patrol',300)

-- max_ticks: a run that takes longer is stopped and counts as a failure.
astra('order_remove',{name='patrol'})
eq(running(),nil)
astra('order_set',{name='slow',steps={wait(600)},max_ticks=120,interval_ticks=60})
until_running('slow',200)
advance(200)
eq(running(),nil)
has(astra('status').orders,'slow failed 1/3: ran over max_ticks 120')

-- Three failed runs in a row switch an order off, with the reason in the line; order_set switches it back on.
astra('order_remove',{name='slow'})
astra('order_set',{name='broken',steps={{action='walk',args={direction='up',ticks=5}}},interval_ticks=60})
advance(600)
line=astra('status').orders
has(line,'broken off after 3 failures: walk: ')
has(line,'invalid compass direction')
eq(astra('orders').list[2].state,'off')
advance(600)
eq(astra('orders').list[2].failures,3) -- no more runs
r=astra('order_set',{name='broken',steps={wait(5)},interval_ticks=60})
eq(r.order.state,'ready'); eq(r.order.failures,0)
advance(200)
eq(astra('orders').list[2].runs>=1,true)

-- Limits and checks when the order is set.
fails(function() astra('order_set',{name='two',steps={wait(5)}}) end,'one default routine (no when) per agent: broken')
fails(function() astra('order_set',{name='bad name!',steps={wait(5)},when={['until']='crafting_done'}}) end,'name: 1..32')
local many={}
for i=1,33 do many[i]=wait(5) end
fails(function() astra('order_set',{name='big',steps=many,when={['until']='crafting_done'}}) end,'steps: 1..32')
fails(function() astra('order_set',{name='far',steps={wait(5)},when={['until']='no_enemies',radius=100}}) end,'when radius is at most 64')
fails(function() astra('order_set',{name='cool',steps={wait(5)},when={['until']='crafting_done'},cooldown_ticks=100}) end,'cooldown_ticks must be an integer 300..216000')
fails(function() astra('order_set',{name='mix',steps={wait(5)},when={['until']='crafting_done'},interval_ticks=600}) end,'interval_ticks is for the default routine')
fails(function() astra('order_set',{name='nest',steps={{action='order_set',args={name='x'}}},when={['until']='crafting_done'}}) end,'action is not queueable')
fails(function() astra('order_set',{name='odd',steps={{action='teleport'}},when={['until']='crafting_done'}}) end,'unknown action in plan')
fails(function() astra('order_set',{name='when',steps={wait(5)},when={['until']='bogus'}}) end,'until must be one of')
fails(function() astra('order_set',{name='arg',steps={wait(5)},colour='red'}) end,'unknown argument colour for order_set')
for i=1,4 do astra('order_set',{name='t'..i,steps={wait(5)},when={['until']='health_below',fraction=0.1}}) end
eq(#astra('orders').list,6) -- heal, broken, t1..t4
fails(function() astra('order_set',{name='t6',steps={wait(5)},when={['until']='crafting_done'}}) end,'at most 6 standing orders')
fails(function() astra('order_remove',{name='nope'}) end,'no standing order nope')
-- a failed order call stops nothing
astra('walk',{direction='east',ticks=100})
pcall(astra,'order_set',{name='t6',steps={wait(5)}})
eq(astra('status').active.kind,'walk')

-- Orders are per agent: Sol has none and no line.
eq(sol('status').orders,nil)
eq(report('sol').orders,nil)
-- Sol's own routine runs beside Astra's, and a running order is not idle on the clock line.
sol('order_set',{name='courier',steps={wait(3000)}})
sol('orders_resume',{hold_s=0})
advance(61)
eq(sol('queue_status').order.name,'courier')
sol('status'); advance(600)
local idle=sol('status').clock:match('character idle (%d+)s of it')
eq(idle,'0')
eq(report('sol').orders.running,'courier')
-- An agent away 30 minutes (no request of its own, no sleep poll) gets no new runs; its next request brings them back.
local function sol_runs() return sol('orders',{peek=true}).list[1].runs end -- a peek is not the agent's request
advance(115000)
local runs=sol_runs()
assert(runs>=2,runs)
advance(10000)
eq(sol_runs(),runs); eq(sol('queue_status',{peek=true}).order,nil)
sol('status')
advance(61)
eq(sol('queue_status').order.name,'courier')

-- The operator's kill switch (orders_kill, operator dispatch only): every running order stops, nothing starts,
-- triggers included, until it is switched off; agents see 'orders: paused by the operator'.
astra('status')
body.health=100
until_running('heal',300)
eq(sol('queue_status').order.name,'courier')
fails(function() astra('orders_kill',{on=true}) end,'unsupported action') -- agents cannot reach it
eq(op('orders_kill',{}).on,false)
until_running('heal',300) -- the agent's failed call stopped its own order; the trigger still holds
r=op('orders_kill',{on=true})
local killed_at=tick
eq(r.on,true); eq(r.since_tick,killed_at); eq(table.concat(r.stopped,','),'astra,sol'); eq(r.agents_with_orders,2)
eq(running(),nil); eq(sol('queue_status').order,nil)
eq(astra('status').orders,'orders: paused by the operator'); eq(sol('status').orders,'orders: paused by the operator')
eq(report('astra').orders.operator_paused,true); eq(report('astra').orders.running,nil)
local o=astra('orders')
eq(o.paused_by_operator,true)
eq(o.list[1].name,'heal'); eq(o.list[1].state,'paused by the operator'); eq(o.list[1].failures,0); eq(o.list[1].last.outcome,'stopped')
advance(3000) -- the trigger holds and both agents play: nothing starts
eq(running(),nil); eq(sol('queue_status').order,nil)
-- the agent's own orders_resume does not lift it; order_set still works and waits too
has(astra('orders_resume',{}).note,'paused by the operator')
sol('order_set',{name='courier',steps={wait(3000)}})
advance(300)
eq(running(),nil); eq(sol('queue_status').order,nil)
-- on again changes nothing and stops nobody; a bad value fails
r=op('orders_kill',{on=true})
eq(#r.stopped,0); eq(r.since_tick,killed_at)
fails(function() op('orders_kill',{on='yes'}) end,'on: true stops all standing orders')
-- off: orders start again after each agent's hold, afresh (no resume of the stopped run)
r=op('orders_kill',{on=false})
eq(r.on,false); eq(r.since_tick,nil)
has(astra('status').orders,'orders: start in 1 s') -- the hold (1 s for Astra) runs from the switch
advance(30)
eq(running(),nil)
until_running('heal',300)
has(astra('queue_status').order.reason,'health 40%')
for _=1,120 do if sol('queue_status').order then break end; advance(1) end
eq(sol('queue_status').order.name,'courier'); eq(sol('queue_status').order.reason,'default routine')
body.health=250

-- Orders between the rounds of a repeating plan (Opus, shift13: "orders never run while my queue repeats, so turret
-- rearm and boiler fuel orders never fire"): a triggered order runs in the pause between rounds, its hold counted from
-- the agent's own last request; the next round waits for it; the default routine waits for orders=all; orders=none
-- keeps them all out.
;(function()
runtime.operator.bot_create('opus')
local opus=as('opus')
local obody=runtime.bots.lookup(runtime.bots.index_of('opus')).character
local function oq() return opus('queue_status',{peek=true}) end
local function until_order(name,n)
  for _=1,n do local o=oq().order; if o and o.name==name then return end; advance(1) end
  error('order '..name..' never ran')
end
opus('order_set',{name='mend',when={['until']='health_below',fraction=0.5},steps={wait(120)},cooldown_ticks=300})
opus('order_set',{name='tidy',steps={wait(30)},interval_ticks=36000})
obody.health=100
local t0=tick
local q=opus('queue_repeat',{steps={wait(600)},interval_ticks=1800})
eq(q.orders_between_rounds,'triggers')
-- In a round nothing starts, and the line says why.
advance(400)
eq(oq().order,nil); eq(oq().cycle,1)
has(opus('status').orders,"waiting for your repeating plan's round (orders run between its rounds: triggered ones)")
-- Between rounds the trigger runs once the hold (20 s from the queue_repeat call) is over, before the next round.
until_order('mend',2000)
assert(tick>=t0+1200 and tick<t0+2400,'started at '..(tick-t0))
eq(oq().repeating,true); eq(oq().cycle,1)
has(opus('status').orders,'mend running (health 40%)')
-- The default routine is not one of the triggered ones: it stays out between rounds.
for _=1,t0+2390-tick do advance(1); local o=oq().order; assert(not o or o.name=='mend','tidy ran between rounds') end
-- mend ran again after each 300-tick cooldown while it held; tidy never.
local list=opus('orders',{peek=true}).list
eq(list[1].runs,3); eq(list[2].runs,0)
for _=1,30 do if oq().cycle==2 then break end; advance(1) end
eq(oq().cycle,2)
-- A round due while an order runs waits for it: rounds of 100 ticks with 60 between.
opus('queue_repeat',{steps={wait(100)},interval_ticks=60})
until_order('mend',4000)
local c,due=oq().cycle,oq().next_cycle_tick
assert(due and due<=tick+60,'the next round is due within the rest')
advance(80)
assert(tick>due,'past the round\'s time')
eq(oq().cycle,c); eq(oq().order.name,'mend')
for _=1,200 do if not oq().order then break end; advance(1) end
eq(oq().order,nil)
advance(2)
eq(oq().cycle,c+1)
-- orders=none: nothing runs between rounds.
opus('queue_repeat',{steps={wait(100)},interval_ticks=600,orders='none'})
eq(oq().orders_between_rounds,'none')
local runs=opus('orders',{peek=true}).list[1].runs
for _=1,2500 do advance(1); eq(oq().order,nil) end
eq(opus('orders',{peek=true}).list[1].runs,runs)
has(opus('status').orders,'your repeating plan (orders: none)')
-- orders=all: the default routine runs between rounds too.
obody.health=250
opus('queue_repeat',{steps={wait(100)},interval_ticks=1800,orders='all'})
until_order('tidy',2000)
eq(oq().repeating,true)
fails(function() opus('queue_repeat',{steps={wait(5)},orders='some'}) end,'orders must be triggers, all or none')
opus('queue_cancel',{})
end)()
-- describe documents the calls (argument checks come from it)
local actions=astra('describe').actions
assert(actions.queue_repeat.orders,'queue_repeat orders')
assert(actions.order_set and actions.order_remove and actions.orders and actions.orders_pause and actions.orders_resume)
has(actions.wait_until['until'],'ghosts_waiting|damaged|fuel_below')
print('orders: ok')
