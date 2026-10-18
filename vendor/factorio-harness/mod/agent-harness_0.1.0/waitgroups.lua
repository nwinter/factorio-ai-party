-- waitgroups: a stop's waits as the game evaluates them (d18 batch36 A3, Luna 15:58: an item-count OR time departure
-- written without compare: "or" was joined with and, so the gate held after the time fallback was meant to release it;
-- viewer Aurora 16:09: Spindle needed repeated fixes). The game reads a stop's wait conditions in order, each joined to
-- the one before by its compare (and | or), and binds and before or: (a and b) or c. Here:
--   flatten  {any_of = [...]} / {all_of = [...]} written as that chain (any_of may hold all_of groups; all_of holds
--            plain waits: the chain is ors of ands);
--   mixed    waits of more than one kind with no compare past the first are refused, naming the default (and) and
--            the way to say or;
--   text     the waits as the game groups them, and each branch that lets it leave with no condition on fuel,
--            oxidizer or ammunition that another branch has.
return function()
  local M = {}
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function copy(w) local c = {}; for k, v in pairs(w) do c[k] = v end; return c end
  -- The chain from a wait list or a group object; field: the compare field's name (platforms and trains: compare).
  function M.flatten(wait, where)
    if type(wait) ~= 'table' or (wait.any_of == nil and wait.all_of == nil) then return wait, false end
    assert(not (wait.any_of ~= nil and wait.all_of ~= nil), where .. ': wait takes any_of or all_of, not both')
    local branches = {}
    local function plain(w, at)
      assert(type(w) == 'table' and type(w.type) == 'string', at .. ' is a wait {type, ...}')
      assert(w.compare == nil, at .. ': inside any_of or all_of a wait takes no compare (the group says it)')
      return copy(w)
    end
    if wait.all_of ~= nil then
      assert(type(wait.all_of) == 'table' and #wait.all_of >= 1, where .. ': all_of is a list of waits')
      local b = {}
      for i, w in ipairs(wait.all_of) do
        assert(type(w) ~= 'table' or (w.any_of == nil and w.all_of == nil),
          where .. ': all_of holds plain waits; the game\'s chain is ors of ands, so (a or b) and c is written any_of [all_of [a, c], all_of [b, c]]')
        b[#b+1] = plain(w, where .. ' all_of ' .. i)
      end
      branches[1] = b
    else
      assert(type(wait.any_of) == 'table' and #wait.any_of >= 1, where .. ': any_of is a list of waits or all_of groups')
      for i, w in ipairs(wait.any_of) do
        if type(w) == 'table' and w.all_of ~= nil then
          assert(type(w.all_of) == 'table' and #w.all_of >= 1, where .. ' any_of ' .. i .. ': all_of is a list of waits')
          local b = {}
          for j, x in ipairs(w.all_of) do
            assert(type(x) ~= 'table' or (x.any_of == nil and x.all_of == nil), where .. ' any_of ' .. i .. ': all_of holds plain waits')
            b[#b+1] = plain(x, where .. ' any_of ' .. i .. ' all_of ' .. j)
          end
          branches[#branches+1] = b
        else
          assert(type(w) ~= 'table' or w.any_of == nil, where .. ' any_of ' .. i .. ': any_of inside any_of is one any_of')
          branches[#branches+1] = {plain(w, where .. ' any_of ' .. i)}
        end
      end
    end
    local out = {}
    for bi, b in ipairs(branches) do
      for j, w in ipairs(b) do
        if #out > 0 then w.compare = (j == 1 and bi > 1) and 'or' or 'and' end
        out[#out+1] = w
      end
    end
    return out, true
  end
  -- A list mixing kinds with no compare past the first: refused.
  function M.mixed(list, where)
    if type(list) ~= 'table' or #list < 2 then return end
    local kinds, seen, missing = {}, {}, {}
    for j, w in ipairs(list) do
      local t = type(w) == 'table' and w.type
      if t and not seen[t] then seen[t] = true; kinds[#kinds+1] = t end
      if j > 1 and type(w) == 'table' and w.compare == nil then missing[#missing+1] = j end
    end
    if #kinds > 1 and #missing > 0 then
      local ns = {}
      for i, j in ipairs(missing) do ns[i] = tostring(j) end
      error(string.format('%s: its waits mix %s with no compare on wait %s; the game joins a wait with no compare by and (the default), so every one must hold. '
        .. 'Say each: compare: "and" or compare: "or" on every wait past the first (the game binds and before or: (a and b) or c), or write wait: {any_of: [...]} or {all_of: [...]} '
        .. '(any_of may hold all_of groups): e.g. {"any_of": [{"type": "item_count", "condition": "thruster-fuel >= 1000"}, {"type": "time", "ticks": 18000}]}',
        where, table.concat(kinds, ' and '), table.concat(ns, ', ')), 0)
    end
  end
  -- What a condition is on: fuel, oxidizer, ammunition, or nil.
  local function concern(c)
    local f = type(c) == 'table' and c.first_signal and c.first_signal.name
    if not f then return nil end
    if f:find('oxidizer', 1, true) then return 'oxidizer' end
    if f:find('fuel', 1, true) then return 'fuel' end
    local it = try(function() return prototypes.item[f] end)
    if it and try(function() return it.type end) == 'ammo' then return 'ammunition' end
    if it and (try(function() return it.fuel_value end) or 0) > 0 then return 'fuel' end
    return nil
  end
  -- The game's records grouped: branches (ors) of ands, each wait's text from text_of(w); the stop's text and notes.
  function M.text(records, text_of)
    local branches, cur = {}, nil
    for j, w in ipairs(records or {}) do
      local cmp = j > 1 and (w.compare_type or 'and') or nil
      if not cur or cmp == 'or' then cur = {waits={}, texts={}, on={}}; branches[#branches+1] = cur end
      cur.waits[#cur.waits+1] = w
      cur.texts[#cur.texts+1] = text_of(w)
      local k = concern(w.condition)
      if k then cur.on[k] = true end
    end
    if #branches == 0 then return nil, nil end
    local parts = {}
    for i, b in ipairs(branches) do
      local t = table.concat(b.texts, ' and ')
      parts[i] = (#branches > 1 and #b.texts > 1) and '(' .. t .. ')' or t
    end
    local notes = {}
    if #branches > 1 then
      for _, k in ipairs({'fuel', 'oxidizer', 'ammunition'}) do
        local any = false
        for _, b in ipairs(branches) do if b.on[k] then any = true end end
        if any then
          for i, b in ipairs(branches) do
            if not b.on[k] then notes[#notes+1] = string.format('branch %d, %s, departs with no %s condition', i, table.concat(b.texts, ' and '), k) end
          end
        end
      end
    end
    return table.concat(parts, ' or '), #notes > 0 and notes or nil
  end
  return M
end
