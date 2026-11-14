-- Lua 5.2; counted idle pass and planet lifecycle equivalence against cp31.
local baseline = arg and arg[1] == '--baseline'
local function eq(a, b, message)
  assert(a == b, (message or 'mismatch') .. ': ' .. tostring(a) .. ' ~= ' .. tostring(b))
end
local counts = {surfaces=0, planet=0, planet_surface=0, forces=0, sorts=0}
local surfaces, planets, associations = {}, {}, {}
local function surface(name, index, planet)
  local s = setmetatable({name=name, index=index, valid=true}, {__index=function(_, k)
    if k == 'planet' then counts.planet=counts.planet+1; return planet end
  end})
  surfaces[name] = s
  return s
end
-- Iterate planets in reverse index order to exercise deterministic equal-age ties.
local planet_order = {}
for i=1,6 do
  local name='p'..i
  local p=setmetatable({}, {__index=function(_, k)
    if k=='surface' then counts.planet_surface=counts.planet_surface+1; return associations[name] end
  end})
  planets[name]=p
  associations[name]=surface(name,i,p)
  table.insert(planet_order,1,name)
end
setmetatable(planets,{__pairs=function()
  local i=0
  return function() i=i+1; local k=planet_order[i]; if k then return k,planets[k] end end
end})
for i=1,30 do surface('platform-'..i,100+i,nil) end
local force={name='player'}
game=setmetatable({tick=0,planets=planets,get_surface=function(k)
  if type(k)=='string' then return surfaces[k] end
  for _,s in pairs(surfaces) do if s.index==k then return s end end
end},{__index=function(_,k)
  if k=='surfaces' then counts.surfaces=counts.surfaces+1; return surfaces end
  if k=='forces' then counts.forces=counts.forces+1; return {player=force} end
end})
local state={netmap={done={},tried={}}}
for name in pairs(planets) do state.netmap.done[name]={tick=0} end
local poles_ready=false
local api={state=function() return state end,
  poles=function() if poles_ready then return {},0,false end end,
  typed=function() return {},0 end}
local factory=dofile('mod/agent-harness_0.1.0/netmap.lua')
local N=factory(api)
local sort=table.sort
table.sort=function(...) counts.sorts=counts.sorts+1; return sort(...) end
for tick=1,600 do game.tick=tick; N.tick(tick) end
table.sort=sort
eq(state.netmap.job,nil,'fresh maps stay idle')
eq(state.netmap.errors,nil,'idle errors')
eq(counts.surfaces,baseline and 200 or 0,'whole-surface enumerations')
eq(counts.planet,baseline and 7200 or 0,'surface planet property reads')
eq(counts.planet_surface,baseline and 0 or 1200,'live planet association reads')
eq(counts.forces,baseline and 200 or 0,'idle force reads')
eq(counts.sorts,baseline and 200 or 0,'idle sorts')
print(string.format('netmap 600 ticks / 6 planets / 30 ships: surface enumerations=%d surface.planet=%d planet.surface=%d forces=%d sorts=%d',
  counts.surfaces,counts.planet,counts.planet_surface,counts.forces,counts.sorts))
-- Equal-age planets, first discovery and period boundaries retain the old order.
state={netmap={done={},tried={}}}
for i=1,6 do
  N.step(state.netmap,i*6)
  eq(state.netmap.job.name,'p'..i,'lowest index among unseen planets')
  N.step(state.netmap,i*6+3)
  eq(state.netmap.tried['p'..i],i*6+3,'failed census retry time')
end
N.step(state.netmap,3608); eq(state.netmap.job,nil,'no early retry')
N.step(state.netmap,3609); eq(state.netmap.job.name,'p1','retry at exact PERIOD')
-- Persisted job resumes in a fresh module instance without losing its surface.
N=factory(api); poles_ready=true
for tick=3612,3630,3 do game.tick=tick; N.tick(tick); if state.netmap.done.p1 then break end end
local completed=state.netmap.done.p1
assert(completed and completed.surface=='p1' and completed.electric.poles==0,'reload completes same snapshot')
eq(#completed.items,0,'empty census snapshot')
-- An associated surface can appear without any surface-created event. Read it
-- on the next idle step, including a surface whose name differs from the planet.
state.netmap.job=nil
for name in pairs(planets) do state.netmap.done[name]={tick=4000} end
associations.p6=nil; surfaces.p6=nil
N.step(state.netmap,4001)
eq(state.netmap.done.p6,nil,'deleted surface result removed')
local replacement=surface('renamed-planet',60,planets.p6)
associations.p6=replacement
N.step(state.netmap,4002)
eq(state.netmap.job.name,'renamed-planet','new association found immediately')
-- Deleting an active job surface cancels it; reassociation can then be selected.
state.netmap.done['renamed-planet']={tick=4002}
surfaces['renamed-planet']=nil; associations.p6=nil
N.step(state.netmap,4005); eq(state.netmap.job,nil,'deleted job cancelled')
N.step(state.netmap,4008); eq(state.netmap.done['renamed-planet'],nil,'deleted result removed')
replacement=surface('second-name',61,planets.p6); associations.p6=replacement
N.step(state.netmap,4011); eq(state.netmap.job.name,'second-name','reassociation found')
-- Age wins before index; a recently tried missing census is not retried early.
state.netmap.job=nil; state.netmap.done={}; state.netmap.tried={}
for name in pairs(planets) do
  local s=associations[name]
  state.netmap.done[s.name]={tick=1000}
end
state.netmap.done.p5.tick=0
state.netmap.tried.p5=4700
state.netmap.done.p4.tick=500
N.step(state.netmap,5000); eq(state.netmap.job.name,'p4','oldest eligible map wins')
print('mt306 netmap lifecycle and cadence: ok')
