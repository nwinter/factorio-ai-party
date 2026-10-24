-- d21 batch66. Run from the harness root: lua tests/d21_batch66.lua
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,part) assert(type(s)=='string' and s:find(part,1,true),tostring(s)..'\n  lacks: '..part) end
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path

-- AB1 (Sol #1591): Solstice's ghosts needed asteroid-collector@uncommon 1, solar-panel@epic 1 and @rare 2; platform_bom
-- counted collector 1 and solar 3 at normal, took the hub's 6 normal panels as covering them, and its request section
-- never asked the qualities. Every count is by item and quality; a slot an item at a quality.
do
  game={tick=0,forces={},surfaces={}}
  defines={inventory={hub_main=1,robot_cargo=2,cargo_unit=3}}
  prototypes={space_location={nauvis={}},item={['solar-panel']={weight=20000},['asteroid-collector']={weight=100000},['speed-module']={weight=20000}},
    quality={normal={},uncommon={},rare={},epic={},legendary={}}}
  local solar={name='solar-panel',items_to_place_this={{name='solar-panel',count=1}}}
  local collector={name='asteroid-collector',items_to_place_this={{name='asteroid-collector',count=1}}}
  local ents={
    {type='entity-ghost',ghost_name='asteroid-collector',ghost_prototype=collector,quality={name='uncommon'}},
    {type='entity-ghost',ghost_name='solar-panel',ghost_prototype=solar,quality={name='epic'}},
    {type='entity-ghost',ghost_name='solar-panel',ghost_prototype=solar,quality={name='rare'}},
    {type='entity-ghost',ghost_name='solar-panel',ghost_prototype=solar,quality={name='rare'}},
    -- a built machine's module request at rare
    {type='item-request-proxy',item_requests={{name='speed-module',quality='rare',count=2}}},
  }
  local robots={}
  local function find(f)
    local want={}
    for _,t in ipairs(type(f.type)=='table' and f.type or {f.type}) do want[t]=true end
    local out={}
    for _,e in ipairs(ents) do if want[e.type] then out[#out+1]=e end end
    if want['construction-robot'] then for _,r in ipairs(robots) do out[#out+1]=r end end
    return out
  end
  -- the hub: 6 normal panels, 1 rare; get_item_count{name, quality} at that quality, a name alone every quality
  local held={['solar-panel@normal']=6,['solar-panel@rare']=1}
  local inv={get_item_count=function(w)
    if type(w)=='table' then return held[w.name..'@'..(w.quality or 'normal')] or 0 end
    local n=0 for k,c in pairs(held) do if k:match('^(.*)@')==w then n=n+c end end return n end}
  local sections={}
  local secs={sections_count=0}
  secs.get_section=function(i) return sections[i] end
  secs.add_section=function(g)
    local sec={group=g,slots={},filters_count=0,active=true}
    sec.set_slot=function(i,x) sec.slots[i]=x; sec.filters_count=math.max(sec.filters_count,i) end
    sec.clear_slot=function(i) sec.slots[i]=nil end
    sec.get_slot=function(i) return sec.slots[i] end
    sec.filters=sec.slots
    sections[#sections+1]=sec; secs.sections_count=#sections; return sec
  end
  secs.remove_section=function(i) table.remove(sections,i); secs.sections_count=#sections end
  local hub={valid=true,get_logistic_sections=function() return secs end,get_inventory=function() return inv end}
  local built={['solar-panel@rare']=5,['solar-panel@normal']=40}
  local pl={valid=true,index=9,name='Solstice',hub=hub,space_location={name='nauvis'},surface={find_entities_filtered=find,
    count_entities_filtered=function(f) return built[f.name..'@'..(f.quality or 'normal')] or 0 end}}
  local force={name='player',platforms={pl}}
  pl.force=force
  game.forces={player=force}
  local st={}
  local B=dofile('mod/agent-harness_0.1.0/platbom.lua'){platform=function() return pl end,state=function() return st end,
    cargo={limits=function() return 1000000,40 end,weigh=function(rest) B_rest=rest; return {total_kg=1,fewest=1} end}}

  -- the read: a row an item at a quality
  local r=B.read({force=force},{platform='Solstice'})
  local row={}
  for _,x in ipairs(r.items) do row[x.key]=x end
  eq(row['asteroid-collector'],nil,'no normal collector row')
  eq(row['asteroid-collector@uncommon'].ghosts_need,1); eq(row['asteroid-collector@uncommon'].quality,'uncommon'); eq(row['asteroid-collector@uncommon'].item,'asteroid-collector')
  eq(row['solar-panel'],nil,'no normal solar row: the hub\'s normal panels cover no ghost')
  eq(row['solar-panel@epic'].ghosts_need,1); eq(row['solar-panel@epic'].hub,0); eq(row['solar-panel@epic'].remaining,1,'6 normal panels do not cover an epic ghost')
  eq(row['solar-panel@epic'].hub_other_quality,7)
  eq(row['solar-panel@rare'].ghosts_need,2); eq(row['solar-panel@rare'].hub,1); eq(row['solar-panel@rare'].remaining,1); eq(row['solar-panel@rare'].built,5,'built at that quality')
  eq(row['speed-module@rare'].requests,2)
  local text=table.concat(r.lines,'\n')
  has(text,'solar-panel@epic: ghosts need 1 (0 built); hub holds 0 (and 7 at other qualities, which do not build these); 1 to send (the hub asks none)')
  has(text,'solar-panel@rare: ghosts need 2 (5 built); hub holds 1 (and 6 at other qualities, which do not build these); 1 to send')
  has(r.requests_check,'4 items the ghosts still need have no active hub request')
  local q={}
  for _,x in ipairs(B_rest) do q[x.name..'@'..x.quality]=x.count end
  eq(q['solar-panel@epic'],1,'to send at its quality'); eq(q['solar-panel@rare'],1); eq(q['asteroid-collector@uncommon'],1)

  -- the request section: one slot an item at a quality (comparator =), the hub's stock at that quality only
  r=B.read({force=force},{platform='Solstice',request=true})
  eq(r.request,'set')
  local sec=sections[1]
  local slot={}
  for i=1,sec.filters_count do local f=sec.slots[i]; if f then slot[f.value.name..'@'..f.value.quality]=f; eq(f.value.comparator,'=') end end
  eq(slot['solar-panel@normal'],nil,'no normal panel asked')
  eq(slot['solar-panel@epic'].min,1); eq(slot['solar-panel@rare'].min,2); eq(slot['asteroid-collector@uncommon'].min,1); eq(slot['speed-module@rare'].min,2)
  text=table.concat(r.lines,'\n')
  has(text,'solar-panel@epic: request 1 from nauvis (the ghosts need 1; the hub holds 0)')
  has(text,'solar-panel@rare: request 2 from nauvis (the ghosts need 2; the hub holds 1)')
  -- the read sees the section's asks by quality
  r=B.read({force=force},{platform='Solstice'})
  row={}
  for _,x in ipairs(r.items) do row[x.key]=x end
  eq(row['solar-panel@epic'].asks,1); eq(row['solar-panel@rare'].asks,2)
  eq(r.requests_check,'every item the ghosts still need has an active hub request')

  -- the rewrite keeps each item and quality in its slot; one built drops out where it stands
  local rare_slot
  for i=1,sec.filters_count do local f=sec.slots[i]; if f and f.value.name=='solar-panel' and f.value.quality=='rare' then rare_slot=i end end
  table.remove(ents,2)   -- the epic panel built
  B.tick(600)
  local names={}
  for i=1,sec.filters_count do local f=sec.slots[i]; if f then names[f.value.name..'@'..f.value.quality]=i end end
  eq(names['solar-panel@epic'],nil,'the epic slot cleared'); eq(names['solar-panel@rare'],rare_slot,'the rare slot where it was')

  -- the watch lowers a slot by what the hub spent at that quality, not at another
  held['solar-panel@normal']=0
  B.watch()
  eq(sec.slots[names['solar-panel@rare']].min,2,'normal panels spent: the rare request stands')
  held['solar-panel@rare']=0
  B.watch()
  eq(sec.slots[names['solar-panel@rare']].min,1,'a rare panel spent: lowered by 1')

  -- min_payload by item@quality, or by item for every quality
  r=B.read({force=force},{platform='Solstice',request=true,min_payload={['solar-panel@rare']=1,['asteroid-collector']=1}})
  for i=1,sec.filters_count do local f=sec.slots[i]; if f then names[f.value.name..'@'..f.value.quality]=f end end
  eq(names['solar-panel@rare'].minimum_delivery_count,1); eq(names['asteroid-collector@uncommon'].minimum_delivery_count,1)
  local ok,err=pcall(B.read,{force=force},{platform='Solstice',request=true,min_payload={['solar-panel@shiny']=1}})
  assert(not ok); has(err,'min_payload: unknown quality shiny')

  -- surface: the hub's asks by quality, held at that quality
  sections[1].slots={{value={type='item',name='solar-panel',quality='epic',comparator='='},min=1,import_from='nauvis'}}
  sections[1].filters=sections[1].slots
  r=B.from_surface({force=force},'nauvis')
  eq(r.requests[1].quality,'epic'); eq(r.requests[1].holds,0)
  has(r.lines[1],'solar-panel@epic 1 (asks 1, holds 0)')
  print('d21_batch66 AB1 platform_bom by item and quality: ok')
end

-- AB3 (Sol #1617): platform_defense read five of Solstice's turrets "preload only" while belt buffers capped near 10
-- held their source inserters off; every feed led to the maker aboard when those gates opened. A link held off by its
-- condition is traced through to its source and said gated closed now, with its condition and the values it reads.
do
  defines={inventory={turret_ammo=1,hub_main=2,chest=3},entity_status={disabled_by_control_behavior=99},wire_connector_id={circuit_red=1,circuit_green=2}}
  prototypes={item={['firearm-magazine']={type='ammo',ammo_category='bullet'}}}
  local n=0
  local function contents(t) local out={} for name,c in pairs(t) do out[#out+1]={name=name,count=c} end return out end
  local function inv(t) return {get_contents=function() return contents(t) end} end
  local function belt(x,y,items)
    n=n+1
    local b={valid=true,unit_number=n,type='transport-belt',name='transport-belt',position={x=x,y=y},belt_neighbours={inputs={}}}
    b.get_max_transport_line_index=function() return 2 end
    b.get_transport_line=function(i) local c=i==1 and contents(items or {}) or {} return setmetatable({get_contents=function() return c end},{__len=function() local t=0 for _,r in ipairs(c) do t=t+r.count end return t end}) end
    return b
  end
  local function turret(x,y,held)
    n=n+1
    local t={valid=true,unit_number=n,type='ammo-turret',name='gun-turret',position={x=x,y=y},prototype={attack_parameters={ammo_categories={'bullet'}}}}
    t.get_inventory=function() return inv({['firearm-magazine']=held}) end
    return t
  end
  local function ins(x,y,from,to,cond)
    n=n+1
    local i={valid=true,unit_number=n,type='inserter',name='fast-inserter',position={x=x,y=y},pickup_target=from,drop_target=to}
    if cond then i.cond=cond; i.get_control_behavior=function() return {disabled=true} end; i.status=99 end
    return i
  end
  local hub={valid=true,unit_number=1000,type='space-platform-hub',name='space-platform-hub',position={x=0,y=0}}
  hub.get_inventory=function() return inv({}) end
  local asm={valid=true,unit_number=1001,type='assembling-machine',name='assembling-machine-2',position={x=5.5,y=-8.5},
    get_recipe=function() return {products={{name='firearm-magazine',amount=1}}} end,get_output_inventory=function() return inv({['firearm-magazine']=4}) end}
  -- 1. a buffer belt capped at 10: its source inserter from the maker off by "firearm-magazine < 10" (12 on its wire)
  local t1=turret(0,-10,20)
  local b1=belt(0,-8.5,{['firearm-magazine']=12})
  local f1=ins(0,-9.5,b1,t1)
  local s1=ins(1.5,-8.5,asm,b1,'enabled when firearm-magazine < 10 (on its wires: firearm-magazine 12): false now')
  -- 2. a relay off by its condition between the maker's belt and the turret's belt
  local t2=turret(10,-10,3)
  local b2,m2=belt(10,-8.5,{}),belt(10,-6.5,{['firearm-magazine']=6})
  local f2=ins(10,-9.5,b2,t2)
  local r2=ins(10,-7.5,m2,b2,'enabled when signal-A > 0 (on its wires: signal-A 0): false now')
  local s2=ins(11.5,-6.5,asm,m2)
  -- 3. a turret whose own feeder from the maker is off by a logistic condition
  local t3=turret(-10,-10,2)
  local f3=ins(-10,-9,asm,t3,'logistic condition firearm-magazine < 50 (network holds firearm-magazine 80): false now')
  -- 4. a belt nothing puts anything on: no route to a source
  local t4=turret(-20,-10,1)
  local b4=belt(-20,-8.5,{['firearm-magazine']=3})
  local f4=ins(-20,-9.5,b4,t4)
  local inserters={f1,s1,f2,r2,s2,f3,f4}
  local surface={find_entities_filtered=function(f)
    local t=type(f.type)=='table' and f.type[1] or f.type
    if t=='inserter' then return inserters end
    if t=='ammo-turret' then return {t1,t2,t3,t4} end
    if t=='transport-belt' then return {b1,b2,m2,b4} end
    return {}
  end}
  -- the real feeders.lua, its condition read from the inserter's GUI text
  local Fd=dofile('mod/agent-harness_0.1.0/feeders.lua'){condition_parts=function(e) return e.cond and {e.cond,'it is off by its condition'} or {} end}
  local F=dofile('mod/agent-harness_0.1.0/ammofeed.lua'){feeders=Fd}
  local tr=F.trace({surface=surface,force='player',hub=hub})
  local lines=table.concat(F.lines(tr,true,'Solstice',false),'\n')
  local r1,r2_,r3,r4=tr.rows[1],tr.rows[2],tr.rows[3],tr.rows[4]
  -- 1: the 12 on the buffer reach it now; the maker's 4 wait behind the gate; refilled by the maker through that gate
  eq(r1.reaches,32); eq(r1.behind_gate,4); eq(#r1.stops,0)
  has(r1.gated[1],'fast-inserter (0,-9.5): the inserters putting items on the belts upstream of transport-belt (0,-8.5) are gated closed now (fast-inserter (1.5,-8.5)): nothing more comes onto them until one opens; 12 on them now')
  has(r1.ways[1],'put on them by fast-inserter (1.5,-8.5) from assembling-machine-2 (5.5,-8.5) (holds 4 of its ammo) (gated closed now: enabled when firearm-magazine < 10 (on its wires: firearm-magazine 12): false now)')
  eq(r1.replenished,'maker'); eq(r1.replenished_gated,true)
  -- 2: the route through the relay is traced to the maker: its belt's 6 and the maker's 4 behind the relay
  eq(r2_.reaches,3); eq(r2_.behind_gate,10); eq(#r2_.stops,0)
  has(r2_.ways[1],'behind a relay fast-inserter (10,-7.5) (gated closed now: enabled when signal-A > 0 (on its wires: signal-A 0): false now) from 1 belt holding 6 of its ammo')
  eq(r2_.replenished,'maker'); eq(r2_.replenished_gated,true)
  -- 3: its own feeder held off: the maker's 4 behind it
  eq(r3.reaches,2); eq(r3.behind_gate,4)
  has(r3.gated[1],'fast-inserter (-10,-9) gated closed now (logistic condition firearm-magazine < 50 (network holds firearm-magazine 80): false now): 4 of its ammo waits behind it in assembling-machine-2 (5.5,-8.5)')
  eq(r3.replenished,'maker'); eq(r3.replenished_gated,true)
  -- 4: no route: preload only, and stopped (dry)
  eq(r4.replenished,'preload'); has(r4.stops[1],'no inserter puts anything on the belts upstream of transport-belt (-20,-8.5): the 3 on them, then dry')
  eq(#r4.gated,0)
  has(lines,'replenishment by turret: 3 from an ammunition maker aboard (assembling-machine-2 (5.5,-8.5) making firearm-magazine) (3 of them only through a link gated closed now: (0,-10), (10,-10), (-10,-10)), 0 from the hub, 0 from chests only (what fills them is not traced), 1 preload only: (-20,-10)')
  has(lines,'gated closed now (a route to the turret, held off by its condition now; it carries when its condition is met): fast-inserter (-10,-9) (logistic condition')
  has(lines,'; fast-inserter (1.5,-8.5) (enabled when firearm-magazine < 10 (on its wires: firearm-magazine 12): false now) on the way of 1 turret: (0,-10)')
  has(lines,'fast-inserter (10,-7.5) (enabled when signal-A > 0 (on its wires: signal-A 0): false now) on the way of 1 turret: (10,-10)')
  has(lines,'gun-turret (-10,-10): holds 2; 2 reach it, 4 more behind a link gated closed now')
  has(lines,'; NOW: fast-inserter (-10,-9) gated closed now')
  has(lines,'gun-turret (-20,-10): holds 1; 4 reach it'); has(lines,'; STOPPED: fast-inserter (-20,-9.5): no inserter puts anything on')
  -- the stranded count leaves out the belt behind the relay (it is on a route)
  eq(tr.stranded,0)
  -- the source opened: refilled by the maker now, nothing gated
  s1.get_control_behavior=nil; s1.status=nil
  tr=F.trace({surface=surface,force='player',hub=hub})
  F.lines(tr,true,'Solstice',false)
  eq(tr.rows[1].reaches,36); eq(tr.rows[1].behind_gate,nil); eq(#tr.rows[1].gated,0); eq(tr.rows[1].replenished_gated,nil)
  defines,prototypes=nil,nil
  print('d21_batch66 AB3 ammunition routes through links gated closed now: ok')
end

-- AB4 (Sol #1681): Solstice at nauvis, schedule [nauvis, gleba] current 1, paused false, read no_schedule from 42819577 to
-- 42828245 while its wait processing-unit >= 300 was false (246 in the hub), and left once 346 had come; the recheck
-- said the call failed. Waiting at its current stop on conditions false now is said as the GUI shows it, apart from no
-- schedule and no path, and is not failed.
do
  game={tick=42819577}
  defines={space_platform_state={waiting_at_station=4,on_the_path=3,no_schedule=1,no_path=5,paused=7},inventory={hub_main=1,hub_trash=2},wire_connector_id={circuit_red=1,circuit_green=2}}
  prototypes={space_location={nauvis={},gleba={}},fluid={},item={['processing-unit']={}}}
  local pu=246
  local hub={valid=true,get_inventory=function() return {get_item_count=function(x) local n=type(x)=='table' and x.name or x; return n=='processing-unit' and pu or 0 end,get_contents=function() return {} end} end,
    get_logistic_sections=function() return {sections_count=0} end}
  local pl={valid=true,name='Solstice',index=9,state=4,space_location={name='nauvis'},force={name='player'},paused=false,hub=hub}
  local sch={get_record_count=function() return #(pl.schedule and pl.schedule.records or {}) end}
  sch.go_to_station=function(i) pl.schedule.current=i; pl.state=1 end
  sch.remove_record=function() end; sch.add_record=function() end
  pl.get_schedule=function() return sch end
  local p={force={platforms={pl},name='player'}}
  game.forces={player=p.force}
  local st={platform_stops={[9]={at='nauvis',tick=42815000}}}
  local space=dofile('mod/agent-harness_0.1.0/space.lua'){state=function() return st end,
    integer=function(v,d,lo,hi,name) v=v==nil and d or v; assert(type(v)=='number' and v>=lo and v<=hi,name..' out of range'); return v end,
    freight={where=function() return {at='nauvis',stopped=true} end,leg=function() return nil end},
    circuit_condition=function(c) local a,cmp,n=c:match('^(%S+) (%S+) (%-?%d+)$'); return {first_signal={type='item',name=a},comparator=cmp,constant=tonumber(n)} end}
  local waits={{type='time',ticks=3600},{type='item_count',condition='processing-unit >= 300',compare='and'}}
  local r=space.platform_schedule(p,{platform='Solstice',stops={{station='nauvis',wait=waits},{station='gleba',wait={{type='time',ticks=10800}}}},current=1,paused=false})
  eq(r.state,'no_schedule')
  eq(r.recheck,nil,'waiting on conditions false now: no recheck, no failure')
  local line='waiting at stop 1 (nauvis): conditions false now: time 60s: 0s left [holds] and item_count processing-unit >= 300: the hub holds 246, 54 to go [false]; the game reads no_schedule while it waits there and leaves when they hold (Solstice at Nauvis, shift52)'
  eq(r.waiting,line)
  eq(r.state_note,'state no_schedule: '..line..' (go to station 1 was called)')
  has(r.current_note,'the current stop (1, nauvis) is the station it is at: waiting at stop 1 (nauvis): conditions false now:')
  -- the stops read and the gate say it waits there
  local stops=space.stops(pl)
  has(stops[1],'1 nauvis (waiting here): time 60s: 0s left and item_count processing-unit >= 300: the hub holds 246, 54 to go')
  has(stops[2],'2 gleba (next)')
  local g=space.gate(p,{platform='Solstice'})
  has(g.lines[1],'Solstice: at station nauvis (the game reads no_schedule); stop 1 of 2')
  -- a recheck begun before (a queue step's) ends ok, with the waiting line
  local v=space.recheck_read({platform='Solstice',first='no_schedule',tick=42819577,ends_tick=42819877,force='player'})
  eq(v.ok,true); eq(v.waiting,line); has(v.line,'Solstice read no_schedule at tick 42819577 (the call\'s tick) and no_schedule 0 ticks later, at nauvis; waiting at stop 1 (nauvis)')
  -- the conditions hold (346 came) and it still reads no_schedule: said, and the recheck goes on to fail as before
  pu=346
  local w=space.waiting_now(pl)
  eq(w.met,true); has(w.line,'conditions hold now: time 60s: 0s left [holds] and item_count processing-unit >= 300: the hub holds 346 (met) [holds]; the game reads no_schedule')
  game.tick=42819877
  v=space.recheck_read({platform='Solstice',first='no_schedule',tick=42819577,ends_tick=42819877,force='player'})
  eq(v.ok,false); has(v.error,'it reads no_schedule: waiting at stop 1 (nauvis): conditions hold now:')
  -- an or: one group holding is enough
  pu=0
  pl.schedule.records[1].wait_conditions={{type='item_count',condition={first_signal={type='item',name='processing-unit'},comparator='>=',constant=300}},
    {type='time',ticks=60,compare_type='or'}}
  eq(space.waiting_now(pl).met,true)
  -- the current stop elsewhere (Swiftlet at aquilo with the current on gleba): not waiting; the stuck text names the stop
  pl.schedule.current=2
  eq(space.waiting_now(pl),nil); eq(space.waiting_line(pl),nil)
  v=space.recheck_read({platform='Solstice',first='no_schedule',tick=42819577,ends_tick=42819877,force='player'})
  eq(v.ok,false); has(v.error,'it reads no_schedule with 2 stops set (current 2, gleba) while it is at nauvis: it has not left')
  -- paused at its stop: not waiting (paused said apart)
  pl.schedule.current=1; pl.paused=true
  eq(space.waiting_now(pl),nil)
  pl.paused=false
  -- waiting_at_station reads the same line, without the no_schedule note
  pl.state=4; pu=100
  pl.schedule.records[1].wait_conditions={{type='item_count',condition={first_signal={type='item',name='processing-unit'},comparator='>=',constant=300}}}
  eq(space.waiting_line(pl),'waiting at stop 1 (nauvis): conditions false now: item_count processing-unit >= 300: the hub holds 100, 200 to go [false]')
  game,defines,prototypes=nil,nil,nil
  print('d21_batch66 AB4 waiting at its stop on conditions false now: ok')
end

-- AB5 (viewer Aurora 13:02: "K2's carbide landed in a different network from its silo"): delivery_watch follows a count
-- of an item to a named consumer, stage by stage, with a deadline, the last confirmed stage and the blocker seen.
do
  game={tick=1000}
  defines={inventory={hub_main=1,rocket_silo_rocket=2,cargo_landing_pad_main=3}}
  prototypes={item={['tungsten-carbide']={},['iron-plate']={}}}
  local held={silo=0,hub=200}
  local silo={valid=true,name='rocket-silo',type='rocket-silo',position={x=12.5,y=-30.5},get_item_count=function() return held.silo end}
  local padroom=false
  local pad={valid=true,name='cargo-landing-pad',type='cargo-landing-pad',position={x=5,y=6},get_inventory=function() return {can_insert=function() return padroom end} end}
  local chest={valid=true,name='requester-chest',type='logistic-container',position={x=20.5,y=1.5},prototype={logistic_mode='requester'},
    get_item_count=function() return 0 end,get_logistic_sections=function() return {sections_count=1,get_section=function() return {active=true,filters={{value={name='iron-plate'},min=10}}} end} end}
  local nets={[silo]=7,[pad]=12,[chest]=7}
  local aquilo={name='aquilo',find_entities_filtered=function(f)
    local out={}
    for _,e in ipairs({silo,pad,chest}) do
      if (not f.name or f.name==e.name) and math.abs(e.position.x-f.position.x)<=(f.radius or 0)+0.01 and math.abs(e.position.y-f.position.y)<=(f.radius or 0)+0.01 then out[#out+1]=e end
    end
    return out
  end}
  aquilo.find_logistic_network_by_position=function(pos)
    for e,id in pairs(nets) do if e.position.x==pos.x and e.position.y==pos.y then return {network_id=id} end end
  end
  for _,e in ipairs({silo,pad,chest}) do e.surface=aquilo; e.force='player' end
  local force={name='player',platforms={},is_chunk_charted=function() return true end}
  local hub={valid=true,get_inventory=function() return {get_item_count=function() return held.hub end} end}
  local pl={valid=true,name='Kestrel II',index=3,hub=hub,paused=false,space_location={name='fulgora'},schedule={records={{station='fulgora'},{station='aquilo'}}}}
  force.platforms={pl}
  game.forces={player=force}; game.planets={aquilo={surface=aquilo},fulgora={},nauvis={}}
  local receipts={}
  local where={}
  local st={}
  -- (d24 batch167 QJ1) the pods freight follows from the hub: the landed stage comes from the one the watch followed
  local fol={down={},up={}}
  local W=dofile('mod/agent-harness_0.1.0/delivwatch.lua'){state=function() return st end,who=function(p) return p.name end,
    census_typed=function(_,s,t) eq(t,'cargo-landing-pad'); return {pad} end,
    freight={where=function() return where end,receipts_since=function(_,since) local o={} for _,r in ipairs(receipts) do if r.tick>since then o[#o+1]=r end end return o end,
      followed=function() return fol end}}
  local sol={name='sol',index=1,force=force,surface=aquilo}
  local function fails(a,text) local ok,err=pcall(W.call,sol,a); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
  fails({item='tungsten-carbide',count=200,to={position={x=0,y=0},surface='aquilo'},deadline_min=20},'no silo, chest or machine of ours within 2 tiles of (0,0) on aquilo')
  fails({item='carbide',count=200,to={position={x=12.5,y=-30.5}},deadline_min=20},'unknown item: carbide')
  fails({item='tungsten-carbide',count=200,to={position={x=12.5,y=-30.5}}},'deadline_min')
  -- set: the silo on aquilo; Kestrel II at fulgora holds 200, its schedule stops at aquilo: loaded
  local r=W.call(sol,{item='tungsten-carbide',count=200,to={position={x=12.5,y=-30.5},surface='aquilo'},deadline_min=20})
  local w=r.watch
  eq(w.id,1); eq(w.direction,'down'); eq(w.last_confirmed,'loaded'); eq(w.carrier,'Kestrel II')
  has(r.line,'delivery watch #1: 200 tungsten-carbide to rocket-silo (12.5,-30.5) on aquilo, open; deadline in 20m00s; last confirmed stage loaded (Kestrel II\'s hub holds 200 tungsten-carbide')
  -- it leaves, flies to aquilo, stops there
  game.tick=1600; pl.space_connection={}; pl.space_location=nil; where={leg={from='fulgora',to='aquilo',flown=0.1}}
  W.tick(1620)
  local x=st.delivwatch.list[1]
  eq(x.stages.departed.text,'Kestrel II left fulgora'); eq(x.stages.in_transit.text,'Kestrel II flying fulgora->aquilo (10% when first seen)')
  game.tick=8940; pl.space_connection=nil; pl.space_location={name='aquilo'}; where={at='aquilo',stopped=true}
  -- stopped there with it aboard while the pad has no room for it (on the headless copy Nauvis's pad was full): blocked
  W.tick(8940)
  local h={}
  eq(W.lines(sol,h)[1],'delivery watch #1 (200 tungsten-carbide to rocket-silo (12.5,-30.5) on aquilo): blocked: no landing pad of ours on aquilo has room for tungsten-carbide (cargo-landing-pad (5,6)): the hub sends no pod of it down')
  padroom=true; game.tick=9000
  -- its pod lands at the pad (5,6), in network #12; the silo is in #7: blocked, the setter told once
  local cargo={{valid_for_read=true,name='tungsten-carbide',count=200,quality={name='normal'}}}
  cargo.get_item_count=function(n) return n=='tungsten-carbide' and 200 or 0 end
  local pod={valid=true,unit_number=501,surface=aquilo,position={x=5,y=6},cargo_pod_destination={station=pad},get_inventory=function() return cargo end}
  fol.down={{pod=pod,unit=501,at='aquilo',tick=8950}}
  receipts[#receipts+1]={tick=8990,kind='received',where='cargo-landing-pad (5,6) on aquilo',cargo={['tungsten-carbide']=200},dest={pad='cargo-landing-pad',position={x=5,y=6},surface='aquilo'}}
  held.hub=0
  W.tick(9000)
  eq(x.stages.landed,nil,'freight\'s receipt alone lands nothing: the watch\'s arrivals are the landed stage\'s source')
  W.pod_tick(9010); pod.valid=false; W.pod_tick(9020); fol.down={}
  W.tick(9060)
  eq(x.last,'network'); eq(x.stages.arrived.text,'Kestrel II stopped at aquilo')
  eq(x.stages.landed.text,'200 tungsten-carbide received by cargo-landing-pad (5,6) on aquilo (from Kestrel II): not counted as received (not landing pads in the consumer\'s logistic network)'); eq(x.stages.landed.tick,9020)
  eq(x.received,0,'landed and received agree: the pad is not in the silo\'s network')
  eq(x.stages.network.text,'the pad (5,6) is in logistic network #12; the consumer in #7')
  local lines=W.lines(sol,h)
  eq(#lines,3)
  eq(lines[1],'delivery watch #1: no longer blocked: no landing pad of ours on aquilo has room for tungsten-carbide (cargo-landing-pad (5,6)): the hub sends no pod of it down')
  has(lines[2],'delivery watch #1: pod 501 from Kestrel II\'s hub at aquilo')
  eq(lines[3],'delivery watch #1 (200 tungsten-carbide to rocket-silo (12.5,-30.5) on aquilo): blocked: landed at the pad (5,6) in logistic network #12; the consumer rocket-silo (12.5,-30.5) is in network #7: robots of one do not carry to the other')
  W.tick(9120); eq(W.lines(sol,h),nil,'told once')
  eq(W.lines({name='astra',force=force},{}),nil,'the setter only')
  -- the deadline passes: late, with the last confirmed stage and the blocker
  game.tick=1000+20*3600+20; W.tick(game.tick)
  eq(x.state,'late')
  lines=W.lines(sol,h)
  has(lines[1],'delivery watch #1 (200 tungsten-carbide to rocket-silo (12.5,-30.5) on aquilo): deadline passed, not reached: last confirmed stage network (the pad (5,6) is in logistic network #12; the consumer in #7')
  has(lines[1],'the consumer holds 0 (0 at the start); received 0 of 200 in 0 pods by landing pads in the consumer\'s logistic network since the watch was set; blocked: landed at the pad (5,6) in logistic network #12')
  -- the pad joined to the silo's network and the carbide brought: blocker gone, reached (late)
  nets[pad]=7; held.silo=200
  game.tick=game.tick+60; W.tick(game.tick)
  lines=W.lines(sol,h)
  has(lines[1],'delivery watch #1: no longer blocked: landed at the pad (5,6) in logistic network #12')
  has(lines[2],'delivery watch #1: reached by the stock test: rocket-silo (12.5,-30.5) holds 200 tungsten-carbide (0 when the watch was set), late, 1s after the deadline')
  eq(x.state,'reached')
  -- the read lists it; a requester chest asking none of the item is a blocker; clear
  local rd=W.call(sol,{})
  eq(#rd.watches,1); has(rd.lines[1],'delivery watch #1: 200 tungsten-carbide to rocket-silo (12.5,-30.5) on aquilo, reached')
  r=W.call(sol,{item='tungsten-carbide',count=10,to={position={x=20.5,y=1.5},surface='aquilo'},deadline_min=5})
  eq(r.watch.blockers[1],'the consumer, requester chest (20.5,1.5), asks none of tungsten-carbide: robots bring it nothing')
  eq(W.call(sol,{id=2,clear=true}).cleared,2)
  eq(#W.call(sol,{}).watches,1)
  -- up: a machine aboard Kestrel II, the carbide launched from nauvis
  local mach={valid=true,name='assembling-machine-3',type='assembling-machine',position={x=3.5,y=-4.5},get_item_count=function() return held.mach or 0 end}
  local deck={name='platform-3',find_entities_filtered=function() return {mach} end,platform={name='Kestrel II'}}
  mach.surface=deck; pl.surface=deck; pl.space_location={name='aquilo'}
  hub.type='space-platform-hub'; hub.surface=deck
  held.hub=0
  local rows={}
  W=dofile('mod/agent-harness_0.1.0/delivwatch.lua'){state=function() return st end,who=function(p) return p.name end,
    freight={where=function() return where end,receipts_since=function() return {} end,incoming=function() return {rows=rows} end,followed=function() return fol end}}
  r=W.call(sol,{item='tungsten-carbide',count=20,to={position={x=3.5,y=-4.5},platform='Kestrel II'},deadline_min=10,from='nauvis'})
  eq(r.watch.direction,'up'); eq(r.watch.blockers[1],'Kestrel II is not stopped at nauvis: a silo there launches to it only while it is')
  pl.space_location={name='nauvis'}
  rows[1]={cargo={['tungsten-carbide']=20},from='nauvis',tick=game.tick,down=false}
  -- (QJ1) the rocket's pod the watch follows: 12 of the 20 in it, landed in the hub
  local rcargo={{valid_for_read=true,name='tungsten-carbide',count=12,quality={name='normal'}}}
  rcargo.get_item_count=function(n) return n=='tungsten-carbide' and 12 or 0 end
  local rpod={valid=true,unit_number=601,surface=deck,position={x=0,y=0},cargo_pod_destination={space_platform={hub=hub,surface=deck}},get_inventory=function() return rcargo end}
  fol.up={{pod=rpod,tick=game.tick,from='nauvis',silo={x=1,y=2},up=1}}
  game.tick=game.tick+60; W.tick(game.tick)
  x=st.delivwatch.list[#st.delivwatch.list]
  eq(x.stages.launched.text,'a rocket from nauvis with 20 tungsten-carbide launched to Kestrel II'); eq(x.stages.in_transit.text,'its pod rising over nauvis')
  rows={}; held.hub=20
  game.tick=game.tick+60; W.tick(game.tick)
  eq(x.stages.landed,nil,'the hub holding more lands nothing: the pod the watch followed does')
  W.pod_tick(game.tick+1); rpod.valid=false; W.pod_tick(game.tick+2); fol.up={}
  eq(x.stages.landed.text,'12 tungsten-carbide received by Kestrel II\'s hub'); eq(x.received,12)
  held.mach=20
  game.tick=game.tick+60; W.tick(game.tick)
  -- (d24 batch146 PR1) from given (nauvis): the stock test is the last stage seen and does not end the watch; 12 of the
  -- 20 received from nauvis
  eq(x.state,'open'); eq(x.last,'reached'); eq(x.received,12)
  game,defines,prototypes=nil,nil,nil
  print('d21_batch66 AB5 delivery_watch: ok')
end

-- AB6 (viewer Aurora 16:02: "Nauvis's obsolete CF500 request diverted K2 cargo intended for Aquilo before it reached the
-- named consumer"): a landing pad asking the item at a stop before the destination is a risk, a blocker while stopped
-- there; a pod of it received on another planet is a diversion.
do
  game={tick=1000}
  defines={inventory={hub_main=1,rocket_silo_rocket=2}}
  prototypes={item={['carbon-fiber']={}}}
  local held={silo=0,hub=600,pad=0}
  local function secs_of(list) return function() return {sections_count=#list,get_section=function(i) return list[i] end} end end
  local silo={valid=true,name='rocket-silo',type='rocket-silo',position={x=12.5,y=-30.5},get_item_count=function() return held.silo end}
  local padsecs={{active=true,filters={{value={name='carbon-fiber'},min=500}}}}
  local npad={valid=true,name='cargo-landing-pad',type='cargo-landing-pad',position={x=52,y=54},get_item_count=function() return held.pad end,get_logistic_sections=secs_of(padsecs)}
  local aquilo={name='aquilo',find_entities_filtered=function(f)
    if math.abs(silo.position.x-f.position.x)<=(f.radius or 0) and math.abs(silo.position.y-f.position.y)<=(f.radius or 0) then return {silo} end
    return {}
  end,find_logistic_network_by_position=function() return {network_id=7} end}
  local nauvis={name='nauvis'}
  silo.surface=aquilo; silo.force='player'; npad.surface=nauvis
  local force={name='player',is_chunk_charted=function() return true end}
  local hubsecs={}
  local hub={valid=true,get_inventory=function() return {get_item_count=function() return held.hub end} end,get_logistic_sections=secs_of(hubsecs)}
  local pl={valid=true,name='Kestrel II',index=3,hub=hub,paused=false,space_location={name='fulgora'},
    schedule={current=1,records={{station='fulgora'},{station='nauvis'},{station='aquilo'}}}}
  force.platforms={pl}
  game.forces={player=force}; game.planets={aquilo={surface=aquilo},nauvis={surface=nauvis},fulgora={}}
  local receipts={}
  local st={}
  local FR66=dofile('mod/agent-harness_0.1.0/freight.lua'){state=function() return {} end}
  local W=dofile('mod/agent-harness_0.1.0/delivwatch.lua'){state=function() return st end,who=function(p) return p.name end,
    census_typed=function(_,s,t) return s==nauvis and t=='cargo-landing-pad' and {npad} or {} end,
    freight={where=function() return {} end,receipts_since=function(_,since) local o={} for _,r in ipairs(receipts) do if r.tick>since then o[#o+1]=r end end return o end,
      hub_keeps_at=FR66.hub_keeps_at,hub_gives=FR66.hub_gives,keep_text=FR66.keep_text}}
  local sol={name='sol',index=1,force=force,surface=aquilo}
  -- at fulgora with 600 aboard: nauvis's pad asking 500 is a risk at stop 2, before aquilo
  local r=W.call(sol,{item='carbon-fiber',count=600,to={position={x=12.5,y=-30.5},surface='aquilo'},deadline_min=30})
  eq(r.watch.blockers,nil)
  eq(r.watch.risks[1],'Kestrel II stops at nauvis (stop 2 of its schedule) before aquilo; the landing pad (52,54) there asks 500 carbon-fiber (holds 0): while it is stopped there its hub sends 500 of it down to that pad (the hub holds 600 now)')
  local h={}
  local lines=W.lines(sol,h)
  eq(#lines,1); has(lines[1],'delivery watch #1 (600 carbon-fiber to rocket-silo (12.5,-30.5) on aquilo): at risk: Kestrel II stops at nauvis (stop 2 of its schedule)')
  -- the hub's own request for nauvis with no max keeps all it holds there: no risk; with max 400 it keeps 400, the rest
  -- goes down (d24 batch137 PI1: only sections importing from the stop's planet count)
  hubsecs[1]={active=true,filters={{value={name='carbon-fiber'},min=10,import_from='nauvis'}}}
  W.tick(1020); local x=st.delivwatch.list[1]
  eq(x.risks and next(x.risks),nil,'kept aboard')
  hubsecs[1].filters[1].max=400
  game.tick=1080; W.tick(1080)
  has(W.row(x).risks[1],'its hub sends 200 of it down to that pad (the hub holds 600 now; hub section 1 keeps carbon-fiber 10..400 at nauvis)')
  lines=W.lines(sol,h)
  eq(#lines,1,'back after it was gone'); has(lines[1],'hub section 1 keeps carbon-fiber 10..400 at nauvis')
  game.tick=1140; W.tick(1140); eq(W.lines(sol,h),nil,'the same risk told once')
  hubsecs[1]=nil
  -- stopped at nauvis: a blocker; the pad's count changing tells nothing new
  game.tick=5000; pl.space_location={name='nauvis'}; pl.schedule.current=2
  W.tick(5040)
  has(W.row(x).blockers[1],'Kestrel II is stopped at nauvis (stop 2 of its schedule) with 600 carbon-fiber in its hub, before aquilo; the landing pad (52,54) there asks 500 carbon-fiber (holds 0): while it is stopped there its hub sends 500 of it down to that pad')
  eq(W.row(x).risks,nil)
  lines=W.lines(sol,h)
  eq(#lines,1); has(lines[1],'blocked: Kestrel II is stopped at nauvis')
  -- a pod of 500 received by nauvis's pad: a diversion, told once, kept with the pad's request
  receipts[#receipts+1]={tick=5050,kind='received',where='cargo-landing-pad (52,54) on nauvis',cargo={['carbon-fiber']=500},stop='nauvis',dest={pad='cargo-landing-pad',position={x=52,y=54},surface='nauvis'}}
  held.hub, held.pad=100, 500
  game.tick=5100; W.tick(5100)
  lines=W.lines(sol,h)
  -- (d24 batch137 PI1) the pad holds what it asks: the hub sends no more there, the blocker is gone
  eq(#lines,2); has(lines[2],'no longer blocked: Kestrel II is stopped at nauvis')
  eq(lines[1],'delivery watch #1 (600 carbon-fiber to rocket-silo (12.5,-30.5) on aquilo): diverted: 500 carbon-fiber received by cargo-landing-pad (52,54) on nauvis, which asks 500 of it (holds 500 now), before aquilo; 500 of it diverted since the watch was set')
  eq(x.diverted,500); eq(x.diversions[1].planet,'nauvis'); eq(x.stages.landed,nil,'not landed at the destination')
  game.tick=5160; W.tick(5160); eq(W.lines(sol,h),nil,'one diversion told once')
  -- it leaves nauvis: the blocker gone; the deadline passes: the status names the diversion
  pl.space_location=nil; pl.space_connection={}; pl.schedule.current=3
  game.tick=5220; W.tick(5220)
  eq(W.lines(sol,h),nil,'(PI1) the blocker went at 5100, when the pad held what it asks')
  game.tick=1000+30*3600+20; W.tick(game.tick)
  has(W.lines(sol,h)[1],'deadline passed, not reached: last confirmed stage departed (Kestrel II left ?')
  has(W.status(x),'; diverted 500: 500 carbon-fiber received by cargo-landing-pad (52,54) on nauvis, which asks 500 of it (holds 500 now), before aquilo')
  -- paused at nauvis, not a stop of its schedule [fulgora, aquilo]: still the pad's draw
  pl.space_connection=nil; pl.space_location={name='nauvis'}; pl.schedule={current=1,records={{station='fulgora'},{station='aquilo'}}}
  held.pad=0  -- (PI1) robots emptied the pad: it lacks 500 again
  game.tick=game.tick+60; W.tick(game.tick)
  has(W.row(x).blockers[1],'Kestrel II is stopped at nauvis (not a stop of its schedule) with 100 carbon-fiber in its hub, before aquilo')
  game,defines,prototypes=nil,nil,nil
  print('d21_batch66 AB6 delivery_watch pad demand: ok')
end

-- AB7 (viewer Aurora 17:03: "Robots moved 300 of Petrel II's packs before its arrival-age check"): each pod with the
-- watched item is followed to the tick it is gone; its count and spoilage then, and the pad's on that tick, are kept.
do
  game={tick=1000}
  defines={inventory={hub_main=1,cargo_unit=3,cargo_landing_pad_main=4,chest=5}}
  prototypes={item={['agricultural-science-pack']={},['iron-plate']={}}}
  local function stack(name,count,spoil) return {valid_for_read=true,name=name,count=count,spoil_percent=spoil,quality={name='normal'}} end
  local function inv(list) local t={} for i,x in ipairs(list) do t[i]=x end for i=#list+1,4 do t[i]={valid_for_read=false} end
    t.get_item_count=function(n) local c=0 for _,x in ipairs(list) do if x.name==n then c=c+x.count end end return c end return t end
  local nauvis={name='nauvis'}
  local padinv=inv({stack('agricultural-science-pack',40,0.9)})
  local pad={valid=true,name='cargo-landing-pad',type='cargo-landing-pad',position={x=52,y=54},surface=nauvis,
    get_inventory=function() return padinv end,get_item_count=function(n) return padinv.get_item_count(n) end}
  nauvis.find_entities_filtered=function(f) if f.radius and math.abs(f.position.x-52)<=f.radius and math.abs(f.position.y-54)<=f.radius then return {pad} end return {} end
  nauvis.find_logistic_network_by_position=function() return {network_id=243} end
  pad.force='player'
  local force={name='player',is_chunk_charted=function() return true end}
  local hubinv=inv({stack('agricultural-science-pack',300,0.4)})
  local psurf={name='platform-5'}
  local pl={valid=true,name='Petrel II',index=5,surface=psurf,paused=false,space_location={name='nauvis'},schedule={current=1,records={{station='nauvis'}}},
    hub={valid=true,type='space-platform-hub',get_inventory=function() return hubinv end,get_logistic_sections=function() return {sections_count=0} end}}
  force.platforms={pl}
  game.forces={player=force}; game.planets={nauvis={surface=nauvis}}
  local podinv=inv({stack('agricultural-science-pack',200,0.1),stack('agricultural-science-pack',100,0.6)})
  local pod={valid=true,unit_number=77,surface=psurf,position={x=0,y=0},cargo_pod_state='awaiting_launch',cargo_pod_destination={station=pad},
    get_inventory=function() return podinv end}
  local fol={down={{pod=pod,unit=77,at='nauvis',tick=1000}},up={}}
  local st={}
  local W=dofile('mod/agent-harness_0.1.0/delivwatch.lua'){state=function() return st end,who=function(p) return p.name end,census_typed=function() return {pad} end,
    freight={where=function() return {at='nauvis',stopped=true} end,receipts_since=function() return {} end,followed=function() return fol end,
      spoils=function(n) return n=='agricultural-science-pack' end}}
  local sol={name='sol',index=1,force=force,surface=nauvis}
  W.call(sol,{item='agricultural-science-pack',count=300,to={position={x=52,y=54},surface='nauvis'},deadline_min=30,from='Petrel II'})
  W.call(sol,{item='iron-plate',count=10,to={position={x=52,y=54},surface='nauvis'},deadline_min=30,from='Petrel II'})
  local h={}; W.lines(sol,h)
  -- the watch pass follows the pod; on the platform it is read every 10 ticks
  game.tick=1020; W.tick(1020)
  eq(st.delivwatch.pods[77].watches[1],'agricultural-science-pack'); eq(st.delivwatch.pods[77].watches[2],nil,'no iron in it')
  game.tick=1025; W.pod_tick(1025); eq(st.delivwatch.pods[77].last.tick,1020,'far: not read yet')
  game.tick=1030; W.pod_tick(1030); eq(st.delivwatch.pods[77].last.tick,1030)
  -- over nauvis: read every tick; it spoils a little on the way down
  pod.surface=nauvis; pod.cargo_pod_state='descending'
  game.tick=1040; W.pod_tick(1040)
  podinv[1].spoil_percent=0.26; pod.cargo_pod_state='parking'
  game.tick=1041; W.pod_tick(1041); eq(st.delivwatch.pods[77].last.tick,1041)
  -- gone: the pad holds its 300 and the 40 it had; robots take from it after
  pod.valid=false
  padinv=inv({stack('agricultural-science-pack',40,0.9),stack('agricultural-science-pack',200,0.26),stack('agricultural-science-pack',100,0.6)})
  game.tick=1042; W.pod_tick(1042)
  padinv=inv({})
  eq(st.delivwatch.pods[77],nil)
  local x=st.delivwatch.list[1]
  local a=x.arrivals[1]
  eq(a.tick,1042); eq(a.pod,77); eq(a.count,300); eq(a.spoil['25-50%'],200); eq(a.spoil['50-75%'],100); eq(a.dest_count,340); eq(a.dest_spoil['75-100%'],40)
  eq(a.stacks[1].spoil_percent,26); eq(a.read_tick,1041); eq(a.platform,'Petrel II'); eq(a.stop,'nauvis')
  eq(a.text,'pod 77 from Petrel II\'s hub at nauvis, sent 1s before, received by cargo-landing-pad (52,54) on nauvis at tick 1042: 300 agricultural-science-pack (200 at 25-50% spoiled, 100 at 50-75% spoiled; the pod\'s last read, 0s before); cargo-landing-pad (52,54) on nauvis held 340 of it on that tick (200 at 25-50% spoiled, 100 at 50-75% spoiled, 40 at 75-100% spoiled)')
  local lines=W.lines(sol,h)
  eq(#lines,2); has(lines[1],'delivery watch #1: pod 77 from Petrel II\'s hub at nauvis')
  -- (d22 batch107 BQ1) the pad consumer received its count: the stock test read on that tick (it holds 340, 40 at the start)
  has(lines[1],'; received 300 of 300 in 1 pod by cargo-landing-pad (52,54) on nauvis since the watch was set, the last at tick 1042')
  -- (d24 batch146 PR1) from given: ended by the received total, the stock test said apart; it counts on to the deadline
  has(lines[2],'delivery watch #1 (300 agricultural-science-pack to cargo-landing-pad (52,54) on nauvis): received 300 of 300 in 1 pod')
  has(lines[2],'; the stock test: the consumer holds 340 now (40 at the start), seen holding 300 more; reached at tick 1042; still counting until the deadline (29m59s from now): later pods add to received')
  eq(W.row(st.delivwatch.list[2]).arrivals,nil)
  -- up: a rocket's pod to the hub; an item that does not spoil reads so; a gone pod in freight's list stops nothing
  local rinv=inv({stack('iron-plate',100,0)})
  local rpod={valid=true,unit_number=88,surface=nauvis,position={x=15,y=59},cargo_pod_state='ascending',cargo_pod_destination={space_platform=pl},get_inventory=function() return rinv end}
  fol.up={{pod={valid=false},tick=1000,from='nauvis'},{pod=rpod,tick=1050,from='nauvis',silo={x=15.5,y=59.5},up=4}}
  pl.hub.name='space-platform-hub'; pl.hub.position={x=0,y=0}; pl.hub.surface=psurf
  pl.hub.get_item_count=function(n) return hubinv.get_item_count(n) end
  psurf.find_entities_filtered=function() return {pl.hub} end
  W.call(sol,{item='iron-plate',count=100,to={position={x=0,y=0},platform='Petrel II'},deadline_min=30,from='nauvis'})
  game.tick=1080; W.tick(1080)
  eq(st.delivwatch.pods[88].watches[3],'iron-plate')
  rpod.surface=psurf; game.tick=1090; W.pod_tick(1090)
  rpod.valid=false; hubinv=inv({stack('iron-plate',100,0)}); game.tick=1091; W.pod_tick(1091)
  local u=st.delivwatch.list[3].arrivals[1]
  eq(u.text,'pod 88 from a rocket from nauvis (rocket-silo (15.5,59.5)), launched 1s before, received by Petrel II\'s hub at tick 1091: 100 iron-plate (it does not spoil; the pod\'s last read, 0s before); Petrel II\'s hub held 100 of it on that tick (it does not spoil)')
  eq(u.rocket.up,4)
  game,defines,prototypes=nil,nil,nil
  print('d21_batch66 AB7 delivery_watch pod arrivals: ok')
end
