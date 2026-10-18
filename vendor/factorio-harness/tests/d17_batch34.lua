-- d17 batch34 (the agents' 12:20 poll). Run from the harness root: lua tests/d17_batch34.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,msg) assert(a==b,(msg or '')..' '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
defines=defines or {}
defines.inventory=defines.inventory or {};defines.inventory.robot_cargo=9
defines.robot_order_type={construct=3}

-- A1 (Astra): a ghost over a live entity of ours it would replace, not marked for upgrade, is blocked; ghosts and
-- construction_robots say so with the count and the upgrade call. ----------------------------------------------------
do
  local layers={object=true,item=true,player=true}
  local box={left_top={x=-0.15,y=-0.15},right_bottom={x=0.15,y=0.15}}
  local medium={name='medium-electric-pole',fast_replaceable_group='electric-pole',collision_box=box,collision_mask={layers=layers},items_to_place_this={{name='medium-electric-pole',count=1}}}
  local small={name='small-electric-pole',fast_replaceable_group='electric-pole',collision_box=box,collision_mask={layers=layers}}
  local chestp={name='wooden-chest',collision_box={left_top={x=-0.35,y=-0.35},right_bottom={x=0.35,y=0.35}},collision_mask={layers=layers}}
  local force={}
  local live,ghosts={},{}
  local surf={name='nauvis'}
  local function at(x,y) return {x=x,y=y} end
  local function ghost(x,y,proto,u)
    local g={valid=true,type='entity-ghost',name='entity-ghost',ghost_name=proto.name,ghost_prototype=proto,position=at(x,y),force=force,surface=surf,unit_number=u,
      bounding_box={left_top={x=x+proto.collision_box.left_top.x,y=y+proto.collision_box.left_top.y},right_bottom={x=x+proto.collision_box.right_bottom.x,y=y+proto.collision_box.right_bottom.y}}}
    ghosts[#ghosts+1]=g; return g
  end
  local function built(x,y,proto,marked)
    local e={valid=true,type=proto==chestp and 'container' or 'electric-pole',name=proto.name,prototype=proto,position=at(x,y),force=force,
      to_be_deconstructed=function() return marked=='decon' end,to_be_upgraded=function() return marked=='up' end}
    live[#live+1]=e; return e
  end
  for i=0,2 do built(10.5+i*7,4.5,small); ghost(10.5+i*7,4.5,medium,600+i) end
  built(40.5,4.5,small,'up'); ghost(40.5,4.5,medium,610)
  ghost(50.5,4.5,medium,611)
  built(60.5,4.5,chestp); ghost(60.5,4.5,medium,612)
  surf.find_entities_filtered=function(f)
    if f.type then return ghosts end
    local out={}
    for _,e in ipairs(live) do
      if e.position.x>f.area[1][1]-0.5 and e.position.x<f.area[2][1]+0.5 and e.position.y>f.area[1][2]-0.5 and e.position.y<f.area[2][2]+0.5 then out[#out+1]=e end
    end
    for _,g in ipairs(ghosts) do if g.position.x>f.area[1][1] and g.position.x<f.area[2][1] and g.position.y>f.area[1][2] and g.position.y<f.area[2][2] then out[#out+1]=g end end
    return out
  end
  local rnet={valid=true,network_id=7,construction_robots={},all_construction_robots=10,available_construction_robots=10,cells={},storages={},
    find_cell_closest_to=function() return nil end,get_item_count=function() return 50 end}
  surf.find_logistic_networks_by_construction_area=function() return {rnet} end
  local RB=dofile('mod/agent-harness_0.1.0/robots.lua'){position=function(v) return v end}
  local u,kind=RB.under(ghosts[1]); eq(u,live[1]); eq(kind,true)
  eq(RB.under(ghosts[4]),nil,'marked for upgrade')
  eq(RB.under(ghosts[5]),nil,'nothing under')
  local c,ck=RB.under(ghosts[6]); eq(c.name,'wooden-chest'); eq(ck,false)
  prototypes={entity={}}
  local GL=dofile('mod/agent-harness_0.1.0/ghostlist.lua'){position=function(v) return v end,integer=function(v,d) return v or d end,
    distance=function(a,b) return ((a.x-b.x)^2+(a.y-b.y)^2)^0.5 end,under=RB.under,under_lines=RB.under_lines}
  local r=GL.read({surface=surf,position=at(0,0),force=force,get_main_inventory=function() return nil end},{})
  has(r.lines[1],'blocked: our live small-electric-pole (10.5,4.5) stands on its spot, not marked for upgrade (robots do not build it until it is)')
  has(r.summary,'4 blocked: a live entity of ours on its spot, not marked for upgrade or deconstruction')
  has(r.summary,'2 robots can build it')
  eq(r.blocked[1],'3 medium-electric-pole ghosts over our live small-electric-pole, not marked for upgrade: robots do not build them until it is; upgrade {area: [[9,3],[26,6]], from: "small-electric-pole", to: "medium-electric-pole"} marks them')
  eq(r.blocked[2],'1 medium-electric-pole ghost over our live wooden-chest, not marked for deconstruction: robots do not build it until it is; deconstruct {area: [[59,3],[62,6]], entity_names: ["wooden-chest"]} marks it')
  -- construction_robots: a robot whose order targets a blocked ghost says it, and ghosts_blocked counts them
  local bot={valid=true,name='construction-robot',position=at(5,5),energy=3000000,prototype={max_energy=3000000},
    robot_order_queue={{type=3,target=ghosts[1]},{type=3,target=ghosts[2]}},
    get_inventory=function() return {get_contents=function() return {{name='medium-electric-pole',count=2,quality='normal'}} end} end}
  rnet.construction_robots={bot}
  local out=RB.read({surface=surf,position=at(0,0),force={logistic_networks={nauvis={rnet}},find_logistic_network_by_position=function() return rnet end}},{_where=', surface: "nauvis"'})
  has(out.robots[1],'its target medium-electric-pole ghost (10.5,4.5) stands over our live small-electric-pole, not marked for upgrade')
  has(out.summary,'1 held up')
  eq(out.ghosts_blocked[1],'2 medium-electric-pole ghosts over our live small-electric-pole, not marked for upgrade: robots do not build them until it is; upgrade {area: [[9,3],[19,6]], from: "small-electric-pole", to: "medium-electric-pole", surface: "nauvis"} marks them')
end

-- A2 (Astra, Luna): a drop into a landing pad: what the pad held before and at landing, and what construction robots
-- took from it in the 20 s after; where_is and shipment say it. -------------------------------------------------------
do
  storage={}
  defines.inventory.chest=1
  local held={['underground-belt']=0,['wooden-chest']=2}
  local robots={}
  local gleba={name='gleba'}
  local pad={valid=true,name='cargo-landing-pad',type='cargo-landing-pad',position={x=54,y=8},force='player',surface=gleba,
    get_item_count=function(w) return held[w.name] or 0 end}
  gleba.find_entities_filtered=function(f)
    if f.name=='cargo-pod-container' then return {} end
    eq(f.type[1],'construction-robot'); eq(f.radius,8)
    return robots
  end
  game={tick=5000,surfaces={gleba=gleba}}
  local D=dofile('mod/agent-harness_0.1.0/drops.lua'){state=function() return storage end,integer=function(v,d) return v or d end,
    who=function(p) return p.name end,resolve=function(n) return n end}
  local pod={valid=true,surface=gleba,position={x=50,y=0}}
  local id=D.record({name='astra'},{pod=pod,platform='Petrel',surface='gleba',pad={x=54,y=8},pad_e=pad,near={x=54,y=8},
    sent={'underground-belt*3','wooden-chest*1'},items={{name='underground-belt',quality='normal',count=3},{name='wooden-chest',quality='normal',count=1}},to={'luna'}})
  local function step(n) for _=1,n do game.tick=game.tick+1; D.tick(game.tick) end end
  step(15)
  -- it lands: the pad holds the 3 belts and 3 chests
  pod.valid=false; held['underground-belt']=3; held['wooden-chest']=3
  step(15)
  local h={}
  eq(#D.lines({name='luna'},h),0,'the landed line waits for the watch')
  -- robots take them: two with belts, one with a chest, each on its way to a ghost
  local function bot(u,item,n,gx)
    return {valid=true,unit_number=u,type='construction-robot',
      get_inventory=function() return {get_item_count=function(w) return w.name==item and n or 0 end} end,
      robot_order_queue={{type=3,target={valid=true,type='entity-ghost',ghost_name=item,name='entity-ghost',position={x=gx,y=20.5}}}}}
  end
  robots={bot(1,'underground-belt',2,60.5),bot(2,'underground-belt',1,61.5),bot(3,'wooden-chest',1,70.5)}
  held['underground-belt']=0; held['wooden-chest']=2
  step(15)
  robots={}
  step(1200)
  local r=storage.drops.list[1]
  eq(D.pad_verdict(r),'landed, then taken by construction robots')
  local line=D.lines({name='luna'},h)[1]
  has(line,'drop #1 from Petrel landed in the landing pad at (54,8) on gleba: underground-belt*3 wooden-chest*1; the pad held underground-belt 0, wooden-chest 2 before it and underground-belt 3, wooden-chest 3 when it landed')
  has(line,'in the 20 s after: underground-belt: construction robots took 3 (first orders: underground-belt ghost (60.5,20.5); underground-belt ghost (61.5,20.5)); wooden-chest: construction robots took 1 (first orders: wooden-chest ghost (70.5,20.5)); it held underground-belt 0, wooden-chest 2 then')
  local rd=D.read({name='astra'},{}).drops[1]
  eq(rd.pad_verdict,'landed, then taken by construction robots'); eq(rd.pad_now,'the pad holds underground-belt 0, wooden-chest 2 now')
  local t=D.taken({item='underground-belt',surface='gleba'})
  eq(#t,1); has(t[1].line,'drop #1 from Petrel ('); eq(t[1].verdict,'landed, then taken by construction robots')
  eq(#D.taken({item='iron-plate',surface='gleba'}),0)
  -- where_is shows it
  local S=dofile('mod/agent-harness_0.1.0/stores.lua'){drops_taken=function(f) return D.taken(f) end,agents=function() return {} end}
  prototypes={item={['underground-belt']={get_spoil_ticks=function() return 0 end}}}
  gleba.find_entities_filtered=function() return {} end
  local w=S.where_is({surface=gleba,position={x=0,y=0},force={name='player'}},{item='underground-belt'})
  has(w.drops[1],'landed, then taken by construction robots: drop #1 from Petrel')
end

-- A3 (Muse): the platform_bom keeper keeps each item in its slot (none written into another's), and platform_bom says
-- which items the open ghosts need that no active hub request asks for. -----------------------------------------------
do
  defines.inventory.hub_main=1
  prototypes={item={['space-platform-foundation']={weight=20000},['solar-panel']={weight=20000},['gun-turret']={weight=20000}},utility_constants={rocket_lift_weight=1000000},
    space_location={nauvis={}}}
  local tile={name='space-platform-foundation',items_to_place_this={{name='space-platform-foundation',count=1}}}
  local panel={name='solar-panel',items_to_place_this={{name='solar-panel',count=1}}}
  local gun={name='gun-turret',items_to_place_this={{name='gun-turret',count=1}}}
  local ents={}
  for i=1,72 do ents[#ents+1]={type='tile-ghost',ghost_name='space-platform-foundation',ghost_prototype=tile} end
  for i=1,3 do ents[#ents+1]={type='entity-ghost',ghost_name='solar-panel',ghost_prototype=panel} end
  local function find(f)
    local want={}
    for _,t in ipairs(type(f.type)=='table' and f.type or {f.type}) do want[t]=true end
    local out={}
    for _,e in ipairs(ents) do if want[e.type] then out[#out+1]=e end end
    return out
  end
  local sections={}
  local secs={sections_count=0}
  secs.get_section=function(i) return sections[i] end
  local writes=0
  secs.add_section=function(g)
    local sec={group=g,slots={},filters_count=0,active=true}
    -- a write of an item another slot holds is refused here (whatever the game does with one, the keeper never asks it)
    sec.set_slot=function(i,x)
      for j,y in pairs(sec.slots) do if j~=i and y.value.name==x.value.name then error('duplicate '..x.value.name..' in slot '..j) end end
      sec.slots[i]=x; sec.filters_count=math.max(sec.filters_count,i); writes=writes+1
    end
    sec.clear_slot=function(i) sec.slots[i]=nil end
    sec.get_slot=function(i) return sec.slots[i] end
    sec.filters={}
    sections[#sections+1]=sec; secs.sections_count=#sections; return sec
  end
  secs.remove_section=function(i) table.remove(sections,i); secs.sections_count=#sections end
  local hub={valid=true,get_logistic_sections=function() return secs end,get_inventory=function() return {get_item_count=function() return 0 end} end}
  local pl={valid=true,index=9,name='Wayfarer',hub=hub,space_location={name='nauvis'},surface={find_entities_filtered=find,count_entities_filtered=function() return 0 end,count_tiles_filtered=function() return 3360 end}}
  local force={name='player',platforms={pl}}
  pl.force=force
  game={tick=600,forces={player=force},surfaces={}}
  local st={}
  local B=dofile('mod/agent-harness_0.1.0/platbom.lua'){platform=function() return pl end,state=function() return st end,
    cargo={limits=function() return 1000000,40 end,weigh=function() return {total_kg=1,fewest=1} end}}
  B.read({force=force},{platform='Wayfarer',request=true})
  local sec=sections[1]
  eq(sec.slots[1].value.name,'solar-panel'); eq(sec.slots[2].value.name,'space-platform-foundation'); eq(sec.slots[2].min,72)
  -- the panels are built: the floor keeps slot 2, slot 1 is cleared
  for i=#ents,1,-1 do if ents[i].ghost_name=='solar-panel' then table.remove(ents,i) end end
  local w0=writes
  B.tick(1200)
  eq(sec.slots[1],nil); eq(sec.slots[2].value.name,'space-platform-foundation'); eq(sec.slots[2].min,72)
  eq(writes,w0,'the floor slot as wanted is not written again')
  -- a gun turret ghost: it takes the free slot 1
  ents[#ents+1]={type='entity-ghost',ghost_name='gun-turret',ghost_prototype=gun}
  B.tick(1800)
  eq(sec.slots[1].value.name,'gun-turret'); eq(sec.slots[2].value.name,'space-platform-foundation')
  -- the read: every item has a request; with the section off, the floor and the turret have none
  for _,x in pairs(sec.slots) do sec.filters[#sec.filters+1]=x end
  local r=B.read({force=force},{platform='Wayfarer'})
  eq(r.requests_check,'every item the ghosts still need has an active hub request'); eq(r.unrequested,nil)
  sec.active=false
  r=B.read({force=force},{platform='Wayfarer'})
  eq(r.requests_check,'2 items the ghosts still need have no active hub request (unrequested)')
  eq(r.unrequested[1],'space-platform-foundation: ghosts need 72, 72 not in the hub, in flight or in robots; no active hub request asks for it')
  defines.inventory.hub_main=nil
end

-- A4 (Sol): a queued wait_until with on_timeout "hold" that times out stays first in pending; the queue pauses with
-- it, the reply names the condition still unmet, and queue_resume waits for it again. ---------------------------------
do
  game={tick=0}
  local world,state,calls={},{},{}
  local players={[1]={index=1}}
  local factory=dofile('mod/agent-harness_0.1.0/scheduler.lua')
  local sch=factory{state=function() return state end,player=function(i) return players[i] end,
    handlers={craft=function() calls[#calls+1]='craft'; return {started=1} end},
    busy=function() return false end,stop=function() end,stop_index=function() end,
    condition=function(_,c) return world.lds==true,'Swiftlet hub low-density-structure 0' end,
    validate_condition=function(c) assert(type(c)=='table' and c['until'],'until must be one of') end}
  local h=sch.handlers
  local p=players[1]
  local function tick(n) for _=1,n do game.tick=game.tick+1; sch.tick() end end
  local gate={['until']='item_count',platform='Swiftlet',item='low-density-structure',at_least=400,timeout=30,on_timeout='hold'}
  h.queue_submit(p,{steps={{action='wait_until',args=gate,label='lds gate'},{action='craft'}}})
  tick(60)
  local q=h.queue_status(p)
  assert(q.paused,'paused'); eq(#calls,0)
  eq(q.pending[1].action,'wait_until'); eq(q.pending[1].label,'lds gate'); eq(q.pending_count,2)
  has(q.paused_why,'wait_until timed out after 31 ticks and is held (on_timeout: hold): still unmet: item_count platform Swiftlet item low-density-structure at_least 400 (saw: Swiftlet hub low-density-structure 0); the step stays first in pending')
  local last=q.history[#q.history]
  eq(last.result.outcome,'timed_out'); eq(last.result.held,true)
  -- resumed, it waits again; met, the plan goes on
  h.queue_resume(p,{})
  tick(15); eq(h.queue_status(p).active.action,'wait_until')
  world.lds=true; tick(15)
  eq(calls[1],'craft')
  -- without on_timeout the step fails and is gone, as before
  world.lds=false; calls={}
  local plain={['until']='item_count',platform='Swiftlet',item='low-density-structure',at_least=400,timeout=30}
  h.queue_submit(p,{steps={{action='wait_until',args=plain},{action='craft'}}})
  tick(60)
  q=h.queue_status(p); eq(q.pending[1].action,'craft'); eq(q.last_failure.result.outcome,'timed_out')
  assert(not pcall(h.queue_submit,p,{steps={{action='wait_until',args={['until']='item_count',on_timeout='retry'}}}}),'on_timeout retry refused')
end

print('d17 batch34 ok')
