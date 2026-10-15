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

-- A list: the modules the machine ends up holding, counts expanded; not a module: refused with modules like it.
local want=M.parse({'speed-module',{name='efficiency-module',count=2,quality='rare'}})
eq(want.kind,'set'); want=want.list
eq(#want,3); eq(want[1].name,'speed-module'); eq(want[1].quality,'normal'); eq(want[3].name,'efficiency-module'); eq(want[3].quality,'rare')
eq(#M.parse(false).list,0); eq(#M.parse({}).list,0); eq(#M.parse('speed-module').list,1)
-- A list with keep or empty entries goes slot by slot (slots past it empty); numbered slots change only those named.
local w=M.parse({'keep','efficiency-module','empty',false})
eq(w.kind,'slots'); eq(w.n,4); eq(w.rest,'empty'); eq(w.at[1],'keep'); eq(w.at[2].name,'efficiency-module'); eq(w.at[3],false); eq(w.at[4],false)
w=M.parse({['3']={name='speed-module',quality='rare'},['1']='empty'})
eq(w.kind,'slots'); eq(w.n,3); eq(w.rest,'keep'); eq(w.at[3].quality,'rare'); eq(w.at[1],false); eq(w.at[2],nil)
fails(function() M.parse({['0']='speed-module'}) end,'slot 0 is not a slot number 1..64')
fails(function() M.parse({['2']={name='speed-module',count=2}}) end,'one module a slot (no count) in slot 2')
fails(function() M.parse({['2']='speed'}) end,'slot 2: not a module: speed')
fails(function() M.parse({first='speed-module'}) end,'modules: first: a count is a whole number 1..16 (a map of module names to counts)')
-- A map of names to counts (Sol, shift17 19:06): the list, names in order.
w=M.parse({['efficiency-module']=3}); eq(w.kind,'set'); eq(#w.list,3); eq(w.list[3].name,'efficiency-module')
w=M.parse({['speed-module']=1,['efficiency-module']=2}); eq(#w.list,3); eq(w.list[1].name,'efficiency-module'); eq(w.list[3].name,'speed-module')
fails(function() M.parse({['efficiency-module']=3,['2']='speed-module'}) end,'a map of module names to counts, or numbered slots, not both')
fails(function() M.parse({speed=2}) end,'not a module: speed')
local mixed={'speed-module'}; mixed['2']='speed-module'
fails(function() M.parse(mixed) end,'a list or numbered slots, not both')
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
-- The efficiency module it holds stays in slot 1; the speed module goes into slot 2.
r=M.set(p,a,M.parse({'speed-module','efficiency-module'}),true)
eq(r.after,'efficiency-module*1 speed-module*1'); eq(held['speed-module@normal'],1); eq(r.returned,nil)
eq(r.by_slot[1],'1 efficiency-module'); eq(r.by_slot[2],'2 speed-module')
-- The engine's own check refuses a slot: nothing moves.
ainv.refuse={['speed-module']=true}
fails(function() M.set(p,a,M.parse({'speed-module','speed-module'}),true) end,'the game refuses speed-module in slot 1')
eq(ainv[1].name,'efficiency-module')
ainv.refuse=nil
-- Slot by slot: keep leaves slot 1, slot 2 is emptied.
r=M.set(p,a,M.parse({'keep','empty'}),true)
eq(r.after,'efficiency-module*1'); eq(r.returned,'speed-module*1 (to your inventory)'); eq(held['speed-module@normal'],2)
r=M.set(p,a,M.parse({['2']='speed-module'}),true)
eq(r.after,'efficiency-module*1 speed-module*1'); eq(ainv[1].name,'efficiency-module'); eq(ainv[2].name,'speed-module')
eq(M.set(p,a,M.parse({['1']='keep'}),true).unchanged,true)
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
-- Astra, shift13 19:40: 9 drills holding speed-module-2 in slots 1 and 2 and efficiency-module in slot 3, asked for
-- ["speed-module-2", "efficiency-module"] by robots. Slot by slot that took the efficiency module out of slot 3 and asked
-- for one in slot 2, none in the network (the drills drew more power). Now the modules named stay where they are:
-- only one speed-module-2 comes out.
local d,dinv=machine(drill,60.5,nil)
dinv[1].set_stack{name='speed-module-2'}; dinv[2].set_stack{name='speed-module-2'}; dinv[3].set_stack{name='efficiency-module'}
roboports={}
r=M.set(p,d,M.parse({'speed-module-2','efficiency-module'}),true,'robots')
eq(r.requested,nil); eq(r.removing,'speed-module-2*1')
eq(r.by_slot[1],'1 speed-module-2'); eq(r.by_slot[2],'2 speed-module-2 (speed-module-2 coming out)'); eq(r.by_slot[3],'3 efficiency-module')
eq(#d.item_request_proxy.insert_plan,0); eq(d.item_request_proxy.removal_plan[1].items.in_inventory[1].stack,1)
-- The same list again: the request stands as it is.
r=M.set(p,d,M.parse({'speed-module-2','efficiency-module'}),true,'robots')
eq(r.unchanged,true); eq(r.removing,'speed-module-2*1')
-- A module on its way in counts where it goes: slot 2's request is left, slot 1's speed module stays.
r=M.set(p,d,M.parse({['2']='efficiency-module'}),true,'robots')
eq(r.requested,'efficiency-module*1'); eq(r.removing,'speed-module-2*1'); eq(r.by_slot[2],'2 speed-module-2 (efficiency-module requested; speed-module-2 coming out)')
r=M.set(p,d,M.parse({'efficiency-module','speed-module-2','efficiency-module'}),true,'robots')
eq(r.unchanged,true); eq(r.requested,'efficiency-module*1')
-- A module requested for slot 2 (slot 1 empty) stays requested there: the list asks for nothing new.
local d2,d2inv=machine(drill,62.5,nil)
d2inv[3].set_stack{name='speed-module-2'}
M.set(p,d2,M.parse({['2']='efficiency-module'}),true,'robots')
r=M.set(p,d2,M.parse({'efficiency-module','speed-module-2'}),true,'robots')
eq(r.unchanged,true); eq(r.requested,'efficiency-module*1'); eq(r.by_slot[1],'1 empty'); eq(r.by_slot[2],'2 empty (efficiency-module requested)')
-- Numbered slots: slot 3 changes, slot 2's request is kept as it is.
r=M.set(p,d,M.parse({['3']='speed-module-2'}),true,'robots')
eq(r.requested,'efficiency-module*1 speed-module-2*1'); eq(r.removing,'speed-module-2*1 efficiency-module*1')
eq(r.by_slot[1],'1 speed-module-2'); eq(r.by_slot[3],'3 efficiency-module (speed-module-2 requested; efficiency-module coming out)')
-- keep and empty slot by slot: slot 1 as it is, slot 2 empty (its request goes), slot 3 empty.
r=M.set(p,d,M.parse({'keep','empty','empty'}),true,'robots')
eq(r.requested,nil); eq(r.removing,'speed-module-2*1 efficiency-module*1')
eq(r.by_slot[2],'2 speed-module-2 (speed-module-2 coming out)'); eq(r.by_slot[3],'3 efficiency-module (efficiency-module coming out)')
-- Too high a slot, and a module the drill does not take.
fails(function() M.set(p,d,M.parse({['4']='speed-module'}),true,'robots') end,'electric-mining-drill (60.5,0.5) has 3 module slots; slot 4 named')
-- By hand, a list with fewer modules: the ones named stay, the others come out.
local h,hin=machine(drill,8.5,nil)
hin[1].set_stack{name='speed-module'}; hin[2].set_stack{name='efficiency-module'}; hin[3].set_stack{name='speed-module'}
held['speed-module@normal']=0; held['efficiency-module@normal']=0
r=M.set(p,h,M.parse({'efficiency-module','speed-module'}),true)
eq(r.by,'hand'); eq(r.returned,'speed-module*1 (to your inventory)'); eq(r.by_slot[1],'1 speed-module'); eq(r.by_slot[2],'2 efficiency-module'); eq(r.by_slot[3],'3 empty')
-- A hand swap clears the robot requests on the slots it set.
local px2={valid=true,insert_plan={{id={name='efficiency-module',quality='normal'},items={in_inventory={{inventory=4,stack=2,count=1}}}}},removal_plan={}}
px2.destroy=function() px2.valid=false; h.item_request_proxy=nil end
h.item_request_proxy=px2
held['speed-module@normal']=1
r=M.set(p,h,M.parse({['3']='speed-module'}),true)
eq(r.note,'the robot requests on the slots set were cleared'); eq(px2.valid,false); eq(r.by_slot[3],'3 speed-module')
-- A ghost with no requests yet: a numbered slot alone.
local g3={valid=true,type='entity-ghost',name='entity-ghost',ghost_name='electric-mining-drill',ghost_type='mining-drill',ghost_prototype=drill,
  position={x=13.5,y=0.5},force=force,surface=surface,insert_plan={}}
r=M.set(p,g3,M.parse({['2']='speed-module'}),true)
eq(r.requested,'speed-module*1'); eq(r.by_slot[1],'1 empty'); eq(r.by_slot[2],'2 speed-module (requested)'); eq(r.by_slot[3],'3 empty')
-- A ghost: numbered slots keep the other requests.
local g2={valid=true,type='entity-ghost',name='entity-ghost',ghost_name='electric-mining-drill',ghost_type='mining-drill',ghost_prototype=drill,
  position={x=11.5,y=0.5},force=force,surface=surface,insert_plan={}}
M.set(p,g2,M.parse({'speed-module','speed-module','speed-module'}),true)
r=M.set(p,g2,M.parse({['2']='efficiency-module'}),true)
eq(r.before,'speed-module*3'); eq(r.requested,'speed-module*2 efficiency-module*1')
eq(r.by_slot[1],'1 speed-module (requested)'); eq(r.by_slot[2],'2 efficiency-module (requested)'); eq(r.by_slot[3],'3 speed-module (requested)')
r=M.set(p,g2,M.parse({'efficiency-module','speed-module'}),true)
eq(r.requested,'speed-module*1 efficiency-module*1'); eq(r.by_slot[1],'1 speed-module (requested)'); eq(r.by_slot[3],'3 empty')
-- Sol, 23:20 (aboard a platform): configure surface=nauvis modules productivity-module x2 into a lab, by remote view.
-- A caller with no body (any read of a body errors, as bots.lua's proxy aboard) gets an item request; robots bring them.
do
  local lab={name='lab',type='lab',allowed_effects=ALL,module_inventory_size=2}
  local l=machine(lab,37.5,nil)
  local nobody=setmetatable({surface=surface,force=force},{__index=function(_,k) error('bot sol is aboard platform Sunward with no body',0) end})
  local row=M.set(nobody,l,M.parse({'productivity-module','productivity-module'}),false)
  eq(row.by,'robots'); eq(row.requested,'productivity-module*2'); eq(l.item_request_proxy.insert_plan[1].id.name,'productivity-module')
  fails(function() M.set(nobody,l,M.parse({'productivity-module'}),false,'hand') end,'out of reach')
end
print('modules: ok')
