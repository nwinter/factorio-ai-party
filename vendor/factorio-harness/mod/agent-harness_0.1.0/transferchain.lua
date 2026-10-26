-- transferchain: transfer {steps: [...]} (d18 batch37 C1, Sonnet: 10+ chained transfers a brick cycle, and a failure
-- mid-chain left items in the pack). One walking call over the steps in order: {take: [{x,y}, ...], item, count?} takes
-- the item from those chests (count in all across them; default all they hold), {give: [{x,y}, ...], item, split?,
-- count?} gives what you hold of it to those (split: even, an even share of what is held at each; fill, all that fits,
-- the default; count: at most that many in all). The first leg that fails or is not reached ends the chain: the reply says what of the chain's items you
-- hold and which steps are left; on_fail: "return" gives what the chain took and you still hold back to the chests it
-- came from (a second walk).
return function(api)
  local M = {}
  M.MAX_LEGS = 32
  -- (d25 batch214 QZ2) the chests in all a chain's steps, as plan counts its legs (a queue step's check too)
  function M.count_legs(steps)
    local n = 0
    for _, st in ipairs(type(steps) == 'table' and steps or {}) do
      local list = type(st) == 'table' and (st.take or st.give)
      if type(list) == 'table' then n = n + ((list.x ~= nil or list[1] == nil and next(list) ~= nil) and 1 or #list) end
    end
    return n
  end
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function at(q) return string.format('(%g,%g)', q.x, q.y) end
  -- places and legs from the steps; refused with the shape when a step is not one.
  function M.plan(a)
    assert(type(a.steps) == 'table' and #a.steps >= 1, 'steps is a list of {take: [{x,y}, ...], item, count?} and {give: [{x,y}, ...], item, split?: "even" | "fill"}')
    assert(a.on_fail == nil or a.on_fail == 'return' or a.on_fail == 'keep', 'on_fail is "return" (give what the chain took back to where it came from) or "keep"')
    local places, legs, groups = {}, {}, {}
    for i, st in ipairs(a.steps) do
      assert(type(st) == 'table', 'steps[' .. i .. '] is {take: [...], item, count?} or {give: [...], item, split?}')
      local kind = st.take ~= nil and 'take' or st.give ~= nil and 'give' or nil
      assert(kind and not (st.take ~= nil and st.give ~= nil), 'steps[' .. i .. '] takes take or give (a list of {x,y})')
      for k in pairs(st) do
        assert(k == 'take' or k == 'give' or k == 'item' or k == 'count' or k == 'split' or k == 'quality' or k == 'inventory',
          string.format('steps[%d]: %s is not a step field: take | give, item, count? (take), split? (give), quality?, inventory?', i, tostring(k)))
      end
      assert(type(st.item) == 'string' and prototypes.item[st.item], 'steps[' .. i .. ']: item is an item name')
      assert(kind == 'give' or st.split == nil, 'steps[' .. i .. ']: split is for a give')
      assert(st.split == nil or st.split == 'even' or st.split == 'fill', 'steps[' .. i .. ']: split is "even" or "fill"')
      local list = st[kind]
      if type(list) == 'table' and (list.x ~= nil or list[1] == nil and next(list) ~= nil) then list = {list} end
      assert(type(list) == 'table' and #list >= 1, 'steps[' .. i .. ']: ' .. kind .. ' is a list of {x,y}')
      local g = {step=i, kind=kind, item=st.item, quality=st.quality or 'normal', left=st.count and api.integer(st.count, nil, 1, 100000, 'count') or nil,
        split=st.split or 'fill', n=#list, done=0, inventory=st.inventory}
      groups[#groups+1] = g
      for _, q in ipairs(list) do
        local pos = api.position(q)
        places[#places+1] = {position=pos, find=true}
        legs[#legs+1] = {group=#groups}
        assert(#legs <= M.MAX_LEGS, 'a chain takes at most ' .. M.MAX_LEGS .. ' chests in all')
      end
    end
    return places, legs, groups
  end
  -- The transfer args for this leg now.
  function M.args(p, action)
    local leg = action.chain_legs[action.index]
    local g = action.groups[leg.group]
    if g.kind == 'take' then
      return {direction='to_player', item=g.item, quality=g.quality, count=g.left or 10000, inventory=g.inventory}, g
    end
    local held = api.held(p, g.item, g.quality)
    local left = math.max(1, g.n - g.done)
    local n = g.split == 'even' and math.ceil(held / left) or held
    if g.left then n = math.min(n, g.left) end
    return {direction='to_entity', item=g.item, quality=g.quality, count=math.max(1, n), inventory=g.inventory, partial=true}, g
  end
  -- After the move: the group's count and where it came from.
  function M.moved(action, g, e, n)
    g.done = g.done + 1
    if g.left then g.left = math.max(0, g.left - n) end
    if g.kind == 'take' then
      if n > 0 then action.took[#action.took+1] = {position={x=e.position.x, y=e.position.y}, item=g.item, quality=g.quality, count=n} end
    end
  end
  -- The facts at its end: what of the chain's items is held, and the steps left.
  function M.report(p, action, last, outcome)
    local held, seen = {}, {}
    for _, g in ipairs(action.groups) do
      local k = g.item .. '@' .. g.quality
      if not seen[k] then
        seen[k] = true
        local n = p and p.valid and api.held(p, g.item, g.quality) or 0
        if n > 0 then held[#held+1] = g.item .. ' ' .. n end
      end
    end
    last.chain_held = #held > 0 and table.concat(held, ', ') or 'none of its items'
    local left = {}
    -- from the leg that failed (stock.lua sets chain_at) or was not reached; none when every leg was walked
    local from = action.chain_at or ((outcome == 'transferred' or outcome == 'nothing_to_do') and #action.chain_legs + 1 or action.index)
    for i = from, #action.chain_legs do
      local leg = action.chain_legs[i]
      local g = action.groups[leg.group]
      local t = action.targets[i]
      if t then left[#left+1] = string.format('step %d %s %s at %s', g.step, g.kind, g.item, at(t.position)) end
    end
    last.chain_left = #left > 0 and left or nil
    if (outcome == 'failed' or outcome == 'unreached' or outcome == 'timed_out') and action.on_fail == 'return' and #action.took > 0 then
      local steps = {}
      for _, t in ipairs(action.took) do steps[#steps+1] = {give={t.position}, item=t.item, count=t.count, quality=t.quality ~= 'normal' and t.quality or nil} end
      last.chain_return = string.format('on_fail "return": what it took goes back to %d chest%s now', #steps, #steps == 1 and '' or 's')
      -- the failed chain's facts ride along to the return walk's last (chain_failed)
      return {action='transfer', args={steps=steps, return_of={outcome=outcome, error=last.error or last.why, held=last.chain_held, left=last.chain_left}}}
    end
    -- the walk back after a failed chain: what that chain ended with
    if action.return_of then last.chain_failed = action.return_of end
    return nil
  end
  return M
end
