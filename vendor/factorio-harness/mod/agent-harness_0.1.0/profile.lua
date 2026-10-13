-- Operator profiler (profile_ticks with a table): for a number of seconds it
-- times every dispatch by action (and scope), the encoding of its reply, every
-- forwarded event by name, the harness tick, and named parts of the reply
-- (part lines are already inside their dispatch). A LuaProfiler reading cannot
-- be compared or read as a number in Lua, so the log gets one line per key per
-- game second and one total per key; tools/profile_log.py ranks them (count,
-- total, worst second). Module state only: it never touches game state.
return function()
  local M = {}
  local run
  local MAX_SECONDS, MAX_LINES = 600, 20000
  local names
  local function event_name(id)
    if not names then
      names = {}
      for k, v in pairs(defines.events) do names[v] = k end
    end
    return names[id] or tostring(id)
  end
  local function line(parts)
    if run.lines >= MAX_LINES then run.dropped = run.dropped + 1; return end
    run.lines = run.lines + 1
    log(parts)
  end
  -- One line per key that ran in the game second just ended; `*` sums the
  -- top-level keys (tick, dispatch, encode, event), parts excluded.
  local function flush()
    local keys = {}
    for key in pairs(run.bucket) do keys[#keys+1] = key end
    table.sort(keys)
    for _, key in ipairs(keys) do
      local b = run.bucket[key]
      line({'', 'agent-harness profile second tick=', run.second * 60, ' n=', b.n, ' key=', key, ' time=', b.p})
    end
    run.bucket = {}
  end
  local function slot(t, key)
    local b = t[key]
    if not b then b = {n=0, p=helpers.create_profiler(true)}; t[key] = b end
    return b
  end
  local function add(key, timer, top)
    local second = math.floor(game.tick / 60)
    if second ~= run.second then flush(); run.second = second end
    for _, k in ipairs(top and {key, '*'} or {key}) do
      local b = slot(run.bucket, k); b.n = b.n + 1; b.p.add(timer)
      b = slot(run.total, k); b.n = b.n + 1; b.p.add(timer)
    end
  end
  local function finish(why)
    flush()
    local keys = {}
    for key in pairs(run.total) do keys[#keys+1] = key end
    table.sort(keys)
    for _, key in ipairs(keys) do
      local b = run.total[key]
      log({'', 'agent-harness profile total ticks=', game.tick - run.start_tick, ' n=', b.n, ' key=', key, ' time=', b.p})
    end
    log({'', 'agent-harness profile done from_tick=', run.start_tick, ' to_tick=', game.tick, ' (', why, ') keys=', #keys,
      ' second_lines=', run.lines, ' dropped=', run.dropped})
    run = nil
  end
  -- args: {seconds=1..600} starts (a run in progress is ended first), {stop=true} ends one now.
  function M.start(args)
    if type(args) ~= 'table' then args = {} end
    if args.stop then
      if not run then return {ok=true, tick=game.tick, note='no profile is running'} end
      finish('stopped'); return {ok=true, tick=game.tick, note='stopped; the lines are in the server log'}
    end
    local seconds = tonumber(args.seconds) or 60
    assert(seconds >= 1 and seconds <= MAX_SECONDS, 'seconds must be 1..' .. MAX_SECONDS)
    seconds = math.floor(seconds)
    if run then finish('restarted') end
    run = {start_tick=game.tick, until_tick=game.tick + seconds * 60, second=math.floor(game.tick / 60), bucket={}, total={}, lines=0, dropped=0}
    return {ok=true, tick=game.tick, until_tick=run.until_tick,
      note='lines "agent-harness profile ..." land in the server log (factorio-current.log); rank them with tools/profile_log.py'}
  end
  function M.running() return run ~= nil end
  local function timed(key, top, fn, ...)
    local timer = helpers.create_profiler()
    local out = table.pack(pcall(fn, ...))
    timer.stop()
    if run then add(key, timer, top) end
    if not out[1] then error(out[2], 0) end
    return table.unpack(out, 2, out.n)
  end
  -- Wraps R.dispatch, R.on_event and R.tick, and each {table, field, label}
  -- of parts. Idle cost: one check per call.
  function M.wrap(R, parts)
    local dispatch, on_event, tick = R.dispatch, R.on_event, R.tick
    R.dispatch = function(request)
      if not run then return dispatch(request) end
      local key = 'dispatch ' .. tostring(request.action)
      local a = request.args
      if type(a) == 'table' and type(a.scope) == 'string' then key = key .. '/' .. a.scope end
      if request.operator == true then key = key .. ' (operator)' end
      local result = timed(key, true, dispatch, request)
      -- control.lua encodes the reply after this returns; the same encoding
      -- once more, timed, so a large reply shows (profiling only).
      if run and type(result) == 'table' then
        local timer = helpers.create_profiler()
        pcall(helpers.table_to_json, result)
        timer.stop()
        add('encode ' .. tostring(request.action), timer, true)
      end
      return result
    end
    if on_event then
      R.on_event = function(event)
        if not run then return on_event(event) end
        return timed('event ' .. event_name(event.name), true, on_event, event)
      end
    end
    R.tick = function(event)
      if not run then return tick(event) end
      timed('tick', true, tick, event)
      if run and game.tick >= run.until_tick then finish('elapsed') end
    end
    for _, part in ipairs(parts or {}) do
      local t, field, label = part[1], part[2], part[3]
      local fn = t and t[field]
      if type(fn) == 'function' then
        t[field] = function(...)
          if not run then return fn(...) end
          return timed('part ' .. label, false, fn, ...)
        end
      end
    end
  end
  return M
end
