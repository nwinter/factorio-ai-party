-- d16 batch7 (operator 15:15, agents' requests 12:20-14:49). Run from the harness root: lua tests/d16_batch7.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,msg) assert(a==b,(msg or '')..' '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end

-- A3 (Haiku: belt_gaps refused a route with corners): a leg that is not straight follows the remembered belt from its
-- start, round its corners, across a gap toward the end; from the other end when the belt runs that way.
do
  game={tick=10}; defines={inventory={chest=1},direction={north=0}}
  local mem={}
  local f={name='player',is_chunk_visible=function() return true end}
  local list={}
  local s={name='nauvis',find_entities_filtered=function() return list end}
  game.forces={player=f}; game.surfaces={nauvis=s}
  local B=dofile('mod/agent-harness_0.1.0/beltgaps.lua'){state=function() return mem end,position=function(a) return a end}
  local function belt(x,y,dir)
    return {valid=true,name='transport-belt',type='transport-belt',position={x=x+.5,y=y+.5},direction=dir,force=f,surface=s,
      bounding_box={left_top={x=x+.1,y=y+.1},right_bottom={x=x+.9,y=y+.9}},get_item_count=function() return 1 end}
  end
  -- east along y=0 to x=4, south from (4,0) to (4,5) with (4,3) gone, then east to (6,5)
  for x=0,3 do list[#list+1]=belt(x,0,4) end
  list[#list+1]=belt(4,0,8); list[#list+1]=belt(4,1,8); list[#list+1]=belt(4,2,8); list[#list+1]=belt(4,4,8)
  list[#list+1]=belt(4,5,4); list[#list+1]=belt(5,5,4); list[#list+1]=belt(6,5,4)
  local p={force=f,surface=s,position={x=0,y=0}}
  local r=B.read(p,{from={x=.5,y=.5},to={x=6.5,y=5.5}})
  eq(r.tiles,12); eq(r.belts,11); eq(#r.missing,1); eq(r.missing[1].position.x,4.5); eq(r.missing[1].position.y,3.5)
  has(r.followed,'1 leg not straight: followed the remembered belt round its corners')
  -- from the downstream end: followed from the other end, the tiles in the order asked
  r=B.read(p,{from={x=6.5,y=5.5},to={x=.5,y=.5}})
  eq(r.tiles,12); eq(#r.missing,1)
  -- no belt remembered at either end: refused
  fails(function() B.read(p,{from={x=20.5,y=20.5},to={x=22.5,y=25.5}}) end,'not horizontal or vertical, and no belt remembered at either end')
  -- straight legs as before
  r=B.read(p,{from={x=.5,y=.5},to={x=3.5,y=.5}}); eq(r.belts,4); eq(r.followed,nil)
  defines=nil
end
print('d16_batch7 A3 belt_gaps follows corners: ok')

-- A8 (Sol 13:50: a long coolant collect woke the sleep every 30 s as queue_stalled): a collect standing at its machine
-- while the machine crafts is no stall; one whose machine stopped says so.
do
  game={tick=100}
  defines={entity_status={working=1,no_ingredients=2}}
  local st={active={}}
  local W=dofile('mod/agent-harness_0.1.0/waits.lua'){state=function() return st end,integer=function(v,d) return v or d end}
  local crafting=true
  local m={valid=true,name='chemical-plant',position={x=3.5,y=4.5},is_crafting=function() return crafting end,crafting_progress=0.4,
    status=1}
  st.active[1]={kind='gather',wait=true,item='fluoroketone-cold-barrel',got=12,targets={{entity=m,position=m.position}}}
  local w=W.collect_waiting(1)
  eq(w.working,true); has(w.line,'collect waits at chemical-plant (3.5,4.5) for fluoroketone-cold-barrel: the machine works: the products come as it crafts (status working, craft 40%), got 12 so far')
  crafting=false; m.status=2
  w=W.collect_waiting(1)
  eq(w.working,false); has(w.line,'the machine is not crafting (status no_ingredients')
  st.active[1]={kind='move_to'}
  eq(W.collect_waiting(1),nil)
  defines=nil
end
print('d16_batch7 A8 a collect waiting on a working machine: ok')

-- A9 (Sonnet 15:20: load_silo waits ran out with an ingredient missing): what the silo lacks of each rocket-part
-- ingredient, for the next part and the parts left.
do
  game={tick=0}
  defines={inventory={assembling_machine_input=2,rocket_silo_rocket=3}}
  local held={['processing-unit']=10,['low-density-structure']=3,['rocket-fuel']=0}
  local silo={valid=true,name='rocket-silo',type='rocket-silo',position={x=15.5,y=59.5},rocket_parts=48,prototype={rocket_parts_required=50},
    get_recipe=function() return {name='rocket-part',ingredients={{type='item',name='processing-unit',amount=10},{type='item',name='low-density-structure',amount=10},
      {type='item',name='rocket-fuel',amount=10}}} end,
    get_inventory=function(i) if i==2 then return {get_item_count=function(n) return held[n] or 0 end} end return nil end}
  local R=dofile('mod/agent-harness_0.1.0/rocketload.lua'){}
  local r=R.parts_short(silo)
  eq(#r.rows,2)
  eq(r.line,'the silo at (15.5,59.5) makes no part: low-density-structure: 7 short of the next part, 17 of the 2 parts left (its input holds 3); rocket-fuel: 10 short of the next part, 20 of the 2 parts left (its input holds 0)')
  held['low-density-structure']=20; held['rocket-fuel']=20
  eq(R.parts_short(silo),nil)
  -- switches as they stand (A12): load_silo never sets them
  silo.use_transitional_requests=false; silo.send_to_orbit_automatically=true
  eq(R.switches_text(silo),'automatic requests off, send to orbit automatically on')
  silo.use_transitional_requests=true
  has(R.switches_text(silo),'automatic requests on, send to orbit automatically on: the game fills and launches this silo\'s rockets for platforms\' requests')
  defines=nil
end
print('d16_batch7 A9 load_silo names the missing ingredient: ok')

-- A11 (Sol 15:22): a helper's train {stops, surface} was refused for the injected helper field.
do
  game={tick=0,train_manager={get_train_stops=function() return {} end,get_trains=function() return {} end},get_surface=function(n) return {name=n} end}
  local T=dofile('mod/agent-harness_0.1.0/trains.lua'){}
  local r=T.stops({surface={name='aquilo'},force={}},{stops=true,surface='nauvis',helper=true})
  eq(r.surface,'nauvis'); eq(r.count,0)
  fails(function() T.stops({surface={name='aquilo'},force={}},{stops=true,limit=3}) end,'stops takes surface only (not limit)')
end
print('d16_batch7 A11 a helper call reads train stops: ok')

-- B3 (Astra on Wren 4+ times): each chunk type from its collectors through inserters and belts to the crushers whose
-- recipe takes it and the hub; a static filter that keeps a collected type from its crusher; a crusher stopped full
-- while its output goes to a full hub.
do
  game={tick=0}
  defines={inventory={hub_main=1},entity_status={working=1,full_output=2}}
  prototypes={item={['metallic-asteroid-chunk']={},['oxide-asteroid-chunk']={},['iron-ore']={}}}
  local n=0
  local function ent(t) n=n+1; t.valid=true; t.unit_number=n; t.position=t.position or {x=n,y=0}; return t end
  local hub=ent{name='space-platform-hub',type='space-platform-hub',get_inventory=function() return {count_empty_stacks=function() return 0 end} end}
  local function crusher(recipe,ing,st) return ent{name='crusher',type='assembling-machine',status=st or 1,prototype={crafting_categories={crushing=true}},
    get_recipe=function() return {name=recipe,ingredients={{name=ing,amount=1}}} end} end
  local cm=crusher('metallic-asteroid-crushing','metallic-asteroid-chunk',2)
  local co=crusher('oxide-asteroid-crushing','oxide-asteroid-chunk')
  local b2=ent{name='transport-belt',type='transport-belt',belt_neighbours={outputs={}}}
  local b1=ent{name='transport-belt',type='transport-belt',belt_neighbours={outputs={b2}}}
  local col=ent{name='asteroid-collector',type='asteroid-collector',filter_slot_count=0}
  local function ins(from,to,filters,mode)
    return ent{name='inserter',type='inserter',pickup_target=from,drop_target=to,use_filters=filters~=nil,inserter_filter_mode=mode or 'whitelist',
      filter_slot_count=filters and #filters or 0,get_filter=function(k) return filters and filters[k] end,get_control_behavior=function() return nil end}
  end
  local list={ins(col,b1),ins(b1,cm),ins(b2,co,{'iron-ore'}),ins(b2,hub,nil),ins(cm,hub)}
  local s={find_entities_filtered=function(f)
    if f.type=='inserter' then return list elseif f.type=='asteroid-collector' then return {col} elseif f.type=='assembling-machine' then return {cm,co} end
    return {} end}
  local P=dofile('mod/agent-harness_0.1.0/platsupply.lua'){}
  local rows,flags=P.trace(s,{},hub)
  eq(rows[1],'metallic-asteroid-chunk: 1 collector; goes to crusher (2,0) metallic-asteroid-crushing, the hub (over 2 belt tiles)')
  eq(rows[2],'oxide-asteroid-chunk: 1 collector; goes to the hub (over 2 belt tiles)')
  has(flags[1],'inserter (9,0) (whitelist: iron-ore) takes from the belt (4,0) into crusher (3,0), whose recipe oxide-asteroid-crushing takes oxide-asteroid-chunk, and keeps it out')
  has(flags[#flags],'crusher (2,0) metallic-asteroid-crushing stopped with its output full; its output inserters drop into the hub, which has no free slot')
  defines,prototypes=nil,nil
end
print('d16_batch7 B3 platform_supply chunk trace: ok')

-- B5 (Sonnet, every shift): a shared fluid's users by recipe, their full-speed take and share.
do
  game={tick=0}
  defines={flow_precision_index={ten_minutes=2}}
  prototypes={item={},fluid={lubricant={}}}
  local function m(recipe,ings,prods,speed,working)
    return {valid=true,crafting_speed=speed,working=working,get_recipe=function() return {name=recipe,energy=10,ingredients=ings,products=prods} end}
  end
  local list={m('electric-engine-unit',{{type='fluid',name='lubricant',amount=15}},{},1,true),m('electric-engine-unit',{{type='fluid',name='lubricant',amount=15}},{},1,false),
    m('express-transport-belt',{{type='fluid',name='lubricant',amount=20}},{},2,true),m('lubricant',{},{{type='fluid',name='lubricant',amount=10}},1,true)}
  local surface={name='nauvis',find_entities_filtered=function() return list end}
  local force={get_fluid_production_statistics=function() return {get_flow_count=function(f) return f.category=='output' and 2100 or 1500 end} end}
  local S=dofile('mod/agent-harness_0.1.0/supply.lua'){status_name=function(e) return e.working and 'working' or 'fluid_ingredient_shortage' end}
  local lines=S.fluid_shares(surface,force,'lubricant')
  eq(lines[1],'lubricant on nauvis: used 210/min, made 150/min (last 10 min); 1 maker at full speed 60/min; its users at full speed 420/min:')
  eq(lines[2],'express-transport-belt: 1 machine (1 working) take 240/min at full speed, 57% of the users\' take')
  eq(lines[3],'electric-engine-unit: 2 machines (1 working) take 180/min at full speed, 43% of the users\' take')
  defines,prototypes=nil,nil
end
print('d16_batch7 B5 bottleneck fluid shares: ok')

-- B6 (Opus 13:51): the factory's shortages in one read.
do
  game={tick=0}
  defines={inventory={assembling_machine_input=2,furnace_source=2}}
  local function crafter(recipe,ing,st,held)
    return {valid=true,type='assembling-machine',name='assembling-machine-2',st=st,fluidbox={},
      get_recipe=function() return {name=recipe,ingredients={{type='item',name=ing,amount=2}}} end,
      get_inventory=function() return {get_item_count=function() return held or 0 end} end}
  end
  local list={crafter('copper-cable','copper-plate','item_ingredient_shortage'),crafter('copper-cable','copper-plate','item_ingredient_shortage'),
    crafter('engine-unit','steel-plate','item_ingredient_shortage',1),{valid=true,type='boiler',name='boiler',st='no_fuel'},
    {valid=true,type='lab',name='lab',st='missing_science_packs'},{valid=true,type='lab',name='lab',st='working'},
    {valid=true,type='mining-drill',name='electric-mining-drill',st='low_power'}}
  local owner={valid=true,type='logistic-container',get_item_count=function() return 10 end}
  local pt={owner=owner,targeted_items_deliver={{name='iron-plate',count=40}},filters={{name='iron-plate',count=100},{name='coal',count=5}}}
  local surface={name='nauvis',find_entities_filtered=function() return list end}
  local force={name='player',current_research={name='automation-2'},logistic_networks={nauvis={{requester_points={pt}}}}}
  local SH=dofile('mod/agent-harness_0.1.0/shortages.lua'){reuse=function(_,fn) return fn() end,status_name=function(e) return e.st end}
  local r=SH.read({surface=surface,force=force},{})
  eq(r.lines[1],'stopped short of an ingredient: copper-cable short of copper-plate (2 machines); engine-unit short of steel-plate (1 machine)')
  eq(r.lines[2],'no fuel: 1 boiler')
  eq(r.lines[3],'power: 1 machines on low power (1 electric-mining-drill), 0 on no power')
  eq(r.lines[4],'labs: 1 of 2 wait for science packs (research automation-2)')
  eq(r.lines[5],'requester chests lack (asked, less held and on the way): iron-plate 50')
  defines=nil
end
print('d16_batch7 B6 shortages: ok')

-- B8 (Sol, board #695): hits on our entities where our force sees, with the source, its position and facing.
do
  game={tick=600}
  local st={}
  local D=dofile('mod/agent-harness_0.1.0/damagelog.lua'){state=function() return st end,position=function(p) return p end,integer=function(v,d) return v or d end}
  local visible=true
  local force={name='player',is_chunk_visible=function() return visible end}
  local wall={valid=true,unit_number=7,name='stone-wall',force=force,surface={name='nauvis'},position={x=10.5,y=4.5}}
  local flamer={valid=true,name='flamethrower-turret',force={name='player'},position={x=14,y=4},direction=4}
  D.on_damaged{entity=wall,cause=flamer,damage_type={name='fire'},final_damage_amount=12,tick=600}
  D.on_damaged{entity=wall,cause=flamer,damage_type={name='fire'},final_damage_amount=12,tick=620}
  D.on_damaged{entity=wall,damage_type={name='acid'},final_damage_amount=5,tick=630}
  visible=false
  D.on_damaged{entity=wall,damage_type={name='acid'},final_damage_amount=5,tick=640}
  game.tick=900
  local h=D.of(wall)
  eq(#h,2)
  eq(h[1],'4s ago: 1 acid hit, 5 damage, from no source the game names (a fire or projectile that outlived it)')
  eq(h[2],'4s ago: 2 fire hits, 24 damage, from flamethrower-turret at (14,4) facing east')
  local r=D.read({surface={name='nauvis',find_entities_filtered=function() return {} end},position={x=10,y=4}},{radius=4})
  eq(#r.entities,1); eq(r.entities[1].alive,false); eq(#r.entities[1].hits,2)
end
print('d16_batch7 B8 damage log: ok')

-- C6 (Astra 13:50: Wren's salvage took about 60 deconstruct calls and a second pass): tiles to take up from the edge
-- in, leaving what stands, tile ghosts and underground spans, the rest joined.
do
  game={tick=0}
  local tiles={}
  for x=0,5 do for y=0,2 do tiles[#tiles+1]={position={x=x,y=y}} end end
  local belt={valid=true,type='transport-belt',bounding_box={left_top={x=0.1,y=1.1},right_bottom={x=0.9,y=1.9}}}
  local s={find_tiles_filtered=function() return tiles end,
    find_entities_filtered=function(f) if f.type=='tile-ghost' then return {{position={x=5.5,y=0.5}}} end return {belt} end}
  local hub={position={x=0.5,y=1.5}}
  local PP=dofile('mod/agent-harness_0.1.0/platplan.lua'){}
  local taken,areas=PP.salvage(s,{},hub,4)
  eq(#taken,4)
  for _,t in ipairs(taken) do
    assert(not (t.x==0 and t.y==1),'the belt\'s tile stays'); assert(not (t.x==5 and t.y==0),'the tile ghost\'s tile stays')
  end
  -- the farthest from the hub first: (5,2) before anything at x<=3
  eq(taken[#taken].y,2)
  assert(#areas<=#taken)
  -- every taken tile was on the edge and the rest stay joined: (4,1) is never taken while (5,1) stands alone
  local left={}
  for _,t in ipairs(tiles) do left[t.position.x..','..t.position.y]=true end
  for _,t in ipairs(taken) do left[t.x..','..t.y]=nil end
  local start,seen,stack,n='0,1',{['0,1']=true},{{0,1}},0
  while #stack>0 do
    local c=table.remove(stack); n=n+1
    for _,d in ipairs({{1,0},{-1,0},{0,1},{0,-1}}) do
      local k=(c[1]+d[1])..','..(c[2]+d[2])
      if left[k] and not seen[k] then seen[k]=true; stack[#stack+1]={c[1]+d[1],c[2]+d[2]} end
    end
  end
  local total=0; for _ in pairs(left) do total=total+1 end
  eq(n,total,'the foundation left is one piece')
end
print('d16_batch7 C6 platform_plan salvage: ok')

-- C8 (Astra 15:20): upgrade changes a ghost in place and marks a built entity, as the upgrade planner; another kind
-- is skipped.
do
  game={tick=0}
  prototypes={entity={['turbo-transport-belt']={fast_replaceable_group='transport-belt',collision_box={left_top={x=-0.4,y=-0.4},right_bottom={x=0.4,y=0.4}}},
    ['transport-belt']={fast_replaceable_group='transport-belt',collision_box={left_top={x=-0.4,y=-0.4},right_bottom={x=0.4,y=0.4}}},
    inserter={fast_replaceable_group='inserter',collision_box={left_top={x=-0.15,y=-0.15},right_bottom={x=0.15,y=0.15}}}}}
  local list={}
  local ghost={valid=true,type='entity-ghost',ghost_name='turbo-transport-belt',position={x=1.5,y=0.5}}
  ghost.order_upgrade=function(o) ghost.ghost_name=o.target; return true end
  local built={valid=true,type='transport-belt',name='turbo-transport-belt',position={x=2.5,y=0.5}}
  built.order_upgrade=function() built.marked=true; return true end
  local ins={valid=true,type='inserter',name='inserter',position={x=3.5,y=0.5},order_upgrade=function() error('not called') end}
  list={ghost,built,ins}
  local p={force={},surface={find_entities_filtered=function(f) if f.type=='entity-ghost' then return {ghost} end return list end}}
  local U=dofile('mod/agent-harness_0.1.0/upgrade.lua'){position=function(q) return q end,read_sight=function() end}
  local r=U.run(p,{area={left_top={x=0,y=0},right_bottom={x=8,y=2}},map={['turbo-transport-belt']='transport-belt',inserter='transport-belt'}})
  eq(r.ghosts_upgraded,1); eq(r.marked_for_upgrade,1); eq(ghost.ghost_name,'transport-belt'); eq(built.marked,true)
  has(r.skipped[1],'inserter (3.5,0.5): transport-belt is not of its kind')
  has(r.line,'1 built entity marked for upgrade (construction robots replace them with 1 transport-belt')
  prototypes=nil
end
print('d16_batch7 C8 upgrade: ok')

-- C9 (Astra 15:20): with automatic requests on, the open requests of platforms over this planet for the load.
do
  game={tick=0}
  defines={inventory={hub_main=1}}
  local function filters(list) return {sections_count=1,get_section=function() return {active=true,filters=list} end} end
  local hub={valid=true,get_inventory=function() return {get_item_count=function(n) return n=='space-platform-foundation' and 285 or 0 end} end,
    get_logistic_sections=function() return filters({{value={name='space-platform-foundation'},min=400,import_from={name='fulgora'}},
      {value={name='rocket'},min=100,import_from={name='nauvis'}},{value={name='holmium-plate'},min=50}}) end}
  local far={valid=true,name='Wren',space_location={name='vulcanus'},hub=hub}
  local here={valid=true,name='Von Braun',space_location={name='fulgora'},hub=hub}
  local silo={surface={name='fulgora',planet={name='fulgora'}},force={platforms={far,here}}}
  local R=dofile('mod/agent-harness_0.1.0/rocketload.lua'){}
  local open=R.open_requests(silo,{['space-platform-foundation']=true,rocket=true})
  eq(#open,1); eq(open[1],'Von Braun asks space-platform-foundation 400, holds 285 (115 short)')
  eq(#R.open_requests(silo,nil),2,'every request of the platform here, the rocket one from nauvis left out')
  defines=nil
end
print('d16_batch7 C9 open requests with automatic requests on: ok')

-- C1 (Astra 13:30): a platform renamed, and what still names the old name; nothing of theirs changed.
do
  game={tick=0}
  local pl={valid=true,name='Von Braun'}
  local st={queues={[5]={current={action='load_silo',args={platform='Von Braun'}},pending={{action='wait_until',args={['until']='platform_arrived',platform='Von Braun'},label='wait'},{action='craft',args={recipe='Von Braunite'}}}}},
    board={items={[697]={kind='task',status='open',title='Build Von Braun transport'},[698]={kind='note',status='done',title='Von Braun old'}}}}
  local R=dofile('mod/agent-harness_0.1.0/platrename.lua'){state=function() return st end,platform=function() return pl end,name_of=function(i) return i==5 and 'astra' or nil end}
  local p={force={platforms={pl,{valid=true,name='Wren'}}}}
  local r=R.rename(p,{platform='Von Braun',name='Braun II'})
  eq(pl.name,'Braun II'); eq(r.was,'Von Braun'); eq(#r.still_named,3)
  eq(r.still_named[1],'astra\'s queue: pending step 1 wait_until (wait)')
  eq(r.still_named[2],'astra\'s queue: the running step load_silo')
  has(r.still_named[3],'board #697 (task)')
  eq(st.queues[5].current.args.platform,'Von Braun','nothing of theirs changed')
  fails(function() R.rename(p,{platform='Braun II',name='Wren'}) end,'another platform of ours is named Wren')
  eq(R.names('the Von Braunite mine','Von Braun'),false)
end
print('d16_batch7 C1 platform_rename: ok')
