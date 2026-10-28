-- mt277 (private: multi-team phase 2, line 2). Run from the harness root: lua tests/mt277.lua
-- The setup's team accounts (mt-red, ...) joining once each were harness chat lines every agent read: players.lua writes
-- no join or leave line on a map with teams set up, and mt_chat_scrub drops those already in the chat.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end

do
  defines={events={on_player_joined_game=1,on_player_left_game=2}}
  local p={index=5,name='mt-red',valid=true,permission_group={name='pog-guest'}}
  game={tick=100,get_player=function(i) return i==5 and p or nil end}
  local s={}
  local notices={}
  local P=dofile('mod/agent-harness_0.1.0/players.lua'){state=function() return s end,is_human=function() return true end,
    votes_on=function() return {} end,notice=function(from,text) notices[#notices+1]=from..': '..text end}
  P.on_event({name=1,player_index=5}); P.on_event({name=2,player_index=5})
  eq(#notices,2,'a one-team map: join and leave lines as before')
  s.mt={order={'red','blue'}}
  P.on_event({name=1,player_index=5}); P.on_event({name=2,player_index=5})
  eq(#notices,2,'a map with teams: no line')
  eq(s.humans.by_index[5].left_tick,100,'the record is kept')

  s.chat={seq=4,messages={
    {seq=1,tick=10,from='players',text='mt-red joined the game (guest group)',notice=true},
    {seq=2,tick=11,from='server',text='harness v1'},
    {seq=3,tick=12,from='players',text='mt-red left the game',notice=true},
    {seq=4,tick=13,from='luna',text='players are here',player=1000001}},cursors={}}
  local M=dofile('mod/agent-harness_0.1.0/multiteam.lua'){state=function() return s end}
  local r=M.operator.mt_chat_scrub({})
  eq(r.dropped,2); eq(r.kept,2)
  eq(s.chat.messages[1].seq,2); eq(s.chat.messages[2].from,'luna')
  eq(s.chat.seq,4,'sequence numbers go on')
  eq(M.operator.mt_chat_scrub({}).dropped,0,'a second scrub drops nothing')
  game=nil; defines=nil
  print('mt277 join lines: ok')
end
