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

-- cp2 (Astra 18:00: idle report 93963 said "idle 11 min / no queue" while its remote capture plan 391 and
-- platform:Asterion UM plan 249 had just run 600 s and K2 plan 79 stayed active): the idle report counts every lane.
do
  game={tick=3600*600}
  local T=game.tick
  local s={active={},stand={[2]=T-11*3600},queues={[2]={paused=true,pending={},history={},revision=4}},
    remote_queues={[2]={paused=false,pending={},revision=9,plan={id=391,kind='submit',name='capture',tick=T-36000,steps=3},
      history={{action='wait_ticks',ok=true,finished_tick=T-1200,plan=391},{action='observe',ok=true,finished_tick=T-600,plan=391}}}},
    platform_lanes={Asterion=true,K2=true,Gone=true},
    ['lane_queues|Asterion']={[2]={paused=false,pending={},revision=3,plan={id=249,kind='submit',name='UM',tick=T-36000,steps=2},
      history={{action='wait_until',ok=true,finished_tick=T-900,plan=249}}}},
    ['lane_queues|K2']={[2]={paused=false,pending={{action='flight_watch'}},revision=7,plan={id=79,kind='repeat',name='K2 ammo',tick=T-72000,steps=2},
      loop={}, current={id='job-3',action='wait_ticks',label='settle',plan=79,until_tick=T+1800,started_tick=T-600},history={}}}}
  local I=dofile('mod/agent-harness_0.1.0/idle.lua'){state=function() return s end,
    agents=function() return {{index=2,name='astra'}} end,mention_counts=function() return {agents={}} end,
    unread=function() return {} end,has_body=function() return true end}
  local row=I.operator.idle_report({}).agents[1]
  eq(row.standing_s,660,'the character stood 11 min'); eq(row.queue.state,'paused','the body queue as before')
  eq(#row.lanes,4,'body, remote, platform:Asterion, platform:K2 (none for Gone)')
  eq(row.lanes[1].lane,'body'); eq(row.lanes[1].state,'paused')
  eq(row.lanes[2].lane,'remote'); eq(row.lanes[2].state,'empty'); eq(row.lanes[2].done,2); eq(row.lanes[2].plan.id,391)
  eq(row.lanes[3].lane,'platform:Asterion'); eq(row.lanes[3].done,1); eq(row.lanes[3].last_done_s,15)
  local k2=row.lanes[4]
  eq(k2.lane,'platform:K2'); eq(k2.state,'running'); eq(k2.plan.id,79); eq(k2.plan.name,'K2 ammo'); eq(k2.loop,true)
  eq(k2.step.action,'wait_ticks'); eq(k2.step.label,'settle'); eq(k2.step.left_s,30); eq(k2.steps,2)
  eq(#row.lanes_active,1); eq(row.lanes_active[1],'platform:K2')
  has(row.counted.text,"(other lanes' steps done: remote 2, platform:Asterion 1)")
  eq(row.counted.lane_steps[1],'remote 2')
  -- an agent with only a body queue: one lane, none active
  s.remote_queues, s.platform_lanes = {}, {}
  row=I.operator.idle_report({}).agents[1]
  eq(#row.lanes,1); eq(row.lanes_active,nil); lacks(row.counted.text,'other lanes')
end
print('d26_batch252 cp2 idle report lanes: ok')
