-- Run from repository root: lua tests/d21_batch64.lua
-- d21 batch64 Z1 (Sol #1515): a crusher with circuit Set recipe on read no_recipe while its green wire carried
-- recipe:oxide-asteroid-crushing = 1. circrecipe.lua follows the game's rules (seen on a private copy): recipe signals
-- above 0 by recipe order, then item signals by the recipes making them; the dump slots hold the old recipe's items
-- after a change, and the machine has no recipe until they are empty.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,part) assert(type(s)=='string' and s:find(part,1,true),tostring(s)..'\n  lacks: '..part) end
defines={wire_connector_id={circuit_red=1,circuit_green=2},inventory={assembling_machine_dump=7}}
local RECIPES={
  ['metallic-asteroid-crushing']={order='b-a-a',products={'iron-ore','metallic-asteroid-chunk'}},
  ['carbonic-asteroid-crushing']={order='b-a-b',products={'carbon','carbonic-asteroid-chunk'}},
  ['oxide-asteroid-crushing']={order='b-a-c',products={'ice','oxide-asteroid-chunk'}},
  ['advanced-oxide-asteroid-crushing']={order='f[advanced-oxide-asteroid-crushing]',products={'ice','calcite','oxide-asteroid-chunk'}},
  ['iron-gear-wheel']={order='c-a',category='crafting',products={'iron-gear-wheel'}}}
local force={recipes={}}
for name,r in pairs(RECIPES) do force.recipes[name]={name=name,enabled=true,category=r.category or 'crushing',prototype={order=r.order}} end
prototypes={quality={normal={level=0},uncommon={level=1},rare={level=2}},
  get_recipe_filtered=function(f) local item=f[1].elem_filters[1].name local out={} for name,r in pairs(RECIPES) do for _,p in ipairs(r.products) do if p==item then out[name]=true end end end return out end}
local wires={[1]={},[2]={}}
local dump={}
local recipe_now
local crusher={name='crusher',position={x=-17,y=-10.5},force=force,prototype={crafting_categories={crushing=true}},bounding_box={left_top={x=-17.7,y=-11.7},right_bottom={x=-16.3,y=-9.3}},
  get_control_behavior=function() return {circuit_set_recipe=true} end,
  get_circuit_network=function(w) return #wires[w]>0 and {signals=wires[w]} or nil end,
  get_recipe=function() if recipe_now then return force.recipes[recipe_now],{name='normal'} end end,
  get_inventory=function(i) return i==7 and {get_contents=function() return dump end} or nil end}
local inserters={}
crusher.surface={find_entities_filtered=function() return inserters end}
local C=dofile('mod/agent-harness_0.1.0/circrecipe.lua'){status_name=function(e) return e.status end}
local function sig(kind,name,count,q) return {signal={type=kind,name=name,quality=q},count=count} end

-- a recipe signal, either wire
wires[2]={sig('recipe','oxide-asteroid-crushing',1)}
local p=C.pick(crusher); eq(p.recipe,'oxide-asteroid-crushing'); eq(p.quality,'normal'); eq(p.from,'recipe:oxide-asteroid-crushing')
wires[2]={}; wires[1]={sig('recipe','oxide-asteroid-crushing',1,'uncommon')}
p=C.pick(crusher); eq(p.recipe,'oxide-asteroid-crushing'); eq(p.quality,'uncommon')
-- several: the lowest recipe order, whatever the counts; normal before rare
wires[1]={sig('recipe','oxide-asteroid-crushing',5),sig('recipe','metallic-asteroid-crushing',1)}
eq(C.pick(crusher).recipe,'metallic-asteroid-crushing')
wires[1]={sig('recipe','advanced-oxide-asteroid-crushing',1),sig('recipe','oxide-asteroid-crushing',5)}
eq(C.pick(crusher).recipe,'oxide-asteroid-crushing')
wires[1]={sig('recipe','oxide-asteroid-crushing',5,'rare'),sig('recipe','oxide-asteroid-crushing',1)}
p=C.pick(crusher); eq(p.recipe,'oxide-asteroid-crushing'); eq(p.quality,'normal')
-- skipped: another machine's recipe, one not researched, a count below 1
force.recipes['carbonic-asteroid-crushing'].enabled=false
wires[1]={sig('recipe','iron-gear-wheel',1),sig('recipe','carbonic-asteroid-crushing',1),sig('recipe','metallic-asteroid-crushing',-1),sig('virtual','signal-A',3)}
p=C.pick(crusher); eq(p.recipe,nil)
eq(p.skipped[1].why,'not one crusher makes'); eq(p.skipped[2].why,'not researched'); eq(p.skipped[3].why,'count -1 (the game takes one above 0)'); eq(p.skipped[4].why,'not a recipe or item signal')
force.recipes['carbonic-asteroid-crushing'].enabled=true
-- item signals: after recipe signals; alone, a recipe making it
wires[1]={sig('item','ice',5),sig('recipe','advanced-oxide-asteroid-crushing',1)}
eq(C.pick(crusher).recipe,'advanced-oxide-asteroid-crushing')
wires[1]={sig('item','ice',1)}; eq(C.pick(crusher).recipe,'oxide-asteroid-crushing')
wires[1]={sig('item','calcite',1)}; eq(C.pick(crusher).recipe,'advanced-oxide-asteroid-crushing')
wires[1]={sig('item','ice',1,'uncommon')}; p=C.pick(crusher); eq(p.recipe,'oxide-asteroid-crushing'); eq(p.quality,'uncommon')
wires[1]={sig('item','iron-gear-wheel',1)}; eq(C.pick(crusher).recipe,nil)
-- red and green summed
wires[1]={sig('recipe','oxide-asteroid-crushing',1)}; wires[2]={sig('recipe','oxide-asteroid-crushing',-1)}
eq(C.pick(crusher).recipe,nil,'1 and -1 make 0')
wires[2]={}

-- inspect's line: Sol's case, the dump holding what the last change left, the takers' filters
wires[1]={}; wires[2]={sig('recipe','oxide-asteroid-crushing',1)}
dump={{name='ice',quality='normal',count=12},{name='carbon',quality='normal',count=4}}
inserters={{name='bulk-inserter',position={x=-15.5,y=-11.5},pickup_target=crusher,use_filters=true,filter_slot_count=2,inserter_filter_mode='whitelist',status='waiting_for_space_in_destination',
    get_filter=function(k) return ({{name='ice'},{name='calcite'}})[k] end},
  {name='fast-inserter',position={x=-15.5,y=-9.5},pickup_target={},status='waiting_for_source_items'}}
local r=C.read(crusher)
eq(r.recipe_now,false); eq(r.wires_give,'oxide-asteroid-crushing'); eq(r.dump[1],'ice*12'); eq(r.dump_left[1],'carbon')
eq(r.line,'Set recipe is on: its wires give oxide-asteroid-crushing (recipe:oxide-asteroid-crushing); it has no recipe: the new one waits until its dump slots are empty: they hold ice*12, carbon*4 (the last recipe change moved the old recipe\'s items there); inserters taking from it: bulk-inserter (-15.5,-11.5) with whitelist filters calcite, ice, waiting_for_space_in_destination: takes ice; nothing here takes carbon out of it (a hand takes them from the dump slots: transfer inventory assembling_machine_dump)')
-- no signal it takes
dump={}; wires[2]={sig('recipe','iron-gear-wheel',1)}
r=C.read(crusher)
eq(r.line,'Set recipe is on and none of the 1 signal on its wires gives a recipe it takes: it has no recipe; not used: recipe:iron-gear-wheel (not one crusher makes)')
wires[2]={}
eq(C.read(crusher).line,'Set recipe is on and its wires carry no signal: it has no recipe')
-- the recipe it has
recipe_now='oxide-asteroid-crushing'; wires[2]={sig('recipe','oxide-asteroid-crushing',1)}
eq(C.read(crusher).line,'Set recipe is on: its wires give oxide-asteroid-crushing (recipe:oxide-asteroid-crushing), the recipe it has')
-- configure's refusal
local text=C.refusal(crusher,'carbonic-asteroid-crushing',nil)
has(text,'crusher (-17,-10.5) has Set recipe on (its circuit settings): the game sets its recipe from its red and green wires and keeps none set by hand; its wires give oxide-asteroid-crushing (recipe:oxide-asteroid-crushing) now')
has(text,'For carbonic-asteroid-crushing by hand: circuit_set {settings: {circuit_set_recipe: false}}, then configure recipe; or keep Set recipe on and send recipe:carbonic-asteroid-crushing (quality normal, above 0) on its red or green wire')
-- Set recipe off: nothing to say
crusher.get_control_behavior=function() return {circuit_set_recipe=false} end
eq(C.read(crusher),nil); eq(C.set_recipe_on(crusher),false)
print('d21_batch64 Z1 circuit Set recipe: ok')

-- d21 batch64 Z2 (Luna #1576): configure {bar}. invbar.lua sets a chest's red-X bar with readback, and on a crafting
-- machine gives the game's reason it has none (2.0.77: supports_bar false, "Given inventory does not have a bar.") and
-- what the game has instead.
defines.inventory.chest=1
prototypes.item={['electric-furnace']={stack_size=50},['iron-plate']={stack_size=100}}
local function integer(v,d,lo,hi,name) assert(type(v)=='number' and v==math.floor(v) and v>=lo and v<=hi,name..' out of range') return v end
local B=dofile('mod/agent-harness_0.1.0/invbar.lua'){integer=integer}
local function chest_inv(n,used)
  local inv,bar={},n+1
  for i=1,n do inv[i]={valid_for_read=i<=used} end
  inv.supports_bar=function() return true end
  inv.get_bar=function() return bar end
  inv.set_bar=function(b) bar=b end
  return inv
end
local cinv=chest_inv(32,5)
local chest={name='iron-chest',type='container',position={x=-221.5,y=-99.5},get_inventory=function(i) return i==1 and cinv or nil end}
local r=B.set(chest,1)
eq(r.bar,1); eq(r.bar_before,'none'); eq(r.slots,32); eq(r.slots_used,5); eq(r.slots_past_bar,4)
eq(r.line,'iron-chest (-221.5,-99.5): bar 1 usable of 32 slots (was none); 5 slots hold items, 4 past the bar: they keep their items, and new items go only into the slots under it')
r=B.set(chest,false); eq(r.bar,'none'); eq(r.bar_before,1); eq(r.slots_past_bar,nil)
r=B.set(chest,0); eq(r.bar,0)
assert(not pcall(B.set,chest,33),'33 of 32 slots is refused')
-- a machine: refused with the game's reason, what it holds at most, and what the game has
local machine
local out_inserter={name='fast-inserter',position={x=-222.5,y=-99.5}}
machine={name='assembling-machine-2',type='assembling-machine',position={x=-224.5,y=-99.5},force=force,
  bounding_box={left_top={x=-226,y=-101},right_bottom={x=-223,y=-98}},
  get_recipe=function() return {name='electric-furnace',products={{type='item',name='electric-furnace',amount=1}}} end,
  get_output_inventory=function() return {1} end,
  get_inventory=function() return {supports_bar=function() return false end} end,
  surface={find_logistic_network_by_position=function() return {network_id=243} end,find_entities_filtered=function() return {out_inserter} end}}
out_inserter.pickup_target=machine; out_inserter.drop_target=chest
local ok,err=pcall(B.set,machine,1)
assert(not ok)
has(err,'bar: assembling-machine-2 (-224.5,-99.5) has none: in 2.0.77 a crafting machine\'s input and output have no bar (the game: "Given inventory does not have a bar.") and its GUI has no output limit')
has(err,'with nothing taking from it it holds at most a stack (electric-furnace: at most 50, a stack)')
has(err,'circuit_set {position: {x=-224.5,y=-99.5}, logistic: "electric-furnace < N"}: it stops while logistic network 243, where it stands, holds N or more')
has(err,'Its output inserters: fast-inserter (-222.5,-99.5) into iron-chest (-221.5,-99.5) (0 of 32 slots usable)')
-- no logistic network there; an inserter; a ghost
machine.surface.find_logistic_network_by_position=function() return nil end
ok,err=pcall(B.set,machine,1); has(err,'the logistic network where it stands (none covers it now)')
ok,err=pcall(B.set,{name='fast-inserter',type='inserter',position={x=1,y=2},get_inventory=function() return nil end},1)
eq(err,'bar: fast-inserter (1,2) has no inventory with a bar in 2.0.77 (the red X is a chest\'s, logistic chest\'s, cargo wagon\'s or cargo landing pad\'s)')
ok,err=pcall(B.set,{type='entity-ghost',ghost_name='steel-chest',position={x=3,y=4}},2)
eq(err,'bar: ghost of steel-chest (3,4) holds no items: the bar is set on the built chest, cargo wagon or landing pad')
print('d21_batch64 Z2 inventory bar: ok')
