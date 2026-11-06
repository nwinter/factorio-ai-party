package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b) assert(a==b,tostring(a)..' ~= '..tostring(b)) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
local function position(p) assert(type(p)=='table' and type(p.x)=='number' and type(p.y)=='number','invalid position'); return p end
game={tick=0}
local proto={fast_replaceable_group='inserter',collision_box={left_top={x=-.4,y=-.4},right_bottom={x=.4,y=.4}}}
prototypes={quality={normal={},epic={}},entity={inserter=proto},item={},fluid={}}
local unlocked,visible=true,true
local entity
local surface={name='platform-1',valid=true}
surface.find_entities_filtered=function(f)
  eq(f.force.name,'ours'); eq(f.position.x,1)
  if not entity or f.name and entity.name~=f.name then return {} end
  return {entity}
end
local platform={name='Asterion',valid=true,surface=surface}
local force={name='ours',platforms={platform},is_quality_unlocked=function() return unlocked end}
local p={index=1,force=force,surface={name='nauvis'},position={x=0,y=0}}
game.get_surface=function(n) if n=='vulcanus' then return surface end end
local function actor(p,a)
  assert(not (a.platform and a.surface),'give platform or surface, not both')
  if a.platform then assert(a.platform=='Asterion','no platform of ours named '..a.platform) end
  if a.surface then assert(a.surface=='vulcanus','no surface named '..a.surface) end
  return {index=p.index,force=p.force,surface=surface}
end
local sight_calls=0
local function sight() sight_calls=sight_calls+1; assert(visible,'target not visible') end
local upgrade=require('upgrade'){position=position,read_sight=sight,real=function() return p end}
local cond=require('conditions'){position=position,entity_quality_sight=sight}
local function fresh(ghost)
  local e={valid=true,name=ghost and 'entity-ghost' or 'inserter',ghost_name='inserter',type=ghost and 'entity-ghost' or 'inserter',quality={name='normal'},position={x=1,y=2},wires={},settings={filter='iron-plate'}}
  e.order_upgrade=function(a)
    eq(a.force,force); eq(a.player,p)
    e.order=a.target
    if ghost then e.quality={name=a.target.quality}; e.ghost_name=a.target.name end
    return true
  end
  entity=e; return e
end
local handlers={upgrade=function(p,a) return upgrade.run(actor(p,a),a) end}
local s={}
-- Exercise the runtime's submission hook, including its call to the shared planner validator.
local f=assert(io.open('mod/agent-harness_0.1.0/runtime.lua')); local runtime=f:read('*a'); f:close()
local hook=assert(runtime:match('step_read_check=(function%(p,action,args,prior%).-\n  end),'))
local readcheck=assert(load('return '..hook,'submission-hook','t',{M={upgrade=upgrade,upgrade_player=actor,step_read_check=function() end}}))()
local base={state=function() return s end,player=function() return p end,handlers=handlers,
  busy=function() return false end,stop=function() end,stop_index=function() end,
  step_read_check=readcheck,condition=cond.check,validate_condition=cond.validate}
local make=require('scheduler')
local lanes=require('queue_lanes'){scheduler=make(base),factory=make,base=base,is_read=function() return false end}
local h=lanes.handlers
local function tick(n) for _=1,n or 1 do game.tick=game.tick+1; lanes.tick() end end
local function args(target) local a={position={x=1,y=2},quality='epic'}; a[target]='Asterion'; if target=='surface' then a.surface='vulcanus' end; return a end
for _,lane in ipairs{'remote','platform:Asterion'} do
  for _,target in ipairs{'platform','surface'} do
    for _,ghost in ipairs{false,true} do
      local a=args(target)
      local direct=fresh(ghost); local want=handlers.upgrade(p,a)
      local e=fresh(ghost); local wires,settings=e.wires,e.settings
      h.queue_submit(p,{lane=lane,steps={{action='upgrade',args=a}}})
      eq(e.order,nil) -- validation must never place the order
      tick()
      local status=h.queue_status(p,{lane=lane,history='all'})
      eq(status.paused,false); eq(status.active,false)
      eq(e.order.name,direct.order.name); eq(e.order.quality,direct.order.quality)
      eq(status.history[1].result.marked_for_upgrade,want.marked_for_upgrade)
      eq(status.history[1].result.ghosts_upgraded,want.ghosts_upgraded)
      eq(e.wires,wires); eq(e.settings,settings)
    end
  end
  fails(function() h.queue_submit(p,{lane=lane,steps={{action='upgrade',args={position={x=1,y=2},quality='epic'}}}}) end,'requires platform or surface')
end
local a=args('platform')
for _,case in ipairs{
  {set=function() unlocked=false end,reset=function() unlocked=true end,error='epic quality is not unlocked'},
  {set=function() visible=false end,reset=function() visible=true end,error='target not visible'},
  {set=function() a.quality='bogus' end,reset=function() a.quality='epic' end,error='quality must be a quality name'},
} do
  fresh(false); case.set()
  fails(function() handlers.upgrade(p,a) end,case.error)
  fails(function() h.queue_submit(p,{lane='platform:Asterion',steps={{action='upgrade',args=a}}}) end,case.error)
  eq(entity.order,nil); case.reset()
end
-- Checks run again when the step executes, not just at submission.
fresh(false)
h.queue_submit(p,{lane='platform:Asterion',steps={{action='upgrade',args=a}}})
unlocked=false; tick(); eq(h.queue_status(p,{lane='platform:Asterion'}).paused,true); eq(entity.order,nil); unlocked=true
h.queue_cancel(p,{lane='platform:Asterion'})
local c={['until']='entity_quality',platform='Asterion',position={x=1,y=2},name='inserter',quality='epic',timeout=100}
cond.validate(c,p)
fresh(false); eq(cond.check(p,c),false)
handlers.upgrade(p,a); eq(cond.check(p,c),false) -- marking is not completion
entity=nil; eq(cond.check(p,c),false)
fresh(true).quality.name='epic'; eq(cond.check(p,c),false)
local e=fresh(false)
h.queue_submit(p,{lane='platform:Asterion',steps={{action='upgrade',args=a},{action='wait_until',args=c}}})
tick(); eq(h.queue_status(p,{lane='platform:Asterion'}).active.action,'wait_until')
e.quality.name='epic'; eq(cond.check(p,c),true); tick(12)
eq(h.queue_status(p,{lane='platform:Asterion'}).active,false)
c.name='other'; eq(cond.check(p,c),false); c.name=nil; eq(cond.check(p,c),true)
c.platform=nil; c.surface='vulcanus'; cond.validate(c,p); eq(cond.check(p,c),true)
visible=false; fails(function() cond.check(p,c) end,'not visible'); visible=true
c.quality='any'; fails(function() cond.validate(c,p) end,'exact quality')
c.quality=nil; fails(function() cond.validate(c,p) end,'exact quality')
c.quality='epic'; c.position=nil; fails(function() cond.validate(c,p) end,'requires position')
assert(sight_calls>0)
print('queue upgrade and entity_quality: ok')
