-- Run from repository root: lua tests/d22_batch109.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path   -- (d24 batch152) modules require qflow
-- d22 batch109 BS1 (Sol #1952: 8 flight watches a force kept Cinder's watch out while 18 platforms flew). A force may
-- hold one counting watch per platform it has (armed, watching, or done and not read); a done one read stops counting
-- and is kept KEEP_READ, at most KEEP_DONE a force. {} lists the limit, how many count and which; a start at the limit
-- names them and how to end one. Each watch reads on its own tick of the second (its phase).
local function eq(a,b,m) if a~=b then error((m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b),2) end end
defines={inventory={turret_ammo=1,hub_main=1},space_platform_state={on_the_path=1,waiting_at_station=2}}
prototypes={item={['firearm-magazine']={type='ammo'}}}
local uid=0
local function turret(x,y)
  uid=uid+1
  local t={valid=true,name='gun-turret',type='ammo-turret',unit_number=100+uid,position={x=x,y=y},count=10}
  t.get_inventory=function() return {get_item_count=function() return t.count end,[1]={valid_for_read=t.count>0,name='firearm-magazine'}} end
  return t
end
local force={name='player',get_item_production_statistics=function() return {get_output_count=function() return 0 end} end}
local reads={}   -- platform index -> ammo reads
local function platform(i,name,flying)
  local t=turret(i,0)
  local ti=t.get_inventory
  t.get_inventory=function() reads[i]=(reads[i] or 0)+1; return ti() end
  local s={name='platform-'..i,find_entities_filtered=function(f) if f.type=='ammo-turret' then return {t} end return {} end}
  return {valid=true,index=i,name=name,surface=s,force=force,state=flying and 1 or 2,space_connection=flying and {from={name='nauvis'},to={name='gleba'}} or nil,
    space_location=not flying and {name='nauvis'} or nil,hub={get_inventory=function() return {get_contents=function() return {} end} end}}
end
local names={'Asterion','Cinder','Swiftlet','Spindle'}
local pls={}
for i,n in ipairs(names) do pls[i]=platform(i,n,i<=2) end
force.platforms={}
for i,pl in ipairs(pls) do force.platforms[i]=pl end
game={tick=1000,forces={player=force}}
local p={name='sol',force=force,index=1}
local st={}
local F=dofile('mod/agent-harness_0.1.0/flightwatch.lua'){state=function() return st end,who=function(q) return q.name end,
  platform=function(q,name) for _,pl in ipairs(pls) do if pl.name==name then return pl end end error('no platform '..name) end,
  hits=function() return {hits=0,damage=0,entities={},by={}} end}
local ticked={}
local function run(to) while game.tick<to do game.tick=game.tick+1; if F.due(game.tick) then ticked[#ticked+1]=game.tick; F.tick(game.tick) end end end

-- the limit: one per platform of the force
eq(F.limit(force),4)
local a=F.call(p,{platform='Asterion'})
local b=F.call(p,{platform='Cinder',from='departure'})
local c=F.call(p,{platform='Swiftlet'})
local w1,w2,w3=st.flightwatch.list[1],st.flightwatch.list[2],st.flightwatch.list[3]
-- each its own tick of the second: PHASE, then 13 ticks on
eq(w1.phase,51); eq(w2.phase,4); eq(w3.phase,17)
local l=F.call(p,{})
eq(l.limit,4); eq(l.counted,3); eq(l.counting[1],a.watch.id); eq(l.counting[3],c.watch.id)
assert(l.limit_line:find('^3 of 4 flight watches count against the force\'s limit %(one per platform of the force%): #1 Asterion %(watching, sol%), #2 Cinder %(armed, sol%), #3 Swiftlet %(watching, sol%)'),l.limit_line)
assert(l.limit_line:find('a done watch stops counting once its result is read %(flight_watch {id}%) and is kept 1h00m00s after'),l.limit_line)
eq(l.watches[1].counts,true)
-- reads spread: each watch on its own tick, one read a second each
reads={}; ticked={}
run(1000+120)
eq(reads[1],2); eq(reads[3],2); eq(reads[2],nil,'an armed watch reads no turret')
local seen={}
for _,t in ipairs(ticked) do seen[t%60]=true end
assert(seen[51] and seen[17] and seen[4],'three phases')
-- the fourth fills the limit; a fifth platform built since then: one more fits
F.call(p,{platform='Spindle',from='departure'})
eq(st.flightwatch.list[4].phase,30)
pls[5]=platform(5,'Petrel',false); force.platforms[5]=pls[5]
eq(F.limit(force),5)
F.call(p,{platform='Petrel',from='departure'})
-- Petrel is gone and Wren built: 5 platforms, 5 counting; a start on Wren is refused naming the watches that count
force.platforms[5]=nil; pls[5].valid=false
pls[6]=platform(6,'Wren',false); force.platforms[6]=pls[6]
local ok,err=pcall(F.call,p,{platform='Wren'})
assert(not ok,'refused at the limit')
err=tostring(err)
assert(err:find('the force has 5 flight watches counting against its limit of 5 %(one per platform of the force%)'),err)
assert(err:find('#1 Asterion %(watching, sol%)') and err:find('#5 Petrel %(armed, sol%)'),err)
-- a replace leaves the count as it was: not refused
eq(F.call(p,{platform='Spindle',from='departure',replace=true}).watch.replaced,4)
assert(err:find('end one with flight_watch {id, clear: true}, or read a done one %(flight_watch {id}%): read, it stops counting'),err)
-- Petrel's watch ends (the platform is gone), done and not read: it counts until read
run(game.tick+60)
local w5
for _,w in ipairs(st.flightwatch.list) do if w.platform=='Petrel' then w5=w end end
eq(w5.state,'done'); eq(F.call(p,{}).counted,5)
F.call(p,{id=w5.id})
local l2=F.call(p,{})
eq(l2.counted,4,'read: no longer counts'); eq(l2.watches[4].counts,false,'Petrel\'s read one')
-- read, a start fits again (Wren); then clear one and start Swiftlet's again
F.call(p,{platform='Wren',from='departure'})
force.platforms[6]=nil; pls[6].valid=false
run(game.tick+60)
F.call(p,{id=st.flightwatch.list[#st.flightwatch.list].id})
F.call(p,{id=w3.id,clear=true})
local d=F.call(p,{platform='Swiftlet'})
eq(d.watch.state,'watching')
eq(st.flightwatch.list[#st.flightwatch.list].phase,17,'the phase left free')
-- read done watches kept: KEEP_DONE a force, the oldest read dropped
F.KEEP_DONE=2
local function done_read(name)
  F.call(p,{platform=name,replace=true})
  local w=st.flightwatch.list[#st.flightwatch.list]
  for _,pl in ipairs(pls) do if pl.name==name then pl.state,pl.space_connection,pl.space_location=1,{from={name='nauvis'},to={name='gleba'}},nil end end
  run(game.tick+60)
  for _,pl in ipairs(pls) do if pl.name==name then pl.state,pl.space_connection,pl.space_location=2,nil,{name='gleba'} end end
  run(game.tick+60)
  eq(w.state,'done',name); game.tick=game.tick+1; F.call(p,{id=w.id})
  return w.id
end
local r1=done_read('Spindle')
local r2=done_read('Spindle')
local r3=done_read('Spindle')
local kept={}
for _,w in ipairs(st.flightwatch.list) do kept[w.id]=true end
eq(kept[r1],nil,'the oldest read dropped'); eq(kept[r2],true); eq(kept[r3],true)
eq(kept[w5.id],nil,'Petrel\'s read watch dropped too (older)')
-- a watch kept from before (no phase) gets one
st.flightwatch.list[1].phase=nil; st.flightwatch.due=nil
assert(F.due(1000*60+51)~=nil)
eq(st.flightwatch.list[1].phase~=nil,true,'a phase given')
-- the feed trace: asked once a minute, or FEED_TICKS_PER_BELT ticks a belt on a large platform; one done since is taken
-- at the next sample; a platform with no ammo turret asks none
st={}
local asks,done={},nil
local belts=0
local G=dofile('mod/agent-harness_0.1.0/flightwatch.lua'){state=function() return st end,who=function(q) return q.name end,
  platform=function(q,name) for _,pl in ipairs(pls) do if pl.name==name then return pl end end end,
  hits=function() return {hits=0,damage=0,entities={},by={}} end,
  trace=function(pl,age) asks[#asks+1]={game.tick,age}; if not done then return nil end
    return {read_tick=done.tick,read_started=done.started,belts=belts,rows={{entity=pl.surface.find_entities_filtered{type='ammo-turret'}[1],kind='hub',reaches=50,stops={},gated={}}}} end,
  trace_done=function() return done and done.tick end,supply_kind=function(row) return row.kind end}
local function grun(to) while game.tick<to do game.tick=game.tick+1; if G.due(game.tick) then G.tick(game.tick) end end end
belts=6743
local t0=game.tick
G.call(p,{platform='Asterion'})
local wa=st.flightwatch.list[1]
eq(#asks,1,'asked at the start'); eq(asks[1][2],3600)
-- the background read ends 30 ticks later: taken at the next sample, no new ask
game.tick=t0+30; done={tick=t0+30,started=t0}
grun(t0+90)
eq(#asks,2,'one read of the done trace'); eq(asks[2][2],math.huge,'a read that starts none')
eq(wa.turrets[1].feed_start.kind,'hub'); eq(wa.belts,6743)
-- no new ask a minute on: 6743 belts * 7 ticks
grun(t0+3700)
eq(#asks,2,'no ask after a minute on a platform of 6743 belts')
grun(t0+6743*7+60)
eq(#asks,3); eq(asks[3][2],6743*7)
-- a small platform: once a minute
belts=200; done=nil
local t1=game.tick
G.call(p,{platform='Swiftlet'})
local n0=#asks
grun(t1+3600+60)
eq(#asks,n0+1,'asked again after a minute')
-- no ammo turret aboard: no trace asked
pls[3].surface.find_entities_filtered=function() return {} end
G.call(p,{platform='Swiftlet',replace=true})
n0=#asks
grun(game.tick+3700)
eq(#asks,n0,'no trace for a platform with no ammo turret')
-- the rows' fuel: held and in tanks alone (endurance.fuel_held), as the fuel outlook gives them
do
  local tank={valid=true,type='storage-tank',fluidbox=setmetatable({},{__len=function() return 1 end,__index=function() return {name='thruster-fuel',amount=700.4} end})}
  local thr={valid=true,type='thruster',fluidbox=setmetatable({},{__len=function() return 2 end,__index=function(_,i) return {name=i==1 and 'thruster-fuel' or 'thruster-oxidizer',amount=100} end})}
  local stats=0
  local pl={name='K',index=2,force={get_fluid_production_statistics=function() stats=stats+1 return nil end},
    surface={find_entities_filtered=function() return {tank,thr} end},space_location={name='nauvis'}}
  local sv=defines; defines={flow_precision_index={one_minute=1}}
  local E=dofile('mod/agent-harness_0.1.0/endurance.lua'){leg=function() return nil end}
  local h=E.fuel_held(pl)
  eq(stats,0,'no statistics read')
  local o=E.fuel_outlook(pl)
  eq(h['thruster-fuel'].held,o.rows[1].held); eq(h['thruster-fuel'].in_tanks,o.rows[1].in_tanks); eq(h['thruster-oxidizer'].held,o.rows[2].held)
  thr.fluidbox=setmetatable({},{__len=function() return 0 end})
  tank.fluidbox=thr.fluidbox
  eq(E.fuel_held(pl)['thruster-oxidizer'].held,0,'none held: 0, as the outlook')
  defines=sv
end
print('d22_batch109 BS1 flight watch limit: ok')
