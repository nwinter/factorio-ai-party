-- d19 batch41. Run from the harness root: lua tests/d19_batch41.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end

-- A2 (Sol seq 868-869, Bastion: platform_rearm {item: firearm-magazine} put 10-magazine requests on 5 railgun and 6 rocket
-- turrets; configure {ammo: false} refused the built turrets and Sol rebuilt all 11). Gun, rocket and railgun turrets,
-- with old requests: an item a named turret does not take is refused with each kind and its items; with no positions the
-- others are left out and named; an old request a turret cannot use is shown, and clear removes it as a deconstruction
-- planner and a cancel do (order_deconstruction on the proxy, read on 2.0.77).
do
  game={tick=1000}
  defines={inventory={turret_ammo=1,hub_main=2,artillery_turret_ammo=3}}
  local ammo={['firearm-magazine']={'bullet','a'},['piercing-rounds-magazine']={'bullet','b'},rocket={'rocket','c'},['explosive-rocket']={'rocket','d'},['railgun-ammo']={'railgun','e'}}
  prototypes={item={},get_item_filtered=function() local t={} for n,_ in pairs(ammo) do t[n]=prototypes.item[n] end return t end}
  for n,c in pairs(ammo) do prototypes.item[n]={name=n,type='ammo',stack_size=100,order=c[2],ammo_category={name=c[1]}} end
  local function proto(name,cat) return {name=name,type='ammo-turret',attack_parameters={ammo_categories={cat}},automated_ammo_count=10,get_inventory_size=function() return 1 end} end
  local P={['gun-turret']=proto('gun-turret','bullet'),['rocket-turret']=proto('rocket-turret','rocket'),['railgun-turret']=proto('railgun-turret','railgun')}
  local ordered={}
  local function request(e,item,n)
    local px={valid=true,insert_plan={{id={name=item},items={in_inventory={{inventory=1,stack=0,count=n}}}}},removal_plan={}}
    px.order_deconstruction=function(f) ordered[#ordered+1]=f; px.valid=false; e.item_request_proxy=nil; return true end
    e.item_request_proxy=px
  end
  local function turret(name,x,y,held)
    local inv={items=held or {}}
    inv.get_item_count=function(n) return inv.items[n] or 0 end
    inv.get_contents=function() local out={} for k,v in pairs(inv.items) do out[#out+1]={name=k,count=v} end return out end
    return {valid=true,name=name,type='ammo-turret',position={x=x,y=y},prototype=P[name],get_inventory=function() return inv end}
  end
  local list={turret('gun-turret',-4.5,-20.5,{['firearm-magazine']=2}),turret('rocket-turret',0.5,-20.5),turret('railgun-turret',4.5,-20.5),turret('railgun-turret',8.5,-20.5)}
  -- Bastion's old requests: firearm-magazine*10 on a rocket turret and a railgun turret
  request(list[2],'firearm-magazine',10); request(list[3],'firearm-magazine',10)
  local T=dofile('mod/agent-harness_0.1.0/turretammo.lua'){state=function() return {} end}
  local hub={valid=true,get_inventory=function() return {get_item_count=function() return 500 end} end}
  local surface={platform={name='Bastion',valid=true,hub=hub},find_entities_filtered=function() return list end}
  local asked={}
  local R=dofile('mod/agent-harness_0.1.0/platrearm.lua'){state=function() return {} end,on_platform=function() return {surface=surface} end,
    remote_entity=function(_,a) for _,e in ipairs(list) do if e.position.x==a.position.x then return e end end error('nothing there',0) end,
    deliver_one=function(_,e,items) for k,n in pairs(items) do asked[#asked+1]=e.name..' '..k..' '..n end return {requested=true} end,
    takes=function(pr) return T.takes(pr) end,unusable=function(e) return T.unusable(e) end}
  local p={force={name='player'}}
  -- named turrets that do not take it: refused, each kind with what it takes
  fails(function() R.handler(p,{platform='Bastion',positions={{x=-4.5,y=-20.5},{x=4.5,y=-20.5}},item='firearm-magazine',ammo_below=5,target_count=10}) end,
    'item firearm-magazine: not taken by railgun-turret (1) takes railgun-ammo')
  eq(#asked,0)
  -- every turret aboard: the gun turret alone, the rest left out and named
  local r=R.handler(p,{platform='Bastion',item='firearm-magazine',ammo_below=5,target_count=10})
  eq(table.concat(asked,'; '),'gun-turret firearm-magazine 8')
  eq(r.turrets,1)
  eq(r.left_out,'left out, not taking firearm-magazine: rocket-turret (1) takes rocket, explosive-rocket; railgun-turret (2) takes railgun-ammo')
  -- nothing aboard takes it: refused
  asked={}
  fails(function() R.handler(p,{platform='Bastion',positions={{x=4.5,y=-20.5}},item='rocket',ammo_below=5,target_count=10}) end,'not taken by railgun-turret (1) takes railgun-ammo')
  -- what each holds (no item): the old requests shown on their rows
  list[1].item_request_proxy=nil
  r=R.handler(p,{platform='Bastion',ammo_below=1,target_count=10})
  eq(r.rows[2].unusable_request,'firearm-magazine*10'); eq(r.rows[3].unusable_request,'firearm-magazine*10'); eq(r.rows[4].unusable_request,nil)
  -- the clear: every request on it, as the planner does
  local c=T.clear(list[3],p.force)
  eq(c.into,'firearm-magazine*10'); eq(c.out,nil); eq(list[3].item_request_proxy,nil); eq(ordered[1],p.force)
  eq(T.clear(list[3],p.force),nil,'none left')
  eq(T.unusable(list[2]),'firearm-magazine*10')
  -- a request it takes is not unusable
  request(list[4],'railgun-ammo',5); eq(T.unusable(list[4]),nil)
  game,defines,prototypes=nil,nil,nil
end
print('d19_batch41 A2 platform_rearm ammunition by turret kind, requests cleared: ok')

-- B1 (Sol seq 861: another agent switched off Swiftlet's required section while Sol's queue waited): each edit of a
-- request section and of a stop's departure conditions keeps the editor, the tick, old and new; the reads show the last
-- edit; the agent whose values an edit changes is told once when someone else edits.
do
  game={tick=1000}
  defines={space_platform_state={paused=7,waiting_at_station=4,on_the_path=3,no_schedule=1},rocket_silo_status={},inventory={hub_main=1,hub_trash=2},cargo_destination={},
    wire_connector_id={circuit_red=1,circuit_green=2}}
  prototypes={item={['firearm-magazine']={},['iron-plate']={}},space_location={nauvis={},fulgora={},gleba={}},quality={normal={}},fluid={['thruster-fuel']={}}}
  local slots={}
  local sec={index=1,is_manual=true,group='',active=true,filters_count=0}
  local function recount() local n=0; for i in pairs(slots) do n=math.max(n,i) end; sec.filters_count=n end
  sec.get_slot=function(i) return slots[i] or {} end
  sec.set_slot=function(i,f) local c={} for k,v in pairs(f) do c[k]=v end; c.import_from=c.import_from or 'nauvis'; slots[i]=c; recount() end
  sec.clear_slot=function(i) slots[i]=nil; recount() end
  setmetatable(sec,{__index=function(_,k) if k=='filters' then local out={}; for i=1,sec.filters_count do out[i]=slots[i] or {} end; return out end end,
    __newindex=function(t,k,v) if k=='filters' then slots={}; for i,f in ipairs(v) do slots[i]=f end; recount() else rawset(t,k,v) end end})
  local secs=setmetatable({get_section=function(i) return i==1 and sec or nil end,add_section=function() return sec end},{__index=function(_,k) if k=='sections_count' then return 1 end end})
  local main={get_item_count=function() return 0 end,get_contents=function() return {} end}
  local pl={valid=true,name='Swiftlet',index=1,state=4,space_location={name='nauvis'},force='player',paused=false,
    schedule={current=1,records={{station='nauvis'},{station='fulgora'}}},
    hub={valid=true,unit_number=78,type='space-platform-hub',position={x=0,y=0},get_logistic_sections=function() return secs end,get_inventory=function() return main end,
      get_item_count=function() return 0 end,get_circuit_network=function() return nil end}}
  local sch=setmetatable({},{__index=function(_,k) if k=='current' then return pl.schedule and pl.schedule.current end end})
  sch.get_record_count=function() return #pl.schedule.records end
  sch.go_to_station=function(i) pl.schedule.current=i end
  pl.get_schedule=function() return sch end
  local force={platforms={pl}}
  local sol,astra={index=11,name='sol',force=force},{index=12,name='astra',force=force}
  local st,told={},{}
  local E=dofile('mod/agent-harness_0.1.0/editlog.lua'){state=function() return st end,deliver=function(i,t) told[#told+1]={i=i,t=t} end,
    index_of=function(n) return ({sol=11,astra=12})[n] end}
  local space=dofile('mod/agent-harness_0.1.0/space.lua'){state=function() return st end,editlog=E,
    integer=function(v,d,lo,hi) v=v==nil and d or v; return v end,
    keep=function() return {set_construction=function(_,on) return on end,construction=function() return nil end} end,
    circuit_condition=function(c) return c end,
    freight={where=function() return {stopped=true,at='nauvis'} end,pads=function() return {},{} end,leg=function() return nil end}}
  space.requests(sol,{platform='Swiftlet',set={{item='iron-plate',min=600}}})
  eq(#told,0,'a first edit tells nobody')
  game.tick=4600
  local r=space.requests(astra,{platform='Swiftlet',section=1,active=false})
  eq(r.sections[1].last_edit,'last edit by astra 0s ago (tick 4600): on: iron-plate 600..inf from nauvis -> off: iron-plate 600..inf from nauvis')
  eq(#told,1); eq(told[1].i,11); eq(r.told_of_edit[1],'sol')
  eq(told[1].t.text,'changed what you set last: Swiftlet hub request section 1: on: iron-plate 600..inf from nauvis -> off: iron-plate 600..inf from nauvis')
  -- astra edits her own change: nobody told
  space.requests(astra,{platform='Swiftlet',section=1,active=true})
  eq(#told,1)
  -- a dry run records nothing
  space.requests(sol,{platform='Swiftlet',set={{item='iron-plate',min=10}},dry_run=true})
  eq(#told,1)
  -- the departure gate: sol sets the stops, astra edits stop 1's waits; sol is told and the gate read shows it
  space.platform_schedule(sol,{platform='Swiftlet',stops={{station='nauvis',wait={{type='time',ticks=600}}},{station='fulgora'}}})
  game.tick=8200
  r=space.platform_schedule(astra,{platform='Swiftlet',stops={{station='nauvis',wait={{type='time',ticks=1200}}},{station='fulgora'}}})
  eq(r.told_of_edit[1],'sol')
  eq(told[2].t.text,'changed what you set last: Swiftlet stop 1: nauvis: time 10s -> nauvis: time 20s')
  local g=space.gate(sol,{platform='Swiftlet'})
  eq(g.edits[1],'Swiftlet stop 1: last edit by astra 0s ago (tick 8200): nauvis: time 10s -> nauvis: time 20s')
  game,defines,prototypes=nil,nil,nil
end
print('d19_batch41 B1 request section and departure gate edits: who, when, old and new; the earlier editor told: ok')

-- B2 (Sol seq 865: structured evidence; reminder 97 folded runs 3-9; a 200-character ack hid outcomes): evidence on a
-- reminder's ack is kept and shown; a 700-character result is kept whole; folded runs say how many and when.
do
  package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
  game={tick=0}
  local st,boxes={}, {}
  local agents={{name='sol',index=2},{name='astra',index=1}}
  local R=dofile('mod/agent-harness_0.1.0/reminders.lua'){state=function() return st end,
    resolve=function(w) for _,a in ipairs(agents) do if a.name==w then return w end end error('no teammate '..w,0) end,
    agents=function() return agents end,who=function(p) return p.name end,
    deliver=function(index,t) boxes[index]=boxes[index] or {}; table.insert(boxes[index],t) end}
  local sol,astra={name='sol',index=2},{name='astra',index=1}
  local function run(ticks) for _=1,ticks do game.tick=game.tick+1; R.tick() end end
  R.handlers.reminder_add(sol,{name='freight review',message='check Swiftlet PU',every_ticks=3600,recipients='sol,astra'})
  run(3600*3)
  local r=R.handlers.reminders(sol,{}).reminders[1]
  has(r.states,'astra overdue (2 runs missed (the first at tick 7200, 1m00s ago; the last at tick 10800, 0s ago), the owner told)')
  local long=string.rep('Swiftlet delivered 600 PU at Aquilo; ',19)
  assert(#long>700)
  local a=R.handlers.reminder_ack(astra,{id=1,result=long,evidence={metric='PU at Aquilo 600',tick=10000,decision='keep section 5 on',result='Spindle launched',owner='sol',next_check=14400}})
  eq(a.missed_runs,'2 runs missed (the first at tick 7200, 1m00s ago; the last at tick 10800, 0s ago)')
  eq(a.reminder.last_result,(long:gsub('%s+$','')),'kept whole')
  eq(a.reminder.evidence[1],'by astra 0m ago: metric PU at Aquilo 600 (tick 10000); decision keep section 5 on; result Spindle launched; owner sol; next check at tick 14400 (in 1m)')
  has(a.reminder.line,'evidence by astra 0m ago: metric PU at Aquilo 600')
  fails(function() R.handlers.reminder_ack(astra,{id=1,result=string.rep('x',1001)}) end,'result is at most 1000 characters (1001)')
  fails(function() R.handlers.reminder_ack(astra,{id=1,evidence={colour='red'}}) end,'evidence: unknown field colour')
  fails(function() R.handlers.reminder_ack(astra,{id=1,evidence={tick=99999}}) end,'evidence.tick is a game tick up to now')
  game=nil
end
print('d19_batch41 B2 reminder evidence, whole results, folded runs with ticks: ok')

-- D2 (operator d18 19:02: construction_robots sources took 24 ms on network 243): the ghosts read 4 squares of 128 a
-- call (fewer once 60 are read); per group the chest the game would take the item from (select_pickup_point), not every chest; the worm checks
-- share one budget of 64 map chunks a call, and a line past it says it was not read.
do
  defines={inventory={robot_cargo=9,chest=1}}
  local force,surf={}, {name='nauvis'}
  local protos=0
  local function proto(item) return setmetatable({},{__index=function(_,k) if k=='items_to_place_this' then protos=protos+1; return {{name=item,count=1}} end end}) end
  local ghosts={}
  for i=1,4 do ghosts[#ghosts+1]={valid=true,type='entity-ghost',ghost_name='stone-wall',ghost_prototype=proto('stone-wall'),position={x=10+i,y=10}} end
  for i=1,2 do ghosts[#ghosts+1]={valid=true,type='entity-ghost',ghost_name='gun-turret',ghost_prototype=proto('gun-turret'),position={x=200+i,y=10}} end
  local function chest(x,items) return {valid=true,name='storage-chest',position={x=x,y=0},get_item_count=function(i) return items[i] or 0 end} end
  local c20,c30=chest(20,{['stone-wall']=50}),chest(30,{['gun-turret']=5})
  local picks={}
  local net={valid=true,network_id=243,cells={{owner={valid=true,position={x=100,y=0}},construction_radius=200}},find_cell_closest_to=function() return true end,construction_robots={},
    select_pickup_point=function(a) picks[#picks+1]=a.name; local o=({['stone-wall']=c20,['gun-turret']=c30})[a.name]; return o and {owner=o} end,
    get_item_count=function(i) return ({['stone-wall']=57,['gun-turret']=5})[i] or 0 end}
  surf.find_entities_filtered=function() return ghosts end
  -- the map's chunk cache: the first line's chunks need 40 reads, the second's 40 more (over the budget of 64)
  local scanned=0
  local forty={} for k=1,40 do forty[k]=k end
  local av={chunks_near=function(pts) return {{1,1,pts[2].x>100 and 'far' or 'near'}} end,
    missing=function(_,path) if path[1][3]=='near' and scanned>0 then return {} end return forty end,
    structures=function(_,_,path,budget) scanned=scanned+1; assert(budget<=64,budget); return {list={}} end,
    reach=function() return 0 end,seg_dist=function() return 99 end}
  local RB=dofile('mod/agent-harness_0.1.0/robots.lua'){position=function(v) return v end,avoid=function() return av end}
  local lines=RB.sources({surface=surf,force=force},net,5)
  eq(protos,2,'one item read a ghost name'); eq(#picks,2,'one pickup choice a group')
  -- the 400x400 construction area is 16 squares of 128, 4 a call: the walls lie in square 6, the turrets in square 7
  eq(lines[1],'ghosts read in squares 5-8 of the 16 squares (128 tiles a side) the construction area covers; sources_from: 9 reads on')
  eq(lines[2],'4 ghosts for stone-wall near (12.5,10): robots would take it from storage-chest (20,0) (holds 50; the network 57), 13 tiles: the straight line passes within reach of no worm or spawner the map shows')
  eq(lines[3],'2 ghosts for gun-turret near (201.5,10): robots would take it from storage-chest (30,0) (holds 5; the network 5), 172 tiles: the line was not read in this call (64 map chunks a call are read for these lines; the next call reads on)')
  eq(RB.sources({surface=surf,force=force},net,13)[1],'no ghost or item request waits there (ghosts read in squares 13-16 of the 16 squares (128 tiles a side) the construction area covers; the last of them)')
  fails(function() RB.sources({surface=surf,force=force},net,17) end,'sources_from: 1..16')
  -- a square that brings 60 ghosts ends the call there
  for i=1,120 do ghosts[#ghosts+1]={valid=true,type='entity-ghost',ghost_name='stone-wall',ghost_prototype=proto('stone-wall'),position={x=-50,y=-150+i}} end
  eq(RB.sources({surface=surf,force=force},net)[1],'ghosts read in square 1 of the 16 squares (128 tiles a side) the construction area covers; sources_from: 2 reads on')
  defines=nil
end
print('d19_batch41 D2 construction_robots sources bounded: ok')
