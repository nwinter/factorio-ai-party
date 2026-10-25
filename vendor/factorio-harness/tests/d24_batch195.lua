-- d24 batch195 hotfix (operator d24 21:18): platform_endurance reads on every call. batch187's kept readings and their
-- background reads are off: on world n a call answered from a kept reading took 80.7 ms against 13.7 ms read in the call.
-- The readings batch187 left in storage are dropped once by M.tick.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m and m..': ' or '')..tostring(a)..' ~= '..tostring(b)) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
game={tick=1000}
local storage={endurance_readings={['16{forecast=true}']={tick=900,reply={n=0},player=1,args={platform='Asterion',forecast=true},asked=950}}}
local E=require('endurance'){state=function() return storage end,platform=function(_,name) return {index=16,name=name} end,
  player_of=function() return {index=1} end}
local reads=0
E.read=function(p,a) reads=reads+1; return {platform=a.platform,n=reads} end
local p={index=1}
-- every call reads, the same arguments within 60 s too, and nothing is kept
local r=E.handler(p,{platform='Asterion',forecast=true})
eq(reads,1); eq(r.n,1); eq(r.reading,nil,'no reading block')
game.tick=1060
r=E.handler(p,{platform='Asterion',forecast=true})
eq(reads,2); eq(r.n,2)
r=E.handler(p,{platform='Asterion',forecast=true,fresh=true})
eq(reads,3)
-- the readings batch187 kept are dropped, with no read in the background
game.tick=1000+2*3600+17
E.tick(game.tick)
eq(storage.endurance_readings,nil); eq(reads,3)
eq(E.schema.platform_endurance.fresh,'optional; every call reads now')
fails(function() E.handler(p,{platform='Asterion',fresh='yes'}) end,'fresh is true or false')
game=nil
print('d24_batch195: ok')
