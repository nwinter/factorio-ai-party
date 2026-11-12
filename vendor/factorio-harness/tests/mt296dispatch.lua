-- Actual runtime schema/cache, refusal and passive boundaries, with a minimal engine scaffold.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
BUNDLE_ID='test'
storage={agent_harness={active={},mt={teams={red={},blue={},green={}},order={'red','blue','green'},first={}}}}
defines={events={on_script_path_request_finished=10,on_entity_died=11},shooting={not_shooting=0,shooting_enemies=1},
 controllers={character=1,remote=27,spectator=2},direction={north=0},inventory={chest=1},build_mode={normal=1},build_check_type={manual=1},flow_precision_index={five_seconds=0,one_minute=1}}
rendering={draw_text=function() return {valid=true,destroy=function() end} end,get_object_by_id=function() end}
remote={interfaces={}};helpers={json_to_table=function(t) return t end};prototypes={item={}}
local forces={};for i,n in ipairs{'player','red','blue','green','enemy'} do forces[n]={name=n,index=i,technologies={['mt-coinage']={enabled=false,researched=false}},
 chart=function() end,is_chunk_visible=function() return true end,is_chunk_charted=function() return true end,
 get_spawn_position=function() return {x=0,y=0} end,players={},platforms={}} end
local surface={name='nauvis',index=1,find_non_colliding_position=function(_,p) return p end,find_entities_filtered=function() return {} end,can_place_entity=function() return true end}
surface.create_entity=function(a) return {valid=true,name=a.name,type='character',force=a.force,surface=surface,position=a.position,unit_number=100,walking_state={walking=false},
 insert=function(q) return q.count end,get_main_inventory=function() return {get_item_count=function() return 0 end,get_contents=function() return {} end} end} end
game={tick=100,players={},forces=forces,get_player=function() end,get_surface=function() return surface end,print=function() end,connected_players={}}
local R=dofile('mod/agent-harness_0.1.0/runtime.lua');R.operator.bot_create{name='r1',force='red'}
local function call(action,args) return R.dispatch{id='test-'..action,bot='r1',action=action,args=args or {}} end
local function read() return R.as_team('red',function() return R.describe_bundle(),R.market.schema('red') end) end
local b,a=read();assert(b=='test' and next(a)==nil)
for name in pairs(R.market.names()) do
 local ok,e=pcall(call,name,{});assert(not ok and e=='unsupported action; call describe',tostring(e))
 local near=R.as_team('red',R.near_actions,name);for _,v in ipairs(near) do assert(v~=name,'near_actions leaks '..name) end
end
storage.agent_harness.mt.first['chart red>blue']=100
b,a=read();assert(b~='test' and a.offer and not a.market and not a.offer.to)
local one=b;storage.agent_harness.mt.first['shot red>green']=100;b,a=read();assert(b~=one and a.offer.to)
local two=b;forces.red.technologies['mt-coinage'].enabled=true;forces.red.technologies['mt-coinage'].researched=true
b,a=read();assert(b~=two and a.market and a.buy.from)
-- A refused mutation is passive through the real stop_player cleanup path.
local idx=R.bots.index_of('r1');local running={kind='wait',until_tick=999999};storage.agent_harness.active[idx]=running
local ok,e=pcall(call,'sell',{item='iron-ore',price=10,count=1});assert(not ok,tostring(e));R.stop_player(idx)
assert(storage.agent_harness.active[idx]==running,'market refusal interrupted active work')
print('mt296 runtime: pre-contact refusal, hidden suggestions, rung/contact cache keys, passive refusal: ok')
