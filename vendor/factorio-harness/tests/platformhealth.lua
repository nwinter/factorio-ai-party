package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b) assert(a==b,tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
local function fails(fn,x) local ok,err=pcall(fn); assert(not ok,'expected refusal'); has(err,x) end
game={tick=1000}; prototypes={}; defines={}
local state={active={}}
local force={name='player',index=1}
local pl={valid=true,name='Asterion',index=7,force=force}; force.platforms={pl}
local list,finds={},0
local surface={name='platform-7',index=8,platform=pl}; pl.surface=surface
surface.find_entities_filtered=function(f)
 finds=finds+1; eq(f.force,force); local out={}
 for _,e in ipairs(list) do
  if e.valid and (not f.position or math.abs(e.position.x-f.position.x)<1 and math.abs(e.position.y-f.position.y)<1) then out[#out+1]=e end
 end
 return out
end
local function ent(u,h,m,x)
 local e={valid=true,unit_number=u,name='gun-turret',type='ammo-turret',health=h,max_health=m,position={x=x,y=0},force=force,surface=surface}
 list[#list+1]=e; return e
end
local a,b=ent(1,49.125,100,0),ent(2,120,400,10)
local function pos(v) assert(type(v)=='table' and type(v.x or v[1])=='number' and type(v.y or v[2])=='number','position requires x,y'); return {x=v.x or v[1],y=v.y or v[2]} end
local A=require('platalerts'){state=function() return state end}
local H=require('platformhealth'){position=pos,damaged=A.damaged,seed=A.seed_damaged,forget=A.forget_damaged}
local C=require('conditions'){position=pos,platform_health=H.check}
local p=setmetatable({index=1,force=force},{__index=function() error('body accessed') end})
local function c(fields) local out={['until']='damaged',platform='Asterion',fraction=.5}; for k,v in pairs(fields or {}) do out[k]=v end; return out end
local when=c(); C.validate(when); local met,saw=C.check(p,when)
eq(met,true); eq(finds,1); has(saw,'49.125/100'); has(saw,'read_tick 1000')
local ev=when.evidence.platform_health; eq(ev.read_tick,1000); eq(ev.count,2); eq(ev.entities[1].unit_number,2)
eq(ev.entities[2].health,49.125); eq(ev.entities[1].max_health,400); eq(ev.entities[1].position.x,10)
a.health=50; b.health=200; game.tick=1010; eq(C.check(p,when),false); eq(finds,1); eq(ev.entities[2].health,49.125)
eq(when.evidence.platform_health.read_tick,1010)
a.health=40; b.health=120
local area=c{area={{-1,-1},{1,1}}}; C.validate(area); eq(C.check(p,area),true); eq(area.evidence.platform_health.count,1)
area.area={{1,-1},{10,1}}; eq(C.check(p,area),false)
local points=c{positions={{.75,0},{0,0}}}; C.validate(points); eq(C.check(p,points),true); eq(points.evidence.platform_health.count,1)
points.positions={{100,100}}; fails(function() C.check(p,points) end,'no entity of ours with health'); eq(points.evidence,nil)
local hp={['until']='damaged',platform='Asterion',hp=40}; C.validate(hp); eq(C.check(p,hp),false)
a.health=39.5; eq(C.check(p,hp),true); hp.fraction=.1; eq(C.check(p,hp),true)
-- Repair removes an entity; another impact re-adds it. Death is not current damage.
a.health=100; b.health=400; eq(C.check(p,when),false); eq(next(A.damaged(pl).set),nil)
a.health=49; A.on_damaged{entity=a,force=force,tick=game.tick,final_damage_amount=51}; eq(C.check(p,when),true)
a.valid=false; eq(C.check(p,when),false); a.valid=true
-- Health reads leave cumulative impact history alone.
a.health=49; A.on_damaged{entity=a,force={name='enemy'},tick=game.tick,final_damage_amount=51}
local hits=A.hit_ring(pl); local count=#hits; a.health=100; eq(C.check(p,when),false); eq(#A.hit_ring(pl),count)
for _,bad in ipairs({{position={0,0}},{radius=4},{positions={}},{positions={{0,0}},area={{0,0},{1,1}}},
 {area={{0,0},{0,2}}},{area={{0,0},{2048,2}}},{fraction=0},{hp=0},{hp=0/0},{platform=''}}) do eq(pcall(C.validate,c(bad)),false) end
fails(function() C.validate(c{positions={{0,0}},area={{0,0},{1,1}}}) end,'positions or area, not both')
fails(function() C.validate(c{position={0,0}}) end,'whole hull, positions or area')
-- Overflow is explicit; duplicate seeds count once; >512 damaged are retained.
A.DAMAGED_MAX=1; A.seed_damaged(pl,{a,a,b}); eq(A.damaged(pl).seeded,false); A.DAMAGED_MAX=32768
local many={}; for i=1,513 do many[i]=ent(100+i,10,100,20+i) end
A.seed_damaged(pl,many); eq(A.damaged(pl).seeded,true); eq(C.check(p,when),true); eq(when.evidence.platform_health.count,513); eq(#when.evidence.platform_health.entities,10)
for _,e in ipairs(many) do e.valid=false end
A.seed_damaged(pl,{a,b}); a.health=100; b.health=400
pl.valid=false; fails(function() C.check(p,when) end,'no platform of ours'); eq(when.evidence,nil); pl.valid=true
-- Real scheduler and lanes, standalone and composite guards, exact evidence.
setmetatable(p,nil)
local cleanups=0
local W=require('waiteta'){check=function(player,cond,record) return C.check(player,cond,true,record) end}
local base={state=function() return state end,player=function() return p end,
 handlers={circuit_set=function() cleanups=cleanups+1; return {} end},
 busy=function() return false end,stop=function() end,stop_index=function() end,claim=function() end,direct_action=function() end,
 wait_check=function(player,cond,record) return W.check(player,cond,record) end,
 condition=function(player,cond) return C.check(player,cond) end,validate_condition=function(cond,player) return C.validate(cond,player) end,
 wait_info=function(out,record) return W.info(out,record) end,outcome=function() return 'done' end,deadline=C.deadline}
local make=require('scheduler'); local body={}; for k,v in pairs(base) do body[k]=v end
local lanes=require('queue_lanes'){scheduler=make(body),factory=make,base=base,is_read=function() return false end}
local h=lanes.handlers
local function tick(n) for _=1,n do game.tick=game.tick+1; lanes.tick() end end
for _,lane in ipairs({'body','remote','platform:Asterion'}) do
 for _,composite in ipairs({false,'all','any'}) do
  a.health=100; cleanups=0
  local guard=c()
  if composite then guard={['until']=composite,conditions={guard,{['until']='tick_at_least',tick=composite=='all' and game.tick or game.tick+1000}}} end
  h.queue_submit(p,{lane=lane,mode='replace',steps={{action='wait_ticks',args={ticks=1000}}},guards={{when=guard,steps={{action='circuit_set',args={platform='Asterion'}}}}}})
  tick(20); eq(cleanups,0); a.health=40; A.on_damaged{entity=a,force=force,tick=game.tick}; tick(20); eq(cleanups,1); tick(20); eq(cleanups,1)
  local st=h.queue_status(p,{lane=lane,history='all'}); local fired
  for _,row in ipairs(st.history) do if row.action=='guard' then fired=row end end
  eq(fired.result.evidence.platform_health.entities[1].health,40); h.queue_cancel(p,{lane=lane})
 end
 a.health=100; cleanups=0
 h.queue_submit(p,{lane=lane,mode='replace',steps={{action='wait_until',args=c()}, {action='circuit_set',args={platform='Asterion'}}}})
 tick(20); eq(cleanups,0); a.health=40; A.on_damaged{entity=a,force=force,tick=game.tick}; tick(20); eq(cleanups,1)
 local st=h.queue_status(p,{lane=lane,history='all'}); local done
 for _,row in ipairs(st.history) do if row.action=='wait_until' then done=row end end
 has(done.result.saw,'health 40/100'); eq(done.result.evidence.platform_health.entities[1].health,40); h.queue_cancel(p,{lane=lane})
end
has(make(body).schema.wait_until.damaged,'read_tick'); has(make(body).schema.wait_until.damaged,'no clean qualification')
print('platform live-health: exact fresh HP, repaired recovery, scopes, overflow, lanes, waits, guards and description ok')
