-- d15 batch5 (operator 05:20, shifts 20-22 requests). Run from the harness root: lua tests/d15_batch5.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,msg) assert(a==b,(msg or '')..' '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end

-- A3 (Muse, twice): a step written flat ({action, position, ...}) is refused on submit, naming the step and the shape. --
do
  game={tick=0}
  local st={}
  local players={[1]={index=1}}
  local handlers={transfer=function() return {} end,collect=function() return {} end}
  local takes={transfer={position=true,item=true,count=true,direction=true},collect={position=true,item=true}}
  local S=dofile('mod/agent-harness_0.1.0/scheduler.lua'){state=function() return st end,player=function(i) return players[i] end,handlers=handlers,
    busy=function() return false end,stop=function() end,stop_index=function() end,condition=function() return false end,validate_condition=function() end,
    takes=function(action,key) return takes[action] and takes[action][key]==true end}
  fails(function() S.handlers.queue_repeat(players[1],{steps={{action='collect',args={position={x=1,y=0},item='yumako'}},
    {action='transfer',position={x=5,y=0},item='yumako',label='drop'}}}) end,
    'steps[2] (transfer, label "drop"): item, position are arguments of transfer written beside action; a step is {action: "transfer", args: {item: ..., position: ...}}')
  fails(function() S.handlers.queue_submit(players[1],{steps={{action='collect',args={item='x'},position={x=1,y=0}}}}) end,
    'this step also has args: put every argument of the action in it')
  eq(st.queues==nil or st.queues[1]==nil or #(st.queues[1].pending or {})==0,true,'nothing queued')
  local ok=pcall(S.handlers.queue_repeat,players[1],{steps={{action='transfer',args={position={x=5,y=0},item='yumako'},wait=true,label='drop'}}})
  assert(ok,'the nested shape passes')
end
print('d15_batch5 A3 flat steps: ok')
