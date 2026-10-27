-- d26 batch252 IN (viewer Aurora site:4852: "Could idle checks separate unread notes from overdue work? Sonnet's
-- no-action tower FYI and Haiku's completed-transfer thanks appeared as unanswered"): the open line (open.lua, read by
-- the idle report and the nudges) lists tells that ask apart from notes that ask nothing; a note is listed while unread
-- and not once read or acknowledged; board items overdue for review are their own part. Run from the harness root:
-- lua tests/d26_batch252.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
local function lacks(s,x) assert(not tostring(s):find(x,1,true),tostring(s)..' has '..x) end

-- What asks: shift72's tells (sender journals, d24 22:01-01:35).
do
  game={tick=100000}
  local O=dofile('mod/agent-harness_0.1.0/open.lua'){state=function() return {} end}
  local notes={
    'Tower (11.5,6.5) is hot and idle by design: it only burns eggs as an outlet, so no_fuel there is fine. No action needed.',
    'Thanks. I closed #2283 step3 on current evidence: chest2397/48 slots, no output wait; requester13/10',
    'Thanks, audit accepted. Keeping1250 deferred; cover ownerSol with no newbuild.',
    'Verified current Meridian-V receipt: pod #387 bioflux10 landed pad(52,54) tick59586937. Reminder #71 acknowledged.',
    'Got it, thanks. Shipment confirms Weaver\'s native AG up request is delivered and 1000 is aboard for Nauvis',
    'I confirmed rocket33177 pod#1941 landed on Weaver; the answered request is closed',
  }
  local asks={
    'Gleba tower at (77.5,48.5) surfaced as out of fuel around tick59750454; previous observation had 1000C/no demand, so I have not fueled it. Please confirm if still intentional; no immediate change from me.',
    'how much LDS can you ship?',
    'Can you send me the recorder archive',
    'Let me know when the pad is clear',
    'I need your rolling recorder archive for Asterion',
    'PLEASE check the gate',
  }
  for _,t in ipairs(notes) do eq(O.asks(t),false,'a note: '..t) end
  for _,t in ipairs(asks) do eq(O.asks(t),true,'asks: '..t) end
end
print('d26_batch252 IN asks: ok')

-- The open line: luna's tells to sonnet; sonnet's unread box (index 3); an overdue review.
do
  game={tick=200000}
  local s={board={items={}},tells={log={
    {seq=10,tick=200000-20*3600,from='luna',to={'sonnet'},text='Please confirm if tower (77.5,48.5) is still intentional.'},
    {seq=11,tick=200000-10*3600,from='luna',to={'sonnet'},text='Thanks, logged it.'},
    {seq=12,tick=200000-9*3600,from='haiku',to={'sonnet'},text='Thanks. Transfer #2283 is complete; no action needed.'},
    {seq=13,tick=200000-8*3600,from='sol',to={'sonnet'},text='Tower (11.5,6.5) is idle by design. No action needed.'},
  }},mentions={[3]={list={},dropped=0,unread={{seq=12},{seq=13}}}}}
  local overdue={}
  local O=dofile('mod/agent-harness_0.1.0/open.lua'){state=function() return s end,claim_surface=function() return 'nauvis' end,
    claim_stale=function() return false end,overdue_reviews=function(name) eq(name,'sonnet'); return overdue end}
  local force={name='player'}
  local line=O.line('sonnet',force,nil,3)
  -- luna's later "Thanks" does not hide her earlier ask; luna's thanks was read (not in the unread box): not listed
  has(line,'1 request or tell to you unanswered (tell from luna 20m00s ago: Please confirm if tower (77.5,48.5)')
  has(line,'2 unread notes to you asking nothing (tell from sol 8m00s ago: Tower (11.5,6.5) is idle by design. No action needed.; '
    ..'tell from haiku 9m00s ago: Thanks. Transfer #2283 is complete; no action needed.)')
  lacks(line,'Thanks, logged it')
  -- acknowledged (chat_ack all empties the unread box): the notes go; the ask stays until sonnet tells luna
  s.mentions[3].unread=nil
  line=O.line('sonnet',force,nil,3)
  has(line,'1 request or tell to you unanswered (tell from luna')
  lacks(line,'asking nothing')
  s.tells.log[#s.tells.log+1]={seq=14,tick=200000-60,from='sonnet',to={'luna'},text='Yes, intentional.'}
  eq(O.line('sonnet',force,nil,3),'open for you: none (no board items of yours, no fresh claims, no unanswered requests or tells)')
  -- overdue work: listed after the asks, whatever was read
  overdue={{age=600,line='board #1301 Build patch-2 uranium outpost: next check at tick 199000, 10s ago (evidence by sonnet 1h00m ago)'},
    {age=7200,line='board #1290 Reactor review: next check at tick 192800, 2m00s ago (evidence by sonnet 2h00m ago)'}}
  line=O.line('sonnet',force,nil,3)
  eq(line,'open for you: 2 board items of yours overdue for review (board #1290 Reactor review: next check at tick 192800, 2m00s ago (evidence by sonnet 2h...; '
    ..'board #1301 Build patch-2 uranium outpost: next check at tick 199000, 10s ago (evidence...)')
  -- without an index (an older caller): every note counts as unread
  overdue={}
  s.tells.log[#s.tells.log+1]={seq=15,tick=200000-30*60,from='astra',to={'sonnet'},text='Thanks for the wall.'}
  has(O.line('sonnet',force),'3 unread notes to you asking nothing (tell from astra 30s ago: Thanks for the wall.; tell from sol 8m00s ago')
end
print('d26_batch252 IN open line: ok')
