-- d17 batch31 (the agents' 06:20 poll). Run from the harness root: lua tests/d17_batch31.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,msg) assert(a==b,(msg or '')..' '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end

-- A1 (Sonnet, Opus): bottleneck {item, chain: true}: each link's makers, rates now and at full speed, its ask and stock,
-- and the link the shortage comes down to. ------------------------------------------------------------------------
do
  game={tick=36000}
  defines={flow_precision_index={ten_minutes=1}}
  prototypes={item={['plastic-bar']={},coal={}},fluid={['petroleum-gas']={},['crude-oil']={}},
    recipe={['plastic-bar']={energy=1,ingredients={{name='petroleum-gas',amount=20},{name='coal',amount=1}},products={{name='plastic-bar',amount=2}}},
      ['basic-oil-processing']={energy=5,ingredients={{name='crude-oil',amount=100}},products={{name='petroleum-gas',amount=45}}}},
    entity={['crude-oil']={infinite_resource=true,normal_resource_amount=300000,mineable_properties={mining_time=1,products={{name='crude-oil',amount=10}}}},
      coal={mineable_properties={mining_time=1,products={{name='coal',amount=1}}}}}}
  local force={name='player',recipes={},logistic_networks={nauvis={{get_item_count=function(n) return n=='coal' and 40 or 0 end}}}}
  local made={['plastic-bar']=100,['petroleum-gas']=1000,['crude-oil']=1200,coal=120}
  local stats={get_flow_count=function(f) return (f.category=='input' and made[f.name] or 0)*10 end}
  force.get_item_production_statistics=function() return stats end
  force.get_fluid_production_statistics=function() return stats end
  local function m(name,st,extra)
    local e={valid=true,force=force,name=name,st=st,crafting_speed=1,productivity_bonus=0,speed_bonus=0,prototype={mining_speed=extra and extra.ms or 1}}
    if extra then for k,v in pairs(extra) do e[k]=v end end
    return e
  end
  local plants={m('chemical-plant','fluid_ingredient_shortage'),m('chemical-plant','fluid_ingredient_shortage')}
  local refs={m('oil-refinery','fluid_ingredient_shortage'),m('oil-refinery','fluid_ingredient_shortage'),m('oil-refinery','working')}
  local jacks={}
  for i=1,4 do jacks[i]=m('pumpjack','working',{mining_target={amount=150000}}) end
  local drill=m('electric-mining-drill','working',{ms=0.5})
  local census={n=10,craft={['plastic-bar']=plants,['basic-oil-processing']=refs},mine={['crude-oil']=jacks,coal={drill}},pump={}}
  local C=dofile('mod/agent-harness_0.1.0/chain.lua'){makers=function() return census,30000 end,status_name=function(e) return e.st end}
  local r=C.read({force=force},{item='plastic-bar'},{name='nauvis',index=1})
  eq(#r.links,4)
  has(r.lines[1],'plastic-bar: 2 chemical-plant on plastic-bar (2 fluid_ingredient_shortage); made 100/min now (used 0/min), 240/min at full speed')
  has(r.lines[2],'petroleum-gas: 3 oil-refinery on basic-oil-processing (2 fluid_ingredient_shortage, 1 working); made 1000/min now (used 0/min), 1620/min at full speed; asked 2400/min at full speed by plastic-bar 2400/min')
  has(r.lines[3],'coal: 1 electric-mining-drill on coal (1 working); made 120/min now (used 0/min), 30/min at full speed; asked 120/min at full speed by plastic-bar 120/min; logistic networks hold 40')
  has(r.lines[4],'crude-oil: 4 pumpjack on crude-oil (4 working); made 1200/min now (used 0/min), 1200/min at full speed; asked 3600/min at full speed by basic-oil-processing 3600/min')
  -- plastic's ingredient below its ask is petroleum-gas (1000 of 2400; coal 120 of 120 is not), whose is crude-oil
  eq(r.limit.item,'crude-oil')
  eq(r.limit_line,'limit: crude-oil: made 1200/min now, below the 3600/min asked at full speed (basic-oil-processing 3600/min), 1200/min at full speed; 4 of the 4 read working; full speed 1200/min is below the ask')
  has(r.as_of,'began 100s ago')
  -- the refineries out of power: the limit stops at them, with their state
  for _,e in ipairs(refs) do e.st='no_power' end
  made['crude-oil']=4000
  r=C.read({force=force},{item='plastic-bar'},{name='nauvis',index=1})
  eq(r.limit.item,'petroleum-gas')
  has(r.limit_line,'3 of the 3 read lack power or fuel')
  -- the refineries' output full and the pumpjacks' too: the limit is the refineries, not the crude below them
  for _,e in ipairs(refs) do e.st='full_output' end
  for _,e in ipairs(jacks) do e.st='waiting_for_space_in_destination' end
  made['crude-oil']=1200
  r=C.read({force=force},{item='plastic-bar'},{name='nauvis',index=1})
  eq(r.limit.item,'petroleum-gas')
  has(r.limit_line,'3 of the 3 read have their output full')
  -- no census pass yet
  local C2=dofile('mod/agent-harness_0.1.0/chain.lua'){makers=function() return nil end,status_name=function(e) return e.st end}
  has(C2.read({force=force},{item='plastic-bar'},{name='nauvis',index=1}).line,'no census pass has listed the machines by recipe')
end
print('d17_batch31 A1 chain: ok')

-- B3 (Astra; Nick 07:10: the game's red overlay when placing a railgun): the entities of ours a railgun's shots cross
-- within its arc, from the prototypes (turn_range 0.2 of a turn, range 40; railgun-ammo a line 50 long, 1 wide, from
-- 3.6 tiles out). -------------------------------------------------------------------------------------------------
do
  local ammo={get_ammo_type=function() return {action={{type='line',range=50,width=1}}} end,ammo_category={name='railgun'}}
  prototypes={entity={['railgun-turret']={attack_parameters={turn_range=0.2,range=40,min_range=3.5,projectile_creation_distance=3.6,ammo_categories={'railgun'}}},
    ['gun-turret']={attack_parameters={range=18,ammo_categories={'bullet'}}}},
    get_item_filtered=function() return {['railgun-ammo']=ammo} end}
  local function ent(name,x,y,extra)
    local e={valid=true,name=name,type=extra and extra.type or 'transport-belt',position={x=x,y=y},is_entity_with_health=true,
      bounding_box={left_top={x=x-0.5,y=y-0.5},right_bottom={x=x+0.5,y=y+0.5}}}
    if extra then for k,v in pairs(extra) do e[k]=v end end
    return e
  end
  local list={ent('transport-belt',0.5,-20.5),ent('transport-belt',0.5,-60.5),ent('transport-belt',20.5,-20.5),ent('pipe',10.5,-20.5,{type='pipe'}),
    ent('steel-chest',0.5,10.5,{type='container'}),ent('transport-belt',2.5,-1.5),ent('entity-ghost',0.5,-30.5,{type='entity-ghost',ghost_name='transport-belt',is_entity_with_health=false}),
    ent('railgun-turret',0,0,{type='ammo-turret',bounding_box={left_top={x=-1.5,y=-2.5},right_bottom={x=1.5,y=2.5}}})}
  local surface={find_entities_filtered=function() return list end}
  local F=dofile('mod/agent-harness_0.1.0/fireline.lua'){}
  eq(F.arc('gun-turret'),nil,'a gun turret aims all round')
  local r=F.hits(surface,{},'railgun-turret',{x=0,y=0},0)
  eq(r.hit,2)
  eq(r.line,'railgun-turret (0,0) facing north aims within 36 degrees of its facing (72 in all) at targets up to 40 tiles; its shots (railgun-ammo: a line 1 wide to 53.6 tiles from its centre) hit 2 of ours: 1 pipe (10.5,-20.5), 1 transport-belt (0.5,-20.5); 1 ghosts of ours there, hit once built: 1 transport-belt (0.5,-30.5)')
  r=F.hits(surface,{},'railgun-turret',{x=0,y=0},8)
  has(r.line,'facing south')
  has(r.line,'hit 1 of ours: 1 steel-chest (0.5,10.5)')
  -- facing east, a shot at 72 degrees from 3.6 tiles out crosses the belt at (2.5,-1.5); a wider look finds nothing else
  r=F.hits(surface,{},'railgun-turret',{x=0,y=0},4)
  has(r.line,'hit 1 of ours: 1 transport-belt (2.5,-1.5)')
  r=F.hits(surface,{},'railgun-turret',{x=0,y=0},12)
  has(r.line,'none of ours')
end
print('d17_batch31 B3 line of fire: ok')

-- B2 (Luna): platform_schedule {platform, next: true}: the game's go to station on the stop after the current one. ------
do
  defines={space_platform_state={waiting_at_station=4,on_the_path=3,no_schedule=1,paused=7},inventory={hub_main=1,hub_trash=2}}
  prototypes={space_location={nauvis={},gleba={}}}
  local recs={{station='nauvis'},{station='gleba'}}
  local cur=1
  local sch={get_record_count=function() return #recs end}
  setmetatable(sch,{__index=function(_,k) if k=='current' then return cur end end})
  local pl={valid=true,name='Spindle',state=4,space_location={name='nauvis'},get_schedule=function() return sch end}
  sch.go_to_station=function(i) cur=i; pl.state=3; pl.space_location=nil; pl.space_connection={} end
  setmetatable(pl,{__index=function(_,k) if k=='schedule' then return {current=cur,records=recs} end end})
  local p={force={platforms={pl}}}
  local space=dofile('mod/agent-harness_0.1.0/space.lua'){state=function() return {} end,
    integer=function(v,d) return v==nil and d or v end,freight={where=function() return {} end,leg=function() return nil end}}
  local r=space.platform_schedule(p,{platform='Spindle',next=true})
  eq(r.sent_to,'from stop 1 (nauvis) to stop 2 (gleba): go to station called (it was waiting at nauvis)')
  eq(cur,2)
  eq(r.schedule,'nauvis | >gleba')
  local ok,err=pcall(space.platform_schedule,p,{platform='Spindle',next=true,current=1})
  assert(not ok and tostring(err):find('next goes alone',1,true),tostring(err))
  -- flying to stop 2: next is stop 1 again
  r=space.platform_schedule(p,{platform='Spindle',next=true})
  has(r.sent_to,'from stop 2 (gleba) to stop 1 (nauvis)')
  has(r.sent_to,'it was flying to stop 2 (gleba)')
end
print('d17_batch31 B2 platform_schedule next: ok')

-- B9 (Astra 07:33, Luna 07:50): a count wait needs its condition and takes no other fields; the game's fluid_count on a
-- platform is noted with what world n showed; harness: true keeps it in the harness, which reads the tanks and sends
-- the platform on. ----------------------------------------------------------------------------------------------------
do
  defines={space_platform_state={waiting_at_station=4,on_the_path=3,no_schedule=1,paused=7},inventory={hub_main=1,hub_trash=2},
    wire_connector_id={circuit_red=1,circuit_green=2}}
  prototypes={space_location={nauvis={},gleba={}},fluid={['thruster-fuel']={}},item={['firearm-magazine']={}}}
  local tank=0
  local hubinv={get_item_count=function() return 700 end}
  local pl={valid=true,name='Spindle',index=3,state=4,space_location={name='nauvis'},force={},paused=false,
    hub={valid=true,get_circuit_network=function() return nil end,get_inventory=function() return hubinv end},
    surface={find_entities_filtered=function() return {{get_fluid_count=function() return tank end}} end}}
  local sch={}
  setmetatable(sch,{__index=function(_,k) if k=='current' then return pl.schedule and pl.schedule.current end end})
  sch.get_record_count=function() return #pl.schedule.records end
  sch.go_to_station=function(i) pl.schedule.current=i end
  pl.get_schedule=function() return sch end
  local p={force={platforms={pl}}}
  local st={}
  local W=dofile('mod/agent-harness_0.1.0/platwait.lua'){state=function() return st end}
  game={tick=600,forces={player={platforms={pl}}}}
  local function cond(c)
    local name,cmp,v=c:match('^(%S+) (%S+) (%d+)$')
    return {first_signal={type=prototypes.fluid[name] and 'fluid' or 'item',name=name},comparator=cmp=='>=' and '≥' or cmp,constant=tonumber(v)}
  end
  local space=dofile('mod/agent-harness_0.1.0/space.lua'){state=function() return st end,platwait=function() return W end,
    circuit_condition=function(c) return type(c)=='string' and cond(c) or c end,
    integer=function(v,d) return v==nil and d or v end,freight={where=function() return {} end,leg=function() return nil end}}
  local function fails(a,text) local ok,err=pcall(space.platform_schedule,p,a); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
  -- Luna's forms: read as the condition and the ticks, said in read_as; other fields refused
  local r0=space.platform_schedule(p,{platform='Spindle',stops={{station='nauvis',wait={{type='fluid_count',fluid='thruster-fuel',count=24000},{type='time',seconds=100,compare='and'}}},{station='gleba'}},current=2})
  eq(r0.read_as[1],'stop 1 wait 1: fluid_count thruster-fuel count 24000 read as condition "thruster-fuel >= 24000"')
  eq(r0.read_as[2],'stop 1 wait 2: seconds 100 read as ticks 6000')
  eq(pl.schedule.records[1].wait_conditions[1].condition.constant,24000)
  eq(pl.schedule.records[1].wait_conditions[2].ticks,6000)
  fails({platform='Spindle',stops={{station='nauvis',wait={{type='item_count',item='firearm-magazine',count=400,op='or',surface='gleba'}}}}},
    'stop 1 wait 1: op, surface are not wait fields (a wait takes type, ticks, condition, compare, harness)')
  fails({platform='Spindle',stops={{station='nauvis',wait={{type='item_count'}}}}},'item_count needs a condition')
  fails({platform='Spindle',stops={{station='nauvis',wait={{type='time',ticks=60,harness=true}}}}},'harness: true goes with a fluid_count wait')
  -- the game's fluid_count: the note
  local r=space.platform_schedule(p,{platform='Spindle',stops={{station='nauvis',wait={{type='fluid_count',condition='thruster-fuel >= 24000'}}},{station='gleba'}},current=2})
  has(r.fluid_count_note,'did not hold while its storage tanks held more')
  eq(r.waits_run[1],"stop 1 (nauvis) fluid_count thruster-fuel >= 24000: the game's condition")
  eq(W.get('Spindle'),nil)
  -- harness: the record holds time 10 s, the hub's item_count and the never condition; the harness holds the tanks
  r=space.platform_schedule(p,{platform='Spindle',current=1,stops={{station='nauvis',wait={{type='time',ticks=600},
    {type='fluid_count',condition='thruster-fuel >= 24000',harness=true,compare='and'},{type='item_count',condition='firearm-magazine >= 700',compare='and'}}},{station='gleba'}}})
  eq(r.fluid_count_note,nil)
  local rec=pl.schedule.records[1].wait_conditions
  eq(#rec,3); eq(rec[1].type,'time'); eq(rec[2].type,'item_count'); eq(rec[3].type,'circuit'); eq(rec[3].condition.constant,-2147483648)
  has(r.waits_run[1],'stop 1 (nauvis) fluid_count thruster-fuel >= 24000: the harness (the sum in its storage tanks')
  has(r.waits_run[2],'never holds, so the game does not send it on')
  eq(r.schedule,'>nauvis (time 10s and item_count firearm-magazine >= 700 and the harness sends it on) | gleba')
  pl.schedule.current=1
  W.tick(600)
  has(W.line('Spindle'),'now waits at stop 1 (nauvis): time 10s: 10s left (not yet); thruster-fuel >= 24000: tanks hold 0 (0 tanks) (not yet); firearm-magazine >= 700: the hub holds 700')
  tank=25000
  W.tick(1200)
  eq(pl.schedule.current,2,'sent on once the tanks and the time hold')
  has(W.line('Spindle'),'last: tick 1200: sent from stop 1 (nauvis) for stop 2 (gleba): time 10s: passed; thruster-fuel >= 24000: tanks hold 25000 (1 tank)')
  -- a stop with an inactivity wait cannot be mirrored
  fails({platform='Spindle',stops={{station='nauvis',wait={{type='inactivity',ticks=600},{type='fluid_count',condition='thruster-fuel >= 24000',harness=true,compare='and'}}}}},
    'harness waits go with time and item_count waits joined by and')
  -- a schedule without harness waits clears the watch
  space.platform_schedule(p,{platform='Spindle',stops={{station='gleba'}}})
  eq(W.get('Spindle'),nil)
end
print('d17_batch31 B9 platform fluid_count: ok')

-- B1 (Luna 06:20): shipment {platform, ready: true}: the platform's gate, the requests from the planet it stops at,
-- each silo there with its rocket, why it waits and the conditions on its feed, and the landing pads' free slots
-- against what the hub would send down. ---------------------------------------------------------------------------
do
  defines={inventory={rocket_silo_rocket=9,cargo_landing_pad_main=1,hub_main=1},wire_connector_id={circuit_red=1,circuit_green=2},
    space_platform_state={waiting_at_station=4,on_the_path=3}}
  prototypes={item={['iron-plate']={stack_size=100},['processing-unit']={stack_size=100},['space-platform-foundation']={stack_size=50}}}
  local force={}
  local silo={valid=true,force=force,name='rocket-silo',position={x=10.5,y=-20.5},bounding_box={left_top={x=6,y=-25},right_bottom={x=15,y=-16}},
    use_transitional_requests=true,transitional_request_target={valid=true,name='Spindle'},get_inventory=function() return {get_contents=function() return {{name='space-platform-foundation',count=30}} end} end,
    get_logistic_point=function() return nil end}
  local ins={valid=true,name='bulk-inserter',position={x=5.5,y=-20.5}}
  local padinv={count_empty_stacks=function() return 2 end,get_insertable_count=function(n) return n=='processing-unit' and 150 or 0 end,
    get_contents=function() return {{name='processing-unit',count=100}} end}
  setmetatable(padinv,{__len=function() return 80 end})
  local padsec={active=true,filters={{value={name='processing-unit'},min=500},{value={name='iron-plate'},min=1000}}}
  local pad={valid=true,type='cargo-landing-pad',force=force,name='cargo-landing-pad',position={x=0,y=0},get_inventory=function() return padinv end,
    get_logistic_sections=function() return {sections_count=1,get_section=function() return padsec end} end}
  silo.type='rocket-silo'
  local finds=0
  local nauvis_s={index=1,name='nauvis',find_entities_filtered=function(f)
    if type(f.type)=='table' and f.type[1]=='rocket-silo' then finds=finds+1; return {silo,pad} end
    return {ins}
  end}
  silo.surface=nauvis_s
  game={tick=1000,planets={nauvis={surface=nauvis_s}}}
  local sec={active=true,filters={{value={name='space-platform-foundation'},min=50,import_from='nauvis'},{value={name='iron-plate'},min=100,import_from='nauvis'}}}
  local pl={valid=true,name='Spindle',index=3,force=force,hub={valid=true,get_logistic_sections=function() return {sections_count=1,get_section=function() return sec end} end},
    schedule={current=1,records={{station='nauvis'},{station='gleba'}}}}
  local p={force={platforms={pl}}}
  local sst={}
  local S=dofile('mod/agent-harness_0.1.0/shipment.lua'){state=function() return sst end,
    hub_counts=function() return {['iron-plate']=100,['processing-unit']=400,['space-platform-foundation']=0} end,
    where=function() return {at='nauvis',stopped=true,text='at nauvis'} end,
    request_rows=function(e,f,only) eq(only,'Spindle'); return {{platform='Spindle',item='space-platform-foundation',line='below_min_payload: Spindle asks space-platform-foundation 50 (holds 0, lacks 50), min payload 50'}} end,
    gate=function() return {lines={'Spindle: at station nauvis; stop 1 of 2: nauvis (waiting here): circuit thruster-fuel >= 24000: the hub\'s wires read thruster-fuel 25000 (met)'}} end,
    gate_row=function(e) return {name=e.name,position=e.position,met=false,line='bulk-inserter (5.5,-20.5): circuit condition space-platform-foundation < 20 (space-platform-foundation 40 on its wires): false now'} end,
    rocket=function() return {rocket_now='rocket built (50/50 parts) and ready to launch, not launched',rocket_ready=true} end}
  local r=S.read(p,{platform='Spindle',ready=true})
  eq(r.planet,'nauvis')
  has(r.lines[1],"gate: Spindle: at station nauvis; stop 1 of 2: nauvis (waiting here): circuit thruster-fuel >= 24000: the hub's wires read thruster-fuel 25000 (met)")
  eq(r.lines[2],'stopped at nauvis')
  has(r.lines[3],'up from nauvis: space-platform-foundation 50 from nauvis: loading (rocket-silo at (11,-20): 30 in its rocket, automatic requests for this platform; the hub holds 0); 1 more delivered')
  has(r.lines[4],'silo rocket-silo (11,-20): rocket built (50/50 parts) and ready to launch, not launched; automatic requests on, filling a rocket for Spindle; its rocket holds space-platform-foundation*30; Spindle asks nauvis for what it lacks: below_min_payload: Spindle asks space-platform-foundation 50 (holds 0, lacks 50), min payload 50; its rocket holds 30 of it')
  has(r.lines[4],'conditions within 8 tiles: bulk-inserter (5.5,-20.5): circuit condition space-platform-foundation < 20 (space-platform-foundation 40 on its wires): false now')
  -- the hub keeps its own 100 iron plates (its request); 400 processing units go down: 4 slots, 2 free, the pads take 150
  eq(r.lines[5],'landing pads on nauvis: cargo-landing-pad (0,0) 2 free slots of 80; the hub would send down processing-unit 400 (pads ask 500, hold 100; 4 slots; the pads can take 150 of it now, 250 short): 4 slots in all, 2 free (fewer)')
  eq(r.down[1].pads_take,150); eq(r.pad_free_slots,2); eq(r.silos[1].rocket_ready,true)
  -- the silos and pads are searched for once a minute
  S.read(p,{platform='Spindle',ready=true}); eq(finds,1)
  local ok,err=pcall(S.read,p,{platform='Spindle',ready=true,item='iron-plate'})
  assert(not ok and tostring(err):find('ready takes platform',1,true),tostring(err))
end
print('d17_batch31 B1 shipment ready: ok')
-- B1: a circuit wait at the stop the platform waits at reads what the hub's wires hold
do
  defines={space_platform_state={waiting_at_station=4,on_the_path=3},inventory={hub_main=1},wire_connector_id={circuit_red=1,circuit_green=2}}
  game={tick=100}
  local net={get_signal=function(s) return s.name=='thruster-fuel' and 25000 or 0 end}
  local pl={valid=true,name='Cinder',index=2,state=4,space_location={name='gleba'},paused=false,
    hub={valid=true,get_circuit_network=function(id) return id==1 and net or nil end},
    schedule={current=1,records={{station='gleba',wait_conditions={{type='circuit',condition={first_signal={type='fluid',name='thruster-fuel'},comparator='≥',constant=22000}}}},{station='nauvis'}}}}
  local space=dofile('mod/agent-harness_0.1.0/space.lua'){state=function() return {} end,integer=function(v,d) return v==nil and d or v end,
    freight={where=function() return {} end,leg=function() return nil end}}
  local r=space.gate({force={platforms={pl}}},{platform='Cinder'})
  has(r.lines[1],"stop 1 of 2: gleba (waiting here): circuit thruster-fuel >= 22000: the hub's wires read thruster-fuel 25000 (met)")
  pl.hub.get_circuit_network=function() return nil end
  has(space.gate({force={platforms={pl}}},{platform='Cinder'}).lines[1],'circuit thruster-fuel >= 22000: the hub has no circuit wire (the condition reads 0)')
end
print('d17_batch31 B1 circuit wait value: ok')

-- B5 (Sol 06:22): platform_supply {platform, fuel: true}: from the thrusters back, each consumer's ingredients against
-- a craft through inserters, belts and pipes, and the first missing link. ---------------------------------------------
do
  defines={entity_status={working=1,item_ingredient_shortage=2,full_output=3},inventory={crafter_input=2,crafter_output=3,hub_main=1,asteroid_collector_output=4}}
  local uid=0
  local function ent(t) uid=uid+1; t.valid=true; t.unit_number=uid; t.status=t.status or 1; return t end
  local function box(list)
    -- list[i] = {fluid, kind, amount, cap, seg (own), conns = {seg ids}}
    local fb={}
    for i,b in ipairs(list) do fb[i]=b.amount>0 and {name=b.fluid,amount=b.amount} or nil end
    setmetatable(fb,{__len=function() return #list end})
    fb.get_locked_fluid=function(i) return list[i].fluid end
    fb.get_prototype=function(i) return {object_name='LuaFluidBoxPrototype',production_type=list[i].kind} end
    fb.get_capacity=function(i) return list[i].cap end
    fb.get_fluid_segment_id=function(i) return list[i].seg end
    fb.get_connections=function(i) local o={} for _,id in ipairs(list[i].conns or {}) do o[#o+1]={get_fluid_segment_id=function() return id end,owner={valid=true}} end return o end
    fb.get_fluid_segment_contents=function(i) return list[i].contents or {} end
    return fb
  end
  local function inv(t) return {get_item_count=function(n) return t[n] or 0 end} end
  local thruster=ent{type='thruster',name='thruster',position={x=0,y=20},fluidbox=box{{fluid='thruster-fuel',kind='input',amount=100,cap=1000,seg=10},{fluid='thruster-oxidizer',kind='input',amount=1000,cap=1000,seg=11}}}
  local pipe=ent{type='pipe',name='pipe',position={x=0,y=18},fluidbox=box{{fluid='thruster-fuel',amount=50,cap=100,seg=10,contents={['thruster-fuel']=50}}}}
  local fuel_recipe={name='thruster-fuel',ingredients={{type='item',name='carbon',amount=2},{type='fluid',name='water',amount=10}},products={{type='fluid',name='thruster-fuel',amount=75}}}
  local carbon_in={}
  local maker=ent{type='assembling-machine',name='chemical-plant',position={x=0,y=10},status=2,get_recipe=function() return fuel_recipe end,
    get_inventory=function(i) return i==2 and inv(carbon_in) or inv({}) end,
    fluidbox=box{{fluid='water',kind='input',amount=20,cap=100,conns={20}},{fluid='thruster-fuel',kind='output',amount=0,cap=100,conns={10}}}}
  local hub=ent{type='space-platform-hub',name='space-platform-hub',position={x=0,y=0}}
  local hubinv={}
  hub.get_inventory=function() return inv(hubinv) end
  local crusher=ent{type='assembling-machine',name='crusher',position={x=-6,y=0},status=2,
    get_recipe=function() return {name='carbonic-asteroid-crushing',ingredients={{type='item',name='carbonic-asteroid-chunk',amount=1}},products={{type='item',name='carbon',amount=10}}} end,
    get_inventory=function() return inv({}) end,fluidbox=box{}}
  local b2=ent{type='transport-belt',name='transport-belt',position={x=3.5,y=10.5}}
  local uo=ent{type='underground-belt',name='underground-belt',belt_to_ground_type='output',position={x=3.5,y=13.5}}
  local function line(n) return {get_item_count=function() return n end} end
  for _,b in ipairs({b2,uo}) do b.get_max_transport_line_index=function() return 2 end; b.get_transport_line=function() return line(0) end end
  b2.belt_neighbours={inputs={uo}}; uo.belt_neighbours={inputs={}}
  local i1=ent{type='inserter',name='inserter',position={x=1.5,y=10.5},drop_target=maker,pickup_target=b2}
  local i2=ent{type='inserter',name='inserter',position={x=-3.5,y=0.5},drop_target=hub,pickup_target=crusher}
  local tiles={}
  local s={get_tile=function(x,y) return {name=tiles[x..','..y] or 'space-platform-foundation'} end}
  s.find_entities_filtered=function(f)
    local t=type(f.type)=='table' and f.type or {f.type}
    local want={} for _,x in ipairs(t) do want[x]=true end
    local out={}
    for _,e in ipairs({thruster,pipe,maker,hub,crusher,b2,uo,i1,i2}) do if want[e.type] then out[#out+1]=e end end
    return out
  end
  local F=dofile('mod/agent-harness_0.1.0/fuelstock.lua'){}
  local r=F.trace({surface=s,force={},name='Wren'})
  eq(r.first_missing,'carbon into chemical-plant (0,10) (holds 0, a craft takes 2): underground-belt exit (3.5,13.5) has no entrance paired')
  has(r.lines[2],'thruster-fuel into 1 thruster: their boxes hold 100 of 1000 (short); the pipes it joins (1 segment) hold 50, 0 tanks on them; 1 maker there')
  has(r.lines[3],'  chemical-plant (0,10) thruster-fuel: item_ingredient_shortage')
  has(r.lines[4],'    carbon into chemical-plant (0,10): holds 0, a craft takes 2 (short); 1 inserter drop into it')
  -- its entrance paired, over empty space
  local ui=ent{type='underground-belt',name='underground-belt',belt_to_ground_type='input',position={x=3.5,y=17.5},belt_neighbours={inputs={}},
    get_max_transport_line_index=function() return 2 end,get_transport_line=function() return line(0) end}
  uo.neighbours=ui; tiles['3,15']='empty-space'
  r=F.trace({surface=s,force={},name='Wren'})
  eq(r.first_missing,'carbon into chemical-plant (0,10) (holds 0, a craft takes 2): underground-belt (3.5,17.5) to (3.5,13.5): its span is over empty space at (3,15)')
  -- from the hub instead: it holds none, the crusher that unloads into it has no chunk and nothing brings one
  i1.pickup_target=hub
  r=F.trace({surface=s,force={},name='Wren'})
  eq(r.first_missing,'no inserter drops carbonic-asteroid-chunk into crusher (-6,0) (it holds 0, a craft takes 1)')
  -- carbon at the maker and fuel in the thruster: nothing missing
  carbon_in.carbon=4; maker.status=1; thruster.fluidbox[1].amount=900
  r=F.trace({surface=s,force={},name='Wren'})
  eq(r.first_missing,nil); has(r.lines[1],'first missing link: none')
end
print('d17_batch31 B5 fuel feedstock: ok')

-- B6 (Astra 06:27) and C3 (Astra 06:31, 06:34): at a stop the hub keeps only what its requests from that planet ask;
-- from: false (or "") names no import planet and drops the slot's, and the game stores nauvis, as for a new slot. -----
do
  game={tick=0}
  defines={space_platform_state={paused=7},rocket_silo_status={},inventory={hub_main=1,hub_trash=2},cargo_destination={}}
  prototypes={item={['space-platform-foundation']={},['firearm-magazine']={}},space_location={nauvis={},fulgora={},gleba={}},quality={normal={}}}
  local slots={}
  local sec={index=1,is_manual=true,group='',active=true,filters_count=0}
  local function recount() local n=0; for i in pairs(slots) do n=math.max(n,i) end; sec.filters_count=n end
  sec.get_slot=function(i) return slots[i] or {} end
  -- the game: a hub request given no import planet is stored from nauvis
  sec.set_slot=function(i,f) local c={} for k,v in pairs(f) do c[k]=v end; c.import_from=c.import_from or 'nauvis'; slots[i]=c; recount() end
  sec.clear_slot=function(i) slots[i]=nil; recount() end
  setmetatable(sec,{__index=function(_,k) if k=='filters' then local out={}; for i=1,sec.filters_count do out[i]=slots[i] or {} end; return out end end,
    __newindex=function(t,k,v) if k=='filters' then slots={}; for i,f in ipairs(v) do slots[i]=f end; recount() else rawset(t,k,v) end end})
  local secs=setmetatable({get_section=function(i) return i==1 and sec or nil end,add_section=function() return sec end},{__index=function(_,k) if k=='sections_count' then return 1 end end})
  local held={['space-platform-foundation']=85,['firearm-magazine']=501}
  local main={get_item_count=function(n) return held[n] or 0 end,get_contents=function() return {} end}
  local platform={valid=true,name='Cinder',index=1,space_location={name='nauvis'},force='player',schedule={current=1,records={{station='nauvis'},{station='fulgora'}}},
    hub={valid=true,unit_number=78,type='space-platform-hub',position={x=0,y=0},get_logistic_sections=function() return secs end,get_inventory=function() return main end,
      get_item_count=function(n) return held[n] or 0 end}}
  local p={index=1,force={platforms={platform}}}
  local st={}
  local pads={nauvis={ask={['space-platform-foundation']=100,['firearm-magazine']=1461},hold={}},fulgora={ask={},hold={}}}
  local space=dofile('mod/agent-harness_0.1.0/space.lua'){state=function() return st end,
    integer=function(v,d,lo,hi,name) v=v==nil and d or v; assert(type(v)=='number' and v>=lo and v<=hi,name..' out of range'); return v end,
    keep=function() return {set_construction=function(_,on) return on end,construction=function() return nil end} end,
    freight={where=function() return {stopped=true,at='nauvis'} end,pads=function(planet) return pads[planet].ask,pads[planet].hold end}}
  -- C3: a new slot with no from: the game set nauvis, and stored says so
  local r=space.requests(p,{platform='Cinder',set={{item='firearm-magazine',min=500,max=2000}}})
  eq(r.stored[1],'firearm-magazine 500..2000 from nauvis (no import planet given: the game set nauvis)')
  r=space.requests(p,{platform='Cinder',set={{item='space-platform-foundation',min=50,from='fulgora'}}})
  -- B6: Cinder at Nauvis under 50..inf from fulgora: a change of that request keeps nothing at Nauvis; all 85 go down
  r=space.requests(p,{platform='Cinder',set={{item='space-platform-foundation',min=100,from='fulgora'}},dry_run=true})
  eq(r.sends_down[1],'space-platform-foundation: the hub holds 85; its requests would keep 85 at fulgora (kept 50 at fulgora): 85 down to nauvis (here) (its landing pads ask 100, hold 0)')
  has(r.sends_down_rule,'a request from another planet keeps nothing there')
  -- the magazines from nauvis: a lower min there keeps less at Nauvis, the rest goes down
  r=space.requests(p,{platform='Cinder',set={{item='firearm-magazine',min=300}},dry_run=true})
  eq(r.sends_down[1],'firearm-magazine: the hub holds 501; its requests would keep 300 at nauvis (kept 500 at nauvis): 201 down to nauvis (here) (its landing pads ask 1461, hold 0; its requests from nauvis keep 300); 300 stay aboard')
  -- C3: from false on a slot from fulgora: dropped, and the game sets nauvis
  r=space.requests(p,{platform='Cinder',set={{item='space-platform-foundation',min=50,from=false}}})
  eq(r.stored[1],'space-platform-foundation 50..inf from nauvis (no import planet given: the game set nauvis) (was space-platform-foundation 50..inf from fulgora)')
  eq(slots[2].import_from,'nauvis')
  r=space.requests(p,{platform='Cinder',set={{item='space-platform-foundation',min=50,from=''}}})
  has(r.stored[1],'(no import planet given: the game set nauvis)')
  local ok,err=pcall(space.requests,p,{platform='Cinder',set={{item='space-platform-foundation',min=50,from='mars'}}})
  assert(not ok and tostring(err):find('mars is not one',1,true),tostring(err))
  defines,prototypes,game=nil,nil,nil
end
print('d17_batch31 B6 and C3 hub keep rule, from false: ok')
-- B6 in shipment's cargo conflict lines: a request from gleba keeps its stock at the Gleba stop, nothing at Nauvis
do
  game={tick=0,planets={}}
  defines={inventory={hub_main=1}}
  local sec={active=true,filters={{value={name='processing-unit'},min=100,import_from='gleba'}}}
  local pl={valid=true,name='Spindle',index=3,force={},hub={valid=true,get_logistic_sections=function() return {sections_count=1,get_section=function() return sec end} end},
    schedule={current=1,records={{station='nauvis'},{station='gleba'}}}}
  local S=dofile('mod/agent-harness_0.1.0/shipment.lua'){state=function() return {} end,
    hub_counts=function() return {['processing-unit']=500} end,
    where=function() return {at='nauvis',stopped=true} end,
    pads=function(planet) if planet=='nauvis' then return {['processing-unit']=300},{} end return {['processing-unit']=400},{} end}
  local c=S.conflicts(pl)
  eq(c[1],'cargo conflict on Spindle: the hub holds 500 processing-unit; stop 1 nauvis (here): its pads ask 300 (hold 0), 300 go down there, 200 left aboard; stop 2 gleba: its pads ask 400 (hold 0), its requests from gleba keep 100, 100 go down there, 100 left aboard')
  game,defines=nil,nil
end
print('d17_batch31 B6 cargo conflicts by import planet: ok')

-- B8 (Luna 07:18: Spindle left Nauvis at once with 4,660 fuel when she set current 2 to change stop 1's waits):
-- platform_schedule {platform, stop, wait}: that record's waits replaced in place, the records, current and state kept;
-- an edit that makes it leave now is refused unless go: true. ---------------------------------------------------------
do
  game={tick=10000}
  defines={space_platform_state={waiting_at_station=4,on_the_path=3,no_schedule=1,paused=7},inventory={hub_main=1,hub_trash=2},wire_connector_id={circuit_red=1,circuit_green=2}}
  prototypes={space_location={nauvis={},gleba={}},fluid={['thruster-fuel']={},['thruster-oxidizer']={}},item={['firearm-magazine']={}}}
  local recs={{station='nauvis',wait_conditions={{type='time',ticks=216000}}},{station='gleba',wait_conditions={{type='time',ticks=600}}}}
  local cur,calls=1,{}
  local sch={get_record_count=function() return #recs end}
  setmetatable(sch,{__index=function(_,k) if k=='current' then return cur end end})
  sch.get_wait_condition_count=function(pos) return #(recs[pos.schedule_index].wait_conditions or {}) end
  sch.remove_wait_condition=function(pos,k) table.remove(recs[pos.schedule_index].wait_conditions,k); calls[#calls+1]='remove' end
  sch.add_wait_condition=function(pos,k,t) local w=recs[pos.schedule_index].wait_conditions or {}; recs[pos.schedule_index].wait_conditions=w; table.insert(w,k,{type=t}) end
  sch.change_wait_condition=function(pos,k,w) recs[pos.schedule_index].wait_conditions[k]=w end
  sch.set_wait_condition_mode=function(pos,k,m) recs[pos.schedule_index].wait_conditions[k].compare_type=m end
  local pl={valid=true,name='Spindle',index=3,state=4,space_location={name='nauvis'},force={},paused=false}
  sch.go_to_station=function(i) cur=i; pl.state=3 end
  pl.get_schedule=function() return sch end
  setmetatable(pl,{__index=function(_,k) if k=='schedule' then return {current=cur,records=recs} end end})
  local wires={['thruster-fuel']=4660,['thruster-oxidizer']=30000}
  local net={get_signal=function(sg) return wires[sg.name] or 0 end}
  local hubinv={get_item_count=function(n) if type(n)=='table' then if (n.quality or 'normal')~='normal' then return 0 end n=n.name end return n=='firearm-magazine' and 800 or 0 end}
  pl.hub={valid=true,get_circuit_network=function(id) return id==1 and net or nil end,get_inventory=function() return hubinv end}
  local p={force={platforms={pl}}}
  local st={platform_stops={[3]={at='nauvis',tick=4000}}}
  local W=dofile('mod/agent-harness_0.1.0/platwait.lua'){state=function() return st end}
  local function cond(c)
    local name,cmp,v=c:match('^(%S+) (%S+) (%d+)$')
    return {first_signal={type=prototypes.fluid[name] and 'fluid' or 'item',name=name},comparator=cmp=='>=' and '≥' or cmp,constant=tonumber(v)}
  end
  local space=dofile('mod/agent-harness_0.1.0/space.lua'){state=function() return st end,platwait=function() return W end,
    circuit_condition=function(c) return type(c)=='string' and cond(c) or c end,
    integer=function(v,d,lo,hi,name) v=v==nil and d or v; assert(type(v)=='number' and v>=lo and v<=hi,name..' out of range'); return v end,
    freight={where=function() return {} end,leg=function() return nil end}}
  local function fails(a,text) local ok,err=pcall(space.platform_schedule,p,a); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
  -- Luna's edit: fuel and oxidizer >= 24000 at stop 1, where it waits; fuel reads 4660 on the wires: it stays
  local r=space.platform_schedule(p,{platform='Spindle',stop=1,wait={{type='circuit',condition='thruster-fuel >= 24000'},{type='circuit',condition='thruster-oxidizer >= 24000'}}})
  eq(cur,1); eq(pl.state,4)
  eq(r.edited,'stop 1 (nauvis): 2 wait conditions set in place; the records and the current stop (1) kept; state waiting_at_station (kept)')
  eq(#recs[1].wait_conditions,2); eq(recs[1].wait_conditions[1].condition.constant,24000); eq(recs[2].wait_conditions[1].ticks,600)
  eq(r.leaves,nil)
  -- its new waits hold now: refused, then made with go
  fails({platform='Spindle',stop=1,wait={{type='item_count',condition='firearm-magazine >= 700'}}},
    'nothing changed: its new waits at stop 1 (nauvis), where it waits, hold now: item_count firearm-magazine >= 700: the hub holds 800; it leaves at once; go: true makes the edit anyway')
  eq(recs[1].wait_conditions[1].type,'circuit','refused: nothing changed')
  fails({platform='Spindle',stop=1,wait={{type='time',ticks=3600}}},'time 60s: passed')
  -- an or: one side holding is enough
  fails({platform='Spindle',stop=1,wait={{type='circuit',condition='thruster-fuel >= 24000'},{type='circuit',condition='thruster-oxidizer >= 24000',compare='or'}}},'hold now')
  fails({platform='Spindle',stop=1,wait={}},'stop 1 (nauvis), where it waits, would have no wait condition: it leaves at once')
  -- Luna's current 2: refused
  fails({platform='Spindle',stop=1,wait={{type='time',ticks=216000}},current=2},'it waits at stop 1 (nauvis) and current 2 sends it to stop 2 (gleba) at once')
  -- another stop's waits: no leaving
  r=space.platform_schedule(p,{platform='Spindle',stop=2,wait={{type='time',ticks=1200}}})
  eq(recs[2].wait_conditions[1].ticks,1200); eq(cur,1)
  -- a harness wait on stop 1: the watch holds it
  r=space.platform_schedule(p,{platform='Spindle',stop=1,wait={{type='fluid_count',condition='thruster-fuel >= 24000',harness=true}}})
  eq(recs[1].wait_conditions[1].condition.constant,-2147483648)
  has(r.harness_waits,'stop 1 (nauvis): tanks thruster-fuel >= 24000')
  -- go: true makes a leaving edit
  r=space.platform_schedule(p,{platform='Spindle',stop=1,wait={{type='item_count',condition='firearm-magazine >= 700'}},go=true})
  has(r.leaves,'hold now'); eq(recs[1].wait_conditions[1].type,'item_count')
  eq(W.get('Spindle'),nil,'the harness wait replaced: no watch left')
  defines,prototypes,game=nil,nil,nil
end
print('d17_batch31 B8 platform_schedule stop edit: ok')

-- C4 (urgent, Astra and Sol 11:09: Kestrel II at Fulgora set to [nauvis] read no_schedule, the rebuild too, and the
-- queue step said success): the state after no_schedule, no_path or paused (not asked) fails the call; one stop that
-- is not where the platform is goes as [where it is, that stop], current 2. -----------------------------------------
do
  game={tick=100}
  defines={space_platform_state={waiting_at_station=4,on_the_path=3,no_schedule=1,no_path=5,paused=7},inventory={hub_main=1,hub_trash=2},wire_connector_id={circuit_red=1,circuit_green=2}}
  prototypes={space_location={nauvis={},fulgora={}},fluid={},item={}}
  local pl={valid=true,name='Kestrel II',index=4,state=4,space_location={name='fulgora'},force={},paused=false}
  local leaves=true
  local sch={get_record_count=function() return #(pl.schedule and pl.schedule.records or {}) end}
  sch.go_to_station=function(i) if leaves then pl.state=3 else pl.state=1 end end
  sch.remove_record=function() end; sch.add_record=function() end
  pl.get_schedule=function() return sch end
  local p={force={platforms={pl}}}
  local st={}
  local space=dofile('mod/agent-harness_0.1.0/space.lua'){state=function() return st end,
    integer=function(v,d,lo,hi,name) v=v==nil and d or v; assert(type(v)=='number' and v>=lo and v<=hi,name..' out of range'); return v end,
    freight={where=function() return {} end,leg=function() return nil end}}
  local function fails(a,text) local ok,err=pcall(space.platform_schedule,p,a); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
  -- one stop, not where it is: [fulgora, nauvis], current 2, said
  local r=space.platform_schedule(p,{platform='Kestrel II',stops={{station='nauvis',wait={{type='time',ticks=600}}}},paused=false})
  eq(#pl.schedule.records,2); eq(pl.schedule.records[1].station,'fulgora'); eq(pl.schedule.records[2].station,'nauvis'); eq(pl.schedule.current,2)
  eq(pl.schedule.records[2].wait_conditions[1].ticks,600); eq(pl.schedule.records[1].wait_conditions,nil)
  has(r.one_stop,'one stop (nauvis) given while the platform is at fulgora: written as [fulgora, nauvis] with current 2')
  eq(r.state,'on_the_path')
  -- as given, and the game leaves it at no_schedule: (d18 batch38 A1) read again; still no_schedule RECHECK_TICKS later,
  -- the call fails with the rule, the schedule as set
  p.force.name='player'; game.forces={player=p.force}
  pl.state,pl.space_location,leaves=4,{name='fulgora'},false
  local function later(a, still)
    local out=space.platform_schedule(p,a)
    assert(out.recheck,'a recheck, no failure in the tick of the call')
    has(out.state_note,'read no_schedule in the tick of this call (the game updates a platform in a later tick); read again every 10 ticks for up to 300')
    local t0=game.tick
    game.tick=t0+40
    if not still then pl.state=3; local v=space.recheck_read(out.recheck); pl.state=1; game.tick=t0; return v end
    eq(space.recheck_read(out.recheck),nil)
    game.tick=t0+space.RECHECK_TICKS
    local v=space.recheck_read(out.recheck)
    game.tick=t0
    return v
  end
  local v=later({platform='Kestrel II',stops={{station='nauvis'}},one_stop='as given'},true)
  eq(v.ok,false)
  has(v.error,'Kestrel II read no_schedule at tick 100 (the call\'s tick) and still no_schedule 300 ticks later; the call failed: it reads no_schedule with 1 stop set (current 1, nauvis) while it is at ?: it has not left; seen across the journals: every one-stop schedule read no_schedule')
  eq(#pl.schedule.records,1)
  -- (A1, Cinder on shift36: next: true read no_schedule and it was flying 39 ticks later) a later read that goes on: both reads said
  v=later({platform='Kestrel II',stops={{station='nauvis'}},one_stop='as given'},false)
  eq(v.ok,true); eq(v.after_ticks,40)
  has(v.line,'Kestrel II read no_schedule at tick 100 (the call\'s tick) and on_the_path 40 ticks later')
  fails({platform='Kestrel II',stops={{station='nauvis'}},one_stop='alone'},'one_stop is "as given"')
  -- a read changes nothing and is not failed
  eq(space.platform_schedule(p,{platform='Kestrel II'}).state,'no_schedule')
  -- clearing the schedule (stops []) is not failed
  space.platform_schedule(p,{platform='Kestrel II',stops={}})
  -- paused before, not asked: fails; asked: not
  pl.state,leaves,pl.paused=4,true,true
  fails({platform='Kestrel II',stops={{station='fulgora'},{station='nauvis'}},current=2},'paused: it goes nowhere until unpaused (paused: false); it was paused before this call')
  r=space.platform_schedule(p,{platform='Kestrel II',stops={{station='fulgora'},{station='nauvis'}},current=2,paused=true})
  eq(r.paused,true)
  -- no_path after: fails
  pl.paused=false
  sch.go_to_station=function() pl.state=5 end
  local r5=space.platform_schedule(p,{platform='Kestrel II',stops={{station='fulgora'},{station='nauvis'}},current=2})
  eq(r5.recheck.first,'no_path'); game.tick=game.tick+space.RECHECK_TICKS
  has(space.recheck_read(r5.recheck).error,'no_path: it has no way from where it is to its next stop')
  -- next: true leaving it at no_schedule: read again too
  sch.go_to_station=function() pl.state=1 end
  eq(space.platform_schedule(p,{platform='Kestrel II',next=true}).recheck.first,'no_schedule')
  -- direct calls: the second read comes as a tell from platform_schedule
  local told={}
  local sp2=dofile('mod/agent-harness_0.1.0/space.lua'){state=function() return st end,deliver=function(i,t) told[#told+1]={i,t} end,
    integer=function(v,d) return v==nil and d or v end,freight={where=function() return {} end,leg=function() return nil end}}
  p.index=7
  st.schedule_rechecks=nil
  sp2.platform_schedule(p,{platform='Kestrel II',next=true})
  eq(#st.schedule_rechecks,1)
  game.tick=math.ceil(game.tick/10)*10+10; pl.state=3; sp2.recheck_tick()
  eq(#st.schedule_rechecks,0); eq(told[1][1],7); eq(told[1][2].from,'platform_schedule'); has(told[1][2].text,'and on_the_path')
  -- a queue step's recheck is the queue's: no tell
  pl.state=1
  local q=sp2.platform_schedule(p,{platform='Kestrel II',next=true}); q.recheck.queued=true
  game.tick=game.tick+10; sp2.recheck_tick(); eq(#told,1); eq(#st.schedule_rechecks,0)
  defines,prototypes,game=nil,nil,nil
end
print('d17_batch31 C4 platform_schedule fails when it goes nowhere: ok')
