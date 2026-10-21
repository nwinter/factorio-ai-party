-- d20 batch70 (operator d21 13:09). Run from the harness root: lua tests/d21_batch70.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,msg) assert(a==b,(msg or '')..' '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end

-- AF2 (viewer Aurora: "Freight review shows 12 missed runs despite newer freight work in chat"; world n #107
-- verify-native-freight-receipts went to its owner Astra alone, every 10 min, and no one was told of the misses): a
-- backup told once when a recipient misses a run, a result the backup records for them, each recipient's latest.
do
  game={tick=0}
  local st={}
  local agents={{name='astra',index=1},{name='sol',index=2},{name='luna',index=3}}
  local boxes={}
  local R=dofile('mod/agent-harness_0.1.0/reminders.lua'){state=function() return st end,
    resolve=function(w) for _,a in ipairs(agents) do if a.name==w then return w end end error('no teammate '..w,0) end,
    agents=function() return agents end,who=function(p) return p.name end,
    deliver=function(index,t) boxes[index]=boxes[index] or {}; table.insert(boxes[index],t) end}
  local astra,sol,luna={name='astra',index=1},{name='sol',index=2},{name='luna',index=3}
  local function run(ticks) for _=1,ticks do game.tick=game.tick+1; R.tick() end end
  fails(function() R.handlers.reminder_add(astra,{message='x',every_ticks=36000,backup='team'}) end,'backup: one teammate\'s name')
  fails(function() R.handlers.reminder_add(astra,{message='x',every_ticks=36000,backup={'sol'}}) end,'backup: one teammate\'s name')
  local add=R.handlers.reminder_add(astra,{name='verify-native-freight-receipts',message='Verify native-route receipts',every_ticks=36000,backup='sol'})
  eq(add.reminder.backup,'sol')
  run(36000)  -- the first run: astra's line, nothing to sol
  eq(#boxes[1],1); eq(boxes[2],nil)
  R.handlers.reminder_ack(astra,{id=1,result='K2 Fulgora PU777/1000, LDS1156'})
  run(36000)  -- the second run, acknowledged: no miss
  eq(boxes[2],nil)
  run(36000)  -- the third: astra's second line waits; a run missed, the backup told once
  eq(#boxes[2],1)
  eq(boxes[2][1].from,'reminder #1')
  eq(boxes[2][1].text,'astra missed a run of reminder #1 verify-native-freight-receipts (astra\'s, every 10m00s; you are its backup): not acknowledged since tick 72000 (10m00s ago), 1 run missed (tick 108000, 0s ago); astra\'s last result: K2 Fulgora PU777/1000, LDS1156 (20m00s ago); reminder_ack {id: 1, for: "astra", result} records one for them')
  run(36000*2)
  eq(#boxes[2],1,'once until astra acknowledges')
  local r=R.handlers.reminders(sol,{all=true}).reminders[1]
  has(r.states,'astra overdue (3 runs missed (the first at tick 108000, 20m00s ago; the last at tick 180000, 0s ago), backup sol told)')
  eq(#r.latest,1); local l=r.latest[1]
  eq(l.name,'astra'); eq(l.waiting_since_tick,72000); eq(l.missed,3); eq(l.acked_tick,36000); eq(l.result,'K2 Fulgora PU777/1000, LDS1156'); eq(l.backup_told_tick,108000)
  eq(l.line,'astra: waiting since tick 72000 (30m00s), 3 runs missed (the first at tick 108000, 20m00s ago; the last at tick 180000, 0s ago), backup sol told; last acknowledged 40m00s ago: K2 Fulgora PU777/1000, LDS1156')
  has(r.line,'; backup sol; ')
  has(r.line,'; latest: astra: waiting since tick 72000')
  -- the backup records a result for astra; only the backup or the owner may, for a recipient, not a checklist
  fails(function() R.handlers.reminder_ack(luna,{id=1,['for']='astra',result='x'}) end,'only reminder #1\'s backup (sol) or its owner')
  fails(function() R.handlers.reminder_ack(sol,{id=1,['for']='luna',result='x'}) end,'luna is not a recipient of reminder #1')
  local a=R.handlers.reminder_ack(sol,{id=1,['for']='astra',result='Kestrel II receipts in the pod ledger: PU 346 landed'})
  eq(a['for'],'astra'); eq(a.missed,3)
  l=R.handlers.reminders(astra,{}).reminders[1].latest[1]
  eq(l.state,'acknowledged'); eq(l.by,'sol'); eq(l.result,'Kestrel II receipts in the pod ledger: PU 346 landed'); eq(l.missed,nil)
  eq(l.line,'astra: acknowledged; last acknowledged 0s ago by sol for them: Kestrel II receipts in the pod ledger: PU 346 landed')
  eq(R.handlers.reminders(astra,{}).reminders[1].result_by,'sol')
  -- a new miss tells the backup again; a backup who is the recipient is not told; false clears it
  run(36000*2)
  eq(#boxes[2],2)
  R.handlers.reminder_edit(astra,{id=1,recipients='astra,sol'})
  R.handlers.reminder_ack(astra,{id=1}); R.handlers.reminder_ack(sol,{id=1})
  local before=#boxes[2]
  run(36000*2)
  eq(#boxes[2],before+2,'sol\'s own run line and the line for astra\'s miss; none for its own miss')
  has(boxes[2][#boxes[2]].text,'astra missed a run of reminder #1')
  r=R.handlers.reminders(astra,{}).reminders[1]
  local by={}; for _,x in ipairs(r.latest) do by[x.name]=x end
  eq(by.astra.backup_told_tick,game.tick); eq(by.sol.backup_told_tick,nil)
  eq(by.astra.result,nil,'acknowledged without a result'); has(by.astra.line,'last acknowledged 20m00s ago (no result given)')
  R.handlers.reminder_edit(astra,{id=1,backup=false})
  eq(R.handlers.reminders(astra,{}).reminders[1].backup,nil)
  -- a job from before results were kept: the last result by that recipient
  local j=st.reminders.jobs[1]
  j.results=nil; j.pending={}; j.acked={astra=game.tick-60,sol=game.tick-30}
  j.result_by='astra'; j.result_tick=game.tick-60; j.last_result='old result'
  by={}; for _,x in ipairs(R.handlers.reminders(astra,{}).reminders[1].latest) do by[x.name]=x end
  eq(by.astra.result,'old result'); eq(by.sol.result,nil)
  game=nil
end
print('d21_batch70 AF2 reminder backup and latest results: ok')
