-- Transport state machine test. JSON codecs are identity maps; engine integration
-- separately exercises the actual Factorio codecs and LuaObject serialization.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local assertions=0
local function eq(a,b) assertions=assertions+1; assert(a==b,tostring(a)..' ~= '..tostring(b)) end
log=function() end
storage={}; game={tick=7}; defines={events={on_tick=1,on_script_path_request_finished=2,on_entity_died=3}}
local encoded,sequence={},0
helpers={table_to_json=function(value) sequence=sequence+1; local key='encoded-'..sequence; encoded[key]=value; return key end,json_to_table=function(key) return encoded[key] end}
local events={}
script={on_init=function(fn) events.init=fn end,on_load=function(fn) events.load=fn end,on_configuration_changed=function(fn) events.config=fn end,on_event=function(id,fn) if type(id)=='table' then events.forward=fn else events.tick=fn end end}
local interface
remote={add_interface=function(_,value) interface=value end}
local calls,stops=0,0
package.loaded.runtime={dispatch=function(r) calls=calls+1; if r.action=='fail' or r.args.fail then error('failure') end; return {calls=calls} end,tick=function() end,stop_all=function() stops=stops+1 end,stop_player=function() stops=stops+1 end}
dofile('mod/agent-harness_0.1.0/control.lua'); events.init()
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
print('control: '..assertions..' assertions passed')
