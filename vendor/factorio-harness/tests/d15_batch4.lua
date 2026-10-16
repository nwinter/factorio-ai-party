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
  -- The feeder filtered to coal: stops there.
  world[#world].filter_slot_count=5; world[#world].use_filters=true; world[#world].get_filter=function(k) return k==1 and {name='coal'} or nil end
  r=trace.trace(p,{position={x=15.5,y=5.5},upstream=true})
  has(r.ingredients[1].line,'inserter (15.5,3.5) waiting_for_source_items filter coal does not let iron-ore through its filter')
  has(r.ingredients[1].line,'no inserter feeding it lets iron-ore through its filter')
  fails(function() trace.trace(p,{position={x=15.5,y=5.5},upstream=true,forward=true}) end,'upstream and forward go one way each')
  -- On the belt tile itself: both lanes walked with no one item; joins listed first first.
  r=trace.trace(p,{position={x=15.5,y=2.5},upstream=true})
  has(r.lanes[1].line,'items come onto it (first first): iron-ore joins the left lane at transport-belt (2.5,2.5) from inserter (2.5,3.5)')
  _=arm
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
