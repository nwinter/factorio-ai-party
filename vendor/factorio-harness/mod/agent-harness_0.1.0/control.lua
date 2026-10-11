-- Keep this transport stable: runtime.lua can be replaced without restarting.
local default_runtime = require('runtime')
local runtime
local MAX_CACHE_BYTES=8*1024*1024
-- A runtime may be up to 8 MiB. One RCON command carries up to MAX_CHUNK_BYTES
-- of it: larger runtimes arrive as install_chunk calls and install_commit.
local MAX_RUNTIME_BYTES,MAX_CHUNK_BYTES=8*1024*1024,262144
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
-- A quarantined runtime cannot run the turn clock, so a turn-mode world would
-- play on unattended; freeze it until a fixed runtime is deployed.
local function quarantine(err)
  state().runtime_fault={tick=game.tick,message=tostring(err)}
  if state().clock and state().clock.mode=='turns' then game.tick_paused=true end
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
    quarantine(err)
    local stopped,stop_error=pcall(runtime.stop_all)
    log('Agent harness tick error: ' .. tostring(err))
    if not stopped then log('Agent harness cleanup error: '..tostring(stop_error)) end
  end
end)
-- Engine callbacks the runtime may need beyond on_tick. Registration is fixed
-- here so hot reloads keep identical handlers; the runtime opts in by exposing
-- on_event. Faults quarantine the runtime exactly like tick failures.
script.on_event({defines.events.on_script_path_request_finished, defines.events.on_entity_died,
    defines.events.on_unit_group_finished_gathering, defines.events.on_entity_damaged, defines.events.on_console_chat}, function(event)
  if state().runtime_fault then return end
  if not runtime then boot() end
  if not runtime.on_event then return end
  local ok, err = pcall(runtime.on_event, event)
  if not ok then
    quarantine(err)
    pcall(runtime.stop_all)
    log('Agent harness event error: ' .. tostring(err))
  end
end)
-- Console audit: every console command that is not a harness request, from a player or over RCON, so the
-- operator can see Lua or commands sent around fh (console_log below; tools/console_audit.py). It lives here,
-- not in the runtime, so installing a runtime cannot remove it. Commands are grouped by shape (long strings and
-- numbers blanked), so a repeated operator poll is one entry with a count.
local AUDIT_SHAPES,AUDIT_TEXT=500,600
local function audit_state()
  storage.console_audit=storage.console_audit or {seq=0,harness=0,other=0,dropped=0,shapes={}}
  return storage.console_audit
end
-- A harness request is exactly `rcon.print(remote.call("agent_harness", "dispatch", <long string>))` (bin/fh,
-- tools/audience.py, the stream service), with a long string that cannot close before its end.
local function harness_request(name,text)
  if name~='silent-command' then return false end
  local eq,start=text:match('^rcon%.print%(remote%.call%(%s*"agent_harness"%s*,%s*"dispatch"%s*,%s*%[(=*)%[()')
  if not eq then return false end
  local close=']'..eq..']))'
  if #text<start+#close-1 or text:sub(-#close)~=close then return false end
  local body=text:sub(start,#text-#close)
  return not body:find(']'..eq..']',1,true) and body:sub(-(#eq+1))~=']'..eq
end
local function shape(name,text)
  local s=text:gsub('%[(=*)%[.-%]%1%]','[[]]'):gsub('%d+','0')
  return (name..' '..s):sub(1,1000)
end
local function audit(event)
  local a=audit_state()
  local name,text=event.command or '',event.parameters or ''
  if harness_request(name,text) then a.harness=a.harness+1; return end
  a.other=a.other+1; a.seq=a.seq+1
  local key=shape(name,text)
  local player=event.player_index and game.get_player(event.player_index)
  local e=a.shapes[key]
  if not e then
    local count=0
    for _ in pairs(a.shapes) do count=count+1 end
    if count>=AUDIT_SHAPES then
      local oldest
      for k,v in pairs(a.shapes) do if not oldest or v.seq<a.shapes[oldest].seq then oldest=k end end
      a.shapes[oldest]=nil; a.dropped=a.dropped+1
    end
    e={command=name,shape=key,first_tick=game.tick,count=0,first_text=text:sub(1,AUDIT_TEXT),players={}}
    a.shapes[key]=e
  end
  e.seq=a.seq; e.last_tick=game.tick; e.count=e.count+1; e.last_text=text:sub(1,AUDIT_TEXT); e.bytes=#text
  e.players[player and player.name or 'rcon']=true
end
script.on_event(defines.events.on_console_command,function(event)
  local ok,err=pcall(audit,event)
  if not ok then log('Agent harness console audit error: '..tostring(err)) end
end)
-- Entries changed after seq `since`, oldest first; harness and other are counts of all commands seen.
local function console_log(since)
  local a=audit_state()
  since=tonumber(since) or 0
  local list={}
  for _,e in pairs(a.shapes) do
    if e.seq>since then
      local players={}
      for p in pairs(e.players) do players[#players+1]=p end
      table.sort(players)
      list[#list+1]={seq=e.seq,command=e.command,shape=e.shape,count=e.count,first_tick=e.first_tick,last_tick=e.last_tick,
        bytes=e.bytes,players=players,first_text=e.first_text,last_text=e.last_text}
    end
  end
  table.sort(list,function(x,y) return x.seq<y.seq end)
  return helpers.table_to_json{ok=true,tick=game.tick,seq=a.seq,harness=a.harness,other=a.other,dropped=a.dropped,entries=list}
end
local read_only = {chat = true, describe = true, observe = true, inspect = true, status = true, recipes = true, technologies = true, queue_status = true, blueprint_export = true, blueprint_list = true, map = true, nearest = true, craftable = true, scan = true, power = true, grid = true, rates = true, bottleneck = true, profiles = true, cameras = true}
-- Operator-only calls (bots, cameras): RCON/console only, never via dispatch.
local function operator(name, arg)
  local ok, result = pcall(function()
    if not runtime then boot() end
    assert(not state().runtime_fault, 'runtime is quarantined after a tick failure; deploy a corrected runtime bundle')
    assert(runtime.operator and runtime.operator[name], name .. ' is not supported by the running runtime; deploy a current one')
    return runtime.operator[name](arg)
  end)
  return helpers.table_to_json(ok and result or {ok=false, tick=game.tick, error={code='operator_failed', message=tostring(result)}})
end
-- Validate, then swap the running runtime (shared by install and install_commit).
local function install_source(source)
  assert(type(source) == 'string' and #source <= MAX_RUNTIME_BYTES, 'runtime source must be <='..MAX_RUNTIME_BYTES..' bytes')
  local candidate = compile(source) -- validate before changing the running runtime
  local stopped=true
  if runtime then stopped=pcall(runtime.stop_all) end
  if not stopped then candidate.stop_all() end
  state().source = source
  runtime = candidate
  state().runtime_fault=nil
  return {ok = true, tick = game.tick, protocol = 2, bytes = #source}
end
local function installing(fn)
  local ok,result=pcall(fn)
  return helpers.table_to_json(ok and result or {ok=false,tick=game.tick,error={code='invalid_runtime',message=tostring(result)}})
end
remote.add_interface('agent_harness', {
  bot_create = function(name) return operator('bot_create', name) end,
  bot_remove = function(name) return operator('bot_remove', name) end,
  bots = function() return operator('bots') end,
  camera = function(json) return operator('camera', json) end,
  cameras = function() return operator('cameras') end,
  profile_ticks = function(n) return operator('profile_ticks', n) end,
  shift_start = function() return operator('shift_start') end,
  console_log = console_log,
  install =function(source) return installing(function() return install_source(source) end) end,
  -- What this control.lua accepts; a world without it takes one install of <=524288 bytes.
  install_limits = function() return helpers.table_to_json{max_bytes=MAX_RUNTIME_BYTES, chunk_bytes=MAX_CHUNK_BYTES, protocol=2} end,
  -- Chunk index of total for upload id; index 1 starts over (an abandoned upload is dropped).
  install_chunk = function(id, index, total, data)
    return installing(function()
      assert(type(id) == 'string' and #id >= 1 and #id <= 64, 'id must be a 1..64 character string')
      assert(type(total) == 'number' and total == math.floor(total) and total >= 1 and total <= MAX_RUNTIME_BYTES / MAX_CHUNK_BYTES + 1, 'total out of range')
      assert(type(index) == 'number' and index == math.floor(index) and index >= 1 and index <= total, 'index out of range')
      assert(type(data) == 'string' and #data <= MAX_CHUNK_BYTES, 'chunk must be a string of <='..MAX_CHUNK_BYTES..' bytes')
      local s = state()
      if index == 1 then s.pending_install = {id=id, total=total, parts={}, bytes=0} end
      local p = s.pending_install
      assert(p and p.id == id and p.total == total, 'no upload '..id..' in progress; send chunk 1 first')
      assert(index == #p.parts + 1, 'expected chunk '..(#p.parts + 1)..', got '..index)
      assert(p.bytes + #data <= MAX_RUNTIME_BYTES, 'runtime source must be <='..MAX_RUNTIME_BYTES..' bytes')
      p.parts[index] = data; p.bytes = p.bytes + #data
      return {ok=true, tick=game.tick, id=id, received=index, total=total, bytes=p.bytes}
    end)
  end,
  -- Assemble the chunks of id; bytes must match what the host sent.
  install_commit = function(id, bytes)
    return installing(function()
      local s = state()
      local p = s.pending_install
      s.pending_install = nil
      assert(p and p.id == id, 'no upload '..tostring(id)..' in progress')
      assert(#p.parts == p.total, 'upload incomplete: '..#p.parts..' of '..p.total..' chunks')
      local source = table.concat(p.parts)
      assert(#source == bytes, 'upload has '..#source..' bytes, expected '..tostring(bytes))
      return install_source(source)
    end)
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
      assert(request.bot==nil or (type(request.bot)=='string' and request.bot:match('^[a-z][a-z0-9_-]*$') and #request.bot<=16), 'bot must be a bot name')
      assert(request.bot==nil or request.player==nil, 'a request may name a player or a bot, not both')
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
      -- An older runtime would ignore `bot` and act as player 1.
      assert(request.bot==nil or runtime.bots~=nil, 'the running runtime does not support bots; deploy a current runtime')
      local success, result = pcall(runtime.dispatch, request)
      -- The runtime resolves a bot name to its index in request.player; an
      -- unknown bot leaves it unset and stops nobody.
      local who=request.player or (request.bot==nil and 1 or nil)
      if not success and not read_only[request.action] and not request.action:match('^queue_') and runtime.stop_player and type(who)=='number' then pcall(runtime.stop_player,who) end
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
