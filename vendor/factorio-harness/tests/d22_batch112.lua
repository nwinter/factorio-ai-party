-- d22 batch112 BV1 (Astra #1962): job-36447's build read interrupted in the queue history, 4 tiles unplaced, after she
-- edited pending jobs by id; the record said nothing more. queue_edit leaves the active step alone (two replays of her
-- edits on a copy of world n: the build ended done), and now says so as read; an interrupted step's record names what
-- paused the queue and, for a build not run again, the entries it left.
-- Run from the harness root: lua tests/d22_batch112.lua
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
game={tick=0}
local state,active={},{}
local players={[1]={index=1}}
-- a walking build: its action keeps the entries left for the call it walks for (autowalk.lua then_call)
local handlers={
  build=function(p,a) active[p.index]={until_tick=game.tick+100,then_call={action='build',args={builds=a.builds}}}; return {walking='entry 1'} end,
  craft=function() return {started=1} end,
}
local S=dofile('mod/agent-harness_0.1.0/scheduler.lua'){
  state=function() return state end,
  player=function(i) return players[i] end,
  handlers=handlers,
  busy=function(p,action) return action=='build' and active[p.index]~=nil end,
  stop=function(p) active[p.index]=nil end,stop_index=function(i) active[i]=nil end,
  left_undone=function(i)
    local a=active[i]
    local list=a and a.then_call.args.builds or {}
    if #list==0 then return nil end
    return {count=#list,line=string.format('ice-platform (%g,%g)',list[1].position.x,list[1].position.y)}
  end,
}
local h=S.handlers
local p=players[1]
local function tick() game.tick=game.tick+1; S.tick() end
local b={{item='ice-platform',position={x=-136.5,y=-394.5}},{item='ice-platform',position={x=-202.5,y=-394.5}}}
h.queue_submit(p,{steps={{action='build',args={builds=b},on_fail='skip'},{action='craft'},{action='craft'}}})
tick()
local st=h.queue_status(p,{pending='all'})
eq(st.active.id,'job-1')
-- an edit of a pending step by id: the active step as read after it
local r=h.queue_edit(p,{id='job-2',steps={{action='craft'}}})
eq(r.active_step,'job-1 build: still the active step, its action running; this edit changed pending steps only')
eq(active[1]~=nil,true,'its action runs on')
r=h.queue_edit(p,{id='job-3',to=1})
has(r.active_step,'job-1 build: still the active step')
-- with expected_revision and index too
r=h.queue_edit(p,{expected_revision=h.queue_status(p).revision,index=1,remove=1,steps={}})
has(r.active_step,'still the active step, its action running')
-- the queue paused by something else (a direct call that drives the character): the record names it, and the build's
-- entries left
S.pause(1)
local last=state.queues[1].history[#state.queues[1].history]
eq(last.id,'job-1'); eq(last.result.reason,'interrupted')
eq(last.result.paused_by,'paused (a direct call that drives your character, stop, or a harness update)')
eq(last.result.left_undone.count,2)
eq(last.result.not_requeued,'not run again: 2 entries left unbuilt (ice-platform (-136.5,-394.5))')
S.pause(1,'your action ended died')
-- no step active: queue_edit says so
state.queues[1].paused=true
r=h.queue_edit(p,{id=state.queues[1].pending[1].id,steps={{action='craft'}}})
eq(r.active_step,'no step was active; this edit changed pending steps only')
game=nil
print('d22_batch112 BV1 queue_edit active step and interrupted record: ok')
