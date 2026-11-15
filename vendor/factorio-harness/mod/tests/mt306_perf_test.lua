-- Count engine crossings, not wall time: portable to raw/compacted Lua 5.2.
-- --baseline prints counts against the unmodified runtime for the bench record.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local baseline=arg and arg[1]=='--baseline'
local function eq(a,b) assert(a==b,tostring(a)..' ~= '..tostring(b)) end
local mods,state_reads,counter_reads=0,0,0
script=setmetatable({}, {__index=function(_,k)
  if k=='active_mods' then mods=mods+1; return {base='2.1.24'} end
end})
game={tick=0}
prototypes={item={},quality={normal={level=0}}}
require('qflow').reset()
local state={}
local L=dofile('mod/agent-harness_0.1.0/productionlegs.lua'){
  state=function() state_reads=state_reads+1; return state end}
local counters={get_input_count=function() counter_reads=counter_reads+1; return 0 end,
  get_output_count=function() counter_reads=counter_reads+1; return 0 end}
local force={get_item_production_statistics=function() return counters end,
  get_fluid_production_statistics=function() return counters end}
for i=1,32 do
  local p={index=i,name='ship'..i,valid=true,space_location={name='nauvis'},surface={},force=force}
  L.observe(p,0,'event',{at='nauvis'})
end
mods,state_reads,counter_reads=0,0,0
for t=1,600 do game.tick=t; L.tick(t) end
eq(counter_reads,0)
print(string.format('mt306 production watch: 32 ships x 600 ticks, active_mods=%d state=%d counters=%d',mods,state_reads,counter_reads))
if not baseline then eq(mods,0); assert(state_reads<=600) end
-- A reloaded module still migrates a pre-2.1 ledger exactly once.
local old={old=true}; state={production_legs=old}
local L2=dofile('mod/agent-harness_0.1.0/productionlegs.lua'){state=function() return state end}
L2.tick(601); eq(state.production_legs_history['2.0-unversioned'],old)
L2.tick(602); eq(state.production_legs_history['2.0-unversioned'],old)

local finds,counts,technology_reads=0,0,0
local unlocks=require('unlocks')
local technologies, built, entity={},{},{}
for _,row in ipairs(unlocks) do
  technologies[row[1]]={researched=true}
  for _,name in ipairs(row[2]) do entity[name]={} end
end
prototypes.entity=entity
game.surfaces={}
for i=1,32 do game.surfaces[i]={count_entities_filtered=function(a)
  finds=finds+1; return i==32 and math.min(1,built[a.name] or 0) or 0
end} end
force=setmetatable({name='red',get_entity_count=function(name) counts=counts+1; return built[name] or 0 end},
  {__index=function(_,k) if k=='technologies' then technology_reads=technology_reads+1; return technologies end end})
local R=dofile('mod/agent-harness_0.1.0/research.lua'){state=function() return {} end}
local all=R.not_built(force)
eq(#all,22); eq(all[1].label,'roboports'); eq(#all[1].techs,2)
built.roboport=2; built['solar-panel']=12
local some=R.not_built(force)
eq(#some,20); eq(some[1].label,'requester chests')
-- Prototype absent and technology unfinished retain their old exclusion rules.
entity.accumulator=nil; technologies['gun-turret'].researched=false
eq(#R.not_built(force),18)
print(string.format('mt306 research: 3 calls x 32 surfaces, surface_counts=%d force_counts=%d technologies=%d',finds,counts,technology_reads))
if not baseline then eq(finds,0); assert(counts<=72); eq(technology_reads,3) end

-- Empty belts need no transport-line userdata or contents tables. Nonempty
-- belts still count every quality; existing fixtures cover underground sharing.
defines={entity_status={}}
local C=dofile('mod/agent-harness_0.1.0/census.lua'){state=function() return {} end}
local sf={index=1,name='platform-1'}
local ctx={si=1,surface_name=sf.name}
local job={where={},belt_items={}}
local line_reads,content_reads=0,0
local occupied=false
local belt={valid=true,name='transport-belt',type='transport-belt',position={x=0,y=0},
  get_item_count=function() return occupied and 3 or 0 end,
  get_max_transport_line_index=function() return 2 end,
  get_transport_line=function(i)
    line_reads=line_reads+1
    return {get_contents=function()
      content_reads=content_reads+1
      return occupied and {{name='iron-plate',count=i,quality=i==1 and 'normal' or 'rare'}} or {}
    end}
  end}
for i=1,10000 do C.read_entity(job,sf,belt,ctx) end
print(string.format('mt306 census: 10000 empty belts, lines=%d contents=%d',line_reads,content_reads))
if not baseline then eq(line_reads,0); eq(content_reads,0) end
occupied=true; C.read_entity(job,sf,belt,ctx)
eq(job.belt_items[1]['iron-plate'],3)

local surface_names,surface_lookups=0,0
local surfaces={}
for i=1,32 do
  surfaces[i]=setmetatable({index=i}, {__index=function(_,k)
    if k=='name' then surface_names=surface_names+1; return i==32 and 'target' or 'surface'..i end
  end})
end
game.surfaces=surfaces
game.get_surface=function(name) surface_lookups=surface_lookups+1; if name=='target' then return surfaces[32] end end
local n={map_tick=0,map={},samples={},busy={},unfilled={},views={red={tick=0}},view_jobs={}}
local N=dofile('mod/agent-harness_0.1.0/networks.lua'){state=function() return {networks=n} end}
local list={{valid=false}}
local j={start=0,steps={{step='walk',surface='target'}},i=1,out={},ctx={target={}},n=0,every=1}
n.view_jobs.red=j
for t=1,600 do game.tick=t; j.list,j.at=list,1; N.view_step(n,force,t) end
print(string.format('mt306 network: 600 view slices x 32 surfaces, surface_names=%d lookups=%d',surface_names,surface_lookups))
if not baseline then assert(surface_names<=601); eq(surface_lookups,600) end

-- Hot integer cell keys retain their saved spelling, including negatives.
local ps={}
force={name='red',is_chunk_visible=function() return true end}
sf={index=1,name='nauvis'}
local entities={}
for i=1,10000 do entities[i]={valid=true,name='lab',type='lab',position={x=-0.5,y=-0.5},force=force,status=1} end
sf.find_entities_filtered=function() return entities end
game.surfaces={sf}; game.get_surface=function() return sf end
defines={entity_status={no_power=1}}
local P=dofile('mod/agent-harness_0.1.0/pushalerts.lua'){
  state=function() return ps end,agents=function() return {} end}
local format,formatted_keys=string.format,0
string.format=function(fmt,...)
  if fmt=='%s|%d,%d' or fmt=='%s|%s|%d,%d' then formatted_keys=formatted_keys+1 end
  return format(fmt,...)
end
local ok,result=pcall(P.read,{force=force,surface=sf},{})
string.format=format
assert(ok,result)
local groups=P.cached_groups(force)
eq(#groups,1); eq(groups[1].key,'unconnected|nauvis|-1,-1'); eq(groups[1].n,10000)
print(string.format('mt306 pushalerts: 10000 labs, fast integer keys=%d',formatted_keys))
if not baseline then assert(formatted_keys>=20000) end

local cells={}
for i=1,1000 do cells[i]={surface='nauvis',n=1,sx=i,sy=0,drills=1,machines=0,turrets=0} end
ps.push_alerts.red={tick=1,sight={cells=cells,radars={}}}
local sort,sorts=table.sort,0
table.sort=function(...) sorts=sorts+1; return sort(...) end
local first
for i=1,12 do
  local lines,tick=P.sight_lines(force)
  eq(tick,1); first=first or lines[1]; eq(lines[1],first); eq(#lines,1)
  lines[2]='caller appends coverage' -- must not pollute another agent's reply
end
table.sort=sort
print(string.format('mt306 board/status sight: 12 readers x 1000 cells, sorts=%d',sorts))
if not baseline then eq(sorts,2) end
ps.push_alerts.red={tick=2,sight={cells={},radars={}}}
eq(P.sight_lines(force),nil,'new snapshot invalidates text')
print('mt306 counted loops: ok')
