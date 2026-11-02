package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b) assert(a==b,tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
local function fails(fn,x) local ok,err=pcall(fn); assert(not ok); if x then has(err,x) end end
game={tick=1000}; defines={inventory={hub_main=1,chest=2}}; prototypes={}
local size,free,bar=1435,16,1436
local inv=setmetatable({valid=true,supports_bar=function() return true end,get_bar=function() return bar end,
 count_empty_stacks=function(filtered,barred) eq(filtered,true); eq(barred,false); return free end},{__len=function() return size end})
local hub={valid=true,get_inventory=function(id) eq(id,1); return inv end}
local pl={valid=true,name='Asterion',hub=hub}
local force={platforms={pl},is_chunk_charted=function() return true end}
local nobody=setmetatable({force=force},{__index=function() error('body accessed') end})
local C=require('conditions'){position=function(v) return {x=v.x or v[1],y=v.y or v[2]} end}
local function cond(fields) local c={['until']='inventory_free_slots',platform='Asterion',below=16}; for k,v in pairs(fields or {}) do c[k]=v end; return c end
local c=cond(); C.validate(c); eq(C.check(nobody,c),false)
eq(c.evidence.inventory_free_slots.free,16); eq(c.evidence.inventory_free_slots.occupied,1419)
eq(c.evidence.inventory_free_slots.total,1435); eq(c.evidence.inventory_free_slots.read_tick,1000)
eq(c.evidence.inventory_free_slots.inbound_reserved_slots,'unavailable')
free=15; game.tick=1010
local met,saw=C.check(nobody,c); eq(met,true); has(saw,'occupied 1420, free 15, total 1435'); has(saw,'read_tick 1010')
local old=c.evidence; free=17; C.check(nobody,c); eq(old.inventory_free_slots.free,15)
eq(C.check(nobody,{['until']='inventory_free_slots',platform='Asterion',at_least=17}),true)
eq(C.check(nobody,{['until']='inventory_free_slots',platform='Asterion',at_least=18}),false)
size=2000; bar=2001; free=582; C.check(nobody,c); eq(c.evidence.inventory_free_slots.total,2000)
hub.valid=false; fails(function() C.check(nobody,c) end,'has no hub'); eq(c.evidence,nil); hub.valid=true
pl.valid=false; fails(function() C.check(nobody,c) end,'no platform of ours'); pl.valid=true
inv.valid=false; fails(function() C.check(nobody,c) end,'has no inventory'); inv.valid=true
for _,fields in ipairs({{platform=''}, {platform=3}, {below=-1}, {below=1.5}, {at_least=0/0}, {at_least=16},
 {on_stale='met'}, {quality='rare'}, {position={0,0}}, {positions={{0,0}}}, {network={0,0}}, {item='rocket'}, {radius=1}}) do
 fails(function() C.validate(cond(fields)) end)
end
fails(function() C.validate{['until']='inventory_free_slots',platform='Asterion'} end)
fails(function() C.validate{['until']='inventory_free_slots',below=1} end)
C.validate{['until']='inventory_free_slots',platform='Asterion',below=0}
C.validate{['until']='inventory_free_slots',platform='Asterion',at_least=0,below=1}
local chest={valid=true,type='logistic-container',name='requester-chest',position={x=4.5,y=3.5},get_inventory=function(id) eq(id,2); return inv end}
local found={chest}; local charted=true
local surface={name='nauvis',find_entities_filtered=function(f)
 eq(f.limit,2); eq(f.force,force); eq(f.type[2],'logistic-container'); eq(f.area[1][1],4.49); return found
end}
game.get_surface=function(name) if name=='nauvis' then return surface end end
force.is_chunk_charted=function() return charted end
local p={index=1,force=force,surface={name='gleba'}}
c={['until']='inventory_free_slots',surface='nauvis',position={4.5,3.5},at_least=3}
C.validate(c); size=48; bar=9; free=3
met,saw=C.check(p,c); eq(met,true); has(saw,'occupied 5, free 3, total 8'); has(saw,'capacity 48, barred 40')
charted=false; fails(function() C.check(p,c) end,'not charted'); charted=true
found={}; fails(function() C.check(p,c) end,'found 0'); found={chest,chest}; fails(function() C.check(p,c) end,'found 2'); found={chest}
inv.supports_bar=function() return false end; inv.get_bar=function() error('bar unsupported') end
C.check(p,c); eq(c.evidence.inventory_free_slots.total,48)
-- Real scheduler and lane validation: once-only reactions, boundary waits, missing reads stay armed.
local state={active={}}; local cleanups=0
local W=require('waiteta'){}
local base={state=function() return state end,player=function() return p end,
 handlers={circuit_set=function() cleanups=cleanups+1; return {} end},
 busy=function() return false end,stop=function() end,stop_index=function() end,claim=function() end,direct_action=function() end,
 condition=function(player,c) return C.check(player,c) end,validate_condition=function(c) return C.validate(c) end,
 wait_info=function(out,record) return W.info(out,record) end,outcome=function() return 'done' end,deadline=C.deadline}
local make=require('scheduler'); local body={}; for k,v in pairs(base) do body[k]=v end
local lanes=require('queue_lanes'){scheduler=make(body),factory=make,base=base,is_read=function() return false end}
local h=lanes.handlers
local function tick(n) for _=1,n do game.tick=game.tick+1; lanes.tick() end end
for _,lane in ipairs({'body','remote','platform:Asterion'}) do
 for _,composite in ipairs({false,'all','any'}) do
  size=1435; free=16; cleanups=0; hub.valid=true
  local when=cond()
  if composite then when={['until']=composite,conditions={when,{['until']='tick_at_least',tick=composite=='all' and game.tick or game.tick+1000}}} end
  h.queue_submit(p,{lane=lane,mode='replace',steps={{action='wait_ticks',args={ticks=1000}}},
   guards={{when=when,steps={{action='circuit_set',args={platform='Asterion'}}}}}})
  tick(20); eq(cleanups,0); hub.valid=false; tick(20)
  local st=h.queue_status(p,{lane=lane,history='all'})
  eq(cleanups,0); eq(#st.guards,1); has(st.guards[1].saw,'has no hub')
  hub.valid=true; free=15; tick(20); eq(cleanups,1); tick(20); eq(cleanups,1)
  st=h.queue_status(p,{lane=lane,history='all'})
  local fired; for _,row in ipairs(st.history) do if row.action=='guard' then fired=row end end
  assert(fired); has(fired.result.saw,'free 15'); eq(fired.result.evidence.inventory_free_slots.free,15)
  h.queue_cancel(p,{lane=lane})
 end
 free=15; cleanups=0
 h.queue_submit(p,{lane=lane,mode='replace',steps={{action='wait_until',args={['until']='inventory_free_slots',platform='Asterion',at_least=16}},
  {action='circuit_set',args={platform='Asterion'}}}})
 tick(20); eq(cleanups,0); free=16; tick(20); eq(cleanups,1); h.queue_cancel(p,{lane=lane})
end
free=0; cleanups=0
h.queue_submit(p,{lane='remote',mode='replace',steps={{action='wait_until',args=c},{action='circuit_set',args={surface='nauvis'}}}})
tick(20); eq(cleanups,0); free=3; tick(20); eq(cleanups,1)
h.queue_submit(p,{lane='remote',mode='replace',steps={{action='wait_until',args=cond()}}})
hub.valid=false; tick(20)
local st=h.queue_status(p,{lane='remote',history='all'}); eq(st.paused,true)
print('inventory_free_slots: thresholds, capacity, scopes, validation, live reads, guards and waits on all lanes: ok')
