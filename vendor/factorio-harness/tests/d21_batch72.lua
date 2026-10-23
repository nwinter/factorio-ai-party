-- Run from repository root: lua tests/d21_batch72.lua
-- d21 batch72 AH1 (Sol #1720: Kestrel IVc's platform read gave 1 turret empty and platform_defense 370 ticks later all
-- 11 armed; polling told neither how long nor which turret). flightwatch.lua: a platform's ammo turrets read once a
-- second from now or its next departure to its next arrival or a time limit: least ammunition, samples and ticks
-- empty, the longest run, the feed (the ammunition trace) at the start, in the first empty run and at the end; damage,
-- losses, repair packs used, thruster fuel and oxidizer at the start and the end; kept until cleared.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
defines={inventory={turret_ammo=1,hub_main=1},space_platform_state={on_the_path=1,waiting_at_station=2}}
prototypes={item={['repair-pack']={type='repair-tool'},['firearm-magazine']={type='ammo'},rocket={type='ammo'}}}
local uid=0
local function turret(name,x,y,n)
  uid=uid+1
  local t={valid=true,name=name,type='ammo-turret',unit_number=100+uid,position={x=x,y=y},count=n,ammo=name=='rocket-turret' and 'rocket' or 'firearm-magazine'}
  t.get_inventory=function() return {get_item_count=function() return t.count end,[1]={valid_for_read=t.count>0,name=t.ammo}} end
  return t
end
local t1,t2,t3=turret('gun-turret',-13,-6,10),turret('gun-turret',0,-10,11),turret('rocket-turret',4.5,-8.5,12)
local turrets={t1,t2,t3}
local used=40
local hubpacks=146
local conn={from={name='aquilo'},to={name='gleba'}}
local surface={name='platform-7',find_entities_filtered=function() local o={} for _,t in ipairs(turrets) do if t.valid then o[#o+1]=t end end return o end}
local force={name='player',get_item_production_statistics=function() return {get_output_count=function(n) return n=='repair-pack' and used or 0 end} end}
local pl={valid=true,index=7,name='Kestrel IVc',surface=surface,force=force,state=1,space_connection=conn,space_location=nil,
  hub={get_inventory=function() return {get_contents=function() return {{name='repair-pack',count=hubpacks},{name='rocket',count=983}} end} end}}
force.platforms={[7]=pl}
game={tick=1000,forces={player=force}}
local p={name='sol',force=force,index=1}
local st={}
local hits={hits=5,damage=100,entities={['gun-turret']=100},by={['small-metallic-asteroid']=5}}
local fuelrows={{name='thruster-fuel',held=24946,in_tanks=24000},{name='thruster-oxidizer',held=25000,in_tanks=24000}}
local trace_calls,trace={},nil
local losses={}
local F=dofile('mod/agent-harness_0.1.0/flightwatch.lua'){state=function() return st end,who=function(q) return q.name end,
  platform=function(q,name) assert(name==pl.name,'no platform '..tostring(name)); return pl end,
  fuel_outlook=function() local o={} for i,r in ipairs(fuelrows) do o[i]={name=r.name,held=r.held,in_tanks=r.in_tanks} end return {rows=o} end,
  hits=function() return hits end,
  losses=function(f,s,since) local o={} for _,r in ipairs(losses) do if r.t>since then o[#o+1]=r end end return o,#o end,
  trace=function(q,age) trace_calls[#trace_calls+1]={game.tick,age}; return trace end,
  supply_kind=function(row) return row.kind,row.all_gated end,
  leg=function(q) local c=q.space_connection; if not c then return nil end; if q.back then return {from=c.to.name,to=c.from.name} end return {from=c.from.name,to=c.to.name} end}
local function run(to) while game.tick<to do game.tick=game.tick+1; if F.due(game.tick) then F.tick(game.tick) end end end
local function trace_at(started,done,kind2,reach2)
  return {read_started=started,read_tick=done,rows={
    {entity=t1,kind='maker',reaches=60,stops={},gated={}},
    {entity=t2,kind=kind2,reaches=reach2,stops=kind2=='preload' and {'fast-inserter (0.5,-7.5): no inserter puts anything on the belts upstream of fast-transport-belt (0.5,-5.5): the 0 on them, then dry'} or {},gated={}},
    {entity=t3,kind='hub',reaches=983,stops={},gated={}}}}
end
-- from now, flying: a trace read before the start counts as the start's
trace=trace_at(400,900,'maker',40)
local r=F.call(p,{platform='Kestrel IVc'})
eq(r.watch.id,1); eq(r.watch.state,'watching'); eq(r.watch.leg,'aquilo->gleba')
assert(r.line:find('watching 3 ammo turrets %(0 railguns%) and 0 accumulators once a second'),r.line)
local w=st.flightwatch.list[1]
eq(w.turrets[2].feed_start.kind,'maker','the feed at the start'); eq(w.turrets[2].feed_start.reaches,40)
-- t2 empties for 3 samples (180 ticks), refills, empties 1 sample; t3 destroyed
run(1060+30)
t2.count=0
run(1060+60*3+30)
eq(w.turrets[2].runs,1); eq(w.turrets[2].empty_samples,3)
-- a trace begun after the run began: the feed in it
trace=trace_at(1300,1350,'preload',0)
t2.count=5
run(1060+60*12+30)
eq(w.turrets[2].feed_empty.kind,'preload','the first trace begun after it first read empty'); eq(w.turrets[2].empty_samples,3)
t2.count=0
run(1060+60*13+30)
t2.count=8
t3.valid=false
hits={hits=12,damage=430.5,entities={['gun-turret']=300.5,['rocket-turret']=130},by={['small-metallic-asteroid']=10,['medium-oxide-asteroid']=2}}
losses={{n='rocket-turret',x=4.5,y=-8.5,t=1900,c='medium-oxide-asteroid'}}
used=46; hubpacks=140
fuelrows={{name='thruster-fuel',held=18000,in_tanks=17000},{name='thruster-oxidizer',held=21000,in_tanks=20000}}
run(1060+60*20+30)
-- arrival
pl.state, pl.space_connection, pl.space_location = 2, nil, {name='gleba'}
run(1060+60*21+30)
eq(w.state,'done'); eq(w.why,'arrived at gleba')
local ev=st.flightwatch.events[#st.flightwatch.events]
eq(ev.to,'sol'); assert(ev.text:find('flight watch #1 on Kestrel IVc ended %(arrived at gleba%)'),ev.text)
assert(ev.text:find('1 of 3 ammo turrets read empty; the longest run 3s %(180 ticks%), gun%-turret %(0,%-10%) #102 from %+2s'),ev.text)
eq(w.turrets[1].e,nil,'entities let go once done')
r=F.call(p,{id=1})
local x=r.watch
eq(x.turrets[1].unit_number,102,'the turret that read empty first'); eq(x.turrets[2].unit_number,101); local s1,s2=x.turrets[1],x.turrets[2]; x.turrets[1],x.turrets[2]=s2,s1; x.lines[1],x.lines[2]=x.lines[2],x.lines[1]
eq(x.turrets[2].least,0); eq(x.turrets[2].empty_samples,4); eq(x.turrets[2].empty_ticks,240); eq(x.turrets[2].empty_runs,2); eq(x.turrets[2].longest_empty_ticks,180)
eq(x.turrets[2].longest_from_tick,1131); eq(x.turrets[2].now,8); eq(x.turrets[1].least,10); eq(x.turrets[1].empty_samples,0)
eq(x.turrets[3].gone_tick,1911,'gone at the first sample it was not valid'); eq(x.turrets[3].least,12)
eq(x.damage.hits,7); eq(x.damage.damage,330.5); eq(x.damage.entities[1],'gun-turret 200.5'); eq(x.damage.entities[2],'rocket-turret 130')
eq(x.damage.by[1],'small-metallic-asteroid 5'); eq(x.lost_count,1); assert(x.lost[1]:find('^rocket%-turret %(4.5,%-8.5%) at %+'),x.lost[1])
eq(x.repair_packs_used,6); eq(x.hub_repair_packs.start,146); eq(x.hub_repair_packs['end'],140)
eq(x.fuel.start['thruster-fuel'].held,24946); eq(x.fuel['end']['thruster-fuel'].held,18000); eq(x.fuel['end']['thruster-oxidizer'].in_tanks,20000)
assert(x.line:find('thruster%-fuel 24946 %-> 18000, thruster%-oxidizer 25000 %-> 21000'),x.line)
assert(x.lines[2]:find('after it first read empty: preload, 0 can reach it; fast%-inserter'),x.lines[2])
assert(x.note:find('once a second'))
-- feed traces: asked at the start, then 10 s after a turret began to read empty, else once a minute
eq(trace_calls[1][1],1000); eq(trace_calls[2][2],600,'soon after an empty run began')
-- read: kept KEEP_READ after its first read, unread kept
eq(st.flightwatch.list[1].read_tick,game.tick)
-- from departure: armed while stopped at gleba, begins when it leaves
t3=turret('rocket-turret',4.5,-8.5,12); turrets={t1,t2,t3}
r=F.call(p,{platform='Kestrel IVc',from='departure',minutes=1})
eq(r.watch.state,'armed'); eq(r.watch.id,2); assert(r.line:find('begins at its next departure'),r.line)
run(game.tick+300)
eq(st.flightwatch.list[2].state,'armed')
local e0=#st.flightwatch.events
pl.state, pl.space_connection, pl.space_location, pl.back = 1, {from={name='nauvis'},to={name='gleba'}}, nil, true
run(game.tick+60)
local w2=st.flightwatch.list[2]
eq(w2.state,'watching'); eq(w2.leg,'gleba->nauvis','a connection flown back: the way it flies'); eq(#w2.turrets,3)
assert(st.flightwatch.events[e0+1].text:find('began: it left for gleba%->nauvis'),st.flightwatch.events[e0+1].text)
-- a turret built meanwhile is added within a minute
local t4=turret('gun-turret',8,8,0); turrets[#turrets+1]=t4
run(game.tick+3660)
eq(w2.state,'done'); eq(w2.why,'its time limit, 1 min'); eq(#w2.turrets,4); assert(w2.turrets[4].added,'built meanwhile')
-- a read gives SHOW turret rows, the rest counted
F.SHOW=2
local rr=F.call(p,{id=w2.id}).watch
eq(#rr.turrets,2); eq(rr.turrets_more,2); assert(rr.turrets_more_line:find('^2 more ammo turrets, none read empty'),rr.turrets_more_line)
F.SHOW=24
w2.read_tick=nil
-- a second watch on the platform while one is not read: refused without replace
local ok,err=pcall(F.call,p,{platform='Kestrel IVc'})
assert(not ok and tostring(err):find('done and not read'),tostring(err))
r=F.call(p,{platform='Kestrel IVc',replace=true}); eq(r.watch.replaced,2)
-- the listing, clear
r=F.call(p,{})
eq(#r.watches,3,'the replaced one kept (d22 batch116 BY1)'); eq(r.watches[2].replaced_by,3); assert(r.lines[1]:find('^flight watch #1 on Kestrel IVc, aquilo%->gleba: watched'),r.lines[1])
r=F.call(p,{id=3,clear=true}); eq(r.cleared,3)
-- a read one is dropped KEEP_READ after it was read
F.tick(game.tick+F.KEEP_READ+1)
eq(#st.flightwatch.list,1,'the read watch dropped; the replaced one not read kept')
F.tick(game.tick+F.WAIT+1)
eq(#st.flightwatch.list,0,'the replaced one not read dropped WAIT after its replace')
-- bad args
ok,err=pcall(F.call,p,{platform='Kestrel IVc',minutes=0}); assert(not ok and tostring(err):find('minutes: 1..480'))
ok,err=pcall(F.call,p,{platform='Kestrel IVc',from='later'}); assert(not ok and tostring(err):find('from:'))
-- started while stopped: the leg once it leaves
pl.state, pl.space_connection, pl.space_location, pl.back = 2, nil, {name='nauvis'}, nil
F.call(p,{platform='Kestrel IVc'})
local w5=st.flightwatch.list[#st.flightwatch.list]
eq(w5.leg,'nauvis')
pl.state, pl.space_connection, pl.space_location = 1, {from={name='nauvis'},to={name='vulcanus'}}, nil
run(game.tick+60)
eq(w5.leg,'nauvis->vulcanus'); eq(F.call(p,{id=w5.id}).watch.at_start,'nauvis')
F.call(p,{id=w5.id,clear=true})
-- the platform gone while watching
F.call(p,{platform='Kestrel IVc'})
force.platforms={}; pl.valid=false   -- (BS1) a deleted platform's object reads invalid; the watch keeps it
run(game.tick+60)
pl.valid=true
local wg=st.flightwatch.list[#st.flightwatch.list]; eq(wg.why,'the platform is gone'); assert(F.call(p,{id=wg.id}).line:find('ended: the platform is gone'))
pl.valid=true
-- the alert lines: to the setter, once
local h={}
local lines=F.lines(p,h)
assert(#lines>=3,'events told'); eq(F.lines(p,h),nil,'once')
-- ammofeed.get gives the read's ticks
local A=dofile('mod/agent-harness_0.1.0/ammofeed.lua'){state=function() return {ammofeed={jobs={},done={[7]={tick=5000,started=4800,tr={rows={}}}}}} end}
local sv=game.tick; game.tick=5100
pl.surface.count_entities_filtered=function() return 500 end
local tr=A.get(pl,3600,true)
eq(tr.read_tick,5000); eq(tr.read_started,4800)
game.tick=sv
print('d21_batch72 AH1 flight watch: ok')
