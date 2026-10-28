-- d28 batch308 FT (viewer Aurora site:5343, follow-through after a job ends while its project stays open): a step done,
-- or a job closed inside an open project, names what stays open and what answers it (the owner's to write); the
-- 10-minute check says when nothing is written on a project since its last step was done; a project is read in its
-- own area only, not its owner's claims. Nothing here decides for the owner.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end

-- 1: board_update replies
do
  local astra,luna={index=1,name='astra'},{index=2,name='luna'}
  game={tick=1000,players={astra,luna}}
  local st={}
  local B=dofile('mod/agent-harness_0.1.0/board.lua'){state=function() return st end,director=function() return false end,
    bots=function() return {} end,profile=function() return nil end}
  local function post(p,a) return B.handlers.board_post(p,a).item.id end
  local proj=post(astra,{kind='project',title='Use LDS productivity for quality copper steel and plastic',owner='astra',
    steps={'Restore the lower casting line','Reuse the bounded metal batch','Raise casting productivity to 300 percent'}})
  -- a step done, steps left: what stays open and the three answers
  local r=B.handlers.board_update(astra,{id=proj,done=2})
  has(r.follow_through,'a step of it is done; #'..proj..' Use LDS productivity for quality copper steel and plastic stays')
  has(r.follow_through,'(1 of 3 steps; next 1. Restore the lower casting line; owner astra)')
  has(r.follow_through,'the step taken next (a note, or board_focus), status blocked with what restarts it in the note, or status done or dropped to retire it')
  -- the same update holding it: no line
  r=B.handlers.board_update(astra,{id=proj,done=1,status='blocked',note='held until LDS 13 is researched'})
  eq(r.follow_through,nil,'a hold written with it')
  r=B.handlers.board_update(astra,{id=proj,status='doing'})
  eq(r.follow_through,nil,'no step done in this update')
  -- a job inside it closed by another agent: the project and its owner named
  local job=post(luna,{kind='task',title='Loom legendary coal pilot',owner='luna'})
  B.handlers.board_update(luna,{id=job,parent=proj})
  r=B.handlers.board_update(luna,{id=job,status='done',note='pilot complete'})
  has(r.follow_through,'#'..job..' is done; #'..proj..' Use LDS')
  has(r.follow_through,'stays doing (2 of 3 steps; next 3. Raise casting productivity to 300 percent; owner astra): its owner writes what comes next')
  -- a closed job whose project is blocked or done: nothing to answer
  local job2=post(luna,{kind='task',title='Second pilot',owner='luna'})
  B.handlers.board_update(luna,{id=job2,parent=proj})
  B.handlers.board_update(astra,{id=proj,status='blocked',note='held'})
  eq(B.handlers.board_update(luna,{id=job2,status='dropped'}).follow_through,nil,'its project holds')
  -- the last step done, the project still doing
  B.handlers.board_update(astra,{id=proj,status='doing'})
  r=B.handlers.board_update(astra,{id=proj,done=3})
  has(r.follow_through,'stays doing (3 of 3 steps; every step done; owner astra)')
  -- a task with no parent: nothing
  local t=post(astra,{kind='task',title='Loose task',owner='astra'})
  eq(B.handlers.board_update(astra,{id=t,status='done'}).follow_through,nil)
  game=nil
  print('d28_batch308 close reply: ok')
end

-- 2: the 10-minute check: a project unchanged since its last step was done, an hour on: said, with what answers it;
-- a note written after it, or a hold: not said
do
  game={tick=0,get_surface=function() return {count_entities_filtered=function() return 7 end} end}
  _G.prototypes={item={}}
  local st={}
  local claim_n=0
  local items={
    [2516]={id=2516,kind='project',title='Use LDS productivity',status='doing',owner='astra',notes={},created_tick=0,updated_tick=100,
      steps={{n=1,text='a',done_by='astra',done_tick=50},{n=2,text='b',done_by='astra',done_tick=100},{n=3,text='Raise casting productivity'}}},
    [1099]={id=1099,kind='claim',title='Aquilo freight receiving',status='doing',owner='astra',area={left_top={x=-24,y=-36},right_bottom={x=24,y=36}}},
    [2518]={id=2518,kind='project',title='Bounded PU quality loop',status='claimed',owner='luna',notes={},created_tick=0,updated_tick=100,
      steps={{n=1,text='a',done_by='luna',done_tick=100},{n=2,text='Run a finite test'}}}}
  local P=dofile('mod/agent-harness_0.1.0/progress.lua'){state=function() return st end,items=function() return items end,
    owner_surface=function() return 'aquilo' end,total=function() return 0 end,since_request=function() return 600,1 end,
    claim_surface=function() return 'aquilo' end,force=function() return 'player' end,
    waiting=function() return nil end,who=function(p) return p.name end,QUIET=72000,PROJECT_QUIET=108000}
  P.tick(); P.tick()                      -- first checks
  game.tick=36000; P.tick(); P.tick()
  local l=P.lines({name='astra'},{})
  eq(l[#l]:find('nothing written on it',1,true),nil,'under an hour: not said')
  -- a project with no area is not read in its owner's claim: the claim's entities are not its progress
  eq(l[#l]:find('claim #1099',1,true),nil,l[#l]); has(l[#l],'unchanged since the last check')
  game.tick=216200; P.tick(); P.tick()
  l=P.lines({name='astra'},{})
  has(l[#l],'stalled: unchanged across 2 checks')
  has(l[#l],'nothing written on it since step 2 was done 1h00m ago: board_update {id: 2516, note} with the step taken next, status blocked with what restarts it in the note, or status done or dropped to retire it')
  -- luna wrote a note after her step: not said
  items[2518].updated_tick=5000
  game.tick=252200; P.tick(); P.tick()
  l=P.lines({name='luna'},{})
  eq(l[#l]:find('nothing written on it',1,true),nil,l[#l])
  -- held: not said
  items[2516].status='blocked'
  game.tick=288200; P.tick(); P.tick()
  l=P.lines({name='astra'},{})
  eq(l[#l]:find('nothing written on it',1,true),nil,l[#l])
  -- a task with no area is still read in its owner's claims
  items[7]={id=7,kind='task',title='Receive freight',status='doing',owner='astra',notes={},created_tick=0,updated_tick=0}
  game.tick=324200; P.tick(); P.tick(); P.tick()
  eq(st.progress.items[7].ev.where,'claim #1099')
  game=nil; prototypes=nil
  print('d28_batch308 progress check: ok')
end
