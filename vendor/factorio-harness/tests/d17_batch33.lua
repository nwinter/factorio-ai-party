-- d17 batch33. Run from the harness root: lua tests/d17_batch33.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,msg) assert(a==b,(msg or '')..' '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end

-- A1 (Sol: Wayfarer's 3318 tile ghosts; the one-tick check stopped at 4096 steps and the dry run read the rest as 107
-- unbuildable): the play stops undecided, never unbuilt; a check across ticks finishes it.
do
  game={tick=1000,surfaces={}}
  local found={}
  for x=0,9 do found[x..','..0]=true end
  local surface={index=7,get_tile=function(x,y) return {name=found[x..','..y] and 'space-platform-foundation' or 'empty-space'} end,
    count_tiles_filtered=function() local n=0 for _ in pairs(found) do n=n+1 end return n end}
  game.surfaces[7]=surface
  local TC=dofile('mod/agent-harness_0.1.0/tilecheck.lua')()
  local tiles={}
  for y=1,20 do for x=0,9 do tiles[#tiles+1]={x,y,'space-platform-foundation'} end end
  tiles[#tiles+1]={40,40,'space-platform-foundation'}  -- far from any foundation
  -- in one go: every fill tile built, the far one not
  local play=TC.play(surface,tiles,nil,{},{},100000)
  local n=0 for _ in pairs(play.built) do n=n+1 end
  eq(n,200); eq(play.left,0); eq(play.rule({40,40}),'no foundation among the 8 tiles round it')
  -- each tile once on the work list: checks stay near the tile count
  assert(play.steps<=2*#tiles,play.steps)
  -- stopped early: the rest is unchecked, not unbuilt
  play=TC.play(surface,tiles,nil,{},{},50)
  assert(play.left>0); local u=0 for _ in pairs(play.unchecked) do u=u+1 end; eq(u,play.left)
  -- across ticks
  local st={}
  local F=dofile('mod/agent-harness_0.1.0/floorcheck.lua'){state=function() return st end}
  local cells={}
  for i,t in ipairs(tiles) do cells[i]={t[1],t[2]} end
  local id=F.start(surface,cells,nil,{},'test fill')
  local r=F.read(id)
  eq(r.state,'running'); has(r.line,'floor check #1 (test fill): 201 tiles, running: 0 rule checks so far (150 a tick), 201 tiles still queued')
  for _=1,20 do F.tick() end
  r=F.read(id)
  eq(r.state,'done'); eq(r.would_build,200); eq(r.never_built,1); eq(r.built,nil)
  eq(r.unbuilt[1],'(40.5,40.5): no foundation among the 8 tiles round it')
  -- (A6, Sol 10:16) what the plan would build, beside the floor built now
  eq(r.floor_now,10)
  has(r.line,'201 planned tiles played through the hub\'s rules'); has(r.line,'200 would be built in turn, 1 never (1 no foundation among the 8 tiles round it); the floor built now: 10 tiles')
  eq(st.floorcheck.jobs[id].ghosts,nil,'the large tables go when done')
  fails(function() F.read(99) end,'no floor check #99 (kept: 1)')
  game=nil
end
print('d17_batch33 A1 floor check across ticks: ok')

-- A3 (Sol: Wayfarer's arithmetic combinators asked 2 against the default, a full rocket of 50, even with tail): tail
-- lowers a slot on the game's default minimum payload too, and each line says the minimum the slot has.
do
  game={tick=0,forces={}}
  defines={inventory={hub_main=1}}
  prototypes={space_location={nauvis={}},item={['arithmetic-combinator']={weight=20000}},utility_constants={rocket_lift_weight=1000000}}
  local ghosts={}
  local proto={name='arithmetic-combinator',items_to_place_this={{name='arithmetic-combinator',count=1}}}
  for i=1,4 do ghosts[i]={type='entity-ghost',ghost_name='arithmetic-combinator',ghost_prototype=proto} end
  local sections={}
  local function section(group)
    local sec={group=group,slots={},is_manual=true,filters_count=0}
    sec.set_slot=function(i,f) sec.slots[i]=f; sec.filters_count=math.max(sec.filters_count,i) end
    sec.get_slot=function(i) return sec.slots[i] end
    sec.clear_slot=function(i) sec.slots[i]=nil end
    return sec
  end
  local secs={sections_count=0}
  secs.get_section=function(i) return sections[i] end
  secs.add_section=function(g) sections[#sections+1]=section(g); secs.sections_count=#sections; return sections[#sections] end
  secs.remove_section=function(i) table.remove(sections,i); secs.sections_count=#sections end
  local held=2
  local hub={valid=true,get_logistic_sections=function() return secs end,get_inventory=function() return {get_item_count=function() return held end} end}
  local pl={valid=true,index=6,name='Wayfarer',hub=hub,space_location={name='nauvis'},surface={find_entities_filtered=function() return ghosts end}}
  local force={name='player',platforms={pl}}
  pl.force=force; game.forces={player=force}
  local st={}
  local B=dofile('mod/agent-harness_0.1.0/platbom.lua'){platform=function() return pl end,state=function() return st end}
  -- without tail: the game's default, said
  local r=B.read({force=force},{platform='Wayfarer',request=true,import_from='nauvis'})
  eq(sections[1].slots[1].minimum_delivery_count,nil)
  has(r.lines[1],'minimum payload: a full rocket, 50 by weight (the game\'s default)')
  -- tail: 4 asked, 2 held: 2 to come, under the 50 a full rocket takes
  r=B.read({force=force},{platform='Wayfarer',request=true,import_from='nauvis',tail=true})
  eq(sections[1].slots[1].minimum_delivery_count,2)
  has(r.lines[1],'custom minimum payload 2 (tail: 2 of the 50 a full rocket takes, what is still to come)')
  defines,prototypes,game=nil,nil,nil
end
print('d17_batch33 A3 tail on the default payload: ok')

-- A4 (Astra 09:50: Petrel's freight queue stopped at each drop for a hand check): pod_landed in the remote and platform
-- lanes, and one drop by drop_id or last_drop.
do
  game={tick=100}
  prototypes={item={}}
  local drops={{id=7,platform='Petrel',state='descending',surface='nauvis'},{id=9,platform='Petrel',state='descending',surface='nauvis'}}
  local C=dofile('mod/agent-harness_0.1.0/conditions.lua'){position=function(v) return v end,
    drop_record=function(id) for _,r in ipairs(drops) do if r.id==id then return r end end end,
    last_drop=function(name) local b; for _,r in ipairs(drops) do if r.platform==name and (not b or r.id>b) then b=r.id end end return b end}
  local pl={valid=true,name='Petrel'}
  local p={force={platforms={pl}}}
  local rec={}
  local c={['until']='pod_landed',platform='Petrel',last_drop=true}
  C.validate(c)
  local met,saw=C.check(p,c,nil,rec)
  eq(met,false); eq(saw,'drop #9 from Petrel still descending'); eq(rec.drop_id,9)
  drops[3]={id=10,platform='Petrel',state='descending'}  -- a later drop does not move the wait
  drops[2].state='landed'; drops[2].into='cargo-landing-pad'; drops[2].at={x=12.5,y=3.5}
  met,saw=C.check(p,c,nil,rec)
  eq(met,true); eq(saw,'drop #9 from Petrel landed in cargo-landing-pad at (12.5,3.5) on nauvis')
  met=C.check(p,{['until']='pod_landed',platform='Petrel',drop_id=7},nil,{})
  eq(met,false)
  fails(function() C.validate({['until']='pod_landed',platform='Petrel',drop_id=7,last_drop=true}) end,'drop_id or last_drop, not both')
  fails(function() C.validate({['until']='pod_landed',platform='Petrel',last_drop=true,at_least=2}) end,'wait for one drop')
  fails(function() C.check(p,{['until']='pod_landed',platform='Petrel',drop_id=3},nil,{}) end,'drop #3 is no longer kept')
  -- the remote lane takes it
  local remote
  dofile('mod/agent-harness_0.1.0/queue_lanes.lua'){scheduler={handlers={},schema={queue_submit={},queue_status={returns=''}}},base={},
    factory=function(r_) remote=r_; return {handlers={}} end,is_read=function() return false end}
  remote.check_step('wait_until',{['until']='pod_landed',platform='Petrel',last_drop=true})
  remote.check_step('wait_until',{['until']='all',conditions={{['until']='pod_landed',platform='Petrel'},{['until']='platform_left',platform='Petrel'}}})
  fails(function() remote.check_step('wait_until',{['until']='pod_landed'}) end,'pod_landed with platform')
  game,prototypes=nil,nil
end
print('d17_batch33 A4 pod_landed in the lanes, one drop: ok')

-- A5 (Sol 09:59: 7 railgun ghosts each asked 10 ammo by place_ghosts' default): a turret ghost's ammo request changed
-- or cleared in place, its module requests kept; place_ghosts names the default it adds.
do
  defines={inventory={turret_ammo=7,turret_modules=3}}
  prototypes={item={['railgun-ammo']={type='ammo',stack_size=10,ammo_category={name='railgun'}},['firearm-magazine']={type='ammo',stack_size=200}},
    get_item_filtered=function() return {['railgun-ammo']={name='railgun-ammo',type='ammo',ammo_category={name='railgun'},order='a'}} end}
  local T=dofile('mod/agent-harness_0.1.0/turretammo.lua'){state=function() return {} end}
  local proto={type='ammo-turret',attack_parameters={ammo_categories={'railgun'}},automated_ammo_count=10,get_inventory_size=function() return 1 end}
  local ghost={valid=true,type='entity-ghost',ghost_name='railgun-turret',ghost_prototype=proto,position={x=3.5,y=-8.5},surface={find_logistic_network_by_position=function() return nil end},force={},
    insert_plan={{id={name='railgun-ammo',quality='normal'},items={in_inventory={{inventory=7,stack=0,count=10}}}},
      {id={name='speed-module',quality='normal'},items={in_inventory={{inventory=3,stack=0,count=1}}}}}}
  local r=T.set(ghost,{name='railgun-ammo',count=2})
  eq(r.before,'railgun-ammo*10'); eq(r.after,'railgun-ammo*2')
  eq(#ghost.insert_plan,2); eq(ghost.insert_plan[1].id.name,'speed-module','the module request stays'); eq(ghost.insert_plan[2].items.in_inventory[1].count,2)
  r=T.set(ghost,false)
  eq(r.before,'railgun-ammo*2'); eq(r.after,'none'); eq(#ghost.insert_plan,1)
  fails(function() T.set({valid=true,type='ammo-turret'},false) end,'a built turret takes ammo by platform_rearm, deliver or transfer')
  local rows={}
  T.add(rows,{name='railgun-ammo',count=10,default=true}); for _=1,6 do T.add(rows,{name='railgun-ammo',count=10,default=true}) end
  eq(T.default_note(rows),'by default 7 turret ghosts each request 10 railgun-ammo (the entry\'s ammo: false for none, or {name, count}; configure {position, ammo} changes it on a ghost)')
  eq(T.default_note({{item='railgun-ammo',count=2,ghosts=1}}),nil,'asked for: no note')
  defines,prototypes=nil,nil
end
print('d17_batch33 A5 a ghost\'s ammo request in place: ok')

-- B1 (Grok 09:22: the last pentapod eggs were in an inserter hand, then robot cargo; where_is said 0): what our robots
-- carry, in where_is and the seed alert.
do
  defines={inventory={robot_cargo=1}}
  local S=dofile('mod/agent-harness_0.1.0/stores.lua'){agents=function() return {} end}
  local function robot(name,n) return {get_inventory=function() return {get_item_count=function(i) return i==name and n or 0 end} end} end
  local net={logistic_robots={robot('pentapod-egg',1),robot('iron-plate',4)},construction_robots={robot('pentapod-egg',2)}}
  local force={logistic_networks={gleba={net}}}
  local n,carrying,read,capped=S.robot_cargo(force,{name='gleba'},'pentapod-egg')
  eq(n,3); eq(carrying,2); eq(read,3); eq(capped,false)
  S.MAX_ROBOTS=2
  n,carrying,read,capped=S.robot_cargo(force,{name='gleba'},'pentapod-egg')
  eq(read,2); eq(capped,true)
  S.MAX_ROBOTS=4096
  -- the seed alert counts it: one egg in a robot is not zero
  game={tick=600,surfaces={}}
  prototypes={recipe={['pentapod-egg']={name='pentapod-egg',ingredients={{type='item',name='pentapod-egg',amount=1}}}}}
  defines.inventory.assembling_machine_input=2; defines.inventory.assembling_machine_output=3
  local empty={get_item_count=function() return 0 end}
  local chamber={valid=true,name='biochamber',type='assembling-machine',position={x=0,y=0},bounding_box={left_top={x=-1.5,y=-1.5},right_bottom={x=1.5,y=1.5}},
    last_user={name='grok'},get_recipe=function() return {name='pentapod-egg'} end,get_inventory=function() return setmetatable(empty,{__len=function() return 0 end}) end}
  local surface={name='gleba',find_entities_filtered=function() return {} end}
  local Sd=dofile('mod/agent-harness_0.1.0/seeds.lua'){state=function() return {} end,crafters=function() return {chamber} end,
    robot_cargo=function(f,s,item) return (S.robot_cargo(f,s,item)) end}
  local rows=Sd.read({name='player',logistic_networks={gleba={net}}},surface)
  eq(rows['pentapod-egg'].count,3); eq(rows['pentapod-egg'].in_robots,3)
  defines,game,prototypes=nil,nil,nil
end
print('d17_batch33 B1 robot cargo counted: ok')

-- B2 (Sol, Astra and viewer Foobator 08:09: who looks after each system): board_review {ownership} per surface.
do
  game={tick=100000}
  local nauvis={name='nauvis',index=1,planet={name='nauvis'}}
  game.surfaces={nauvis}
  game.get_surface=function(n) return n=='nauvis' and nauvis or nil end
  local items={
    [5]={id=5,kind='claim',status='claimed',owner='astra',title='Nauvis smelting',surface='nauvis',area={left_top={x=0,y=0},right_bottom={x=20,y=20}},active_tick=99000},
    [6]={id=6,kind='claim',status='claimed',owner='sol',title='Nauvis (everything else)',surface='nauvis',active_tick=90000},
    [9]={id=9,kind='task',status='blocked',owner='astra',title='steel row',notes={{tick=98000,by='astra',text='no coal on the west belt'}}}}
  local st={board={items=items}}
  local function machine(x,y,net) return {valid=true,name='steel-furnace',position={x=x,y=y},electric_network_id=net} end
  local crafters={machine(5,5,57),machine(50,50,57)}
  local roboport={valid=true,position={x=200,y=200}}
  local force={platforms={},logistic_networks={nauvis={{network_id=3,cells={{owner=roboport}}}}}}
  local C=dofile('mod/agent-harness_0.1.0/claims.lua'){state=function() return st end,crafters=function() return crafters end}
  -- an inspection in astra's area by sol is recorded
  C.worked({name='sol',surface=nauvis,character=nil},{position={x=4,y=4}},'inspect',true)
  eq(items[5].inspected.by,'sol'); eq(items[5].inspected.tick,100000)
  game.tick=100600
  local r=C.ownership({force=force},{})
  eq(#r.surfaces,1); eq(r.surfaces[1].surface,'nauvis')
  local rows=r.surfaces[1].systems
  eq(rows[1].kind,'power'); eq(rows[1].claims,1)
  eq(rows[1].line,'electric network #57: 2 machines (2 steel-furnace): claim #5 astra (active there 26s ago, inspected 10s ago by sol): 1 of 2 machines in its area')
  eq(rows[2].line,'logistic network #3: 1 roboport cell: no area covers it; planet-wide claim #6 sol (active there 2m56s ago, no inspection there recorded)')
  eq(r.blocked[1],'astra: #9 steel row is blocked (latest note 43s ago by astra: no coal on the west belt)')
  game=nil
end
print('d17_batch33 B2 ownership read: ok')

-- batch32 B5 (Astra: Kestrel II read 15 railgun rounds able to reach a railgun while both railguns stood empty: the
-- rounds sat behind magazines on a full ring): a way open by topology but blocked now by another ammunition at the
-- front of the lane it picks from reads blocked, apart from reaching, with the lane's mix.
do
  defines={inventory={turret_ammo=1,hub_main=2,chest=3},entity_status={disabled_by_control_behavior=99}}
  prototypes={item={['firearm-magazine']={type='ammo',ammo_category='bullet'},['railgun-ammo']={type='ammo',ammo_category='railgun'}}}
  local n=0
  local function contents(t) local out={} for name,c in pairs(t) do out[#out+1]={name=name,count=c} end return out end
  local function inv(t) return {get_contents=function() return contents(t) end} end
  -- lane 1 of a belt: its items front first ({name, count}) as detailed contents, 4 a tile when full
  local function belt(x,y,lane)
    n=n+1
    local b={valid=true,unit_number=n,type='transport-belt',name='transport-belt',position={x=x,y=y},belt_neighbours={inputs={}}}
    b.get_max_transport_line_index=function() return 2 end
    b.get_transport_line=function(i)
      local items=i==1 and lane or {}
      local sum={}
      for _,it in ipairs(items) do sum[it]=(sum[it] or 0)+1 end
      local det={}
      for k,it in ipairs(items) do det[k]={stack={valid_for_read=true,name=it,count=1},position=1-k*0.25} end
      return setmetatable({line_length=1,get_contents=function() return contents(sum) end,get_detailed_contents=function() return det end},
        {__len=function() return #items end})
    end
    return b
  end
  local turret={valid=true,unit_number=100,type='ammo-turret',name='railgun-turret',position={x=0,y=-10},prototype={attack_parameters={ammo_categories={'railgun'}}}}
  turret.get_inventory=function() return inv({}) end
  local hub={valid=true,unit_number=200,type='space-platform-hub',name='space-platform-hub',position={x=0,y=0}}
  hub.get_inventory=function() return inv({}) end
  local b1=belt(0,-8,{'firearm-magazine','firearm-magazine','firearm-magazine','railgun-ammo'})
  local b2=belt(0,-7,{'railgun-ammo','railgun-ammo','railgun-ammo','railgun-ammo'})
  b1.belt_neighbours.inputs={b2}; b2.belt_neighbours.inputs={b1}
  local ins={valid=true,unit_number=300,type='inserter',name='fast-inserter',position={x=0,y=-9},drop_target=turret,pickup_target=b1,pickup_from_right_lane=false}
  local surface={find_entities_filtered=function(f)
    local t=type(f.type)=='table' and f.type[1] or f.type
    if t=='inserter' then return {ins} end
    if t=='ammo-turret' then return {turret} end
    if t=='transport-belt' then return {b1,b2} end
    return {}
  end}
  local F=dofile('mod/agent-harness_0.1.0/ammofeed.lua'){}
  local tr=F.trace({surface=surface,force='player',hub=hub})
  local row=tr.rows[1]
  eq(row.reaches,0); eq(row.blocked,5)
  has(table.concat(row.stops,' | '),'blocked by firearm-magazine ahead: the left lane at (0,-8) is full, firearm-magazine at its front (mix: 1 railgun-ammo, 3 firearm-magazine); the 5 behind it do not reach the turret now')
  local lines=F.lines(tr,true)
  has(table.concat(lines,' | '),'railgun-turret (0,-10): holds 0; 0 reach it, 5 more blocked by other ammunition ahead')
  -- the front item one the turret takes: not blocked
  b1=belt(0,-8,{'railgun-ammo','firearm-magazine','firearm-magazine','firearm-magazine'}); b1.belt_neighbours.inputs={b2}; b2.belt_neighbours.inputs={b1}; ins.pickup_target=b1
  tr=F.trace({surface=surface,force='player',hub=hub})
  eq(tr.rows[1].blocked,nil); eq(tr.rows[1].reaches,5)
  defines,prototypes=nil,nil
end
print('d17_batch33 batch32 B5 ammunition blocked by other ammunition ahead: ok')

-- batch32 B7 (Gemini: robots with no storage): logistics_audit {storage}: storage room, robots holding cargo with no
-- order, their items and whether a storage chest can take each.
do
  defines={inventory={chest=1,robot_cargo=2}}
  local function chest(free,filter) return {valid=true,type='logistic-container',storage_filter=filter and {name=filter} or nil,
    get_inventory=function() return {count_empty_stacks=function() return free end} end} end
  local function robot(items,orders)
    return {robot_order_queue=orders or {},get_inventory=function()
      return {is_empty=function() return next(items)==nil end,get_contents=function() local out={} for n,c in pairs(items) do out[#out+1]={name=n,count=c} end return out end} end}
  end
  local ln={network_id=12,storages={chest(0,'iron-plate'),chest(3,'copper-plate')},
    logistic_robots={robot({['steel-plate']=4}),robot({['iron-plate']=2},{{}}),robot({})},construction_robots={robot({['iron-plate']=1})}}
  local L=dofile('mod/agent-harness_0.1.0/logaudit.lua'){state=function() return {} end}
  local r=L.storage({},{},{name='nauvis'},ln)
  eq(r.storage_chests,2); eq(r.free_slots,3); eq(r.full_chests,1); eq(r.robots_stuck,2)
  eq(r.line,'logistic network #12 on nauvis: 2 storage chests, 3 free slots (1 full), filtered: copper-plate 1, iron-plate 1; 2 robots hold cargo with nowhere to put it: iron-plate 1: its filtered storage chests are full and no unfiltered one has room; steel-plate 4: no storage chest has room for it (a free slot, unfiltered or filtered to it)')
  ln.storages[3]=chest(5,nil)
  has(L.storage({},{},{name='nauvis'},ln).line,'steel-plate 4: 1 storage chest can take it')
  defines=nil
end
print('d17_batch33 batch32 B7 network storage: ok')
