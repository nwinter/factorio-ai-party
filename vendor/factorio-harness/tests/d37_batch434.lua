-- Sol #2912: pickup capacity is not a requirement to fill the hand. Run from the harness root.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b) assert(a==b,tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(s:find(x,1,true),s..' lacks '..x) end
local function lacks(s,x) assert(not s:find(x,1,true),s..' contains '..x) end
local function refused(fn) local ok,err=pcall(fn); assert(not ok); return tostring(err) end
local force={inserter_stack_size_bonus=2,bulk_inserter_capacity_bonus=11}
defines={entity_status={waiting_for_more_items=33}}
local function fixture(name,full,unavailable)
  local reads=0
  local stack=name=='stack-inserter'
  local proto=setmetatable({inserter_stack_size_bonus=stack and 4 or 0,
    bulk=stack or name=='bulk-inserter',uses_inserter_stack_size_bonus=true,
    get_inserter_rotation_speed=function() return 0.04 end}, {__index=function(_,key)
      if key=='wait_for_full_hand' then
        reads=reads+1
        if unavailable then error("LuaEntityPrototype doesn't contain key wait_for_full_hand") end
        return full
      end
    end})
  local function entity(ghost)
    return {type=ghost and 'entity-ghost' or 'inserter',name=ghost and 'entity-ghost' or name,
      ghost_name=ghost and name,ghost_type=ghost and 'inserter',
      prototype=not ghost and proto or nil,ghost_prototype=ghost and proto or nil,
      force=force,position={x=-34.5,y=172.5},quality={name='normal'},
      status=33,held_stack={valid_for_read=true,name='iron-plate',count=1},
      inserter_stack_size_override=0,get_control_behavior=function() return nil end}
  end
  return entity,function() return reads end
end
for _,unavailable in ipairs({false,true}) do
  for i,name in ipairs({'fast-inserter','long-handed-inserter','bulk-inserter','stack-inserter'}) do
    local full=name=='stack-inserter'
    local make,reads=fixture(name,full,unavailable)
    local D=require('details'){}
    -- Both call orders, including a ghost as the first read.
    if i%2==0 then D.configure_wait_for_full_hand(make(true),full) else D.hand(make(false)) end
    for _,ghost in ipairs({false,true}) do
      local e=make(ghost)
      local hand=D.hand(e)
      eq(hand.wait_for_full_hand,full); eq(D.wait_for_full_hand(e),full)
      eq(hand.effective_hand_size,full and 16 or name=='bulk-inserter' and 12 or 3)
      if ghost then eq(hand.held_count,nil) else eq(hand.held_count,1) end
      if full then
        has(hand.hand_line,'; waits for a full hand (prototype wait_for_full_hand true)')
        has(hand.short,', waits for a full hand')
      else
        has(hand.hand_line,'does not require a full hand (prototype wait_for_full_hand false); hand size is the maximum pickup size')
        lacks(hand.short,'waits for a full hand')
      end
      lacks(hand.hand_line,'from a belt waits')
      local configured=D.configure_wait_for_full_hand(e,full)
      eq(configured.wait_for_full_hand,hand.wait_for_full_hand); eq(configured.unchanged,true)
      has(configured.line,'wait for a full hand '..(full and 'on' or 'off')..', as its prototype has it')
      has(refused(function() D.configure_wait_for_full_hand(e,not full) end),
        full and 'waits for a full hand' or 'does not wait for a full hand')
      if not ghost then
        has(D.hand_wait(e),'holds 1 iron-plate')
        if full then has(D.hand_wait(e),name..' waits for a full hand') else lacks(D.hand_wait(e),'waits for a full hand') end
      end
      e.quality.name='legendary'; D.hand(e)
    end
    eq(reads(),1) -- false and unavailable properties must also be cached across every caller
  end
end
-- A readable property wins over the stock prototype name, in both directions.
for _,name in ipairs({'fast-inserter','stack-inserter','custom-inserter'}) do
  for _,full in ipairs({true,false}) do
    local make,reads=fixture(name,full,false)
    local D=require('details'){}
    eq(D.hand(make(false)).wait_for_full_hand,full)
    eq(D.configure_wait_for_full_hand(make(true),full).wait_for_full_hand,full)
    eq(reads(),1)
  end
end
-- Missing properties on unknown inserters remain unknown (including a cached nil).
do
  local make,reads=fixture('custom-inserter',nil,true)
  local D=require('details'){}
  for _=1,3 do
    eq(D.wait_for_full_hand(make(false)),nil)
    has(D.hand(make(true)).hand_line,'full-hand waiting unknown')
    has(refused(function() D.configure_wait_for_full_hand(make(false),false) end),'no verified 2.0.77 value is known')
  end
  eq(reads(),1)
end
print('d37_batch434: four inserter kinds, ghosts, configure agreement, property precedence and cached fallback: ok')
-- The public describe text must agree with the entity read.
defines.events={}; defines.inventory={}; defines.controllers={}
storage={agent_harness={}}; game={tick=0}
local describe=require('runtime').dispatch{action='describe'}
has(describe.actions.inspect.note,'hand size is the maximum pickup size')
has(describe.actions.inspect.note,'inspect and configure share the cached prototype value')
lacks(describe.actions.inspect.note,'every inserter waited at a belt')
print('d37_batch434: public describe wording: ok')
