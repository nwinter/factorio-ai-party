-- d16 batch8 (operator 18:30, agents' requests at the 16:50 and 18:20 polls). Run from the harness root: lua tests/d16_batch8.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,msg) assert(a==b,(msg or '')..' '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end

-- A5 (Opus 2x: a queue that paused itself after a craft step): queue_status says why it paused.
do
  game={tick=0}
  local st={}
  local players={[1]={index=1}}
  local S=dofile('mod/agent-harness_0.1.0/scheduler.lua'){state=function() return st end,player=function(i) return players[i] end,
    handlers={craft=function() error('not crafted: 8 gun-turret held by our factory',0) end,walk=function() return {} end},
    busy=function() return false end,stop=function() end,stop_index=function() end,validate_condition=function() end}
  local function run(n) for _=1,n do game.tick=game.tick+1; S.tick() end end
  S.handlers.queue_submit(players[1],{steps={{action='craft',args={recipe='gun-turret',count=8}},{action='walk',args={direction='north',ticks=3}}}})
  run(3)
  local q=S.handlers.queue_status(players[1],{})
  eq(q.paused,true)
  has(q.paused_why,'craft failed: not crafted: 8 gun-turret held by our factory (on_fail abort pauses the plan; on_fail skip goes on)')
  has(q.paused_why,'queue_resume runs the rest')
  S.pause(1,'stop')
  has(S.handlers.queue_status(players[1],{}).paused_why,'stop (tick')
end
print('d16_batch8 A5 why the queue paused: ok')

-- B1 (Sonnet 18:20: three times a launch hit the 1000 kg lift): a list split into rockets by weight and stacks.
do
  game={tick=0}
  prototypes={item={['space-platform-foundation']={weight=20000,stack_size=50},['firearm-magazine']={weight=10000,stack_size=200},lab={weight=1000000,stack_size=10}}}
  local R=dofile('mod/agent-harness_0.1.0/rocketload.lua'){}
  eq(R.split({{name='firearm-magazine',quality='normal',count=100}},1000000,20),nil,'one rocket: no split')
  local parts,total=R.split({{name='space-platform-foundation',quality='normal',count=120},{name='firearm-magazine',quality='normal',count=40}},1000000,20)
  eq(total,2800); eq(#parts,3)
  eq(parts[1][1].count,50); eq(parts[2][1].count,50); eq(parts[3][1].count,20); eq(parts[3][2].name,'firearm-magazine'); eq(parts[3][2].count,40)
  prototypes.item.lab.weight=2000000
  fails(function() R.split({{name='lab',quality='normal',count=1}},1000000,20) end,'one lab (2000 kg) does not fit under a rocket\'s lift (1000 kg)')
  prototypes=nil
end
print('d16_batch8 B1 load_silo split over rockets: ok')

-- B2 (Grok 6x: Swift's schedule read a 3600 s stop while Sol's queue sent it on once cargo landed): what else sends a
-- platform on, beside its schedule.
do
  game={tick=0}
  local st={queues={[7]={pending={{action='wait_until',args={['until']='item_count',item='agricultural-science-pack',at_least=1,platform='Swift'}},
    {action='platform_schedule',args={platform='Swift',stops={{station='gleba'},{station='nauvis'}}}}}}},
    orders={[3]={list={{name='swift-out',when={['until']='platform_arrived',platform='Swift',location='gleba'},steps={{action='platform_schedule',args={platform='Swift',stops={{station='nauvis'}}}}}}}}}}
  local D=dofile('mod/agent-harness_0.1.0/departure.lua'){state=function() return st end,name_of=function(i) return i==7 and 'sol' or 'astra' end}
  local l=D.lines('Swift')
  eq(#l,2)
  eq(l[1],'astra\'s standing order swift-out: when platform_arrived platform Swift location gleba, platform_schedule Swift (nauvis)')
  eq(l[2],'sol\'s queue: wait_until item_count item agricultural-science-pack platform Swift at_least 1 then platform_schedule Swift (gleba -> nauvis)')
  eq(D.lines('Wren'),nil)
end
print('d16_batch8 B2 what sends a platform on: ok')

-- B3 (Astra 18:20: projections mixed powered flight with drifting and stops): ammunition by phase.
do
  game={tick=0}
  defines={}
  prototypes={item={rocket={type='ammo'}}}
  local st={}
  local F=dofile('mod/agent-harness_0.1.0/freight.lua'){state=function() return st end}
  local used,made=0,0
  local pl={index=4,paused=false,speed=1,force={get_item_production_statistics=function() return {get_input_count=function() return made end,get_output_count=function() return used end} end}}
  local rec={}
  local function second(w,du,dm) used=used+du; made=made+dm; F.phase_step(rec,pl,w) end
  second({leg={from='a',to='b'}},0,0)
  for _=1,60 do second({leg={from='a',to='b'}},2,0) end           -- moving: 120/min
  pl.paused=true
  for _=1,60 do second({leg={from='a',to='b'}},1,0) end           -- still: 60/min
  for _=1,60 do second({stopped=true,at='b'},0,1) end             -- stopped: made 60/min
  eq(rec.phase.moving.s,60); eq(rec.phase.moving.by.rocket.used,120); eq(rec.phase.still.by.rocket.used,60); eq(rec.phase.stopped.by.rocket.made,60)
  st.freight_platforms=nil
  defines,prototypes=nil,nil
end
print('d16_batch8 B3 ammunition by flight phase: ok')

-- B4 (Astra 18:20: Kestrel needed three floor corrections): the floor every ghost needs: footprints, tunnels, holes, links.
do
  game={tick=0}
  prototypes={entity={['underground-belt']={max_underground_distance=5}}}
  local tiles={}
  for x=0,6 do for y=0,2 do if not (x==3 and y==1) then tiles[#tiles+1]={position={x=x,y=y}} end end end
  local function ghost(name,t,x,y,dir,io)
    return {valid=true,type='entity-ghost',ghost_name=name,ghost_type=t,position={x=x+.5,y=y+.5},direction=dir,belt_to_ghost=io,
      bounding_box={left_top={x=x+.1,y=y+.1},right_bottom={x=x+.9,y=y+.9}}}
  end
  local gin=ghost('underground-belt','underground-belt',0,5,4); gin.belt_to_ground_type='input'
  local gout=ghost('underground-belt','underground-belt',4,5,4); gout.belt_to_ground_type='output'
  local far=ghost('inserter','inserter',10,1,0)
  local ghosts={gin,gout,far}
  local s={find_tiles_filtered=function() return tiles end,
    find_entities_filtered=function(f)
      if f.type=='entity-ghost' then return ghosts end
      return {}
    end}
  local PP=dofile('mod/agent-harness_0.1.0/platplan.lua'){}
  local list,why=PP.floor(s,{},{position={x=0.5,y=0.5}})
  eq(why.foot,3,'the two undergrounds and the inserter'); eq(why.tunnel,3,'(1..3,5) under the pair'); eq(why.hole,1,'(3,1) enclosed')
  assert(why.link>=1,'the far inserter and the tunnel row joined to the hub floor')
  local at={}
  for _,t in ipairs(list) do at[t.x..','..t.y]=t.kind end
  eq(at['3,1'],'hole'); eq(at['2,5'],'tunnel'); eq(at['10,1'],'foot')
  prototypes=nil
end
print('d16_batch8 B4 platform floor plan: ok')
