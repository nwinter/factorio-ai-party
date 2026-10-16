-- d15 batch4 (operator 21:25, shifts 19-20 requests). Run from the harness root: lua tests/d15_batch4.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,msg) assert(a==b,(msg or '')..' '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end

-- 1 (Sol): requests checks every argument before it changes anything; max "inf" on a hub. --------------------------
do
  defines={space_platform_state={paused=7},rocket_silo_status={},inventory={hub_main=1,hub_trash=2},cargo_destination={}}
  prototypes={item={['firearm-magazine']={},coal={}},space_location={nauvis={},vulcanus={}},quality={normal={},rare={}}}
  local function section(manual)
    local slots={}
    local sec={index=1,is_manual=manual,group='',active=true,filters_count=0}
    local function recount() local n=0; for i in pairs(slots) do n=math.max(n,i) end; sec.filters_count=n end
    sec.get_slot=function(i) return slots[i] or {} end
    sec.set_slot=function(i,f) slots[i]=f; recount() end
    sec.clear_slot=function(i) slots[i]=nil; recount() end
    setmetatable(sec,{__index=function(_,k) if k=='filters' then local out={}; for i=1,sec.filters_count do out[i]=slots[i] or {} end; return out end end})
    return sec
  end
  local list={section(true)}
  local secs=setmetatable({get_section=function(i) return list[i] end,add_section=function() local s=section(true); s.index=#list+1; list[#list+1]=s; return s end},
    {__index=function(_,k) if k=='sections_count' then return #list end end})
  local held=450
  local main={get_item_count=function() return held end,get_contents=function() return {{name='firearm-magazine',count=held}} end}
  local trash={get_contents=function() return {} end}
  local platform={valid=true,name='Starling',index=1,space_location=nil,space_connection={},
    hub={valid=true,type='space-platform-hub',position={x=0,y=0},get_logistic_sections=function() return secs end,
      get_inventory=function(i) return i==1 and main or trash end}}
  local p={index=1,force={platforms={platform}}}
  local switched=0
  local space=dofile('mod/agent-harness_0.1.0/space.lua'){state=function() return {} end,
    integer=function(v,d,lo,hi,name) v=v==nil and d or v; assert(type(v)=='number' and v>=lo and v<=hi,name..' out of range'); return v end,
    keep=function() return {set_construction=function(_,on) switched=switched+1; return on end,construction=function() return nil end} end,
    freight={where=function() return {} end}}
  local r=space.requests(p,{platform='Starling',set={{item='firearm-magazine',min=400,max='inf',from='vulcanus'}}})
  eq(r.stored[1],'firearm-magazine 400..inf from vulcanus')
  eq(r.over_max,nil,'no max, nothing over it')
  r=space.requests(p,{platform='Starling',set={{item='firearm-magazine',min=400,max=420}}})
  eq(r.over_max[1],'firearm-magazine: the hub holds 450, 30 over the max 420')
  -- A bad second entry: nothing changes, not even the construction switch or the first entry.
  fails(function() space.requests(p,{platform='Starling',construction_requests=true,set={{item='coal',min=5},{item='firearm-magazine',min=10,max='lots'}}}) end,
    'or "inf" for none: "lots" is not')
  eq(switched,0,'construction switch untouched'); eq(#list[1].filters,1,'coal not set')
  fails(function() space.requests(p,{platform='Starling',clear={'firearm-magazine','nope'}}) end,'unknown item: nope')
  eq(list[1].filters[1].max,420,'the clear changed nothing')
  fails(function() space.requests(p,{platform='Starling',set={{item='coal',min=5,from='mars'}}}) end,'mars is not one')
  fails(function() space.requests(p,{platform='Starling',set={{item='coal',min=5,quality='legendary'}}}) end,'unknown quality: legendary')
  fails(function() space.requests(p,{platform='Starling',section=4,set={{item='coal',min=5}}}) end,'section 4 does not exist')
  eq(#list[1].filters,1)
  r=space.requests(p,{platform='Starling',set={{item='coal',min=5,max='Infinity'}}})
  eq(r.stored[1],'coal 5..inf')
end
print('d15_batch4 1 requests: ok')

-- 2 (Sol, Luna, Astra, Grok): trace {position, upstream}: a crusher's ore down a belt to an oxidizer plant, an arm on
-- the way sending it onto a furnace belt, coal joining the lane. ----------------------------------------------------
do
  defines={inventory={chest=1,crafter_input=3,lab_input=4,asteroid_collector_output=8,hub_main=9},entity_status={},wire_connector_id={}}
  prototypes={item={['iron-ore']={type='item'},coal={type='item',fuel_value=4e6},['iron-plate']={type='item'}},recipe={},quality={}}
  prototypes.get_entity_filtered=function() return {} end
  local function inv(items)
    items=items or {}
    return {get_item_count=function(name) return items[name] or 0 end,
      get_contents=function() local out={} for k,v in pairs(items) do out[#out+1]={name=k,count=v} end table.sort(out,function(a,b) return a.name<b.name end) return out end,
      can_insert=function() return true end,is_full=function() return false end}
  end
  local surface={name='platform-2',valid=true}
  local world,n={},0
  local function ent(e)
    n=n+1; e.valid=true; e.unit_number=n; e.surface=surface; e.force='player'; e.status=e.status or 'working'
    e.bounding_box={left_top={x=e.position.x-0.5,y=e.position.y-0.5},right_bottom={x=e.position.x+0.5,y=e.position.y+0.5}}
    world[#world+1]=e; return e
  end
  surface.find_entities_filtered=function(f)
    local out={}
    local types=type(f.type)=='table' and f.type or {f.type}
    for _,e in ipairs(world) do
      local ok=false
      for _,t in ipairs(types) do if e.type==t then ok=true end end
      if ok and f.position then ok=((e.position.x-f.position.x)^2+(e.position.y-f.position.y)^2)^0.5<=(f.radius or 0.5) end
      if ok then out[#out+1]=e end
    end
    return out
  end
  surface.get_tile=function() return {name='space-platform-foundation'} end
  local function crafter(x,y,name,recipe,input,output,status)
    local e=ent{name=name,type='assembling-machine',position={x=x,y=y},status=status}
    local i,o=inv(input),inv(output)
    e.get_recipe=function() return recipe end
    e.get_inventory=function(id) if id==defines.inventory.crafter_input then return i end end
    e.get_output_inventory=function() return o end
    return e
  end
  local function inserter(x,y,pick,drop,o)
    o=o or {}
    local e=ent{name=o.name or 'inserter',type='inserter',position={x=x,y=y},status=o.status or 'working'}
    e.pickup_target,e.drop_target=pick,drop
    e.pickup_position=o.pickup or (pick and pick.position)
    e.drop_position=o.drop or (drop and drop.position)
    e.held_stack={valid_for_read=o.held~=nil,name=o.held and o.held[1],count=o.held and o.held[2]}
    e.filter_slot_count=o.filters and 5 or 0
    e.use_filters=o.filters~=nil
    e.inserter_filter_mode='whitelist'
    e.get_filter=function(k) local f=o.filters and o.filters[k] return f and {name=f} or nil end
    return e
  end
  -- Belts face east (direction 4); lane 1 (left) is the north half. Tiles of a run share one internal line.
  local function belt(x,y,left,right,run)
    local e=ent{name='transport-belt',type='transport-belt',position={x=x,y=y},direction=4,belt_shape='straight'}
    e.lines={}
    for k,items in ipairs({left or {},right or {}}) do
      local l={owner=e,line_length=1,internal=run..':'..k,items=items}
      l.get_contents=function() local m={} for _,it in ipairs(l.items) do m[it]=(m[it] or 0)+1 end local out={} for nm,c in pairs(m) do out[#out+1]={name=nm,count=c} end return out end
      l.get_detailed_contents=function() local out={} for i,it in ipairs(l.items) do out[#out+1]={stack={valid_for_read=true,name=it,count=1},position=i*0.25} end return out end
      l.get_line_item_position=function() return {x=e.position.x,y=e.position.y+(k==1 and -0.25 or 0.25)} end
      l.line_equals=function(o) return o.internal==l.internal end
      l.input_lines={}
      e.lines[k]=l
    end
    e.get_max_transport_line_index=function() return 2 end
    e.get_transport_line=function(k) return e.lines[k] end
    e.belt_neighbours={inputs={},outputs={}}
    e.get_item_count=function(item) local c=0 for _,l in ipairs(e.lines) do for _,it in ipairs(l.items) do if it==item then c=c+1 end end end return c end
    return e
  end
  local oxidizer={name='thruster-oxidizer',ingredients={{type='item',name='iron-ore',amount=2}},products={{name='thruster-oxidizer'}}}
  local crush={name='metallic-asteroid-crushing',ingredients={{type='item',name='metallic-asteroid-chunk',amount=1}},products={{name='iron-ore'}}}
  local crusher=crafter(1.5,5.5,'crusher',crush,{},{['iron-ore']=0},'working')
  local belts={}
  for x=1,15 do
    local left={}
    if x>=2 and x<=8 then left[#left+1]='iron-ore' end
    if x>=5 then left[#left+1]='coal' end
    belts[x]=belt(x+0.5,2.5,left,{},'A')
    if x>1 then belts[x].belt_neighbours.inputs={belts[x-1]}; belts[x-1].belt_neighbours.outputs={belts[x]} end
  end
  local furnace_belt=belt(9.5,4.5,{},{},'F')
  local coal_chest=ent{name='iron-chest',type='container',position={x=5.5,y=0.5}}
  local cinv=inv({coal=50}); coal_chest.get_inventory=function() return cinv end
  local T=crafter(15.5,5.5,'chemical-plant',oxidizer,{},{},'item_ingredient_shortage')
  inserter(2.5,3.5,crusher,belts[2],{drop={x=2.5,y=2.25}})
  local arm=inserter(9.5,3.5,belts[9],furnace_belt,{held={'iron-ore',1}})
  inserter(5.5,1.5,coal_chest,belts[5],{drop={x=5.5,y=2.25}})
  inserter(15.5,3.5,belts[15],T,{status='waiting_for_source_items'})
  local force={name='player',current_research=nil,is_chunk_visible=function() return true end}
  local function lookup(_,a)
    for _,e in ipairs(world) do if e.type~='inserter' and e.type~='transport-belt' and math.abs(e.position.x-a.position.x)<0.6 and math.abs(e.position.y-a.position.y)<0.6 then return e end end
    for _,e in ipairs(world) do if e.type=='transport-belt' and math.abs(e.position.x-a.position.x)<0.6 and math.abs(e.position.y-a.position.y)<0.6 then return e end end
    error('nothing there',0)
  end
  local supply=require('supply'){status_name=function(e) return e.status end,position=function(v) return v end,integer=function(v,d) return v or d end}
  local trace=require('trace'){supply=supply,entity=lookup,remote_entity=lookup,status_name=function(e) return e.status end,
    position=function(v) return {x=v.x,y=v.y} end,integer=function(v,d) return v or d end}
  local p={surface=surface,force=force,position={x=0,y=0}}
  local r=trace.trace(p,{position={x=15.5,y=5.5},upstream=true})
  eq(r.entity,'chemical-plant'); eq(#r.ingredients,1)
  local ore=r.ingredients[1]
  eq(ore.item,'iron-ore'); eq(#ore.lanes,2)
  local left=ore.lanes[1].line
  has(left,'goes elsewhere first at inserter (9.5,3.5) working, holding 1 iron-ore takes it onto transport-belt (9.5,4.5) (6 tiles back)')
  has(left,'iron-ore first on this lane 7 tiles back, at transport-belt (8.5,2.5)')
  has(left,'comes onto it from inserter (2.5,3.5) working from crusher (1.5,5.5) (13 tiles back)')
  has(left,'first other item: coal joins the left lane at transport-belt (5.5,2.5) from inserter (5.5,1.5) working from iron-chest (5.5,0.5)')
  has(left,'the lane starts at transport-belt (1.5,2.5)')
  has(ore.lanes[1].path_back,'transport-belt (15.5,2.5) to (1.5,2.5) left lane (15 tiles)')
  has(ore.lanes[2].line,'no iron-ore on this lane for 15 tiles back')
  has(r.line,'chemical-plant (15.5,5.5) item_ingredient_shortage (recipe thruster-oxidizer): iron-ore (has 0 of 2): ')
  eq(r.cost,'30 belt tiles, 2 lane walks')
  -- A full left lane at the feeder with no ore on it: a jammed mixed lane.
  for x=12,15 do belts[x].lines[1].items={'coal','coal','coal','coal'} end
  r=trace.trace(p,{position={x=15.5,y=5.5},upstream=true})
  has(r.ingredients[1].lanes[1].line,'the left lane at transport-belt (15.5,2.5) is full and holds no iron-ore (left lane 4 coal, right lane empty), front item coal')
  -- F4 (Astra): the front item's only taker on the lane puts it into a machine with full output: a deadlock.
  local boiler=crafter(17.5,3.5,'boiler-room',{name='burn-coal',ingredients={{type='item',name='coal',amount=1}},products={{name='steam'}}},{},{},'full_output')
  local coal_arm=inserter(16.5,2.5,belts[15],boiler,{pickup={x=15.5,y=2.25}})
  r=trace.trace(p,{position={x=15.5,y=5.5},upstream=true})
  has(r.ingredients[1].lanes[1].jammed,'; deadlock: inserter (16.5,2.5) working takes coal into boiler-room (17.5,3.5) (recipe burn-coal) (full_output)')
  table.remove(world); table.remove(world)  -- the arm and its machine out again: the feeder is world[#world] below
  -- The feeder filtered to coal: stops there.
  world[#world].filter_slot_count=5; world[#world].use_filters=true; world[#world].get_filter=function(k) return k==1 and {name='coal'} or nil end
  r=trace.trace(p,{position={x=15.5,y=5.5},upstream=true})
  has(r.ingredients[1].line,'inserter (15.5,3.5) waiting_for_source_items filter coal does not let iron-ore through its filter')
  has(r.ingredients[1].line,'no inserter feeding it lets iron-ore through its filter')
  fails(function() trace.trace(p,{position={x=15.5,y=5.5},upstream=true,forward=true}) end,'upstream and forward go one way each')
  -- On the belt tile itself: both lanes walked with no one item; joins listed first first.
  r=trace.trace(p,{position={x=15.5,y=2.5},upstream=true})
  has(r.lanes[1].line,'items come onto it (first first): iron-ore joins the left lane at transport-belt (2.5,2.5) from inserter (2.5,3.5)')
  -- The summary line: each lane's first problem.
  world[#world].filter_slot_count=0; world[#world].use_filters=false
  for x=12,15 do belts[x].lines[1].items={'coal'} end
  r=trace.trace(p,{position={x=15.5,y=5.5},upstream=true})
  has(r.ingredients[1].line,'iron-ore (has 0 of 2): inserter (15.5,3.5) picks transport-belt (15.5,2.5) left lane: goes elsewhere first at inserter (9.5,3.5)')
  has(r.ingredients[1].line,'right lane: no iron-ore on this lane for 15 tiles back, and nothing found putting it onto it (the lane starts at transport-belt (1.5,2.5) (right lane nothing))')
  -- The arm off by its circuit condition: named as off, not as taking it.
  arm.status='disabled_by_control_behavior'
  r=trace.trace(p,{position={x=15.5,y=5.5},upstream=true})
  has(r.ingredients[1].lanes[1].line,'1 inserter that would take it elsewhere is off by its condition now: inserter (9.5,3.5) disabled_by_control_behavior')
  assert(not r.ingredients[1].lanes[1].line:find('goes elsewhere first',1,true))
  arm.status='working'
  -- A feeder reading a requester chest with none: its request.
  local req=ent{name='requester-chest',type='logistic-container',position={x=20.5,y=5.5},prototype={logistic_mode='requester'}}
  local rinv=inv({}); req.get_inventory=function() return rinv end
  req.get_logistic_sections=function() return {sections_count=1,get_section=function() return {active=true,filters={{value={name='iron-ore'},min=40}}} end} end
  local T2=crafter(22.5,5.5,'chemical-plant',oxidizer,{},{},'item_ingredient_shortage')
  inserter(21.5,5.5,req,T2)
  r=trace.trace(p,{position={x=22.5,y=5.5},upstream=true})
  has(r.ingredients[1].line,'reads requester-chest (20.5,5.5), holding 0 iron-ore; a requester chest requesting 40 (robots fill it); no inserter fills it')
  -- An inserter filtered to iron-ore from the hub puts only iron-ore onto the lane (not the hub's other items).
  local hub=ent{name='space-platform-hub',type='space-platform-hub',position={x=0.5,y=0.5}}
  local hinv=inv({['iron-plate']=100}); hub.get_inventory=function() return hinv end
  inserter(3.5,1.5,hub,belts[3],{drop={x=3.5,y=2.25},filters={'iron-ore'}})
  r=trace.trace(p,{position={x=15.5,y=5.5},upstream=true})
  has(r.ingredients[1].lanes[1].line,'comes onto it from inserter (2.5,3.5)')
  assert(not r.ingredients[1].lanes[1].line:find('iron-plate joins',1,true),r.ingredients[1].lanes[1].line)
end
print('d15_batch4 2 upstream: ok')

-- 3 (Opus): power {position, fragile}: the poles whose loss alone cuts machines off from all generation. -------------
do
  defines={wire_connector_id={pole_copper=5}}
  local world={}
  local function ent(e)
    e.valid=true; e.unit_number=#world+1; e.electric_network_id=e.net or 7
    local w=(e.size or 1)/2
    e.bounding_box={left_top={x=e.position.x-w,y=e.position.y-w},right_bottom={x=e.position.x+w,y=e.position.y+w}}
    e.prototype=e.prototype or {electric_energy_source_prototype=e.type~='container' and {} or nil}
    world[#world+1]=e; return e
  end
  local function pole(x,y)
    local e=ent{name='small-electric-pole',type='electric-pole',position={x=x,y=y},prototype={get_supply_area_distance=function() return 2.5 end}}
    e.wires={}
    e.get_wire_connector=function(id) assert(id==5); local c={connections={}}; for _,o in ipairs(e.wires) do c.connections[#c.connections+1]={target={owner=o}} end; return c end
    return e
  end
  local function wire(a,b) a.wires[#a.wires+1]=b; b.wires[#b.wires+1]=a end
  local surface={find_entities_filtered=function(f)
    local out={}
    local types=f.type and (type(f.type)=='table' and f.type or {f.type})
    for _,e in ipairs(world) do
      local ok=true
      if types then ok=false; for _,t in ipairs(types) do if e.type==t then ok=true end end end
      local q=e.position
      if ok and f.radius then ok=((q.x-f.position.x)^2+(q.y-f.position.y)^2)<=f.radius^2 end
      if ok and f.area then local b=e.bounding_box; ok=b.right_bottom.x>f.area[1][1] and b.left_top.x<f.area[2][1] and b.right_bottom.y>f.area[1][2] and b.left_top.y<f.area[2][2] end
      if ok then out[#out+1]=e end
    end
    return out
  end}
  local G,A,B,C,D,E,F=pole(0,0),pole(10,0),pole(20,0),pole(30,0),pole(30,10),pole(40,0),pole(10,5)
  wire(G,A); wire(A,B); wire(G,F); wire(F,B); wire(B,C); wire(C,D); wire(C,E)
  ent{name='steam-engine',type='generator',position={x=1.5,y=0},size=3}
  ent{name='electric-mining-drill',type='mining-drill',position={x=20,y=2},size=3}
  ent{name='pumpjack',type='mining-drill',position={x=30,y=12},size=3}
  ent{name='electric-mining-drill',type='mining-drill',position={x=41,y=1},size=3}
  ent{name='inserter',type='inserter',position={x=9.5,y=1.5}}  -- covered by A alone; A is not a cut (F runs beside it)
  local fragile=dofile('mod/agent-harness_0.1.0/fragile.lua'){position=function(v) return v end,
    integer=function(v,d,lo,hi,name) v=v==nil and d or v; assert(v>=lo and v<=hi,name); return v end}
  local p={surface=surface,force='player'}
  local r=fragile.read(p,{position={x=0,y=0}})
  eq(r.fragile_total,3); eq(r.poles,7); eq(r.generators,1)
  -- G is the one pole covering the steam engine: its loss cuts everything.
  eq(r.fragile[1].line,'small-electric-pole (0,0): its loss cuts 6 poles and 4 machines (2 electric-mining-drill, 1 inserter, 1 pumpjack) around (25.3,6.5), from (9.5,1) to (41,12), off from all generation')
  table.remove(r.fragile,1)
  eq(r.fragile[1].line,'small-electric-pole (20,0): its loss cuts 3 poles and 3 machines (2 electric-mining-drill, 1 pumpjack) around (30.5,6.5), from (20,1) to (41,12), off from all generation')
  eq(r.fragile[2].line,'small-electric-pole (30,0): its loss cuts 2 poles and 2 machines (1 electric-mining-drill, 1 pumpjack) around (35.5,6.5), from (30,1) to (41,12), off from all generation')
  eq(r.line,'network 7, 7 poles in the area, 1 generators: 3 poles whose loss alone cuts machines off from all generation')
  -- An outpost read: the area around it, the wires to the base counted as power.
  r=fragile.read(p,{position={x=30,y=0},radius=15})
  eq(r.wires_out,2); eq(r.poles,4); eq(r.fragile_total,2); eq(r.fragile[1].machines_cut,3)
  -- No generator and no wire out.
  pole(60,0)
  r=fragile.read(p,{position={x=60,y=0},radius=8})
  has(r.line,'no generator in 1 poles\' areas and no wire leaving the area')
  -- A second link beside B: no cut left at B; C still cuts.
  local B2=pole(20,5); wire(F,B2); wire(B2,C)
  r=fragile.read(p,{position={x=0,y=0}})
  eq(r.fragile_total,2); has(r.fragile[2].line,'small-electric-pole (30,0)')
end
print('d15_batch4 3 fragile: ok')

-- 4 (Haiku, Muse): personal requests not filled, and why; the alert for a network with no logistic robots. ---------
do
  defines={logistic_member_index={character_requester=1}}
  game={tick=100}
  local inv={get_item_count=function(q) return ({['repair-pack']=2,['iron-plate']=500})[q.name] or 0 end}
  local net={network_id=12,all_logistic_robots=0,available_logistic_robots=0,get_item_count=function(q) return ({['repair-pack']=40})[q.name] or 0 end}
  local pt={enabled=true,logistic_network=net,filters={{name='repair-pack',quality='normal',count=10},{name='iron-plate',quality='normal',count=100},{name='coal',quality='normal',count=50}},
    targeted_items_deliver={}}
  local c={valid=true,position={x=-10,y=562},get_logistic_point=function() return pt end,get_main_inventory=function() return inv end}
  local p={character=c}
  local P=dofile('mod/agent-harness_0.1.0/personal.lua'){}
  local rows=P.unfilled(p)
  eq(#rows,2)
  eq(rows[1].line,'repair-pack: hold 2 of 10; logistic network 12 where you stand has no logistic robots (its roboports hold none)')
  net.all_logistic_robots=5
  rows=P.unfilled(p)
  eq(rows[1].line,'repair-pack: hold 2 of 10; all 5 logistic robots of network 12 are busy now; it holds 40 repair-pack')
  eq(rows[2].line,'coal: hold 0 of 50; logistic network 12 holds no coal robots can take (its provider, storage and buffer chests: none, or all reserved)')
  net.available_logistic_robots=3; pt.targeted_items_deliver={{name='repair-pack',quality='normal',count=4}}
  eq(P.unfilled(p)[1].line,'repair-pack: hold 2 of 10 (4 on the way); robots are bringing 4; network 12 holds 40 more')
  pt.logistic_network=nil; c.surface={find_logistic_network_by_position=function() return nil end}
  eq(P.unfilled(p)[1].why,'no logistic network where you stand (-10,562) (no roboport\'s logistic area covers it)')
  pt.enabled=false
  has(P.unfilled(p)[1].why,'your personal logistics are switched off')
  -- The alert: unfilled 60 s or more in a network with 0 logistic robots, once, again after 10 minutes.
  pt.enabled=true; pt.logistic_network=net; net.all_logistic_robots=0; pt.targeted_items_deliver={}
  local h={}
  eq(P.lines(p,h),nil,'first seen now')
  game.tick=100+3600
  local l=P.lines(p,h)
  eq(l[1],'your personal requests repair-pack 2 of 10, coal 0 of 50 sit unfilled: logistic network 12 where you stand (-10,562) has no logistic robots (a network\'s logistic robots are those in its roboports\' robot slots and in the air)')
  game.tick=game.tick+600
  eq(P.lines(p,h),nil,'told once')
  game.tick=game.tick+36000
  has(P.lines(p,h)[1],'repair-pack 2 of 10')
end
print('d15_batch4 4 personal: ok')

-- 5 (Opus): burner machines no inserter feeds, running dry within 10 minutes. ----------------------------------------
do
  defines={entity_status={working=1,low_power=2,no_fuel=3},inventory={chest=1}}
  prototypes={item={coal={fuel_value=4e6},['copper-ore']={fuel_value=0}}}
  game={tick=0,surfaces={}}
  local st={}
  local surface={index=1,name='nauvis'}
  local list={}
  local all_inserters={}
  surface.find_entities_filtered=function(f) local out={} for _,i in ipairs(all_inserters) do if (i.position.x-f.position.x)^2+(i.position.y-f.position.y)^2<=f.radius^2 then out[#out+1]=i end end return out end
  game.surfaces={nauvis=surface}
  local force={name='player'}
  local function furnace(x,y,coal,status)
    local e={valid=true,type='furnace',name='stone-furnace',unit_number=#list+1,position={x=x,y=y},surface=surface,force=force,status=1,coal=30,
      burner={remaining_burning_fuel=0},prototype={get_max_energy_usage=function() return 90000/60 end,burner_prototype={effectivity=1}},
      bounding_box={left_top={x=x-1,y=y-1},right_bottom={x=x+1,y=y+1}}}
    e.later={coal,status or 1}
    e.get_fuel_inventory=function() return {get_contents=function() return e.coal>0 and {{name='coal',count=e.coal}} or {} end} end
    list[#list+1]=e; return e
  end
  -- 90 kW on coal (4 MJ): 1.35 coal a minute. 5 coal: about 3.7 min; 20 coal: about 14.8 min.
  for k=1,4 do furnace(k*2,0,5) end
  furnace(10,0,20)
  furnace(12,0,0,3)
  furnace(16,0,0,3).status=3  -- never seen working with fuel: an abandoned one is not counted
  list[#list].coal=0
  local fed=furnace(14,0,5)
  all_inserters[1]={position={x=14,y=-1.5},drop_target=fed,held_stack={valid_for_read=true,name='coal',count=1},filter_slot_count=0}
  local B=dofile('mod/agent-harness_0.1.0/burnerfuel.lua'){state=function() return st end,fuel_users=function() return list end}
  game.tick=60; B.tick(60)
  eq(#st.burnerfuel.alerts,0,'30 coal each: over 10 minutes')
  for _,e in ipairs(list) do if e.unit_number~=7 then e.coal,e.status=e.later[1],e.later[2] end end
  local m=B.minutes(list[1]); assert(m>3.6 and m<3.8,m)
  for t=120,600,60 do game.tick=t; B.tick(t) end
  local h={}
  local l=B.lines({force=force},h)
  eq(l[1],'stone-furnace near (6,0), fed by hand or by order (no inserter brings them fuel): 4 run dry within 10 min at full use (coal; the first in about 3 min); 1 is out of fuel now')
  eq(#l,1)
  for t=660,6000,60 do game.tick=t; B.tick(t) end
  eq(B.lines({force=force},h),nil,'told once')
end
print('d15_batch4 5 burner fuel: ok')

-- 6 (Sonnet): requester chests: what is over the request leaves; one item in every slot. ----------------------------
do
  defines={logistic_member_index={logistic_container=1},inventory={chest=1}}
  local items={['iron-plate']=100}
  local slots=48
  local inv={get_item_count=function(n) return items[n] or 0 end,count_empty_stacks=function() return 0 end,
    get_contents=function() local out={} for n,c in pairs(items) do out[#out+1]={name=n,count=c} end table.sort(out,function(a,b) return a.name<b.name end) return out end}
  setmetatable(inv,{__len=function() return slots end})
  local pt={trash_not_requested=false,filters={{name='iron-plate',count=10,max_count=20},{name='copper-plate',count=10}}}
  local ins={drop_target=nil,name='fast-inserter',position={x=1.5,y=0.5},pickup_target={valid=true,name='transport-belt',position={x=2.5,y=0.5}}}
  local e={valid=true,prototype={logistic_mode='requester'},position={x=0.5,y=0.5},force='player',
    get_inventory=function() return inv end,get_logistic_point=function() return pt end,
    surface={find_entities_filtered=function() return {ins} end}}
  ins.drop_target=e
  local R=dofile('mod/agent-harness_0.1.0/reqchest.lua'){}
  eq(R.over(e,'iron-plate'),'iron-plate: the chest holds 100, over its request max 20: the game moves the 80 over it to the chest\'s trash slots, and robots carry them to storage')
  items['copper-plate']=100
  eq(R.over(e,'copper-plate'),nil,'no max, trash unrequested off: it stays')
  pt.trash_not_requested=true
  has(R.over(e,'copper-plate'),'over its request 10 with trash unrequested on: the game moves the 90 over it')
  items.coal=5
  has(R.over(e,'coal'),'coal is not requested here and trash unrequested is on: the game moves all 5')
  items={['iron-plate']=4800}
  eq(R.one_item(e).line,'one item fills every slot: iron-plate 4800 in all 48 slots (it requests 10..20), so copper-plate cannot come in; put in by fast-inserter (1.5,0.5) from transport-belt (2.5,0.5)')
  items={['iron-plate']=4000,['copper-plate']=5}
  eq(R.one_item(e),nil,'two items')
end
print('d15_batch4 6 requester chests: ok')

-- 7 (Sonnet): a platform's arrival estimated before it leaves its stop. -------------------------------------------
do
  defines={space_platform_state={on_the_path=9},inventory={hub_main=1,hub_trash=2}}
  prototypes={space_connection={['gleba-nauvis']={from={name='nauvis'},to={name='gleba'},length=15000}}}
  game={tick=10000}
  local st={}
  local F=dofile('mod/agent-harness_0.1.0/freight.lua'){state=function() return st end}
  local pl={valid=true,index=3,name='Starling',state=1,paused=false,space_location={name='gleba'},
    schedule={current=1,records={{station='gleba',wait_conditions={{type='time',ticks=3600},{type='all_requests_satisfied'}}},{station='nauvis',wait_conditions={{type='time',ticks=1800}}}}}}
  st.freight={[3]={segs={{kind='stop',at='gleba',start=9400}},speed=2}}  -- 2 km a tick: 120 km/s
  local r=F.before_departure(pl,'nauvis')
  eq(r.after_s,175); eq(r.eta_s,nil)
  eq(r.line,'ETA 175s after gleba: all_requests_satisfied: leaves gleba when time 60s and all_requests_satisfied; gleba->nauvis 15000 km at 120 km/s (its last speed): 125s')
  pl.schedule.records[1].wait_conditions={{type='time',ticks=3600}}
  r=F.before_departure(pl,'nauvis')
  eq(r.eta_s,175); has(r.line,'ETA 175s before departure: leaves gleba when time 60s')
  eq(select(2,F.before_departure(pl,'vulcanus')),'its schedule does not go to vulcanus')
  st.freight[3].speed=nil
  eq(select(2,F.before_departure(pl,'nauvis')),'no flying speed seen yet for Starling')
  -- waiteta uses it while no leg is flown.
  st.freight[3].speed=2
  local W=dofile('mod/agent-harness_0.1.0/waiteta.lua'){before_departure=function(a,b) return F.before_departure(a,b) end}
  local row=W.estimate({},{['until']='platform_arrived',platform='Starling',location='nauvis'},false,{platform=pl},{})
  eq(row.eta_s,175); has(row.line,'platform_arrived Starling: ETA 175s (before departure: leaves gleba when time 60s')
end
print('d15_batch4 7 platform arrival: ok')

-- 8 (Muse): what automatic launch waits for. -------------------------------------------------------------------------
do
  defines={logistic_member_index={rocket_silo_requester=4}}
  prototypes={item={['low-density-structure']={weight=5000}},utility_constants={rocket_lift_weight=1000000}}
  local net={get_item_count=function() return 30 end}
  local pt={filters={{name='low-density-structure',count=200}}}
  local silo={position={x=15.5,y=59.5},surface={planet={name='nauvis'},find_logistic_network_by_position=function() return net end},
    transitional_request_target={valid=true,name='Starling'},get_logistic_point=function() return pt end}
  local hub={valid=true,get_item_count=function() return 0 end,get_logistic_sections=function() return {sections_count=1,get_section=function() return {active=true,
    filters={{value={name='low-density-structure'},min=50,import_from={name='nauvis'}}}} end} end}
  local force={platforms={{valid=true,name='Starling',space_location={name='nauvis'},hub=hub}}}
  local S=dofile('mod/agent-harness_0.1.0/silo.lua'){}
  eq(S.auto_wait(silo,force,{{name='low-density-structure',count=14}}),'filling a rocket for Starling: low-density-structure 14 of 200 aboard (a full rocket by weight, 5 kg each); its network holds 30 more, under the 186 it still waits for; it goes up once the rocket holds what the silo requests (on 2.0.77 a full rocket of the item, or the request\'s min payload)')
  silo.transitional_request_target=nil
  eq(S.auto_wait(silo,force,{}),'no platform taken up now; above nauvis: Starling asks low-density-structure 50 (holds 0, lacks 50), no min payload: a rocket waits for a full one, 200 by weight, the silo\'s network holds 30, under the 200 a rocket waits for')
end
print('d15_batch4 8 silo: ok')

-- 9 (Gemini, 21:40): train {stops: true}: every stop of ours on a surface. ------------------------------------------
do
  defines={train_state={},signal_state={}}
  prototypes={entity={}}
  local s1={valid=true,unit_number=1,backer_name='Scrap North',position={x=-41,y=93},trains_limit=2,trains_count=1,connected_rail={name='straight-rail',position={x=-43,y=93}}}
  local s2={valid=true,unit_number=2,backer_name='Iron Drop',position={x=1,y=193},trains_count=0,connected_rail=nil}
  local surface={name='fulgora'}
  game={get_surface=function(n) return n=='fulgora' and surface or nil end,train_manager={
    get_train_stops=function(f) assert(f.surface==surface) return {s1,s2} end,
    get_trains=function() return {{id=13,station=nil,path_end_stop=s1,front_stock={valid=true,position={x=-43,y=110}}}} end}}
  local T=dofile('mod/agent-harness_0.1.0/trains.lua'){}
  local r=T.handlers.train({surface={name='nauvis'},force='player'},{stops=true,surface='fulgora'})
  eq(r.count,2)
  eq(r.stops[1].line,'Iron Drop (1,193): limit none, 0 trains on the way or there; rail none: no straight rail beside it on the side that serves its direction')
  eq(r.stops[2].line,'Scrap North (-41,93): limit 2, 1 train on the way or there (train 13 heading there (front (-43,110))); rail straight-rail (-43,93)')
  fails(function() T.handlers.train({surface=surface,force='player'},{stops=true,position={x=0,y=0}}) end,'stops takes surface only')
end
print('d15_batch4 9 train stops: ok')

-- 11 (Opus): smaller margins verified over every leg left in a via chain, and for {distance: N}. ----------------------
do
  game={tick=0,forces={player={name='player'},enemy={name='enemy'}}}
  prototypes={entity={['biter-spawner']={result_units={}}}}
  defines=defines or {}
  local force=game.forces.player
  force.get_friend=function() return false end
  force.get_cease_fire=function() return false end
  local state,paths,asked={},{},{}
  local surface={name='nauvis',index=1}
  local hazard={valid=true,name='biter-spawner',type='unit-spawner',position={x=50,y=42.5},force=game.forces.enemy}
  surface.find_entities_filtered=function() return {hazard} end
  surface.request_path=function(a) asked[#asked+1]=a; return #asked end
  local p={index=1,position={x=0,y=0},surface=surface,force=force,walking_state={walking=false},
    character={prototype={collision_box={left_top={x=-0.2,y=-0.2},right_bottom={x=0.2,y=0.2}},collision_mask={layers={player=true}}}}}
  package.loaded.avoid=nil; package.loaded.margin_probe=nil
  local A=require('avoid'){state=function() return state end,charted=function() return true end,leg=function() return false end}
  local P=require('margin_probe'){avoid=A,paths=function() return paths end}
  local function run(n)
    local count=0
    while P.tick(p,n) do
      game.tick=game.tick+1; count=count+1; assert(count<2000)
      local q=n.margin_probe
      if q.id then local r=asked[q.id]; P.on_path(n,{id=q.id,path={{position=r.start},{position={x=(r.start.x+r.goal.x)/2,y=(r.start.y+r.goal.y)/2}},{position=r.goal}}}) end
    end
    return n.margin_probe.result
  end
  -- A via chain: the leg to (100,0) failed; the rest of the chain goes on to (100,100) then (0,100).
  local n={position={x=100,y=0},path_state='unsafe',foes={mode=A.mode(4),goal={x=100,y=0}},via={index=1,points={{x=100,y=0},{x=100,y=100}},final={x=0,y=100}}}
  local r=run(n)
  eq(r.legs,3); eq(r.to.x,0); eq(r.to.y,100)
  has(r.line,'the 3 legs left in the via chain (0,0) to (0,100)')
  has(r.method,'every leg left in the chain')
  -- {distance: N}: smaller distances are tried (before, the check started below 0 and verified nothing).
  n={position={x=100,y=0},path_state='unsafe',foes={mode=A.mode({distance=12}),goal={x=100,y=0}}}
  r=run(n)
  eq(r.requested_distance,12); assert(r.largest_verified_distance and r.largest_verified_distance<12,tostring(r.largest_verified_distance))
  has(r.line,'(avoid_enemies {distance: ')
end
print('d15_batch4 11 via margins: ok')

-- 12 (Muse): a repeating loop's hand steps walk into reach (walk: true unless the step says walk). ------------------
do
  game={tick=0}
  local st,seen={},{}
  local players={[1]={index=1}}
  local handlers={
    collect=function(_,a) seen[#seen+1]={action='collect',walk=a.walk}; return {} end,
    transfer=function(_,a) seen[#seen+1]={action='transfer',walk=a.walk}; return {} end,
    craft=function(_,a) seen[#seen+1]={action='craft',walk=a.walk}; return {} end}
  local S=dofile('mod/agent-harness_0.1.0/scheduler.lua'){state=function() return st end,player=function(i) return players[i] end,handlers=handlers,
    busy=function() return false end,stop=function() end,stop_index=function() end,condition=function() return false end,validate_condition=function() end}
  S.handlers.queue_repeat(players[1],{steps={{action='collect',args={position={x=10,y=0},item='yumako'}},
    {action='transfer',args={position={x=50,y=0},direction='to_entity',item='yumako',walk=false}},
    {action='transfer',args={from='nearest',item='coal'}},{action='craft',args={recipe='x'}}},interval_ticks=60})
  for _=1,5 do game.tick=game.tick+1; S.tick() end
  eq(seen[1].walk,true,'collect walks'); eq(seen[2].walk,false,'walk: false kept'); eq(seen[3].walk,nil,'from nearest untouched'); eq(seen[4].walk,nil,'craft untouched')
  -- A plain submitted plan is not a loop: unchanged.
  seen={}
  S.handlers.queue_submit(players[1],{mode='replace',steps={{action='collect',args={position={x=10,y=0},item='yumako'}}}})
  for _=1,3 do game.tick=game.tick+1; S.tick() end
  eq(seen[1].walk,nil,'a submitted plan keeps its args')
end
print('d15_batch4 12 loop walk: ok')

-- 14 (Sol): cargo fills one rocket from a mix and says what is left over. --------------------------------------------
do
  prototypes={item={explosives={weight=2000,stack_size=50},['low-density-structure']={weight=5000,stack_size=50},['iron-plate']={weight=1000,stack_size=100}},
    utility_constants={rocket_lift_weight=1000000}}
  local C=dofile('mod/agent-harness_0.1.0/cargo.lua'){}
  local r=C.one_rocket({{name='explosives',count=375},{name='low-density-structure',count=50}},1000000,20)
  eq(r.line,'one rocket: explosives 375 (750 kg) + low-density-structure 50 (250 kg) = 1000 of 1000 kg, 9 of 20 slots; full by weight; nothing left over')
  r=C.one_rocket({{name='explosives',count=400},{name='low-density-structure',count=50}},1000000,20)
  eq(r.line,'one rocket: explosives 400 (800 kg) + low-density-structure 40 (200 kg) = 1000 of 1000 kg, 9 of 20 slots; full by weight; left over: low-density-structure 10')
  r=C.one_rocket({{name='explosives',count=375}},1000000,20,'low-density-structure')
  eq(r.items[2].count,50); eq(r.items[2].top_up,true); eq(r.left_over,nil)
  r=C.one_rocket({{name='iron-plate',count=200}},1000000,20)
  eq(r.line,'one rocket: iron-plate 200 (200 kg) = 200 of 1000 kg, 2 of 20 slots; room left 800 kg, 18 slots; nothing left over')
end
print('d15_batch4 14 cargo: ok')

-- 15 (Opus): outpost: one queued tour (construct, rearm, wire); turrets out of robot reach under 20% ammo. ----------
do
  defines={inventory={turret_ammo=1},wire_connector_id={pole_copper=5},flow_precision_index={five_seconds=1}}
  prototypes={item={['firearm-magazine']={type='ammo',stack_size=200},['gun-turret']={}}}
  local world={}
  local function connector(e) return {can_wire_reach=function(o) return true end,owner=e} end
  local function pole(x,y,net,made)
    local e={valid=true,type='electric-pole',name='small-electric-pole',position={x=x,y=y},electric_network_id=net,
      electric_network_statistics={output_counts=made and {['steam-engine']=1} or {},get_flow_count=function() return made and 10 or 0 end}}
    e.get_wire_connector=function() return connector(e) end
    world[#world+1]=e; return e
  end
  pole(0,0,1,true); pole(6,0,2,false)
  local tinv={get_item_count=function() return 5 end,get_contents=function() return {{name='firearm-magazine',count=5}} end}
  world[#world+1]={valid=true,type='ammo-turret',name='gun-turret',position={x=3,y=3},get_inventory=function() return tinv end}
  world[#world+1]={valid=true,type='entity-ghost',ghost_name='gun-turret',position={x=4,y=4},ghost_prototype={items_to_place_this={{name='gun-turret',count=1}}}}
  local surface={find_entities_filtered=function(f)
    local out={}
    for _,e in ipairs(world) do if e.type==f.type then out[#out+1]=e end end
    return out
  end}
  local submitted
  local O=dofile('mod/agent-harness_0.1.0/outpost.lua'){position=function(v) return v end,
    integer=function(v,d,lo,hi,name) v=v==nil and d or v; assert(v>=lo and v<=hi,name); return v end,
    submit=function(_,a) submitted=a; return {plan={id=7,steps=#a.steps}} end}
  local p={surface=surface,force='player',get_item_count=function(n) return n=='firearm-magazine' and 100 or 0 end}
  local r=O.read(p,{position={x=0,y=0},radius=16,dry_run=true})
  eq(r.ghosts,1); eq(r.turrets_low,1); eq(r.unpowered_networks,1)
  eq(r.plan[1],'construct: 1 ghosts (1 gun-turret); short of gun-turret 1 (you hold 0)')
  eq(r.plan[2],'rearm: 1 of 1 ammo turrets under 20 rounds, with firearm-magazine (you hold 100)')
  eq(r.plan[3],'wire: small-electric-pole (6,0) (network 2, no power) to small-electric-pole (0,0) (network 1)')
  eq(submitted,nil,'dry run queues nothing')
  r=O.read(p,{position={x=0,y=0},radius=16})
  eq(r.queued,3); eq(submitted.steps[3].action,'wire'); eq(submitted.steps[2].args.ammo,'firearm-magazine'); eq(submitted.steps[1].on_fail,'skip')
  -- pushalerts: a turret with 30 of 400 rounds where no construction robot reaches.
  local PA=dofile('mod/agent-harness_0.1.0/pushalerts.lua'){state=function() return {} end}
  local slots={{valid_for_read=true,name='firearm-magazine'},{valid_for_read=false}}
  local inv=setmetatable({get_item_count=function() return 30 end},{__index=function(_,k) return slots[k] end,__len=function() return 2 end})
  local t={name='gun-turret',position={x=-15,y=558},force='player',surface={find_logistic_networks_by_construction_area=function() return {} end}}
  eq(PA.outpost_low(t,inv),'gun-turret (-15,558): 30 of 400 firearm-magazine (7%)')
  t.surface.find_logistic_networks_by_construction_area=function() return {{}} end
  eq(PA.outpost_low(t,inv),nil,'robots reach it')
end
print('d15_batch4 15 outpost: ok')

-- F1 (Astra, 3 times): deconstruct of ghosts: a removed ghost is invalid at once; never fail for an entity gone. -----
do
  defines={input_action={}}
  game={create_inventory=function() return {[1]={},destroy=function() end} end}
  prototypes={entity={}}
  local force={name='player',is_chunk_charted=function() return true end}
  local list={}
  local function ghost(name,also)
    local g={valid=true,type='entity-ghost',name='entity-ghost',ghost_name=name,force=force,minable=true}
    setmetatable(g,{__index=function(t,k) if not rawget(t,'alive') then error('LuaEntity API call when LuaEntity was invalid.') end end})
    g.alive=true
    local real={}
    for k,v in pairs(g) do real[k]=v end
    -- Every field read errors once it is gone, as the engine's do.
    local e=setmetatable({},{__index=function(_,k)
      if k=='valid' then return real.alive end
      if not real.alive then error('LuaEntity API call when LuaEntity was invalid.') end
      if k=='to_be_deconstructed' then return function() return false end end
      if k=='order_deconstruction' then return function() real.alive=false; if also then also() end; return true end end
      return real[k]
    end})
    return e,real
  end
  local g1,r1=ghost('transport-belt')
  local g2,r2=ghost('inserter')
  local g3,r3=ghost('inserter')
  -- Removing g2 takes g3 with it (a ghost under another).
  getmetatable(g2).__index=(function(old) return function(t,k)
    if k=='order_deconstruction' and r2.alive then return function() r2.alive=false; r3.alive=false; return true end end
    return old(t,k) end end)(getmetatable(g2).__index)
  list={g1,g2,g3}
  local p={index=1,position={x=0,y=0},force=force,surface={find_entities_filtered=function() return list end}}
  local B=dofile('mod/agent-harness_0.1.0/blueprints.lua'){position=function(v) return v end,real=function(q) return q end}
  local r=B.handlers and B.handlers.deconstruct or B.deconstruct
  local out=r(p,{area={left_top={x=48,y=217},right_bottom={x=49,y=218}},entity_types={'entity-ghost'}})
  eq(out.changed,2); eq(out.ghosts_removed,2); eq(out.ghosts_removed_by_name,'1 inserter, 1 transport-belt')
  has(out.gone,'1 found in the area were gone by the time they were reached')
end
print('d15_batch4 F1 deconstruct ghosts: ok')

-- F2 (Muse): a gathering already told wakes again only when it changes. ----------------------------------------------
do
  game={tick=1000}
  local s={active={}}
  local U=dofile('mod/agent-harness_0.1.0/urgent.lua'){state=function() return s end,who=function(p) return p.name end,
    attack_line=function(v) return 'attack' end,claim_surface=function() return 'nauvis' end,claim_stale=function() return false end,
    platform_hears=function() return false end,power_view=function() return nil end}
  local p={index=1,name='muse',surface={name='nauvis'},character={valid=true,position={x=82,y=-4},health=250},force={platforms={}}}
  s.attack_groups={}
  local seq=0
  local function gather(size,at,target)
    game.tick=game.tick+600; seq=seq+1
    s.attack_groups[#s.attack_groups+1]={seq=seq,tick=game.tick,size=size,position=at,target=target,surface='nauvis'}
    return U.check(p,U.base(p,40) and {tick=game.tick-1,hub={},radius=40})
  end
  has(gather(8,{x=187,y=-14},{x=96,y=-30}),'enemy group of 8')
  eq(gather(12,{x=187,y=-14},{x=96,y=-30}),nil,'same spot, not much larger')
  eq(gather(4,{x=191,y=1},{x=96,y=-30}),nil,'within 24 tiles of the spot')
  has(gather(21,{x=187,y=-14},{x=96,y=-30}),'again: it is larger: 21 (the largest told was 8)')
  eq(gather(19,{x=187,y=-14},{x=96,y=-38}),nil)
  -- Its target 15+ tiles nearer.
  has(gather(19,{x=187,y=-14},{x=90,y=-8}),'again: it heads 21 tiles nearer you than before (9, was 30)')
  -- Our structures near its target hit since (49 tiles from the character: no attack wake of its own).
  s.damage={a={id=5,at={x=130,y=-20},damage=40,hits=2,last=game.tick+300,surface='nauvis'}}
  game.tick=game.tick+300
  has(gather(19,{x=187,y=-14},{x=110,y=-20}),'again: our structures near its target took damage since at (130,-20)')
  -- Another spot is a new gathering.
  s.damage=nil
  has(gather(5,{x=100,y=60},{x=90,y=10}),'enemy group of 5')
end
print('d15_batch4 F2 gatherings: ok')

-- F3 (Haiku): a network's repair packs in its roboports' material slots and its chests, on its line. -----------------
do
  defines={inventory={roboport_material=7}}
  prototypes={item={['repair-pack']={type='repair-tool'}}}
  local function port(x,packs)
    local mat={get_contents=function() return packs>0 and {{name='repair-pack',count=packs}} or {} end}
    return {valid=true,position={x=x,y=0},get_inventory=function(i) assert(i==7); return mat end}
  end
  local cells={{owner=port(0,10),logistic_radius=25,construction_radius=55},{owner=port(50,0),logistic_radius=25,construction_radius=55}}
  local ln={network_id=120,all_logistic_robots=0,available_logistic_robots=0,all_construction_robots=20,available_construction_robots=20,cells=cells,
    get_item_count=function(n) return n=='repair-pack' and 0 or 0 end}
  local N=dofile('mod/agent-harness_0.1.0/networks.lua'){state=function() return {} end}
  local v=N.logistic_view(ln)
  eq(v.repair_packs,10); eq(v.ports_without_packs,1)
  has(v.text,'; repair packs: 10 in roboport material slots (1 of 2 roboports hold none), 0 in its chests')
end
print('d15_batch4 F3 repair packs: ok')

-- F4 (Astra): a belt reading its entire belt: the line's extent, what ends it, its contents against the wires. ----
do
  defines={wire_connector_id={circuit_red=1,circuit_green=2}}
  local function belt(x,typ,line,items)
    local b={valid=true,name=typ=='underground-belt' and 'underground-belt' or 'transport-belt',type=typ or 'transport-belt',position={x=x,y=0}}
    local l={id=line,get_contents=function() return items end}
    l.line_equals=function(o) return o.id==l.id end
    local empty={id=line,get_contents=function() return {} end,line_equals=l.line_equals}
    b.get_transport_line=function(k) return k==1 and l or empty end
    b.belt_neighbours={inputs={},outputs={}}
    return b
  end
  local b1,b2,u=belt(0.5,nil,'A',{{name='iron-ore',count=4}}),belt(1.5,nil,'A',{{name='iron-ore',count=3}}),belt(2.5,'underground-belt','A',{})
  local u2=belt(6.5,'underground-belt','B',{{name='iron-ore',count=8}})
  u.neighbours=u2
  b1.belt_neighbours.outputs={b2}; b2.belt_neighbours.inputs={b1}; b2.belt_neighbours.outputs={u}; u.belt_neighbours.inputs={b2}
  b2.get_circuit_network=function(w) return w==1 and {signals={{signal={name='iron-ore'},count=7}}} or nil end
  local C=dofile('mod/agent-harness_0.1.0/circuits.lua'){}
  eq(C.belt_segment(b2),'this tile\'s line runs 3 tiles: back at transport-belt (0.5,0) (the belt starts there), on at underground-belt (2.5,0) (an underground; past it is not this line); it holds 7 iron-ore')
  b2.get_circuit_network=function(w) return w==1 and {signals={{signal={name='iron-ore'},count=15}}} or nil end
  has(C.belt_segment(b2),'(the wires read: iron-ore 15 on the wires, which includes anything else on those networks)')
end
print('d15_batch4 F4 belt segment: ok')

-- F9 (Sol): deconstruct and cancel count only our entities' marks, by name; items on the ground are left to
-- items_on_ground. ----------------------------------------------------------------------------------------------------
do
  defines={input_action={}}
  local force={name='player',is_chunk_charted=function() return true end}
  local neutral={name='neutral'}
  local function ent(t,n,f,marked)
    local e={valid=true,type=t,name=n,force=f,minable=true,marked=marked}
    e.to_be_deconstructed=function() return e.marked end
    e.cancel_deconstruction=function() e.marked=false end
    e.order_deconstruction=function() e.marked=true; return true end
    return e
  end
  local list={ent('assembling-machine','chemical-plant',force,true),ent('inserter','fast-inserter',force,true)}
  for _=1,3 do list[#list+1]=ent('item-entity','item-on-ground',neutral,true) end
  local p={index=1,position={x=0,y=0},force=force,surface={find_entities_filtered=function() return list end}}
  local B=dofile('mod/agent-harness_0.1.0/blueprints.lua'){position=function(v) return v end,real=function(q) return q end}
  local out=B.deconstruct(p,{area={left_top={x=-32,y=-32},right_bottom={x=32,y=32}},cancel=true})
  eq(out.cancelled,2); eq(out.cancelled_by_name,'1 chemical-plant, 1 fast-inserter')
  eq(list[3].marked,true,'items on the ground keep their marks')
end
print('d15_batch4 F9 deconstruction counts: ok')

-- F5 (Luna): an inserter in one line: its condition and the signals on its wires now, wires, filter, pickup and drop. -
do
  defines={wire_connector_id={circuit_red=1,circuit_green=2,pole_copper=5},entity_status={disabled_by_control_behavior=9}}
  prototypes={item={['iron-ore']={}},fluid={},virtual_signal={},entity={},recipe={},space_location={},quality={}}
  local C=dofile('mod/agent-harness_0.1.0/circuits.lua'){}
  local belt={valid=true,name='transport-belt',position={x=8.5,y=1.5}}
  local furnace_belt={valid=true,name='transport-belt',position={x=10.5,y=2.5}}
  local cond={first_signal={name='iron-ore'},comparator='>',constant=0}
  local e={valid=true,type='inserter',name='fast-inserter',position={x=9.5,y=2.5},status=9,pickup_target=belt,drop_target=furnace_belt,
    filter_slot_count=5,use_filters=true,inserter_filter_mode='whitelist',held_stack={valid_for_read=false},
    get_filter=function(k) return k==1 and {name='iron-ore'} or nil end,
    get_control_behavior=function() return {circuit_condition=cond} end,
    get_circuit_network=function(w) return w==1 and {get_signal=function(s) return s.name=='iron-ore' and 0 or 0 end} or nil end}
  local c={enable='iron-ore > 0',enable_met=false,
    wires={red={{entity='decider-combinator',position={x=12.5,y=2},side='output'}}},networks={red={id=31,signals={{name='calcite',count=40}}}}}
  eq(C.inserter_line(e,c),'fast-inserter (9.5,2.5): enabled when iron-ore > 0 (on its wires: iron-ore 0): false now; it is off by its condition; red wire to decider-combinator (12.5,2) output; network 31 carries calcite 40; filter iron-ore; picks from transport-belt (8.5,1.5), drops into transport-belt (10.5,2.5)')
end
print('d15_batch4 F5 inserter line: ok')

-- F6 (Opus): an outpost's output gone to 0: wakes the drills' builders with the item, the rate it had and the cause. -
do
  game={tick=5000}
  defines={entity_status={working=1}}
  local drills={}
  local surface={find_entities_filtered=function() return drills end}
  game.get_surface=function() return surface end
  local s={losses={{id=77,surface='nauvis',box={-305,-320,-290,-308},first=4900,last=4990,total=30,names={['electric-mining-drill']=22},
    causes={['big-biter']=7},mined={coal={drills=22,per_min=402}},builders={opus=true}}}}
  local U=dofile('mod/agent-harness_0.1.0/urgent.lua'){state=function() return s end,who=function(p) return p.name end,
    attack_line=function() return 'attack' end,claim_surface=function() return 'nauvis' end,claim_stale=function() return false end,
    platform_hears=function() return false end,power_view=function() return nil end}
  local function agent(name) return {index=name=='opus' and 1 or 2,name=name,surface={name='nauvis'},character={valid=true,position={x=0,y=0},health=250},force={platforms={}}} end
  local base={tick=4800,hub={}}
  eq(U.check(agent('opus'),base),'outpost output: coal from drills at (-297,-314) is 0/min now, was about 402/min (22 drills destroyed by 7 big-biter; loss incident #77); no drill of ours mining coal works within 32 tiles there')
  eq(U.check(agent('sol'),base),nil,'not its builder, no claim there')
  -- A drill still mining coal there: no wake.
  s.losses[1].id=78; s.losses[1].out_check=nil
  drills={{valid=true,status=1,mining_target={prototype={mineable_properties={products={{name='coal'}}}}}}}
  eq(U.check(agent('opus'),base),nil,'coal still mined there')
end
print('d15_batch4 F6 outpost output: ok')

-- F7 (Sol): remote module requests say plainly nothing is installed; a heat budget for a heat network. --------------
do
  prototypes={entity={['heat-pipe']={heat_buffer_prototype={specific_heat=1000000,default_temperature=15}}}}
  local function part(name,x,t,c) return {valid=true,name=name,unit_number=x+100,position={x=x,y=0},temperature=t,prototype={heat_buffer_prototype={specific_heat=c}},heat_neighbours={}} end
  local tower=part('heating-tower',0,500,2500000)
  local pipes={}
  for i=1,10 do pipes[i]=part('heat-pipe',i,60,1000000) end
  tower.heat_neighbours={pipes[1]}
  for i=1,10 do pipes[i].heat_neighbours={pipes[i-1] or tower,pipes[i+1]} end
  local H=dofile('mod/agent-harness_0.1.0/heating.lua'){footprint=function() end}
  local r=H.budget({},pipes[5],21)
  eq(r.parts,11); eq(r.capacity_mj_per_c,12.5)
  -- mean (2.5*500+10*60)/12.5 = 148; with 21 pipes at 15: (1850+315)/33.5 = 64.6
  eq(r.mean_c,148); eq(r.after_c,64.6)
  has(r.line,'21 new heat pipes, each 1.0 MJ per C starting at 15 C, take the mean to 64.6 C (83.4 C lower)')
  has(r.line,'heat network of 11 parts (1 heating-tower, 10 heat-pipe): mean 148.0 C, lowest 60.0 C at heat-pipe (5,0), highest 500.0 C at heating-tower (0,0)')
end
print('d15_batch4 F7 heat budget: ok')
do
  prototypes={item={['efficiency-module']={}},quality={normal={}}}
  local net={network_id=44,all_construction_robots=0,available_construction_robots=0,get_item_count=function() return 6 end}
  local port={position={x=0,y=0},logistic_cell={construction_radius=55,logistic_network=net}}
  local e={surface={find_entities_filtered=function() return {port} end},force='player',position={x=10,y=10}}
  local Mo=dofile('mod/agent-harness_0.1.0/modules.lua'){}
  has(Mo.carrier(e,{{name='efficiency-module',quality='normal',count=3}},nil),'; network 44 has no construction robots: nothing is brought until it has some')
end
print('d15_batch4 F7 module requests: ok')
