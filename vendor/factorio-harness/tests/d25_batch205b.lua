-- d25 batch205 QR2 (Astra #2338: a queue could not read the flight watch its earlier step started, knowing no id).
-- Run from the harness root: lua tests/d25_batch205b.lua. flight_watch {platform, read: true} reads the platform's
-- latest kept watch in full, or not_found; it never starts or replaces one.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
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
local function fails(fn,x) local ok,err=pcall(fn); assert(not ok,'expected a failure: '..x); assert(tostring(err):find(x,1,true),tostring(err)..' lacks '..x) end
-- none kept: not_found, and nothing started
local r=F.call(p,{platform='Asterion',read=true})
eq(r.not_found,true); eq(r.line,"no flight watch on Asterion is kept (flight_watch {} lists the force's)")
eq(#((st.flightwatch or {}).list or {}),0,'no watch started')
-- a watch started; read by platform gives it in full and leaves it running
local a=F.call(p,{platform='Asterion'})
r=F.call(p,{platform='Asterion',read=true})
eq(r.watch.id,a.watch.id); eq(r.watch.state,'watching'); eq(#st.flightwatch.list,1); eq(r.older,nil)
assert(r.watch.samples~=nil or r.watch.turrets~=nil,'the full row')
-- replaced: the latest is the new one, the old one named as older
game.tick=game.tick+600
local b=F.call(p,{platform='Asterion',replace=true})
r=F.call(p,{platform='Asterion',read=true})
eq(r.watch.id,b.watch.id); eq(r.older[1],a.watch.id); eq(#st.flightwatch.list,2)
assert(r.line:find('; older kept on Asterion: #'..a.watch.id,1,true),r.line)
-- another platform's watch is not read
F.call(p,{platform='Cinder'})
eq(F.call(p,{platform='Asterion',read=true}).watch.id,b.watch.id)
eq(F.call(p,{platform='Swiftlet',read=true}).not_found,true)
-- a done watch read this way is read as by id: it stops counting against the limit
local wb=st.flightwatch.list[2]; wb.state='done'
eq(wb.read_tick,nil)
F.call(p,{platform='Asterion',read=true})
eq(wb.read_tick,game.tick)
-- refused, before anything is read or started
fails(function() F.call(p,{platform='Asterion',read=false}) end,'read: true, with platform')
fails(function() F.check_read({read=true}) end,'read: true takes platform')
fails(function() F.check_read({read=true,platform='Asterion',minutes=30}) end,'read: true takes platform only')
fails(function() F.check_read({read=true,platform='Asterion',id=1}) end,'read: true takes platform only')
F.check_read({platform='Asterion',minutes=30})
print('d25_batch205b QR2 flight_watch read by platform: ok')
