-- d18 batch37. Run from the harness root: lua tests/d18_batch37.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end

-- A1-A3 (Opus about 10 times with a 16-call grid script; Astra 4+; Haiku: which shell maker lacked what): every maker of
-- an item on the surface, nearest first, with status and why, rate, inputs against one craft, and what it feeds.
do
  defines={inventory={assembling_machine_input=2,assembling_machine_output=3,furnace_source=4,furnace_result=5},entity_status={disabled_by_control_behavior=9}}
  local shell={name='artillery-shell',energy=15,products={{type='item',name='artillery-shell',amount=1}},
    ingredients={{type='item',name='explosive-cannon-shell',amount=4},{type='item',name='radar',amount=1},{type='item',name='explosives',amount=8}}}
  prototypes={item={['artillery-shell']={}},recipe={['artillery-shell']=shell,['iron-plate']={products={{name='iron-plate',amount=1}}}}}
  local surface={name='nauvis'}
  local force={}
  local function machine(id,x,y,status,inputs,out)
    local e={valid=true,unit_number=id,name='assembling-machine-2',type='assembling-machine',force=force,surface=surface,position={x=x,y=y},
      bounding_box={left_top={x=x-1.5,y=y-1.5},right_bottom={x=x+1.5,y=y+1.5}},crafting_speed=0.75,productivity_bonus=0,status=status}
    e.get_inventory=function(i) local t=i==2 and inputs or {['artillery-shell']=out or 0}; return {get_item_count=function(n) return t[n] or 0 end} end
    return e
  end
  local m1=machine(1,10,0,'working',{['explosive-cannon-shell']=8,radar=2,explosives=16},2)
  local m2=machine(2,40,0,'item_ingredient_shortage',{['explosive-cannon-shell']=1,radar=1,explosives=8},0)
  local m3=machine(3,-80,0,'disabled_by_control_behavior',{},0)
  local chest={valid=true,name='requester-chest',position={x=10,y=3}}
  local out_ins={valid=true,name='inserter',position={x=10,y=2},pickup_target=m1,drop_target=chest,status=1}
  local in_ins={valid=true,name='inserter',position={x=40,y=-2},drop_target=m2,status=9}
  surface.find_entities_filtered=function(f) if f.area[1][1]<12 and f.area[1][1]>5 then return {out_ins} elseif f.area[1][1]>30 then return {in_ins} end return {} end
  local M=dofile('mod/agent-harness_0.1.0/makersall.lua'){status_name=function(e) return e.status end,
    state_text=function(e) return e==m3 and 'off by its logistic condition explosives > 100 (network holds 40)' or 'off by its circuit condition signal-A > 0 (signal-A 0 on its wires)' end,
    census_makers=function() return {craft={['artillery-shell']={m2,m3,m1}}} end}
  eq(M.recipes_of('artillery-shell')[1],'artillery-shell')
  local r=M.read({surface=surface,position={x=0,y=0},force=force},'artillery-shell',surface,{makers='all'})
  eq(r.makers,3); eq(r.rows[1].position.x,10,'nearest first')
  eq(r.lines[1],'assembling-machine-2 (10,0) artillery-shell: working; 3 a minute; inputs explosive-cannon-shell 8/4, radar 2/1, explosives 16/8; output holds 2 artillery-shell; feeds requester-chest (10,3) (by inserter (10,2))')
  has(r.lines[2],'assembling-machine-2 (40,0) artillery-shell: item ingredient shortage (input inserter (40,-2) off by its circuit condition signal-A > 0 (signal-A 0 on its wires)); 0 a minute; inputs explosive-cannon-shell 1/4')
  has(r.lines[3],'disabled by control behavior (off by its logistic condition explosives > 100 (network holds 40))')
  eq(r.rows[2].short[1],'explosive-cannon-shell')
  has(r.line,'3 machines on nauvis make artillery-shell (3 artillery-shell): 1 disabled_by_control_behavior, 1 item_ingredient_shortage, 1 working')
  -- paged
  M.PAGE=2
  r=M.read({surface=surface,position={x=0,y=0},force=force},'artillery-shell',surface,{makers='all'})
  eq(#r.rows,2); eq(r.next_from,3)
  r=M.read({surface=surface,position={x=0,y=0},force=force},'artillery-shell',surface,{makers='all',from=3})
  eq(#r.rows,1); eq(r.next_from,nil)
  fails(function() M.read({surface=surface,force=force},'artillery-shell',surface,{makers=true}) end,'makers is "all"')
  defines,prototypes=nil,nil
end
print('d18_batch37 A1-A3 every maker of an item: ok')

-- A2 (Opus): makers_worst names a machine's own enable condition when it is disabled_by_control_behavior; it ranks with
-- the gated ones, so three short machines no longer hide it.
do
  defines={inventory={assembling_machine_input=2,assembling_machine_output=3,furnace_source=4,furnace_result=5},entity_status={disabled_by_control_behavior='disabled_by_control_behavior'}}
  local recipe={name='low-density-structure',ingredients={{type='item',name='steel-plate',amount=2}}}
  local function m(x,status) return {valid=true,unit_number=x,name='assembling-machine-2',position={x=x,y=0},status=status,
    get_inventory=function() return {get_item_count=function() return 0 end} end} end
  local list={}
  for i=1,3 do list[#list+1]={e=m(i,'item_ingredient_shortage'),recipe=recipe} end
  list[#list+1]={e=m(9,'disabled_by_control_behavior'),recipe=recipe}
  local S=dofile('mod/agent-harness_0.1.0/supply.lua'){status_name=function(e) return e.status end,
    state_text=function() return 'off by its logistic condition low-density-structure < 400 (network holds 900)' end}
  local _,worst=S.machines({item='low-density-structure',spots={}},list,'makers',{},nil)
  has(worst[1],'(9,0) assembling-machine-2 disabled_by_control_behavior (off by its logistic condition low-density-structure < 400 (network holds 900))')
  defines=nil
end
print('d18_batch37 A2 a machine off by its own condition among the worst: ok')

-- B1 (Sonnet: calcite in chests the silo's network could not give; Grok: 16,000 copper ore in plain chests on Gleba):
-- where a surface holds an item no network gives, from the census lists.
do
  game={tick=100}
  local function chest(id,x,y,typ,mode,n,ln)
    return {valid=true,unit_number=id,name=typ=='container' and 'steel-chest' or mode..'-chest',type=typ,position={x=x,y=y},
      prototype={logistic_mode=mode},logistic_network=ln,get_item_count=function() return n end}
  end
  local net5,net7={network_id=5},{network_id=7}
  local chests={chest(1,30,0,'container',nil,5200),chest(2,10,0,'container',nil,4000),chest(3,5,0,'logistic-container','requester',98),
    chest(4,50,0,'logistic-container','passive-provider',300,net7),chest(5,60,0,'logistic-container','passive-provider',20,net5),
    chest(6,70,0,'logistic-container','passive-provider',7,nil)}
  local furnace={valid=true,name='stone-furnace',position={x=2,y=2},get_output_inventory=function() return {get_item_count=function() return 12 end} end}
  local E=dofile('mod/agent-harness_0.1.0/elsewhere.lua'){chests=function() return chests end,crafters=function() return {furnace} end}
  local surface={index=3,name='gleba'}
  local line,total=E.line({name='player'},surface,'copper-ore',nil,{x=0,y=0})
  eq(total,9317)
  eq(line,'gleba holds 9317 copper-ore outside the logistic networks\' providers and storage: plain chests 9207 in 3 (no network gives them; nearest steel-chest (10,0) 4000, steel-chest (30,0) 5200, passive-provider-chest (70,0) 7); requester and buffer chests 98 in 1 (theirs; nearest requester-chest (5,0) 98); machine outputs 12 in 1 (nearest stone-furnace (2,2) 12)')
  -- from network 5 (a silo's): network 7's providers count, network 5's do not
  game.tick=5000
  line=E.line({name='player'},surface,'copper-ore',net5,{x=0,y=0})
  has(line,'that network 5 cannot give'); has(line,'network 7\'s provider and storage chests 300 in 1'); assert(not line:find('network 5\'s',1,true),line)
  has(E.line({name='player'},surface,'copper-ore',net5,{x=0,y=0},true),'plain chests 9207')
  assert(not E.line({name='player'},surface,'copper-ore',net5,{x=0,y=0},true):find('network 7',1,true))
  game=nil
end
print('d18_batch37 B1 where a surface holds what no network gives: ok')

-- B2 (Gemini 16:53: Kestrel II waiting for 500 carbon fiber at Fulgora): each stop's item wait against the planet's stock
-- and its production a minute over the last 10 minutes.
do
  defines={flow_precision_index={ten_minutes=3}}
  prototypes={item={['carbon-fiber']={},['iron-plate']={}}}
  local made={['carbon-fiber']=0,['iron-plate']=600}
  local fulgora={index=4,name='fulgora'}
  game={planets={fulgora={surface=fulgora},nauvis={surface={index=1,name='nauvis'}}}}
  local force={logistic_networks={fulgora={{get_item_count=function(n) return n=='carbon-fiber' and 120 or 0 end}},nauvis={}},
    get_item_production_statistics=function() return {get_flow_count=function(t) assert(t.category=='input' and t.count); return made[t.name] end} end}
  local pl={force=force,hub={valid=true,get_item_count=function(n) return n=='carbon-fiber' and 80 or 0 end},
    schedule={records={{station='fulgora',wait_conditions={{type='item_count',condition={first_signal={name='carbon-fiber'},comparator='≥',constant=500}}}},
      {station='nauvis',wait_conditions={{type='item_count',condition={first_signal={name='iron-plate'},comparator='≥',constant=600}},{type='time',ticks=600,compare_type='or'}}}}}}
  local N=dofile('mod/agent-harness_0.1.0/launchneed.lua'){elsewhere=function(_,s,item) return 'x',item=='carbon-fiber' and 30 or 0 end}
  local lines=N.wait_lines(pl)
  eq(lines[1],'stop 1 (fulgora) waits for carbon-fiber >= 500: the hub holds 80, 420 short; fulgora holds 150 (120 in its logistic networks, 30 outside them) and made 0 a minute over the last 10 min: not met at this rate')
  eq(lines[2],'stop 2 (nauvis) waits for iron-plate >= 600: the hub holds 0, 600 short; nauvis holds 0 (0 in its logistic networks, 0 outside them) and made 60 a minute over the last 10 min: about 10 min at this rate')
  defines,prototypes,game=nil,nil,nil
end
print('d18_batch37 B2 a stop item wait against stock and production: ok')

-- B3 (Grok: Spindle's hub filled with ore twice; the science rocket could not board): a team alert once per wait.
do
  defines={space_platform_state={waiting_at_station=4,on_the_path=3},inventory={hub_main=1}}
  local inv={}
  for i=1,3 do inv[i]={valid_for_read=true,name='copper-ore',count=50} end
  inv[4]={valid_for_read=true,name='iron-ore',count=50}
  inv[5]={valid_for_read=false}
  local gleba={index=3}
  game={tick=0,planets={gleba={surface=gleba}},forces={}}
  local pl={valid=true,index=2,name='Spindle',state=4,space_location={name='gleba'},force={},hub={get_inventory=function() return inv end}}
  game.forces.player={platforms={pl}}
  local silo={valid=true,position={x=65.5,y=14.5}}
  local told={}
  local H=dofile('mod/agent-harness_0.1.0/hubfull.lua'){state=(function() local st={} return function() return st end end)(),
    silos=function() return {silo} end,request_rows=function(e,f,only) assert(only=='Spindle'); return {{flag='hub_full',item='agricultural-science-pack',hub_free_slots=1,slots_for_payload=5}} end,
    listeners=function() return {{name='grok',index=7}} end,deliver=function(i,t) told[#told+1]={i=i,t=t} end}
  local line=H.check(pl)
  eq(line,'hub full: Spindle waits at gleba with 1 free hub slots; the agricultural-science-pack payload a rocket from rocket-silo (65.5,14.5) waits for takes 5; the hub holds copper-ore 150 (3 slots), iron-ore 50 (1 slots)')
  eq(#told,1); eq(told[1].i,7); eq(told[1].t.wake,true)
  eq(H.check(pl),nil,'once per wait'); eq(#told,1)
  pl.state=3; H.check(pl); pl.state=4
  H.check(pl); eq(#told,2,'a new wait tells again')
  defines,game=nil,nil
end
print('d18_batch37 B3 a hub too full for its payload: ok')


-- C2 (viewer Aurora 16:57): the flare's reply says which range holds each piece, and 10 s on whether a shot followed.
do
  defines={inventory={artillery_turret_ammo=1,artillery_wagon_ammo=2},flow_precision_index={one_minute=1,ten_minutes=3}}
  game={tick=0,surfaces={}}
  local shells={a=5,b=3}
  local function piece(key,x)
    return {valid=true,name='artillery-turret',type='artillery-turret',position={x=x,y=0},force={artillery_range_modifier=0},
      prototype={manual_range_modifier=2.5,guns={{attack_parameters={range=224,min_range=32}}}},
      get_inventory=function() return {get_contents=function() return {{name='artillery-shell',count=shells[key]}} end} end}
  end
  local pa,pb=piece('a',0),piece('b',-300)
  local flare={valid=true}
  local surface={index=1,name='nauvis',create_entity=function() return flare end,
    find_entities_filtered=function(f) if f.type=='artillery-projectile' then return {{}} end if f.type=='inserter' then return {} end return {pa,pb} end}
  game.surfaces[1]=surface
  local st,told={},{}
  local force={technologies={artillery={researched=true}},is_chunk_charted=function() return true end,valid=true,
    get_item_production_statistics=function() return {get_flow_count=function() return 2 end} end}
  local A=dofile('mod/agent-harness_0.1.0/artillery.lua'){position=function(q) return q end,held=function() return 1 end,state=function() return st end,
    deliver=function(i,t) told[#told+1]={i=i,t=t} end}
  local p={index=5,surface=surface,force=force}
  local r=A.remote(p,{item='artillery-targeting-remote',position={x=200,y=0}},{})
  has(r.in_range[1],'artillery-turret (0,0) 200 tiles, in its automatic range too, 5 shells')
  has(r.in_range[2],'artillery-turret (-300,0) 500 tiles, in its manual range only (560; automatic 224), 3 shells')
  has(r.confirm,'in 10 s your team block says whether a shot followed')
  game.tick=300; A.tick(); eq(#told,0,'not yet')
  shells.a=4; flare.valid=false; game.tick=601; A.tick()
  eq(told[1].i,5)
  eq(told[1].t.text,'artillery flare at (200,0), 10 s on: the flare is gone (its shots were taken); shells gone from artillery-turret (0,0) 5 -> 4 shells; 1 projectile in the air within 64 tiles of it')
  eq(st.artillery_checks,nil)
  defines,game=nil,nil
end
print('d18_batch37 C2 artillery ranges and the shot confirmed: ok')
-- The runtime against a fake engine (as tests/d17_batch35.lua sets it up), for the calls below.
storage={agent_harness={active={}}}
defines={events={on_script_path_request_finished=10,on_entity_died=11,on_entity_damaged=12,on_console_chat=13,on_unit_group_finished_gathering=14},
  shooting={not_shooting=0,shooting_enemies=1},controllers={character=1,remote=27,spectator=2},direction={north=0},
  inventory={chest=1,character_main=1,character_guns=3,character_ammo=4},
  build_mode={normal=1},build_check_type={manual=1},flow_precision_index={five_seconds=0,one_minute=1}}
prototypes={item={['submachine-gun']={type='gun',attack_parameters={ammo_categories={'bullet'},range=18}},
  ['rocket-launcher']={type='gun',attack_parameters={ammo_categories={'rocket'},range=36}},
  ['firearm-magazine']={type='ammo',ammo_category={name='bullet'}},rocket={type='ammo',ammo_category={name='rocket'}},
  ['iron-plate']={type='item'}}}
local drawn={}
rendering={draw_text=function() local obj={valid=true}; obj.destroy=function() obj.valid=false end; drawn[#drawn+1]=obj; return obj end,
  get_object_by_id=function(id) return drawn[id] end}
remote={interfaces={}}
helpers={json_to_table=function(t) return t end}
local force={name='player',get_friend=function() return false end,get_cease_fire=function() return false end,chart=function() end,
  is_chunk_visible=function() return true end,is_chunk_charted=function() return true end,get_spawn_position=function() return {x=0,y=0} end}
local surface={name='nauvis',index=1}
local units=0
local function character(pos)
  units=units+1
  local c={valid=true,name='character',type='character',force=force,surface=surface,position=pos,unit_number=500+units,health=250,max_health=250,
    prototype={collision_box={left_top={x=-0.2,y=-0.2},right_bottom={x=0.2,y=0.2}},collision_mask={layers={player=true}}},
    driving=false,build_distance=10,reach_distance=10,character_running_speed=0.15,walking_state={walking=false},selected_gun_index=1}
  c.insert=function(s) return s.count end
  c.get_item_count=function() return 0 end
  c.can_reach_entity=function() return true end
  c.destroy=function() c.valid=false end
  return c
end
surface.find_non_colliding_position=function(_,origin) return origin end
surface.create_entity=function(args) if args.name=='character' then return character(args.position) end return {valid=true,name=args.name,position=args.position} end
surface.can_place_entity=function() return true end
surface.find_entities_filtered=function() return {} end
surface.get_total_pollution=function() return 0 end; surface.get_chunks=function() return function() end end; surface.get_pollution=function() return 0 end
surface.request_path=function() return 1 end
local players={}
local tick=0
game={tick=0,players=players,forces={player=force,enemy={name='enemy',get_evolution_factor=function() return 0 end,get_evolution_factor_by_time=function() return 0 end,
  get_evolution_factor_by_pollution=function() return 0 end,get_evolution_factor_by_killing_spawners=function() return 0 end}},
  get_player=function(i) if type(i)=='string' then for _,p in ipairs(players) do if p.name==i then return p end end return nil end return players[i] end,
  get_surface=function() return surface end,print=function() end,connected_players=players,
  get_pollution_statistics=function() return {input_counts={},output_counts={},get_flow_count=function() return 0 end} end}
local runtime=dofile('mod/agent-harness_0.1.0/runtime.lua')
local function advance(n) for _=1,n do tick=tick+1; game.tick=tick; runtime.tick{tick=tick} end end
local function request(req)
  local ok,result=pcall(runtime.dispatch,req)
  if not ok then
    if req.bot then pcall(runtime.stop_player,runtime.bots.index_of(req.bot)) end
    error(result,0)
  end
  return result
end
local function as(name) return function(action,args) return request{action=action,args=args or {},bot=name} end end
local grok=as('grok')
runtime.operator.bot_create('grok')
local body=runtime.lookup(runtime.bots.index_of('grok')).character


-- C3 (Muse, daily: a direct call paused the running queue and left it paused): queue_resume_after on the call, or the
-- queue's resume_after_direct, runs the queue again when the call ends.
do
  surface.find_entities_filtered=function() return {} end
  body.position={x=0,y=0}
  local function running() local q=grok('queue_status',{}); return q.paused==false end
  grok('queue_submit',{steps={{action='move_to',args={position={x=200,y=0},pathfind=false}},{action='wait_ticks',args={ticks=10}}}})
  advance(3); assert(running())
  -- a failed direct call: paused, then running again at once
  local ok,err=pcall(grok,'move_to',{position={x=5,y=5},unsafe_goal='yes',queue_resume_after=true})
  assert(not ok); has(err,'your queue, paused by this call, runs again (queue_resume_after)')
  assert(running(),'resumed after the failure')
  -- a direct walk: the queue runs again when it ends
  advance(3)
  local r=grok('move_to',{position={x=3,y=0},pathfind=false,queue_resume_after=true})
  eq(r.queue_resumes,'your queue, paused by this call, runs again when it ends (queue_resume_after)')
  assert(not running(),'paused while the walk runs')
  body.position={x=3,y=0}; advance(30)
  assert(running(),'resumed when the walk ended')
  eq(grok('status',{}).last.queue_resumed,'your queue, paused by this call, runs again now (queue_resume_after)')
  -- without it the queue stays paused, as before
  advance(3)
  pcall(grok,'move_to',{position={x=5,y=5},unsafe_goal='yes'})
  assert(not running())
  -- the queue's own setting
  grok('queue_submit',{mode='replace',resume_after_direct=true,steps={{action='wait_ticks',args={ticks=600}}}})
  advance(2)
  pcall(grok,'move_to',{position={x=5,y=5},unsafe_goal='yes'})
  assert(running(),'resume_after_direct')
  grok('queue_cancel',{})
end
print('d18_batch37 C3 a queue paused by a direct call runs again when it ends: ok')

-- C2 (Muse about 6 times): the remote on another surface is refused, saying what is known of the game's rule.
do
  prototypes.item['artillery-targeting-remote']={capsule_action={type='artillery-remote'}}
  local ok,err=pcall(grok,'use_item',{item='artillery-targeting-remote',position={x=1,y=1},surface='aquilo'})
  assert(not ok); has(err,'use_item acts where your character is (nauvis)'); has(err,'is not established')
end
print('d18_batch37 C2 the remote on another surface refused: ok')

-- C1 (Sonnet: 10+ chained transfers a brick cycle; a failure mid-chain left items in the pack): transfer {steps} walks
-- takes and gives in one call; a failure says what is held and the steps left; on_fail "return" gives it back.
do
  -- slot inventories: stores are {item=count} views kept in step with the slots
  local function inv_of(store,n)
    local inv={valid=true}
    local function sync() for k in pairs(store) do store[k]=nil end; for i=1,#inv do local sl=inv[i]; if sl.valid_for_read then store[sl.name]=(store[sl.name] or 0)+sl.count end end end
    local function slot()
      local sl={valid_for_read=false,count=0,quality={name='normal'}}
      sl.transfer_stack=function(src,k)
        k=math.min(k or src.count,src.count)
        if sl.valid_for_read and sl.name~=src.name then return false end
        local room=100-sl.count; k=math.min(k,room)
        if k<=0 then return false end
        sl.name=src.name; sl.count=sl.count+k; sl.valid_for_read=true
        src.count=src.count-k; if src.count<=0 then src.valid_for_read=false; src.count=0; src.name=nil end
        src.owner_sync(); sync()
        return true
      end
      sl.owner_sync=sync
      return sl
    end
    for i=1,n or 8 do inv[i]=slot() end
    for k,v in pairs(store) do
      local left=v
      for i=1,#inv do if left<=0 then break end; local sl=inv[i]; if not sl.valid_for_read then local c=math.min(100,left); sl.name=k; sl.count=c; sl.valid_for_read=true; left=left-c end end
    end
    inv.get_item_count=function(q) local nm=type(q)=='table' and q.name or q; sync(); if nm then return store[nm] or 0 end; local t=0; for _,v in pairs(store) do t=t+v end; return t end
    inv.get_contents=function() sync(); local out={}; for k,v in pairs(store) do if v>0 then out[#out+1]={name=k,count=v,quality='normal'} end end return out end
    inv.is_empty=function() sync(); return next(store)==nil end
    inv.can_insert=function() return true end
    inv.get_insertable_count=function() return 1000 end
    inv.set=function(k,v) for i=1,#inv do local sl=inv[i]; if sl.name==k then sl.valid_for_read=false; sl.count=0; sl.name=nil end end
      if v>0 then for i=1,#inv do local sl=inv[i]; if not sl.valid_for_read then sl.name=k; sl.count=v; sl.valid_for_read=true; break end end end; sync() end
    return inv
  end
  local pack={}
  local chests={}
  local function chest(x,y,store)
    local e={valid=true,name='wooden-chest',type='container',force=force,surface=surface,position={x=x,y=y},unit_number=900+#chests,
      prototype={type='container'},store=store}
    local inv=inv_of(store)
    e.inv=inv
    e.get_inventory=function() return inv end
    e.get_output_inventory=function() return inv end
    e.get_item_count=inv.get_item_count
    chests[#chests+1]=e
    return e
  end
  local a=chest(1,0,{['iron-plate']=30})
  local b=chest(2,0,{['iron-plate']=10})
  local c=chest(3,0,{})
  local d=chest(4,0,{})
  surface.find_entities_filtered=function(f)
    local out={}
    for _,e in ipairs(chests) do
      local pos=f.position
      if e.valid and pos and math.abs(e.position.x-pos.x)<0.6 and math.abs(e.position.y-pos.y)<0.6 then out[#out+1]=e end
    end
    return out
  end
  local main=inv_of(pack,16)
  body.get_main_inventory=function() return main end
  body.get_inventory=function() return main end
  body.get_item_count=main.get_item_count
  body.position={x=2,y=1}
  -- the shape refused before any walk
  fails(function() grok('transfer',{steps={{take={{x=1,y=0}},give={{x=3,y=0}},item='iron-plate'}}}) end,'takes take or give')
  fails(function() grok('transfer',{steps={{take={{x=1,y=0}},item='iron-plate',split='even'}}}) end,'split is for a give')
  fails(function() grok('transfer',{steps={{take={{x=1,y=0}},item='iron-plate'}},on_fail='drop'}) end,'on_fail is "return"')
  local r=grok('transfer',{steps={{take={{x=1,y=0},{x=2,y=0}},item='iron-plate',count=35},{give={{x=3,y=0},{x=4,y=0}},item='iron-plate',split='even'}}})
  has(r.chain,'step 1: take iron-plate at 2 chests (35 in all)'); has(r.chain,'step 2: give iron-plate at 2 chests (even)'); eq(r.legs,4)
  advance(30)
  local last=grok('status',{}).last
  eq(last.outcome,'transferred','chain outcome')
  eq(a.inv.get_item_count('iron-plate'),0); eq(b.inv.get_item_count('iron-plate'),5)
  eq(c.inv.get_item_count('iron-plate'),18); eq(d.inv.get_item_count('iron-plate'),17)
  eq(last.chain_held,'none of its items'); eq(last.chain_left,nil)
  -- a failed leg: the steps left, what is held, and on_fail "return" gives it back where it came from
  a.inv.set('iron-plate',20)
  b.valid=false
  grok('transfer',{steps={{take={{x=1,y=0}},item='iron-plate'},{give={{x=2,y=0}},item='iron-plate'},{give={{x=3,y=0}},item='iron-plate'}},on_fail='return'})
  for _=1,30 do advance(1); if grok('status',{}).last.outcome=='failed' then break end end
  last=grok('status',{}).last
  eq(last.outcome,'failed','failed chain'); has(last.chain_held,'iron-plate 20')
  has(last.chain_left[1],'step 2 give iron-plate at (2,0)'); has(last.chain_left[2],'step 3 give iron-plate at (3,0)')
  has(last.chain_return,'goes back to 1 chest')
  advance(40)
  eq(a.inv.get_item_count('iron-plate'),20,'returned'); eq(pack['iron-plate'] or 0,0)
  last=grok('status',{}).last
  eq(last.outcome,'transferred'); eq(last.chain_failed.outcome,'failed'); has(last.chain_failed.left[1],'step 2 give')
  has(last.started_by,'on_fail "return" of a transfer chain that ended failed')
end
print('d18_batch37 C1 a chain of transfers in one call: ok')

-- D4 (viewer Aurora 18:11: hidden unload plans read as missing automation): every agent's queued or running jobs that
-- act on or wait on a platform, read only.
do
  local st=storage.agent_harness
  local gi=runtime.bots.index_of('grok')
  st.queues=st.queues or {}
  st.queues[gi]={revision=1,sequence=3,paused=false,history={{action='drop',ok=true,args={platform='Kestrel II'},result={dropped={'carbon-fiber*100'}},finished_tick=game.tick}},
    current={id=2,action='wait_until',args={['until']='item_count',platform='Kestrel II',item='carbon-fiber',at_least=500},started_tick=game.tick,saw={line='hub holds 120'}},
    pending={{id=3,action='drop',args={platform='Kestrel II',items={{item='carbon-fiber',count=500}}}},{id=4,action='move_to',args={position={x=1,y=1}}}}}
  st.platform_lanes={['Kestrel II']=true}
  st['lane_queues|Kestrel II']={[gi]={revision=1,sequence=1,paused=true,history={},pending={{id=1,action='platform_schedule',args={platform='Kestrel II'}}}}}
  local lines=runtime.platjobs.lines('Kestrel II')
  eq(#lines,2)
  has(lines[1],'grok, lane body: now: wait_until item_count carbon-fiber >= 500 on Kestrel II, running, waiting since 0s ago; saw hub holds 120')
  has(lines[1],'pending #1: drop carbon-fiber*500'); assert(not lines[1]:find('move_to'),lines[1])
  has(lines[1],'1 drop so far (1 ok, 0 failed); last carbon-fiber*100')
  has(lines[2],'grok, lane platform:Kestrel II: pending #1: platform_schedule')
  has(runtime.platjobs.lines('Petrel')[1],'no agent has a queued or running job that acts on or waits on Petrel')
  st.queues[gi]=nil; st['lane_queues|Kestrel II']=nil; st.platform_lanes=nil
end
print('d18_batch37 D4 every agent\'s jobs on a platform: ok')

-- U1 (Haiku: a 480-tile rearm leg cut at once with enemies_ahead, retry_when_clear or not): with ahead_wait the tour
-- waits where it stands, rechecks, and walks on when the leg clears; enemies_ahead only when the wait runs out.
do
  local saved=game
  game={tick=0}
  local function distance(a,b) return ((a.x-b.x)^2+(a.y-b.y)^2)^0.5 end
  local f={}
  local p={force=f,position={x=0,y=0},reach_distance=10}
  local t1={valid=true,type='ammo-turret',name='gun-turret',force=f,position={x=5,y=0}}
  local t2={valid=true,type='ammo-turret',name='gun-turret',force=f,position={x=60,y=0}}
  local threat,checks=nil,0
  local S=dofile('mod/agent-harness_0.1.0/stock.lua'){distance=distance,integer=function(v,d) return v or d end,
    goal_inside=function() return nil end,goal_check=function() return nil end,goal_text=function() return 'place' end,
    leg_threat=function(_,from,to) if to.x==60 then checks=checks+1; if threat then return {line='the leg from (5,0) to (60,0) passes enemy group of 9'} end end end,
    visit=function() return {transferred=10} end,can_reach=function() return true end,
    request_path=function(_,nav) nav.requested=true end,navigate=function() p.position={x=60,y=0}; return 'arrived' end,stop_walking=function() end}
  p.can_reach_entity=function(e) return distance(p.position,e.position)<=10 end
  -- clears after 10 s: it waited and went on
  local action=S.start_tour(p,'rearm',{t1,t2},3600,{avoid_mode={},ahead_wait=3600})
  threat=true
  local r
  for _=1,600 do game.tick=game.tick+1; r=S.tick(p,action); if r then break end end
  eq(r,nil,'still waiting at 10 s'); assert(checks>=3 and checks<=5,'rechecked every 3 s: '..checks)
  eq(action.until_tick,3600+3600+0,'the wait does not eat the tour time')
  threat=nil
  for _=1,400 do game.tick=game.tick+1; r=S.tick(p,action); if r then break end end
  assert(r~='enemies_ahead',tostring(r))
  has(action.ahead_waited[1],'waited 1'); has(action.ahead_waited[1],'before stop 2 of 2, then went on: the leg from (5,0) to (60,0) passes enemy group of 9')
  -- not clear within the wait: enemies_ahead, saying how long it waited
  p.position={x=0,y=0}
  action=S.start_tour(p,'rearm',{t1,t2},3600,{avoid_mode={},ahead_wait=600})
  threat=true
  for _=1,1200 do game.tick=game.tick+1; r=S.tick(p,action); if r then break end end
  eq(r,'enemies_ahead'); has(action.enemies_ahead,'1 of 2 stops done; waited 10 s for it to clear (the most: 10 s)')
  game=saved
end
print('d18_batch37 U1 a tour waits for a leg enemies pass: ok')

-- U2 (Haiku: wait --until alert woke 1 s apart, again and again, as one attack's hits grew): an attack known when the
-- wait began wakes it only when it changed (more attackers, a loss near it); its repeats are held and said.
do
  local saved=game
  game={tick=1000}
  local st={damage={},attack_groups={},losses={},alert_seq=5,loss_seq=2}
  local U=dofile('mod/agent-harness_0.1.0/urgent.lua'){state=function() return st end,who=function(p) return p.name end}
  local p={index=7,name='haiku',surface={name='nauvis'},character={valid=true,position={x=0,y=0}},force={platforms={}}}
  st.damage.a={id=8793,at={x=-48,y=396},damage=60,hits=1,size=7,seq=5,surface='nauvis'}
  local known=U.alert_known(p)
  eq(known.areas[8793],7)
  -- more hits, the same attackers: held
  st.damage.a.hits=6; st.damage.a.seq=6; st.alert_seq=6
  eq(U.alert(p,5,nil,known),nil)
  st.damage.a.hits=8; st.damage.a.seq=7; st.alert_seq=7
  eq(U.alert(p,6,nil,known),nil); has(U.held_text(known),'held the repeats of attack #8793 hit 7 more times')
  -- a new attack elsewhere: wakes, new
  st.damage.b={id=8800,at={x=100,y=0},damage=30,hits=1,size=2,seq=8,surface='nauvis'}
  has(U.alert(p,7,nil,known),'(new since your wait began)')
  st.damage.b=nil
  -- a loss near the known one: wakes, changed
  st.losses[1]={seq=3,surface='nauvis',box={-50,390,-50,390},names={['gun-turret']=1}}
  st.damage.a.seq=9
  has(U.alert(p,8,nil,known),'(changed since your wait began: lost since: gun-turret x1)')
  -- more attackers: changed
  st.losses={}; st.damage.a.size=9; st.damage.a.seq=10
  has(U.alert(p,9,nil,known),'2 more attackers seen')
  eq(U.held_text(known),nil)
  game=saved
end
do
  -- through a sleep: the repeat keeps it asleep; a new attack wakes it, saying the repeats held
  local st=storage.agent_harness
  surface.find_entities_filtered=function() return {} end
  st.damage={a={id=8793,at={x=-48,y=396},damage=60,hits=1,size=7,seq=(st.alert_seq or 0)+1,surface='nauvis',first=game.tick,last=game.tick,entities={['gun-turret']=1},units={},kinds={}}}
  st.alert_seq=(st.alert_seq or 0)+1
  local r=grok('sleep',{seconds=60,condition={['until']='alert'},wake_on_urgent=false})
  for _=1,3 do
    st.alert_seq=st.alert_seq+1; st.damage.a.seq=st.alert_seq; st.damage.a.hits=st.damage.a.hits+1; st.damage.a.last=game.tick
    advance(70)
  end
  local s1=grok('sleep_check',{})
  assert(not s1.woke,'held: '..tostring(s1.woke))
  st.alert_seq=st.alert_seq+1
  st.damage.b={id=8800,at={x=100,y=0},damage=30,hits=1,size=2,seq=st.alert_seq,surface='nauvis',first=game.tick,last=game.tick,entities={['gun-turret']=1},units={},kinds={}}
  advance(70)
  local s2=grok('sleep_check',{})
  eq(s2.woke,'alert'); has(s2.alert,'new since your wait began'); has(s2.alert_held,'held the repeats of attack #8793 hit 3 more times')
  st.damage={}
end
print('d18_batch37 U2 an attack\'s repeats do not wake an alert wait: ok')
