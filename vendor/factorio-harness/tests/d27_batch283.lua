-- d27 batch283 WP (Sol #2612): a remote-lane wait_until all of 5 produced conditions on Vulcanus (four processing-unit
-- machines, one electronic-circuit machine) failed at its first check, "the electromagnetic-plant at (-19,76) is gone
-- since the wait began", while the plant stood there working. Every produced member kept its machines in one table on
-- the wait's record, and each member called gone every machine in it that it did not count itself: the second member
-- did not count the first one's plant. Each condition now has a baseline of its own.
-- Run from the harness root: lua tests/d27_batch283.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,part) assert(type(s)=='string' and s:find(part,1,true),tostring(s)..'\n  lacks: '..part) end

prototypes={item={['processing-unit']={},['electronic-circuit']={},['iron-gear-wheel']={}},quality={normal={}},space_location={},
  recipe={['processing-unit']={name='processing-unit',products={{type='item',name='processing-unit',amount=1}}},
    ['electronic-circuit']={name='electronic-circuit',products={{type='item',name='electronic-circuit',amount=1}}}}}
-- Sol's machines on Vulcanus; Sol's character on Nauvis (another surface)
local machines={}
local function machine(n,name,x,y,recipe,pf)
  local m={valid=true,unit_number=n,type='assembling-machine',name=name,position={x=x,y=y},products_finished=pf,
    get_recipe=function() return {name=recipe} end}
  machines[#machines+1]=m
  return m
end
local em=machine(101,'electromagnetic-plant',-19,76,'processing-unit',500)
local a1=machine(102,'assembling-machine-3',-12.5,97.5,'processing-unit',40)
local a2=machine(103,'assembling-machine-3',-20.5,87.5,'processing-unit',41)
local a3=machine(104,'assembling-machine-3',-29.5,87.5,'processing-unit',42)
local ec=machine(105,'assembling-machine-3',33,179,'electronic-circuit',9000)
local vulcanus={index=3,name='vulcanus'}
vulcanus.find_entities_filtered=function(f)
  local out={}
  for _,m in ipairs(machines) do
    if m.valid and math.abs(m.position.x-f.position.x)<=f.radius and math.abs(m.position.y-f.position.y)<=f.radius then out[#out+1]=m end
  end
  return out
end
local nauvis={index=1,name='nauvis'}
game={tick=0,get_surface=function(n) return n=='vulcanus' and vulcanus or nil end}
local p={force={name='player',is_chunk_charted=function() return true end,platforms={}},surface=nauvis}
local C=require('conditions'){position=function(v) return {x=v.x or v[1],y=v.y or v[2]} end,known=function() return true end}
local function pu(x,y,n) return {['until']='produced',position={x=x,y=y},item='processing-unit',at_least=n,surface='vulcanus'} end
local sol={['until']='all',conditions={pu(-19,76,95),pu(-12.5,97.5,36),pu(-20.5,87.5,36),pu(-29.5,87.5,36),
  {['until']='produced',position={x=33,y=179},item='electronic-circuit',at_least=1000,surface='vulcanus'}}}
local function check(c,rec) C.validate(c); return C.check(p,c,true,rec) end

-- Sol's wait: read at its first check with every machine there, nothing gone; met once each has made its share
do
  local rec={}
  local met,saw=check(sol,rec)
  eq(met,false)
  has(saw,'not yet: made 0 processing-unit (0 crafts) in 1 machine on vulcanus since the wait began (at least 95)')
  has(saw,'not yet: made 0 electronic-circuit (0 crafts) in 1 machine on vulcanus since the wait began (at least 1000)')
  assert(not saw:find('gone',1,true),saw)
  em.products_finished=em.products_finished+95; a1.products_finished=a1.products_finished+36; a2.products_finished=a2.products_finished+36
  met,saw=check(sol,rec)
  eq(met,false); has(saw,'met: made 95 processing-unit (95 crafts) in 1 machine on vulcanus since the wait began (at least 95)')
  has(saw,'not yet: made 0 processing-unit (0 crafts) in 1 machine on vulcanus since the wait began (at least 36)')
  a3.products_finished=a3.products_finished+36; ec.products_finished=ec.products_finished+1000
  eq((check(sol,rec)),true)
  print('WP Sol\'s wait (5 produced on vulcanus, the agent on nauvis): no machine called gone, met when each has: ok')
end

-- the same machine twice: both count from its count at the first check; counter_from twice on one machine: each from
-- its own count
do
  local rec={}
  local c={['until']='all',conditions={pu(-19,76,5),pu(-19,76,10)}}
  local base=em.products_finished
  eq((check(c,rec)),false)
  em.products_finished=base+7
  local met,saw=check(c,rec)
  eq(met,false); has(saw,'met: made 7 processing-unit'); has(saw,'not yet: made 7 processing-unit')
  em.products_finished=base+10; eq((check(c,rec)),true)
  rec={}
  local f1,f2=pu(-19,76,10),pu(-19,76,10)
  f1.counter_from=base; f2.counter_from=base+8
  met,saw=check({['until']='all',conditions={f1,f2}},rec)
  eq(met,false); has(saw,'met: made 10 processing-unit'); has(saw,'not yet: made 2 processing-unit')
  print('WP the same machine twice, counter_from twice: ok')
end

-- any: met by the first member that holds; the others still counted from the same first check
do
  local rec={}
  local c={['until']='any',conditions={pu(-12.5,97.5,5),pu(-20.5,87.5,3)}}
  eq((check(c,rec)),false)
  a2.products_finished=a2.products_finished+3
  local met,saw=check(c,rec)
  eq(met,true); has(saw,'#2 produced: met: made 3 processing-unit'); eq(rec.matched.index,2)
  -- (all and any take plain members: no nesting)
  assert(not pcall(C.validate,{['until']='all',conditions={c,pu(-29.5,87.5,1)}}),'plain members')
  print('WP any: ok')
end

-- a machine that is gone is still said, by the member that counts it
do
  local rec={}
  eq((check(sol,rec)),false)
  a2.valid=false
  local ok,err=pcall(check,sol,rec)
  assert(not ok); has(tostring(err),'the assembling-machine-3 at (-20.5,87.5) on vulcanus is gone since the wait began')
  a2.valid=true
  print('WP a machine gone: named: ok')
end

-- two platform members (two items): each from its own statistics count
do
  local counts={['processing-unit']=100,['iron-gear-wheel']=5000}
  local stats={get_input_count=function(q) return counts[type(q)=='table' and q.name or q] or 0 end}
  local pl={valid=true,name='Kestrel',surface={index=9}}
  p.force.platforms={pl}
  p.force.get_item_production_statistics=function() return stats end
  local c={['until']='all',conditions={{['until']='produced',platform='Kestrel',item='processing-unit',at_least=10},
    {['until']='produced',platform='Kestrel',item='iron-gear-wheel',at_least=10}}}
  local rec={}
  eq((check(c,rec)),false)
  counts['processing-unit']=110
  local met,saw=check(c,rec)
  eq(met,false); has(saw,'met: made 10 processing-unit on platform Kestrel'); has(saw,'not yet: made 0 iron-gear-wheel on platform Kestrel')
  print('WP two platform members: ok')
end

-- a wait in flight from before (its record has the one table): it goes on for its first member
do
  local rec={produced_base={machines={[103]={name='assembling-machine-3',x=-20.5,y=87.5,recipe='processing-unit'}},[103]=a2.products_finished-4}}
  local met,saw=check(pu(-20.5,87.5,4),rec)
  eq(met,true); has(saw,'made 4 processing-unit')
  print('WP a record from before: ok')
end
game=nil; prototypes=nil
print('d27_batch283 WP: ok')
