-- d28 batch306 (Sol #2672). Run from the harness root: lua tests/d28_batch306.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,msg) assert(a==b,(msg or '')..' '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
local function lacks(s,x) assert(not tostring(s):find(x,1,true),tostring(s)..' has '..x) end

-- A logistic network that counts by quality: a name alone is the normal count, {name, quality} that quality's.
local function network(id,counts)
  return {valid=true,network_id=id,get_item_count=function(item)
    local name,q=item,'normal'
    if type(item)=='table' then name,q=item.name,item.quality or 'normal' end
    return (counts[name] or {})[q] or 0
  end}
end

-- QL1 (Sol: "iron-plate@legendary < 400 reads normal reserved -54 but false"; "copper-plate@legendary < 100 reads
-- copper-plate 31651 but true"): a logistic condition's explanation reads the count at the condition's quality.
do
  prototypes={item={['iron-plate']={},['copper-plate']={}},fluid={},virtual_signal={},quality={normal={},legendary={}}}
  defines={wire_connector_id={circuit_red=1,circuit_green=2},entity_status={disabled_by_control_behavior=7},control_behavior={type={inserter=1}}}
  local C=dofile('mod/agent-harness_0.1.0/circuits.lua'){}
  -- normal iron reserved beyond stock (-54), legendary iron 450; normal copper 31651, legendary copper 40
  local net=network(243,{['iron-plate']={normal=-54,legendary=450},['copper-plate']={normal=31651,legendary=40}})
  local function inserter(x,y,item,constant,fulfilled)
    local cb={type=1,connect_to_logistic_network=true,circuit_enable_disable=false,
      logistic_condition={first_signal={type='item',name=item,quality='legendary'},comparator='<',constant=constant,fulfilled=fulfilled}}
    local e={valid=true,type='inserter',name='fast-inserter',position={x=x,y=y},status=fulfilled and 1 or 7,
      get_control_behavior=function() return cb end,get_circuit_network=function() return nil end}
    e.surface={find_logistic_network_by_position=function(p,f) return net end}
    e.force={find_logistic_network_by_position=function(p,s) return net end}
    return e,cb
  end
  -- the iron input (36.5,70.5): 450 legendary held, so "< 400" is false; the normal -54 is not what it reads
  local iron,cb=inserter(36.5,70.5,'iron-plate',400,false)
  local c=C.read(iron,cb)
  eq(c.logistic,'iron-plate@legendary < 400')
  eq(c.logistic_reads,'network 243 (its logistic area holds the centre): iron-plate@legendary 450')
  local parts=C.condition_parts(iron,c,cb)
  eq(parts[1],'no circuit condition')
  eq(parts[2],'logistic condition iron-plate@legendary < 400 (network holds iron-plate@legendary 450): false now')
  eq(parts[3],'it is off by its condition')
  lacks(table.concat(parts,'; '),'-54'); lacks(table.concat(parts,'; '),'reserved')
  -- the copper input (32.5,76.5): 40 legendary, "< 100" true; the normal 31651 not shown
  local copper,cb2=inserter(32.5,76.5,'copper-plate',100,true)
  c=C.read(copper,cb2)
  eq(c.logistic_reads,'network 243 (its logistic area holds the centre): copper-plate@legendary 40')
  parts=C.condition_parts(copper,c,cb2)
  eq(parts[2],'logistic condition copper-plate@legendary < 100 (network holds copper-plate@legendary 40): true now')
  lacks(table.concat(parts,'; '),'31651')
  -- legendary iron reserved beyond stock: the note names the legendary item
  net=network(243,{['iron-plate']={normal=5000,legendary=-12}})
  c=C.read(iron,cb)
  has(c.logistic_reads,'iron-plate@legendary -12 (network count -12: reserved beyond stock: deliveries have reserved 12 more iron-plate@legendary than the network holds')
  parts=C.condition_parts(iron,c,cb)
  has(parts[2],'logistic condition iron-plate@legendary < 400 (network count -12: reserved beyond stock: deliveries have reserved 12 more iron-plate@legendary')
  lacks(parts[2],'5000')
  -- a normal condition reads the normal count, as before
  cb.logistic_condition={first_signal={type='item',name='iron-plate'},comparator='<',constant=400,fulfilled=false}
  c=C.read(iron,cb)
  eq(c.logistic,'iron-plate < 400')
  eq(c.logistic_reads,'network 243 (its logistic area holds the centre): iron-plate 5000')
  eq(C.condition_parts(iron,c,cb)[2],'logistic condition iron-plate < 400 (network holds iron-plate 5000): false now')
  -- the count id the network takes
  eq(C.item_id({name='iron-plate'}).quality,'normal'); eq(C.item_id({name='iron-plate',quality='normal'}).quality,'normal')
  eq(C.item_id({name='iron-plate',quality={name='rare'}}).quality,'rare')
  prototypes,defines=nil,nil
end
print('d28_batch306 QL1 a logistic condition explained at its quality: ok')

-- QL2: gates and the pushed off_by_condition alert say a legendary count under 0 as the legendary item's.
do
  game={tick=600}
  defines={wire_connector_id={circuit_red=1,circuit_green=2},entity_status={disabled_by_control_behavior=7}}
  local C=dofile('mod/agent-harness_0.1.0/circuits.lua'){}
  local net=network(243,{['iron-plate']={normal=5000,legendary=-54}})
  net.get_supply_counts=function() return nil end
  local cond={first_signal={type='item',name='iron-plate',quality='legendary'},comparator='<',constant=400,fulfilled=false}
  local cb={connect_to_logistic_network=true,logistic_condition=cond}
  local e={valid=true,name='fast-inserter',position={x=36.5,y=70.5},get_control_behavior=function() return cb end,
    surface={find_logistic_network_by_position=function() return net end}}
  local G=dofile('mod/agent-harness_0.1.0/gates.lua'){negative_note=C.negative_note,
    circuit_read=function() return {logistic='iron-plate@legendary < 400',logistic_met=false} end}
  local row=G.row(e)
  local text=type(row)=='table' and (row.line or row.text or table.concat(row,'; ')) or tostring(row)
  has(text,'iron-plate@legendary -54 (network count -54: reserved beyond stock: deliveries have reserved 54 more iron-plate@legendary')
  lacks(text,'5000')
  game,defines=nil,nil
end
print('d28_batch306 QL2 gates names the quality in a count under 0: ok')

-- QL3 (Sol: place_ghosts' dry run said "network 954 covering it holds no fast-inserter" (a character's personal
-- roboport) while network 243 built 5 of the 6 in 9 s): with several networks over the ghosts, the one holding the
-- item at the ghost's quality is named; each network that holds none is said.
do
  game={tick=600}
  prototypes={entity={['construction-robot']={max_payload_size=1},['logistic-robot']={max_payload_size=1}}}
  local function ent(name,x,y,u) return {valid=true,name=name,position={x=x,y=y},unit_number=u} end
  local chest=ent('storage-chest',40,60,3)
  local picked
  local function net(id,counts,port,robots)
    local n=network(id,counts)
    n.cells={{owner=port,stationed_construction_robot_count=robots,stationed_logistic_robot_count=0}}
    n.available_construction_robots=robots; n.available_logistic_robots=0
    n.select_pickup_point=function(f) picked=f.name; return {owner=chest} end
    n.find_cell_closest_to=function() return n.cells[1] end
    return n
  end
  -- 954: a character's personal roboport (a mobile cell), 14 robots, holding none; 243: a roboport holding normal
  -- fast-inserters and 2 legendary
  local char=net(954,{},ent('character',36,58,9),14)
  char.cells[1].mobile=true
  local base=net(243,{['fast-inserter']={normal=200,legendary=2},['electric-furnace']={normal=10}},ent('roboport',30,50,1),300)
  local list={char,base}
  local surf={find_logistic_networks_by_construction_area=function() return list end}
  local force={worker_robots_storage_bonus=0,find_logistic_network_by_position=function() return base end}
  local DP=dofile('mod/agent-harness_0.1.0/robottrips.lua'){}
  local jobs={{kind='construct',pos={x=32.5,y=74.5},item='fast-inserter',count=1},{kind='construct',pos={x=32.5,y=72.5},item='fast-inserter',count=1},
    {kind='construct',pos={x=32.5,y=76.5},item='electric-furnace',count=1}}
  local lines=DP.preview(surf,force,jobs)
  local all=table.concat(lines,'\n')
  has(lines[1],'3 robot trips: about 3 robots would go at once')
  has(lines[1],'from roboport (30,50) (3 trips)')
  has(lines[1],'; by network 243')
  lacks(all,'network 954 covering')
  has(all,"network 954's construction area covers 3 of the ghosts too, and it holds none of their items: "..DP.NOTE)
  eq(picked,'electric-furnace')
  -- a legendary ghost: counted and picked up at its quality
  lines=DP.preview(surf,force,{{kind='construct',pos={x=32.5,y=74.5},item='fast-inserter',quality='legendary',count=1}})
  has(lines[1],'1 robot trips'); has(lines[1],'by network 243')
  eq(type(picked),'table'); eq(picked.name,'fast-inserter'); eq(picked.quality,'legendary')
  -- an epic ghost: no network holds it at epic, though 243 holds normal ones; both networks named
  lines=DP.preview(surf,force,{{kind='construct',pos={x=32.5,y=74.5},item='fast-inserter',quality='epic',count=1},
    {kind='construct',pos={x=33.5,y=74.5},item='fast-inserter',quality='epic',count=1}})
  all=table.concat(lines,'\n')
  has(all,'2 fast-inserter@epic ghosts near (33,74.5): networks 954, 243 covering them hold no fast-inserter@epic')
  -- with a ghost no network holds it for beside one 243 builds: only 243 named as building (live, the copy named 381 too)
  local pick=char.select_pickup_point
  char.select_pickup_point=function() return nil end
  lines=DP.preview(surf,force,{{kind='construct',pos={x=32.5,y=74.5},item='fast-inserter',count=1},{kind='construct',pos={x=33.5,y=74.5},item='fast-inserter',quality='epic',count=1}})
  has(lines[1],'by network 243'); lacks(lines[1],'954')
  char.select_pickup_point=pick
  -- one network only: the line as before
  list={base}
  lines=DP.preview(surf,force,{{kind='construct',pos={x=32.5,y=74.5},item='rail',count=1}})
  has(table.concat(lines,'\n'),'1 rail ghost near (32.5,74.5): network 243 covering it holds no rail')
  -- the network a character's roboport would build from when it alone holds the item
  list={char,base}
  char.get_item_count=function(item) return (type(item)=='string' and item or item.name)=='rail' and 5 or 0 end
  lines=DP.preview(surf,force,{{kind='construct',pos={x=32.5,y=74.5},item='rail',count=1}})
  has(lines[1],'by network 954')
  has(table.concat(lines,'\n'),"network 243's construction area covers 1 of the ghosts too")
  -- the engine's order (measured, batch306): a personal roboport first, then the network whose logistic area holds the
  -- ghost, then the rest as found. Two roboport networks A (found first) and B that both hold the item:
  local A=net(379,{['iron-chest']={normal=5}},ent('roboport',6000,6100,11),10)
  local B=net(380,{['iron-chest']={normal=5}},ent('roboport',6060,6100,12),10)
  local area=B
  force.find_logistic_network_by_position=function() return area end
  list={A,B}
  local function by(x,y) local l=DP.preview(surf,force,{{kind='construct',pos={x=x,y=y},item='iron-chest',count=1}}); return l[1]:match('by network (%d+)') end
  eq(by(6040.5,6100.5),'380','in B\'s logistic area: B (G3)')
  area=A; eq(by(6020.5,6110.5),'379','in A\'s logistic area: A (G6)')
  area=nil; eq(by(6032.5,6114.5),'379','in neither: the first found, though B\'s roboport is nearer (G8)')
  -- a character holding it, in B's logistic area: the character (C2); holding none: B (C1)
  local ch=net(381,{['iron-chest']={normal=5}},ent('character',6040.5,6126.5,13),10)
  ch.cells[1].mobile=true
  list={A,B,ch}; area=B
  eq(by(6042.5,6120.5),'381','C2')
  ch.get_item_count=function() return 0 end
  eq(by(6040.5,6120.5),'380','C1')
  eq(#DP.build_order(surf,force,{x=0,y=0},list),3)
  force.find_logistic_network_by_position=function() return base end
  list={char,base}
  -- a requester's delivery at its quality
  picked=nil
  lines=DP.preview(surf,force,{{kind='deliver',pos={x=32.5,y=77.5},item='fast-inserter',quality='legendary',count=2}})
  eq(picked.quality,'legendary')
  game,prototypes=nil,nil
end
print('d28_batch306 QL3 robot_dispatch names the network that holds the item at its quality: ok')

-- QL4: an off machine's state (thrust.state_text, used by shortages, makers and trace) names its circuit signal's
-- quality with the value its wires carry at that quality.
do
  defines={wire_connector_id={circuit_red=1,circuit_green=2},entity_status={disabled_by_control_behavior=7}}
  local wire={get_signal=function(sig) return sig.quality=='legendary' and 3 or 900 end}
  local cb={circuit_condition={first_signal={type='item',name='iron-plate',quality='legendary'},comparator='<',constant=10}}
  local e={valid=true,status=7,get_control_behavior=function() return cb end,get_circuit_network=function(w) return w==1 and wire or nil end}
  local enable='iron-plate@legendary < 10'
  local T=dofile('mod/agent-harness_0.1.0/thrust.lua'){circuit=function() return {enable=enable,logistic=false} end}
  eq(T.state_text(e),'off by its circuit condition iron-plate@legendary < 10 (iron-plate@legendary 3 on its wires)')
  cb.circuit_condition.first_signal.quality=nil; enable='iron-plate < 10'
  eq(T.state_text(e),'off by its circuit condition iron-plate < 10 (iron-plate 900 on its wires)')
  defines=nil
end
print('d28_batch306 QL4 an off machine\'s circuit signal named at its quality: ok')
