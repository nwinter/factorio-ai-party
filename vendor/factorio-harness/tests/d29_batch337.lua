-- Run from repository root: lua tests/d29_batch337.lua
-- d29 batch337 WR (Sol, board #2741: "Cinder queued flight_watch read:true and queued explicit id1660 both returned
-- archived donewatch, but next queued flight_watch refused done and not read"). Sol's journal (shift99): the queued read
-- (job 67, tick 81243368) read #1660 while it still watched; it ended at Cinder's arrival, which the queue then waited
-- for, and the start after it (job 71, tick 81248280) was refused "done and not read"; job 61 (#1659) came with no read
-- before it. A read of a done watch marks it read wherever it runs (queue and plan steps call the same handler,
-- runtime.lua handlers.flight_watch -> flightwatch.call). Now the setter's own start reads its platform's done, unread
-- watch first (previous_watch) and goes on; another agent's still refuses it.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
defines={inventory={turret_ammo=1,hub_main=1},space_platform_state={on_the_path=1,waiting_at_station=2,paused=3}}
prototypes={item={['repair-pack']={type='repair-tool'},['firearm-magazine']={type='ammo'},['railgun-ammo']={type='ammo'}}}
local reads={}   -- ammo inventory reads by tick
local uid=0
local function turret(x,y,n,rail)
  uid=uid+1
  local t={valid=true,name=rail and 'railgun-turret' or 'gun-turret',type='ammo-turret',unit_number=1000+uid,position={x=x,y=y},count=n,
    ammo=rail and 'railgun-ammo' or 'firearm-magazine'}
  if rail then t.electric_buffer_size, t.energy = 1e7, 1e7 end
  t.get_inventory=function() reads[game.tick]=(reads[game.tick] or 0)+1; return {get_item_count=function() return t.count end,[1]={valid_for_read=t.count>0,name=t.ammo}} end
  return t
end
local turrets={}
-- Resolute's mix: 97 gun turrets, then 32 railguns, the last at (18.5,380.5)
local function resolute(n_guns,n_rails)
  turrets={}
  for i=1,n_guns do turrets[#turrets+1]=turret(-40+i%40,360+math.floor(i/40),10) end
  for i=1,n_rails-1 do turrets[#turrets+1]=turret(-30+2*i,378.5,10,true) end
  turrets[#turrets+1]=turret(18.5,380.5,10,true)
  return turrets[#turrets]
end
local conn={from={name='gleba'},to={name='aquilo'}}
local surface={name='platform-22',find_entities_filtered=function(f)
  local o={} for _,t in ipairs(turrets) do if t.valid and (not f.type or f.type==t.type) then o[#o+1]=t end end return o end}
local force={name='player',get_item_production_statistics=function() return {get_output_count=function() return 0 end} end}
local pl={valid=true,index=22,name='Resolute',surface=surface,force=force,state=2,space_connection=nil,space_location={name='gleba'},
  hub={get_inventory=function() return {get_contents=function() return {} end} end}}
force.platforms={[22]=pl}
game={tick=1000,forces={player=force}}
local p={name='astra',force=force,index=1}
local st={}
local F=dofile('mod/agent-harness_0.1.0/flightwatch.lua'){state=function() return st end,who=function(q) return q.name end,
  platform=function(q,name) assert(name==pl.name,'no platform '..tostring(name)); return pl end,
  fuel_outlook=function() return {rows={}} end,
  hits=function() return {hits=0,damage=0,entities={},by={}} end,
  losses=function() return {},0 end,
  leg=function(q) local c=q.space_connection; if not c then return nil end; return {from=c.from.name,to=c.to.name} end}
local function run(to) while game.tick<to do game.tick=game.tick+1; if F.due(game.tick) then F.tick(game.tick) end end end
local function depart() pl.state, pl.space_connection, pl.space_location = 1, conn, nil end
local function stop_at(name) pl.state, pl.space_connection, pl.space_location = 2, nil, {name=name} end
local function last_event() return st.flightwatch.events[#st.flightwatch.events].text end
local function fresh() st={}; stop_at('gleba'); reads={} end


local sol, astra = {name='sol',force=force,index=2}, {name='astra',force=force,index=1}
resolute(4,1)
-- 1. Sol's sequence: a start, read while it watches (nothing final to read), it ends at the arrival, then a new start
local r1=F.call(sol,{platform='Resolute',from='departure',minutes=10})
local id1=r1.watch.id
run(game.tick+120); depart(); run(game.tick+120)
local w1=st.flightwatch.list[1]
eq(w1.state,'watching')
local q=F.call(sol,{platform='Resolute',read=true})           -- as job 67: the watch still running
eq(q.watch.state,'watching'); eq(w1.read_tick,nil)
stop_at('aquilo'); run(game.tick+120); eq(w1.state,'done'); eq(w1.read_tick,nil)
local t_start=game.tick
local r2=F.call(sol,{platform='Resolute',from='departure',minutes=10})  -- as job 71: refused before, now it reads #id1
eq(w1.read_tick,t_start,'read by this start'); eq(r2.previous_watch.id,id1); eq(r2.previous_watch.state,'done')
assert(r2.previous_line:find('was done and not read: read now by this start',1,true),r2.previous_line)
assert(r2.previous_watch.note and r2.previous_watch.line,'its full result')
eq(r2.watch.state,'armed'); assert(r2.watch.id>id1)
eq(F.call(sol,{id=id1}).watch.id,id1,'still readable by id')
print('d29_batch337 1. the setter\'s start after its watch ended unread reads it (previous_watch) and goes on: ok')

-- 2. another agent's start on a platform whose done watch (Sol's) is unread: refused as before, nothing read
fresh(); resolute(4,1)
local s1=F.call(sol,{platform='Resolute',from='departure',minutes=10})
run(game.tick+120); depart(); run(game.tick+120); stop_at('aquilo'); run(game.tick+120)
local ws=st.flightwatch.list[1]; eq(ws.state,'done')
local ok,err=pcall(F.call,astra,{platform='Resolute',from='departure',minutes=10})
assert(not ok and tostring(err):find('is done and not read',1,true),tostring(err)); eq(ws.read_tick,nil)
print('d29_batch337 2. another agent\'s start: refused, the watch left unread: ok')

-- 3. a read of a done watch marks it, by read: true and by id, whoever reads (queue, plan and direct steps all call
-- this): the next start needs no previous_watch
for _,how in ipairs({{read=true,platform='Resolute'},{id='ID'}}) do
  fresh(); resolute(4,1)
  local a=F.call(sol,{platform='Resolute',from='departure',minutes=10})
  run(game.tick+120); depart(); run(game.tick+120); stop_at('aquilo'); run(game.tick+120)
  local wd=st.flightwatch.list[1]; eq(wd.state,'done')
  local args={} for k,v in pairs(how) do args[k]=v=='ID' and a.watch.id or v end
  F.call(astra,args)                                          -- read by another agent: read all the same
  eq(wd.read_tick,game.tick)
  local b=F.call(sol,{platform='Resolute',from='departure',minutes=10})
  eq(b.previous_watch,nil); eq(b.watch.state,'armed')
end
print('d29_batch337 3. a read of a done watch (read: true, by id) marks it read; the next start goes on: ok')

-- 4. replace: true is as before: the done watch replaced, not read
fresh(); resolute(4,1)
local c1=F.call(sol,{platform='Resolute',from='departure',minutes=10})
run(game.tick+120); depart(); run(game.tick+120); stop_at('aquilo'); run(game.tick+120)
local wc=st.flightwatch.list[1]
local c2=F.call(sol,{platform='Resolute',from='departure',minutes=10,replace=true})
eq(c2.replaced_watch.id,c1.watch.id); eq(c2.previous_watch,nil); eq(wc.read_tick,nil); eq(wc.replaced_by,c2.watch.id)
print('d29_batch337 4. replace: true replaces as before (not read): ok')
