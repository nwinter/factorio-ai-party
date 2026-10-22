-- Run from repository root: lua tests/d21_batch79.lua
-- d20 batch79 AO1 (Astra #1845: five machines read 3 low_power samples of 601, "low power 0%", with no way to tell
-- startup from brownout): uptime gives each status other than working its first and last sample tick and its longest
-- run of samples in a row, the last 8 status changes, and a share that rounds to 0% with its count.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
game={tick=1000}
defines={inventory={assembling_machine_input=2,furnace_source=2,assembling_machine_output=3,furnace_result=3}}
local recipe={name='refined-concrete',ingredients={}}
local function machine(x) return {valid=true,name='assembling-machine-3',type='assembling-machine',position={x=x,y=83.5},products_finished=0,status='working',
  get_recipe=function() return recipe,{name='normal'} end,get_inventory=function() return {get_item_count=function() return 0 end,get_contents=function() return {} end} end} end
local a,b=machine(20.5),machine(24.5)
local st={}
local U=dofile('mod/agent-harness_0.1.0/uptime.lua'){state=function() return st end,remote_entity=function(_,t) return t.position.x==20.5 and a or b end,
  status_name=function(e) return e.status end,craftrate=function() return {crafts_per_min=22.5,productivity=0} end}
U.handler({index=1},{positions={{x=20.5,y=83.5},{x=24.5,y=83.5}},seconds=120})
-- machine a: low power at the samples of seconds 3 and 4 (two in a row) and at 90 (one); machine b works throughout
local low={[3]=true,[4]=true,[90]=true}
local second=0  -- (the start samples once: second 0)
for t=1001,1000+120*60 do
  game.tick=t
  local job=st.uptime[1]
  if job and t>=job.next_tick then second=second+1; a.status=low[second] and 'low_power' or 'working' end
  U.tick(t)
end
local r=U.handler({index=1},{})
local ra,rb=r.machines[1],r.machines[2]
eq(ra.samples.low_power,3)
local lp=ra.status_runs.low_power
eq(lp.samples,3); eq(lp.longest_run,2); eq(lp.first_s,3); eq(lp.last_s,math.floor((lp.last_tick-1000)/60+0.5))  -- (the phase moves 7 ticks a second)
assert(lp.first_tick>1000 and lp.last_tick>lp.first_tick,'ticks')
eq(#ra.changes,4); has(ra.changes[1],': working -> low_power'); has(ra.changes[2],': low_power -> working')
has(ra.line,string.format('when: low power from 3 s to %d s (ticks %d-%d), at most 2 samples in a row',lp.last_s,lp.first_tick,lp.last_tick))
eq(rb.status_runs,nil); eq(rb.changes,nil)
assert(not rb.line:find('when:',1,true),rb.line)
-- a share under 0.5% names its count (Astra's 3 of 601 read "low power 0%")
local U2=dofile('mod/agent-harness_0.1.0/uptime.lua'){state=function() return {} end}
local job={start=0,samples=601,machines={}}
local m={status={working=598,low_power=3},runs={low_power={first=60,last=36000,longest=1}},changes={{60,'working','low_power'}}}
local t=U2.timing(job,m)
has(t.text,'when: low power from 1 s to 600 s (ticks 60-36000), at most 1 sample in a row')
eq(t.status_runs.low_power.samples,3)
eq(U2.share_text('low_power',3,601),'low power 0% (3 of 601 samples)'); eq(U2.share_text('working',598,601),'working 100%')
-- the last 8 changes only
local a2=machine(1); local st2={}
local U3=dofile('mod/agent-harness_0.1.0/uptime.lua'){state=function() return st2 end,remote_entity=function() return a2 end,status_name=function(e) return e.status end,
  craftrate=function() return {crafts_per_min=1,productivity=0} end}
game.tick=1000
U3.handler({index=1},{position={x=1,y=83.5},seconds=60})
for t=1001,1000+60*60 do
  game.tick=t
  local job=st2.uptime[1]
  if job and t>=job.next_tick then a2.status=(a2.status=='working') and 'no_power' or 'working' end
  U3.tick(t)
end
local r3=U3.handler({index=1},{}).machines[1]
eq(#r3.changes,8); eq(r3.status_runs.no_power.longest_run,1)
print('d21_batch79 AO1 uptime timing: ok')
