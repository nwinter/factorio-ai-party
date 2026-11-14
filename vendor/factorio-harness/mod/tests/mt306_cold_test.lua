-- First reads do no base scans; saved jobs publish the same facts after load.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or '')..': '..tostring(a)..' ~= '..tostring(b)) end
defines={entity_status={working=0,no_power=1},flow_precision_index={five_seconds=0,one_hour=3},inventory={}}
prototypes={item={},entity={},quality={normal={level=0}}}
local s,finds={},0
local f={name='red',players={},logistic_networks={},platforms={},is_chunk_visible=function() return true end}
local sf={name='nauvis',index=1,valid=true}
local stats={input_counts={},output_counts={},get_flow_count=function() return 0 end}
local es={}
for i=1,3 do es[i]={valid=true,name='small-electric-pole',type='electric-pole',position={x=i,y=0},
  force=f,electric_network_id=7,electric_network_statistics=stats} end
es[4]={valid=true,name='lab',type='lab',position={x=0,y=0},force=f,status=1,electric_network_id=7}
sf.find_entities_filtered=function(q)
  finds=finds+1
  local out={}
  for _,e in ipairs(es) do
    local match=q.type==nil or q.type==e.type
    if type(q.type)=='table' then for _,t in ipairs(q.type) do if t==e.type then match=true end end end
    local a,p=q.area,e.position
    if match and (not a or p.x>=a[1][1] and p.x<a[2][1] and p.y>=a[1][2] and p.y<a[2][2]) then out[#out+1]=e end
  end
  return out
end
game={tick=0,forces={red=f},surfaces={sf},players={},get_surface=function(k) if k==1 or k=='nauvis' then return sf end end}
local N,P
local function reload()
  N=dofile('mod/agent-harness_0.1.0/networks.lua'){background=true,state=function() return s end}
  P=dofile('mod/agent-harness_0.1.0/pushalerts.lua'){background=true,state=function() return s end,
    who=function() return 'r1' end,agents=function() return {} end,
    network_cursor=function(force) return N.alert_cursor(force) end,
    network_step=function(cur,max) local done=N.alert_step(cur,max); return done,cur.out end}
end
reload()
-- A bot-only force can request its first read after an empty joined-player
-- pole map has already completed; it must invalidate that map and join a job.
for t=1,8 do game.tick=t; N.tick(t) end
assert(s.networks.map_tick,'initial playerless map completed')
local p={force=f,surface=sf,index=1}
local hints={}
for i=1,12 do
  eq(N.read(p,{}).pending,true)
  eq(#N.alert_groups(f),0)
  eq(P.read(p,{}).pending,true)
  local compact=P.read(p,{compact=true,cursor=true})
  eq(compact.pending,true); eq(compact.cursor,nil); assert(compact.note:find('in progress',1,true))
  eq(#P.lines(p,hints),0); eq(hints.push,nil)
end
eq(finds,0,'12 simultaneous cold readers make no entity queries')
eq(s.networks.map_tick,nil,'first bot-only request schedules a new map')
eq(s.networks.views.red,nil); eq(s.push_alerts.red,nil,'pending is never a completed snapshot')
local cur=N.alert_cursor(f)
eq(N.alert_step(cur,1),false)
local finish
for t=9,6000 do
  game.tick=t
  N.tick(t); P.tick(t)
  if t==10 then reload() end -- persisted cursor/job state, no module-local work to lose
  if s.networks.views.red and s.push_alerts.red then finish=t; break end
end
assert(finish,'background jobs completed: '..tostring(s.push_errors and s.push_errors.last)..' / '..tostring(s.networks.view_errors and s.networks.view_errors.last))
assert(finish<300,'cold force must not inherit an empty map\'s slow refresh cadence')
eq(N.alert_step(cur,1),true,'a waiting cursor resumes after load')
local v=N.read(p,{})
eq(v.pending,nil); eq(#v.surfaces,1); eq(v.surfaces[1].electric[1].none,1)
local alert=P.read(p,{compact=true,cursor=true})
eq(alert.pending,nil); eq(alert.cursor,1,'first completed read owns the first cursor')
eq(s.push_alerts.red.groups[1].kind,'no_power.network')
print(string.format('mt306 cold reads: queries=0; background finished at tick %d (%d total queries); reload and playerless force passed',finish,finds))

-- Existing per-force pacing must remain intact: a round-robin shortcut
-- multiplies sparse census walks (one band per turn) by the force count.
local teams={'red','blue','green','yellow'}
game.forces={}
for _,name in ipairs(teams) do game.forces[name]={name=name,players={{}}} end
local calls={census={},networks={},pushalerts={}}
local function count(kind,force)
  calls[kind][force.name]=(calls[kind][force.name] or 0)+1
end
s={}
N=dofile('mod/agent-harness_0.1.0/networks.lua'){state=function() return s end}
P=dofile('mod/agent-harness_0.1.0/pushalerts.lua'){state=function() return s end}
local C=dofile('mod/agent-harness_0.1.0/census.lua'){state=function() return s end,team_names=function() return teams end,
  walk={start=function() return {} end,band=function(_,_,filter)
    count('census',filter.force); return {}
  end}}
N.view_step=function(_,force) count('networks',force) end
P.step=function(_,force) count('pushalerts',force) end
for t=1,600 do game.tick=t; N.view_tick(t); P.tick(t); C.tick(t) end
for _,name in ipairs(teams) do
  eq(calls.networks[name],600); eq(calls.pushalerts[name],600)
  eq(calls.census[name],300,'empty bands per force in 600 ticks')
end
print('mt306 cadence: 4 forces each walk 300 empty bands in 600 ticks; every force retains its view/alert pacing')
