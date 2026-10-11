-- Run from repository root: lua tests/crafting.lua
-- Bot hand crafting counts like a player's: item production statistics and
-- craft-item research triggers, from queue differences.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local s={}
local flows={}
local stats={on_flow=function(item,n) flows[item]=(flows[item] or 0)+n end}
local electronics={name='electronics',researched=false,enabled=true,prerequisites={}}
local asp={name='automation-science-pack',researched=false,enabled=true,prerequisites={electronics=electronics}}
local cable_tech={name='cable-tech',researched=false,enabled=true,prerequisites={}}
local force={name='player',technologies={['automation-science-pack']=asp,electronics=electronics,['cable-tech']=cable_tech},
  get_item_production_statistics=function() return stats end}
prototypes={
  recipe={
    lab={products={{type='item',name='lab',amount=1}},ingredients={{type='item',name='iron-gear-wheel',amount=10},{type='item',name='electronic-circuit',amount=10},{type='item',name='transport-belt',amount=4}}},
    ['iron-gear-wheel']={products={{type='item',name='iron-gear-wheel',amount=1}},ingredients={{type='item',name='iron-plate',amount=2}}},
    ['copper-cable']={products={{type='item',name='copper-cable',amount=2}},ingredients={{type='item',name='copper-plate',amount=1}}}},
  technology={
    ['automation-science-pack']={research_trigger={type='craft-item',item='lab',count=1}},
    ['cable-tech']={research_trigger={type='craft-item',item={name='copper-cable'},count=10}},
    electronics={research_trigger={type='craft-item',item='copper-plate',count=10}}}}
storage={}
local crafting=dofile('mod/agent-harness_0.1.0/crafting.lua'){state=function() return s end}
local bots=dofile('mod/agent-harness_0.1.0/bots.lua'){state=function() return s end,crafting=crafting}
-- A character whose queue the test advances like the engine would.
local queue={}
local c={valid=true,force=force,surface={},crafting_queue_size=0}
setmetatable(c,{__index=function(_,k) if k=='crafting_queue' then return queue end end})
local function set(q) queue=q; rawset(c,'crafting_queue_size',#q) end
c.begin_crafting=function(a)
  if a.recipe=='lab' then set({{index=1,recipe='iron-gear-wheel',count=10,prerequisite=true},{index=2,recipe='lab',count=a.count}})
  else local q={}; for _,e in ipairs(queue) do q[#q+1]=e end; q[#q+1]={index=#q+1,recipe=a.recipe,count=a.count}; set(q) end
  return a.count
end
c.cancel_crafting=function(a) local e=queue[a.index]; e.count=e.count-a.count; if e.count==0 then table.remove(queue,a.index) end; set(queue) end
local b={name='astra',index=1000001,character=c}
local p=bots.proxy(b)
local function check(tick) crafting.tick(b,tick) end -- runs when (tick+index)%10==0: ticks 9, 19, ...

-- A lab with its 10 gears queued as intermediates: gears count as they finish.
p.begin_crafting{recipe='lab',count=1}
queue[1].count=4; check(9)
eq(flows['iron-gear-wheel'],6); eq(flows['iron-plate'],-12); eq(flows.lab,nil)
check(10) -- not this bot's tick
set({}); check(19)
eq(flows['iron-gear-wheel'],10-10); eq(flows['iron-plate'],-20); eq(flows.lab,1); eq(flows['electronic-circuit'],-10)
-- The lab trigger needs electronics first: crafted before that, it does not count.
eq(asp.researched,false); eq(s.bot_crafting.triggers.player['automation-science-pack'],nil)
electronics.researched=true
p.begin_crafting{recipe='lab',count=1}; set({}); check(29)
eq(asp.researched,true); eq(flows.lab,2)
-- Trigger counts accumulate across crafts (10 cables = 5 crafts of 2).
p.begin_crafting{recipe='copper-cable',count=3}; set({}); check(39)
eq(flows['copper-cable'],6); eq(cable_tech.researched,false); eq(s.bot_crafting.triggers.player['cable-tech'],6)
p.begin_crafting{recipe='copper-cable',count=2}; set({}); check(49)
eq(cable_tech.researched,true); eq(s.bot_crafting.triggers.player['cable-tech'],nil)
-- Cancelling is not crafting; a craft finished just before the cancel still counts.
local gears=flows['iron-gear-wheel']
p.begin_crafting{recipe='iron-gear-wheel',count=5}
queue[1].count=4 -- one finished
p.cancel_crafting{index=1,count=3}
eq(flows['iron-gear-wheel'],gears+1)
set({}); check(59) -- the last one finishes
eq(flows['iron-gear-wheel'],gears+2)
-- A new craft started while another is running: the earlier completion counts once.
p.begin_crafting{recipe='iron-gear-wheel',count=2}
queue[1].count=1
p.begin_crafting{recipe='copper-cable',count=1}
eq(flows['iron-gear-wheel'],gears+3)
set({}); check(69)
eq(flows['iron-gear-wheel'],gears+4); eq(flows['copper-cable'],12)
-- Death: the queue is lost, nothing more is counted.
p.begin_crafting{recipe='iron-gear-wheel',count=3}
crafting.forget(b); c.valid=false; set({}); check(79)
eq(flows['iron-gear-wheel'],gears+4)
-- An idle bot with no snapshot costs no queue read.
c.valid=true; s.bot_crafting.queues[b.index]=nil
setmetatable(c,{__index=function(_,k) if k=='crafting_queue' then error('queue read while idle') end end})
check(89)
print('crafting: ok')
