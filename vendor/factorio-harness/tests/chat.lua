-- Run from repository root: lua tests/chat.lua
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
local printed={}
local astra={index=1,name='pog-astra',chat_color={r=1,g=0.5,b=0}}
local opus={index=2,name='pog-opus',chat_color={r=0.2,g=0.6,b=1}}
local nick={index=3,name='nwinter'}
game={tick=10,print=function(m) printed[#printed+1]=m end,get_player=function(i) return ({astra,opus,nick})[i] end}
local s={}
local chat=dofile('mod/agent-harness_0.1.0/chat.lua'){state=function() return s end}
-- Saying posts to the game chat as the player, coloured, and is not unread for the sender.
eq(chat.handlers.say(astra,{text='taking iron, you take copper'}).seq,1)
eq(printed[1],'[color=1.00,0.50,0.00]pog-astra[/color]: taking iron, you take copper')
eq(chat.unread(1),nil)
-- The other agent sees it as unread until it reads.
local u=chat.unread(2); eq(u.unread,1); eq(u.latest,'pog-astra: taking iron, you take copper')
local r=chat.handlers.chat(opus,{}); eq(#r.messages,1); eq(r.messages[1].from,'pog-astra'); eq(r.cursor,1)
eq(chat.unread(2),nil); eq(#chat.handlers.chat(opus,{}).messages,0)
-- A person typing in a client arrives through on_console_chat; both agents see it.
game.tick=20; chat.on_console_chat({player_index=3,message='nice base'})
eq(chat.unread(1).latest,'nwinter: nice base'); eq(chat.unread(2).unread,1)
-- Newlines are flattened, long text is cut, empty text is refused.
chat.handlers.say(opus,{text='a\nb'}); eq(printed[2]:sub(-3),'a b')
chat.handlers.say(opus,{text=string.rep('x',600)}); eq(#s.chat.messages[#s.chat.messages].text,500)
fails(function() chat.handlers.say(opus,{text=''}) end,'text is required')
-- since/limit keep the newest; the log is bounded.
for i=1,250 do chat.handlers.say(astra,{text='m'..i}) end
eq(#s.chat.messages,200)
r=chat.handlers.chat(opus,{since=0,limit=5}); eq(#r.messages,5); eq(r.messages[5].text,'m250')
fails(function() chat.handlers.chat(opus,{limit=0}) end,'limit must be')
-- peek reads without moving the cursor.
chat.handlers.say(astra,{text='peek test'})
local before=chat.unread(2).unread
eq(#chat.handlers.chat(opus,{since=0,limit=3,peek=true}).messages,3); eq(chat.unread(2).unread,before)
-- With an audience (players minus camera clients), lines go to those players only.
local heard={}
local viewer={index=1,print=function(m) heard[#heard+1]=m end}
local s2={}
local chat2=dofile('mod/agent-harness_0.1.0/chat.lua'){state=function() return s2 end,audience=function() return {viewer} end}
local before_print=#printed
chat2.handlers.say(astra,{text='only players see this'})
eq(#printed,before_print); eq(#heard,1); eq(heard[1]:sub(-21),'only players see this')
print('chat: ok')
