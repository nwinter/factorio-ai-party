-- d24 batch177 QT1 (viewer Aurora 17:20: "#151 is enabled every 20m but hidden from Active and labelled done despite
-- its next run"). World n 17:25: reminder #151 read enabled true, done true, every 20m00s, next in 17m51s, states "sol
-- done". A one-time job that ran is off and done; edited to a cadence and enabled, it kept done. done belongs to a job
-- that is off: an edit that enables a job clears it, and a job's row never says done while it is enabled (so a job
-- saved that way reads right). Run from the harness root: lua tests/d24_batch177.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end

game={tick=600}
local st={}
local api={state=function() return st end,who=function(p) return p.name end,resolve=function(n) return n end,
  agents=function() return {{name='sol',index=1}} end,deliver=function() end}
local R=dofile('mod/agent-harness_0.1.0/reminders.lua')(api)
local sol={name='sol'}
local function row(id) return R.handlers.reminders(sol,{id=id}).reminders[1] end

-- a one-time job runs: off and done
local id=R.handlers.reminder_add(sol,{name='BF age and buffer review after rollback',message='review',due_in_ticks=3600}).added
game.tick=4200; R.tick()
local r=row(id)
eq(r.enabled,false); eq(r.done,true)
R.handlers.reminder_ack(sol,{id=id,result='no gap'})
-- edited to every 20 minutes and enabled: on, not done, its next run named
R.handlers.reminder_edit(sol,{id=id,every_ticks=72000,enabled=true})
r=row(id)
eq(r.enabled,true); eq(r.done,nil,'an enabled job is not done'); eq(r.next_due_in_s,1200); eq(r.cadence,'every 20m00s')
assert(r.line:find('next in 20m00s',1,true),r.line)
-- a job saved enabled and done (as #151 was) reads not done
st.reminders.jobs[id].done=true
r=row(id)
eq(r.enabled,true); eq(r.done,nil)
-- off again: off, and a job that is off and done still reads done
R.handlers.reminder_edit(sol,{id=id,enabled=false})
eq(row(id).done,true,'off and done stays done')
R.handlers.reminder_edit(sol,{id=id,enabled=true})
eq(st.reminders.jobs[id].done,nil,'enabling clears it')
print('d24_batch177 QT1 an enabled reminder is not done: ok')
