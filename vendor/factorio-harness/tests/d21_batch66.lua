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
