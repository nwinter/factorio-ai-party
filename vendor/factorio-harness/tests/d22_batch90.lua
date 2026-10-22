-- d22 batch90 contracts (AZ1-AZ5: the AU1 review's A1, A3, findings 6 and 7, board request #1878). lua tests/d22_batch90.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,t) assert(type(s)=='string' and s:find(t,1,true),'missing "'..t..'" in: '..tostring(s)) end

-- d22 batch90 AZ1: an item whose evidence read throws is recorded (when, the error) and waits 10 minutes; the other
-- items are checked (s55-57: one throwing item kept first in line stopped every check).
do
  game={tick=0,get_surface=function() return nil end}
  _G.prototypes={item={['iron-plate']={}}}
  local st={}
  local items={[3]={id=3,kind='task',title='Broken area',status='doing',owner='luna',notes={},created_tick=0,updated_tick=0,area={left_top={x=0,y=0},right_bottom={x=8,y=8}}},
    [5]={id=5,kind='task',title='Iron for Swift',status='doing',owner='opus',notes={},created_tick=0,updated_tick=0,needs={{name='iron-plate',count=500}}}}
  local P=dofile('mod/agent-harness_0.1.0/progress.lua'){state=function() return st end,items=function() return items end,
    owner_surface=function(name) if name=='luna' then error('surface read failed') end return 'nauvis' end,total=function() return 100 end,
    since_request=function() return 600,1 end,waiting=function() return nil end,who=function(p) return p.name end,QUIET=72000,PROJECT_QUIET=108000}
  P.tick()
  eq(st.progress.items[3].state,'check failed'); assert(st.progress.items[3].error:find('surface read failed',1,true),st.progress.items[3].error)
  eq(st.progress.items[3].tick,0)
  game.tick=120; P.tick()
  eq(st.progress.items[5].state,'first check','the next item is checked')
  game.tick=240; P.tick()
  eq(st.progress.items[3].tick,0,'the failed item waits its 10 minutes')
  local r=P.read({},{id=3})
  assert(r.lines[1]:find('checked 4s ago: check failed (the game read threw: ',1,true) and r.lines[1]:find('surface read failed; next check in 10 min)',1,true),r.lines[1])
  assert(r.rows[1].check_error:find('surface read failed',1,true) and r.rows[1].checked_s==4,r.rows[1].check_error)
  game.tick=36000; P.tick()
  eq(st.progress.items[3].tick,36000,'checked again after 10 minutes'); eq(st.progress.items[3].state,'check failed')
  game.tick=36120; P.tick(); game.tick=36240; P.tick()
  eq(st.progress.items[5].state,'unchanged since the last check','the other item keeps its 10-minute checks')
  -- once the read works, a first check; the error goes
  P=dofile('mod/agent-harness_0.1.0/progress.lua'){state=function() return st end,items=function() return items end,
    owner_surface=function() return 'nauvis' end,total=function() return 100 end,since_request=function() return 600,1 end,
    waiting=function() return nil end,who=function(p) return p.name end,QUIET=72000,PROJECT_QUIET=108000}
  game.tick=72000; P.tick()
  eq(st.progress.items[3].state,'first check'); eq(st.progress.items[3].error,nil)
  game=nil; prototypes=nil
  print('AZ1 a throwing check recorded, the others go on: ok')
end

-- AZ2 (A3): reminder_* actions are talk, never game work (luna's 222 acks of #71 kept her standing time at 0);
-- a reminder linked to a board item that has not changed since an ack reads "acknowledged, not done".
do
  game={tick=600}
  local st={stand={[1]=100}}
  local I=dofile('mod/agent-harness_0.1.0/idle.lua'){state=function() return st end,is_read=function(a) return a=='reminders' end}
  for _,a in ipairs({'reminder_ack','reminder_add','reminder_snooze','reminder_edit','reminder_remove'}) do I.request(1,a,{id=1},{ok=true}) end
  eq(st.stand[1],100,'acks do not end standing')
  local b=st.idle_log[1][math.floor(game.tick/3600)]
  eq(b.talk,5); eq(b.acts,0)
  I.request(1,'craft',{},{crafted=2})
  eq(st.stand[1],nil,'a game action ends it')
  game=nil
end
do
  game={tick=1000}
  local st,sent={},{}
  local items={[1514]={id=1514,kind='task',status='doing',title='Gleba farm',created_tick=0,updated_tick=500}}
  local R=dofile('mod/agent-harness_0.1.0/reminders.lua'){state=function() return st end,who=function(p) return p.name end,
    resolve=function(n) return n end,agents=function() return {{name='luna',index=1}} end,
    deliver=function(index,t) sent[#sent+1]={index=index,t=t} end,item=function(id) return items[id] end}
  local luna={name='luna'}
  local id=R.handlers.reminder_add(luna,{name='farm',message='check the farm',every_ticks=10800,board_item=1514}).added
  game.tick=11800; R.tick()
  R.handlers.reminder_ack(luna,{id=id,result='looked'})
  game.tick=12400
  local row=R.handlers.reminders(luna,{}).reminders[1]
  has(row.states,'luna acknowledged, not done: board #1514 (doing) unchanged since the ack, last change 3m18s ago')
  has(row.latest[1].state,'acknowledged, not done'); eq(row.yours:sub(1,22),'acknowledged, not done')
  items[1514].updated_tick=12000                          -- the item moved after the ack
  eq(R.handlers.reminders(luna,{}).reminders[1].yours,'acknowledged')
  items[1514].updated_tick=100; items[1514].status='done'  -- done: plain
  eq(R.handlers.reminders(luna,{}).reminders[1].yours,'acknowledged')
  game=nil
  print('AZ2 reminder acks are talk; acknowledged, not done: ok')
end

-- AZ5 (Sol board #1878): assembler_batch's holds are false whatever the network count. A logistic condition reads the
-- network's count less what deliveries reserved (Sol's thruster read -3), so "thruster < 0" held true and the output
-- inserter ran; every generated hold is "ITEM < -2147483648", as circuit_set switch_off's condition.
do
  local B=dofile('mod/agent-harness_0.1.0/batch.lua'){}
  eq(B.HOLD,' < -2147483648')
  local src=io.open('mod/agent-harness_0.1.0/batch.lua'):read('a')
  assert(not src:find("' < 0'",1,true),'no fixed < 0 hold left')
  -- the 32-bit least value is what a count can never be under: the condition never holds at any count, -3 included
  for _,n in ipairs({-3,-2147483647,0,5}) do assert(not (n < -2147483648)) end
  print('AZ5 assembler_batch holds never hold: ok')
end
