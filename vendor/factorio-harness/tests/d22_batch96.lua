-- d22 batch96 BF1 part 1: the platform read (dispatch platform: 40.6 ms on world n at 14:06, worst 83.5) on a copy of
-- world n's 13:05 autosave spent most of Asterion's 77-93 ms in freight.stock_places (its 6,651 belts found in 24 ms and
-- read in 44), then a find of every entity aboard for the damaged list (33 ms for 7,957, capped at 5,000), the hub
-- inserters (every inserter aboard, capped at 500) and the ammo model's quarter-minute stepping (5.9 ms a row).
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
defines={inventory={hub_main=1,hub_trash=2,turret_ammo=3,assembling_machine_output=4},flow_precision_index={ten_minutes=1}}
game={tick=3600*10}

-- 1. stock_places: belts and inserter hands from the platform's background read (freight.belt_tick), else the census
-- pass's, else read now; the hub, turrets and machines read now
do
  local finds={}
  local function inv(list) return {get_contents=function() return list end} end
  local hub={valid=true,get_inventory=function(i) return i==1 and inv({{name='rocket',count=40}}) or nil end}
  local turret={valid=true,get_inventory=function() return inv({{name='rocket',count=10}}) end}
  local machine={valid=true,get_output_inventory=function() return inv({{name='rocket',count=2}}) end}
  local belt={valid=true,type='transport-belt',get_max_transport_line_index=function() return 2 end,
    -- (a transport line's # is its item count, as the game's: d22 batch110 BT1 reads no empty line's contents)
    get_transport_line=function() return setmetatable({get_contents=function() return {{name='rocket',count=5}} end},{__len=function() return 5 end}) end}
  local surface={index=7,find_entities_filtered=function(f)
    finds[#finds+1]=f
    if f.type=='ammo-turret' then return {turret} end
    if type(f.type)=='table' and f.type[1]=='assembling-machine' then return {machine} end
    if type(f.type)=='table' and f.type[1]=='transport-belt' then return {belt} end
    return {}
  end}
  local pl={index=4,surface=surface,force={name='player'},hub=hub}
  local st={}
  local idx={belts={rocket=300,['iron-plate']=50},hands={rocket=3},as_of=3600*9}
  local F=dofile('mod/agent-harness_0.1.0/freight.lua'){state=function() return st end,census_where=function(f,s) eq(s,surface); return idx end}
  local ALL=setmetatable({},{__index=function() return true end})
  -- no background read yet: the census pass's belts and hands
  local sp=F.stock_places(pl,ALL)
  eq(sp.belts.rocket,300); eq(sp.hands.rocket,3); eq(sp.from_census,true); eq(sp.as_of,3600*9)
  eq(sp.hub.rocket,40); eq(sp.turrets.rocket,10); eq(sp.machines.rocket,2); eq(sp.total.rocket,355)
  for _,f in ipairs(finds) do assert(not (type(f.type)=='table' and f.type[1]=='transport-belt'),'no belt find') end
  eq(st.platform_belts[4].wanted,game.tick,'marked as read')
  -- a background read done: its belts and hands, as of its tick
  st.platform_belts[4].done={tick=3600*9.5,belts={rocket=120},hands={rocket=1},belt_entities=40}
  sp=F.stock_places(pl,{rocket=true})
  eq(sp.belts.rocket,120); eq(sp.hands.rocket,1); eq(sp.from_belt_read,true); eq(sp.as_of,3600*9.5); eq(sp.belt_entities,40); eq(sp.total.rocket,173)
  -- neither: all read now, as before
  local F2=dofile('mod/agent-harness_0.1.0/freight.lua'){state=function() return {} end,census_where=function() return nil end}
  sp=F2.stock_places(pl,ALL)
  eq(sp.belts.rocket,10); eq(sp.from_census,nil); eq(sp.from_belt_read,nil)

  -- belt_tick: the platform read lately, a band of its chunks every BELT_STEP ticks, until the walk is done
  local bands={{belt,{valid=true,type='inserter',held_stack={valid_for_read=true,name='rocket',count=2}}},{belt}}
  local bi=0
  local walk={band=function(w) eq(w.max,1); bi=bi+1; return bands[bi] end}
  local st2={}
  local F3=dofile('mod/agent-harness_0.1.0/freight.lua'){state=function() return st2 end,walk=walk,census_where=function() return nil end}
  surface.get_chunks=function() local done=false; return function() if done then return nil end done=true; return {x=0,y=0} end end
  local pf={name='player',platforms={pl}}
  pl.valid=true
  game.forces={player=pf}
  F3.stock_places(pl,ALL)  -- read now, and wanted
  local t=game.tick - game.tick % F3.BELT_STEP
  F3.belt_tick(t)  -- starts the job
  eq(st2.platform_belts.active,4)
  F3.belt_tick(t+F3.BELT_STEP); F3.belt_tick(t+2*F3.BELT_STEP); F3.belt_tick(t+3*F3.BELT_STEP)
  local done=st2.platform_belts[4].done
  eq(done.belts.rocket,20,'two belts, two lines of 5'); eq(done.hands.rocket,2); eq(done.belt_entities,2); eq(done.tick,t)
  eq(st2.platform_belts.active,nil)
  -- not again before BELT_EVERY
  F3.belt_tick(t+4*F3.BELT_STEP); eq(st2.platform_belts.active,nil)
  game.forces=nil
end
print('d22_batch96 BF1 stock_places from the background belt read: ok')

-- 2. the census counts an underground exit's buried lines once (its entrance's), as stock_places does
do
  local C=dofile('mod/agent-harness_0.1.0/census.lua'){state=function() return {} end,walk={}}
  local function line(items) local function c() local o={} for _,x in ipairs(items) do o[#o+1]=x end return o end
    return {id=items.id,get_contents=c,line_equals=function(o) return o.id==items.id end} end
  local buried3,buried4={id=3,{name='coal',count=4}},{id=4,{name='coal',count=4}}
  local entrance={valid=true,type='underground-belt',name='underground-belt',position={x=0,y=0},belt_to_ground_type='input',
    get_max_transport_line_index=function() return 4 end}
  local lines_in={line({id=1,{name='coal',count=1}}),line({id=2}),line(buried3),line(buried4)}
  entrance.get_transport_line=function(i) return lines_in[i] end
  local exit={valid=true,type='underground-belt',name='underground-belt',position={x=0,y=5},belt_to_ground_type='output',neighbours=entrance,
    get_max_transport_line_index=function() return 4 end}
  local lines_out={line({id=5,{name='coal',count=2}}),line({id=6}),line(buried3),line(buried4)}
  exit.get_transport_line=function(i) return lines_out[i] end
  local job={belt_items={},where={}}
  local ctx={si=1,surface_name='platform-1'}
  C.read_entity(job,{index=1},entrance,ctx); C.read_entity(job,{index=1},exit,ctx)
  eq(job.belt_items[1].coal,1+8+2,'the buried 8 once')
end
print('d22_batch96 BF1 census underground lines once: ok')

-- 3. the damaged list: one read of every entity seeds it; then the game's damage events add to it, and a read checks
-- only those (healed or gone ones drop out); a full list reads every entity again
do
  local st={}
  local PA=dofile('mod/agent-harness_0.1.0/platalerts.lua'){state=function() return st end}
  local own={name='player'}
  local pl={index=4,name='Asterion',valid=true}
  local surface={name='platform-4',platform=pl}
  pl.surface=surface
  local function ent(u,h,m) return {valid=true,unit_number=u,health=h,max_health=m,force=own,surface=surface,name='belt'..u,position={x=u,y=0}} end
  local a,b,c=ent(1,50,100),ent(2,100,100),ent(3,100,100)
  eq(PA.damaged(pl).seeded,false)
  PA.seed_damaged(pl,{a})
  eq(PA.damaged(pl).seeded,true)
  c.health=40
  PA.on_damaged({entity=c,force={name='enemy'},final_damage_amount=60,tick=game.tick})
  local set=PA.damaged(pl).set
  assert(set[1]==a and set[3]==c and set[2]==nil,'a and c')
  a.health=100  -- repaired
  PA.forget_damaged(pl,{1})
  assert(PA.damaged(pl).set[1]==nil)
  -- full: more than DAMAGED_MAX hit: not seeded any more (the next read reads every entity)
  for u=10,10+PA.DAMAGED_MAX do local e=ent(u,1,100); PA.on_damaged({entity=e,force={name='enemy'},final_damage_amount=1,tick=game.tick}) end
  eq(PA.damaged(pl).seeded,false)
end
print('d22_batch96 BF1 damaged list from damage events: ok')

-- 4. lasts: found by halving the quarter-minute steps, the same minute as stepping one at a time
do
  local AM=dofile('mod/agent-harness_0.1.0/ammomodel.lua'){}
  local function stepping(at)
    if at(1440)>0 then return nil end
    local lo,hi=0,0.25
    while at(hi)>0 do lo,hi=hi,hi+0.25 end
    for _=1,8 do local mid=(lo+hi)/2; if at(mid)>0 then lo=mid else hi=mid end end
    return hi
  end
  -- a model whose cap binds: made at most 50 over any time, used 3 a minute, from 400 aboard
  local cases={{stock=400,made=10,used=3,cap=50},{stock=5,made=1,used=3,cap=100},{stock=3000,made=2,used=4,cap=0},{stock=0,made=1,used=2,cap=0}}
  for _,c in ipairs(cases) do
    local m={held={x=c.stock},received={}}
    function m.made(name,made,t) return math.min(made*t,c.cap) end
    function m.cap(name) return {} end
    function m.left(name,made,used,t,stock) return (stock or m.held[name] or 0)+m.made(name,made,t)-used*t end
    -- the module's lasts on this model (its body reads m.cap, m.left)
    local new=AM.lasts_of(m,'x',c.made,c.used,c.stock)
    local old=stepping(function(t) return m.left('x',c.made,c.used,t,c.stock) end)
    eq(new,old,'stock '..c.stock)
  end
end
print('d22_batch96 BF1 lasts by halving: ok')

-- 5. thrust: the thrusters found once a tick, read and after_pumps share it
do
  local n=0
  local thr={valid=true,name='thruster',position={x=0,y=0},fluidbox=setmetatable({},{__len=function() return 0 end})}
  local s={index=9,find_entities_filtered=function(f) if f.type=='thruster' then n=n+1; return {thr} end return {} end,
    count_entities_filtered=function() return 0 end}
  local TH=dofile('mod/agent-harness_0.1.0/thrust.lua'){}
  local pl={surface=s,force={name='player'}}
  TH.read(pl); TH.read(pl)
  eq(n,1,'one find in the tick')
  game.tick=game.tick+1
  TH.read(pl)
  eq(n,2,'a new tick finds again')
end
print('d22_batch96 BF1 thrusters once a tick: ok')
defines,game=nil,nil

-- BF1 part 2: the platforms read (dispatch platforms: the stream's platforms {platform} 4 a second, 43.6-47.9 ms a
-- second on world n; compact 19-22 ms, every full row 70-84 ms and 118 KB on the copy)
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end

-- 6. full rows 2 a page with no platform named: page, pages, count, next; the departure lines from one walk
do
  game={tick=600}
  defines={space_platform_state={waiting_at_station=2},inventory={hub_main=1,hub_trash=2,turret_ammo=3},flow_precision_index={ten_minutes=1}}
  prototypes={item={}}
  local plats={}
  for i=1,5 do plats[i]={valid=true,name='P'..i,index=i,state=2,space_location={name='nauvis'}} end
  local p={index=1,force={platforms=plats},surface={find_entities_filtered=function() return {} end}}
  local st,walks={},0
  local space=dofile('mod/agent-harness_0.1.0/space.lua'){state=function() return st end,
    departure_all=function() walks=walks+1; return {P2={'sol\'s queue: platform_schedule P2'}} end,
    departure=function(name,by) return by[name] end}
  local r=space.platforms(p,{compact=false})
  eq(#r.platforms,2); eq(r.platforms[1].name,'P1'); eq(r.page,1); eq(r.pages,3); eq(r.count,5)
  eq(r.next,'platforms {compact: false, page: 2}')
  eq(r.platforms[2].departure[1],'sol\'s queue: platform_schedule P2'); eq(walks,1,'one walk a read')
  r=space.platforms(p,{compact=false,page=3})
  eq(#r.platforms,1); eq(r.platforms[1].name,'P5'); eq(r.next,nil)
  eq(#space.platforms(p,{compact=false,page=4}).platforms,0)
  eq(#space.platforms(p,{compact=false,platform='P4'}).platforms,1,'a platform named: its row, no page')
  fails(function() space.platforms(p,{page=2}) end,'page goes with every platform')
  fails(function() space.platforms(p,{compact=false,platform='P1',page=1}) end,'page goes with every platform')
  fails(function() space.platforms(p,{compact=false,page=0}) end,'page is 1 or more')
end
print('d22_batch96 BF1 platforms full rows paged: ok')

-- 7. the compact read: one count of both ghost kinds by name, and no ghost find or tile check with none; the turrets,
-- thrusters and tanks of the background read when a count finds no other aboard, else found
do
  game={tick=600}
  defines={space_platform_state={waiting_at_station=2},inventory={hub_main=1,hub_trash=2,turret_ammo=3},flow_precision_index={ten_minutes=1}}
  prototypes={item={['firearm-magazine']={type='ammo'},['iron-plate']={type='item'}}}
  local function inv(list) return {get_contents=function() return list end,count_empty_stacks=function() return 5 end,get_item_count=function() return 0 end} end
  local turret={valid=true,type='ammo-turret',get_inventory=function() return inv({{name='firearm-magazine',count=10}}) end}
  local tank={valid=true,type='storage-tank',fluidbox=setmetatable({},{__len=function() return 1 end,__index=function(_,i) return {name='thruster-fuel',amount=500} end})}
  local hub={valid=true,get_inventory=function(i) return inv({{name='firearm-magazine',count=40},{name='iron-plate',count=9}}) end,get_logistic_sections=function() return nil end}
  local finds,counts,aboard={},{},1
  local surface={find_entities_filtered=function(f) finds[#finds+1]=f
      if f.type=='ammo-turret' then return {turret} end
      if type(f.type)=='table' and f.type[1]=='thruster' then return {tank} end
      return {} end,
    count_entities_filtered=function(f) counts[#counts+1]=f
      if f.name then return 0 end
      return 1+aboard end}
  local pl={valid=true,name='Kestrel',index=3,state=2,space_location={name='nauvis'},surface=surface,hub=hub,force={name='player',get_fluid_production_statistics=function() return nil end}}
  local p={index=1,force={platforms={pl}}}
  local lists={turrets={turret},tanks={tank}}
  local space=dofile('mod/agent-harness_0.1.0/space.lua'){state=function() return {} end,
    platform_lists=function(x) eq(x,pl); return aboard==1 and lists or nil end}
  local r=space.platforms(p,{})
  eq(r.compact,true)
  has(r.lines[1],'ammo firearm-magazine 50'); has(r.lines[1],'thruster fuel 500 units'); has(r.lines[1],'ghosts lack nothing')
  local ghost_counts=0
  for _,f in ipairs(counts) do if f.name then ghost_counts=ghost_counts+1; eq(f.name[1],'entity-ghost'); eq(f.name[2],'tile-ghost'); eq(f.limit,1) end end
  eq(ghost_counts,1,'one ghost count')
  for _,f in ipairs(finds) do
    local t=type(f.type)=='table' and f.type[1] or f.type
    assert(t~='entity-ghost' and t~='tile-ghost','no ghost find with none counted')
    assert(t~='ammo-turret' and t~='thruster','the listed turrets and tanks')
  end
  -- a turret built since the background read: the lists are not used, they are found
  aboard,finds=2,{}
  r=space.platforms(p,{})
  has(r.lines[1],'ammo firearm-magazine 50')
  local found={}
  for _,f in ipairs(finds) do found[type(f.type)=='table' and f.type[1] or f.type]=true end
  eq(found['ammo-turret'],true); eq(found.thruster,true)
end
print('d22_batch96 BF1 compact platforms read: ok')

-- 8. freight.platform_lists: the background read's turrets and tanks (valid ones) while a count of them aboard finds
-- no more; nil before a read and when one was built since
do
  game={tick=600}
  local st={platform_belts={}}
  local F=dofile('mod/agent-harness_0.1.0/freight.lua'){state=function() return st end}
  local n=2
  local pl={index=4,force={name='player'},surface={count_entities_filtered=function(f)
    eq(f.type[1],'ammo-turret'); eq(f.type[2],'thruster'); eq(f.type[3],'storage-tank'); eq(f.force.name,'player'); return n end}}
  eq(F.platform_lists(pl),nil,'no read yet'); eq(st.platform_belts[4].wanted,600,'marked as read lately')
  local gone={valid=false}
  st.platform_belts[4].done={tick=500,belts={},hands={},turrets={{valid=true},gone},tanks={{valid=true}}}
  local l=F.platform_lists(pl)
  eq(#l.turrets,1); eq(#l.tanks,1); eq(l.tick,500)
  n=3
  eq(F.platform_lists(pl),nil,'one more aboard than listed')
  eq(F.platform_lists({name='fake'}),nil,'no index')
end
print('d22_batch96 BF1 platform_lists: ok')

-- 9. departure: every platform's lines from one walk of the queues and orders, the same as one platform's
do
  local st={queues={[1]={pending={{action='wait_until',args={['until']='item_count',item='coal'}},{action='platform_schedule',args={platform='A',stops={{station='nauvis'}}}}}}},
    remote_queues={[2]={current={action='platform_schedule',args={platform='B',stops={{station='vulcanus'}}}}}},
    orders={[1]={list={{name='ship',when={['until']='time'},steps={{action='platform_schedule',args={platform='A',stops={{station='gleba'}}}}}}}}}}
  local D=dofile('mod/agent-harness_0.1.0/departure.lua'){state=function() return st end,name_of=function(i) return ({'sol','luna'})[i] end}
  local all=D.all()
  eq(#all.A,2); eq(#all.B,1); eq(all.C,nil)
  for _,name in ipairs({'A','B'}) do
    local one=D.lines(name)
    eq(#one,#all[name]); for i,l in ipairs(one) do eq(l,all[name][i]) end
    eq(D.lines(name,all),all[name])
  end
  has(all.A[1],'platform_schedule A'); has(all.B[1],'luna\'s remote queue'); eq(D.lines('C',all),nil)
end
print('d22_batch96 BF1 departure lines in one walk: ok')

-- 10. platjobs.all(want): only the rows of the platforms a reply has
do
  game={tick=600}
  local st={queues={[1]={pending={{action='drop',args={platform='A',item='coal',count=5}},{action='drop',args={platform='B',item='coal',count=7}}}}}}
  local J=dofile('mod/agent-harness_0.1.0/platjobs.lua'){state=function() return st end,remote_keys=function() return {} end,lookup=function() return {name='sol'} end}
  local all=J.all()
  assert(all.A and all.B,'both without want')
  local some=J.all({B=true})
  eq(some.A,nil); eq(#some.B,1); eq(J.lines('B',some)[1],J.lines('B',all)[1])
end
print('d22_batch96 BF1 jobs lines for the rows shown: ok')

-- 11. with fields (__want from the fields wrapper) a row makes only the parts those fields need
do
  game={tick=600}
  defines={space_platform_state={waiting_at_station=2},inventory={hub_main=1,hub_trash=2,turret_ammo=3},flow_precision_index={ten_minutes=1}}
  prototypes={item={}}
  local made={}
  local function count(k,v) return function() made[k]=(made[k] or 0)+1; return v end end
  local hub={valid=true,position={x=0,y=0},get_inventory=function() return {get_contents=function() return {{name='coal',count=3}} end,count_empty_stacks=function() return 1 end,
    get_item_count=function() return 0 end} end,get_logistic_sections=count('sections',nil)}
  local surface={find_entities_filtered=function() return {} end,count_entities_filtered=function() return 0 end}
  local pl={valid=true,name='P1',index=1,state=2,space_location={name='nauvis'},surface=surface,hub=hub,force={}}
  local p={index=1,force={platforms={pl}},surface={find_entities_filtered=function() return {} end,planet=nil}}
  local fr={read=count('freight',{}),receipts=count('landed'),freshness=count('spoiling'),ammo=count('ammo','ammo line'),incoming=count('incoming'),
    leg=function() return nil end,where=function() return {} end}
  local space=dofile('mod/agent-harness_0.1.0/space.lua'){state=function() return {} end,freight=fr,defense=count('defense','def'),
    engine=count('engine'),thrust_after=count('thrust'),wait_need=count('wait'),launch_need=count('launch')}
  local r=space.platforms(p,{platform='P1',compact=false,__want={ammo_rates=true,hub_items=true}})
  eq(r.platforms[1].ammo_rates,'ammo line'); eq(r.platforms[1].hub_items,'coal*3')
  eq(made.ammo,1)
  for _,k in ipairs({'freight','landed','spoiling','incoming','defense','engine','thrust','wait','launch','sections'}) do eq(made[k],nil,k..' not made') end
  made={}
  r=space.platforms(p,{platform='P1',compact=false})
  for _,k in ipairs({'freight','ammo','defense','engine','thrust','wait','launch','sections'}) do eq(made[k],1,k..' made without fields') end
  eq(r.platforms[1].defense,'def')
end
print('d22_batch96 BF1 a row makes only the fields asked: ok')

-- BF1 part 3: the alerts' background read (on world n a game second held 164 ms of pushalerts.slice, another 141 ms of
-- pushalerts.drill_sites: depleted-drill lookups of 40-60 ms each on the copy, and mine forecasts up to 28 ms)

-- 12. a slice reads up to 150 entities and as many as its estimated cost (5,000) covers; after each step the job waits
-- its cost's share of 20,000 a second, so no 60 ticks hold more than that and one step
do
  game={tick=100}
  defines={entity_status={working=0,no_power=1,low_power=2,no_fuel=3,no_minable_resources=9},inventory={},alert_type={}}
  local force={name='player',players={{}},is_chunk_visible=function() return true end}
  local surface={name='nauvis',index=1}
  game.surfaces={nauvis=surface};game.forces={player=force}
  local ents={}
  for i=1,400 do ents[i]={valid=true,type='assembling-machine',name='assembling-machine-2',status=0,force=force,surface=surface,unit_number=i,
    position={x=(i%20)+.5,y=math.floor(i/20)+.5}} end
  for i=401,700 do ents[i]={valid=true,type='container',name='iron-chest',status=0,force=force,surface=surface,unit_number=i,
    position={x=(i%20)+.5,y=math.floor(i/20)+.5}} end
  surface.find_entities_filtered=function(f)
    if not f.area then return ents end
    local out={}
    for _,e in ipairs(ents) do local q=e.position; if q.x>=f.area[1][1] and q.x<f.area[2][1] and q.y>=f.area[1][2] and q.y<f.area[2][2] then out[#out+1]=e end end
    return out
  end
  local st,steps={},{}
  local A=dofile('mod/agent-harness_0.1.0/pushalerts.lua'){state=function() return st end,agents=function() return {} end,who=function() return 'opus' end,
    timed=function(name,f,...)
      local j=st.push_jobs.player; local list,at=j.list,j.at
      f(...)
      local n=list and at and ((j.list==list and j.at or #list+1)-at) or 0
      local cost=0
      if name=='pushalerts.slice' then for i=at,at+n-1 do cost=cost+(list[i].type=='assembling-machine' and 75 or 10) end
      else cost=({['pushalerts.merge']=10000,['pushalerts.alerts']=5000,['pushalerts.networks']=1000})[name] or 500 end
      steps[#steps+1]={name=name,tick=game.tick,n=n,cost=cost}
    end}
  A.tick(game.tick)
  for _=1,6000 do game.tick=game.tick+1; A.tick(game.tick); if not st.push_jobs.player then break end end
  eq(st.push_jobs.player,nil,'the pass ends')
  local read,most=0,0
  for _,s in ipairs(steps) do
    if s.name=='pushalerts.slice' then
      read=read+s.n; most=math.max(most,s.n); assert(s.cost<5000+75,'a slice stops at its cost: '..s.cost)
    end
  end
  eq(read,700,'every entity read'); eq(most,150,'chests: 150 a slice')
  for i,s in ipairs(steps) do
    local sum=0
    for j=i,#steps do if steps[j].tick<s.tick+60 then sum=sum+steps[j].cost end end
    assert(sum<=20000+5075,'60 ticks from '..s.tick..' hold '..sum)
  end
  local first,last=steps[1].tick,steps[#steps].tick
  assert(last-first>=60*(400*75+300*10)/20000-60,'spread: '..(last-first)..' ticks')
end
print('d22_batch96 BF1 alerts read paced by its cost: ok')

-- 13. drill_sites: chunk keys and candidate order without text or a table each, and the drills and ghosts round the
-- candidates found once (a spot no box touches needs no find); the same sites, checks and names as before
do
  local D=dofile('mod/agent-harness_0.1.0/drill_sites.lua'){state=function() return {} end,integer=function(v,d) return v or d end,
    entity=function() error('no entity') end,position=function(q) return {x=q.x or q[1],y=q.y or q[2]} end,on_surface=function(p) return p end}
  game={tick=10}
  defines={entity_status={no_minable_resources=9},build_check_type={manual=1}}
  local proto={type='mining-drill',name='electric-mining-drill',mining_drill_radius=2.49,tile_width=3,tile_height=3,resource_categories={basic=true}}
  prototypes={entity={['electric-mining-drill']=proto,coal={type='resource',resource_category='basic'}}}
  local function run(with_boxes)
    local finds,places={},0
    local ore={}
    for x=-12,12 do for y=-12,12 do ore[#ore+1]={valid=true,position={x=x+.5,y=y+.5},amount=100,name='coal'} end end
    local drills={{valid=true,type='mining-drill',name='electric-mining-drill',position={x=4.5,y=.5}},
      {valid=true,type='entity-ghost',ghost_name='transport-belt',name='entity-ghost',position={x=-3.5,y=2.5}}}
    for _,d in ipairs(drills) do
      local h=d.type=='mining-drill' and 1.4 or 0.4
      if with_boxes then d.bounding_box={left_top={x=d.position.x-h,y=d.position.y-h},right_bottom={x=d.position.x+h,y=d.position.y+h}} end
      d.h=h
    end
    local surface={name='nauvis',find_entities_filtered=function(f)
      finds[#finds+1]=f
      if f.type=='resource' and not f.invert then
        local out={}
        for _,o in ipairs(ore) do local q=o.position; if q.x>=f.area[1][1] and q.x<f.area[2][1] and q.y>=f.area[1][2] and q.y<f.area[2][2] then out[#out+1]=o end end
        return out
      end
      if type(f.type)=='table' then
        local out={}
        for _,d in ipairs(drills) do
          local q=d.position
          if q.x+d.h>f.area[1][1] and q.x-d.h<f.area[2][1] and q.y+d.h>f.area[1][2] and q.y-d.h<f.area[2][2] then out[#out+1]=d end
        end
        return out
      end
      return {}
    end,can_place_entity=function(a) places=places+1; return math.abs(a.position.x)+math.abs(a.position.y)>3 end}
    local force={name='player',is_chunk_visible=function() return true end}
    local p={force=force,surface=surface,position={x=.5,y=.5}}
    local r=D.read(p,{position={x=.5,y=.5},resource='coal',drill='electric-mining-drill',radius=6,limit=5})
    local occupant_finds=0
    for _,f in ipairs(finds) do if type(f.type)=='table' and f.limit==8 then occupant_finds=occupant_finds+1 end end
    return r,occupant_finds,places
  end
  local a,fa,pa=run(false)
  local b,fb,pb=run(true)
  eq(#a.sites,5); eq(#b.sites,5)
  for i=1,5 do eq(a.sites[i].position.x,b.sites[i].position.x); eq(a.sites[i].position.y,b.sites[i].position.y); eq(a.sites[i].amount,b.sites[i].amount); eq(a.sites[i].distance,b.sites[i].distance) end
  eq(a.checks,b.checks); eq(a.line,b.line); eq(a.occupied,b.occupied); eq(pa,pb)
  for i=2,5 do
    local x,y=a.sites[i-1],a.sites[i]
    assert(x.distance<y.distance or x.distance==y.distance and (x.position.x<y.position.x or x.position.x==y.position.x and x.position.y<y.position.y),'nearest first, then x, then y')
  end
  assert(a.occupied and a.occupied>=1,'a drill there is named'); assert(fb<fa,'fewer finds with boxes: '..fb..' of '..fa)
  prototypes=nil
end
print('d22_batch96 BF1 drill sites: ok')

-- BF1 part 4: platform_endurance (Kestrel IVb 66 ms on world n) and platform_supply (about 20 ms)

-- 14. the hull's width from foundation counts in columns, no tile read; the same as the first and last column holding one
do
  local cols={}
  for x=-7,12 do cols[x]=true end
  cols[3]=nil  -- a gap inside does not matter
  local counts=0
  local s={find_entities_filtered=function(f) eq(f.type,'thruster'); return {{},{},{},{},{},{}} end,
    find_tiles_filtered=function() error('no tile read') end,
    count_tiles_filtered=function(f)
      counts=counts+1
      eq(f.name,'space-platform-foundation'); eq(f.area[1][2],-128); eq(f.area[2][2],128); eq(f.limit,1)
      for x=f.area[1][1],f.area[2][1]-1 do if cols[x] then return 1 end end
      return 0
    end}
  local F=dofile('mod/agent-harness_0.1.0/freight.lua'){state=function() return {} end}
  local g=F.geometry({surface=s,force={name='player'}})
  eq(g.width,20); eq(g.thrusters,6)
  assert(counts<=2*(8+32),'counted by strips: '..counts)
  cols={}
  eq(F.geometry({surface=s,force={name='player'}}).width,nil,'no foundation')
  cols={[-128]=true,[127]=true}
  eq(F.geometry({surface=s,force={name='player'}}).width,256,'the edges of the area')
end
print('d22_batch96 BF1 hull width by counts: ok')

-- 15. platform_supply's chunk trace: each chunk type's walk takes a belt's outputs, an inserter's filter and target and a
-- machine's recipe from what the first walk read (the same rows)
do
  game={tick=0}
  defines={inventory={hub_main=1},entity_status={working=1,full_output=2}}
  prototypes={item={['metallic-asteroid-chunk']={},['oxide-asteroid-chunk']={},['carbonic-asteroid-chunk']={}}}
  local n,reads=0,{}
  local function ent(t)
    n=n+1; t.valid=true; t.unit_number=n; t.position=t.position or {x=n,y=0}
    local raw={}
    for k,v in pairs(t) do if k=='belt_neighbours' or k=='drop_target' then raw[k]=v; t[k]=nil end end
    return setmetatable(t,{__index=function(_,k) if raw[k]~=nil then reads[k]=(reads[k] or 0)+1; return raw[k] end end})
  end
  local hub=ent{name='space-platform-hub',type='space-platform-hub',get_inventory=function() return {count_empty_stacks=function() return 3 end} end}
  local cm=ent{name='crusher',type='assembling-machine',status=1,prototype={crafting_categories={crushing=true}},
    get_recipe=function() reads.recipe=(reads.recipe or 0)+1; return {name='metallic-asteroid-crushing',ingredients={{name='metallic-asteroid-chunk',amount=1}}} end}
  local b3=ent{name='transport-belt',type='transport-belt',belt_neighbours={outputs={}}}
  local b2=ent{name='transport-belt',type='transport-belt',belt_neighbours={outputs={b3}}}
  local b1=ent{name='transport-belt',type='transport-belt',belt_neighbours={outputs={b2}}}
  local col=ent{name='asteroid-collector',type='asteroid-collector',filter_slot_count=0}
  local function ins(from,to) return ent{name='inserter',type='inserter',pickup_target=from,drop_target=to,use_filters=false} end
  local list={ins(col,b1),ins(b3,cm),ins(b3,hub)}
  local s={find_entities_filtered=function(f)
    if f.type=='inserter' then return list elseif f.type=='asteroid-collector' then return {col} elseif f.type=='assembling-machine' then return {cm} end
    return {} end}
  local P=dofile('mod/agent-harness_0.1.0/platsupply.lua'){}
  local rows=P.trace(s,{},hub)
  eq(#rows,3)
  eq(rows[2],'metallic-asteroid-chunk: 1 collector; goes to crusher (2,0) metallic-asteroid-crushing, the hub (over 3 belt tiles)')
  eq(rows[1],'carbonic-asteroid-chunk: 1 collector; goes to the hub (over 3 belt tiles)')
  eq(reads.belt_neighbours,3,'each belt\'s outputs once for 3 chunk types')
  eq(reads.drop_target,3,'each inserter\'s target once')
  defines,prototypes=nil,nil
end
print('d22_batch96 BF1 chunk trace reads once: ok')

-- BF1 part 5 (operator 17:26: flight_watch reads 36 ms on world n, board.team up to 63 ms with platalerts.lines 51)

-- 16. the platform alerts' expired scans read in the background, the oldest of those read lately, one a step; a reply
-- takes a scan up to twice as old while the background runs
do
  game={tick=100000}
  defines={space_platform_state={on_the_path=4,waiting_at_station=6},inventory={turret_ammo=3,hub_main=1}}
  prototypes={item={}}
  local st={}
  local finds={}
  local function plat(i)
    return {valid=true,index=i,name='P'..i,state=6,surface={name='platform-'..i,find_entities_filtered=function() finds[#finds+1]=i; return {} end},force={name='player'}}
  end
  local p1,p2,p3=plat(1),plat(2),plat(3)
  game.forces={player={platforms={p1,p2,p3}}}
  local A=dofile('mod/agent-harness_0.1.0/platalerts.lua'){state=function() return st end,who=function() return 'sol' end}
  st.platform_alerts={by={[1]={scan={tick=game.tick-700},scan_wanted=game.tick-100,seq=0,minutes={},workers={}},
    [2]={scan={tick=game.tick-650},scan_wanted=game.tick-100,seq=0,minutes={},workers={}},
    [3]={scan={tick=game.tick-900},scan_wanted=game.tick-20000,seq=0,minutes={},workers={}}}}
  A.tick(game.tick+1)
  eq(#finds,0,'only every SCAN_STEP ticks')
  game.tick=game.tick+20-(game.tick%20)
  A.tick(game.tick)
  eq(#finds,1); eq(finds[1],1,'the oldest of those read lately (3 was not read in 5 minutes)')
  eq(st.platform_alerts.by[1].scan.tick,game.tick)
  A.tick(game.tick+20)
  eq(finds[2],2)
  A.tick(game.tick+40)
  eq(#finds,2,'none expired')
  eq(st.platform_alerts.scan_bg,game.tick+40)
  defines,prototypes=nil,nil
end
print('d22_batch96 BF1 platform scans in the background: ok')

-- 17. the fuel outlook's thrusters and tanks from the platform's background read when it has them
do
  game={tick=600}
  defines={flow_precision_index={one_minute=1}}
  local tank={valid=true,type='storage-tank',fluidbox=setmetatable({},{__len=function() return 1 end,__index=function() return {name='thruster-fuel',amount=700} end})}
  local thr={valid=true,type='thruster',fluidbox=setmetatable({},{__len=function() return 2 end,__index=function(_,i) return {name=i==1 and 'thruster-fuel' or 'thruster-oxidizer',amount=100} end})}
  local found=0
  local pl={name='K',index=2,force={get_fluid_production_statistics=function() return nil end},
    surface={find_entities_filtered=function() found=found+1; return {tank,thr} end},space_location={name='nauvis'}}
  local lists
  local E=dofile('mod/agent-harness_0.1.0/endurance.lua'){platform_lists=function() return lists end,leg=function() return nil end}
  local o=E.fuel_outlook(pl)
  eq(found,1,'no lists: found'); eq(o.rows[1].held,800); eq(o.rows[1].in_tanks,700); eq(o.rows[2].held,100)
  lists={turrets={},tanks={tank,thr}}
  local o2=E.fuel_outlook(pl)
  eq(found,1,'the lists, no find'); eq(o2.line,o.line)
end
print('d22_batch96 BF1 fuel outlook from the background lists: ok')
