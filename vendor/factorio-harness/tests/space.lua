-- Run from repository root: lua tests/space.lua
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
defines={space_platform_state={waiting_for_starter_pack=0,waiting_at_station=6,paused=7},
  rocket_silo_status={building_rocket=5,rocket_ready=9},inventory={hub_main=1,rocket_silo_rocket=2},
  cargo_destination={orbit=1,station=2,surface=3,space_platform=4}}
prototypes={item={['iron-plate']={},coal={},['space-platform-starter-pack']={}},space_location={nauvis={},vulcanus={}}}
-- A manual logistic section with slots like the engine's (gaps allowed).
local function section(manual,group)
  local slots={}
  local sec={index=1,is_manual=manual,group=group or '',active=true}
  sec.filters_count=0
  local function recount() local n=0; for i in pairs(slots) do n=math.max(n,i) end; sec.filters_count=n end
  sec.get_slot=function(i) return slots[i] or {} end
  sec.set_slot=function(i,f) slots[i]=f; recount() end
  sec.clear_slot=function(i) slots[i]=nil; recount() end
  setmetatable(sec,{__index=function(_,k) if k=='filters' then local out={}; for i=1,sec.filters_count do out[i]=slots[i] or {} end; return out end end,
    __newindex=function(t,k,v) if k=='filters' then slots={}; recount() else rawset(t,k,v) end end})
  return sec
end
local function sections(list)
  return setmetatable({get_section=function(i) return list[i] end,
    add_section=function() local s=section(true); s.index=#list+1; list[#list+1]=s; return s end},
    {__index=function(_,k) if k=='sections_count' then return #list end end})
end
local char_sections=sections({})
local hub_sections=sections({section(false),section(true)})
hub_sections.get_section(2).index=2
local hub_inv={get_contents=function() return {{name='iron-plate',count=5}} end}
local platform={valid=true,name='alpha',index=1,state=7,paused=true,space_location={name='nauvis'},weight=60000,
  surface={name='platform-1'},hub={valid=true,position={x=0,y=0},get_logistic_sections=function() return hub_sections end,
    get_inventory=function() return hub_inv end},can_leave_current_location=function() return true end}
local silo_cargo={get_contents=function() return {} end}
local launched
local silo={valid=true,type='rocket-silo',position={x=20.5,y=20.5},rocket_silo_status=5,rocket_parts=10,prototype={rocket_parts_required=50},
  get_inventory=function() return silo_cargo end,launch_rocket=function(d) launched=d; return true end}
local p={index=1,force={platforms={platform},recipes={}},character={get_logistic_sections=function() return char_sections end},
  surface={planet={name='nauvis'},find_entities_filtered=function() return {silo} end}}
local space_state={}
local space=dofile('mod/agent-harness_0.1.0/space.lua'){
  state=function() return space_state end,
  -- The spread lines (runtime.lua fresh_inv, tested in tests/picksource.lua): which inventory and items were asked.
  fresh_inv=function(force,inv,names)
    local list={}
    for name in pairs(names or {}) do list[#list+1]=name end
    table.sort(list)
    _G.fresh_asked={inv=inv,names=#list>0 and table.concat(list,',') or nil}
    return {'spread of '..(#list>0 and table.concat(list,',') or 'all')}
  end,
  position=function(v) return v end,
  integer=function(v,d,lo,hi,name) v=v==nil and d or v; assert(type(v)=='number' and v>=lo and v<=hi,name..' out of range'); return v end,
  remote_entity=function(_,a) assert(a.position.x==20.5,'no entity of ours at that position'); return silo end,
  real=function(q) return q end,stop=function(q) q.stopped=(q.stopped or 0)+1 end,
  -- drops.lua's side, faked: who is told, and the record space.drop hands it
  drops={recipients=function(to) if to==nil then return {} end assert(to~='nobody','unknown agent nobody'); return {to} end,
    record=function(_,d) _G.drop_record=d; _G.drop_records=_G.drop_records or {}; table.insert(_G.drop_records,d); return 7 end},
  -- The pod split (cargo.lua) and a full drop's timed action (runtime.lua).
  cargo=dofile('mod/agent-harness_0.1.0/cargo.lua'){},start=function(_,job) _G.drop_job=job end,pending=function() return _G.pending_job end}
-- Character requests: a manual section is created, slots are reused per item.
local r=space.requests(p,{set={{item='iron-plate',min=100},{item='coal',min=5,max=10}}})
eq(r.target,'character'); eq(r.sections[1].requests[1],'iron-plate 100..inf'); eq(r.sections[1].requests[2],'coal 5..10')
r=space.requests(p,{set={{item='iron-plate',min=50,max=50}}})
eq(#r.sections[1].requests,2); eq(r.sections[1].requests[1],'iron-plate=50')
r=space.requests(p,{clear={'iron-plate'}})
eq(#r.sections[1].requests,1); eq(r.sections[1].requests[1],'coal 5..10')
r=space.requests(p,{set={{item='iron-plate',min=1}}}) -- the freed slot is reused
eq(r.sections[1].requests[1],'iron-plate 1..inf')
eq(#space.requests(p,{clear_all=true}).sections[1].requests,0)
fails(function() space.requests(p,{set={{item='nope',min=1}}}) end,'unknown item: nope')
fails(function() space.requests(p,{set={{item='coal',min=5,max=2}}}) end,'max must be at least min')
-- min alone keeps the slot's max while it is at least min, as the GUI does (friction3: Grok's map sets turned
-- copper-cable 200..400 into 40..inf); under min it is dropped, said; "inf" sets none.
r=space.requests(p,{set={{item='coal',min=5,max=10}}})
r=space.requests(p,{set={{item='coal',min=7}}})
eq(r.sections[1].requests[1],'coal 7..10'); eq(r.stored[1],'coal 7..10 (max kept: not named in this edit) (was coal 5..10)')
r=space.requests(p,{set={{item='coal',min=20}}})
eq(r.stored[1],'coal 20..inf (max 10 dropped: under min 20) (was coal 7..10)')
r=space.requests(p,{set={{item='coal',min=5,max=10}}})
r=space.requests(p,{set={{item='coal',min=5,max='inf'}}})
eq(r.stored[1],'coal 5..inf (was coal 5..10)')
fails(function() space.requests(p,{set={{item='coal',min=5,max='lots'}}}) end,'max must be at least min ("inf" for none)')
space.requests(p,{clear_all=true})
-- set as a map (friction2: Muse's {"low-density-structure": 100} set nothing and the reply said changed_section 1; the
-- silo requester stayed at min 4 for 11.7 min): the call runs as the list (aliases.lua, the reply's corrected says so);
-- a map that reaches the handler is refused with the list form; a call that changes nothing names no changed section.
do
  prototypes.item['low-density-structure']={}; prototypes.item.grenade={}
  local aliases=dofile('mod/agent-harness_0.1.0/aliases.lua'){}
  local takes=function() return true end
  local _,args,fix=aliases.fix('requests',{position={x=1,y=2},set={['low-density-structure']=100,coal={min=5,max=10},['iron-plate']={count=7}}},takes)
  eq(#args.set,3); eq(args.set[1].item,'coal'); eq(args.set[1].min,5); eq(args.set[1].max,10)
  eq(args.set[2].item,'iron-plate'); eq(args.set[2].min,7); eq(args.set[2].count,nil)
  eq(args.set[3].item,'low-density-structure'); eq(args.set[3].min,100); eq(args.position.x,1)
  eq(fix.notes[1],'set as a map {item: min} is the list [{item, min}]'); eq(fix.quiet,true)
  eq(fix.call,'requests {"position":{"x":1,"y":2},"set":[{"item":"coal","max":10,"min":5},{"item":"iron-plate","min":7},{"item":"low-density-structure","min":100}]}')
  -- a list, or a map of something else, is left as it is
  local list={{item='coal',min=1}}
  local _,same,none=aliases.fix('requests',{set=list},takes); eq(same.set,list); eq(none,nil)
  _,same,none=aliases.fix('requests',{set={coal='lots'}},takes); eq(same.set.coal,'lots'); eq(none,nil)
  args.position=nil; r=space.requests(p,args)
  eq(r.changed_section,1); eq(r.stored[3],'low-density-structure 100..inf')
  fails(function() space.requests(p,{set={coal='lots'}}) end,'set requires an array of {item,min,max?,quality?,from?}: [{"item":"iron-plate","min":100}]')
  r=space.requests(p,{clear={'grenade'}})
  eq(r.changed_section,nil); eq(r.unchanged,'this call set, cleared and switched nothing in section 1')
  eq(r.stored[1],'grenade: no request to clear in section 1')
  r=space.requests(p,{set={}})
  eq(r.changed_section,nil); eq(r.unchanged,'this call set, cleared and switched nothing in section 1')
  r=space.requests(p,{clear={'coal','iron-plate','low-density-structure'}})
  eq(r.changed_section,1); eq(r.unchanged,nil)
  prototypes.item['low-density-structure']=nil; prototypes.item.grenade=nil
end
-- Platform hub requests skip the game-controlled section and name the planet.
r=space.requests(p,{platform='alpha',set={{item='iron-plate',min=100,from='nauvis'}}})
eq(r.target,'platform alpha'); eq(r.sections[2].requests[1],'iron-plate 100..inf from nauvis'); eq(r.sections[1].controlled,true)
fails(function() space.requests(p,{platform='beta'}) end,'no platform named beta; platforms: alpha')
fails(function() space.requests(p,{section=1,platform='alpha',set={{item='coal',min=1}}}) end,'controlled by the game')
-- An exact request keeps its planet in the readback (Astra, 02:00: `calcite=500` hid `from vulcanus`); a section that
-- is off says so (off=true and a note: false drops out of the compact reply), and active switches it.
r=space.requests(p,{platform='alpha',set={{item='coal',min=500,max=500,from='vulcanus'}}})
eq(r.sections[2].requests[2],'coal=500 from vulcanus'); eq(r.changed_section,2); eq(r.sections[2].off,nil)
-- What is stored for each item touched is echoed, and an edit without from keeps the import planet (Luna, shift12
-- 19:30: min/max edits of three requests from vulcanus turned them into from nauvis).
eq(r.stored[1],'coal=500 from vulcanus')
r=space.requests(p,{platform='alpha',set={{item='coal',min=0,max=400}}})
eq(r.sections[2].requests[2],'coal 0..400 from vulcanus')
eq(r.stored[1],'coal 0..400 from vulcanus (import planet kept: not named in this edit) (was coal=500 from vulcanus)')
r=space.requests(p,{platform='alpha',set={{item='coal',min=0,max=400,from='nauvis'}}})
eq(r.stored[1],'coal 0..400 from nauvis (was coal 0..400 from vulcanus)')
fails(function() space.requests(p,{platform='alpha',set={{item='coal',min=1,from='Sunward'}}}) end,
  'from is the planet a platform hub imports the item from, a space location (nauvis, vulcanus): Sunward is not one')
r=space.requests(p,{platform='alpha',clear={'coal','iron-plate','iron-plate'}})
eq(r.stored[1],'coal: cleared (was coal 0..400 from nauvis)'); eq(r.stored[2],'iron-plate: cleared (was iron-plate 100..inf from nauvis)')
eq(r.stored[3],'iron-plate: no request to clear in section 2')
r=space.requests(p,{platform='alpha',set={{item='iron-plate',min=100,from='nauvis'},{item='coal',min=500,max=500,from='vulcanus'}}})
eq(r.sections[2].requests[1],'iron-plate 100..inf from nauvis'); eq(r.sections[2].requests[2],'coal=500 from vulcanus')
eq(space.requests(p,{platform='alpha'}).stored,nil,'a plain read echoes nothing')
-- A character request names no planet.
eq(space.requests(p,{set={{item='coal',min=5}}}).stored[1],'coal 5..inf')
space.requests(p,{clear={'coal'}})
hub_sections.get_section(2).active=false
r=space.requests(p,{platform='alpha'})
eq(r.sections[2].off,true); eq(r.note,'section 2 is switched off: its requests are not made (requests {section, active: true} switches one on)')
r=space.requests(p,{platform='alpha',section=2,active=true})
eq(r.sections[2].off,nil); eq(r.note,nil); eq(hub_sections.get_section(2).active,true)
fails(function() space.requests(p,{platform='alpha',active='yes'}) end,'active must be true or false')
-- The platforms row keeps the requests of a section that is off apart.
hub_sections.get_section(2).active=false
local offrow=space.platforms(p,{}).platforms[1]
eq(offrow.requests,nil); eq(offrow.requests_off[1],'iron-plate 100..inf from nauvis'); eq(offrow.requests_off[2],'coal=500 from vulcanus')
hub_sections.get_section(2).active=true
eq(space.platforms(p,{}).platforms[1].requests_off,nil)
-- A requester chest: its requests and its "request from buffer chests" switch.
do
  local chest_sections=sections({})
  local requester={valid=true,name='requester-chest',type='logistic-container',position={x=3.5,y=3.5},request_from_buffers=false,
    get_logistic_sections=function() return chest_sections end}
  local space2=dofile('mod/agent-harness_0.1.0/space.lua'){
    position=function(v) return v end,
    integer=function(v,d,lo,hi,name) v=v==nil and d or v; assert(type(v)=='number' and v>=lo and v<=hi,name..' out of range'); return v end,
    remote_entity=function() return requester end,real=function(q) return q end,stop=function() end}
  local rq=space2.requests(p,{position={x=3.5,y=3.5},set={{item='iron-plate',min=200}},from_buffers=true})
  eq(rq.target,'requester-chest at (3.5,3.5)'); eq(rq.sections[1].requests[1],'iron-plate 200..inf')
  eq(requester.request_from_buffers,true); eq(rq.from_buffers,true)
  eq(space2.requests(p,{position={x=3.5,y=3.5}}).from_buffers,true) -- a read reports it
  fails(function() space2.requests(p,{position={x=3.5,y=3.5},from_buffers='yes'}) end,'from_buffers must be boolean')
  fails(function() space.requests(p,{platform='alpha',from_buffers=true}) end,'from_buffers is a requester chest setting')
end
-- Platform view and schedule.
local view=space.platforms(p,{})
eq(view.platforms[1].state,'paused'); eq(view.platforms[1].at,'nauvis'); eq(view.platforms[1].hub_items,'iron-plate*5')
eq(view.platforms[1].requests[1],'iron-plate 100..inf from nauvis'); eq(view.silos[1].parts,'10/50'); eq(view.silos[1].status,'building_rocket')
eq(view.platforms[1].speed,nil,'details only for one named platform')
-- One platform in full: speed, damage, chunks, thruster tanks, unbuilt ghosts.
platform.speed=0.0123; platform.damaged_tiles={{position={x=1,y=1},damage=5}}
platform.find_asteroid_chunks_filtered=function() return {{name='metallic-asteroid-chunk'},{name='metallic-asteroid-chunk'},{name='oxide-asteroid-chunk'}} end
local tank=function(fuel,ox) return setmetatable({get_capacity=function() return 1000 end},{__index=function(_,i) return ({{amount=fuel},{amount=ox}})[i] end}) end
platform.surface.find_entities_filtered=function(f) if f.type=='thruster' then return {{fluidbox=tank(800,500)},{fluidbox=tank(1000,900)}} end return {} end
platform.surface.count_entities_filtered=function() return 7 end
local one=space.platforms(p,{platform='alpha'}).platforms[1]
-- Sol, 22:52: the hub's spread on the row, so cargo is judged before departure.
eq(one.freshness[1],'spread of all')
eq(one.speed_kms,0.7); eq(one.speed,0.012); eq(one.damaged_tiles,1); eq(one.asteroid_chunks,'metallic-asteroid-chunk*2 oxide-asteroid-chunk*1')
eq(one.thrusters,'2, lowest tank 50%'); eq(one.unbuilt_ghosts,7)
platform.find_asteroid_chunks_filtered=function() error('no chunks API') end
eq(space.platforms(p,{platform='alpha'}).platforms[1].asteroid_chunks,nil,'a failing read is skipped')
-- Where hub items go (request #4): an inserter taking from the hub with
-- nothing to drop into, items thrown overboard, the game's item statistics for
-- the platform surface, and the hub's trash slots.
do
  local find,saved_force=platform.surface.find_entities_filtered,platform.force
  local drain={position={x=-2.5,y=3.5},pickup_target=platform.hub,drop_position={x=-2.5,y=4.7}}
  local fed={position={x=1.5,y=3.5},pickup_target=platform.hub,drop_target={name='crusher'},drop_position={x=1.5,y=4.7}}
  platform.surface.find_entities_filtered=function(f) if f.type=='inserter' then return {drain,fed} end return find(f) end
  platform.surface.get_tile=function(x,y) return {name=y==4 and x==-3 and 'empty-space' or 'space-platform-foundation'} end
  defines.flow_precision_index={ten_minutes=1}; defines.inventory.hub_trash=5
  platform.force={get_item_production_statistics=function(s)
    assert(s==platform.surface)
    return {output_counts={['firearm-magazine']=50,coal=1},input_counts={['solar-panel']=4},
      get_flow_count=function(f) assert(f.precision_index==1 and f.count==true); return ({['firearm-magazine']=20,['solar-panel']=4})[f.name] or 0 end}
  end}
  platform.ejected_items={{item={name='firearm-magazine',quality='normal'}},{item={name='firearm-magazine',quality='normal'}},{item={name='solar-panel',quality='normal'}}}
  local row=space.platforms(p,{platform='alpha'}).platforms[1]
  eq(#row.hub_inserters_without_target,1); eq(row.hub_inserters_without_target[1],'(-2.5,3.5) drops onto empty-space')
  eq(row.consumed_10min,'firearm-magazine*20'); eq(row.produced_10min,'solar-panel*4')
  eq(row.thrown_overboard,'firearm-magazine*2 solar-panel*1')
  eq(row.hub_trash,'iron-plate*5')
  local all=space.platforms(p,{}).platforms[1]
  eq(all.thrown_overboard,nil,'details only for one named platform'); eq(all.hub_trash,'iron-plate*5','every row')
  -- Where the hub's trash goes (operator 09:04: Sunward's trash on Gleba, no landing pad): down to the planet the
  -- platform is stopped at, to its pad or as cargo-pod containers near (0,0); kept while flying.
  eq(all.hub_trash_note,nil,'a location not known as a planet: no note')
  local saved_loc=platform.space_location
  platform.space_location={name='gleba',type='planet'}
  eq(space.platforms(p,{}).platforms[1].hub_trash_note,'the game sends the hub\'s trash down to gleba in cargo pods while the platform is stopped there: to its landing pad, or, with none there, as cargo-pod containers on the ground near (0,0) (where_is lists them)')
  platform.space_location,platform.space_connection,platform.distance=nil,{from={name='nauvis'},to={name='gleba'},length=15000},0.5
  eq(space.platforms(p,{}).platforms[1].hub_trash_note,'the hub keeps its trash while flying; when the platform stops at a planet, the game sends it down in cargo pods: to its landing pad, or, with none there, as cargo-pod containers on the ground near (0,0) (where_is lists them)')
  -- requests on a hub: a max under what it holds is named, with the trash and where it goes.
  hub_inv.get_item_count=function(it) assert(it.name=='iron-plate' and it.quality=='normal'); return 5 end
  local rq=space.requests(p,{platform='alpha',set={{item='iron-plate',min=0,max=2}}})
  eq(rq.over_max[1],'iron-plate: the hub holds 5, 3 over the max 2'); eq(rq.hub_trash,'iron-plate*5')
  assert(rq.trash_note:find('^in flight the game moves what is over a max to the hub\'s trash within a second%. the hub keeps its trash while flying'),rq.trash_note)
  platform.space_location,platform.space_connection={name='gleba',type='planet'},nil
  rq=space.requests(p,{platform='alpha',set={{item='iron-plate',min=0,max=2}}})
  assert(rq.trash_note:find('^while the platform is stopped the game leaves what is over a max in the hub; once it flies, the game moves that to the trash, which goes down at the next stop%. the game sends the hub\'s trash down to gleba'),rq.trash_note)
  platform.space_location,platform.space_connection={name='nauvis'},{from={name='nauvis'},to={name='gleba'},length=15000}
  rq=space.requests(p,{platform='alpha',set={{item='iron-plate',min=0,max=9}}})
  eq(rq.over_max,nil); assert(rq.trash_note:find('^the hub keeps its trash while flying'),rq.trash_note)
  hub_inv.get_item_count=nil
  space.requests(p,{platform='alpha',clear={'iron-plate'}})
  platform.space_location,platform.space_connection,platform.distance=saved_loc,nil,nil
  platform.surface.find_entities_filtered,platform.force,platform.ejected_items=find,saved_force,nil
  defines.flow_precision_index,defines.inventory.hub_trash=nil,nil
end
-- Repair on a platform is the game's (shift05 08:03: Astra's hub stayed at
-- 637/1000 while 5 packs went to turrets and an inserter): the named view
-- lists what is damaged, most damaged first, and the hub's repair packs.
do
  local find,contents=platform.surface.find_entities_filtered,hub_inv.get_contents
  local function ent(name,x,h,m) return {name=name,position={x=x,y=0},health=h,max_health=m} end
  platform.surface.find_entities_filtered=function(f)
    if not f.type then return {ent('space-platform-hub',0,637,1000),ent('gun-turret',-6,53,400),ent('inserter',4.5,150,150),{name='entity-ghost',position={x=1,y=1},max_health=0}} end
    return find(f)
  end
  local row=space.platforms(p,{platform='alpha'}).platforms[1]
  eq(row.repair_packs,'none'); eq(#row.damaged,2)
  eq(row.damaged[1],'gun-turret (-6,0) 53/400'); eq(row.damaged[2],'space-platform-hub (0,0) 637/1000'); eq(row.damaged_count,nil)
  prototypes.item['repair-pack']={type='repair-tool'}
  hub_inv.get_contents=function() return {{name='iron-plate',count=5},{name='repair-pack',count=12}} end
  eq(space.platforms(p,{platform='alpha'}).platforms[1].repair_packs,'repair-pack*12')
  -- Every row has the damaged and repair packs (platforms study: hub health and
  -- damage came only from inspect); the most damaged 3 without platform=.
  local all=space.platforms(p,{}).platforms[1]
  eq(#all.damaged,2); eq(all.repair_packs,'repair-pack*12'); eq(all.speed,nil,'speed only for one named platform')
  assert(space.REPAIR_NOTE:find('one entity at a time',1,true))
  platform.surface.find_entities_filtered,hub_inv.get_contents,prototypes.item['repair-pack']=find,contents,nil
end
local sch=space.platform_schedule(p,{platform='alpha',stops={{station='vulcanus',wait={{type='time',ticks=600}}},{station='nauvis',wait={{type='all_requests_satisfied'}}}},paused=false})
eq(sch.schedule,'>vulcanus (time 10s) | nauvis (all_requests_satisfied)'); eq(platform.paused,false)
eq(platform.schedule.records[1].wait_conditions[1].ticks,600)
fails(function() space.platform_schedule(p,{platform='alpha',stops={{station='moon'}}}) end,'station must be a planet')
-- Launch: only a ready rocket, to a platform in orbit here or explicitly to orbit.
fails(function() space.launch(p,{position={x=20.5,y=20.5},platform='alpha'}) end,'rocket is not ready: building_rocket')
silo.rocket_silo_status=9
fails(function() space.launch(p,{position={x=20.5,y=20.5}}) end,'orbit=true')
-- An empty rocket (Sol, 06:29: Luna launched empty while bio science sat in a chest nearby): refused unless
-- allow_empty, naming the science in chests within 32 tiles.
prototypes.item['agricultural-science-pack']={type='tool'}; prototypes.item['iron-plate']={type='item'}
local bio={valid=true,name='wooden-chest',position={x=30.5,y=22.5},get_inventory=function() return {get_contents=function()
  return {{name='iron-plate',count=50},{name='agricultural-science-pack',count=120}} end} end}
silo.surface={find_entities_filtered=function(f) assert(f.radius==32 and f.limit,'bounded'); return {bio} end}
fails(function() space.launch(p,{position={x=20.5,y=20.5},platform='alpha'}) end,
  'launch refused: the rocket holds nothing, and launching spends its parts; load cargo with transfer {position, direction=to_entity, inventory=rocket_silo_rocket, item, count}, or allow_empty=true to launch it empty; science in chests within 32 tiles: wooden-chest (30.5,22.5) agricultural-science-pack*120')
fails(function() space.launch(p,{position={x=20.5,y=20.5},platform='alpha',allow_empty='yes'}) end,'allow_empty must be boolean')
local l=space.launch(p,{position={x=20.5,y=20.5},platform='alpha',allow_empty=true})
-- Cargo goes to the hub as a station (a surface destination on a platform
-- makes the game refuse: shift04 07:17, Peregrine paused in orbit).
eq(l.to,'platform alpha'); eq(launched.type,2); eq(launched.station,platform.hub); eq(launched.surface,nil); eq(l.cargo,'empty')
-- Sol, 22:52: the rocket cargo's spread, read before it goes.
eq(l.freshness[1],'spread of all'); eq(fresh_asked.inv,silo_cargo)
-- A new platform waiting for its starter pack: the space_platform destination.
platform.state=0
space.launch(p,{position={x=20.5,y=20.5},platform='alpha',allow_empty=true})
eq(launched.type,4); eq(launched.space_platform,platform)
platform.state=7
-- Over the rocket's lift (shift04 07:17: Sol's 1060 kg): refused before the
-- game is asked, naming the excess and the heaviest cargo.
do
  local launch,saved=silo.launch_rocket,silo_cargo
  local asked=0
  silo.launch_rocket=function() asked=asked+1; return false end
  local weights={['space-platform-foundation']=20000,['firearm-magazine']=10000,['gun-turret']=20000,['fast-inserter']=20000,['solar-panel']=20000,stone=50000}
  for name,w in pairs(weights) do prototypes.item[name]={weight=w} end
  prototypes.utility_constants={rocket_lift_weight=1000000}
  silo_cargo={get_contents=function() return {{name='solar-panel',count=1},{name='gun-turret',count=4},{name='space-platform-foundation',count=30},
    {name='fast-inserter',count=4},{name='firearm-magazine',count=28}} end}
  eq(space.platforms(p,{}).silos[1].weight,'1060/1000 kg')
  fails(function() space.launch(p,{position={x=20.5,y=20.5},platform='alpha'}) end,
    'launch refused, overweight by 60 kg: the rocket holds 1060 kg and lifts 1000 kg; take cargo out with transfer {position, direction=to_player, inventory=rocket_silo_rocket, item, count} (cargo: space-platform-foundation*30 at 20 kg, firearm-magazine*28 at 10 kg, fast-inserter*4 at 20 kg, gun-turret*4 at 20 kg, solar-panel*1 at 20 kg)')
  eq(asked,0)
  -- The game says no (launch_rocket false) for its own reasons: the error names what may stop it.
  silo_cargo={get_contents=function() return {{name='stone',count=20}} end}
  fails(function() space.launch(p,{position={x=20.5,y=20.5},platform='alpha'}) end,
    'the game refused the launch (launch_rocket returned false): the silo holds no rocket entity; platform alpha is paused (platform_schedule paused=false unpauses it) [silo rocket_ready/nil, cargo 1000/1000 kg, platform alpha paused at nauvis, destination station]')
  silo.rocket={valid=true}; platform.state=6
  fails(function() space.launch(p,{position={x=20.5,y=20.5},platform='alpha'}) end,
    'the game refused the launch (launch_rocket returned false) [silo rocket_ready/nil, cargo 1000/1000 kg, platform alpha waiting_at_station at nauvis, destination station]')
  eq(asked,2)
  silo.launch_rocket,silo_cargo,silo.rocket,platform.state=launch,saved,nil,7
  for name in pairs(weights) do prototypes.item[name]=nil end
  prototypes.utility_constants=nil
end
platform.space_location={name='vulcanus'}
fails(function() space.launch(p,{position={x=20.5,y=20.5},platform='alpha'}) end,'not in orbit of nauvis')
eq(space.launch(p,{position={x=20.5,y=20.5},auto_requests=true}).auto_requests,true)
-- Switching automatic requests on with cargo loaded by hand: the game moves it
-- to the silo's trash slots; the reply names it and how to take it back.
do
  defines.inventory.rocket_silo_trash=3
  local trash={get_contents=function() return {} end}
  local get_inv,saved=silo.get_inventory,silo_cargo
  silo.get_inventory=function(i) if i==3 then return trash end return silo_cargo end
  silo.use_transitional_requests=false
  silo_cargo={get_contents=function() return {{name='space-platform-foundation',count=40},{name='solar-panel',count=7}} end}
  local sw=space.launch(p,{position={x=20.5,y=20.5},auto_requests=true})
  eq(sw.auto_requests,true); eq(sw.cargo_to_trash,'space-platform-foundation*40 solar-panel*7'); eq(sw.trash,nil)
  assert(sw.note:find('moves that cargo out of the rocket into the silo\'s trash slots',1,true),sw.note)
  assert(sw.note:find('transfer {position, direction=to_player, inventory=rocket_silo_trash}',1,true),sw.note)
  -- Already on, or switching off: no note.
  eq(space.launch(p,{position={x=20.5,y=20.5},auto_requests=true}).note,nil)
  eq(space.launch(p,{position={x=20.5,y=20.5},auto_requests=false}).note,nil)
  -- The game moved it: the reply and the platforms read list the trash.
  silo_cargo=saved
  trash={get_contents=function() return {{name='space-platform-foundation',count=40},{name='inserter',count=1}} end}
  eq(space.launch(p,{position={x=20.5,y=20.5},auto_requests=true}).trash,'space-platform-foundation*40 inserter*1')
  eq(space.platforms(p,{}).silos[1].trash,'space-platform-foundation*40 inserter*1')
  silo.get_inventory,silo.use_transitional_requests,defines.inventory.rocket_silo_trash=get_inv,nil,nil
end
-- Riding needs the silo in reach and a platform; the character goes along.
platform.space_location={name='nauvis'}
p.can_reach_entity=function() return false end
fails(function() space.launch(p,{position={x=20.5,y=20.5},platform='alpha',ride=true}) end,'within reach of the silo')
p.can_reach_entity=function() return true end
fails(function() space.launch(p,{position={x=20.5,y=20.5},ride=true}) end,'ride needs platform')
-- Riding as the silo GUI allows: no other payload, nothing carried but armor and guns.
defines.inventory.character_main=10; defines.inventory.character_ammo=11
local carried={[10]=false,[11]=false}
p.character.get_inventory=function(i) return {is_empty=function() return not carried[i] end} end
carried[11]=true
fails(function() space.launch(p,{position={x=20.5,y=20.5},platform='alpha',ride=true}) end,'put down everything in character_ammo')
carried[11]=false
local saved_cargo=silo_cargo
silo_cargo={get_contents=function() return {{name='coal',count=5}} end}
fails(function() space.launch(p,{position={x=20.5,y=20.5},platform='alpha',ride=true}) end,'only payload')
silo_cargo=saved_cargo
local rode=space.launch(p,{position={x=20.5,y=20.5},platform='alpha',ride=true})
assert(rode.riding); eq(p.stopped,1)
-- A bot (no LuaPlayer behind it) rides through bots.lua: the same checks
-- first, then the rocket flies with no character and the bot boards its pod.
local bot=setmetatable({__bot='astra'},{__index=p})
local real_of=function(q) if rawget(q,'__bot') then return nil end return q end
local boarded,landed,checked
local record={name='astra'}
local bot_space=dofile('mod/agent-harness_0.1.0/space.lua'){position=function(v) return v end,integer=function(v) return v end,
  remote_entity=function() return silo end,real=real_of,stop=function(q) q.stopped=(q.stopped or 0)+1 end,
  bot=function(q) return rawget(q,'__bot') and record or nil end,
  bots={can_board=function(b) checked=b end,board=function(b,pl,pod) boarded={b=b,pl=pl,pod=pod} end,
    land=function(b) landed=b; return {landing='nauvis',at={x=1,y=2}} end}}
silo.rocket={valid=true,attached_cargo_pod={valid=true,name='cargo-pod'}}
carried[10]=true
fails(function() bot_space.launch(bot,{position={x=20.5,y=20.5},platform='alpha',ride=true}) end,'put down everything in character_main')
eq(boarded,nil,'nothing moves when the rule fails')
carried[10]=false
launched=nil
local br=bot_space.launch(bot,{position={x=20.5,y=20.5},platform='alpha',ride=true})
eq(checked,record); eq(boarded.b,record); eq(boarded.pl,platform); eq(boarded.pod,silo.rocket.attached_cargo_pod)
eq(launched.station,platform.hub,'the rocket flies to the platform'); assert(br.riding:find('aboard alpha',1,true))
eq(p.stopped,1,'boarding stops the bot in bots.lua, not here')
eq(bot_space.land(bot,{}).landing,'nauvis'); eq(landed,record)
-- Landing: only from our platform stopped at a planet.
fails(function() space.land(p,{}) end,'not on a space platform')
p.surface.platform=platform; platform.force=p.force
platform.space_location={name='nauvis',type='planet'}
p.land_on_planet=function() return true end
eq(space.land(p,{}).landing,'nauvis'); eq(p.stopped,2)
platform.space_location=nil; platform.space_connection={from={name='nauvis'},to={name='vulcanus'}}; platform.distance=0.25
fails(function() space.land(p,{}) end,'not stopped at a planet (at nauvis->vulcanus 25%)')
p.surface.platform=nil
-- Drop: hub items go down in a cargo pod to the planet below a stopped platform.
-- The hub's own stacks move (freshness kept); repeated entries add up.
defines.inventory.cargo_unit=30
prototypes.item['iron-plate'].stack_size=100; prototypes.item.coal.stack_size=50
-- Item stacks as the engine's: transfer_stack into a stack of the same item
-- tops it up to the stack size (checked on 2.0.77) and leaves the rest.
local function stack(name,count,spoil)
  local st={valid_for_read=count>0,name=name,count=count,quality={name='normal'},spoil_percent=spoil or 0,
    prototype={stack_size=name and prototypes.item[name] and prototypes.item[name].stack_size or 100}}
  st.clear=function() st.valid_for_read=false; st.count=0 end
  st.transfer_stack=function(o)
    if st.valid_for_read and st.name==o.name then
      local n=math.min(st.prototype.stack_size-st.count,o.count)
      st.count=st.count+n; o.count=o.count-n
      if o.count==0 then o.clear() end
      return o.count==0
    end
    st.name,st.count,st.quality,st.spoil_percent,st.valid_for_read,st.prototype=o.name,o.count,o.quality,o.spoil_percent,true,o.prototype; o.clear(); return true
  end
  return st
end
local function slots(list,n) local inv={}; for i=1,n do inv[i]=list[i] or stack(nil,0) end; return inv end
local hub_slots=slots({stack('iron-plate',3,0.25),stack('coal',5),stack('iron-plate',4,0.5)},4)
for i=1,#hub_slots do hub_inv[i]=hub_slots[i] end
hub_inv.get_item_count=function(q) local n=0; for i=1,#hub_slots do local st=hub_slots[i]; if st.valid_for_read and st.name==q.name then n=n+st.count end end; return n end
hub_inv.insert=function(st) for i=1,#hub_slots do if not hub_slots[i].valid_for_read then hub_slots[i].transfer_stack(st); return hub_slots[i].count end end; return 0 end
local vulcanus_surface={name='vulcanus',pads={}}
vulcanus_surface.find_entities_filtered=function() return vulcanus_surface.pads end
game={planets={vulcanus={surface=vulcanus_surface}}}
p.force.get_spawn_position=function() return {x=0,y=0} end
local drop_pod,inserted
local refuse=false
-- pod_size: a pod's slots (10 in the game); hatches: pods the hub can make now (nil: any).
local pod_size,hatches=2,nil
platform.hub.create_cargo_pod=function()
  if hatches then if hatches<=0 then return nil end; hatches=hatches-1 end
  local cargo=slots({},pod_size)
  cargo.find_empty_stack=function() for i=1,#cargo do if not cargo[i].valid_for_read then return cargo[i],i end end end
  -- insert tops up a part stack of the item first, as the engine's does.
  cargo.insert=function(def)
    inserted=def
    local size,left=prototypes.item[def.name].stack_size or 100,def.count
    for i=1,#cargo do
      local st=cargo[i]
      if left>0 and st.valid_for_read and st.name==def.name and st.count<size then local n=math.min(size-st.count,left); st.count=st.count+n; left=left-n end
    end
    while left>0 do
      local st=cargo.find_empty_stack()
      if not st then break end
      local n=math.min(size,left)
      st.name,st.count,st.spoil_percent,st.valid_for_read,st.prototype=def.name,n,def.spoil_percent or 0,true,{stack_size=size}
      left=left-n
    end
    return def.count-left
  end
  cargo.is_empty=function() for i=1,#cargo do if cargo[i].valid_for_read then return false end end return true end
  local pod={valid=true,cargo=cargo}
  drop_pod=setmetatable({},{__index=pod,__newindex=function(_,k,v) if k=='cargo_pod_destination' and refuse then error('refused') end pod[k]=v end})
  pod.get_inventory=function(i) eq(i,30); return cargo end
  pod.destroy=function() pod.valid=false end
  return drop_pod
end
platform.space_location={name='vulcanus',type='planet'}
fails(function() space.drop(p,{platform='alpha',items={{item='iron-plate',count=5},{item='iron-plate',count=5}}}) end,'holds 7 iron-plate, not 10')
local d=space.drop(p,{platform='alpha',items={{item='iron-plate',count=3},{item='iron-plate',count=2}}})
eq(d.dropped[1],'iron-plate*5'); eq(#d.dropped,1,'repeated entries add up')
eq(drop_pod.cargo[1].spoil_percent,0.25,'a whole stack moves as is')
eq(inserted.count,2); eq(inserted.spoil_percent,0.5,'part of a stack keeps its freshness')
eq(drop_pod.cargo[1].count,5,'the part joins the stack sent whole, as the engine inserts'); eq(drop_pod.cargo[2].valid_for_read,false)
eq(hub_inv.get_item_count{name='iron-plate'},2,'only what left the hub was sent')
eq(drop_pod.cargo_pod_destination.surface,vulcanus_surface); eq(drop_pod.cargo_pod_destination.position.x,0); eq(d.to,'vulcanus')
-- The drop is followed until it lands (drops.lua): its number, the pod, who is told.
eq(d.drop,7); eq(drop_record.pod,drop_pod); eq(drop_record.platform,'alpha'); eq(drop_record.surface,'vulcanus')
eq(drop_record.sent[1],'iron-plate*5'); eq(drop_record.near.x,0); assert(d.note:find('team block says where',1,true),d.note)
fails(function() space.drop(p,{platform='alpha',items={{item='iron-plate',count=1}},to='nobody'}) end,'unknown agent nobody')
eq(hub_inv.get_item_count{name='iron-plate'},2,'an unknown teammate fails before anything leaves the hub')
-- Two items in one drop, each from its own hub stack.
d=space.drop(p,{platform='alpha',items={{item='coal',count=5},{item='iron-plate',count=2}}})
eq(d.dropped[1],'coal*5'); eq(d.dropped[2],'iron-plate*2'); eq(d.not_sent,nil)
hub_inv.insert(stack('coal',4)); hub_inv.insert(stack('iron-plate',1))
d=space.drop(p,{platform='alpha',items={{item='coal',count=2},{item='iron-plate',count=1}}})
eq(d.not_sent,nil)
hub_inv.insert(stack('coal',3))
vulcanus_surface.pads={{position={x=9,y=9}}}
d=space.drop(p,{platform='alpha',items={{item='coal',count=1}},position={x=4,y=4}})
eq(d.pad.x,9); eq(drop_pod.cargo_pod_destination.position,nil,'a pad takes it')
-- A refused destination puts the items back.
local coal_before=hub_inv.get_item_count{name='coal'}
refuse=true
fails(function() space.drop(p,{platform='alpha',items={{item='coal',count=2}}}) end,'items stay in the hub')
eq(hub_inv.get_item_count{name='coal'},coal_before); eq(drop_pod.valid,false)
-- The hub cannot take them back (filled meanwhile): they stay in the pod, which is kept.
local insert=hub_inv.insert
hub_inv.insert=function() return 0 end
fails(function() space.drop(p,{platform='alpha',items={{item='coal',count=2}}}) end,'the hub took back all but coal*2, which stay in the cargo pod on the hub')
eq(drop_pod.valid,true); eq(drop_pod.cargo[1].count,2,'two hub stacks of 1 share a pod slot')
hub_inv.insert=insert
refuse=false
platform.space_location=nil
fails(function() space.drop(p,{platform='alpha',items={{item='coal',count=1}}}) end,'not stopped at a planet')
-- A list bigger than one pod (Astra, shift09: a Gleba kit took three drops,
-- the first partial one read as complete). Pods of 10 slots; the split keeps
-- the list's order (cargo.lua pods).
platform.space_location={name='vulcanus',type='planet'}
pod_size=10; game.tick=1000
hub_slots={}
for i=1,12 do hub_slots[#hub_slots+1]=stack('iron-plate',100) end
for i=1,10 do hub_slots[#hub_slots+1]=stack('coal',50) end
for i=1,8 do hub_slots[#hub_slots+1]=stack(nil,0) end
for i=1,#hub_slots do hub_inv[i]=hub_slots[i] end
for i=#hub_slots+1,40 do hub_inv[i]=nil end
local kit={{item='iron-plate',count=1200},{item='coal',count=300}}
-- Dry run: the split, nothing sent.
platform.hub.cargo_hatches={{is_output_compatible=false},{is_output_compatible=true},{is_output_compatible=true},{is_output_compatible=true}}
local dry=space.drop(p,{platform='alpha',items=kit,dry_run=true})
eq(dry.dry_run,true); eq(#dry.pods,2); eq(dry.pods[1],'pod 1 (10 slots): iron-plate*1000'); eq(dry.pods[2],'pod 2 (8 slots): iron-plate*200 coal*300')
-- Sol, 22:52: the hub's stacks of the items to drop, their spread.
eq(dry.freshness[1],'spread of coal,iron-plate'); eq(fresh_asked.inv,hub_inv)
eq(dry.pod_slots,'a cargo pod holds 10 slots (no weight limit); the list takes 18 stacks')
eq(dry.hatches,'3 output hatches: up to 3 pods leave at once, each hatch sends its next 2 s after its last')
assert(dry.sends:find('full: true sends all 2 pods',1,true),dry.sends); eq(dry.short,nil)
eq(hub_inv.get_item_count{name='iron-plate'},1200,'a dry run sends nothing')
eq(space.drop(p,{platform='alpha',items={{item='coal',count=600}},dry_run=true}).short[1],'coal: the hub holds 500 of 600')
-- The landing pad's room for what would go (Astra, shift12 13:50: 773 electromagnetic science packs spilled once; 43
-- asteroid chunks had taken 43 slots): its free slots, what takes the others, the new slots the drop needs, the spill.
do
  defines.inventory.cargo_landing_pad_main=31
  prototypes.item['carbonic-asteroid-chunk']={stack_size=1}
  local function padslot(name,count) return {valid_for_read=name~=nil,name=name,count=count or 0,quality={name='normal'}} end
  local pad_slots={padslot('carbonic-asteroid-chunk',1),padslot('carbonic-asteroid-chunk',1),padslot('carbonic-asteroid-chunk',1),padslot('iron-plate',50),
    padslot(),padslot(),padslot(),padslot()}
  local bar
  local pad_inv=setmetatable({supports_bar=function() return true end,get_bar=function() return bar or #pad_slots+1 end},
    {__index=function(_,i) return pad_slots[i] end,__len=function() return #pad_slots end})
  local pad={valid=true,position={x=9,y=9},get_inventory=function(i) eq(i,31); return pad_inv end}
  local pads=vulcanus_surface.pads
  vulcanus_surface.pads={pad}
  -- Pod 1, iron-plate*1000: 50 into the part stack there, 950 need 10 new slots; 4 are free: 400 fit, 550 spill.
  local room=space.drop(p,{platform='alpha',items=kit,dry_run=true})
  eq(room.pad_free,4); eq(room.spill,550)
  eq(room.pad_room,'landing pad (9,9): 4 of 8 slots free (taken: carbonic-asteroid-chunk 3 slots (3), iron-plate 1 slot (50)); '..
    'this drop needs 10 new slots: iron-plate*550 would not fit and land on the ground around the pad')
  -- full: both pods, iron-plate*1200 and coal*300.
  room=space.drop(p,{platform='alpha',items=kit,dry_run=true,full=true})
  eq(room.spill,1050); assert(room.pad_room:find('needs 18 new slots: iron-plate*750 coal*300 would not fit',1,true),room.pad_room)
  -- What fits says so; slots past the red-X limit do not count.
  room=space.drop(p,{platform='alpha',items={{item='iron-plate',count=40}},dry_run=true})
  eq(room.spill,nil); assert(room.pad_room:find('this drop needs 0 new slots: it fits, 4 free after',1,true),room.pad_room)
  bar=6
  room=space.drop(p,{platform='alpha',items={{item='coal',count=150}},dry_run=true})
  eq(room.pad_free,1); eq(room.spill,100); assert(room.pad_room:find('1 of 5 slots free',1,true),room.pad_room)
  vulcanus_surface.pads={}
  eq(space.drop(p,{platform='alpha',items={{item='coal',count=1}},dry_run=true}).pad_room,'no landing pad of ours on vulcanus: the pods land as cargo pod containers')
  vulcanus_surface.pads=pads
end
-- Without full: the first pod goes, and the reply says what stays in the hub.
d=space.drop(p,{platform='alpha',items=kit})
eq(#d.dropped,1); eq(d.dropped[1],'iron-plate*1000'); eq(d.pods,nil)
eq(d.short,'not sent, still in the hub: iron-plate*200 coal*300 (a cargo pod holds 10 slots and the list takes 2 pods; full: true sends them all)')
eq(hub_inv.get_item_count{name='iron-plate'},200)
-- full: every pod, at once while hatches are free.
for i=1,10 do hub_inv.insert(stack('iron-plate',100)) end
_G.drop_records={}
d=space.drop(p,{platform='alpha',items=kit,full=true})
eq(#d.pods,2); eq(d.pods[1].items,'iron-plate*1000'); eq(d.pods[1].slots,10); eq(d.pods[2].items,'iron-plate*200 coal*300'); eq(d.pods[2].slots,8)
eq(d.dropped[1],'iron-plate*1200'); eq(d.dropped[2],'coal*300'); eq(d.short,nil); eq(d.pods_waiting,nil)
eq(#drop_records,2,'each pod is followed down')
-- full with one hatch free: the rest wait for a hatch, a timed action.
for i=1,12 do hub_inv.insert(stack('iron-plate',100)) end
for i=1,6 do hub_inv.insert(stack('coal',50)) end
hatches=1; _G.drop_job=nil
d=space.drop(p,{platform='alpha',items=kit,full=true})
eq(#d.pods,1); assert(d.pods_waiting:find('1 more pod wait',1,true) and d.pods_waiting:find('iron-plate*200 coal*300',1,true),d.pods_waiting)
eq(d.until_tick,1000+120*2+600); eq(drop_job.kind,'drop'); eq(#drop_job.pods,1)
game.tick=1010
eq(space.drop_tick(p,drop_job),nil,'no hatch free yet')
hatches=1; game.tick=1020
eq(space.drop_tick(p,drop_job),'dropped')
local res,why=space.drop_result(drop_job,'dropped')
eq(#res.pods,2); eq(res.pods[2].items,'iron-plate*200 coal*300'); eq(res.dropped[2],'coal*300'); eq(res.not_sent,nil); eq(why,nil)
-- The hub ran short meanwhile: what is there goes; short says what did not.
for i=1,12 do hub_inv.insert(stack('iron-plate',100)) end
for i=1,6 do hub_inv.insert(stack('coal',50)) end
hatches=1; game.tick=2000
d=space.drop(p,{platform='alpha',items=kit,full=true})
for i=1,#hub_slots do if hub_slots[i].valid_for_read and hub_slots[i].name=='coal' then hub_slots[i].clear() end end
hub_inv.insert(stack('coal',20))
hatches=nil; game.tick=2010
eq(space.drop_tick(p,drop_job),'short')
res,why=space.drop_result(drop_job,'short')
eq(res.pods[2].items,'iron-plate*200 coal*20'); eq(why,'the hub held less than asked: coal*280 not sent')
-- The platform leaves: the waiting pods are not sent.
for i=1,12 do hub_inv.insert(stack('iron-plate',100)) end
hatches=1; game.tick=3000
d=space.drop(p,{platform='alpha',items={{item='iron-plate',count=1200}},full=true})
-- (its schedule heads for nauvis, as a platform that left vulcanus for nauvis has: the leg is read the way it is flown)
local kept_schedule=platform.schedule; platform.schedule={records={{station='nauvis'}},current=1}
platform.space_location=nil; platform.space_connection={from={name='vulcanus'},to={name='nauvis'}}; platform.distance=0.1
game.tick=3010
eq(space.drop_tick(p,drop_job),'failed'); eq(drop_job.why,'platform alpha left vulcanus (at vulcanus->nauvis 10%)')
res=space.drop_result(drop_job,'failed'); eq(res.not_sent,'iron-plate*200')
platform.schedule=kept_schedule
-- One full drop at a time: another is refused while its pods wait (nothing leaves the hub).
_G.pending_job={platform=platform,pods={{items={}}}}
platform.space_location={name='vulcanus',type='planet'}; platform.space_connection=nil
local before_iron=hub_inv.get_item_count{name='iron-plate'}
fails(function() space.drop(p,{platform='alpha',items={{item='iron-plate',count=100}},full=true}) end,'your last full drop from alpha still has 1 pod waiting for a hatch')
eq(hub_inv.get_item_count{name='iron-plate'},before_iron)
eq(space.drop(p,{platform='alpha',items={{item='iron-plate',count=100}},full=true,dry_run=true}).dry_run,true,'a dry run is not refused')
_G.pending_job=nil
-- No hatch free at all: without full it fails, with full it waits for one.
platform.space_location={name='vulcanus',type='planet'}; platform.space_connection=nil
hatches=0
fails(function() space.drop(p,{platform='alpha',items={{item='iron-plate',count=100}}}) end,'no free cargo hatch right now')
d=space.drop(p,{platform='alpha',items={{item='iron-plate',count=100}},full=true})
eq(d.drop,nil); eq(#d.pods,0); assert(d.pods_waiting:find('1 more pod wait',1,true),d.pods_waiting)
hatches=nil; pod_size=2

-- Creating a platform goes through the force like the platform GUI.
p.force.create_space_platform=function(args) return {name=args.name,state=0,planet=args.planet} end
local made=space.platform_create(p,{name='beta'})
eq(made.state,'waiting_for_starter_pack'); eq(made.planet,'nauvis')
p.force.recipes['space-platform-starter-pack']={enabled=false}
fails(function() space.platform_create(p,{}) end,'not unlocked yet')
-- Flight on every row: speed in km/s (the game's is km per tick), the leg flown, km left on it, minutes at this
-- speed, the schedule's next stop. At nauvis with the schedule heading for vulcanus: no leg yet.
platform.speed=0; platform.space_location={name='nauvis'}; platform.space_connection=nil
platform.schedule={current=1,records={{station='vulcanus'},{station='nauvis'}}}
local row=space.platforms(p,{}).platforms[1]
eq(row.speed_kms,0); eq(row.next_stop,'vulcanus'); eq(row.leg,nil); eq(row.eta_min,nil)
-- On the way: a connection is measured from its `from` end (nauvis->vulcanus, a quarter of the way).
platform.space_location=nil; platform.distance=0.25; platform.speed=1.5; platform.last_visited_space_location={name='nauvis'}
platform.space_connection={name='nauvis-vulcanus',from={name='nauvis'},to={name='vulcanus'},length=15000}
row=space.platforms(p,{}).platforms[1]
eq(row.speed_kms,90); eq(row.leg,'nauvis->vulcanus'); eq(row.heading_to,'vulcanus'); eq(row.leg_km,15000); eq(row.leg_left_km,11250)
eq(row.eta_min,2.1); eq(row.next_stop,'vulcanus'); eq(row.at,'nauvis->vulcanus 25%')
-- Flown the other way (the schedule's stop is the connection's from end): the km left are the quarter behind.
platform.schedule.current=2; platform.last_visited_space_location={name='vulcanus'}
row=space.platforms(p,{}).platforms[1]
eq(row.leg,'vulcanus->nauvis'); eq(row.heading_to,'nauvis'); eq(row.leg_left_km,3750); eq(row.eta_min,0.7); eq(row.next_stop,'nauvis')
-- A stop past this leg (a longer trip): the end it did not come from.
platform.schedule={current=1,records={{station='aquilo'}}}; platform.last_visited_space_location={name='vulcanus'}
row=space.platforms(p,{}).platforms[1]
eq(row.heading_to,'nauvis'); eq(row.leg_left_km,3750); eq(row.next_stop,'aquilo')
-- The unit, from shift08's recorded reads on world n: Sunward flew nauvis->vulcanus back from 80% to 55% in 6631 ticks
-- at speed 0.556 (game units). km per tick puts it 8313 km from nauvis after those ticks; the read said 55% (8250 km).
platform.schedule={current=1,records={{station='nauvis'}}}; platform.speed=0.556; platform.distance=0.80
row=space.platforms(p,{}).platforms[1]
eq(row.speed_kms,33.4); eq(row.leg_left_km,12000); eq(row.eta_min,6)
assert(math.abs((row.leg_left_km-0.556*6631)-0.55*15000)<0.02*15000,'km per tick matches the recorded flight')
-- No speed: no minutes.
platform.speed=0
eq(space.platforms(p,{}).platforms[1].eta_min,nil)
-- Waiting at its current stop: the next stop is the one after it.
platform.space_connection=nil; platform.space_location={name='vulcanus'}
platform.schedule={current=1,records={{station='vulcanus'},{station='nauvis'}}}
row=space.platforms(p,{}).platforms[1]
eq(row.next_stop,'nauvis'); eq(row.leg,nil); eq(row.at,'vulcanus')
eq(space.flight(platform).next_stop,'nauvis')
-- Each stop with its wait conditions, where it waits (with how far each is) or flies to, and the next one
-- (operator 10:53, Gemini). The arrival tick comes from the watcher (once a second from the harness tick).
do
  local saved={sched=platform.schedule,state=platform.state,loc=platform.space_location,conn=platform.space_connection,hub=platform.hub}
  game.tick=1000
  game.forces={player={platforms={platform}}}
  platform.state=6; platform.space_location={name='vulcanus'}; platform.space_connection=nil
  platform.schedule={current=1,records={
    {station='vulcanus',wait_conditions={{type='time',ticks=1800},{type='item_count',compare_type='and',
      condition={first_signal={type='item',name='calcite'},comparator='≥',constant=500}}}},
    {station='nauvis',wait_conditions={{type='all_requests_satisfied'},{type='inactivity',ticks=600,compare_type='or'}}}}}
  local hub_counts={calcite=120,['iron-plate']=40}
  local reqs={sections_count=1,get_section=function() return {active=true,filters={
    {value={name='iron-plate',quality='normal'},min=100},{value={name='calcite',quality='normal'},min=50},{value={name='coal',quality='normal'},min=0}}} end}
  platform.hub={valid=true,position={x=0,y=0},get_logistic_sections=function() return reqs end,
    get_inventory=function() return {get_item_count=function(it) return hub_counts[type(it)=='table' and it.name or it] or 0 end,get_contents=function() return {} end} end}
  -- First look after a deploy: stopped before the harness watched.
  space.watch_stops(1000)
  game.tick=1600
  local st=space.stops(platform)
  eq(st[1],'1 vulcanus (waiting here): time 30s: waited at least 10s (stopped before the harness looked) and item_count calcite >= 500: the hub holds 120, 380 to go')
  eq(st[2],'2 nauvis (next): all_requests_satisfied or inactivity 10s')
  -- Flying on, then arriving: the countdown from the arrival.
  platform.state=2; platform.space_location=nil; platform.space_connection={from={name='vulcanus'},to={name='nauvis'},length=1000}
  platform.schedule.current=2
  space.watch_stops(1700)
  eq(space.stops(platform)[2],'2 nauvis (flying to it): all_requests_satisfied or inactivity 10s')
  platform.state=6; platform.space_location={name='nauvis'}; platform.space_connection=nil
  space.watch_stops(2000)
  game.tick=2300
  platform.get_schedule=function() return {tick_of_last_activity=2200} end
  st=space.stops(platform)
  eq(st[2],'2 nauvis (waiting here): all_requests_satisfied: 1 of 2 requests unmet (iron-plate 40/100) or inactivity 10s: 2s without activity, 8s left')
  eq(st[1],'1 vulcanus (next): time 30s and item_count calcite >= 500')
  platform.schedule.records[2].wait_conditions={{type='time',ticks=1800}}
  eq(space.stops(platform)[2],'2 nauvis (waiting here): time 30s: 25s left')
  -- The maximum time reads as such.
  platform.schedule.records[2].wait_conditions={{type='time',ticks=2147483647}}
  eq(space.stops(platform)[2],'2 nauvis (waiting here): time the maximum (about 414 days)')
  -- The platforms row carries them.
  eq(space.platforms(p,{}).platforms[1].stops[2],'2 nauvis (waiting here): time the maximum (about 414 days)')
  platform.schedule,platform.state,platform.space_location,platform.space_connection,platform.hub=saved.sched,saved.state,saved.loc,saved.conn,saved.hub
  platform.get_schedule=nil
end
-- A hub's Request missing construction materials (Astra, shift12 19:16): read in every hub reply, switched by
-- construction_requests through keep.lua (faked here: the setting on the hub).
do
  local hub=platform.hub
  local fake={construction=function(e) return e.construction_on and {} or nil end,
    set_construction=function(e,on) if not e.stuck then e.construction_on=on end; return e.construction_on==true end}
  local space3=dofile('mod/agent-harness_0.1.0/space.lua'){state=function() return space_state end,position=function(v) return v end,
    integer=function(v,d) return v==nil and d or v end,remote_entity=function() return silo end,real=function(q) return q end,
    keep=function() return fake end}
  eq(space3.requests(p,{platform='alpha'}).construction_requests,'off')
  eq(space3.requests(p,{platform='alpha',construction_requests=true}).construction_requests,
    'on (switched on now: the game fills its section from the platform\'s ghosts within a second)')
  eq(space3.requests(p,{platform='alpha'}).construction_requests,'on')
  eq(space3.requests(p,{platform='alpha',construction_requests=false}).construction_requests,'off (switched off now)')
  fails(function() space3.requests(p,{platform='alpha',construction_requests='yes'}) end,'construction_requests must be true or false')
  fails(function() space3.requests(p,{construction_requests=true}) end,'construction_requests is a platform hub setting')
  hub.stuck=true
  fails(function() space3.requests(p,{platform='alpha',construction_requests=true}) end,'the game kept Request missing construction materials off')
  hub.stuck,hub.construction_on=nil,nil
  eq(space3.requests(p,{}).construction_requests,nil,'not a hub')
  -- A manual section requesting an item of the game's section too: the hub requests the sum.
  fake.construction=function() return {filters={{value={name='coal',quality='normal'},min=3},{value={name='iron-plate',quality='uncommon'},min=19}}} end
  local rq=space3.requests(p,{platform='alpha',set={{item='coal',min=3,from='nauvis'}}})
  eq(rq.construction_overlap,'manual sections request these too, and the hub requests the sum: coal 3+3')
  hub_sections.get_section(2).active=false
  eq(space3.requests(p,{platform='alpha'}).construction_overlap,nil,'a section that is off requests nothing')
  hub_sections.get_section(2).active=true
end
-- Hub slots asteroid chunks take, one a slot (Astra, shift14 22:50: a chunk backlog hid in raw stock).
do
  local function chunk(name) return {valid_for_read=true,name=name,count=1} end
  local empty={valid_for_read=false}
  local inv={chunk('metallic-asteroid-chunk'),empty,chunk('carbonic-asteroid-chunk'),chunk('metallic-asteroid-chunk'),
    {valid_for_read=true,name='iron-plate',count=50}}
  inv.get_contents=function() return {{name='iron-plate',count=50}} end
  local hub={get_inventory=function(i) assert(i==defines.inventory.hub_main); return inv end}
  eq(space.hub_chunks(hub),'asteroid chunks take 3 of 5 slots (metallic 2, carbonic 1)')
  local kept=platform.hub.get_inventory
  platform.hub.get_inventory=function(i) if i==defines.inventory.hub_main then return inv end end
  eq(space.platforms(p,{}).platforms[1].hub_chunks,'asteroid chunks take 3 of 5 slots (metallic 2, carbonic 1)','every row')
  inv[1],inv[3],inv[4]=empty,empty,empty
  eq(space.hub_chunks(hub),nil,'no chunk in the hub')
  platform.hub.get_inventory=kept
  -- With platform set, per ammo type over the last leg and the rockets on their way up (freight.lua's reads).
  local real=dofile('mod/agent-harness_0.1.0/freight.lua'){state=function() return space_state end}
  local fake=setmetatable({ammo=function(pl) assert(pl==platform); return {'firearm-magazine: made 42/min, used 38/min over the last 10 min; hub 544, turrets 191'} end,
    incoming=function() return {rockets=1,cargo='firearm-magazine*20',lines={'a rocket from nauvis launched 3s ago: firearm-magazine*20 (rising over nauvis)'}} end},{__index=real})
  local space4=dofile('mod/agent-harness_0.1.0/space.lua'){state=function() return space_state end,position=function(v) return v end,
    integer=function(v,d) return v==nil and d or v end,remote_entity=function() return silo end,real=function(q) return q end,freight=fake}
  local row=space4.platforms(p,{platform='alpha'}).platforms[1]
  eq(row.ammo_rates[1],'firearm-magazine: made 42/min, used 38/min over the last 10 min; hub 544, turrets 191')
  eq(row.incoming_cargo,'1 rocket on the way: firearm-magazine*20'); eq(row.incoming[1],'a rocket from nauvis launched 3s ago: firearm-magazine*20 (rising over nauvis)')
  row=space4.platforms(p,{}).platforms[1]
  eq(row.ammo_rates,nil,'details only for one named platform'); eq(row.incoming_cargo,nil)
end
-- A set without section edits the item's slot in the manual section that holds it (Grok, d15 06:20: a hub's set of
-- underground-belt 4 added a section and the hub requested 2+4): a grouped section too, said; a second holder named.
do
  prototypes.item['underground-belt']={}
  local grouped=section(true,'ship parts'); grouped.index=1
  grouped.set_slot(1,{value={type='item',name='underground-belt',quality='normal',comparator='='},min=2})
  local list={grouped}
  local hub2=sections(list)
  local pl2={valid=true,name='beta2',index=2,state=7,space_location={name='nauvis'},surface={name='platform-2'},
    hub={valid=true,type='space-platform-hub',position={x=0,y=0},get_logistic_sections=function() return hub2 end,get_inventory=function() return hub_inv end}}
  table.insert(p.force.platforms,pl2)
  local r2=space.requests(p,{platform='beta2',set={{item='underground-belt',min=4}}})
  eq(hub2.sections_count,1,'no section added'); eq(grouped.get_slot(1).min,4)
  eq(r2.changed_section,1); eq(r2.stored[1],'underground-belt 4..inf (was underground-belt 2..inf)')
  eq(r2.sections_note[1],'underground-belt: section 1 is the logistic group "ship parts": every entity in the group gets the change, as in the GUI')
  -- an item not requested anywhere goes to the default section (added: the only manual one is grouped)
  r2=space.requests(p,{platform='beta2',set={{item='coal',min=1}}})
  eq(hub2.sections_count,2); eq(r2.changed_section,2)
  -- held in two sections: the first is edited, the other named
  list[2].set_slot(2,{value={type='item',name='underground-belt',quality='normal',comparator='='},min=3})
  r2=space.requests(p,{platform='beta2',set={{item='underground-belt',min=6}}})
  eq(grouped.get_slot(1).min,6); eq(list[2].get_slot(2).min,3)
  eq(r2.sections_note[1],'underground-belt is requested in section 2 too (the hub requests the sum; requests {section, clear} removes one)')
  -- clear without section finds the holder
  r2=space.requests(p,{platform='beta2',clear={'coal'}})
  eq(r2.stored[1]:sub(1,13),'coal: cleared')
  table.remove(p.force.platforms)
end
-- Personal max under what you hold (Opus, d15 09:20): refused without force; remove is clear.
do
  local main={get_item_count=function(q) return (type(q)=='table' and q.name or q)=='pumpjack' and 6 or 0 end}
  p.get_main_inventory=function() return main end
  prototypes.item.pumpjack={}
  space.requests(p,{set={{item='pumpjack',min=0,max=10}}})
  fails(function() space.requests(p,{set={{item='pumpjack',min=0,max=0}}}) end,'pumpjack max 0: you hold 6; the game moves what you hold over a personal max to your trash')
  local r=space.requests(p,{set={{item='pumpjack',min=0,max=0}},force=true}); eq(r.changed_section,1)
  r=space.requests(p,{remove={'pumpjack'}}); eq(r.stored[1]:sub(1,17),'pumpjack: cleared')
  p.get_main_inventory=nil
end
print('space: ok')
