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
    b.get_transport_line=function(i) return {get_contents=function() return i==1 and contents(items or {}) or {} end} end
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
