-- Run from repository root: lua tests/d17_batch23.lua
-- d17 batch23: the agents' 19:50 poll.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end

-- A1 (Sol): platform_defense cover by asteroid size, from each turret's priority list and minimum range.
do
  defines={inventory={turret_ammo=1}}
  local function turret(name,x,y,range,min,only)
    local list={}
    for _,n in ipairs(only or {}) do list[#list+1]={name=n} end
    return {valid=true,type='ammo-turret',name=name,position={x=x,y=y},bounding_box={left_top={x=x-1,y=y-1},right_bottom={x=x+1,y=y+1}},
      get_inventory=function() return {get_contents=function() return {{name='rocket',count=20}} end} end,
      prototype={attack_parameters={range=range,min_range=min}},ignore_unprioritised_targets=only~=nil,
      get_priority_target=function(i) return list[i] end}
  end
  local rocket=turret('rocket-turret',0,-20,36,15,{'big-oxide-asteroid','big-carbonic-asteroid','big-metallic-asteroid'})
  local gun=turret('gun-turret',20,0,18,0,nil)
  local tiles={}
  for x=0,3 do tiles[#tiles+1]={position={x=x,y=0}} end
  local s={find_entities_filtered=function(f) if f.type=='asteroid-collector' or f.type=='inserter' then return {} end return {rocket,gun} end,
    find_tiles_filtered=function() return tiles end}
  local D=dofile('mod/agent-harness_0.1.0/platdefense.lua'){platform=function() return {name='Swiftlet',surface=s,force='f'} end}
  local r=D.read({},{platform='Swiftlet'})
  eq(r.turrets[1].engages,'only big-carbonic-asteroid, big-metallic-asteroid, big-oxide-asteroid (ignores the rest)')
  eq(r.turrets[1].min_range,15); eq(r.turrets[2].engages,'every asteroid')
  local north
  for _,row in ipairs(r.sides) do if row.side=='north' then north=row end end
  -- tiles 0 and 1 are past the gun's 18: only the rocket turret reaches them, and it engages big ones only
  eq(north.edge_tiles,4); eq(north.by_size.small.uncovered,2); eq(north.by_size.medium.uncovered,2); eq(north.by_size.huge.uncovered,2)
  eq(north.by_size.big.uncovered,0)
  local line
  for _,l in ipairs(r.lines) do if l:find('^north side') then line=l end end
  has(line,'north side: 4 edge tiles, 2 where a size is not covered; small 2 uncovered ((0,0)-(1,0) 2 tiles); medium 2 uncovered')
  has(line,'big all covered')
  local by
  for _,l in ipairs(r.lines) do if l:find('^by their priority lists') then by=l end end
  has(by,'rocket-turret (0,-20) engages only big-carbonic-asteroid, big-metallic-asteroid, big-oxide-asteroid (ignores the rest), not within 15 tiles')
  -- inside the minimum range the rocket turret reaches nothing
  rocket.position={x=0,y=-5}
  r=D.read({},{platform='Swiftlet'})
  for _,row in ipairs(r.sides) do if row.side=='north' then north=row end end
  eq(north.by_size.big.uncovered,2)
  defines=nil
end
print('d17_batch23 A1 platform_defense by asteroid size: ok')

-- A2 (Astra, Kestrel II): the belt back into the hub read stranded while the hub fed the turrets; a disabled old
-- loader was named beside the bulk inserter feeding the line; a long-handed bridge's belt end read stranded. Each
-- belt is read once; turrets on one line or loop share it.
do
  defines={inventory={turret_ammo=1,hub_main=2,chest=3},entity_status={disabled_by_control_behavior=99}}
  prototypes={item={['firearm-magazine']={type='ammo',ammo_category='bullet'},['iron-plate']={type='item'}}}
  local n=0
  local function contents(t) local out={} for name,c in pairs(t) do out[#out+1]={name=name,count=c} end return out end
  local function inv(t) return {get_contents=function() return contents(t) end} end
  local reads=0
  local function belt(x,y,items)
    n=n+1
    local b={valid=true,unit_number=n,type='transport-belt',name='fast-transport-belt',position={x=x,y=y},nb={inputs={},outputs={}}}
    setmetatable(b,{__index=function(t,k) if k=='belt_neighbours' then reads=reads+1 return t.nb end end})
    b.get_max_transport_line_index=function() return 2 end
    b.get_transport_line=function(i) local c=i==1 and contents(items or {}) or {} return setmetatable({get_contents=function() return c end},{__len=function() local s=0 for _,r in ipairs(c) do s=s+r.count end return s end}) end
    return b
  end
  local function link(a,b) a.nb.outputs[#a.nb.outputs+1]=b; b.nb.inputs[#b.nb.inputs+1]=a end
  local function ins(x,y,from,to,name) n=n+1; return {valid=true,unit_number=n,type='inserter',name=name or 'fast-inserter',position={x=x,y=y},pickup_target=from,drop_target=to} end
  local function turret(x,y)
    n=n+1
    local t={valid=true,unit_number=n,type='ammo-turret',name='gun-turret',position={x=x,y=y},prototype={attack_parameters={ammo_categories={'bullet'}}}}
    t.get_inventory=function() return inv({}) end
    return t
  end
  local hub={valid=true,unit_number=9000,type='space-platform-hub',name='space-platform-hub',position={x=0,y=0}}
  hub.get_inventory=function() return inv({['firearm-magazine']=100}) end
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
  -- the line: bulk loader from the hub onto L1 -> L2 ... L6, L6 -> bulk inserter back into the hub; 2 magazines on
  -- each belt. Turret A takes from L2, turret B from L4. The old loader onto L1 is switched off.
  local L={}
  for i=1,6 do L[i]=belt(5.5,i,{['firearm-magazine']=2}) end
  for i=1,5 do link(L[i],L[i+1]) end
  local A,B=turret(8,2),turret(8,4)
  local loader=ins(4.5,1,hub,L[1],'bulk-inserter')
  local old=ins(4.5,0,hub,L[1])
  old.get_control_behavior=function() return {disabled=true} end
  local back=ins(4.5,6,L[6],hub,'bulk-inserter')
  local fa,fb=ins(6.5,2,L[2],A),ins(6.5,4,L[4],B)
  local belts={L[1],L[2],L[3],L[4],L[5],L[6]}
  local tr=run({B,A},belts,{loader,old,back,fa,fb})
  local ra,rb
  for _,row in ipairs(tr.rows) do if row.entity==A then ra=row else rb=row end end
  eq(ra.reaches,100+4,'A: the hub and L1-L2'); eq(rb.reaches,100+8,'B: the hub and L1-L4')
  eq(ra.belts,2); eq(rb.belts,4)
  eq(#ra.stops,0); eq(#rb.stops,0)
  has(rb.ways[1],'put on them by bulk-inserter (4.5,1) from space-platform-hub (0,0)')
  assert(not rb.ways[1]:find('(4.5,0)',1,true),'the switched-off old loader is not named while the bulk loader feeds the line: '..rb.ways[1])
  eq(tr.stranded,0,'L5 and L6 run back into the hub'); eq(tr.via_hub,4)
  local lines=dofile('mod/agent-harness_0.1.0/ammofeed.lua'){}.lines(tr,false,'Kestrel II',false)
  has(lines[1],'belts back into the hub 4'); has(lines[1],'stranded: 0')
  eq(reads,6,'each belt read once')
  -- the bulk loader switched off too: nothing more comes, and both loaders are named as switched off
  loader.get_control_behavior=function() return {disabled=true} end
  tr=run({A},belts,{loader,old,back,fa})
  has(tr.rows[1].stops[1],'the inserters putting items on are switched off')
  has(tr.rows[1].ways[1],'bulk-inserter (4.5,1) from space-platform-hub (0,0) (holds 100 of its ammo) (switched off)')
  loader.get_control_behavior=nil
  -- a long-handed bridge: M1 -> M2 (picked) -> M3 (the belt's end, 8 on it); the bridge drops onto N1 -> N2 -> the turret
  local M1,M2,M3=belt(25.5,57.5,{['firearm-magazine']=1}),belt(25.5,58.5,{['firearm-magazine']=8}),belt(25.5,59.5,{['firearm-magazine']=8})
  link(M1,M2); link(M2,M3)
  local N1,N2=belt(25.5,62.5),belt(25.5,63.5)
  link(N1,N2)
  local C=turret(28,64)
  local bridge=ins(25.5,60.5,M2,N1,'long-handed-inserter')
  local fc=ins(26.5,63.5,N2,C)
  local mload=ins(24.5,57.5,hub,M1)
  tr=run({C},{M1,M2,M3,N1,N2},{bridge,fc,mload})
  eq(tr.rows[1].reaches,100+9,'the hub, M1 and M2 through the bridge'); eq(#tr.rows[1].stops,0)
  has(tr.rows[1].ways[1],'through long-handed-inserter (25.5,60.5) from fast-transport-belt (25.5,58.5)')
  eq(tr.stranded,0,'the belt end is not stranded'); eq(tr.at_end,8)
  has(tr.at_end_rows[1],'8 on 1 belt ending at (25.5,59.5), past fast-transport-belt (25.5,58.5)')
  lines=dofile('mod/agent-harness_0.1.0/ammofeed.lua'){}.lines(tr,false,'Kestrel II',false)
  local endline
  for _,l in ipairs(lines) do if l:find('^at belt ends') then endline=l end end
  has(endline,'at belt ends past a pickup on a turret\'s way (not counted as stranded; they move on when the belt beyond is joined): 8')
  -- a loop R1 -> R2 -> R3 -> R1 with two turrets: each reaches the whole loop
  local R={belt(40,0,{['firearm-magazine']=3}),belt(41,0,{['firearm-magazine']=3}),belt(42,0,{['firearm-magazine']=3})}
  link(R[1],R[2]); link(R[2],R[3]); link(R[3],R[1])
  local D,E=turret(40,2),turret(42,2)
  tr=run({D,E},R,{ins(40,1,R[1],D),ins(42,1,R[3],E),ins(41,-1,hub,R[2])})
  eq(tr.rows[1].reaches,100+9); eq(tr.rows[2].reaches,100+9); eq(tr.rows[1].belts,3)
  defines,prototypes=nil,nil
end
print('d17_batch23 A2 ammunition feed: hub return, switched-off loaders, belt ends, one read per belt: ok')
