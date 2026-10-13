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
r=chat.handlers.say(opus,{text=string.rep('x',600)}); eq(#s.chat.messages[#s.chat.messages].text,500)
eq(r.cut.length,600); eq(r.cut.kept,500) -- the reply says it was cut
eq(chat.handlers.say(opus,{text=string.rep('x',500)}).cut,nil)
-- aloud says who hears it: spoken on the stream in your voice; text otherwise.
assert(chat.schema.say.aloud:find('spoken in your own voice',1,true)); assert(not chat.schema.say.aloud:find('sparingly',1,true))
fails(function() chat.handlers.say(opus,{text=''}) end,'text is required')
-- since/limit keep the newest; the log is bounded.
for i=1,250 do chat.handlers.say(astra,{text='m'..i}) end
eq(#s.chat.messages,200)
r=chat.handlers.chat(opus,{since=0,limit=5}); eq(#r.messages,5); eq(r.messages[5].text,'m250')
fails(function() chat.handlers.chat(opus,{limit=0}) end,'limit must be')
-- peek reads without moving the cursor.
chat.handlers.say(astra,{text='peek test'})
local before=chat.unread(2,'peek').unread
eq(#chat.handlers.chat(opus,{since=0,limit=3,peek=true}).messages,3); eq(chat.unread(2,'peek').unread,before)
-- Lossless: a read marks only what it returned; the older unread stay unread and are counted.
local s3={}
local c3=dofile('mod/agent-harness_0.1.0/chat.lua'){state=function() return s3 end}
for i=1,10 do c3.handlers.say(astra,{text='a'..i}) end
r=c3.handlers.chat(opus,{limit=3})
eq(#r.messages,3); eq(r.messages[1].text,'a8'); eq(r.messages[3].text,'a10'); eq(r.remaining,7); eq(r.cursor,10)
eq(c3.unread(2,'peek').unread,7); eq(c3.unread(2,'peek').latest,'pog-astra: a7')
r=c3.handlers.chat(opus,{limit=5}); eq(r.messages[1].text,'a3'); eq(r.messages[5].text,'a7'); eq(r.remaining,2)
r=c3.handlers.chat(opus,{}); eq(#r.messages,2); eq(r.messages[2].text,'a2'); eq(r.remaining,nil)
eq(s3.chat.cursors[2],10); eq(s3.chat.read[2],nil)
-- Writing does not mark others' unread messages read (the old cursor jumped over them).
c3.handlers.say(astra,{text='b1'}); c3.handlers.say(opus,{text='reply'}); c3.handlers.say(astra,{text='b2'})
r=c3.handlers.chat(opus,{}); eq(#r.messages,2); eq(r.messages[1].text,'b1'); eq(r.messages[2].text,'b2')
-- since returns everything after it, the reader's own lines included, and marks those read.
r=c3.handlers.chat(opus,{since=10,peek=true}); eq(#r.messages,3); eq(r.messages[2].text,'reply')
c3.handlers.say(astra,{text='c1'}); c3.handlers.say(astra,{text='c2'})
r=c3.handlers.chat(opus,{since=14,limit=1}); eq(r.messages[1].text,'c2'); eq(r.remaining,1)
eq(c3.unread(2,'peek').latest,'pog-astra: c1')
-- The reply trailer repeats only when a newer message arrived; 'always' (status) shows it anyway.
eq(c3.unread(2).unread,1); eq(c3.unread(2),nil); eq(c3.unread(2,'always').unread,1); eq(c3.unread(2),nil)
c3.handlers.say(astra,{text='c3'}); eq(c3.unread(2).unread,2); eq(c3.unread(2),nil)
-- peek neither shows-and-forgets nor hides: it always reports and remembers nothing.
c3.handlers.say(astra,{text='c4'}); eq(c3.unread(2,'peek').unread,3); eq(c3.unread(2).unread,3)
-- After everything is read the trailer is gone and a new message shows again.
c3.handlers.chat(opus,{}); eq(c3.unread(2),nil)
c3.handlers.say(astra,{text='d1'}); eq(c3.unread(2).latest,'pog-astra: d1')
-- The read set stays bounded by the log when a reader keeps cherry-picking the newest.
for i=1,300 do c3.handlers.say(astra,{text='e'..i}); if i%2==0 then c3.handlers.chat(opus,{limit=1}) end end
local n=0; for _ in pairs(s3.chat.read[2] or {}) do n=n+1 end
assert(n<=200,'read set bounded: '..n)
eq(#s3.chat.messages,200)
-- With an audience (players minus camera clients), lines go to those players only.
local heard={}
local viewer={index=1,print=function(m) heard[#heard+1]=m end}
local s2={}
local chat2=dofile('mod/agent-harness_0.1.0/chat.lua'){state=function() return s2 end,audience=function() return {viewer} end}
local before_print=#printed
chat2.handlers.say(astra,{text='only players see this'})
eq(#printed,before_print); eq(#heard,1); eq(heard[1]:sub(-21),'only players see this')
-- Drained reads: every unread mention in full past the limit, a digest of the rest, `left` until read.
local s4={}
local c4=dofile('mod/agent-harness_0.1.0/chat.lua'){state=function() return s4 end,
  mention_of=function(index,m) return index==2 and m.player~=2 and m.text:find('@opus',1,true) and '@' or nil end}
nick.chat_color={r=1,g=1,b=1}
for i=1,40 do c4.handlers.say(i%3==0 and nick or astra,{text=(i==2 or i==35) and '@opus m'..i or 'm'..i}) end
r=c4.handlers.chat(opus,{limit=3})
eq(#r.messages,5); eq(r.messages[1].text,'@opus m2'); eq(r.messages[1].mention,'@'); eq(r.messages[2].text,'@opus m35')
eq(r.messages[3].text,'m38'); eq(r.messages[3].mention,nil)
eq(r.remaining,35); eq(r.digest,'35 older messages not shown (seq 1..37): pog-astra 23, nwinter 12; chat again for them')
eq(c4.left(2),35); eq(c4.left(1),nil)
c4.handlers.say(astra,{text='new'}); eq(c4.left(2),36)
r=c4.handlers.chat(opus,{limit=100}); eq(r.remaining,nil); eq(r.digest,nil); eq(c4.left(2),nil)
-- peek and since reads leave `left` alone.
for i=1,5 do c4.handlers.say(astra,{text='p'..i}) end
c4.handlers.chat(opus,{limit=1,peek=true}); eq(c4.left(2),nil)
c4.handlers.chat(opus,{limit=1,since=0}); eq(c4.left(2),nil)
-- look: a camera hint for the stream, checked and kept on the message (Sol's 14:09 line about Sunward).
local s5={}
local nauvis={name='nauvis'}
local vulcanus={name='vulcanus'}
local force={is_chunk_charted=function(surface,c) return surface==nauvis or (c.x>=-5 and c.x<=5) end}
local sol={index=4,name='pog-sol',chat_color={r=1,g=0.8,b=0},surface=vulcanus,force=force}
game.surfaces={nauvis=nauvis,vulcanus=vulcanus}
local c5=dofile('mod/agent-harness_0.1.0/chat.lua'){state=function() return s5 end,
  platform=function(p,name) if name=='Sunward' then return {name='Sunward'} end error('no platform named '..tostring(name)..'; platforms: Sunward',0) end,
  agents=function() return {{index=1,name='astra',display_name='Astra'},{index=4,name='sol',display_name='Sol'}} end}
r=c5.handlers.say(sol,{text='First Vulcanus to Nauvis delivery is loaded up on Sunward and ready to go home.',aloud=true,look={platform='Sunward'}})
eq(s5.chat.messages[r.seq].look.platform,'Sunward')
local m=c5.handlers.chat(astra,{since=0}).messages[1]; eq(m.look.platform,'Sunward'); eq(m.aloud,true)
c5.handlers.say(sol,{text='look',look={agent='Astra'}}); eq(s5.chat.messages[2].look.agent,'astra')
c5.handlers.say(sol,{text='here',look={position={x=10.04,y=-20}}})
eq(s5.chat.messages[3].look.surface,'vulcanus'); eq(s5.chat.messages[3].look.position.x,10)
c5.handlers.say(sol,{text='there',look={area={left_top={-10,-10},right_bottom={30,10}},surface='nauvis'}})
local l=s5.chat.messages[4].look; eq(l.surface,'nauvis'); eq(l.position.x,10); eq(l.extent,40)
fails(function() c5.handlers.say(sol,{text='x',look={platform='Starling'}}) end,'no platform named Starling')
fails(function() c5.handlers.say(sol,{text='x',look={agent='zed'}}) end,'no agent named zed; agents: astra, sol')
fails(function() c5.handlers.say(sol,{text='x',look={position={x=900,y=0}}}) end,'is not charted')
fails(function() c5.handlers.say(sol,{text='x',look={surface='gleba',position={x=0,y=0}}}) end,'no surface named gleba')
fails(function() c5.handlers.say(sol,{text='x',look={nothing=1}}) end,'look must be')
eq(#s5.chat.messages,4) -- a refused look posts nothing
assert(c5.schema.say.look:find('{platform: NAME}',1,true))
print('chat: ok')
