-- d15 batch5 (operator 05:20, shifts 20-22 requests). Run from the harness root: lua tests/d15_batch5.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,msg) assert(a==b,(msg or '')..' '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end

-- A3 (Muse, twice): a step written flat ({action, position, ...}) is refused on submit, naming the step and the shape. --
do
  game={tick=0}
  local st={}
  local players={[1]={index=1}}
  local handlers={transfer=function() return {} end,collect=function() return {} end}
  local takes={transfer={position=true,item=true,count=true,direction=true},collect={position=true,item=true}}
  local S=dofile('mod/agent-harness_0.1.0/scheduler.lua'){state=function() return st end,player=function(i) return players[i] end,handlers=handlers,
    busy=function() return false end,stop=function() end,stop_index=function() end,condition=function() return false end,validate_condition=function() end,
    takes=function(action,key) return takes[action] and takes[action][key]==true end}
  fails(function() S.handlers.queue_repeat(players[1],{steps={{action='collect',args={position={x=1,y=0},item='yumako'}},
    {action='transfer',position={x=5,y=0},item='yumako',label='drop'}}}) end,
    'steps[2] (transfer, label "drop"): item, position are arguments of transfer written beside action; a step is {action: "transfer", args: {item: ..., position: ...}}')
  fails(function() S.handlers.queue_submit(players[1],{steps={{action='collect',args={item='x'},position={x=1,y=0}}}}) end,
    'this step also has args: put every argument of the action in it')
  eq(st.queues==nil or st.queues[1]==nil or #(st.queues[1].pending or {})==0,true,'nothing queued')
  local ok=pcall(S.handlers.queue_repeat,players[1],{steps={{action='transfer',args={position={x=5,y=0},item='yumako'},wait=true,label='drop'}}})
  assert(ok,'the nested shape passes')
end
print('d15_batch5 A3 flat steps: ok')

-- B3 (Sonnet, Astra): a load_silo step paused by the agent's own call is requeued; a walking load with the rocket's
-- totals (to_total), so it goes on from what is aboard. ---------------------------------------------------------------
do
  game={tick=100}
  local st={active={}}
  local players={[1]={index=1}}
  local S=dofile('mod/agent-harness_0.1.0/scheduler.lua'){state=function() return st end,player=function(i) return players[i] end,handlers={load_silo=function() return {} end},
    busy=function() return false end,stop=function() end,stop_index=function() end,condition=function() return false end,validate_condition=function() end}
  st.queues={[1]={pending={},history={},revision=1,sequence=1,paused=false,
    current={id='job-7',action='load_silo',args={position={x=15.5,y=59.5},items={['agricultural-science-pack']=300},walk=true,from={{x=1,y=2}}},wait=true}}}
  st.active[1]={queued=true,op='load_silo',goals={{name='agricultural-science-pack',quality='normal',target=885}}}
  S.pause(1)
  local q=st.queues[1]
  eq(q.paused,true); eq(q.pending[1].id,'job-7'); eq(q.pending[1].action,'load_silo')
  eq(q.pending[1].args.to_total,true); eq(q.pending[1].args.items[1].count,885); eq(q.pending[1].args.walk,true)
  eq(q.requeued_load.id,'job-7')
  has(q.history[#q.history].result.resumed_from,'to_total')
  -- A load waiting for its rocket (no goals yet): requeued as it was.
  st.active[1]={queued=true,kind='feed'}
  q.paused=false; q.current=table.remove(q.pending,1); q.current.args={position={x=15.5,y=59.5},items={coal=5}}
  S.pause(1)
  eq(q.pending[1].args.items.coal,5); eq(q.pending[1].args.to_total,nil)
end
print('d15_batch5 B3 load_silo requeue: ok')

-- B3 (Grok): a walking load ends when the rocket it fills launches by another hand. -------------------------------------
do
  game={tick=1000}
  prototypes={item={['agricultural-science-pack']={weight=1000}}}
  defines={inventory={rocket_silo_rocket=1},rocket_silo_status={rocket_ready=13}}
  local silo={valid=true,name='rocket-silo',type='rocket-silo',position={x=15.5,y=59.5},unit_number=9}
  local launched
  local R=dofile('mod/agent-harness_0.1.0/rocketload.lua'){last_launch=function(s) return launched end}
  local action={silo=silo,started_tick=500,goals={{name='agricultural-science-pack',quality='normal',target=885}},rows={},trips=1,items={},load={}}
  launched={tick=900,by='astra',cargo='agricultural-science-pack 885'}
  local out=R.walk_visit({},action,{position={x=3,y=4},name='steel-chest'})
  eq(out.stop,'rocket_launched'); eq(action.final,'rocket_launched')
  has(action.why,'launched 1 s ago by astra (cargo: agricultural-science-pack 885)')
end
print('d15_batch5 B3 gather stops at launch: ok')

-- I (viewer Foobator; design Astra and Sol 05:16): reminder jobs: a line to each recipient when due, missed runs folded
-- into the pending one, ack keeps the cadence, snooze moves the next run, a rollback sets due ticks from the tick. ---------
do
  game={tick=960}
  local st={}
  local boxes={}
  local agents={{name='sol',index=2},{name='astra',index=1},{name='luna',index=3}}
  local R=dofile('mod/agent-harness_0.1.0/reminders.lua'){state=function() return st end,
    resolve=function(w) for _,a in ipairs(agents) do if a.name==w then return w end end error('no teammate '..w,0) end,
    agents=function() return agents end,who=function(p) return p.name end,
    deliver=function(index,t) boxes[index]=boxes[index] or {}; table.insert(boxes[index],t) end}
  local sol,astra,luna={name='sol',index=2},{name='astra',index=1},{name='luna',index=3}
  local function run(ticks) for _=1,ticks do game.tick=game.tick+1; R.tick() end end
  local r=R.handlers.reminder_add(sol,{name='ship review',message='Petrel ammo, fuel and hub room',every_ticks=54000,recipients='sol,astra',board_item=575})
  eq(r.added,1); eq(r.reminder.recipients,'astra, sol'); eq(r.reminder.next_due_tick,54960)
  fails(function() R.handlers.reminder_add(sol,{message='x',every_ticks=60}) end,'every_ticks must be 3600..')
  fails(function() R.handlers.reminder_add(sol,{message='x'}) end,'every_ticks (a cadence')
  fails(function() R.handlers.reminder_edit(astra,{id=1,message='mine now'}) end,'is sol\'s: its owner edits')
  run(54000)
  eq(#boxes[2],1); eq(#boxes[1],1); eq(boxes[3],nil,'luna is no recipient')
  has(boxes[1][1].text,'ship review (sol, every 15m00s, board #575): Petrel ammo, fuel and hub room; reminder_ack {id: 1, result}')
  eq(boxes[1][1].from,'reminder #1')
  local l=R.handlers.reminders(astra,{}).reminders[1]
  eq(l.yours,'pending'); eq(l.next_due_tick,108960)
  -- Not acknowledged: the next run folds into the pending line (no second line), and it reads overdue.
  run(54000)
  eq(#boxes[1],1,'no backlog'); has(R.handlers.reminders(astra,{}).reminders[1].states,'astra pending (1 run missed)')
  -- sol acknowledges: the result is kept, the cadence stays anchored.
  local ack=R.handlers.reminder_ack(sol,{id=1,result='Petrel 900 magazines, 4 free slots'})
  eq(ack.missed,1); eq(R.handlers.reminders(sol,{}).reminders[1].next_due_tick,162960)
  run(54000)
  eq(#boxes[2],2,'sol gets the next run'); eq(#boxes[1],1,'astra still pending: folded')
  -- A server paused for hours: one run, not one per missed interval.
  game.tick=game.tick+54000*5-1; run(1)
  eq(#boxes[2],2,'still pending for sol: folded'); eq(R.handlers.reminders(sol,{}).reminders[1].next_due_tick,162960+54000*6)
  -- snooze: the next run only.
  local sn=R.handlers.reminder_snooze(astra,{id=1,ticks=600}); eq(sn.next_due_tick,game.tick+600)
  run(600); eq(#boxes[1],2,'astra\'s snoozed run came')
  -- A rollback: a next run more than one interval ahead is set from the restored tick.
  local job=st.reminders.jobs[1]
  game.tick=game.tick-200000; R.tick()
  for _=1,59 do game.tick=game.tick+1; R.tick() end
  assert(job.next_due>game.tick and job.next_due<=game.tick+54000,'next run within one interval of the restored tick: '..job.next_due..' at '..game.tick)
  -- Once, to the team: fires once and is done.
  local once=R.handlers.reminder_add(luna,{message='Aquilo heater check',due_in_ticks=120,recipients='team'})
  run(180)
  eq(#boxes[3],1); eq(R.handlers.reminders(luna,{}).reminders[1].done,true)
  eq(#R.handlers.reminders(luna,{}).reminders,1,'luna: hers and those to her, not #1')
  eq(R.handlers.reminders(luna,{all=true}).count,2)
  R.handlers.reminder_remove(sol,{id=1}); eq(R.handlers.reminders(sol,{all=true}).count,1)
  eq(once.added,2)
end
print('d15_batch5 I reminders: ok')

-- C1 (Astra, Sonnet): a platform request's minimum payload (the GUI's custom minimum payload, minimum_delivery_count). -
do
  defines={space_platform_state={paused=7},rocket_silo_status={},inventory={hub_main=1,hub_trash=2},cargo_destination={}}
  prototypes={item={stone={},coal={}},space_location={nauvis={},fulgora={}},quality={normal={}}}
  local slots={}
  local sec={index=1,is_manual=true,group='',active=true,filters_count=0}
  local function recount() local n=0; for i in pairs(slots) do n=math.max(n,i) end; sec.filters_count=n end
  sec.get_slot=function(i) return slots[i] or {} end
  sec.set_slot=function(i,f) slots[i]=f; recount() end
  sec.clear_slot=function(i) slots[i]=nil; recount() end
  setmetatable(sec,{__index=function(_,k) if k=='filters' then local out={}; for i=1,sec.filters_count do out[i]=slots[i] or {} end; return out end end})
  local secs=setmetatable({get_section=function(i) return i==1 and sec or nil end,add_section=function() return sec end},{__index=function(_,k) if k=='sections_count' then return 1 end end})
  local main={get_item_count=function() return 0 end,get_contents=function() return {} end}
  local platform={valid=true,name='Swift',index=1,space_connection={},
    hub={valid=true,type='space-platform-hub',position={x=0,y=0},get_logistic_sections=function() return secs end,get_inventory=function() return main end}}
  local p={index=1,force={platforms={platform}}}
  local space=dofile('mod/agent-harness_0.1.0/space.lua'){state=function() return {} end,
    integer=function(v,d,lo,hi,name) v=v==nil and d or v; assert(type(v)=='number' and v>=lo and v<=hi,name..' out of range'); return v end,
    keep=function() return {set_construction=function(_,on) return on end,construction=function() return nil end} end,freight={where=function() return {} end}}
  local r=space.requests(p,{platform='Swift',set={{item='stone',min=50,from='fulgora',min_payload=10}}})
  eq(slots[1].minimum_delivery_count,10); eq(r.stored[1],'stone 50..inf from fulgora min payload 10')
  -- an edit that does not name it keeps it; false clears it
  r=space.requests(p,{platform='Swift',set={{item='stone',min=80}}})
  eq(slots[1].minimum_delivery_count,10); has(r.stored[1],'stone 80..inf from fulgora min payload 10 (import planet kept: not named in this edit) (min payload kept: not named in this edit)')
  r=space.requests(p,{platform='Swift',set={{item='stone',min=80,min_payload=false}}})
  eq(slots[1].minimum_delivery_count,nil); eq(r.stored[1],'stone 80..inf from fulgora (import planet kept: not named in this edit) (was stone 80..inf from fulgora min payload 10)')
  fails(function() space.requests(p,{platform='Swift',set={{item='coal',min=5,min_payload=2.5}}}) end,'min_payload must be 1..1000000')
  fails(function() space.requests({index=2,force={platforms={}},get_main_inventory=function() return main end,get_requester_point=function() return nil end},{set={{item='coal',min=5,min_payload=3}}}) end,'')
end
print('d15_batch5 C1 min payload: ok')

-- C4 (Sonnet, Astra): arrival estimates through the schedule: the shortest way through the connections, and in flight
-- the rest of the leg, then the stops after it. -------------------------------------------------------------------------
do
  defines={space_platform_state={on_the_path=9},inventory={hub_main=1,hub_trash=2}}
  prototypes={space_connection={a={from={name='nauvis'},to={name='fulgora'},length=15000},b={from={name='nauvis'},to={name='vulcanus'},length=15000},
    c={from={name='nauvis'},to={name='gleba'},length=15000},d={from={name='vulcanus'},to={name='gleba'},length=15000},e={from={name='gleba'},to={name='fulgora'},length=15000},
    f={from={name='fulgora'},to={name='aquilo'},length=30000}}}
  game={tick=10000}
  local st={}
  local F=dofile('mod/agent-harness_0.1.0/freight.lua'){state=function() return st end}
  local r=F.path('fulgora','vulcanus')
  eq(r.km,30000); eq(#r.via,1); eq(r.also~=nil,true,'as short the other way')
  eq(F.path('aquilo','vulcanus').km,60000); eq(F.path('nauvis','nauvis').km,0)
  -- At Fulgora, its schedule to Vulcanus: the way through Nauvis or Gleba.
  local pl={valid=true,index=4,name='Tern',state=1,paused=false,space_location={name='fulgora'},
    schedule={current=1,records={{station='fulgora',wait_conditions={{type='time',ticks=600}}},{station='vulcanus',wait_conditions={{type='time',ticks=600}}}}}}
  st.freight={[4]={segs={{kind='stop',at='fulgora',start=10000}},speed=2}}
  r=F.before_departure(pl,'vulcanus')
  eq(r.eta_s,10+250)
  has(r.line,'fulgora->vulcanus 30000 km via ')
  -- In flight on its first leg toward Gleba (schedule: gleba, then vulcanus), 5000 km left at 2 km a tick.
  pl.space_location=nil
  pl.space_connection={from={name='fulgora'},to={name='gleba'},length=15000}; pl.distance=2/3; pl.speed=2
  pl.last_visited_space_location={name='fulgora'}
  pl.schedule={current=1,records={{station='gleba',wait_conditions={{type='time',ticks=1200}}},{station='vulcanus',wait_conditions={}}}}
  r=F.before_departure(pl,'vulcanus')
  -- 2500 ticks of flight left (42 s), 20 s at Gleba, 15000 km at 2 km a tick (125 s)
  eq(r.eta_s,math.ceil(2500/60+20+125))
  has(r.line,'flying fulgora->gleba: 5000 km left at its speed now: 42s; stops at gleba (time 20s); gleba->vulcanus 15000 km at 120 km/s (its last speed): 125s')
  local W=dofile('mod/agent-harness_0.1.0/waiteta.lua'){before_departure=function(a,b) return F.before_departure(a,b) end}
  local row=W.estimate({},{['until']='platform_arrived',platform='Tern',location='vulcanus'},false,{platform=pl,leg=F.leg(pl)},{})
  eq(row.eta_s,r.eta_s); has(row.line,'through its schedule: flying fulgora->gleba')
  -- cargo {incoming}: the platforms headed for vulcanus, with the ETA and the hub's cargo.
  local hubinv={get_contents=function() return {{name='tungsten-plate',count=400,quality='normal'},{name='calcite',count=900,quality='normal'}} end}
  pl.hub={valid=true,get_inventory=function() return hubinv end}
  local stay={valid=true,index=5,name='Petrel',hub={valid=true,get_inventory=function() return hubinv end},space_location={name='vulcanus'},state=1,
    schedule={current=1,records={{station='vulcanus'}}}}
  local rows=F.headed({platforms={pl,stay}},'vulcanus',8)
  eq(#rows,1,'a platform at the planet now is not headed for it'); eq(rows[1].platform,'Tern'); eq(rows[1].eta_s,r.eta_s)
  has(rows[1].line,'Tern (flying fulgora->gleba 67%): ETA '); has(rows[1].line,'hub: calcite*900 tungsten-plate*400')
end
print('d15_batch5 C4 arrival through the schedule: ok')

-- D4 (Astra, Sol): rotate takes platform= and surface= (remote view). ----------------------------------------------------
do
  local bots=dofile('mod/agent-harness_0.1.0/bots.lua')
  local list=type(bots)=='function' and bots{} or bots
  local on_platform,on_surface=false,false
  for _,n in ipairs(list.PLATFORM_ACTIONS) do if n=='rotate' then on_platform=true end end
  for _,n in ipairs(list.SURFACE_ACTIONS) do if n=='rotate' then on_surface=true end end
  assert(on_platform and on_surface,'rotate with platform= and surface=')
end
print('d15_batch5 D4 rotate by remote view: ok')

-- D2 (Sol, Astra): an empty platform turret that takes ammo the hub holds: where it is and what feeds it. -------------
do
  prototypes={item={rocket={type='ammo',ammo_category={name='rocket'}},['firearm-magazine']={type='ammo',ammo_category={name='bullet'}}}}
  local surface={}
  local force={name='player'}
  local turret={valid=true,name='rocket-turret',position={x=-14.5,y=-16.5},surface=surface,force=force,prototype={attack_parameters={ammo_categories={'rocket'}}}}
  local asm={valid=true,name='assembling-machine-2',type='assembling-machine',position={x=-14.5,y=-20.5},
    get_output_inventory=function() return {get_contents=function() return {} end} end}
  local chest={valid=true,name='iron-chest',position={x=-11.5,y=-20.5}}
  local arm={valid=true,name='long-handed-inserter',position={x=-14.5,y=-18.5},drop_target=turret,pickup_target=asm}
  local rival={valid=true,name='fast-inserter',position={x=-12.5,y=-20.5},drop_target=chest,pickup_target=asm}
  surface.find_entities_filtered=function(f) if f.type=='inserter' then return {arm,rival} end return {} end
  local P=dofile('mod/agent-harness_0.1.0/platalerts.lua'){state=function() return {} end}
  local rows=P.empty_turrets({},{empty_list={turret},hub_ammo={rocket=250,['firearm-magazine']=900}})
  eq(#rows,1)
  eq(rows[1],'rocket-turret (-14.5,-16.5) is empty while the hub holds rocket*250 it takes: fed by long-handed-inserter (-14.5,-18.5) from assembling-machine-2 (-14.5,-20.5) holding 0 of its ammo; taking from it too: fast-inserter (-12.5,-20.5) into iron-chest (-11.5,-20.5)')
  eq(#P.empty_turrets({},{empty_list={turret},hub_ammo={['firearm-magazine']=900}}),0,'the hub holds none it takes')
  arm.drop_target=nil
  has(P.empty_turrets({},{empty_list={turret},hub_ammo={rocket=5}})[1],'no inserter drops into it')
end
print('d15_batch5 D2 empty platform turrets: ok')

-- D3 (Sol): platform_plan: foundation islands, belt loops, head-on belts, side-loads (built and ghosts). ----------------
do
  local tiles={}
  for x=-2,1 do for y=-2,1 do tiles[#tiles+1]={position={x=x,y=y}} end end
  local ghost_tiles={}
  for x=10,12 do ghost_tiles[#ghost_tiles+1]={position={x=x+0.5,y=0.5},ghost_name='space-platform-foundation'} end
  local belts={}
  local function belt(x,y,dir,ghost) local e={position={x=x+0.5,y=y+0.5},direction=dir}
    if ghost then e.type='entity-ghost'; e.ghost_type='transport-belt'; e.ghost_name='transport-belt' else e.type='transport-belt'; e.name='transport-belt' end
    belts[#belts+1]=e end
  -- a closed 2x2 loop: (0,0) east, (1,0) south, (1,1) west, (0,1) north
  belt(0,0,4); belt(1,0,8); belt(1,1,12,true); belt(0,1,0)
  -- head on: (5,0) east into (6,0) west
  belt(5,0,4); belt(6,0,12)
  -- a side-load: (8,0)->(8,1) south... a line (8,2) east fed from behind by (7,2) east, and from the side by (8,1) south
  belt(7,2,4); belt(8,2,4); belt(8,1,8)
  -- a curve: (3,5) south into (3,6) east with nothing behind (3,6): no side-load
  belt(3,5,8); belt(3,6,4)
  local s={find_tiles_filtered=function() return tiles end,
    find_entities_filtered=function(f)
      if f.type=='tile-ghost' then return ghost_tiles end
      if f.type=='entity-ghost' then local o={} for _,b in ipairs(belts) do if b.type=='entity-ghost' then o[#o+1]=b end end return o end
      local o={} for _,b in ipairs(belts) do if b.type~='entity-ghost' then o[#o+1]=b end end return o
    end,count_entities_filtered=function() return 0 end}
  local pl={name='Petrel',surface=s,hub={valid=true,position={x=0,y=0}},force='player'}
  local P=dofile('mod/agent-harness_0.1.0/platplan.lua'){platform=function() return pl end}
  local r=P.read({},{platform='Petrel'})
  eq(r.foundation_tiles,19); eq(r.hub_group,16); eq(#r.islands,1); eq(r.islands[1].size,3); eq(r.islands[1].ghost_tiles,3)
  eq(#r.loops,1); eq(r.loops[1].belts,4); eq(r.loops[1].ghosts,1); eq(r.loops[1].exits,0)
  eq(#r.head_on,1); has(r.head_on[1],'run head on into each other')
  eq(#r.side_loads,1); eq(r.side_loads[1],'transport-belt (8.5,1.5) feeds the side of transport-belt (8.5,2.5)')
end
print('d15_batch5 D3 platform_plan: ok')

-- D1 (Sol, Astra): platform_supply: the chain in order, the first stop named. -------------------------------------------
do
  defines={entity_status={working=1,item_ingredient_shortage=2,full_output=3},inventory={asteroid_collector_output=1,crafter_input=2,crafter_output=3,turret_ammo=4,hub_main=5}}
  prototypes={item={rocket={type='ammo'}},tile={}}
  local empty={get_contents=function() return {} end,get_item_count=function() return 0 end}
  local s={}
  local col={valid=true,name='asteroid-collector',position={x=-0.5,y=-40.5},status=1,filter_slot_count=1,get_filter=function() return 'metallic-asteroid-chunk' end,
    bounding_box={left_top={x=-2,y=-42},right_bottom={x=1,y=-39}},get_inventory=function() return empty end}
  local crusher={valid=true,name='crusher',position={x=-6,y=-2.5},status=2,get_recipe=function() return {name='metallic-asteroid-crushing'} end,
    prototype={crafting_categories={crushing=true}},get_inventory=function() return empty end}
  local arm={valid=true,name='fast-inserter',position={x=-0.5,y=-38.5},pickup_target=col,drop_target={valid=true,name='transport-belt',position={x=-0.5,y=-37.5}}}
  s.find_entities_filtered=function(f)
    if f.type=='asteroid-collector' then return {col} elseif f.type=='assembling-machine' then return {crusher}
    elseif f.type=='inserter' then return {arm} end
    return {}
  end
  local pl={name='Petrel',surface=s,force='player',hub={valid=true,get_inventory=function() return {get_contents=function() return {{name='rocket',count=250}} end} end}}
  local P=dofile('mod/agent-harness_0.1.0/platsupply.lua'){platform=function() return pl end}
  local r=P.read({},{platform='Petrel'})
  eq(r.first_stop,'crusher (-6,-2.5) metallic-asteroid-crushing: item_ingredient_shortage; in empty, out empty')
  eq(r.lines[1],'first stop: '..r.first_stop)
  has(r.lines[3],'collector (-0.5,-40.5): working; holds empty; filters metallic-asteroid-chunk; taken by fast-inserter (-0.5,-38.5) into transport-belt (-0.5,-37.5)')
  has(table.concat(r.lines,'|'),'0 guns, 0 empty; the hub holds rocket*250')
end
print('d15_batch5 D1 platform_supply: ok')

-- E1 (Opus 00:21): a pole loss that leaves machines with no power wakes agents on that surface (urgent). ----------------
do
  game={tick=5000}
  local st={powercut={cuts={{id=104,tick=4700,checked=5000,surface='nauvis',net=2,poles={{name='small-electric-pole',position={x=-104.5,y=-160.5},by='medium-spitter'}},
    parts={{id=2,cut=false,kw=900},{id=928,cut=true,total=9}}}}}}
  local U=dofile('mod/agent-harness_0.1.0/urgent.lua'){state=function() return st end,who=function(p) return p.name end,
    cut_line=function(c) return 'power cut #'..c.id..': small-electric-pole (-104.5,-160.5) destroyed by medium-spitter; #928 had no power: 9 machines' end,
    cut_fixed=function() return false end}
  local opus={index=4,name='opus',surface={name='nauvis'},character={valid=true,position={x=0,y=0}}}
  local line=U.check(opus,{tick=4000})
  eq(line,'power cut #104: small-electric-pole (-104.5,-160.5) destroyed by medium-spitter; #928 had no power: 9 machines')
  eq(U.check(opus,{tick=4000}),nil,'told once')
  local far={index=5,name='sol',surface={name='aquilo'},character={valid=true,position={x=0,y=0}}}
  eq(U.check(far,{tick=4000}),nil,'another surface')
  local near={index=6,name='luna',surface={name='nauvis'},character={valid=true,position={x=0,y=0}}}
  eq(U.check(near,{tick=4000,radius=40}),nil,'outside a wait\'s radius')
  st.powercut.cuts[1].parts[2].total=2
  local grok={index=7,name='grok',surface={name='nauvis'},character={valid=true,position={x=0,y=0}}}
  eq(U.check(grok,{tick=4000}),nil,'under 3 machines')
end
print('d15_batch5 E1 power cut wakes: ok')

-- E3 (Opus, twice): the boilers' fuel drills on the power those boilers make, short of it. -----------------------------
do
  defines={entity_status={working=1,low_power=2,no_power=3}}
  local function drill(x,status,net,ore) return {valid=true,position={x=x,y=0},status=status,electric_network_id=net,mining_target={name=ore}} end
  local list={drill(1,2,7,'coal'),drill(2,2,7,'coal'),drill(3,1,7,'coal'),drill(4,2,9,'coal'),drill(5,2,7,'iron-ore')}
  local surface={find_entities_filtered=function() return list end}
  local N=dofile('mod/agent-harness_0.1.0/networks.lua'){state=function() return {} end}
  eq(N.spiral(surface,'player',{x=0,y=0},7,{'coal'}),'3 electric drills mining coal within 160 tiles run on this network: 2 on low power, 0 on no power, 1 other; the fuel these boilers burn comes from machines their power runs')
  list[1].status=1; list[2].status=1
  eq(N.spiral(surface,'player',{x=0,y=0},7,{'coal'}),nil,'none short of power')
end
print('d15_batch5 E3 boiler fuel spiral: ok')

-- F1 (Opus, twice): enemy groups seen now are hazards a walk plans round, where they are and ahead of them. ------------
do
  game={tick=100}
  local visible=true
  game.forces={player={name='player',players={{}},is_chunk_visible=function() return visible end},enemy={name='enemy',players={}}}
  local grp={valid=true,position={x=100,y=0},members={1,2,3,4,5,6}}
  local st={live_groups={{id=7,group=grp,surface='nauvis',target={x=100,y=200}}}}
  local A=dofile('mod/agent-harness_0.1.0/avoid.lua'){state=function() return st end,charted=function() return true end}
  local surface={name='nauvis',index=1}
  local discs=A.attack_discs(surface,{attacks=true,pad=4})
  eq(#discs,2); eq(discs[1].group,true); eq(discs[1].name,'enemy group of 6 heading for (100,200)')
  eq(discs[2].y,48,'a disc 48 tiles ahead toward its target'); has(discs[2].name,'(ahead of it)')
  local id=discs[1].id
  grp.position={x=100,y=40}
  eq(A.attack_discs(surface,{attacks=true,pad=4})[1].id~=id,true,'a new name once it moved a chunk on: planned again')
  visible=false
  eq(#A.attack_discs(surface,{attacks=true,pad=4}),0,'a group no player force sees now is no hazard')
  visible=true; grp.valid=false
  eq(#A.attack_discs(surface,{attacks=true,pad=4}),0,'a group gone')
end
print('d15_batch5 F1 enemy groups on the way: ok')
