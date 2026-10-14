-- Run from repository root: lua tests/trace.lua
-- trace (trace.lua) against a fake engine: a machine's feeders and the chest next to the one its long inserter
-- reads (Grok, shift09 00:20); a forward walk from an asteroid collector down a belt and an underground pair to a
-- belt end full of a chunk nobody on it takes (Astra, 00:30); an item's routes through a filtered splitter to a lab,
-- a requester with no request, and a lab no route reaches (Luna, 00:20).
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(text,part) assert(text and tostring(text):find(part,1,true),tostring(text)..' lacks '..part) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
defines={inventory={chest=1,crafter_input=3,lab_input=4,asteroid_collector_output=8,hub_main=9},entity_status={}}
prototypes={item={['stone-brick']={type='item'},['iron-plate']={type='item'},['oxide-asteroid-chunk']={type='item'},
  ['metallic-asteroid-chunk']={type='item'},['chemical-science-pack']={type='tool'},['iron-ore']={type='item'}},recipe={}}
local function inv(items)
  items=items or {}
  local i={}
  i.get_item_count=function(name) return items[name] or 0 end
  i.get_contents=function() local out={} for k,v in pairs(items) do out[#out+1]={name=k,count=v,quality='normal'} end table.sort(out,function(a,b) return a.name<b.name end) return out end
  i.is_empty=function() return next(items)==nil end
  i.full=false
  i.can_insert=function() return not i.full end
  i.is_full=function() return i.full end
  return i
end
local surface={name='nauvis',valid=true}
local world={}
local n=0
local function ent(e)
  n=n+1; e.valid=true; e.unit_number=n; e.surface=e.surface or surface; e.force=e.force or 'player'; e.status=e.status or 'working'
  e.bounding_box=e.bounding_box or {left_top={x=e.position.x-0.5,y=e.position.y-0.5},right_bottom={x=e.position.x+0.5,y=e.position.y+0.5}}
  world[#world+1]=e
  return e
end
local function contains(list,v) for _,x in ipairs(list) do if x==v then return true end end return false end
surface.find_entities_filtered=function(f)
  local out={}
  local types=type(f.type)=='table' and f.type or {f.type}
  for _,e in ipairs(world) do
    local ok=e.valid and (f.type==nil or contains(types,e.type))
    if ok and f.position then ok=((e.position.x-f.position.x)^2+(e.position.y-f.position.y)^2)^0.5<=(f.radius or 0.5) end
    if ok then out[#out+1]=e end
  end
  return out
end
surface.get_tile=function() return {name='concrete'} end
local function crafter(x,y,name,recipe,input,output,status)
  local e=ent{name=name,type='assembling-machine',position={x=x,y=y},status=status or 'item_ingredient_shortage',
    bounding_box={left_top={x=x-1.5,y=y-1.5},right_bottom={x=x+1.5,y=y+1.5}}}
  local i,o=inv(input),inv(output)
  e.get_recipe=function() return recipe end
  e.get_inventory=function(id) if id==defines.inventory.crafter_input then return i end end
  e.get_output_inventory=function() return o end
  return e
end
local function chest(x,y,items,name,mode)
  local e=ent{name=name or 'iron-chest',type=mode and 'logistic-container' or 'container',position={x=x,y=y},prototype={logistic_mode=mode}}
  e.inv=inv(items)
  e.get_inventory=function(id) if id==defines.inventory.chest then return e.inv end end
  e.get_logistic_sections=function() return {sections_count=0} end
  return e
end
local function lab(x,y,items)
  local e=ent{name='lab',type='lab',position={x=x,y=y},status='missing_science_packs'}
  local i=inv(items)
  e.get_inventory=function(id) if id==defines.inventory.lab_input then return i end end
  return e
end
local function inserter(x,y,name,pick,drop,o)
  o=o or {}
  local e=ent{name=name or 'inserter',type='inserter',position={x=x,y=y},status=o.status or 'working'}
  e.pickup_target,e.drop_target=pick,drop
  e.pickup_position=o.pickup or (pick and pick.position) or {x=x,y=y-1}
  e.drop_position=o.drop or (drop and drop.position) or {x=x,y=y+1}
  e.held_stack={valid_for_read=o.held~=nil,name=o.held and o.held[1],count=o.held and o.held[2]}
  e.filter_slot_count=o.filters and 5 or 0
  e.use_filters=o.filters~=nil
  e.inserter_filter_mode=o.mode or 'whitelist'
  e.get_filter=function(k) local f=o.filters and o.filters[k] return f and {name=f} or nil end
  if o.left~=nil then e.pickup_from_left_lane=o.left end
  if o.right~=nil then e.pickup_from_right_lane=o.right end
  return e
end
-- Belts face east: the left lane is the north half. A line's items are listed back to front.
local function line(e,k,items,internal)
  local l={owner=e,line_length=1,output_lines={},internal=internal or (e.unit_number..':'..k),items=items or {}}
  l.get_contents=function() local m={} for _,it in ipairs(l.items) do m[it]=(m[it] or 0)+1 end local out={} for name,c in pairs(m) do out[#out+1]={name=name,count=c} end return out end
  l.get_detailed_contents=function() local out={} for i,it in ipairs(l.items) do out[#out+1]={stack={valid_for_read=true,name=it,count=1},position=i*0.25} end return out end
  l.get_item_count=function(item) local c=0 for _,it in ipairs(l.items) do if it==item then c=c+1 end end return c end
  l.get_line_item_position=function() return {x=e.position.x,y=e.position.y+(k%2==1 and -0.25 or 0.25)} end
  l.line_equals=function(o) return o.internal==l.internal end
  return l
end
local function belt(x,y,lanes,internal,kind,name)
  local e=ent{name=name or 'transport-belt',type=kind or 'transport-belt',position={x=x,y=y},direction=4}
  e.lines={}
  for k=1,(kind=='underground-belt' and 4 or kind=='splitter' and 8 or 2) do e.lines[k]=line(e,k,(lanes or {})[k],internal and (internal..':'..(k%2==1 and 'L' or 'R'))) end
  e.get_max_transport_line_index=function() return #e.lines end
  e.get_transport_line=function(k) return e.lines[k] end
  e.belt_neighbours={inputs={},outputs={}}
  e.get_item_count=function(item) local c=0 for _,l in ipairs(e.lines) do c=c+l.get_item_count(item) end return c end
  return e
end
local function link(a,b) a.belt_neighbours.outputs[#a.belt_neighbours.outputs+1]=b end
local function feeds(a,b) for k=1,2 do a.lines[k].output_lines={b.lines[k]} end end
local force={name='player'}
force.current_research={name='chem-research',research_unit_ingredients={{name='chemical-science-pack'}}}
local function lookup(p,a)
  for _,e in ipairs(world) do
    if e.valid and e.type~='inserter' and e.type~='transport-belt' and math.abs(e.position.x-a.position.x)<0.6 and math.abs(e.position.y-a.position.y)<0.6 then return e end
  end
  for _,e in ipairs(world) do  -- a belt tile only when nothing else is there
    if e.valid and e.type=='transport-belt' and math.abs(e.position.x-a.position.x)<0.6 and math.abs(e.position.y-a.position.y)<0.6 then return e end
  end
  error('entity not found at ('..a.position.x..','..a.position.y..')',0)
end
local supply=require('supply'){status_name=function(e) return e.status end,position=function(v) return v end,integer=function(v,d) return v or d end}
local trace=require('trace'){supply=supply,entity=lookup,remote_entity=lookup,status_name=function(e) return e.status end,
  position=function(v) return {x=v.x,y=v.y} end,integer=function(v,d) return v or d end}
force.is_chunk_visible=function() return true end
local p={surface=surface,force=force,position={x=0,y=0}}

-- 1. Grok: the wall assembler's long inserter reads the chest without bricks; the bricks sit in the chest beside it.
local wall={name='stone-wall',ingredients={{type='item',name='stone-brick',amount=5}},products={{name='stone-wall'}}}
local A=crafter(0.5,0.5,'assembling-machine-2',wall,{},{})
local C1=chest(0.5,4.5,{['iron-plate']=10})
local C2=chest(1.5,4.5,{['stone-brick']=200})
inserter(0.5,2.5,'long-handed-inserter',C1,A,{status='waiting_for_source_items'})
local r=trace.trace(p,{position={x=0.5,y=0.5}})
eq(r.entity,'assembling-machine-2'); eq(r.crafting,'recipe stone-wall'); eq(#r.ingredients,1)
eq(r.ingredients[1].text,'stone-brick: has 0 of 5; long-handed-inserter (0.5,2.5) waiting_for_source_items takes from iron-chest (0.5,4.5) holding 0; 200 in iron-chest (1.5,4.5), read by nothing')
eq(r.ingredients[1].unread.holds,200); eq(r.feeders[1].from,'iron-chest (0.5,4.5) holding 10 iron-plate')
-- A chest some inserter reads is not "read by nothing".
local reader=inserter(2.5,4.5,'inserter',C2,nil)
r=trace.trace(p,{position={x=0.5,y=0.5}})
eq(r.ingredients[1].unread,nil); eq(r.ingredients[1].text:find('read by nothing',1,true),nil)
reader.valid=false
-- Filters: a feeder whose filter keeps bricks out does not feed them.
local f=inserter(-1.5,0.5,'fast-inserter',C2,A,{filters={'iron-plate'}})
r=trace.trace(p,{position={x=0.5,y=0.5}})
has(r.ingredients[1].text,'long-handed-inserter (0.5,2.5)'); eq(r.ingredients[1].text:find('fast-inserter',1,true),nil)
f.valid=false
-- Nothing lacking: a note; all=true lists every ingredient.
A.get_inventory=function(id) if id==defines.inventory.crafter_input then return inv({['stone-brick']=10}) end end
r=trace.trace(p,{position={x=0.5,y=0.5}})
eq(#r.ingredients,0); has(r.note,'every ingredient')
eq(#trace.trace(p,{position={x=0.5,y=0.5},all=true}).ingredients,1)
fails(function() trace.trace(p,{position={x=0.5,y=4.5}}) end,'has no recipe or research to trace')

-- 2. Astra: a collector's output down a belt run (one internal line), an underground pair (output_lines), to a belt end
-- whose right lane is full of oxide chunks; the inserters on the way take metallic chunks and iron ore only.
local K=ent{name='asteroid-collector',type='asteroid-collector',position={x=0.5,y=20.5}}
local Kout=inv({['metallic-asteroid-chunk']=5,['oxide-asteroid-chunk']=3})
K.get_inventory=function(id) if id==defines.inventory.asteroid_collector_output then return Kout end end
local B1=belt(3.5,20.5,{{},{'metallic-asteroid-chunk','metallic-asteroid-chunk'}},'run1')
local B2=belt(4.5,20.5,{},'run1')
local U1=belt(5.5,20.5,{},nil,'underground-belt','underground-belt'); U1.belt_to_ground_type='input'
local U2=belt(9.5,20.5,{},nil,'underground-belt','underground-belt'); U2.belt_to_ground_type='output'
local B3=belt(10.5,20.5,{{},{'oxide-asteroid-chunk','oxide-asteroid-chunk','oxide-asteroid-chunk','oxide-asteroid-chunk'}})
link(B1,B2); link(B2,U1); U1.neighbours=U2; link(U2,B3)
feeds(B2,U1); feeds(U1,U2); feeds(U2,B3)
inserter(2.5,20.5,'fast-inserter',K,B1,{drop={x=3.5,y=20.75}})
local metallic={name='metallic-asteroid-crushing',ingredients={{type='item',name='metallic-asteroid-chunk',amount=1}},products={{name='iron-ore'}}}
local crusher=crafter(10.5,23.5,'crusher',metallic,{},{},'working')
inserter(10.5,21.5,'fast-inserter',B3,crusher,{filters={'metallic-asteroid-chunk'},status='waiting_for_source_items'})
local box=chest(3.5,22.5,{})
box.inv.full=true
inserter(3.5,21.5,'inserter',B1,box,{filters={'iron-ore'},status='waiting_for_space_in_destination',held={'iron-ore',1}})
r=trace.trace(p,{position={x=0.5,y=20.5},forward=true})
eq(r.output,'5 metallic-asteroid-chunk, 3 oxide-asteroid-chunk')
eq(r.takers[1],'fast-inserter (2.5,20.5) working -> transport-belt (3.5,20.5) right lane')
eq(#r.routes,1)
local route=r.routes[1]
eq(route.path,'transport-belt (3.5,20.5) to (4.5,20.5) right lane (2 tiles) -> underground-belt (5.5,20.5) right lane -> underground-belt (9.5,20.5) right lane -> transport-belt (10.5,20.5) right lane')
eq(route.carries,'4 oxide-asteroid-chunk, 2 metallic-asteroid-chunk')
has(route.stop,'belt ends at transport-belt (10.5,20.5): left lane empty, right lane 4 oxide-asteroid-chunk (full)')
has(route.stop,'the front of the lane is oxide-asteroid-chunk, which no inserter on this route takes')
eq(route.nobody_takes,'oxide-asteroid-chunk')
has(route.takers[1],'inserter (3.5,21.5) waiting_for_space_in_destination filter iron-ore, holding 1 iron-ore -> iron-chest (3.5,22.5) (full) (holding what it cannot drop)')
has(route.takers[2],'fast-inserter (10.5,21.5) waiting_for_source_items filter metallic-asteroid-chunk -> crusher (10.5,23.5)')
-- An inserter that picks only the other lane is no taker of this one (it says so).
local wrong=inserter(4.5,21.5,'fast-inserter',B2,crusher,{left=true,right=false})
r=trace.trace(p,{position={x=0.5,y=20.5},forward=true})
has(table.concat(r.routes[1].takers,' | '),'fast-inserter (4.5,21.5) working, picks only the left lane -> crusher (10.5,23.5)')
wrong.valid=false
-- Out of sight: the walk stops where radar coverage ends.
local B4=belt(40.5,20.5,{})
link(B3,B4); feeds(B3,B4)
force.is_chunk_visible=function(_,c) return c.x~=1 end
r=trace.trace(p,{position={x=0.5,y=20.5},forward=true})
eq(r.routes[1].stop,'goes out of sight at (40.5,20.5) (no radar coverage there)')
force.is_chunk_visible=function() return true end
B4.valid=false; B3.belt_neighbours.outputs={}; for k=1,2 do B3.lines[k].output_lines={} end
-- Nothing takes from a lone machine.
local lone=crafter(40.5,40.5,'assembling-machine-1',wall,{},{})
r=trace.trace(p,{position={x=40.5,y=40.5},forward=true})
eq(r.note,'no inserter takes from it'); eq(r.routes,nil)
lone.valid=false

-- 2b. Opus (06:26): ore fed into a plate bus. A forward trace from a belt tile follows its lanes and names where
-- other items join: the bus it is side-loaded onto (your ore mixes in), and, from the bus, the belt side-loading ore
-- onto it; a splitter's other input.
do
  local O1=belt(20.5,38.5,{{'iron-ore'},{'iron-ore'}},'o'); O1.direction=8
  local O2=belt(20.5,39.5,{{'iron-ore'},{'iron-ore'}},'o'); O2.direction=8
  local P0=belt(19.5,40.5,{{'iron-plate','iron-plate'},{}},'bus')
  local P1=belt(20.5,40.5,{{'iron-plate','iron-ore'},{}},'bus')
  local P2=belt(21.5,40.5,{{'iron-plate','iron-ore'},{}},'bus')
  for _,b in ipairs({P0,P1,P2}) do b.belt_shape='straight' end
  link(O1,O2); link(O2,P1); link(P0,P1); link(P1,P2)
  P1.belt_neighbours.inputs={P0,O2}; P2.belt_neighbours.inputs={P1}; O2.belt_neighbours.inputs={O1}
  for k=1,2 do O2.lines[k].output_lines={P1.lines[1]} end
  r=trace.trace(p,{position={x=20.5,y=38.5},forward=true})
  eq(r.belt,'transport-belt'); eq(r.lanes,'left lane 1 iron-ore, right lane 1 iron-ore'); eq(#r.routes,2)
  eq(r.routes[1].merges[1],'joins transport-belt (20.5,40.5) carrying iron-plate on the left lane: your iron-ore mixes in')
  eq(#r.merges,1,'named once'); has(r.routes[2].stop,'joins route 1 at transport-belt (20.5,40.5) left lane')
  has(r.routes[1].path,'transport-belt (20.5,40.5) to (21.5,40.5) left lane')
  -- Items move: with the bus empty at the join and behind it, the plates further along its lane still name it.
  P0.lines[1].items={}; P1.lines[1].items={'iron-ore'}; P2.lines[1].items={'iron-plate','iron-ore'}
  r=trace.trace(p,{position={x=20.5,y=38.5},forward=true})
  eq(r.merges[1],'joins transport-belt (20.5,40.5) carrying iron-plate on the left lane: your iron-ore mixes in')
  P0.lines[1].items={'iron-plate','iron-plate'}; P1.lines[1].items={'iron-plate','iron-ore'}
  -- From the bus: the ore belt side-loads onto its left lane; the right lane carries nothing, so it is not walked.
  r=trace.trace(p,{position={x=19.5,y=40.5},forward=true})
  eq(#r.routes,1); eq(r.merges[1],'transport-belt (20.5,39.5) side-loads iron-ore onto transport-belt (20.5,40.5) left lane, which carried iron-plate')
  -- An inserter putting coal from a chest onto the bus lane is named; one holding plates (what the lane carries) is not.
  local coalbox=chest(21.5,38.5,{coal=50})
  local ci=inserter(21.5,39.5,'inserter',coalbox,P2,{drop={x=21.5,y=40.25}})
  local pi=inserter(22.5,39.5,'inserter',nil,P2,{drop={x=21.5,y=40.25},held={'iron-plate',1}})
  r=trace.trace(p,{position={x=19.5,y=40.5},forward=true})
  eq(#r.merges,2); eq(r.merges[2],'inserter (21.5,39.5) puts coal onto transport-belt (21.5,40.5) left lane (from iron-chest (21.5,38.5)), which carried iron-plate, iron-ore')
  ci.valid=false; pi.valid=false; coalbox.valid=false
  -- A belt side-loading onto the other lane, or carrying what the lane carries already, is not named.
  P0.lines[2].items={'iron-ore'}
  r=trace.trace(p,{position={x=19.5,y=40.5},forward=true})
  eq(#r.routes,2); eq(#r.merges,1,'the side-load lands on the left lane only')
  P0.lines[1].items={'iron-ore'}; P1.lines[1].items={'iron-ore'}; P2.lines[1].items={'iron-ore'}
  r=trace.trace(p,{position={x=19.5,y=40.5},forward=true}); eq(r.merges,nil,'ore onto ore')
  -- A splitter's other input carrying something else.
  local A1=belt(30.5,40.5,{{'iron-ore'},{}},'sa')
  local S=belt(31.5,40.5,{{},{}},'sa','splitter','splitter')
  local X=belt(30.5,41.5,{{'copper-plate'},{}},'sx')
  link(A1,S); link(X,S); S.belt_neighbours.inputs={A1,X}
  r=trace.trace(p,{position={x=30.5,y=40.5},forward=true})
  eq(r.merges[1],'splitter (31.5,40.5) also takes transport-belt (30.5,41.5) carrying copper-plate; this lane carried iron-ore')
  for _,e in ipairs({O1,O2,P0,P1,P2,A1,S,X}) do e.valid=false end
end

-- 3. Luna: chemical packs from their maker through a splitter whose filter sends them right, to a lab; a requester
-- chest on the way asks for nothing; a far lab no route reaches.
local chem={name='chemical-science-pack',ingredients={{type='item',name='iron-plate',amount=1}},products={{name='chemical-science-pack'}}}
local P=crafter(0.5,60.5,'assembling-machine-3',chem,{},{['chemical-science-pack']=4},'working')
local D1=belt(3.5,60.5,{},'d')
local D2=belt(4.5,60.5,{{},{'chemical-science-pack'}},'d')
local S=belt(5.5,60.5,{},nil,'splitter','splitter')
S.splitter_filter={name='chemical-science-pack'}; S.splitter_output_priority='right'
local E1=belt(6.5,60,{})   -- the north (left) output
local E2=belt(6.5,61,{})   -- the south (right) output
link(D1,D2); link(D2,S); link(S,E1); link(S,E2)
feeds(D2,S)
for k=1,2 do S.lines[k].output_lines={E1.lines[k],E2.lines[k]} end
inserter(2.5,60.5,'inserter',P,D1,{drop={x=3.5,y=60.75}})
local L1=lab(6.5,63.5,{})
inserter(6.5,62,'inserter',E2,L1)
local L2=lab(60.5,60.5,{})
local L3=lab(30.5,30.5,{['chemical-science-pack']=5})
local R=chest(4.5,58.5,{},'requester-chest','requester')
inserter(4.5,59.5,'inserter',D2,R)
local eaten=inserter(6.5,59,'inserter',E1,lab(6.5,57.5,{}))
r=trace.trace(p,{item='chemical-science-pack'})
eq(r.makers,'1 making it: 1 working')
eq(#r.routes,1)
route=r.routes[1]
has(route.path,'splitter (5.5,60.5) right lane (filter chemical-science-pack to the right) -> transport-belt (6.5,61) right lane')
has(table.concat(route.takers,' | '),'requester-chest (4.5,58.5) (a requester chest with no request for chemical-science-pack)')
has(r.reaches[1],'lab (6.5,63.5) by inserter (6.5,62) (route 1)')
eq(r.labs_short,'3 of 4 labs hold none of it')
has(table.concat(r.labs,' | '),'lab (6.5,63.5): reached by route 1')
has(table.concat(r.labs,' | '),'lab (60.5,60.5): no route from a maker reaches it; no inserter feeds it; nearest route tile')
has(r.cost,'1 makers')
-- The lab on the splitter's other output is no reach (the filter sends the packs right).
eq(table.concat(r.reaches,' | '):find('6.5,57.5',1,true),nil)
-- Out of sight: a route stops where radar coverage ends.
force.is_chunk_visible=function(_,c) return c.x<0 or (c.y~=1) end
r=trace.trace(p,{item='chemical-science-pack'})
eq(r.routes,nil); eq(r.makers,'nothing on nauvis makes chemical-science-pack')
force.is_chunk_visible=function() return true end
-- near: only that area's makers and labs.
r=trace.trace(p,{item='chemical-science-pack',near={x=60,y=60},radius=5})
eq(r.makers,'nothing on nauvis makes chemical-science-pack'); eq(r.area,'(60,60) radius 5'); eq(r.labs_short,'1 of 1 labs hold none of it')
-- Arguments.
fails(function() trace.trace(p,{item='chemical-science-pack',position={x=1,y=1}}) end,'give item, or position')
fails(function() trace.trace(p,{position={x=0.5,y=0.5},near={x=1,y=1}}) end,'surface, near and radius go with item')
fails(function() trace.trace(p,{position={x=0.5,y=0.5},forward=true,all=true}) end,'all goes with a backward trace')
fails(function() trace.trace(p,{item='unobtainium'}) end,'item must be an item name')
fails(function() trace.trace(p,{}) end,'trace takes position')
print('trace: ok')
