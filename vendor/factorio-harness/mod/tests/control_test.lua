-- Transport state machine test. JSON codecs are identity maps; engine integration
-- separately exercises the actual Factorio codecs and LuaObject serialization.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local assertions=0
local function eq(a,b) assertions=assertions+1; assert(a==b,tostring(a)..' ~= '..tostring(b)) end
log=function() end
storage={}; defines={events={on_tick=1,on_script_path_request_finished=2,on_entity_died=3,on_player_created=4,on_built_entity=5,on_console_command=9,
  on_research_finished=40,on_research_queued=41,on_rocket_launch_ordered=42},input_action={deconstruct=1,upgrade=2,import_blueprint_string=3}}
-- Permission groups: the guest group is created at init with the planners and blueprint import denied.
local groups={}
local function group(name) local g={name=name,players={},denied={}}
  g.set_allows_action=function(a,allowed) g.denied[a]=not allowed end
  g.add_player=function(p) p.group=name end
  groups[name]=g; return g end
local people={{index=1,name='nick',valid=true},{index=2,name='pog-cam1',valid=true},{index=3,name='eve',valid=true}}
game={tick=7,permissions={get_group=function(n) return groups[n] end,create_group=group},get_player=function(i) return people[i] end}
local encoded,sequence={},0
helpers={table_to_json=function(value) sequence=sequence+1; local key='encoded-'..sequence; encoded[key]=value; return key end,json_to_table=function(key) return encoded[key] end}
local events={}
script={on_init=function(fn) events.init=fn end,on_load=function(fn) events.load=fn end,on_configuration_changed=function(fn) events.config=fn end,on_event=function(id,fn) if type(id)=='table' then events.forward=fn; events.forwarded=id elseif id==4 then events.created=fn elseif id==9 then events.console=fn else events.tick=fn end end}
local interface
remote={add_interface=function(_,value) interface=value end}
local calls,stops=0,0
package.loaded.runtime={dispatch=function(r) calls=calls+1; if r.action=='fail' or r.args.fail then error('failure') end; return {calls=calls} end,tick=function() end,stop_all=function() stops=stops+1 end,stop_player=function() stops=stops+1 end}
dofile('mod/agent-harness_0.1.0/control.lua'); events.init()
local guest=groups['pog-guest']
eq(guest.denied[1],true); eq(guest.denied[2],true); eq(guest.denied[3],true)
-- A newcomer joins as a guest; camera clients and names the operator trusted do not.
storage.agent_harness.trusted_names={eve=true}
for i=1,3 do events.created({player_index=i}) end
eq(people[1].group,'pog-guest'); eq(people[2].group,nil); eq(people[3].group,nil)
-- The player log's events are forwarded to the runtime with the older ones.
local forwarded_ids={}
for _,id in ipairs(events.forwarded) do forwarded_ids[id]=true end
eq(forwarded_ids[2] and forwarded_ids[3] and forwarded_ids[5],true); eq(forwarded_ids[4],nil)
-- Research news (research.lua): a finished and a queued technology.
eq(forwarded_ids[40] and forwarded_ids[41],true)
-- Rocket launches (silo.lua's last launch).
eq(forwarded_ids[42],true)
-- Forwarded engine events reach runtime.on_event; a failure quarantines the runtime.
local forwarded={}
package.loaded.runtime.on_event=function(e) forwarded[#forwarded+1]=e.name; if e.fail then error('bad event') end end
events.forward({name=2}); eq(forwarded[1],2)
events.forward({name=3,fail=true}); eq(storage.agent_harness.runtime_fault.message:find('bad event')~=nil,true)
storage.agent_harness.runtime_fault=nil
local function request(id,action) return helpers.table_to_json{id=id,action=action,args={}} end
local first=request('one','build'); local response=interface.dispatch(first)
eq(encoded[response].ok,true); eq(interface.dispatch(first),response); eq(calls,1)
local conflict=interface.dispatch(request('one','craft')); eq(encoded[conflict].ok,false); eq(calls,1)
local failing=request('two','fail'); local failure=interface.dispatch(failing)
eq(encoded[failure].ok,false); eq(interface.dispatch(failing),failure); eq(calls,2)
local observation=request('read','observe'); interface.dispatch(observation); interface.dispatch(observation); eq(calls,4)
-- The operator's 5-second votes_pending poll is a read: it never fills the replay cache.
local polled=#storage.agent_harness.order
for i=1,3 do interface.dispatch(request('poll-'..i,'votes_pending')) end
eq(#storage.agent_harness.order,polled)
local stopped_before=stops
local invalid_read=helpers.table_to_json{id='invalid-read',action='observe',args={fail=true}}
eq(encoded[interface.dispatch(invalid_read)].ok,false); eq(stops,stopped_before)
local invalid_edit=helpers.table_to_json{id='invalid-edit',action='queue_edit',args={fail=true}}
eq(encoded[interface.dispatch(invalid_edit)].ok,false); eq(stops,stopped_before)
local bad=interface.install('not valid Lua'); eq(encoded[bad].ok,false); eq(storage.agent_harness.source,nil)
local source='return {dispatch=function() return {new=true} end,tick=function() end,stop_all=function() end}'
eq(encoded[interface.install(source)].ok,true); eq(storage.agent_harness.source,source)
eq(encoded[interface.dispatch(request('new','observe'))].result.new,true)
events.load(); eq(encoded[interface.dispatch(request('reload','observe'))].result.new,true)
-- Chunked install: limits, chunks in order, byte check, then the same swap.
eq(encoded[interface.install_limits()].max_bytes,8*1024*1024); eq(encoded[interface.install_limits()].chunk_bytes,262144)
local chunked='return {dispatch=function() return {chunked=true} end,tick=function() end,stop_all=function() end}'
local parts={chunked:sub(1,30),chunked:sub(31,60),chunked:sub(61)}
eq(encoded[interface.install_chunk('u1',2,3,parts[2])].ok,false) -- chunk 1 first
eq(encoded[interface.install_chunk('u1',1,3,parts[1])].received,1)
eq(encoded[interface.install_chunk('u1',3,3,parts[3])].ok,false) -- out of order
eq(encoded[interface.install_chunk('u1',2,3,parts[2])].bytes,60)
eq(encoded[interface.install_commit('u1',#chunked)].ok,false) -- incomplete; the upload is dropped
eq(storage.agent_harness.pending_install,nil); eq(encoded[interface.dispatch(request('still-new','observe'))].result.new,true)
for i=1,3 do interface.install_chunk('u2',i,3,parts[i]) end
eq(encoded[interface.install_commit('u2',#chunked+1)].ok,false) -- byte count mismatch
for i=1,3 do interface.install_chunk('u3',i,3,parts[i]) end
local committed=encoded[interface.install_commit('u3',#chunked)]
eq(committed.ok,true); eq(committed.protocol,2); eq(committed.bytes,#chunked); eq(storage.agent_harness.source,chunked)
eq(encoded[interface.dispatch(request('chunked','observe'))].result.chunked,true)
eq(encoded[interface.install_chunk('u4',1,1,string.rep('x',262145))].ok,false) -- chunk too large
-- The single-call cap is 8 MiB now (was 524288).
local big='return {dispatch=function() return {big=true} end,tick=function() end,stop_all=function() end}\n--'..string.rep('x',600000)
eq(encoded[interface.install(big)].ok,true)
eq(encoded[interface.install(source)].ok,true)
for i=1,260 do interface.dispatch(request('bounded-'..i,'build')) end
eq(#storage.agent_harness.order,256); eq(storage.agent_harness.cache.one,nil)
-- Request byte budget also bounds large mutation replay records.
for i=1,10 do
  local key=string.rep('x',900000)..i
  encoded[key]={id='large-'..i,action='build',args={}}
  interface.dispatch(key)
end
eq(storage.agent_harness.cache_bytes<=8*1024*1024,true)
eq(storage.agent_harness.cache['large-1'],nil)
eq(storage.agent_harness.cache['large-10']~=nil,true)
-- Older saves lazily reconstruct accounting from persisted records.
storage.agent_harness.cache_bytes=nil
interface.dispatch(request('migrated','observe'))
eq(storage.agent_harness.cache_bytes>0,true)
local faulty='return {dispatch=function() return {diagnostic=true} end,tick=function() storage.tick_calls=(storage.tick_calls or 0)+1; error("tick broke") end,stop_all=function() error("cleanup broke") end}'
log=function() end
eq(encoded[interface.install(faulty)].ok,true)
events.tick{tick=8}; events.tick{tick=9}
eq(storage.tick_calls,1); eq(storage.agent_harness.runtime_fault.tick,7)
local quarantined=encoded[interface.dispatch(request('fault-write','build'))]
eq(quarantined.ok,false); eq(quarantined.error.code,'runtime_fault')
eq(encoded[interface.dispatch(request('fault-read','observe'))].ok,true)
eq(encoded[interface.install(source)].ok,true); eq(storage.agent_harness.runtime_fault,nil)
eq(encoded[interface.dispatch(request('recovered-write','build'))].ok,true)
-- Bots: a request names a player or a bot (a valid name), never both.
local function bot_request(id,fields) local r={id=id,action='build',args={}}; for k,v in pairs(fields) do r[k]=v end; return helpers.table_to_json(r) end
-- A runtime without bot support refuses bot requests instead of acting as player 1.
local before_calls=calls
eq(encoded[interface.dispatch(bot_request('bot-old',{bot='astra'}))].error.code,'invalid_request'); eq(calls,before_calls)
eq(encoded[interface.install('return {bots={},dispatch=function() return {} end,tick=function() end,stop_all=function() end}')].ok,true)
eq(encoded[interface.dispatch(bot_request('bot-ok',{bot='astra'}))].ok,true)
eq(encoded[interface.dispatch(bot_request('bot-both',{bot='astra',player=1}))].error.code,'invalid_request')
eq(encoded[interface.dispatch(bot_request('bot-bad',{bot='Astra!'}))].error.code,'invalid_request')
-- A failed request for an unknown bot stops nobody (not player 1).
stopped={}
local botty='return {bots={},dispatch=function(r) if r.bot=="known" then r.player=1000001 end; error("nope") end,tick=function() end,stop_all=function() end,stop_player=function(i) stopped[#stopped+1]=i end,'..
  'operator={bot_create=function(name) return {ok=true,bot={name=name}} end,camera=function(args) return {ok=true,args=args} end}}'
eq(encoded[interface.install(botty)].ok,true)
interface.dispatch(bot_request('ghost-bot',{bot='ghost'})); eq(#stopped,0)
interface.dispatch(bot_request('known-bot',{bot='known'})); eq(stopped[1],1000001)
-- Operator calls go to runtime.operator and report failures as JSON.
eq(encoded[interface.bot_create('astra')].bot.name,'astra')
eq(encoded[interface.camera('cam-json')].ok,true)
eq(encoded[interface.bot_remove('astra')].error.code,'operator_failed')
-- Console audit: harness requests are only counted; anything else is logged by shape.
game.get_player=function(i) return {name='player'..i} end
local function console(text,player,name) events.console{command=name or 'silent-command',parameters=text,player_index=player} end
local function audit_log(since) return encoded[interface.console_log(since)] end
console('rcon.print(remote.call("agent_harness", "dispatch", [[\n{"id":"a","action":"status","bot":"haiku"}]]))')
console('rcon.print(remote.call("agent_harness","dispatch",[==[{"id":"b","action":"say","args":{"text":"]] x"}}]==]))')
local log0=audit_log(0); eq(log0.harness,2); eq(log0.other,0); eq(#log0.entries,0)
-- Code after a closed long string, a body ending in "]", another command name: all logged.
console('rcon.print(remote.call("agent_harness", "dispatch", [[\n{}]])) game.speed=10 rcon.print(remote.call("agent_harness", "dispatch", [[\n{}]]))')
console('rcon.print(remote.call("agent_harness", "dispatch", [[\n{}]]]))')
console('rcon.print(remote.call("agent_harness", "dispatch", [[\n{}]]))',nil,'c')
console('game.player.insert{name="iron-plate",count=100}',1,'c')
local log1=audit_log(0); eq(log1.harness,2); eq(log1.other,4); eq(#log1.entries,4)
eq(log1.entries[1].first_text:find('game.speed=10',1,true)~=nil,true); eq(log1.entries[1].players[1],'rcon')
eq(log1.entries[4].command,'c'); eq(log1.entries[4].players[1],'player1')
-- The same shape with other numbers and long strings is one entry with a count; since returns only what changed.
console('rcon.print(remote.call("agent_harness","camera",[[{"zoom":0.5}]]))')
console('rcon.print(remote.call("agent_harness","camera",[[{"zoom":12}]]))')
local log2=audit_log(log1.seq); eq(#log2.entries,1); eq(log2.entries[1].count,2)
eq(log2.entries[1].shape,'silent-command rcon.print(remote.call("agent_harness","camera",[[]]))')
eq(log2.entries[1].first_text:find('0.5',1,true)~=nil,true); eq(log2.entries[1].last_text:find('12',1,true)~=nil,true)
-- Bounded: past 500 shapes the least recently seen ones are dropped.
for i=1,500 do console('local x'..string.rep('y',i)..'=1') end
local log3=audit_log(0); eq(#log3.entries,500); eq(log3.dropped,5)
-- A malformed event is logged, never raised.
events.console{command='c',parameters={}}
print('control: '..assertions..' assertions passed')
