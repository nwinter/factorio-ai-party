package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b) assert(a==b,tostring(a)..' ~= '..tostring(b)) end
local function has(s,w) assert(s and s:find(w,1,true),tostring(s)..' lacks '..w) end
game={tick=600}
-- Held item diagnostics preserve quality, name both entities, and make no
-- permanent incompatibility claim for an inventory that is merely full.
local D=require('details'){}
local target={valid=true,name='biochamber',type='assembling-machine',position={x=2,y=1},
  get_recipe=function() return {name='iron-bacteria-cultivation'} end}
local ins={type='inserter',name='fast-inserter',position={x=1,y=1},drop_target=target,
  held_stack={valid_for_read=true,name='jelly',count=3,quality={name='uncommon'}}}
target.can_insert=function(a) eq(a.name,'jelly');eq(a.quality,'uncommon');eq(a.count,1);return false end
local text=D.held_blocked(ins);has(text,'fast-inserter (1,1) holds 3 jelly@uncommon');has(text,'biochamber (2,1) cannot accept one now');has(text,'iron-bacteria-cultivation')
target.can_insert=function() return true end;eq(D.held_blocked(ins),nil)
target.can_insert=function() error('unsupported') end;eq(D.held_blocked(ins),nil)
ins.held_stack.valid_for_read=false;eq(D.held_blocked(ins),nil)
-- Each built entry is configured now; wires are deferred once and refusals keep indices.
local events={}
local E=require('entryset'){position=function(p) return p end,reason=tostring,call=function(action,_,a)
 events[#events+1]=action
 if action=='configure' and a.position.x==2 then error('bad recipe',0) end
 return action=='wire' and {connected=true} or {}
end}
local batch={rows={},wires={},set=0,failed={}}
E.built({}, {name='inserter',position={x=1,y=1},configure={filters={'jelly'}},wires={{to={x=2,y=1},color='red'}}},1,batch)
eq(table.concat(events,','),'configure')
E.built({}, {name='biochamber',position={x=2,y=1},configure={recipe='bad'}},3,batch)
local r=E.built_result({},batch,{},false);has(r.settings_note,'pending');eq(#events,2)
r=E.built_result({},batch,{},true);eq(table.concat(events,','),'configure,configure,wire');eq(r.settings[2].index,3);has(r.settings_line,'entry 3 configure: bad recipe')
-- Platform pump checks: existing wire, declared future wire, missing wire, disabled.
prototypes={entity={pump={type='pump'},pole={type='electric-pole'}}}
local read
local C=require('pumpcheck'){read=function() return read end}
local p={force={},surface={find_entities_filtered=function() return {{}} end}}
local entries={{name='pump',position={x=1,y=1},circuit={enable='signal-D = 0'}}}
has(C.plan(p,entries)[1],'no red or green wire declared')
entries[2]={name='pole',position={x=2,y=2},wires={{to={x=1,y=1},color='red'}}}
has(C.plan(p,entries)[1],'1 circuit wire(s) declared')
entries[2].wires[1].color='copper';has(C.plan(p,entries)[1],'no red or green wire declared')
read={enable='signal-D = 0',networks={red={}}};eq(C.plan(p,entries),nil)
read={enable='signal-D = 0'};entries[1].circuit={enable=false};eq(C.plan(p,entries),nil)
entries[1].circuit=nil;has(C.plan(p,entries)[1],'no connected circuit wire')
local many={}
local reads=0
p.surface.find_entities_filtered=function() reads=reads+1;return {} end
for i=1,70 do many[i]={name='pump',position={x=i,y=0},circuit={enable='signal-D = 0'}} end
local capped=C.plan(p,many);eq(reads,64);has(capped[#capped],'6 further pumps not checked')

-- Boiler status never invokes view()'s synchronous map/network fallback.
local state={networks={views={player={surfaces={{name='nauvis',electric={{boiler_low_count=2,boiler_sample_tick=300,
 boiler_low_rows={'(1,2) 3.0 min, iron-chest (1,0): coal*4','(3,2) 2.0 min, no inserter feeds it'}}}}}}}}}
local N=require('networks'){state=function() return state end}
text=N.boiler_line({name='player'},'nauvis');has(text,'under 20 min of own fuel at sampled draw: 2');has(text,'coal*4');has(text,'sample 5 s old')
has(N.boiler_line({name='player'},'gleba'),'unavailable')
-- Minimum moves uses actual completed results, defaults unchanged; explicit
-- threshold overrides short-skip, follows on_fail, and survives repeat copies.
local function run(options)
 local s,calls,active={},0,false
 local who={index=1}
 local Q=require('scheduler'){
  state=function() return s end,player=function() return who end,
  handlers={transfer=function() calls=calls+1;active=options.timed or false;return options.timed and {until_tick=game.tick+1} or {moved=options.n} end,
    craft=function() calls=calls+1;return {} end},
  busy=function() return active end,stop=function() active=false end,
  outcome=function() return options.outcome or 'transferred' end,
  completion=function() return {moved=options.n} end}
 local step={action='transfer',args={up_to=true},min_moved=options.min,on_fail=options.policy,on_short='skip'}
 Q.handlers.queue_submit(who,{steps={step,{action='craft'}}})
 Q.tick();active=false;game.tick=game.tick+10;Q.tick()
 return s.queues[1],calls,Q,who
end
local q,calls=run{n=0,min=1};eq(q.paused,true);eq(q.history[1].ok,false);eq(calls,1);has(q.history[1].result.reason,'moved 0')
q,calls=run{n=0};eq(q.history[1].ok,true);eq(calls,2)
q,calls=run{n=0,min=1,policy='skip'};eq(q.history[1].ok,false);eq(calls,2)
q,calls=run{n=0,min=1,timed=true};eq(q.history[1].ok,false);eq(calls,1)
q,calls=run{n=0,min=1,timed=true,outcome='out_of_items'};eq(q.history[1].ok,false);eq(calls,1)
q,calls=run{n=1,min=1,timed=true};eq(q.history[1].ok,true);eq(calls,2)
local _,_,Q,who=run{n=1,min=1}
assert(not pcall(Q.handlers.queue_submit,who,{steps={{action='transfer',min_moved=1,wait=false}}}))
assert(not pcall(Q.handlers.queue_submit,who,{steps={{action='craft',min_moved=1}}}))
local repeatq=Q.handlers.queue_repeat(who,{steps={{action='transfer',min_moved=1}},times=2})
eq(repeatq.pending[1].min_moved,1)
print('d15_0450b: ok')
