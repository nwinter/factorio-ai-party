-- d29 batch365 FL: next leg change includes pass-through, reversal and departure from a stop.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,t) assert(s:find(t,1,true),s..' missing '..t) end
defines={inventory={turret_ammo=1,hub_main=1},space_platform_state={on_the_path=1,waiting_at_station=2,paused=3}}
prototypes={item={}}
local force={name='player',get_item_production_statistics=function() return {get_output_count=function() return 0 end} end}
local pl={valid=true,index=1,name='Resolute',force=force,surface={name='platform-1',find_entities_filtered=function() return {} end},
  hub={get_inventory=function() return {get_contents=function() return {} end} end}}
force.platforms={[1]=pl}
game={tick=1000,forces={player=force}}
local p={name='astra',force=force,index=1}
local st, calls = {}, 0
local api={state=function() return st end, who=function(q) return q.name end, platform=function() return pl end,
  fuel_outlook=function() return {rows={}} end, hits=function() return {hits=0,damage=0,entities={},by={}} end,
  losses=function() return {},0 end,
  leg=function(q)
    calls=calls+1
    local c=q.space_connection
    return c and {from=q.back and c.to or c.from,to=q.back and c.from or c.to,back=q.back}
  end}
local function load() return dofile('mod/agent-harness_0.1.0/flightwatch.lua')(api) end
local F=load()
local function fly(name,from,to,back)
  pl.state,pl.space_location,pl.space_connection,pl.back=1,nil,{name=name,from=from,to=to},back or false
end
local function stop(location) pl.state,pl.space_connection,pl.space_location=2,nil,{name=location} end
local function run(n)
  for _=1,n or 60 do game.tick=game.tick+1; if F.due(game.tick) then F.tick(game.tick) end end
end
local function start(from)
  st={}; local r=F.call(p,{platform=pl.name,from=from,minutes=1})
  return st.flightwatch.list[1],r
end
local function read(w) return F.call(p,{id=w.id}).watch end
-- Registration captures the current leg, even if it changes before the first scheduled check.
fly('aquilo-edge','aquilo','edge')
local w,r=start('leg'); local set=game.tick
eq(w.state,'armed'); has(r.line,'next leg change'); has(F.card('astra')[1].line,'next leg change')
fly('edge-shattered','edge','shattered-planet')
run()
eq(w.state,'watching'); local c=read(w).start_change
eq(c.kind,'connection'); eq(c.before.connection,'aquilo-edge'); eq(c.after.connection,'edge-shattered')
eq(c.from_tick,set); eq(c.tick,w.start); eq(c.before.from,'aquilo'); eq(c.after.to,'shattered-planet')
has(read(w).line,'began on connection changed'); has(st.flightwatch.events[1].text,'connection changed')
-- The reason persists after reload, mixed rebase and final arrival.
F=load(); eq(read(w).start_change.tick,c.tick)
F.rebase(w,game.tick); eq(read(w).start_change.tick,c.tick)
stop('shattered-planet'); run(); eq(w.state,'done'); eq(read(w).start_change.tick,c.tick)
-- Departure semantics are unchanged: a pass-through does not start it, a subsequent stop/departure does.
fly('aquilo-edge','aquilo','edge'); w=start('departure')
fly('edge-shattered','edge','shattered-planet'); run(); eq(w.state,'armed')
stop('shattered-planet'); run(); eq(w.state,'armed')
fly('edge-shattered','edge','shattered-planet',true); run(); eq(w.state,'watching')
-- Each identity component matters, without requiring a different connection name.
for _,change in ipairs({'back','from','to','connection'}) do
  fly('aquilo-edge','aquilo','edge'); w=start('leg'); run()
  if change=='back' then pl.back=true else pl.space_connection[change=='connection' and 'name' or change]='changed' end
  run(); eq(w.state,'watching',change); eq(read(w).start_change.kind,change=='connection' and 'connection' or 'direction')
end
-- A genuine reversal retains the connection and flips the direction and oriented ends.
fly('edge-shattered','edge','shattered-planet'); w=start('leg'); pl.back=true; run()
c=read(w).start_change; eq(c.before.back,false); eq(c.after.back,true); eq(c.after.from,'shattered-planet'); eq(c.after.to,'edge')
-- Distance and speed do not change the identity; one identity read per second, no extra tick work.
fly('aquilo-edge','aquilo','edge'); w=start('leg'); calls=0
pl.distance,pl.speed=0.7,100; run(600); eq(w.state,'armed'); eq(calls,10)
-- Reload while armed retains its baseline. Paused in flight is not a stop or a new leg.
F=load(); pl.state=3; run(); eq(w.state,'armed')
pl.state=1; run(); eq(w.state,'armed')
stop('edge'); run(); eq(w.state,'armed')
fly('aquilo-edge','aquilo','edge',true); run(); eq(w.state,'watching'); eq(read(w).start_change.kind,'departure')
eq(read(w).start_change.before.location,'edge')
-- Registered while stopped: its next departure starts either armed mode.
for _,from in ipairs({'leg','departure'}) do
  stop('aquilo'); w=start(from); run(); eq(w.state,'armed')
  fly('aquilo-edge','aquilo','edge'); run(); eq(w.state,'watching')
  if from=='leg' then eq(read(w).start_change.kind,'departure'); has(read(w).line,'left a stop') end
end
-- Armed timeout and replacement describe the correct trigger.
fly('aquilo-edge','aquilo','edge'); w=start('leg')
game.tick=w.set+F.WAIT+60; run(); eq(w.state,'done'); eq(w.why,'no leg change within 24h')
w=start('leg'); r=F.call(p,{platform=pl.name,from='now',replace=true}); has(r.replaced_line,'next leg change')
-- Shared direct / queue-submit / dry-run validation: the runtime delegates to this world-free checker.
for _,from in ipairs({'now','departure','leg'}) do F.check({platform=pl.name,from=from}) end
for _,from in ipairs({'later',false,3,{}}) do
  local ok,e=pcall(F.check,{platform=pl.name,from=from}); eq(ok,false); has(tostring(e),'from:')
  ok,e=pcall(F.call,p,{platform=pl.name,from=from}); eq(ok,false); has(tostring(e),'from:')
end
local ok,e=pcall(F.check,{platform=pl.name,read=true,from='leg'}); eq(ok,false); has(tostring(e),'takes platform only')
local source=assert(io.open('mod/agent-harness_0.1.0/runtime.lua')):read('*a')
has(source,'flight_watch=function(a) M.flightwatch.check(a) end')
print('d29_batch365 FL: pass-through, reversal, departure, sampling, persistence, reasons and shared validation: ok')
