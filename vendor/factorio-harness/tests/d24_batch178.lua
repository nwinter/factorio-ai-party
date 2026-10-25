-- Run from repository root: lua tests/d24_batch178.lua
-- d24 batch178: QU1 (#2063) a queued wait_ticks's own completion; QU2 (#2062) power by_cause on a platform;
-- QU3 (#2052) request sections by group name and across a construction_requests switch.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
local function has(s,text) assert(tostring(s):find(text,1,true),tostring(s)) end
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path

-- QU1 (Sol #2063: remoteplan224 job3557 waited 36000 ticks; its completion said wait_until/told at tick 51670140; on the
-- copy job-2 wait_ticks read job-1 move_to's "arrived"): the scheduler gives a wait_ticks step its own completion, and
-- hands the step to completion and outcome, which give nothing written before the step began (as runtime.lua's do).
do
  game={tick=0}
  local state,active,last,mining={},{},{},{}
  local players={[1]={index=1}}
  local factory=dofile('mod/agent-harness_0.1.0/scheduler.lua')
  local handlers={
    move_to=function(p,a) active[p.index]=game.tick+(a.ticks or 3); return {accepted=true} end,
    -- a timed action that runs 2 ticks and leaves no completion of its own (as a refusal or an instant finish)
    mine=function(p) mining[p.index]=game.tick+2; return {accepted=true} end,
  }
  local scheduler=factory{
    state=function() return state end,
    player=function(i) return players[i] end,
    handlers=handlers,
    busy=function(p,action) return action=='move_to' and active[p.index]~=nil or action=='mine' and mining[p.index]~=nil end,
    stop=function(p) active[p.index]=nil end,stop_index=function(i) active[i]=nil end,
    condition=function() return false end,validate_condition=function() end,
    completion=function(p,action,step)
      local row=last[p.index]
      if row and step and step.started_tick and (row.tick or 0)<step.started_tick then return nil end
      return row
    end,
    outcome=function(p,action,step)
      local row=last[p.index]
      if row and step and step.started_tick and (row.tick or 0)<step.started_tick then return nil end
      return row and row.outcome
    end,
  }
  local p=players[1]
  local function tick()
    game.tick=game.tick+1
    for i,expiry in pairs(active) do if game.tick>=expiry then active[i]=nil; last[i]={kind='move_to',outcome='arrived',tick=game.tick} end end
    for i,expiry in pairs(mining) do if game.tick>=expiry then mining[i]=nil end end
    scheduler.tick()
  end
  scheduler.handlers.queue_submit(p,{steps={{action='move_to',args={ticks=3}},{action='wait_ticks',args={ticks=10}},{action='mine'}}})
  for _=1,30 do tick() end
  local h=scheduler.handlers.queue_status(p,{history='all'}).history
  eq(#h,3)
  eq(h[1].result.completion.kind,'move_to'); eq(h[1].result.completion.outcome,'arrived')
  local w=h[2].result.completion
  eq(w.kind,'wait_ticks'); eq(w.outcome,'completed'); eq(w.ticks,10); eq(w.start_tick,h[2].started_tick); eq(w.end_tick,h[2].started_tick+10)
  eq(w.waited,10); eq(w.tick,h[2].finished_tick)
  eq(h[3].result.completion,nil,'mine left no completion of its own: not the move_to before it')
  eq(h[3].result.outcome,'completed')
  -- runtime.lua's hooks take the step and give nothing older than it
  local src=io.open('mod/agent-harness_0.1.0/runtime.lua'):read('*a')
  eq(select(2,src:gsub('if row and step and step.started_tick and %(row.tick or 0%)<step.started_tick then return nil end','')),2)
  has(src,'completion=function(p,action,step)'); has(src,'outcome=function(p,action,step)')
  print('d24_batch178 QU1 wait_ticks completion: ok')
end

-- QU2 (Sol #2062: power {platform: Asterion, by_cause: true} said "no electric network of ours with a draw on
-- platform-16"; the plain read gave network 20579): a platform's own network from networks.platform_grid, its figures
-- the surface's statistics, its capacity, the platform named; and platform_grid itself.
do
  game={tick=43217816}
  defines={flow_precision_index={five_seconds=0},entity_status={working=1,low_power=14,no_power=2}}
  prototypes={surface_property={['solar-power']={default_value=100}},quality={normal={level=0}}}
  local stats={input_counts={['assembling-machine-1']=2,['laser-turret']=1},output_counts={['solar-panel']=3,['fusion-generator']=1},
    get_flow_count=function(a) return ({['assembling-machine-1']=3000,['solar-panel']=3000,['laser-turret']=500,['fusion-generator']=500})[a.name] end}
  local function ent(t,id,x) return {valid=true,type=t,name=t,position={x=x,y=0},electric_network_id=id,
    prototype={get_max_energy_production=function() return 1000 end,get_max_power_output=function() return t=='fusion-generator' and 833333 or nil end}} end
  local list={ent('solar-panel',1456,1),ent('solar-panel',1456,2),ent('solar-panel',1456,3),ent('accumulator',1456,8),ent('fusion-generator',1456,9),
    ent('solar-panel',1460,10)}
  local found
  local plat_surface={name='platform-7',has_global_electric_network=true,global_electric_network_statistics=stats,
    platform={name='Prospect',space_location={name='nauvis',solar_power_in_space=300}},
    find_entities_filtered=function(f) found=f; return list end}
  local NW=require('networks'){state=function() return {} end}
  local g=NW.platform_grid(plat_surface,{name='player'})
  eq(found.type[1],'solar-panel'); eq(found.force.name,'player')
  eq(g.network,1456); eq(g.draw_kw,210); eq(g.production_kw,210)
  -- 3 panels at 300% (540 kW) and a fusion generator's 50 MW
  eq(g.capacity_kw,540+50000)
  eq(g.consumers[1].name,'assembling-machine-1'); eq(g.consumers[1].kw,180); eq(g.producers[1].name,'solar-panel')
  plat_surface.has_global_electric_network=false
  eq(NW.platform_grid(plat_surface,{name='player'}),nil)
  -- powercause on the platform: the platform's network, named, with what makes it and its capacity
  local P=dofile('mod/agent-harness_0.1.0/powercause.lua'){pole_map=function() return {} end,
    platform_power=function(s,f) return {network=20579,draw_kw=29742,production_kw=29742,capacity_kw=280273,
      consumers={{name='assembling-machine-3',kw=10528},{name='laser-turret',quality='rare',kw=3673}},
      producers={{name='fusion-generator',kw=21049},{name='fusion-generator',quality='rare',kw=8420},{name='solar-panel',kw=273}}} end}
  local force={name='player',logistic_networks={}}
  local r=P.read({surface={name='platform-16',platform={name='Asterion'}},force=force},{})
  eq(r.platform,'Asterion'); eq(r.surface,'platform-16')
  local n=r.networks[1]
  eq(n.network,20579); eq(n.platform_network,true); eq(n.draw_kw,29742); eq(n.made_kw,29742); eq(n.capacity_kw,280273)
  eq(n.by_cause[2].name,'laser-turret'); eq(n.by_cause[2].quality,'rare'); eq(n.made_by[2].quality,'rare'); eq(n.made_by[2].kw,8420)
  has(r.lines[1],"electric network 20579 (platform Asterion's own network: its machines, panels and accumulators, no pole needed): draws 29.7 MW, made 29.7 MW, capacity 280.3 MW (last 5 s)")
  has(r.lines[1],'made by fusion-generator 21.0 MW, fusion-generator (rare) 8.4 MW, solar-panel 273 kW')
  -- no network there: the platform named
  local P2=dofile('mod/agent-harness_0.1.0/powercause.lua'){pole_map=function() return {} end,platform_power=function() return nil end}
  local r2=P2.read({surface={name='platform-16',platform={name='Asterion'},find_entities_filtered=function() return {} end},force=force},{})
  eq(r2.lines[1],'no electric network of ours with a draw on platform Asterion (platform-16)')
  defines,prototypes=nil,nil
  print('d24_batch178 QU2 power by_cause on a platform: ok')
end

-- QU3 (Sol #2052: construction_requests true inserted the game's section at 1, and section 5 active false in the same
-- call switched off the section after the intended one; on the copy, Asterion's section 15 meant "production upgrade
-- pickup" and "recovery collectors" was switched on): indices as the sections were before the call, a section by its
-- group's name, and section_before / section_after in a write's reply.
do
  defines={space_platform_state={waiting_at_station=6},inventory={hub_main=1},cargo_destination={}}
  prototypes={item={['iron-plate']={}},space_location={nauvis={}}}
  local function section(manual,group)
    local slots={}
    local sec={index=1,is_manual=manual,group=group or '',active=true,valid=true}
    sec.filters_count=0
    local function recount() local n=0; for i in pairs(slots) do n=math.max(n,i) end; sec.filters_count=n end
    sec.get_slot=function(i) return slots[i] or {} end
    sec.set_slot=function(i,f) slots[i]=f; recount() end
    sec.clear_slot=function(i) slots[i]=nil; recount() end
    setmetatable(sec,{__index=function(_,k) if k=='filters' then local out={}; for i=1,sec.filters_count do out[i]=slots[i] or {} end; return out end end,
      __newindex=function(t,k,v) if k=='filters' then slots={}; recount() else rawset(t,k,v) end end})
    return sec
  end
  local list={}
  local function reindex() for i,s in ipairs(list) do s.index=i end end
  local secs=setmetatable({get_section=function(i) return list[i] end,
    add_section=function() local s=section(true); list[#list+1]=s; reindex(); return s end,
    remove_section=function(i) table.remove(list,i); reindex() end},
    {__index=function(_,k) if k=='sections_count' then return #list end end})
  for i,g in ipairs({'','','A recovery','B upgrade','C rail'}) do list[i]=section(true,g); list[i].active=(i~=4) end
  reindex()
  local hub={valid=true,type='space-platform-hub',name='space-platform-hub',position={x=0,y=0},get_logistic_sections=function() return secs end,
    get_inventory=function() return {get_contents=function() return {} end,get_item_count=function() return 0 end} end}
  local platform={valid=true,name='alpha',index=1,state=6,space_location={name='nauvis'},surface={name='platform-1'},hub=hub}
  local p={index=1,force={platforms={platform},recipes={},get_logistic_group=function() return nil end},surface={}}
  -- the game's switch, faked: on inserts its section at 1, off takes it out (the manual sections keep their order)
  local fake={construction=function(e) return e.on and {filters={}} or nil end,
    set_construction=function(e,on)
      if on and not e.on then table.insert(list,1,section(false)); reindex() end
      if not on and e.on then table.remove(list,1); reindex() end
      e.on=on; return on end}
  local space=dofile('mod/agent-harness_0.1.0/space.lua'){state=function() return {} end,position=function(v) return v end,
    integer=function(v,d) return v==nil and d or v end,real=function(q) return q end,keep=function() return fake end}
  -- switched on with section 4 ("B upgrade", off) switched on in the same call: B upgrade is switched on, now section 5
  local r=space.requests(p,{platform='alpha',construction_requests=true,section=4,active=true})
  eq(list[5].group,'B upgrade'); eq(list[5].active,true); eq(list[4].group,'A recovery'); eq(list[4].active,true)
  eq(r.changed_section,5)
  eq(r.section_before.index,4); eq(r.section_before.group,'B upgrade'); eq(r.section_before.active,false)
  eq(r.section_after.index,5); eq(r.section_after.active,true)
  eq(r.section_moved,"section 4 (as the call found it) is section 5 after construction_requests on switched the game's section in: the call wrote section 5")
  -- switched off with section 6 ("C rail") switched off: C rail, now section 5
  r=space.requests(p,{platform='alpha',construction_requests=false,section=6,active=false})
  eq(#list,5); eq(list[5].group,'C rail'); eq(list[5].active,false); eq(list[4].active,true)
  eq(r.section_before.index,6); eq(r.section_after.index,5); has(r.section_moved,'section 6 (as the call found it) is section 5')
  -- by the group's name
  r=space.requests(p,{platform='alpha',section='B upgrade',active=false})
  eq(list[4].active,false); eq(r.section_group,'B upgrade'); eq(r.section_before.index,4); eq(r.section_before.active,true); eq(r.section_after.active,false)
  eq(r.section_moved,nil)
  fails(function() space.requests(p,{platform='alpha',section='Z none',active=true}) end,'no section is in the logistic group "Z none" (sections in a group: 3 "A recovery", 4 "B upgrade", 5 "C rail")')
  list[2].group='A recovery'
  fails(function() space.requests(p,{platform='alpha',section='A recovery',active=true}) end,'sections 2, 3 are all in the logistic group "A recovery"')
  list[2].group=''
  -- a set into a named section across the switch: the item goes to the section named
  r=space.requests(p,{platform='alpha',construction_requests=true,section=3,set={{item='iron-plate',min=7}}})
  eq(list[4].group,'A recovery'); eq(list[4].filters[1].value.name,'iron-plate'); eq(r.section_after.index,4); eq(r.section_before.index,3)
  -- a read gives no before/after
  r=space.requests(p,{platform='alpha'})
  eq(r.section_before,nil); eq(r.section_after,nil)
  defines,prototypes=nil,nil
  print('d24_batch178 QU3 request sections: ok')
end
