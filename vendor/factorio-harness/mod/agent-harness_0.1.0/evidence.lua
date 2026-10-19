-- Evidence on a board item or a reminder's acknowledgment (d19 batch41 B2, Sol seq 865: reviews kept outcomes in free
-- text that a 200-character ack cut, and nobody could tell which decision a measurement changed or who checks next):
-- optional fields, each stored as given and shown with the item or the reminder.
--   metric      what was measured, with its value
--   tick        the game tick it was measured at (default: now)
--   decision    the decision it changed
--   result      the downstream result seen
--   owner       who owns what is still open
--   next_check  when or what the next check is (text, or a game tick)
return function()
  local M = {}
  local TEXT = 500
  M.FIELDS = {'metric', 'tick', 'decision', 'result', 'owner', 'next_check'}
  local KNOWN = {metric=true, tick=true, decision=true, result=true, owner=true, next_check=true}
  local function text(v, name)
    assert(type(v) == 'string' and v:find('%S'), 'evidence.' .. name .. ' is text')
    local t = v:gsub('[%c]+', ' ')
    assert(#t <= TEXT, string.format('evidence.%s is %d characters, over its limit of %d: nothing stored', name, #t, TEXT))
    return t
  end
  -- The checked copy of an evidence argument (nil stays nil); by: who gives it.
  function M.check(v, by)
    if v == nil then return nil end
    assert(type(v) == 'table' and next(v) ~= nil, 'evidence is {metric?, tick?, decision?, result?, owner?, next_check?}')
    for k in pairs(v) do
      assert(KNOWN[k], 'evidence: unknown field ' .. tostring(k) .. ' (metric, tick, decision, result, owner, next_check)')
    end
    local e = {by=by, at=game.tick}
    if v.metric ~= nil then e.metric = text(v.metric, 'metric') end
    if v.tick ~= nil then
      assert(type(v.tick) == 'number' and v.tick == math.floor(v.tick) and v.tick >= 0 and v.tick <= game.tick, 'evidence.tick is a game tick up to now (' .. game.tick .. ')')
      e.tick = v.tick
    end
    if v.decision ~= nil then e.decision = text(v.decision, 'decision') end
    if v.result ~= nil then e.result = text(v.result, 'result') end
    if v.owner ~= nil then e.owner = text(v.owner, 'owner') end
    if v.next_check ~= nil then
      if type(v.next_check) == 'number' then
        assert(v.next_check == math.floor(v.next_check) and v.next_check >= 0, 'evidence.next_check is text or a game tick')
        e.next_check = v.next_check
      else e.next_check = text(v.next_check, 'next_check') end
    end
    assert(e.metric or e.decision or e.result or e.owner or e.next_check, 'evidence needs metric, decision, result, owner or next_check')
    return e
  end
  local function ago(ticks)
    local m = math.floor(math.max(0, ticks) / 3600)
    if m >= 60 then return string.format('%dh%02dm', math.floor(m / 60), m % 60) end
    return m .. 'm'
  end
  -- One line: 'by sol 12m ago: metric PU 600/min (tick 31697849); decision ...; result ...; owner astra; next check ...'.
  function M.line(e)
    if not e then return nil end
    local parts = {}
    if e.metric then parts[#parts+1] = 'metric ' .. e.metric .. (e.tick and string.format(' (tick %d)', e.tick) or '') end
    if not e.metric and e.tick then parts[#parts+1] = string.format('at tick %d', e.tick) end
    if e.decision then parts[#parts+1] = 'decision ' .. e.decision end
    if e.result then parts[#parts+1] = 'result ' .. e.result end
    if e.owner then parts[#parts+1] = 'owner ' .. e.owner end
    if e.next_check then
      parts[#parts+1] = type(e.next_check) == 'number'
        and string.format('next check at tick %d (%s)', e.next_check, e.next_check > game.tick and 'in ' .. ago(e.next_check - game.tick) or ago(game.tick - e.next_check) .. ' ago')
        or 'next check ' .. e.next_check
    end
    return string.format('by %s %s ago: %s', tostring(e.by), ago(game.tick - (e.at or game.tick)), table.concat(parts, '; '))
  end
  -- A list kept to the newest `keep`.
  function M.add(list, e, keep)
    list = list or {}
    list[#list+1] = e
    while #list > (keep or 5) do table.remove(list, 1) end
    return list
  end
  return M
end
