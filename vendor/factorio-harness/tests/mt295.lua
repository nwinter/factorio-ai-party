local state={mt={teams={red={},blue={}}}};game={tick=100}
local current='red';local profile={display_name='Forge',persona='Builds patiently.',avatar={emblem='gear'}}
local feed=dofile('mod/agent-harness_0.1.0/teamfeed.lua'){
 state=function() return state end,team_now=function() return current end,
 agents=function() return current=='red' and {{name='r1',index=1}} or {{name='b1',index=2}} end,
 profile=function() return profile end}
feed.emit('operator','tell','team-private','private instructions')
assert(feed.operator.mt_feed{}.last_seq==0)
feed.emit('r1','say','team-private','one');profile.avatar.emblem='rocket'
current='blue';feed.emit('b1','say','team-private','two')
local read=feed.operator.mt_feed{since=0,limit=1};assert(#read.lines==1 and read.cursor==1 and read.last_seq==2)
assert(read.lines[1].identity.avatar.emblem=='gear','snapshot not changed by later profile')
read=feed.operator.mt_feed{since=read.cursor,limit=1};assert(read.lines[1].team=='blue' and read.cursor==2)
for i=1,2001 do feed.emit('b1','say','team-private','line '..i) end
read=feed.operator.mt_feed{since=0,limit=500};assert(read.gap and #read.lines==500 and read.first_seq==4)
read=feed.operator.mt_feed{limit=2};assert(#read.lines==2 and read.cursor==2003 and read.lines[1].seq==2002)
assert(not pcall(feed.operator.mt_feed,{limit=501}))
assert(not pcall(feed.operator.mt_feed,{since=-1}))
state.mt=nil;feed.emit('b1','say','team-private','ordinary world');assert(not state.mt)
print('mt295 feed ordering, cursor, retention, identity snapshots and ordinary world unchanged: ok')
