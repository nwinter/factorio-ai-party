-- Run from repository root: lua tests/modules.lua
-- configure modules (modules.lua; Astra and Gemini, shift12 15:10: Sunward's module swaps took three blueprint round
-- trips, Fulgora's upgrades four): a machine's module slots set in one call, by hand in reach, else as an item
-- request (robots, or a platform's hub), or a ghost's module requests. Fake engine; the rule for which module goes
-- where agreed with 2.0.77's can_set_stack in 5892 machine, recipe and module cases on a private copy of world n.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(text,part) assert(type(text)=='string' and text:find(part,1,true),'missing "'..part..'" in: '..tostring(text)) end
local function fails(fn,part) local ok,err=pcall(fn); eq(ok,false,'expected error'); has(tostring(err),part) end
defines={inventory={crafter_modules=4,mining_drill_modules=2,lab_modules=3,beacon_modules=1,chest=1}}
local ALL={speed=true,productivity=true,consumption=true,pollution=true,quality=true}
prototypes={quality={normal={name='normal'},rare={name='rare'}},
  item={['speed-module']={type='module',category='speed',module_effects={speed=0.2,consumption=0.5,quality=-0.1}},
    ['speed-module-2']={type='module',category='speed',module_effects={speed=0.3,consumption=0.6,quality=-0.15}},
    ['productivity-module']={type='module',category='productivity',module_effects={productivity=0.04,consumption=0.4,pollution=0.05,speed=-0.05}},
    ['efficiency-module']={type='module',category='efficiency',module_effects={consumption=-0.3}},
    ['quality-module']={type='module',category='quality',module_effects={quality=0.1,speed=-0.05}},
    ['iron-plate']={type='item'}}}
local am2={name='assembling-machine-2',type='assembling-machine',allowed_effects=ALL,module_inventory_size=2}
local beacon={name='beacon',type='beacon',allowed_effects={speed=true,consumption=true,pollution=true},
  allowed_module_categories={speed=true,efficiency=true},module_inventory_size=2}
local furnace_recipe={name='electric-furnace',allowed_effects={speed=true,consumption=true,pollution=true,quality=true,productivity=false}}
local plain_recipe={name='iron-gear-wheel',allowed_effects=ALL}
local no_quality={name='no-quality-recipe',allowed_effects={speed=true,consumption=true,pollution=true,productivity=true}}
local M=dofile('mod/agent-harness_0.1.0/modules.lua'){out_of_reach=function(_,e) return 'entity is out of reach: '..e.name end}

-- The list: one slot an entry, counts expanded; not a module: refused with modules like it.
local want=M.parse({'speed-module',{name='efficiency-module',count=2,quality='rare'}})
eq(#want,3); eq(want[1].name,'speed-module'); eq(want[1].quality,'normal'); eq(want[3].name,'efficiency-module'); eq(want[3].quality,'rare')
eq(#M.parse(false),0); eq(#M.parse({}),0); eq(#M.parse('speed-module'),1)
fails(function() M.parse({'speed'}) end,'not a module: speed; modules like it: speed-module, speed-module-2')
fails(function() M.parse({'iron-plate'}) end,'not a module: iron-plate')
fails(function() M.parse({{name='speed-module',count=0}}) end,'count is a whole number 1..16')
fails(function() M.parse({{name='speed-module',quality='shiny'}}) end,'unknown quality shiny')
-- Which module goes where: a module's bonuses must be allowed by the machine and its recipe; what it worsens does
-- not count (a speed module lowers quality, and still goes under a recipe that allows no quality).
has(M.why_not(am2,furnace_recipe,{name='productivity-module'},'assembling-machine-2 (1,1) making electric-furnace'),
  'productivity-module does not go in assembling-machine-2 (1,1) making electric-furnace: its recipe electric-furnace allows no productivity')
eq(M.why_not(am2,no_quality,{name='speed-module'},'m'),nil)
has(M.why_not(am2,no_quality,{name='quality-module'},'m'),'its recipe no-quality-recipe allows no quality')
eq(M.why_not(am2,plain_recipe,{name='productivity-module'},'m'),nil)
has(M.why_not(beacon,nil,{name='productivity-module'},'beacon (3,3)'),'productivity-module (productivity) does not go in beacon (3,3): it takes efficiency, speed modules')
eq(M.why_not(beacon,nil,{name='efficiency-module'},'b'),nil)

-- A fake world: machines with module slots, a character's inventory, the surface's item requests.
local force={name='player'}
local spilled,roboports={},{}
local surface={name='nauvis'}
surface.spill_item_stack=function(a) spilled[#spilled+1]=a.stack end
surface.find_entities_filtered=function(f) eq(f.type,'roboport'); return roboports end
surface.create_entity=function(a)
  eq(a.name,'item-request-proxy')
  local px={valid=true,name=a.name,insert_plan=a.modules,removal_plan=a.removal_plan}
  px.destroy=function() px.valid=false; a.target.item_request_proxy=nil end
  a.target.item_request_proxy=px
  return px
end
local function slots(n,index)
  local inv={index=index}
  for i=1,n do
    local s={valid_for_read=false}
    s.set_stack=function(x) s.valid_for_read=true; s.name=x.name; s.quality={name=x.quality or 'normal'}; s.count=x.count or 1; return true end
    s.clear=function() s.valid_for_read=false; s.name=nil; s.quality=nil; s.count=nil end
    s.can_set_stack=function(x) return not (inv.refuse and inv.refuse[x.name]) end
    inv[i]=s
  end
  return setmetatable(inv,{__len=function() return n end})
end
local function machine(proto,x,recipe)
  local inv=slots(proto.module_inventory_size,proto.type=='beacon' and 1 or 4)
  local e={valid=true,name=proto.name,type=proto.type,prototype=proto,position={x=x,y=0.5},force=force,surface=surface}
  e.get_module_inventory=function() return inv end
  e.get_recipe=function() return recipe and {prototype=recipe} end
  return e,inv
end
local held={}
local function key(x) return x.name..'@'..(x.quality or 'normal') end
local main={}
main.get_item_count=function(x) return held[key(x)] or 0 end
main.insert=function(x) held[key(x)]=(held[key(x)] or 0)+x.count; return x.count end
main.remove=function(x) held[key(x)]=(held[key(x)] or 0)-x.count; return x.count end
local p={surface=surface,position={x=0,y=0},get_main_inventory=function() return main end,
  can_reach_entity=function(e) return e.position.x<10 end}

-- By hand, in reach: the new ones from the inventory, the old ones back into it.
local a,ainv=machine(am2,5.5,plain_recipe)
held['speed-module@normal']=2
local r=M.set(p,a,M.parse({'speed-module','speed-module'}),true)
eq(r.by,'hand'); eq(r.before,'empty'); eq(r.after,'speed-module*2'); eq(held['speed-module@normal'],0)
held['efficiency-module@normal']=1
r=M.set(p,a,M.parse({'efficiency-module'}),true)
eq(r.after,'efficiency-module*1','the slot past the list is emptied'); eq(r.returned,'speed-module*2 (to your inventory)')
eq(held['speed-module@normal'],2); eq(held['efficiency-module@normal'],0); eq(ainv[2].valid_for_read,false)
eq(M.set(p,a,M.parse({'efficiency-module'}),true).unchanged,true)
-- Not enough held: refused, nothing changed; a module coming out counts toward what is needed.
fails(function() M.set(p,a,M.parse({'speed-module-2','speed-module-2'}),true) end,
  'not enough modules in your inventory for assembling-machine-2 (5.5,0.5) making iron-gear-wheel (speed-module-2: 2 needed, you hold 0); by="robots" requests them instead')
eq(ainv[1].name,'efficiency-module')
r=M.set(p,a,M.parse({'speed-module','efficiency-module'}),true)
eq(r.after,'speed-module*1 efficiency-module*1'); eq(held['speed-module@normal'],1)
-- The engine's own check refuses a slot: nothing moves.
ainv.refuse={['speed-module']=true}
fails(function() M.set(p,a,M.parse({'efficiency-module','speed-module'}),true) end,'the game refuses speed-module in slot 2')
ainv.refuse=nil
-- Too many for the slots, and a module the recipe does not take.
fails(function() M.set(p,a,M.parse({'speed-module','speed-module','speed-module'}),true) end,'has 2 module slots; 3 given')
local f=machine(am2,6.5,furnace_recipe)
fails(function() M.set(p,f,M.parse({'productivity-module'}),true) end,'its recipe electric-furnace allows no productivity')
-- by=hand out of reach: the reach refusal.
local far,finv=machine(am2,50.5,plain_recipe)
fails(function() M.set(p,far,M.parse({'speed-module'}),true,'hand') end,'entity is out of reach: assembling-machine-2')

-- Out of reach: an item request, slot by slot: the new ones in, the old ones out; who brings them.
finv[1].set_stack{name='speed-module'}; finv[2].set_stack{name='speed-module'}
r=M.set(p,far,M.parse({{name='efficiency-module',count=2}}),true)
eq(r.by,'robots'); eq(r.before,'speed-module*2'); eq(r.requested,'efficiency-module*2'); eq(r.removing,'speed-module*2')
eq(r.note,'no roboport\'s construction area covers it: no robot comes until one does')
local px=far.item_request_proxy
eq(px.insert_plan[1].id.name,'efficiency-module'); eq(#px.insert_plan[1].items.in_inventory,2)
eq(px.insert_plan[1].items.in_inventory[2].inventory,4); eq(px.insert_plan[1].items.in_inventory[2].stack,1)
eq(px.removal_plan[1].id.name,'speed-module'); eq(px.removal_plan[1].items.in_inventory[1].stack,0)
local q=M.requests(far)
eq(q.requested,'efficiency-module*2'); eq(q.removing,'speed-module*2')
-- A roboport's construction area covers it: its network, what it holds, its robots and free storage.
local net={network_id=8,available_construction_robots=49,all_construction_robots=50,
  get_item_count=function(x) return x.name=='efficiency-module' and 2 or 0 end,
  storages={{can_insert=function(x) return x.name~='speed-module' end}}}
roboports={{valid=true,position={x=40,y=0},logistic_cell={construction_radius=55,logistic_network=net}}}
r=M.set(p,far,M.parse({'efficiency-module','speed-module-2'}),true)
eq(r.requested,'efficiency-module*1 speed-module-2*1'); eq(r.removing,'speed-module*2')
eq(r.note,'construction robots of logistic network 8 bring them and take the old ones out (it holds efficiency-module 2 (1 wanted), '
  ..'speed-module-2 0 (1 wanted)); none comes for speed-module-2 until it holds it; 49 of 50 construction robots idle; '
  ..'no storage chest has room for speed-module: the old ones ride in a robot until one has')
eq(far.item_request_proxy,px,'the same request, its plans replaced')
-- Other requests on the machine stay (fuel for another inventory); setting what it holds clears the module rows.
px.insert_plan[#px.insert_plan+1]={id={name='coal'},items={in_inventory={{inventory=1,stack=0,count=5}}}}
r=M.set(p,far,M.parse({'speed-module','speed-module'}),true)
eq(r.unchanged,true); has(r.note,'its module requests were cleared')
eq(px.valid,true); eq(#px.insert_plan,1); eq(px.insert_plan[1].id.name,'coal'); eq(#px.removal_plan,0)
eq(M.requests(far),nil)
px.insert_plan={}
r=M.set(p,far,M.parse({'efficiency-module'}),true,'robots')
eq(r.requested,'efficiency-module*1'); eq(r.removing,'speed-module*2')
-- A removal alone waits for a storage chest with room (2.0.77: nothing moved for 30 s, then 8 s once one had room).
r=M.set(p,far,M.parse({}),true)
has(r.note,'construction robots of logistic network 8 take them out; 49 of 50 construction robots idle; no storage chest has room for speed-module: no robot takes them out until one has')
net.storages={{can_insert=function() return true end}}
eq(M.set(p,far,M.parse({}),true).note,'construction robots of logistic network 8 take them out; 49 of 50 construction robots idle')
r=M.set(p,far,M.parse({'speed-module','speed-module'}),true)
eq(px.valid,false,'nothing left in it: the request goes')

-- By robots in reach (by=robots), and on a platform: its hub.
local hubbed,hinv=machine(am2,3.5,plain_recipe)
hubbed.surface={name='platform-2',platform={hub={get_item_count=function(x) return x.name=='speed-module' and 4 or 0 end}},
  create_entity=surface.create_entity}
r=M.set(p,hubbed,M.parse({'speed-module'}),false)
eq(r.by,'hub'); eq(r.note,'the platform hub brings them (it holds speed-module 4 (1 wanted))')
hinv[1].set_stack{name='efficiency-module'}
r=M.set(p,hubbed,M.parse({}),false)
eq(r.removing,'efficiency-module*1'); eq(r.note,'the platform hub takes them out')

-- A ghost: its insert plan's module rows (the fuel row stays); by=hand needs a built machine.
local ghost={valid=true,type='entity-ghost',name='entity-ghost',ghost_name='assembling-machine-2',ghost_type='assembling-machine',
  ghost_prototype=am2,position={x=7.5,y=0.5},force=force,surface=surface,
  insert_plan={{id={name='coal'},items={in_inventory={{inventory=1,stack=0,count=5}}}}}}
ghost.get_recipe=function() return {prototype=plain_recipe} end
r=M.set(p,ghost,M.parse({'productivity-module','speed-module'}),true)
eq(r.by,'ghost'); eq(r.ghost,true); eq(r.requested,'productivity-module*1 speed-module*1'); eq(r.before,'empty')
eq(#ghost.insert_plan,3); eq(ghost.insert_plan[1].id.name,'coal'); eq(ghost.insert_plan[2].items.in_inventory[1].stack,0)
eq(M.requests(ghost).requested,'productivity-module*1 speed-module*1')
r=M.set(p,ghost,M.parse({'speed-module'}),true)
eq(r.before,'productivity-module*1 speed-module*1'); eq(r.requested,'speed-module*1'); eq(#ghost.insert_plan,2)
fails(function() M.set(p,ghost,M.parse({'speed-module'}),true,'hand') end,'a ghost takes modules as requests')
-- A drill ghost's modules go to the drill's module inventory (2 on 2.0.77).
local drill={name='electric-mining-drill',type='mining-drill',allowed_effects=ALL,module_inventory_size=3}
local dg={valid=true,type='entity-ghost',name='entity-ghost',ghost_name='electric-mining-drill',ghost_type='mining-drill',ghost_prototype=drill,
  position={x=9.5,y=0.5},force=force,surface=surface,insert_plan={}}
M.set(p,dg,M.parse({{name='speed-module',count=3}}),true)
eq(dg.insert_plan[1].items.in_inventory[3].inventory,2); eq(dg.insert_plan[1].items.in_inventory[3].stack,2)
print('modules: ok')
