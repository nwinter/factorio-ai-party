-- d22 batch100 BJ2: name checks against `prototypes`, which is userdata in 2.0 (read on a copy of world n: type()
-- of prototypes, prototypes.entity and a quality prototype are all userdata). A check for a table skipped them on the
-- real engine. Game objects here are userdata fakes (a file handle with its own metatable), never tables.
-- Run from the harness root: lua tests/d22_batch100b.lua
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
local function ud(fields) local u=io.tmpfile(); debug.setmetatable(u,{__index=fields}); return u end
game={tick=100,get_surface=function(n) return n=='nauvis' and {valid=true,count_entities_filtered=function() return 1 end} or nil end}
prototypes=ud{
  entity=ud{boiler=ud{name='boiler'},['electric-mining-drill']=ud{name='electric-mining-drill'}},
  item=ud{['iron-plate']=ud{name='iron-plate'}},
  recipe=ud{['iron-gear-wheel']=ud{name='iron-gear-wheel'}}}
assert(type(prototypes)=='userdata')

-- serves (standing orders, reminders): the machine's name is checked against the entity prototypes
do
  local S=dofile('mod/agent-harness_0.1.0/serves.lua')()
  local p={valid=true,surface={name='nauvis'},force={name='player'}}
  fails(function() S.parse({name='boiler-x',position={x=8.5,y=42}},p) end,'serves.name: no entity named boiler-x')
  local sv=S.parse({name='boiler',position={x=8.5,y=42}},p)
  assert(sv.name=='boiler' and sv.surface=='nauvis')
end

-- ground rules' applies_to: each name an entity, item or recipe
do
  local st={}
  local items={[1]={id=1,kind='lesson',status='open',title='Big drills for outposts',created_tick=0}}
  local L=dofile('mod/agent-harness_0.1.0/lessonbook.lua'){state=function() return st end,items=function() return items end,stale=12*216000,
    active=function(i) return i.status=='open' end,who=function(q) return q.name end}
  local p={name='astra',index=1}
  fails(function() L.rule_add(p,{text='use big drills',applies_to={'electric-mining-dril'},lessons={1}}) end,'applies_to: no entity, item or recipe named electric-mining-dril')
  local ok,err=pcall(L.rule_add,p,{text='use big drills',applies_to={'electric-mining-drill','iron-plate','iron-gear-wheel'},lessons={1}})
  assert(ok or not tostring(err):find('applies_to',1,true),'known names pass: '..tostring(err))
end
print('d22_batch100b BJ2 prototypes checks: ok')
