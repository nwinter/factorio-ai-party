-- Common pump methods must work without the removed scalar property, at the entity's quality.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local quality={name='rare'}
local calls=0
local proto=setmetatable({get_pumping_speed=function(q) assert(q==quality); calls=calls+1; return 30 end},
  {__index=function(_,key) error('unexpected prototype property '..key) end})
local pump={name='offshore-pump',type='offshore-pump',valid=true,quality=quality,prototype=proto}
local force={name='player',recipes={},logistic_networks={}}
pump.force=force
local C=require('ratechain'){}
prototypes={recipe={},item={},fluid={water={}},entity={}}
local r=C.plan({water={{e=pump,miner=true}}},'water',600,force)
assert(r.steps[1].per_min_each==108000,'pump target rate must use quality-aware method')
assert(calls==1)
game={tick=3600}
defines={flow_precision_index={ten_minutes=1}}
local stats={get_flow_count=function() return 0 end}
force.get_item_production_statistics=function() return stats end
force.get_fluid_production_statistics=function() return stats end
local chain=require('chain'){makers=function() return {n=1,craft={},mine={},pump={water={pump}}},0 end,
  status_name=function() return 'working' end}
r=chain.read({force=force},{item='water'},{name='nauvis',index=1})
assert(calls>=2,'chain must read the new method too: '..calls)
assert(r.lines[1]:find('108000/min at full speed',1,true),r.lines[1])
print('batch353: quality-aware pump methods without removed scalar API: ok')
