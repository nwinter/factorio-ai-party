-- Run from repository root: lua tests/audience.lua
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
local printed,mentions={},{}
local astra={index=1,name='astra',chat_color={r=1,g=0.5,b=0}}
local grok={index=2,name='grok',chat_color={r=0.2,g=0.6,b=1}}
game={tick=600,print=function(m) printed[#printed+1]=m end}
local s={}
local chat=dofile('mod/agent-harness_0.1.0/chat.lua'){state=function() return s end,on_message=function(m) mentions[#mentions+1]=m end}
local aud=dofile('mod/agent-harness_0.1.0/audience.lua'){state=function() return s end,post_viewer=function(n,t) return chat.viewer(n,t) end}

-- A confession is stored for the audience: nothing in chat, no message for the hint filer, nothing printed.
local r=aud.handlers.confess(astra,{text='  honestly grok\'s belts scare me\n'})
eq(r.seq,1); eq(r.note,'viewers hear this; teammates do not')
eq(s.audience.confessions[1].text,"honestly grok's belts scare me")
eq(s.chat,nil); eq(#mentions,0); eq(#printed,0)
fails(function() aud.handlers.confess(grok,{text='  '}) end,'text is required')
fails(function() aud.handlers.confess(grok,{}) end,'text must be a string')
-- One every 15 s per agent; others are not held up.
fails(function() aud.handlers.confess(astra,{text='again'}) end,'one confession every 15 s; next in 15 s')
game.tick=600+5*60; aud.handlers.confess(grok,{text='I think we need more power'})
game.tick=600+15*60; aud.handlers.confess(astra,{text=string.rep('x',400)})
eq(#s.audience.confessions[3].text,300)
-- An agent reads only its own; the operator reads everyone's with names, since and limit.
r=aud.handlers.confessions(grok,{}); eq(#r.confessions,1); eq(r.confessions[1].text,'I think we need more power'); eq(r.confessions[1].from,nil); eq(r.cursor,3)
r=aud.operator.confessions({}); eq(#r.confessions,3); eq(r.confessions[2].from,'grok')
r=aud.operator.confessions({since=1}); eq(#r.confessions,2); eq(r.confessions[1].seq,2)
r=aud.operator.confessions({limit=1}); eq(#r.confessions,1); eq(r.confessions[1].seq,3)
fails(function() aud.operator.confessions({limit=0}) end,'limit must be 1..100')
-- The log is bounded.
for i=1,210 do game.tick=game.tick+15*60; aud.handlers.confess(astra,{text='c'..i}) end
eq(#s.audience.confessions,200); eq(s.audience.confessions[200].text,'c210')

-- Viewer relay: posted to chat as "viewer NAME", flagged, unread for every agent, no mention filed.
game.tick=100000
r=aud.operator.viewer_say({name='Bob_42',text='@grok build more turrets!'})
eq(r.posted,true); eq(r.from,'viewer Bob_42')
eq(printed[#printed],'[color=0.62,0.62,0.62]viewer Bob_42:[/color] @grok build more turrets!')
eq(#mentions,0)
eq(chat.unread(1).latest,'viewer Bob_42: @grok build more turrets!'); eq(chat.unread(2).unread,1)
local m=chat.handlers.chat(grok,{}).messages[1]; eq(m.from,'viewer Bob_42'); eq(m.viewer,true); eq(m.text,'@grok build more turrets!')
-- Rich text cannot pass through the name or text; newlines are flattened.
r=aud.operator.viewer_say({name='[color=red]server[/color]',text='[img=item/iron-plate] hi\nthere'})
eq(r.from,'viewer color=redserver/color'); eq(r.text,'(img=item/iron-plate) hi there')
fails(function() aud.operator.viewer_say({name='  ',text='x'}) end,'name is required')
fails(function() aud.operator.viewer_say({name='a',text=''}) end,'text is required')
r=aud.operator.viewer_say({name=string.rep('n',40),text=string.rep('t',300)}); eq(#r.text,200); eq(r.from,'viewer '..string.rep('n',24))
-- One line per viewer every 20 s (names compared case-blind); dropped lines are not errors.
r=aud.operator.viewer_say({name='bob_42',text='again'}); eq(r.posted,false); eq(r.dropped,'viewer_rate'); eq(r.retry_after_s,20)
-- At most 6 viewer lines a minute in all.
for i=1,3 do eq(aud.operator.viewer_say({name='v'..i,text='hi'}).posted,true) end
r=aud.operator.viewer_say({name='v9',text='hi'}); eq(r.posted,false); eq(r.dropped,'global_rate'); eq(r.retry_after_s,60)
game.tick=game.tick+20*60
r=aud.operator.viewer_say({name='bob_42',text='later'}); eq(r.dropped,'global_rate'); eq(r.retry_after_s,40)
game.tick=game.tick+40*60
eq(aud.operator.viewer_say({name='bob_42',text='later'}).posted,true)
-- The per-name table forgets names once their gap has passed.
local n=0; for _ in pairs(s.audience.viewers.by_name) do n=n+1 end; eq(n,1)
print('audience: ok')
