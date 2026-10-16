-- d15 batch3 (operator 18:30, shifts 18-19 requests). Run from the harness root: lua tests/d15_batch3.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,msg) assert(a==b,(msg or '')..' '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end

-- A mock inventory: slots {name,count} or false.
local function inventory(list)
  local inv={}
  local mt={__len=function() return #list end,__index=function(_,k)
    if type(k)=='number' then local s=list[k]; return s and {valid_for_read=true,name=s[1],count=s[2]} or {valid_for_read=false} end
    if k=='count_empty_stacks' then return function() local n=0; for _,s in ipairs(list) do if not s then n=n+1 end end; return n end end
    if k=='can_insert' then return function() for _,s in ipairs(list) do if not s then return true end end; return false end end
    if k=='get_item_count' then return function(name) local n=0; for _,s in ipairs(list) do if s and s[1]==name then n=n+s[2] end end; return n end end
  end}
  return setmetatable(inv,mt)
end

-- 1 (Astra, Luna): a chest with every slot used, what fills it, and the machines whose output waits on it. ---------
do
  defines={inventory={chest=1},entity_status={}}
  local status={}
  local force={name='player'}
  local by_type={}
  local surface={find_entities_filtered=function(f)
    local out={}
    local types=type(f.type)=='table' and f.type or {f.type}
    for _,t in ipairs(types) do for _,e in ipairs(by_type[t] or {}) do out[#out+1]=e end end
    return out
  end}
  local function entity(t)
    t.valid=true; t.surface=surface; t.force=force
    local x,y=t.position.x,t.position.y
    t.bounding_box={left_top={x=x-0.5,y=y-0.5},right_bottom={x=x+0.5,y=y+0.5}}
    by_type[t.type]=by_type[t.type] or {}; table.insert(by_type[t.type],t)
    return t
  end
  local slots={}
  for i=1,48 do slots[i]=i<=40 and {'spoilage',100} or {'nutrients',30} end
  local full_inv=inventory(slots)
  local chest=entity{type='logistic-container',name='passive-provider-chest',unit_number=10,position={x=10.5,y=4.5},get_inventory=function() return full_inv end}
  local spare_inv=inventory({{'nutrients',5},false,false})
  local spare=entity{type='container',name='steel-chest',unit_number=11,position={x=14.5,y=4.5},get_inventory=function() return spare_inv end}
  local bio=entity{type='assembling-machine',name='biochamber',unit_number=20,position={x=7.5,y=4.5}}
  local ins=entity{type='inserter',name='inserter',unit_number=30,position={x=9.5,y=4.5},drop_target=chest,pickup_target=bio}
  local other=entity{type='inserter',name='inserter',unit_number=31,position={x=11.5,y=4.5},drop_target=spare,pickup_target=chest}
  status[bio]='full_output'; status[ins]='waiting_for_space_in_destination'; status[other]='working'
  local F=require('fullchest'){status_name=function(e) return status[e] end}
  local r=F.read(chest)
  eq(r.line,'passive-provider-chest (10.5,4.5): 48/48 slots used (spoilage 4000 in 40 slots, nutrients 240 in 8 slots); output waits on it: biochamber (7.5,4.5) full_output (1 inserter waiting)')
  eq(F.read(spare),nil,'a chest with a free slot is not full')
  eq(F.free_note(spare),', 2/3 slots free'); eq(F.free_note(chest),', 0/48 slots free')
  eq(F.of_machine(bio).line,r.line,'a full_output machine finds the chest its inserter waits on')
  local near=F.nearest_free(chest)
  eq(near[1],'steel-chest (14.5,4.5) 2/3 slots free, 4 tiles')
  spare_inv=inventory({{'nutrients',5}})
  eq(F.nearest_free(chest)[1],'no chest of ours within 32 tiles has a free slot')

  -- supply: full_chests from the makers' takers, free slots on the listed providers.
  prototypes={item={nutrients={}},fluid={}}
  local S=require('supply'){state=function() return {} end,integer=function(v,d) return v or d end,status_name=function(e) return status[e] end}
  local t={item='nutrients',chests={{n=240,e=chest,kind='passive-provider'}},takers={n=1,states={},into={},chests={[10]=chest}},request_of={}}
  local lines=S.full_chests(t)
  eq(lines[1],r.line); eq(#lines,1,'the same chest once')
  eq(S.top_chests(t)[1],'(10.5,4.5) passive-provider-chest 240, 0/48 slots free')

  -- open for you: a full_output machine in a fresh claim whose output waits on a full chest.
  game={tick=100000,surfaces={gleba={index=4,find_entity=function(name,pos) if name=='biochamber' and pos.x==7.5 then return bio end end}}}
  local st={board={items={{id=700,kind='claim',owner='luna',status='doing',title='bioflux',surface='gleba',area={left_top={x=0,y=0},right_bottom={x=40,y=40}}}}},
    survey_cache={['player/4']={positions={biochamber={full_output={{x=7.5,y=4.5}}}}}}}
  local O=require('open'){state=function() return st end,claim_surface=function(i) return i.surface end,claim_stale=function() return false end,fullchest=F}
  has(O.line('luna',force),'1 full chest in your claims that output waits on (passive-provider-chest (10.5,4.5) 48/48 slots used (spoilage 4000 in 40 slots, nutrients 240 in 8 slots))')
end
print('d15_batch3 1 full chests: ok')

-- 2 (Sol): what removing heat pipes does to heat: freezable entities losing their last warm heater, parts cut off. --
do
  local all={}
  local function proto(type,w,h,heating,buf) return {type=type,w=w,h=h,heating_energy=heating or 0,heat_buffer_prototype=buf and {specific_heat=1e6,max_temperature=1000,min_working_temperature=15,max_transfer=1e9} or nil} end
  local surface={planet={prototype={entities_require_heating=true}}}
  local n=0
  local function ent(name,pr,x,y,temp)
    n=n+1
    local e={valid=true,unit_number=n,name=name,type=pr.type,prototype=pr,position={x=x,y=y},direction=0,temperature=temp,heat_neighbours={}}
    all[#all+1]=e; return e
  end
  local function link(a,b) table.insert(a.heat_neighbours,b); table.insert(b.heat_neighbours,a) end
  surface.find_entities_filtered=function(f)
    local out={}
    local types=f.type and (type(f.type)=='table' and f.type or {f.type})
    for _,e in ipairs(all) do
      local ok=true
      if types then ok=false; for _,t in ipairs(types) do if t==e.type then ok=true end end end
      local a=f.area
      local w,h=(e.prototype.w or 1)/2,(e.prototype.h or 1)/2
      if ok and a and not (e.position.x+w>a[1][1] and e.position.x-w<a[2][1] and e.position.y+h>a[1][2] and e.position.y-h<a[2][2]) then ok=false end
      if ok then out[#out+1]=e end
    end
    return out
  end
  local H=require('heating'){footprint=function(pr,pos) return {left_top={x=pos.x-pr.w/2,y=pos.y-pr.h/2},right_bottom={x=pos.x+pr.w/2,y=pos.y+pr.h/2}} end}
  local tower=ent('heating-tower',proto('reactor',3,3,0,true),1.5,1.5,300)
  local pipe=proto('heat-pipe',1,1,0,true)
  local p1=ent('heat-pipe',pipe,3.5,1.5,280); local p2=ent('heat-pipe',pipe,4.5,1.5,270); local p3=ent('heat-pipe',pipe,5.5,1.5,260)
  link(tower,p1); link(p1,p2); link(p2,p3)
  local ug=ent('pipe-to-ground',proto('pipe-to-ground',1,1,50),5.5,2.5)
  local turbine=ent('steam-turbine',proto('generator',3,5,100),7.5,1.5)
  local loss=H.loss(surface,{name='player'},{p2})
  eq(loss.cut_off,'1 heat-network part cut off from every nuclear reactor and heating tower (1 heat-pipe; first at (5.5,1.5)); they keep their heat and cool')
  eq(loss.freeze_count,2)
  has(table.concat(loss.freeze,' | '),'pipe-to-ground (5.5,2.5): keeps only heaters cut off from every reactor and heating tower, which cool (heat-pipe (5.5,1.5) 260 C)')
  has(table.concat(loss.freeze,' | '),'steam-turbine (7.5,1.5): keeps only heaters cut off from every reactor and heating tower, which cool (heat-pipe (5.5,1.5) 260 C)')
  -- removing the end pipe: nothing cut; the turbine loses its last heater
  loss=H.loss(surface,{name='player'},{p3})
  eq(loss.cut_off,nil); eq(loss.freeze_count,1); has(table.concat(loss.freeze,' | '),'steam-turbine (7.5,1.5): loses its last heater at 30 C or more (heat-pipe (5.5,1.5) 260 C)')
  -- a pipe whose neighbours stay warm from another heater: nothing
  local p4=ent('heat-pipe',pipe,4.5,3.5,250); link(p4,tower)
  loss=H.loss(surface,{name='player'},{p2})
  eq(loss.freeze_count,1,'the underground keeps p4'); has(loss.freeze[1],'steam-turbine')
  -- no heating needed and nothing cut: none
  surface.planet.prototype.entities_require_heating=false
  eq(H.loss(surface,{name='player'},{p3}).none,'no entity loses its last heater at 30 C or more and no heat-network part is cut off')
  eq(H.loss(surface,{name='player'},{ug}),nil,'no heat part removed')
end
print('d15_batch3 2 heat: ok')

-- 3 (Grok): guns and ammo per slot; compatible ammo in another slot; moving ammo between ammo slots. ---------------
do
  defines={inventory={character_guns=1,character_ammo=2}}
  prototypes={item={pistol={type='gun',attack_parameters={ammo_categories={'bullet'}}},
    ['piercing-rounds-magazine']={type='ammo',ammo_category={name='bullet'}},rocket={type='ammo',ammo_category={name='rocket'}}}}
  local function slot(name,count)
    local s={}
    local function set(n,c) s.name,s.count,s.valid_for_read=n,c,n~=nil end
    set(name,count)
    s.swap_stack=function(o) local n,c=s.name,s.count; set(o.name,o.count); o._set(n,c); return true end
    s._set=set
    return s
  end
  local guns={slot('pistol',1),slot(),slot()}
  local ammo={slot(),slot('piercing-rounds-magazine',75),slot()}
  local p={get_inventory=function(i) return i==1 and guns or ammo end}
  local A=require('ammoslots')()
  local r=A.read(p)
  local g,am=A.lines(r)
  eq(g,'1 pistol, 2 empty, 3 empty'); eq(am,'1 empty, 2 piercing-rounds-magazine*75, 3 empty')
  eq(A.elsewhere(r,1),'piercing-rounds-magazine*75 in ammo slot 2 fits pistol (gun slot 1 fires only from ammo slot 1; ammo slot 2 is fired by gun slot 2: empty)')
  eq(A.idle_ammo(r)[1],'ammo slot 2 piercing-rounds-magazine*75: gun slot 2 is empty; it fits gun slot 1 pistol, which fires only from its own ammo slot')
  eq(A.fits('pistol','rocket'),false)
  local m=A.move(p,'piercing-rounds-magazine',1)
  eq(m.from,2); eq(m.to,1); eq(ammo[1].name,'piercing-rounds-magazine'); eq(ammo[1].count,75); eq(ammo[2].valid_for_read,false)
  eq(A.idle_ammo(A.read(p)),nil)
  -- Regression (hotfix 000fb4ac, Sol 18:54): in 2.0 a stack's quality is a LuaQualityPrototype, userdata, not a table.
  local function quality(name) local u=io.tmpfile(); debug.setmetatable(u,{__index={name=name}}); return u end
  ammo[2]=slot('piercing-rounds-magazine',10); ammo[2].quality=quality('uncommon'); ammo[1].quality=quality('normal')
  g,am=A.lines(A.read(p))
  eq(am,'1 piercing-rounds-magazine*75, 2 piercing-rounds-magazine@uncommon*10, 3 empty')
end
print('d15_batch3 3 ammo slots: ok')

-- 4 (Haiku, Luna): the route read before walking: worms on the way with their range, closed-in goals. ------------
do
  game={tick=100,forces={player={name='player'},enemy={name='enemy'}}}
  prototypes={entity={['big-worm-turret']={attack_parameters={range=38}},['biter-spawner']={result_units={}}}}
  local force=game.forces.player
  force.get_friend=function() return false end; force.get_cease_fire=function() return false end
  local worm={valid=true,name='big-worm-turret',type='turret',position={x=250,y=0},force=game.forces.enemy}
  local surface={name='nauvis',index=1,find_entities_filtered=function() return {worm} end}
  local st={}
  local A=require('avoid'){state=function() return st end,charted=function() return true end,leg=function() return false end}
  local closed_goal=false
  local P={half=function() return 0.2 end,area_text=function() return 'the area (10,10)-(20,20) has no gap' end,
    region=function(_,q) return {closed=closed_goal and q.x==500} end,
    dig=function() return {mine={{name='stone-wall',position={x=21.5,y=15.5}},{name='steel-chest',position={x=22.5,y=15.5}}}} end}
  local RC=require('routecheck'){avoid=A,pathing=P}
  local p={index=1,position={x=0,y=0},surface=surface,force=force,character={}}
  local out=RC.check(p,{{x=0,y=0},{x=500,y=0}},A.mode({distance=12}))
  has(out.enemies[1],'big-worm-turret (250,0) range 38: closest pass ')
  has(out.enemies[1],'inside it)')
  has(out.under_range[1],'big-worm-turret (250,0) range 38 is more than distance 12; the route passes ')
  has(out.route,'round worms and spawners')
  has(out.reachable,'not closed in at either end')
  -- the default margins keep the route out of its range
  out=RC.check(p,{{x=0,y=0},{x=500,y=0}},A.mode(nil))
  assert(not out.enemies[1]:find('inside it',1,true),out.enemies[1]); eq(out.under_range,nil)
  -- a live move_to with distance 12 names the worm too (on the straight line)
  has(RC.under_live(p,{{x=0,y=0},{x=500,y=0}},A.mode({distance=12}))[1],'passes 0 tiles from it')
  -- a closed goal: the entities to mine for a way in, the first met first
  closed_goal=true
  out=RC.check(p,{{x=0,y=0},{x=500,y=0}},A.mode(nil))
  eq(out.reachable,'no: closed in at the goal'); eq(out.mine_for_a_way_in[1],'steel-chest (23,16)')
  has(out.closed_in_goal,'the goal: the area')
  -- a goal in deep water: no spot to stand there, no dig (measured on a copy of world n: (350,900) read "closed in, about 0 tiles")
  P.region=function(_,q) return q.x==500 and {closed=true,stuck=true,tiles=0} or {} end
  P.dig=function() error('no dig for a goal with no spot to stand') end
  surface.get_tile=function() return {name='deepwater'} end
  out=RC.check(p,{{x=0,y=0},{x=500,y=0}},A.mode(nil))
  eq(out.reachable,'no: no spot to stand at the goal'); eq(out.closed_in_goal,'the goal: no spot the character stands on within a tile of (500,0) (the tile there: deepwater)')
  eq(out.mine_for_a_way_in,nil)
end
print('d15_batch3 4 route check: ok')

-- 5 (Sol): the inserters that take a machine's output and the chest they fill; the wait's reply says so. ---------
do
  prototypes={item={['lithium-plate']={}}}
  local force={name='player'}
  local chest={valid=true,unit_number=7,type='container',name='steel-chest',position={x=6.5,y=-3.5},get_item_count=function(n) return n=='lithium-plate' and 340 or 0 end}
  local plant
  local ins={valid=true,unit_number=8,name='fast-inserter',position={x=5.5,y=-3.5},drop_target=chest,use_filters=false}
  -- (a filter's name as a prototype, userdata in 2.0)
  local proto=io.tmpfile(); debug.setmetatable(proto,{__index={name='iron-plate'}})
  local blocked={valid=true,unit_number=9,name='inserter',position={x=3.5,y=-1.5},drop_target=chest,use_filters=true,inserter_filter_mode='whitelist',
    get_filter=function(i) return i==1 and {name=proto} or nil end}
  local surface={find_entities_filtered=function() return {ins,blocked} end}
  plant={valid=true,name='foundry',type='assembling-machine',position={x=3.5,y=-3.5},force=force,surface=surface,
    bounding_box={left_top={x=2,y=-5},right_bottom={x=5,y=-2}},get_recipe=function() return {name='molten-lithium'} end}
  ins.pickup_target=plant; blocked.pickup_target=plant
  local ST=require('stock'){integer=function(v,d) return v or d end}
  local tk=ST.output_takers(plant,'lithium-plate')
  eq(tk.line,'1 inserter takes lithium-plate from its output as it is made: fast-inserter (5.5,-3.5) into steel-chest (6.5,-3.5) (holds 340 lithium-plate)')
  eq(tk.chests[1].holds,340)
  -- the whitelist naming iron-plate by a userdata prototype lets iron-plate through
  has(ST.output_takers(plant,'iron-plate').line,'2 inserters take iron-plate')
  local _,out=ST.start_wait({position={x=0,y=0},force=force,can_reach_entity=function() return true end},{item='lithium-plate',count=100},plant,600)
  eq(out.taken_by_inserters,tk.line); eq(out.follow_chests,'follow: true takes from steel-chest (6.5,-3.5) instead')
end
print('d15_batch3 5 collect output takers: ok')

-- 7 (Muse, Luna): history keeps each step's arguments; a finished loop keeps its steps (queue_status {args: true}). -
do
  game={tick=0}
  local state,active={},{}
  local players={[1]={index=1}}
  local s=require('scheduler'){
    state=function() return state end,player=function(i) return players[i] end,
    handlers={craft=function() return {started=1} end},
    busy=function() return false end,stop=function() end,stop_index=function() end,
    outcome=function() return nil end,completion=function() return nil end,
    condition=function() return false end,validate_condition=function() end,
  }
  local h,p=s.handlers,players[1]
  local function tick() game.tick=game.tick+1; s.tick() end
  h.queue_submit(p,{steps={{action='craft',args={recipe='iron-gear-wheel',count=5}}}})
  tick()
  local q=h.queue_status(p)
  eq(q.history[#q.history].action,'craft'); eq(q.history[#q.history].args,nil,'no arguments unless asked')
  q=h.queue_status(p,{args=true})
  eq(q.history[#q.history].args.recipe,'iron-gear-wheel'); eq(q.history[#q.history].args.count,5)
  -- a loop of 2 rounds keeps its steps for queue_status {args: true}
  h.queue_repeat(p,{steps={{action='craft',args={recipe='pipe',count=2}}},times=2,interval_ticks=60})
  for _=1,200 do tick() end
  q=h.queue_status(p)
  eq(q.loop_done.rounds,2); eq(q.loop_done.steps,nil); eq(q.loop_done.steps_count,1)
  q=h.queue_status(p,{args=true})
  eq(q.loop_done.steps[1].action,'craft'); eq(q.loop_done.steps[1].args.recipe,'pipe')
end
print('d15_batch3 7 history args: ok')

-- 7 (Luna): a queued timed transfer interrupted by a direct action goes on from the stops left. -------------------
do
  game={tick=0}
  local state,active={},{}
  local players={[1]={index=1}}
  local s=require('scheduler'){
    state=function() return state end,player=function(i) return players[i] end,
    handlers={transfer=function(p,a) active[p.index]=game.tick+1000; return {walking=true} end,craft=function() return {started=1} end},
    busy=function(p) return active[p.index]~=nil end,stop=function(p) active[p.index]=nil end,stop_index=function(i) active[i]=nil end,
    outcome=function() return nil end,completion=function() return nil end,
    condition=function() return false end,validate_condition=function() end,
  }
  local h,p=s.handlers,players[1]
  local function tick() game.tick=game.tick+1; s.tick() end
  local stops={{x=1.5,y=1.5},{x=10.5,y=1.5},{x=20.5,y=1.5}}
  h.queue_submit(p,{steps={{action='transfer',args={positions=stops,item='coal',count=20,direction='to_entity',walk=true}},{action='craft'}}})
  tick()
  local cur=state.queues and state.queues[1] and state.queues[1].current
  assert(cur and cur.action=='transfer','the transfer runs')
  -- the runtime notes the part done (M.tour_mark): one stop done, two left
  cur.tour_left={positions={{x=10.5,y=1.5},{x=20.5,y=1.5}},done=1,total=3,got=20,item='coal'}
  s.pause(1)
  local q=h.queue_status(p)
  eq(q.pending[1].action,'transfer'); eq(#q.pending[1].args.positions,2); eq(q.pending[1].args.positions[1].x,10.5); eq(q.pending[1].args.count,20)
  has(q.history[#q.history].result.resumed_from,'1 of 3 stops done (moved 20); requeued with the 2 left')
  eq(q.history[#q.history].result.requeued,true)
  -- a courier past its take: requeued as the give at the destination
  h.queue_cancel(p,{})
  h.queue_submit(p,{steps={{action='transfer',args={pick='first_with_stock',positions={{x=1.5,y=1.5}},item='iron-plate',to={x=30.5,y=4.5},count=50}}}})
  h.queue_resume(p,{}); tick()
  cur=state.queues[1].current
  cur.tour_left={positions={{x=30.5,y=4.5}},done=1,total=2,got=50,item='iron-plate',courier=true,taken=50}
  s.pause(1)
  q=h.queue_status(p)
  eq(q.pending[1].args.position.x,30.5); eq(q.pending[1].args.count,50); eq(q.pending[1].args.direction,'to_entity'); eq(q.pending[1].args.pick,nil)
  has(q.history[#q.history].result.resumed_from,'the take is done (50 iron-plate); requeued as the give at (30.5,4.5)')
end
print('d15_batch3 7 resume: ok')

-- 8 (Sonnet): a fast replace of an inserter keeps what its hand holds in the new inserter's hand. ----------------
do
  prototypes={item={['iron-plate']={stack_size=100},inserter={stack_size=50},['fast-inserter']={stack_size=50}}}
  defines={inventory={chest=1}}
  local function stack(name,count)
    local s={name=name,count=count,valid_for_read=name~=nil,quality='normal'}
    s.clear=function() s.name=nil; s.count=0; s.valid_for_read=false end
    s.transfer_stack=function(o) s.name,s.count,s.valid_for_read=o.name,o.count,true; o.clear(); return true end
    return s
  end
  -- the character's inventory: its one slot full of iron plates; the build uses its last fast inserter
  local main={stack('iron-plate',100)}
  main.supports_filters=function() return false end
  local p={get_main_inventory=function() return main end,insert=function() return 0 end,surface={spill_item_stack=function() error('nothing spills') end},position={x=0,y=0}}
  local old={valid=true,name='inserter',type='inserter',position={x=3.5,y=4.5},held_stack=stack('iron-plate',5),get_max_inventory_index=function() return 0 end,
    prototype={mineable_properties={products={{type='item',name='inserter',amount=1}}}},quality='normal'}
  local RP=require('replace'){}
  local plan=RP.plan(p,old,{type='inserter',name='fast-inserter'},'normal',1)
  eq(plan.error,nil); eq(plan.hand.name,'iron-plate'); eq(plan.hand.count,5)
  -- after the build: the hold has the old inserter and its hand; the new one's hand takes the plates
  local hold={stack('inserter',1),stack('iron-plate',5)}
  hold.destroy=function() end
  local got={}
  p.insert=function(s) got[#got+1]=s.name; return s.count end
  local new={valid=true,name='fast-inserter',held_stack=stack()}
  local line=RP.give(p,new,hold,plan)
  eq(new.held_stack.name,'iron-plate'); eq(new.held_stack.count,5)
  has(line,"kept 5 iron-plate in the new fast-inserter's hand")
  -- an inserter hand that would need room it does not have is named in the refusal
  main[1]=stack('copper-plate',100)
  plan=RP.plan(p,old,{type='container',name='wooden-chest'},'normal',0)
  has(plan.error,'your inventory has no room for'); has(plan.error,'5 iron-plate')
end
print('d15_batch3 8 fast replace hand: ok')

-- 9 (Grok): enemy units near an artillery piece: distance, their range, whether our turrets reach them. -----------
do
  prototypes={entity={['big-spitter']={attack_parameters={range=13}},['medium-biter']={attack_parameters={range=1}}}}
  defines={inventory={artillery_turret_ammo=1}}
  local force={name='player',is_chunk_visible=function() return true end,is_chunk_charted=function() return true end,artillery_range_modifier=0}
  local units={{valid=true,name='big-spitter',position={x=20,y=0}},{valid=true,name='medium-biter',position={x=3,y=4}},{valid=true,name='big-spitter',position={x=0,y=40}}}
  local gun={valid=true,name='gun-turret',type='ammo-turret',position={x=25,y=0},prototype={attack_parameters={range=18}}}
  local surface={find_entities_filtered=function(f)
    if f.type=='unit' then return units end
    if type(f.type)=='table' and f.type[1]=='ammo-turret' then return {gun} end
    return {}
  end}
  local piece={valid=true,name='artillery-turret',type='artillery-turret',position={x=0,y=0},surface=surface,force=force,
    prototype={guns={{attack_parameters={range=224,min_range=32}}}},get_inventory=function() return {get_contents=function() return {} end} end}
  local AR=require('artillery'){position=function(v) return v end}
  local u=AR.units_near(piece)
  eq(u.count,3); eq(u.by_name,'1 medium-biter, 2 big-spitter')
  eq(u.rows[1],'medium-biter (3,4) 5 tiles away, its range 1 (4 outside it); no turret of ours reaches it')
  eq(u.rows[2],'big-spitter (20,0) 20 tiles away, its range 13 (7 outside it); 1 turret of ours reaches it')
  has(AR.row(piece).line,'3 enemy units within 64 tiles (1 medium-biter, 2 big-spitter): medium-biter (3,4)')
end
print('d15_batch3 9 artillery units: ok')

-- 10: platform_endurance on a young leg (the window inside the leg) and its ingredient cap two levels down with fluids.
do
  defines={flow_precision_index={ten_minutes=2,one_minute=1,five_seconds=0},inventory={hub_main=1,turret_ammo=1,assembling_machine_input=2}}
  prototypes={item={rocket={type='ammo'},explosives={type='item'},coal={type='item'}},fluid={['thruster-fuel']={},['thruster-oxidizer']={},['sulfuric-acid']={}},
    space_location={nauvis={solar_power_in_space=100},fulgora={solar_power_in_space=120}},
    space_connection={a={from={name='nauvis'},to={name='fulgora'},length=15000}}}
  game={tick=10*3600}
  -- the statistics: per minute over the last minute and over the last 10 (the 10 hold the stop: fuel used 0 there)
  local per={one={['thruster-fuel']={0,600},rocket={0,12}},ten={['thruster-fuel']={0,180},rocket={0,2}}}
  local function stats(kind) return {get_flow_count=function(a) local t=a.precision_index==1 and per.one or per.ten; local r=t[a.name]; local m=a.precision_index==1 and 1 or 10
    return r and (a.category=='input' and r[1] or r[2])*m or 0 end} end
  local hub=setmetatable({get_contents=function() return {{name='rocket',count=100},{name='explosives',count=10},{name='coal',count=20}} end,count_empty_stacks=function() return 5 end},{__len=function() return 10 end})
  local tank={fluidbox={{name='sulfuric-acid',amount=50},{name='thruster-fuel',amount=6000}}}
  local function asm(recipe,fluid) return {get_recipe=function() return recipe end,get_inventory=function() return {get_contents=function() return {} end} end,fluidbox=fluid or {}} end
  local A=asm({products={{name='rocket',amount=1}},ingredients={{type='item',name='explosives',amount=1}}})
  local B=asm({products={{name='explosives',amount=1}},ingredients={{type='item',name='coal',amount=2},{type='fluid',name='sulfuric-acid',amount=10}}},{{name='sulfuric-acid',amount=30}})
  local surface={find_entities_filtered=function(f)
    if f.type=='assembling-machine' then return {A,B} elseif type(f.type)=='table' then return {tank} end
    return {} end}
  local force={get_item_production_statistics=function() return stats() end,get_fluid_production_statistics=function() return stats() end}
  local pl={name='Swift',surface=surface,force=force,hub={get_inventory=function() return hub end},speed=25/60,space_connection={},
    schedule={current=2,records={{station='nauvis'},{station='fulgora'}}}}
  local leg={from='nauvis',to='fulgora',left_km=6000}
  -- the leg it flies began 3 minutes ago; rockets 0 used then, 36 now (12/min)
  local segs={{kind='stop',at='nauvis',start=0,['end']=7*3600},{kind='leg',from='nauvis',to='fulgora',start=7*3600,ammo0={rocket={made=0,used=0}}}}
  made_now=0
  local E=require('endurance'){platform=function() return pl end,leg=function() return leg end,segments=function() return segs end,
    ammo_counts=function() return {rocket={made=made_now,used=36}} end}
  local r=E.read({},{platform='Swift'})
  local by={}; for _,x in ipairs(r.resources) do by[x.name]=x end
  eq(by.rocket.used_per_min,12); eq(by.rocket.rate_from,'this leg so far, 3m00s')
  eq(by['thruster-fuel'].used_per_min,600); eq(by['thruster-fuel'].rate_from,'last 1 min, within this leg (3m00s so far)')
  eq(by['thruster-fuel'].lasts_min,10,'6000 at 600/min, not 180/min from a window that held the stop')
  -- two levels down: rockets from explosives (10 aboard) and explosives from coal (20, 2 a craft) and acid (50 in a tank and
  -- 30 in the maker, 10 a craft): 8 more explosives, so at most 18 more rockets
  made_now=15
  r=E.read({},{platform='Swift'})
  by={}; for _,x in ipairs(r.resources) do by[x.name]=x end
  local cap=by.rocket.ingredient_limited
  eq(cap.more,18); eq(cap.item,'explosives'); eq(cap.below.more,8); eq(cap.below.item,'sulfuric-acid')
  has(by.rocket.line,'at most 18 more (explosives 10 aboard and at most 8 more from its own ingredients aboard (sulfuric-acid 80), 1 a craft)')
  prototypes,defines=nil,nil
end
print('d15_batch3 10 endurance: ok')
