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
  local r0=space.platform_schedule(p,{platform='Spindle',stops={{station='nauvis',wait={{type='fluid_count',fluid='thruster-fuel',count=24000},{type='time',seconds=100}}},{station='gleba'}},current=2})
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
    {type='fluid_count',condition='thruster-fuel >= 24000',harness=true},{type='item_count',condition='firearm-magazine >= 700'}}},{station='gleba'}}})
  eq(r.fluid_count_note,nil)
  local rec=pl.schedule.records[1].wait_conditions
  eq(#rec,3); eq(rec[1].type,'time'); eq(rec[2].type,'item_count'); eq(rec[3].type,'circuit'); eq(rec[3].condition.constant,-2147483648)
  has(r.waits_run[1],'stop 1 (nauvis) fluid_count thruster-fuel >= 24000: the harness (the sum in its storage tanks')
  has(r.waits_run[2],'never holds, so the game does not send it on')
  eq(r.schedule,'>nauvis (time 10s, item_count firearm-magazine >= 700, the harness sends it on) | gleba')
  pl.schedule.current=1
  W.tick(600)
  has(W.line('Spindle'),'now waits at stop 1 (nauvis): time 10s: 10s left (not yet); thruster-fuel >= 24000: tanks hold 0 (0 tanks) (not yet); firearm-magazine >= 700: the hub holds 700')
  tank=25000
  W.tick(1200)
  eq(pl.schedule.current,2,'sent on once the tanks and the time hold')
  has(W.line('Spindle'),'last: tick 1200: sent from stop 1 (nauvis) for stop 2 (gleba): time 10s: passed; thruster-fuel >= 24000: tanks hold 25000 (1 tank)')
  -- a stop with an inactivity wait cannot be mirrored
  fails({platform='Spindle',stops={{station='nauvis',wait={{type='inactivity',ticks=600},{type='fluid_count',condition='thruster-fuel >= 24000',harness=true}}}}},
    'harness waits go with time and item_count waits joined by and')
  -- a schedule without harness waits clears the watch
  space.platform_schedule(p,{platform='Spindle',stops={{station='gleba'}}})
  eq(W.get('Spindle'),nil)
end
print('d17_batch31 B9 platform fluid_count: ok')
