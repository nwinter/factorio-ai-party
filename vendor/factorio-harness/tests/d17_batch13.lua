-- d17 batch13 contracts. Run from the harness root: lua tests/d17_batch13.lua
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end

-- B1 (Kestrel: magazines stranded on a rear loop while the bow turrets ran empty): each turret's way back to its
-- ammunition; what can reach it, and what is stranded.
do
  defines={inventory={turret_ammo=1,hub_main=2,chest=3},entity_status={disabled_by_control_behavior=99}}
  prototypes={item={['firearm-magazine']={type='ammo',ammo_category='bullet'},['iron-plate']={type='item'}}}
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
  local turret={valid=true,unit_number=100,type='ammo-turret',name='gun-turret',position={x=0,y=-10},prototype={attack_parameters={ammo_categories={'bullet'}}}}
  turret.get_inventory=function() return inv({['firearm-magazine']=2}) end
  local hub={valid=true,unit_number=200,type='space-platform-hub',name='space-platform-hub',position={x=0,y=0}}
  hub.get_inventory=function() return inv({['firearm-magazine']=300}) end
  -- the feed: B1 <- B2 <- B3, 5 magazines on B2, nothing loading them
  local b1,b2,b3=belt(0,-8),belt(0,-7,{['firearm-magazine']=5}),belt(0,-6)
  b1.belt_neighbours.inputs={b2}; b2.belt_neighbours.inputs={b3}
  -- a loop at the stern with 100 magazines no turret reaches
  local l1,l2=belt(10,10,{['firearm-magazine']=60}),belt(11,10,{['firearm-magazine']=40})
  l1.belt_neighbours.inputs={l2}; l2.belt_neighbours.inputs={l1}
  local ins={valid=true,unit_number=300,type='inserter',name='fast-inserter',position={x=0,y=-9},drop_target=turret,pickup_target=b1}
  local belts={b1,b2,b3,l1,l2}
  local surface={find_entities_filtered=function(f)
    local t=type(f.type)=='table' and f.type[1] or f.type
    if t=='inserter' then return {ins} end
    if t=='ammo-turret' then return {turret} end
    if t=='transport-belt' then return belts end
    return {}
  end}
  local pl={surface=surface,force='player',hub=hub}
  local F=dofile('mod/agent-harness_0.1.0/ammofeed.lua'){}
  local tr=F.trace(pl)
  eq(tr.rows[1].reaches,7,'its 2 and the 5 on the belt upstream')
  has(tr.rows[1].stops[1],'no inserter puts anything on the belts upstream of transport-belt (0,-8): the 5 on them, then dry')
  eq(tr.stranded,100); eq(tr.hub_reaches,false); eq(tr.hub_stranded['firearm-magazine'],300)
  has(tr.stranded_groups[1],'100 on 2 belts in (10,10)-(11,10)')
  local lines=F.lines(tr,false)
  has(lines[1],'ammunition that can reach a turret: 7'); has(lines[1],'hub 300 NOT reaching any turret')
  -- an inserter putting magazines on B3 from the hub: the hub reaches the turret, nothing stops it
  local loader={valid=true,unit_number=301,type='inserter',name='fast-inserter',position={x=0,y=-5},drop_target=b3,pickup_target=hub}
  surface.find_entities_filtered=function(f)
    local t=type(f.type)=='table' and f.type[1] or f.type
    if t=='inserter' then return {ins,loader} end
    if t=='ammo-turret' then return {turret} end
    if t=='transport-belt' then return belts end
    return {}
  end
  tr=F.trace(pl)
  eq(tr.rows[1].reaches,307); eq(#tr.rows[1].stops,0); eq(tr.hub_reaches,true); eq(tr.stranded,100)
  -- switched off: the loader no longer counts, and it is said
  loader.get_control_behavior=function() return {disabled=true} end
  tr=F.trace(pl)
  eq(tr.rows[1].reaches,7); has(tr.rows[1].stops[1],'the inserters putting items on are switched off')
  defines,prototypes=nil,nil
  print('d17_batch13 B1 ammunition feed: ok')
end

-- A1 (Luna: a routine check woke long waits): a reminder with wake: false is delivered as an fyi line (it wakes no
-- wait); reminder_ack takes next_in_ticks (the next run later) and, from its owner, a new cadence.
do
  game={tick=1000}
  local st,sent={},{}
  local R=dofile('mod/agent-harness_0.1.0/reminders.lua'){state=function() return st end,who=function(p) return p.name end,
    resolve=function(n) return n end,agents=function() return {{name='luna',index=1},{name='sol',index=2}} end,
    deliver=function(index,t) sent[#sent+1]={index=index,t=t} end}
  local luna,sol={name='luna'},{name='sol'}
  local r=R.handlers.reminder_add(luna,{message='Gleba core check',every_ticks=3600,wake=false})
  has(r.reminder.wake,'false: delivered with the next reply')
  game.tick=4620; R.tick()
  eq(#sent,1); eq(sent[1].index,1,'only its recipient'); eq(sent[1].t.fyi,true,'wakes no wait')
  local a=R.handlers.reminder_ack(luna,{id=r.added,result='no change',next_in_ticks=18000})
  eq(a.reminder.next_due_tick,4620+18000); has(a.note,'the next run in 5m00s')
  local ok,err=pcall(R.handlers.reminder_ack,sol,{id=r.added,every_ticks=18000})
  assert(not ok and tostring(err):find('its owner',1,true),tostring(err))
  a=R.handlers.reminder_ack(luna,{id=r.added,every_ticks=18000})
  eq(a.reminder.every_ticks,18000); has(a.note,'the cadence is now every 5m00s')
  game=nil
  print('d17_batch13 A1 reminders: ok')
end

-- B1 relays (Astra: Wren's bow; Sol: Meridian's west turret, read STOPPED): an inserter moving items from one belt
-- onto another feeds the turret's belt; the trace goes on through it to the belt it takes from and that belt's loaders.
do
  defines={inventory={turret_ammo=1,hub_main=2,chest=3},entity_status={disabled_by_control_behavior=99}}
  prototypes={item={['firearm-magazine']={type='ammo',ammo_category='bullet'},rocket={type='ammo',ammo_category='rocket'}}}
  local n=500
  local function contents(t) local out={} for name,c in pairs(t) do out[#out+1]={name=name,count=c} end return out end
  local function inv(t) return {get_contents=function() return contents(t) end} end
  local function belt(x,y,items)
    n=n+1
    local b={valid=true,unit_number=n,type='transport-belt',name='transport-belt',position={x=x,y=y},belt_neighbours={inputs={}}}
    b.get_max_transport_line_index=function() return 2 end
    b.get_transport_line=function(i) local c=i==1 and contents(items or {}) or {} return setmetatable({get_contents=function() return c end},{__len=function() local t=0 for _,r in ipairs(c) do t=t+r.count end return t end}) end
    return b
  end
  local function ins(x,y,from,to) n=n+1; return {valid=true,unit_number=n,type='inserter',name='fast-inserter',position={x=x,y=y},pickup_target=from,drop_target=to} end
  local hub={valid=true,unit_number=1,type='space-platform-hub',name='space-platform-hub',position={x=0,y=0}}
  hub.get_inventory=function() return inv({['firearm-magazine']=200,rocket=50}) end
  local function run(turrets,belts,inserters)
    local surface={find_entities_filtered=function(f)
      local t=type(f.type)=='table' and f.type[1] or f.type
      if t=='inserter' then return inserters end
      if t=='ammo-turret' then return turrets end
      if t=='transport-belt' then return belts end
      return {}
    end}
    return dofile('mod/agent-harness_0.1.0/ammofeed.lua'){}.trace({surface=surface,force='player',hub=hub})
  end
  local function turret(x,y,cat)
    n=n+1
    local t={valid=true,unit_number=n,type='ammo-turret',name=cat=='rocket' and 'rocket-turret' or 'gun-turret',position={x=x,y=y},prototype={attack_parameters={ammo_categories={cat or 'bullet'}}}}
    t.get_inventory=function() return inv({}) end
    return t
  end
  -- Wren: relay (-2.5,-9.5) from belt (-2.5,-8.5) onto (-2.5,-10.5) -> (-3.5,-10.5) -> (-3.5,-12.5) -> the bow gun
  local bow=turret(-3.5,-15)
  local b1,b2,b3=belt(-3.5,-12.5,{['firearm-magazine']=4}),belt(-3.5,-10.5,{['firearm-magazine']=6}),belt(-2.5,-10.5,{['firearm-magazine']=5})
  b1.belt_neighbours.inputs={b2}; b2.belt_neighbours.inputs={b3}
  local spine=belt(-2.5,-8.5,{['firearm-magazine']=20})
  local feeder=ins(-3.5,-13.5,b1,bow)
  local relay=ins(-2.5,-9.5,spine,b3)
  local loader=ins(-1.5,-7.5,hub,spine)
  local tr=run({bow},{b1,b2,b3,spine},{feeder,relay,loader})
  eq(#tr.rows[1].stops,0,'no stop: the relay feeds it'); eq(tr.hub_reaches,true); eq(tr.stranded,0)
  eq(tr.rows[1].reaches,4+6+5+20+200)
  has(tr.rows[1].ways[1],'through fast-inserter (-2.5,-9.5) from transport-belt (-2.5,-8.5)')
  -- Meridian: relay (-12.5,-2.5) from the hub's rocket spine (-12.5,-1.5) onto (-12.5,-3.5), a lone belt
  local west=turret(-12.5,-6.5,'rocket')
  local lone,rspine=belt(-12.5,-3.5,{}),belt(-12.5,-1.5,{rocket=8})
  local f2=ins(-12.5,-4.5,lone,west)
  local r2=ins(-12.5,-2.5,rspine,lone)
  local l2=ins(-11.5,-1.5,hub,rspine)
  tr=run({west},{lone,rspine},{f2,r2,l2})
  eq(#tr.rows[1].stops,0,'no stop: fed from the spine'); eq(tr.rows[1].reaches,8+50)
  -- the relay switched off: stopped again, and said
  r2.get_control_behavior=function() return {disabled=true} end
  tr=run({west},{lone,rspine},{f2,r2,l2})
  has(tr.rows[1].stops[1],'no inserter puts anything on the belts upstream of transport-belt (-12.5,-3.5)')
  defines,prototypes=nil,nil
  print('d17_batch13 B1 relays: ok')
end
