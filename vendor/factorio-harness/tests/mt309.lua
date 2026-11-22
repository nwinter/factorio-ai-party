-- mt309 (note-mt309-t, the three-team contact test). Run from the harness root: lua tests/mt309.lua
-- Every death of a team's entity is counted by the force that killed it, for the test's losses to rivals and to
-- biters (mt_contacts' losses). Deaths of the enemy force's entities, and of a force that is no team, are not.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end

do
  game={tick=100}
  local s={mt={order={'green','yellow','blue'},teams={green={},yellow={},blue={}}}}
  local M=dofile('mod/agent-harness_0.1.0/multiteam.lua'){state=function() return s end}
  local force=function(n) return {name=n} end
  local function died(victim,by,type)
    M.game.on_died{entity={valid=true,type=type or 'assembling-machine',force=force(victim),unit_number=1},force=by and force(by) or nil}
  end
  died('green','enemy'); died('green','enemy'); died('green','yellow'); died('green',nil)
  died('yellow','green','character')
  died('enemy','green','unit-spawner'); died('player','enemy')
  local l=M.operator.mt_contacts({}).losses
  eq(l.green.enemy,2,'to biters'); eq(l.green.yellow,1,'to a rival'); eq(l.green.none,1,'no killer')
  eq(l.yellow.green,1,'a character too'); eq(l.enemy,nil,'biters are no team'); eq(l.player,nil,'nor player')
  eq(l.blue,nil,'no loss, no row')
  game=nil
  print('mt309 losses by killer: ok')
end
