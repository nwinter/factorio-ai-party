-- Run from repository root: lua tests/d22_batch116.lua
-- d22 batch116 BY1 (Astra #1968: a dry run of the full-edge plan refused steps[1] flight_watch in lane
-- platform:Asterion, "not supported in the remote lane (no body steps)"). flight_watch runs as a step in the remote
-- lane and the platform lanes; in a platform lane a start without platform or id watches the lane's platform. A
-- replace keeps the replaced watch readable by id: a done one as it ended, a watching one ended there; an armed one
-- is dropped.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) if a~=b then error((m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b),2) end end
defines={inventory={turret_ammo=1,hub_main=1},space_platform_state={on_the_path=1,waiting_at_station=2}}
prototypes={item={['firearm-magazine']={type='ammo'}}}
local force={name='player',get_item_production_statistics=function() return {get_output_count=function() return 0 end} end}
local gun={valid=true,name='gun-turret',type='ammo-turret',unit_number=7,position={x=1,y=2}}
gun.get_inventory=function() return {get_item_count=function() return 10 end,[1]={valid_for_read=true,name='firearm-magazine'}} end
local pl={valid=true,index=1,name='Asterion',force=force,state=2,space_location={name='aquilo'},
  surface={name='platform-1',find_entities_filtered=function(f) if f.type=='ammo-turret' then return {gun} end return {} end},
  hub={get_inventory=function() return {get_contents=function() return {} end} end}}
force.platforms={pl}
local function fly(to) pl.state,pl.space_location,pl.space_connection=1,nil,{from={name='aquilo'},to={name=to}} end
local function arrive(at) pl.state,pl.space_location,pl.space_connection=2,{name=at},nil end
game={tick=1000,forces={player=force}}
local p={index=1,name='astra',force=force}
local fst={}
local F=dofile('mod/agent-harness_0.1.0/flightwatch.lua'){state=function() return fst end,who=function(q) return q.name end,
  platform=function(_,name) assert(name==pl.name,'no platform of ours named '..tostring(name)); return pl end,
  hits=function() return {hits=0,damage=0,entities={},by={}} end}
local s={active={}}
local handlers={flight_watch=function(q,a) return F.call(q,a) end,platform_schedule=function() return {ok=true} end}
local base={state=function() return s end,player=function() return p end,handlers=handlers,busy=function() return false end,
  stop=function() end,stop_index=function() end,direct_action=function() return nil end,
  condition=function() return false,'' end,validate_condition=function(c) assert(c['until']) end}
local make=require('scheduler')
local body=make(base)
local q=require('queue_lanes'){scheduler=body,factory=make,base=base,is_read=function() return false end}
local h=q.handlers
local function tick(n)
  for _=1,n or 1 do game.tick=game.tick+1; q.tick(); if F.due(game.tick) then F.tick(game.tick) end end
end
local function history(lane) return h.queue_status(p,{lane=lane,history='all',args=true}).history end

-- Astra's dry run (runs/shift60 full-edge-dry-run.json, its first two steps): accepted in the platform and remote lanes
local plan={{action='flight_watch',args={platform='Asterion',from='departure',minutes=240,replace=true}},
  {action='platform_schedule',args={platform='Asterion',paused=false,stops={{station='aquilo'},{station='solar-system-edge'}},current=2}}}
for _,lane in ipairs({'platform:Asterion','remote'}) do
  local r=h.queue_submit(p,{lane=lane,dry_run=true,steps=plan})
  eq(r.dry_run,true,lane); eq(r.steps,2,lane); eq(r.queued,false,lane)
end
eq(fst.flightwatch,nil,'a dry run starts no watch')
-- the body lane takes it as before
eq(h.queue_submit(p,{dry_run=true,steps=plan}).steps,2)

-- a platform lane step without platform watches the lane's platform; it moves no character and no schedule
h.queue_submit(p,{lane='platform:Asterion',steps={{action='flight_watch',args={from='departure'}}}})
tick()
local hist=history('platform:Asterion')
eq(#hist,1); eq(hist[1].ok,true); eq(hist[1].args.platform,'Asterion','the lane\'s platform')
local w1=fst.flightwatch.list[1]
eq(w1.platform,'Asterion'); eq(w1.state,'armed')
-- a remote lane step with no platform lists (a read)
h.queue_submit(p,{lane='remote',steps={{action='flight_watch'}}})
tick()
eq(history('remote')[1].result.counted,1)
-- the outbound leg: departs, flies, arrives at the edge; the watch is done and not read
fly('solar-system-edge'); tick(120)
eq(w1.state,'watching')
arrive('solar-system-edge'); tick(60)
eq(w1.state,'done'); assert(w1.why:find('^arrived at solar%-system%-edge'),w1.why)
-- the turnaround: a lane step replaces it with the return-leg watch
h.queue_submit(p,{lane='platform:Asterion',steps={{action='flight_watch',args={from='departure',minutes=240,replace=true}}}})
tick()
hist=history('platform:Asterion')
local res=hist[#hist].result
eq(hist[#hist].ok,true)
eq(res.watch.replaced,w1.id); eq(res.watch.state,'armed')
eq(res.replaced_watch.id,w1.id); eq(res.replaced_watch.state,'done'); eq(res.replaced_watch.replaced_by,res.watch.id)
assert(res.replaced_watch.line:find('^flight watch #1 on Asterion, aquilo%->solar%-system%-edge: watched for'),res.replaced_watch.line)
assert(res.replaced_line:find('^flight watch #1 on Asterion %(ended: arrived at solar%-system%-edge%) is kept: flight_watch {id: 1} reads it in full; it no longer counts against the limit; kept 24h00m00s unless read, then 1h00m00s after the read'),res.replaced_line)
-- one counts (the new one); the outbound one reads by id in full
local l=F.call(p,{})
eq(l.counted,1); eq(l.counting[1],res.watch.id); eq(#l.watches,2)
local full=F.call(p,{id=w1.id}).watch
eq(full.state,'done'); eq(full.replaced_by,res.watch.id); eq(full.turrets[1].unit_number,7); eq(full.samples>0,true)
-- read: kept KEEP_READ after the read
F.tick(game.tick+F.KEEP_READ+1)
eq(#fst.flightwatch.list,1,'read, dropped KEEP_READ after the read')
-- a running watch replaced from a lane step ends there and stays readable by id
local w2=fst.flightwatch.list[1]
fly('aquilo'); tick(120)
eq(w2.state,'watching')
h.queue_submit(p,{lane='platform:Asterion',steps={{action='flight_watch',args={replace=true}}}})
tick()
hist=history('platform:Asterion')
res=hist[#hist].result
eq(w2.state,'done'); eq(w2.why,'replaced by #'..res.watch.id)
eq(res.replaced_watch.state,'done'); eq(res.replaced_watch.ended_by,'replaced by #'..res.watch.id)
eq(F.call(p,{id=w2.id}).watch.id,w2.id)
-- an armed watch replaced is dropped: nothing read yet
arrive('aquilo'); tick(60)
h.queue_submit(p,{lane='platform:Asterion',steps={{action='flight_watch',args={from='departure',replace=true}}}})
tick()
local w4=fst.flightwatch.list[#fst.flightwatch.list]
eq(w4.state,'armed')
h.queue_submit(p,{lane='platform:Asterion',steps={{action='flight_watch',args={from='departure',replace=true}}}})
tick()
hist=history('platform:Asterion')
res=hist[#hist].result
eq(res.replaced_watch,nil); assert(res.replaced_line:find('was waiting for its next departure: dropped, nothing read yet'),res.replaced_line)
local ok=pcall(F.call,p,{id=w4.id})
eq(ok,false,'the armed one dropped')
-- the setter's card shows the counting watch alone, not a replaced one
local card=F.card('astra')
eq(#card,1); eq(card[1].id,'flight#'..res.watch.id)
-- without replace a lane step at the limit fails, naming the watch
h.queue_submit(p,{lane='platform:Asterion',steps={{action='flight_watch',args={}}}})
tick()
hist=history('platform:Asterion')
eq(hist[#hist].ok,false)
print('d22_batch116 BY1 flight_watch in the platform and remote lanes: ok')
