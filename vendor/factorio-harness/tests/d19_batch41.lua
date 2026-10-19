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
