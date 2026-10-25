-- d24 batch187 QAC1: platform_endurance answers the last complete reading of the same arguments (in storage) for 60 s
-- with its age; a reading asked for within 3 minutes is read again in the background once 45 s old, one a second at
-- most; without detail the numeric tables whose figures the lines carry are left out.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m and m..': ' or '')..tostring(a)..' ~= '..tostring(b)) end
local function has(s,part) assert(type(s)=='string' and s:find(part,1,true),tostring(s)..' lacks '..part) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
game={tick=1000}
local storage={}
local plats={Asterion={index=16,name='Asterion'},Swiftlet={index=4,name='Swiftlet'}}
local players={[1]={index=1}}
local E=require('endurance'){state=function() return storage end,platform=function(_,name) return assert(plats[name],'no platform named '..name) end,
  player_of=function(i) return players[i] end}
local reads=0
E.read=function(p,a)
  reads=reads+1
  return {platform=a.platform,n=reads,lines={'read '..reads},forecast_damage=a.forecast and {{ammo='rocket',shots=1}} or nil,forecast_targets=a.forecast and {ammo={}} or nil,
    forecast_model=a.forecast and {lines={'m'},legs={{from='a',to='b',km=1,total=2,asteroids={x=2},per_600s={x=1},line='l'}}} or nil,
    resources={{name='rocket',stock=5,by_place={hub=5},ingredient_limited={more=1},line='rocket: 5'}}}
end
local p={index=1}
-- the first call reads; the next within 60 s is answered from it, with its age
local r=E.handler(p,{platform='Asterion',forecast=true})
eq(reads,1); eq(r.n,1); eq(r.reading.fresh,true); eq(r.reading.age_s,0); has(r.reading.note,'read in this call')
eq(r.forecast_damage,nil); eq(r.forecast_targets,nil); eq(r.resources[1].by_place,nil); eq(r.resources[1].ingredient_limited,nil); eq(r.resources[1].stock,5)
eq(r.forecast_model.legs[1].asteroids,nil); eq(r.forecast_model.legs[1].total,2); has(r.detail_note,'come with detail: true')
game.tick=1000+1800
r=E.handler(p,{platform='Asterion',forecast=true})
eq(reads,1); eq(r.n,1); eq(r.reading.fresh,false); eq(r.reading.age_s,30); eq(r.reading.tick,1000); has(r.reading.note,'the reading of 30 s ago')
-- detail: the tables, from the same reading; the stored reading is not changed by the reply
r=E.handler(p,{platform='Asterion',forecast=true,detail=true})
eq(reads,1); eq(r.forecast_damage[1].shots,1); eq(r.resources[1].by_place.hub,5); eq(r.forecast_model.legs[1].asteroids.x,2); eq(r.detail_note,nil)
r.extra=true; eq(storage.endurance_readings[next(storage.endurance_readings)].reply.extra,nil)
-- other arguments are another reading; fresh reads again
r=E.handler(p,{platform='Asterion'}); eq(reads,2); eq(r.reading.fresh,true)
r=E.handler(p,{platform='Asterion',forecast=true,fresh=true}); eq(reads,3); eq(r.reading.fresh,true)
r=E.handler(p,{platform='Asterion',forecast=true,route={'aquilo','solar-system-edge'}}); eq(reads,4)
r=E.handler(p,{platform='Asterion',forecast=true,route={'aquilo','solar-system-edge'}}); eq(reads,4)
-- past 60 s it is read in the call (and the Asterion readings, last asked for over 3 min ago, are not read again)
game.tick=game.tick+3*3600+60
r=E.handler(p,{platform='Swiftlet',forecast=true}); eq(reads,5)
local before=reads
game.tick=game.tick+60; r=E.handler(p,{platform='Swiftlet',forecast=true}); eq(reads,before); eq(r.reading.age_s,1)
-- background: once 45 s old, the oldest asked for within 3 min is read again on tick%60==17, one a tick
game.tick=game.tick+2700+(17-(game.tick+2700)%60)
E.tick(game.tick); eq(reads,before+1)
local sw
for _,e in pairs(storage.endurance_readings) do if e.platform=='Swiftlet' then sw=e end end
eq(sw.tick,game.tick); eq(sw.background,1)
r=E.handler(p,{platform='Swiftlet',forecast=true}); eq(reads,before+1); eq(r.reading.fresh,false); eq(r.reading.age_s,0)
E.tick(game.tick+1); eq(reads,before+1,'only on tick%60==17')
-- the Asterion readings were last asked for over 3 min ago: not read again
local n=reads
for _=1,5 do game.tick=game.tick+60; E.tick(game.tick) end
eq(reads,n)
-- a caller gone: its reading dropped
players[1]=nil
game.tick=game.tick+2700+(17-(game.tick+2700)%60)
E.tick(game.tick)
local left=0; for _,e in pairs(storage.endurance_readings) do if e.platform=='Swiftlet' then left=left+1 end end
eq(left,0)
fails(function() E.handler(p,{platform='Asterion',detail='yes'}) end,'detail is true or false')
fails(function() E.handler(p,{platform='Asterion',fresh=1}) end,'fresh is true or false')
print('d24_batch187: ok')
