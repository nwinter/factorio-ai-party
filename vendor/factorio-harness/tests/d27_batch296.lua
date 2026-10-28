-- Run from repository root: lua tests/d27_batch296.lua
-- d27 batch296 FA (Astra #2647: Resolute's watch 1469 took 1 hit, 2317.4, before guard 32 paused it, then coasted to
-- Aquilo; the end alert said "0 hits (0 shots that hit), 0 damage, 0 kills", the railguns' own fire, and nothing of the
-- damage taken, while flight_watch {id: 1469} said 1 hit, 2317.4). flightwatch.lua: the end alert says the damage
-- taken and the losses, the same phrase from the same totals as flight_watch's line; the railguns' part reads "their
-- fire".
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
defines={inventory={turret_ammo=1,hub_main=1},space_platform_state={on_the_path=1,waiting_at_station=2,paused=3}}
prototypes={item={['repair-pack']={type='repair-tool'},['firearm-magazine']={type='ammo'},rocket={type='ammo'}}}
local uid=0
local function turret(name,x,y,n)
  uid=uid+1
  local t={valid=true,name=name,type='ammo-turret',unit_number=100+uid,position={x=x,y=y},count=n,ammo=name=='rocket-turret' and 'rocket' or 'firearm-magazine'}
  t.get_inventory=function() return {get_item_count=function() return t.count end,[1]={valid_for_read=t.count>0,name=t.ammo}} end
  return t
end
local turrets={turret('gun-turret',-12,-52,10),turret('gun-turret',16,-52,10),turret('rocket-turret',17.5,-39.5,20)}
local conn={from={name='gleba'},to={name='aquilo'}}
local surface={name='platform-22',find_entities_filtered=function() local o={} for _,t in ipairs(turrets) do if t.valid then o[#o+1]=t end end return o end}
local force={name='player',get_item_production_statistics=function() return {get_output_count=function() return 0 end} end}
local pl={valid=true,index=22,name='Resolute',surface=surface,force=force,state=2,space_connection=nil,space_location={name='gleba'},
  hub={get_inventory=function() return {get_contents=function() return {{name='repair-pack',count=200}} end} end}}
force.platforms={[22]=pl}
game={tick=1000,forces={player=force}}
local p={name='astra',force=force,index=1}
local st={}
-- platalerts' running totals of hits on the platform (they never reset)
local hits={hits=40,damage=30000,entities={['railgun-turret']=30000},by={['small-metallic-asteroid']=40}}
local F=dofile('mod/agent-harness_0.1.0/flightwatch.lua'){state=function() return st end,who=function(q) return q.name end,
  platform=function(q,name) assert(name==pl.name,'no platform '..tostring(name)); return pl end,
  fuel_outlook=function() return {rows={{name='thruster-fuel',held=3822,in_tanks=0},{name='thruster-oxidizer',held=3822,in_tanks=0}}} end,
  hits=function() return hits end,
  losses=function() return {},0 end,
  leg=function(q) local c=q.space_connection; if not c then return nil end; return {from=c.from.name,to=c.to.name} end}
local function run(to) while game.tick<to do game.tick=game.tick+1; if F.due(game.tick) then F.tick(game.tick) end end end
local function depart() pl.state, pl.space_connection, pl.space_location = 1, conn, nil end
local function arrive() pl.state, pl.space_connection, pl.space_location = 2, nil, {name='aquilo'} end
local function last_event() return st.flightwatch.events[#st.flightwatch.events].text end
local function taken(text) return text:match('(damage taken [^;]*; %d+ lost)') end

-- 1. a hit, then a guard's abort (paused mid-connection), then a coast to the arrival
local r=F.call(p,{platform='Resolute',from='departure',minutes=10})
eq(r.watch.state,'armed')
run(game.tick+120); depart(); run(game.tick+120)
local w=st.flightwatch.list[1]
eq(w.state,'watching'); eq(w.leg,'gleba->aquilo')
hits={hits=41,damage=32317.4,entities={['railgun-turret']=32317.4},by={['small-metallic-asteroid']=40,['medium-oxide-asteroid']=1}}
run(game.tick+600)
pl.state=defines.space_platform_state.paused  -- the abort: paused, still on the connection
run(game.tick+1200)
eq(w.state,'watching','paused on the connection: still watching')
pl.state=defines.space_platform_state.on_the_path  -- the coast
run(game.tick+1800)
arrive(); run(game.tick+120)
eq(w.state,'done'); eq(w.why,'arrived at aquilo')
local alert=last_event()
assert(alert:find('^flight watch #1 on Resolute ended %(arrived at aquilo%) after %S+: damage taken 2317.4 in 1 hit %(railgun%-turret 2317.4%); 0 lost; none of 3 ammo turrets read empty'),alert)
local x=F.call(p,{id=1}).watch
eq(x.damage.hits,1); eq(x.damage.damage,2317.4); eq(x.damage.by[1],'medium-oxide-asteroid 1')
eq(taken(alert),taken(x.line),'the alert and flight_watch say the same')
eq(taken(alert),'damage taken 2317.4 in 1 hit (railgun-turret 2317.4); 0 lost')
-- later hits (at the stop) are not the watch's: the alert and the read keep the end's totals
hits={hits=45,damage=40000,entities={['railgun-turret']=40000},by={['small-metallic-asteroid']=44,['medium-oxide-asteroid']=1}}
run(game.tick+120)
x=F.call(p,{id=1}).watch
eq(x.damage.hits,1); eq(taken(x.line),taken(alert))

-- 2. a normal leg, nothing taken: the alert as before, with the damage phrase first
r=F.call(p,{platform='Resolute',from='departure',minutes=10,replace=true})
pl.space_location={name='aquilo'}; conn={from={name='aquilo'},to={name='gleba'}}
run(game.tick+120); depart(); run(game.tick+1200)
local w2=st.flightwatch.list[#st.flightwatch.list]
eq(w2.state,'watching')
arrive(); pl.space_location={name='gleba'}; run(game.tick+120)
eq(w2.state,'done')
alert=last_event()
local want=string.format('flight watch #%d on Resolute ended (arrived at gleba) after %s: damage taken 0 in 0 hits; 0 lost; %s%s; ammunition used none; flight_watch {id: %d} reads it',
  w2.id,alert:match('after (%S+):'),F.worst(w2),F.power_text(w2),w2.id)
eq(alert,want)
x=F.call(p,{id=w2.id}).watch
eq(x.damage.hits,0); eq(taken(x.line),'damage taken 0 in 0 hits; 0 lost')

-- 3. railguns aboard: their part names their fire, apart from the damage taken
w2.turrets[1].buffer, w2.turrets[1].low_samples, w2.turrets[1].low_longest = 4e6, 0, 0
w2.turrets[1].hits, w2.turrets[1].shots, w2.turrets[1].damage, w2.turrets[1].kills = 0, 0, 0, 0
assert(F.power_text(w2):find('1 powered turrets %(railguns%): none read below a shot\'s energy %(its full buffer%); their fire: 0 hits %(0 shots that hit%), 0 damage dealt, 0 kills'),F.power_text(w2))
print('d27_batch296: ok')
