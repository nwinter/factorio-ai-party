-- Explicit level costs, lab demand, repeated queue levels, and read-only state.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local cost=require('researchcost')
local function eq(a,b) assert(a==b,tostring(a)..' ~= '..tostring(b)) end
local function near(a,b) assert(math.abs(a-b)<1e-7,tostring(a)..' ~= '..tostring(b)) end
local function serialize(v)
  if type(v)~='table' then return tostring(v) end
  local keys,out={},{}
  for k,x in pairs(v) do if type(x)~='function' then keys[#keys+1]=k end end
  table.sort(keys,function(a,b) return tostring(a)<tostring(b) end)
  for _,k in ipairs(keys) do out[#out+1]=tostring(k)..'='..serialize(v[k]) end
  return '{'..table.concat(out,',')..'}'
end
local red={name='automation-science-pack',amount=2}
local t={name='lds',level=15,researched=false,research_unit_count=437893,research_unit_energy=3600,saved_progress=0.2,
  research_unit_ingredients={red},prototype={level=1,max_level=4294967295,research_unit_count_formula='1500*1.5^(L-1)'}}
local f={name='player',technologies={lds=t},current_research=t,research_progress=0.75,research_queue={t,t,t}}
local s={research_targets={player={lds=17}},research_plan={player={names={'lds'}}}}
game={tick=10000,surfaces={nauvis={name='nauvis',index=1}},difficulty_settings={technology_price_multiplier=1}}
helpers={evaluate_expression=function(formula,v)
  eq(formula,'1500*1.5^(L-1)'); eq(v.L,v.l); return 1500*1.5^(v.L-1)
end}
local lab={valid=true,name='biolab',quality={name='normal'},prototype={lab_inputs={'automation-science-pack'}}}
local other={valid=true,name='lab',quality={name='normal'},prototype={lab_inputs={'automation-science-pack'}}}
local incompatible={valid=true,name='lab',prototype={lab_inputs={'chemical-science-pack'}}}
local api={rate=function() return 100,3600 end,minutes=function(ticks) return tostring(ticks/60)..'s' end,
  labs_of=function() return {lab,other,incompatible},9000 end,
  lab_rate=function(e) return e==lab and {speed=2,drain=50,productivity=1} or {speed=1,drain=100,productivity=0} end,
  working=function() return true end}
local checks=0
local function read(fn)
  local before=serialize({force=f,state=s})
  local ok,result=pcall(fn)
  eq(serialize({force=f,state=s}),before)
  checks=checks+1
  return ok,result
end
local function query(level)
  local ok,r=read(function() return cost.query(f,t,level,api) end)
  assert(ok,r); return r
end
local r=query(15)
eq(r.full_units,437893); near(r.remaining_units,109473.25); eq(r.progress_source,'current research')
near(r.eta_seconds,109473.25*3600/100/60)
eq(r.nominal_packs_per_unit[red.name],2); near(r.nominal_packs_remaining[red.name],218946.5)
eq(r.cohort.labs,3); eq(r.cohort.compatible,2); eq(r.cohort.working,2)
near(r.cohort.pack_equivalents_per_nominal_unit,2/5)
near(r.physical_packs_remaining[red.name],218946.5*2/5)
r=query(16); eq(r.full_units,656840); eq(r.remaining_units,656840); eq(r.progress_source,'not started')
query(16) -- the second read has the same invariants
r=query(14); eq(r.completed,true); eq(r.remaining_units,0); eq(r.eta_seconds,0)
f.current_research=nil; f.research_progress=0
r=query(15); eq(r.progress_source,'saved progress'); near(r.remaining_units,437893*0.8)
r=query(16); eq(r.progress_fraction,0) -- saved progress belongs only to the force's level
game.difficulty_settings.technology_price_multiplier=1.25
r=query(16); eq(r.full_units,821050) -- native floors the formula before applying the multiplier
t.prototype.ignore_tech_cost_multiplier=true; eq(query(16).full_units,656840)
t.prototype.ignore_tech_cost_multiplier=nil; game.difficulty_settings.technology_price_multiplier=1
api.rate=function() return 0,3600 end
r=query(16); eq(r.eta_seconds,nil); assert(r.eta:find('unavailable',1,true))
api.working=function() return false end
r=query(16); eq(r.physical_packs_remaining,nil); eq(r.cohort.working,0)
api.labs_of=function() return nil end
r=query(16); eq(r.physical_packs_remaining,nil); eq(r.cohort.incomplete,true)
api.labs_of=function() local a={} for i=1,300 do a[i]=lab end return a,9000 end
api.working=function() return true end
r=query(16); eq(r.cohort.labs,256); eq(r.cohort.incomplete,true); eq(r.physical_packs_remaining,nil)
for _,level in ipairs({0,-1,1.5,'16',math.huge,100,4294967296}) do
  local ok=read(function() return cost.query(f,t,level,api) end); eq(ok,false)
end
t.prototype.research_trigger={type='craft-item'}
eq(read(function() return cost.query(f,t,15,api) end),false)
t.prototype.research_trigger=nil
t.prototype.level=7; eq(read(function() return cost.query(f,t,6,api) end),false); t.prototype.level=1
t.prototype.max_level=17; eq(read(function() return cost.query(f,t,18,api) end),false); t.prototype.max_level=4294967295

-- A repeated native queue holds the same LuaTechnology handle. Only its first occurrence has saved progress.
game.surfaces={}
defines={flow_precision_index={ten_minutes=2}}
local research=require('research'){state=function() return s end}
research.rate=function() return 100,3600 end
f.current_research=t; f.research_progress=0.75
local ok,q=read(function() return research.queue(f) end); assert(ok,q)
for i,level in ipairs({15,16,17}) do eq(q.entries[i].level,level) end
eq(q.entries[1].full_units,437893); eq(q.entries[2].full_units,656840); eq(q.entries[3].full_units,985261)
eq(q.entries[1].progress,75); eq(q.entries[2].progress,0); eq(q.entries[3].progress,0)
eq(q.entries[2].remaining_units,656840); assert(q.entries[3].done_in)
f.current_research=nil
ok,q=read(function() return research.queue(f) end); assert(ok,q)
eq(q.entries[1].progress,20); eq(q.entries[2].progress,0)

local targets=require('researchtarget'){state=function() return s end}
read(function() return targets.read(f) end)
s.research_targets=nil
read(function() return targets.read(f) end) -- no insertion of an empty targets table on first read

-- A sample pair spanning different costs of the same infinite technology is not a throughput observation.
s.research_rate={player={{tick=0,name='lds',progress=0.1,work=100},{tick=1800,name='lds',progress=0.2,work=200}}}
research=require('research'){state=function() return s end}
ok,r=read(function() return research.rate('player') end); eq(ok,true); eq(r,nil)
print('batch355: '..checks..' reads/refusals preserve research, progress, queue, targets and levels')
