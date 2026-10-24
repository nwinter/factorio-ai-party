-- d17 batch12 contracts.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path   -- (d24 batch152) modules require qflow
_G.defines={inventory={turret_ammo=1}}

-- A3: stay_in_turret_coverage routes round an L of turrets, and refuses where coverage ends.
do
  local turrets={}
  local function turret(x,y)
    turrets[#turrets+1]={type='ammo-turret',position={x=x,y=y},prototype={attack_parameters={range=18}},
      get_inventory=function() return {is_empty=function() return false end} end}
  end
  -- a row along y=0 from x=0 to 100, then a column up x=100 to y=-100
  for x=0,100,20 do turret(x,0) end
  for y=-100,0,20 do turret(100,y) end
  local surface={find_entities_filtered=function() return turrets end}
  local p={surface=surface,force='player'}
  local T=dofile('mod/agent-harness_0.1.0/turretcover.lua'){}
  local via,line=T.route(p,{x=0,y=0},{x=100,y=-100})
  assert(#via>=1,'a turn needs a via point')
  -- every via point lies within a turret's reach
  for _,q in ipairs(via) do
    local inside=false
    for _,t in ipairs(turrets) do if ((q.x-t.position.x)^2+(q.y-t.position.y)^2)^0.5<=16 then inside=true end end
    assert(inside,'via point outside coverage '..q.x..','..q.y)
  end
  assert(line:find('via',1,true),line)
  -- a goal far outside every reach: refused (d17 batch13 C2: up to max_uncovered tiles at each end are walked)
  local ok,err=pcall(T.route,p,{x=0,y=0},{x=-60,y=-60})
  assert(not ok and tostring(err):find('outside our turrets\' reach',1,true),tostring(err))
  -- a goal a few tiles out (the base's middle): walked from the nearest covered cell, said
  local v2,l2=T.route(p,{x=0,y=0},{x=50,y=-30})
  assert(l2:find('the last',1,true) and l2:find('are outside it',1,true),l2)
  -- two covered areas apart: refused with where coverage is missing
  turrets={}
  turret(0,0); turret(100,0)
  ok,err=pcall(T.route,p,{x=0,y=0},{x=100,y=0})
  assert(not ok and tostring(err):find('coverage is missing between',1,true),tostring(err))
  -- an empty turret does not count
  turrets={}
  turret(0,0)
  turrets[1].get_inventory=function() return {is_empty=function() return true end} end
  ok,err=pcall(T.route,p,{x=0,y=0},{x=4,y=0})
  assert(not ok and tostring(err):find('0 of our turrets that would shoot now near the way (1 more',1,true),tostring(err))
  print('d17_batch12 A3 turret coverage: ok '..line)
end

-- A2: enemy units our force sees now near the way are discs (16-tile cells), named; unseen ones are not.
do
  local visible={['0,0']=true}
  _G.game={tick=100,forces={player={name='player',players={1},is_chunk_visible=function(_,c) return visible[c.x..','..c.y]==true end},
    enemy={name='enemy',players={}}}}
  local units={}
  local function unit(name,x,y) units[#units+1]={valid=true,type='unit',name=name,position={x=x,y=y}} end
  unit('big-biter',10,10); unit('big-biter',12,11); unit('big-spitter',14,12); unit('small-biter',40,40)
  local surface={name='nauvis',find_entities_filtered=function(f) assert(f.type=='unit'); return units end}
  local A=dofile('mod/agent-harness_0.1.0/avoid.lua'){state=function() return {} end}
  local discs=A.attack_discs(surface,A.mode(nil),{0,0,20,20})
  eq=function(a,b) assert(a==b,tostring(a)..' ~= '..tostring(b)) end
  eq(#discs,1)
  eq(discs[1].name,'3 enemy units (1 big-spitter, 2 big-biter)')
  eq(discs[1].units,true); eq(discs[1].r,24+4)
  -- no box: none (the plan reads them with the chunks along the way)
  eq(#A.attack_discs(surface,A.mode(nil)),0)
  -- avoid_enemies false: none
  eq(A.mode(false),nil)
  print('d17_batch12 A2 units seen now: ok')
end

-- A0 (Sol: the managed platform_bom section erased min_payload every 10 s): the slot's custom minimum payload and max
-- are kept through the rewrite; request takes a min_payload map; a slot already as wanted is not written again.
do
  game={tick=0,forces={}}
  defines={inventory={hub_main=1}}
  prototypes={space_location={fulgora={}},item={['transport-belt']={},['steel-plate']={}}}
  local ghosts={}
  local belt={name='transport-belt',items_to_place_this={{name='transport-belt',count=1}}}
  for i=1,5 do ghosts[i]={type='entity-ghost',ghost_name='transport-belt',ghost_prototype=belt} end
  local sections,writes={},0
  local function section(group)
    local sec={group=group,slots={},is_manual=true}
    sec.filters_count=0
    sec.set_slot=function(i,f) writes=writes+1; sec.slots[i]=f; sec.filters_count=math.max(sec.filters_count,i) end
    sec.get_slot=function(i) return sec.slots[i] end
    sec.clear_slot=function(i) sec.slots[i]=nil end
    return sec
  end
  local secs={sections_count=0}
  secs.get_section=function(i) return sections[i] end
  secs.add_section=function(g) sections[#sections+1]=section(g); secs.sections_count=#sections; return sections[#sections] end
  secs.remove_section=function(i) table.remove(sections,i); secs.sections_count=#sections end
  local hub={valid=true,get_logistic_sections=function() return secs end,get_inventory=function() return {get_item_count=function() return 0 end} end}
  local pl={valid=true,index=5,name='Meridian',hub=hub,space_location={name='fulgora'},surface={find_entities_filtered=function() return ghosts end}}
  local force={name='player',platforms={pl}}
  pl.force=force; game.forces={player=force}
  local st={}
  local B=dofile('mod/agent-harness_0.1.0/platbom.lua'){platform=function() return pl end,state=function() return st end}
  B.read({force=force},{platform='Meridian',request=true})
  -- min_payload sets the slot's custom minimum payload (as minpayload.lua does)
  sections[1].slots[1].minimum_delivery_count=6; sections[1].slots[1].max=40
  local before=writes
  B.tick(600)
  assert(sections[1].slots[1].minimum_delivery_count==6,'min_payload kept through the rewrite')
  assert(writes==before,'a slot already as wanted is not written again')
  table.remove(ghosts)
  B.tick(1200)
  assert(sections[1].slots[1].min==4 and sections[1].slots[1].minimum_delivery_count==6 and sections[1].slots[1].max==40,'lowered, min_payload and max kept')
  -- the request's own map wins, and is kept for later rewrites
  local r=B.read({force=force},{platform='Meridian',request=true,min_payload={['transport-belt']=2}})
  assert(sections[1].slots[1].minimum_delivery_count==2)
  assert(r.lines[1]:find('custom minimum payload 2',1,true),r.lines[1])
  B.tick(1800)
  assert(sections[1].slots[1].minimum_delivery_count==2)
  defines,prototypes=nil,nil
  print('d17_batch12 A0 min_payload kept in the platform_bom section: ok')
end

-- C6 (Sol: a second load_silo launch step read the first one's launch as made under it): the game's launch-ordered
-- event a few ticks after our launch call updates that record instead of making a new one.
do
  local st={}
  game={tick=1000}
  local S=dofile('mod/agent-harness_0.1.0/silo.lua'){state=function() return st end}
  local silo={unit_number=7,surface={name='gleba'},position={x=65.5,y=14.5}}
  S.record(silo,{by='sol',to='platform Swift',cargo='agricultural-science-pack*500',called=true})
  game.tick=1002
  S.record(silo,{cargo='agricultural-science-pack*500',to='platform Swift',ordered=true})
  local r=S.last_launch(silo)
  assert(r.tick==1000 and r.by=='sol' and r.ordered,'one launch, one record: '..tostring(r.tick))
  -- a later launch is a new record
  game.tick=5000
  S.record(silo,{cargo='bioflux*40',ordered=true})
  assert(S.last_launch(silo).tick==5000)
  game=nil
  print('d17_batch12 C6 one launch, one record: ok')
end

-- C2 (Luna: a top-up order went off after three refusals during a short attack): a refusal for enemies that come and go
-- (an area under attack now, units or a group seen now) is no failure; the order waits for the place to clear.
do
  game={tick=1}
  local st={}
  local result
  local enemies='3 enemy units (3 small-wriggler-pentapod) at (2,18)'
  local started=0
  local api={state=function() return st end,last_seen=function() return game.tick end,player=function() return {character={valid=true}} end,busy=function() return nil end,
    condition=function() return true,'ok' end,
    scheduler={order_result=function() local r=result; result=nil; return r end,order=function() return nil end,free=function() return true end,
      resting=function() return nil end,run_order=function() started=started+1 end,loop_orders=function() return nil end},
    enemies_near=function() return enemies end}
  local O=dofile('mod/agent-harness_0.1.0/orders.lua')(api)
  st.orders={[1]={list={{name='topup',steps={{action='feed'}},interval=600,cooldown=600,max_ticks=3600,failures=0,runs=0,next_tick=0,priority=0}},hold=0,rr=0,busy_tick=0,drove_tick=0}}
  local o=st.orders[1].list[1]
  local function fail(reason) result={name='topup',outcome='failed',reason=reason,tick=game.tick}; game.tick=game.tick+60; O.tick() end
  for _=1,3 do fail('goal (2,18) is within 24 tiles of attack #12 at (2,18), an area under attack now (last hit 2s ago)') end
  assert(o.failures==0 and not o.off,'enemy refusals are no failures')
  assert(o.enemy_wait and o.enemy_wait.at.x==2,'waits for (2,18)')
  assert(O.line(1):find('topup waits for enemies near (2,18) to clear (not a failure)',1,true),O.line(1))
  -- still there: no run; clear: it runs
  local before=started
  game.tick=o.next_tick; O.tick()
  for _=1,120 do game.tick=game.tick+1; O.tick() end
  assert(started==before,'no run while enemies are there')
  enemies=nil
  for _=1,1200 do game.tick=game.tick+1; O.tick() end
  assert(o.enemy_wait==nil and started>before,'runs once the place is clear '..tostring(o.enemy_wait)..' '..started..' '..before..' '..tostring(O.line(1)))
  -- a worm (it stays) still counts as a failure
  fail('goal (5,5) is inside big-worm-turret (9,9) range 38 (5.0 tiles from it)')
  assert(o.failures==1)
  game=nil
  print('d17_batch12 C2 orders wait out enemies: ok')
end

-- C8 (Grok: Swift read 59 minutes left at Vulcanus while a remote-lane queue was about to send it on): the departure
-- lines read the remote lane too.
do
  local st={queues={},remote_queues={[3]={current={action='wait_until',args={['until']='item_count',item='agricultural-science-pack',platform='Swift',at_least=500}},
    pending={{action='platform_schedule',args={platform='Swift',stops={{station='gleba'}}}}}}}}
  local D=dofile('mod/agent-harness_0.1.0/departure.lua'){state=function() return st end,name_of=function() return 'grok' end}
  local l=D.lines('Swift')
  assert(l and l[1]:find("grok's remote queue: wait_until item_count",1,true) and l[1]:find('platform_schedule Swift (gleba)',1,true),tostring(l and l[1]))
  print('d17_batch12 C8 the remote lane sends platforms on: ok')
end
