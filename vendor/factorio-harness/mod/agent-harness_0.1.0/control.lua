-- Keep this transport stable: runtime.lua can be replaced without restarting.
local default_runtime = require('runtime')
local runtime
local MAX_CACHE_BYTES=8*1024*1024
local function trim_cache(s)
  while #s.order>256 or s.cache_bytes>MAX_CACHE_BYTES do
    local oldest=table.remove(s.order,1)
    local entry=s.cache[oldest]
    s.cache_bytes=s.cache_bytes-#entry.request-#entry.response
    s.cache[oldest]=nil
  end
end
local function state()
  storage.agent_harness = storage.agent_harness or {cache = {}, order = {}, active = {}, cache_bytes=0}
  local s=storage.agent_harness
  if s.cache_bytes==nil then
    s.cache_bytes=0
    for _,entry in pairs(s.cache) do s.cache_bytes=s.cache_bytes+#entry.request+#entry.response end
    trim_cache(s)
  end
  return s
end
local function compile(source)
  local chunk, err = load(source, '@agent-harness/runtime', 't', _ENV)
  assert(chunk, err)
  local candidate = chunk()
  assert(type(candidate) == 'table' and type(candidate.dispatch) == 'function'
    and type(candidate.tick) == 'function' and type(candidate.stop_all) == 'function', 'invalid runtime contract')
  return candidate
end
local function boot()
  runtime = storage.agent_harness and storage.agent_harness.source
    and compile(storage.agent_harness.source) or default_runtime
end
script.on_init(function() state(); boot() end)
-- on_load must not write storage or touch game.
script.on_load(boot)
script.on_configuration_changed(function() state(); boot(); runtime.stop_all() end)
script.on_event(defines.events.on_tick, function(event)
  if state().runtime_fault then return end
  if not runtime then boot() end
  local ok, err = pcall(runtime.tick, event)
  if not ok then
    state().runtime_fault={tick=game.tick,message=tostring(err)}
    local stopped,stop_error=pcall(runtime.stop_all)
    log('Agent harness tick error: ' .. tostring(err))
    if not stopped then log('Agent harness cleanup error: '..tostring(stop_error)) end
  end
end)
-- Engine callbacks the runtime may need beyond on_tick. Registration is fixed
-- here so hot reloads keep identical handlers; the runtime opts in by exposing
-- on_event. Faults quarantine the runtime exactly like tick failures.
script.on_event({defines.events.on_script_path_request_finished, defines.events.on_entity_died,
    defines.events.on_unit_group_finished_gathering, defines.events.on_entity_damaged}, function(event)
  if state().runtime_fault then return end
  if not runtime then boot() end
  if not runtime.on_event then return end
  local ok, err = pcall(runtime.on_event, event)
  if not ok then
    state().runtime_fault={tick=game.tick,message=tostring(err)}
    pcall(runtime.stop_all)
    log('Agent harness event error: ' .. tostring(err))
  end
end)
local read_only = {describe = true, observe = true, inspect = true, status = true, recipes = true, technologies = true, queue_status = true, blueprint_export = true, blueprint_list = true, map = true, nearest = true, craftable = true, scan = true, power = true, grid = true, rates = true, bottleneck = true}
remote.add_interface('agent_harness', {
  install = function(source)
    local ok,result=pcall(function()
    assert(type(source) == 'string' and #source <= 524288, 'runtime source must be <=524288 bytes')
    local candidate = compile(source) -- validate before changing the running runtime
    local stopped=true
    if runtime then stopped=pcall(runtime.stop_all) end
    if not stopped then candidate.stop_all() end
    state().source = source
    runtime = candidate
    state().runtime_fault=nil
    return {ok = true, tick = game.tick, protocol = 1}
    end)
    return helpers.table_to_json(ok and result or {ok=false,tick=game.tick,error={code='invalid_runtime',message=tostring(result)}})
  end,
  dispatch = function(json)
    local request
    local ok, response = pcall(function()
      assert(type(json) == 'string' and #json <= 1048576, 'request must be <=1048576 bytes')
      request = helpers.json_to_table(json)
      assert(type(request) == 'table', 'invalid JSON request')
      assert(type(request.id) == 'string' and #request.id >= 1 and #request.id <= 128, 'id must be a 1..128 character string')
      assert(type(request.action) == 'string', 'action must be a string')
      assert(request.player==nil or (type(request.player)=='number' and request.player==math.floor(request.player) and request.player>=1), 'player must be a positive integer')
      assert(request.args == nil or type(request.args) == 'table', 'args must be an object')
      local s = state()
      local previous = s.cache[request.id]
      if previous then
        assert(previous.request == json, 'request id reused with different payload')
        return previous.response
      end
      if s.runtime_fault and not read_only[request.action] then
        return helpers.table_to_json({id=request.id,ok=false,tick=game.tick,error={code='runtime_fault',
          message='runtime is quarantined after a tick failure; deploy a corrected runtime bundle',fault=s.runtime_fault}})
      end
      if not runtime then boot() end
      local success, result = pcall(runtime.dispatch, request)
      if not success and not read_only[request.action] and not request.action:match('^queue_') and runtime.stop_player and type(request.player or 1)=='number' then pcall(runtime.stop_player,request.player or 1) end
      local envelope = {id = request.id, ok = success, tick = game.tick}
      if success then envelope.result = result else envelope.error = {code = 'action_failed', message = tostring(result)} end
      local encoded = helpers.table_to_json(envelope)
      if not read_only[request.action] then
        s.cache[request.id] = {request = json, response = encoded}
        s.order[#s.order + 1] = request.id
        s.cache_bytes=s.cache_bytes+#json+#encoded
        trim_cache(s)
      end
      return encoded
    end)
    if ok then return response end
    return helpers.table_to_json({id = request and request.id, ok = false, tick = game.tick,
      error = {code = 'invalid_request', message = tostring(response)}})
  end
})
