-- Run from the harness root: lua tests/d17_batch16_rt.lua
-- d17 batch16 through the runtime against a fake engine (the scaffold of tests/d16_batch7_rt.lua).
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
local force={name='player',get_friend=function() return false end,get_cease_fire=function() return false end,chart=function() end,is_chunk_visible=function() return true end,is_chunk_charted=function() return true end,get_spawn_position=function() return {x=0,y=0} end}
local surface={name='nauvis',index=1}
local units=0
local function character(pos)
  local items={}
  units=units+1
  local c={valid=true,name='character',type='character',force=force,surface=surface,position=pos,unit_number=500+units,health=250,max_health=250,
    prototype={collision_box={left_top={x=-0.2,y=-0.2},right_bottom={x=0.2,y=0.2}},collision_mask={layers={player=true}}},
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
  -- As the engine: a bot's index is no player index.
  get_player=function(i) assert(type(i)=='string' or i<=65536,'Given player value is too big'); if type(i)=='string' then for _,p in ipairs(players) do if p.name==i then return p end end return nil end return players[i] end,
  get_surface=function() return surface end,print=function() end,connected_players=players,
  get_pollution_statistics=function() return {input_counts={},output_counts={},get_flow_count=function() return 0 end} end}
local runtime=dofile('mod/agent-harness_0.1.0/runtime.lua')
local function advance(n) for _=1,n do tick=tick+1; game.tick=tick; runtime.tick{tick=tick} end end
local function jump(n) tick=tick+n; game.tick=tick end
-- As control.lua does: a failed request stops its player unless the runtime
-- marked it passive.
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
astra('profile',{display_name='Astra',glyph='A',color='#9977ff'})
sol('profile',{display_name='Sunny',glyph='S',color='#ffcb45'})

-- A1 (Grok d17 16:16): load_silo {walk, from: [chest], launch, platform} without the silo's position failed as
-- "position requires x and y", read as the from list being wrong. It names the silo it needs, the silos here and a
-- call that keeps the from list.
do
  local silo={valid=true,name='rocket-silo',type='rocket-silo',force=force,surface=surface,position={x=65.5,y=14.5},
    rocket_silo_status=1,rocket_parts=20,prototype={rocket_parts_required=50}}
  defines.rocket_silo_status={rocket_ready=5,building_rocket=1}
  local was=surface.find_entities_filtered
  surface.find_entities_filtered=function(f) if f and f.type=='rocket-silo' then return {silo} end return {} end
  local args={platform='Wren',launch=true,walk=true,items={{item='rocket-turret',count=5}},from={{x=-17.5,y=27.5}}}
  local ok,err=pcall(grok,'load_silo',args)
  err=tostring(err)
  assert(not ok and err:find('load_silo takes the silo: position (the silo; from is the chests: one {x,y} or a list of them)',1,true),err)
  assert(err:find('rocket-silo (65.5,14.5) building_rocket, parts 20/50',1,true),err)
  assert(err:find('fh call load_silo',1,true) and err:find('-17.5',1,true) and err:find('65.5',1,true),err)
  assert(not err:find('position requires x and y',1,true),err)
  -- a dry run needs the silo too
  fails(function() grok('load_silo',{dry_run=true,items={['iron-plate']=10}}) end,'load_silo takes the silo: position')
  surface.find_entities_filtered=was
end
print('d17_batch16_rt A1 load_silo without its silo: ok')

-- A4 (Sol d17 16:13, 2x): a direct transfer requeued the running load_silo and the queue started it again on its own when
-- the transfer ended. queue_pause is the agent's own pause: the running step goes back to the head of pending, and the
-- lane holds until queue_resume; direct calls in between never resume it, and their replies say so.
do
  local index=runtime.bots.index_of('sol')
  sol('queue_cancel',{})
  sol('queue_submit',{steps={{action='move_to',args={position={x=30,y=5}},label='to the silo'},{action='wait_ticks',args={ticks=60}}}})
  advance(2)
  local q=storage.agent_harness.queues[index]
  local function dump(t) local o={} for k,v in pairs(t or {}) do o[#o+1]=tostring(k)..'='..tostring(type(v)=='table' and (v.action or v.reason or '{}') or v) end return table.concat(o,' ') end
  assert(q.current and q.current.action=='move_to','q: '..dump(q)..' last: '..dump(q.history[#q.history])..' result: '..dump(q.history[#q.history] and q.history[#q.history].result))
  local r=sol('queue_pause',{})
  assert(r.held and r.held:find('paused by you',1,true) and r.held:find('move_to stopped and requeued at the head',1,true),tostring(r.held))
  eq(q.paused,true); assert(q.held,'held')
  eq(q.pending[1].action,'move_to','requeued at the head')
  -- a direct call that would have resumed a requeued load: it does not, and says the queue is held
  q.requeued_load={id=q.pending[1].id,tick=game.tick}
  local out={}
  runtime.resume_requeued_load(storage and {index=index} or nil,'transfer',out)
  eq(q.paused,true,'still paused after a direct transfer')
  assert(out.queue_held and out.queue_held:find('paused by you (queue_pause',1,true) and out.queue_held:find('this call did not resume it',1,true),tostring(out.queue_held))
  eq(runtime.resume_after(index,q.pending[1].id),false,'a timed action ending does not resume it')
  advance(120)
  eq(q.paused,true,'held across ticks')
  local st=sol('queue_status',{})
  assert(tostring(st.paused_why):find('paused by you (queue_pause): held until queue_resume',1,true),tostring(st.paused_why))
  -- queue_resume lifts the hold
  sol('queue_resume',{})
  eq(q.paused,false); eq(q.held,nil)
  -- without queue_pause, a requeued load still resumes after a direct call ends (unchanged)
  sol('queue_cancel',{})
  -- (d24 batch138 PJ1) a submit with start:false is staged, held as queue_pause holds it: a direct call does not resume it
  local staged=sol('queue_submit',{steps={{action='wait_ticks',args={ticks=600}}},start=false})
  eq(staged.state,'paused, held until queue_resume'); assert(tostring(staged.staged):find('start: false: the lane is paused and held',1,true),tostring(staged.staged))
  q.requeued_load={id=q.pending[1].id,tick=game.tick}
  out={}
  runtime.resume_requeued_load({index=index},'transfer',out)
  eq(q.paused,true,'a staged queue stays paused'); eq(out.queue_resumed,nil)
  sol('queue_cancel',{})
  -- paused by a direct call (not held), a requeued load still resumes after it ends (unchanged)
  eq(sol('queue_submit',{steps={{action='wait_ticks',args={ticks=600}}}}).state,'running')
  q.paused=true; q.held=nil
  q.requeued_load={id=q.pending[1].id,tick=game.tick}
  out={}
  runtime.resume_requeued_load({index=index},'transfer',out)
  eq(q.paused,false,'resumed as before'); assert(out.queue_resumed,'said')
  sol('queue_cancel',{})
end
print('d17_batch16_rt A4 queue_pause holds: ok')

-- A5 (Haiku d17: "the idle counter should not count a sleep that is holding a defence watch"; operator cp4: standing
-- still accrues so the idle nudge fires as before): with a standing order armed, idle time is also on watch, named, in
-- the clock line, the sleep line and the idle report; the report's orders name it for the nudge.
do
  local index=runtime.bots.index_of('grok')
  grok('queue_cancel',{})
  grok('order_set',{name='defend',when={['until']='health_below',fraction=0.5},steps={{action='wait_ticks',args={ticks=60}}},priority=7,cooldown_ticks=300})
  grok('orders_resume',{})
  grok('status',{brief=true})
  advance(600)
  local r=grok('status',{brief=true})
  assert(r.clock and r.clock:find('character idle 10s of it (100%, on watch: defend for 10s of that)',1,true),tostring(r.clock))
  local sl=grok('sleep',{seconds=60})
  local line=sl.while_asleep or ''
  assert(line:find('your character stands idle for up to 60 s, on watch: your standing orders (defend) run when a trigger holds',1,true),line)
  advance(3600)
  -- the idle report: still standing (the nudge fires as before), on watch named, the orders' armed for the nudge text
  local rep=op('idle_report',{})
  local row
  for _,a in ipairs(rep.agents or rep) do if a.name=='grok' or a.agent=='grok' then row=a end end
  assert(row,'grok in the idle report')
  assert((row.standing_s or 0)>=60,'standing accrues: '..tostring(row.standing_s))
  eq(row.orders and row.orders.armed,'defend')
  local function find_text(t,depth) if depth>3 then return nil end for _,v in pairs(t) do if type(v)=='string' and v:find('on watch',1,true) then return v elseif type(v)=='table' then local f=find_text(v,depth+1) if f then return f end end end end
  local w=find_text(row,0)
  assert(w and w:find('asleep',1,true) and w:find('on watch',1,true) and w:find('(standing orders armed: defend)',1,true),tostring(w))
  -- paused orders: idle, nothing on watch
  grok('orders_pause',{})
  grok('status',{brief=true})
  advance(300)
  r=grok('status',{brief=true})
  assert(r.clock:find('character idle 5s of it (100%',1,true) and not r.clock:find('on watch',1,true),r.clock)
  grok('order_remove',{name='defend'})
end
print('d17_batch16_rt A5 an armed standing order is named on watch; standing still counts: ok')

-- B2 (Muse 15:49: transfer {to: "haiku", items} failed; players lists humans only): players lists the teammates'
-- characters with positions; transfer {to_player: NAME} hands items to one within reach, dropped at their feet as loot.
do
  prototypes=prototypes or {item={}}
  prototypes.item['iron-plate']=prototypes.item['iron-plate'] or {name='iron-plate',type='item',get_spoil_ticks=function() return 0 end}
  local spilled={}
  surface.spill_item_stack=function(t) spilled[#spilled+1]=t; return {} end
  local gi=runtime.bots.index_of('grok')
  local si=runtime.bots.index_of('sol')
  local gp,sp=runtime.lookup(gi),runtime.lookup(si)
  gp.character.position={x=10,y=10}; sp.character.position={x=12,y=10}
  local r=grok('players',{})
  assert(r.teammates and #r.teammates>=2,'teammates listed')
  local first=r.teammates[1]
  eq(first.name,'sol'); eq(first.distance,2)
  assert(first.line:find('Sunny on Nauvis at (12.0,10.0), 2 tiles E',1,true),first.line)
  -- a give by name: from grok's inventory, dropped at Sol's feet
  local inv=gp.character.get_main_inventory()
  inv.remove=function(st) return math.min(st.count,gp.character.items[st.name] or 0) end
  inv.get_item_count=function(q) return gp.character.items[type(q)=='table' and q.name or q] or 0 end
  gp.character.items['iron-plate']=30
  gp.character.can_reach_entity=function(e) return ((e.position.x-10)^2+(e.position.y-10)^2)^0.5<=10 end
  local g=grok('transfer',{to_player='Sol',item='iron-plate',count=20})
  eq(g.to_player,'sol'); eq(g.given[1],'iron-plate 20'); eq(#spilled,1); eq(spilled[1].stack.count,20); eq(spilled[1].position.x,12)
  assert(spilled[1].enable_looted,'loot their character picks up')
  assert(g.note:find("dropped at sol's feet (12.0,10.0)",1,true),g.note)
  -- to as a name too; out of reach: refused with where to go
  sp.character.position={x=40,y=10}
  fails(function() grok('transfer',{to='sol',item='iron-plate',count=1}) end,"sol's character at (40.0,10.0) is 30.0 tiles away, out of your reach")
  fails(function() grok('transfer',{to_player='nobody',item='iron-plate'}) end,'no teammate nobody; teammates: astra, sol')
end
print('d17_batch16_rt B2 teammates and a hand-over by name: ok')

-- C1 (Luna on Gleba: waits woke for other agents' tells to the team, Nauvis worm losses and other platforms' losses
-- while her own loop was stable): wake_local wakes only for what is the sleeper's. Default unchanged.
do
  local f=runtime.board.wake_filter({wake_local=true})
  assert(f and f.local_only,'a filter')
  eq(runtime.board.wakes({from='astra',team=true},f),false,'a tell to the whole team waits')
  eq(runtime.board.wakes({from='astra'},f),true,'a tell to you wakes')
  eq(runtime.board.wakes({from='astra',team=true,wake=true},f),true,'a tell sent with wake still does')
  eq(runtime.board.wakes({from='astra',team=true},nil),true,'default unchanged')
  fails(function() runtime.board.wake_filter({wake_local='yes'}) end,'wake_local must be true or false')
  -- urgent: another platform's losses wake only when you are aboard it
  local gi=runtime.bots.index_of('grok')
  local gp=runtime.lookup(gi)
  local old_hears=runtime.platalerts and runtime.platalerts.hears
  storage.agent_harness.losses={{id=1397,platform='Meridian',surface='platform-5',box={-3,5,-1,7},first=game.tick+1,last=game.tick+1,
    causes={['big-oxide-asteroid']=19},names={['transport-belt']=20},total=24}}
  local base=runtime.urgent.base(gp,nil)
  local base_local=runtime.urgent.base(gp,nil); base_local.local_only=true
  jump(2)
  local saved=runtime.urgent_hears
  if runtime.platalerts then runtime.platalerts.hears=function() return true end end
  local plain_line=runtime.urgent.check(gp,base)
  local local_line=runtime.urgent.check(gp,base_local)
  if runtime.platalerts then runtime.platalerts.hears=old_hears end
  assert(plain_line and plain_line:find('platform Meridian lost buildings',1,true),tostring(plain_line))
  eq(local_line,nil,'not aboard Meridian: it waits')
  storage.agent_harness.losses={}
  -- a sleep with wake_local and a plain alert condition: the alert keeps to the sleeper's surface
  local r=grok('sleep',{seconds=60,wake_local=true,condition={['until']='alert'}})
  local rec=storage.agent_harness.sleeps[gi]
  assert(rec and rec.wake_local and rec.alert_filter and rec.alert_filter.surface=='nauvis','alert on your surface')
  assert(rec.wake_filter and rec.wake_filter.local_only,'tells filtered')
end
print('d17_batch16_rt C1 wake_local: ok')
