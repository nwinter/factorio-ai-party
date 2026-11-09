-- #2882: an arrival wait and the next watch can run before the periodic final sample.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
defines={inventory={turret_ammo=1,hub_main=1},space_platform_state={on_the_path=1,waiting_at_station=2}}
prototypes={item={['firearm-magazine']={type='ammo'},['repair-pack']={type='repair-tool'}}}
local used,damage,repairs=0,0,0
local force={name='player',get_item_production_statistics=function() return {get_output_count=function(x)
  local n=type(x)=='string' and x or x.name
  return n=='firearm-magazine' and used or n=='repair-pack' and repairs or 0
end} end}
local turret={valid=true,name='gun-turret',type='ammo-turret',unit_number=7,position={x=1,y=2},count=10}
turret.get_inventory=function() return {get_item_count=function() return turret.count end,
  [1]={valid_for_read=turret.count>0,name='firearm-magazine'}} end
local surface={index=9,name='platform-1',find_entities_filtered=function(f) return f.type=='ammo-turret' and {turret} or {} end}
local pl={valid=true,index=1,name='Asterion',surface=surface,force=force,
  hub={get_inventory=function() return {get_contents=function() return {} end} end}}
force.platforms={pl}
game={tick=1000,forces={player=force}}
local p={name='astra',force=force}
local st,F
local api={state=function() return st end,platform=function() return pl end,
  hits=function() return {hits=damage>0 and 1 or 0,damage=damage,entities={},by={}} end}
local function load() F=dofile('mod/agent-harness_0.1.0/flightwatch.lua')(api) end
-- Factorio serializes plain storage values and preserves LuaObject references.
local function saved(v)
  if v==pl or v==turret then return v end
  assert(type(v)~='function','a closure leaked into storage')
  if type(v)~='table' then return v end
  local out={} for k,x in pairs(v) do out[saved(k)]=saved(x) end return out
end
local function reload() st=saved(st); load(); F.reindex() end
local function fly() pl.state=1; pl.space_connection={from={name='nauvis'},to={name='fulgora'}}; pl.space_location=nil end
local function arrive() pl.state=2; pl.space_connection=nil; pl.space_location={name='fulgora'} end
local function run(to) while game.tick<to do game.tick=game.tick+1; if F.due(game.tick) then F.tick(game.tick) end end end
local function fresh()
  st={}; game.tick=1000; used,damage,repairs=0,0,0; turret.count=10; fly(); load()
  F.call(p,{platform=pl.name})
  local w=st.flightwatch.list[1]
  run(game.tick+60)
  return w
end
local function refused()
  local ok,err=pcall(F.call,p,{platform=pl.name,from='departure'})
  assert(not ok)
  local want='flight watch #1 on Asterion is watching: read it (flight_watch {id: 1}), clear it, or give replace: true'
  eq(tostring(err):sub(-#want),want,'refusal unchanged')
end
-- Same tick as native arrival, a few ticks after arrival just before the sample,
-- and the scheduled sample tick before the sampler runs. Reload before and after handoff.
for _,offset in ipairs({1,57,60}) do
  local w=fresh()
  game.tick=w.last_sample+1
  arrive(); used,damage,repairs=17,42,2; turret.count=0
  game.tick=w.last_sample+offset -- no periodic sample has run since the arrival
  reload(); w=st.flightwatch.list[1]
  local before=saved(st)
  -- The periodic path at this observation tick is the reference, including final turret reads.
  w.phase=game.tick%F.EVERY; F.reindex(); F.tick(game.tick)
  local expected=F.call(p,{id=w.id}).watch
  st=saved(before); load()
  local r=F.call(p,{platform=pl.name,from='departure'})
  local old=r.previous_watch
  eq(old.id,1); eq(old.state,'done'); eq(old.ended_by,'arrived at fulgora')
  eq(old.end_tick,game.tick); eq(old.end_tick,expected.end_tick)
  eq(old.damage.damage,42); eq(old.damage.damage,expected.damage.damage)
  eq(old.repair_packs_used,2); eq(old.repair_packs_used,expected.repair_packs_used)
  eq(old.ammunition.total,17); eq(old.ammunition.total,expected.ammunition.total)
  eq(old.samples,expected.samples); eq(old.turrets[1].now,0)
  eq(old.turrets[1].empty_ticks,expected.turrets[1].empty_ticks)
  local boundary
  for _,b in ipairs(old.ammunition_boundaries) do if b.what=='arrival' then boundary=b end end
  eq(boundary.what,'arrival'); eq(boundary.from_tick,w.last_sample-offset)
  eq(boundary.to_tick,game.tick); eq(boundary.total,17)
  assert(r.previous_line:find('previous_watch',1,true)); eq(r.replaced_watch,nil)
  eq(r.watch.state,'armed'); eq(r.watch.id,2)
  eq(st.flightwatch.list[2].seen_stopped,true)
  local ended=old.end_tick
  reload(); used,damage,repairs=100,200,9
  -- 60-tick dwell: next departure is watched without another manual call.
  run(ended+60); fly(); run(game.tick+60)
  eq(st.flightwatch.list[2].state,'watching')
  local kept=F.call(p,{id=1}).watch
  eq(kept.end_tick,ended); eq(kept.ammunition.total,17); eq(kept.damage.damage,42)
  eq(kept.repair_packs_used,2)
end
fresh(); refused() -- flying
pl.state=2; pl.space_connection=nil; refused() -- stopped in space, no location
arrive(); st.flightwatch.list[1].flew=false; refused() -- has never flown
local w=fresh(); arrive()
local ok,err=pcall(F.call,{name='sol',force=force},{platform=pl.name,from='departure'})
assert(not ok and tostring(err):find('is watching',1,true)); eq(w.state,'watching')
-- Explicit replacement keeps its existing reason and result fields.
local r=F.call(p,{platform=pl.name,from='departure',replace=true})
eq(r.previous_watch,nil); eq(r.replaced_watch.ended_by,'replaced by #2')
print('batch420: arrival handoff, sampler parity, frozen totals, refusals, replacement and save/load: ok')
