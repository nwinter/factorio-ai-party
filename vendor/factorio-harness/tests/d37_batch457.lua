-- #2937: automatic first sources cover the whole manifest before any walk/load/pause.
local function eq(a,b) assert(a==b,tostring(a)..' ~= '..tostring(b)) end
local function has(s,t) assert(s and s:find(t,1,true),tostring(s)..' lacks '..t) end
defines={inventory={chest=1},rocket_silo_status={rocket_ready=7}}
game={tick=123993692}
prototypes={item={['solar-panel']={weight=20000,stack_size=50}},utility_constants={rocket_lift_weight=1000000}}
local force={}
local net={storages={},providers={},requesters={}}
local surface={name='aquilo',find_logistic_network_by_position=function() return net end}
local inventory={}
local p={force=force,surface=surface,get_main_inventory=function() return {get_item_count=function(id) return inventory[id.name] or 0 end} end}
local silo={force=force,surface=surface,position={x=0,y=0},use_transitional_requests=true}
local entities={}
local function chest(mode,x,y,stock)
  local c={valid=true,type='logistic-container',name=mode..'-chest',prototype={logistic_mode=mode},
    force=force,surface=surface,position={x=x,y=y},stock=stock}
  c.get_inventory=function() return {get_item_count=function(id) return id.quality=='normal' and (c.stock[id.name] or 0) or 0 end} end
  entities[#entities+1]=c
  return c
end
local R=dofile('mod/agent-harness_0.1.0/rocketload.lua'){
  sight_entity=function(_,pos)
    for _,c in ipairs(entities) do if c.position==pos then assert(not c.unseen,'outside visible chunks'); return c end end
    error('no chest')
  end}
local a=chest('storage',27.5,2.5,{['solar-panel']=3})
local b=chest('passive-provider',-12.5,-18.5,{['solar-panel']=2})
local c=chest('passive-provider',-12.5,-17.5,{['solar-panel']=1})
net.storages={a}; net.providers={b,c,a} -- duplicate lists count the chest once
net.select_pickup_point=function() return {owner=a} end -- always the same preferred chest
local function select(n) return R.first_sources(p,silo,{['solar-panel']=n},{'solar-panel'}) end
local from,lines,err=select(6)
eq(err,nil); eq(#from,3); eq(from[1].x,27.5); eq(#lines,3)
eq(a.stock['solar-panel'],3); eq(silo.use_transitional_requests,true)
-- The engine can return different LuaEntity wrappers for the same chest: table identity is not a key.
local wrapper={}; for k,v in pairs(a) do wrapper[k]=v end
net.storages={wrapper}
from,lines,err=select(7); eq(#from,3); has(err,'solar-panel 6 of 7 (1 short)')
net.storages={a}
local buffer=chest('buffer',5,0,{['solar-panel']=50})
local requester=chest('requester',6,0,{['solar-panel']=50})
net.providers={b,c,buffer}; net.requesters={buffer,requester}
from,lines,err=select(7)
has(err,'solar-panel 6 of 7 (1 short)'); has(err,'buffer-chest (5,0) holding 50 solar-panel: automatic first pickup excludes buffers')
has(err,'requester-chest (6,0) holding 50 solar-panel: not a storage or provider chest')
has(err,'nothing walked or loaded; automatic requests unchanged')
-- Active providers, inventory, multiple items, duplicate preferred points, normal quality only.
local d=chest('active-provider',8,0,{['solar-panel']=1,iron=4})
net.providers={b,c,d}; net.requesters={}
from,lines,err=R.first_sources(p,silo,{['solar-panel']=7,iron=4},{'solar-panel','iron'})
eq(err,nil); eq(#from,4)
inventory['solar-panel']=6
from,lines,err=select(6); eq(err,nil); eq(from,nil); eq(#lines,0)
inventory={}; d.unseen=true
from,lines,err=select(7); has(err,'outside visible chunks'); eq(#from,3)
d.unseen=nil; d.stock['solar-panel']=0
from,lines,err=select(7); has(err,'eligible chests have insufficient normal-quality stock')
-- No network cannot silently fall back to chests near the character.
surface.find_logistic_network_by_position=function() return nil end
from,lines,err=select(6); eq(from,nil); has(err,'no logistic network at the silo')
surface.find_logistic_network_by_position=function() return net end
-- More than the explicit from limit refuses with the omitted source and the limit.
net.storages={}; net.providers={}; net.select_pickup_point=function() end
for i=1,17 do net.providers[i]=chest('passive-provider',i,0,{['solar-panel']=1}) end
from,lines,err=select(17); eq(#from,16); has(err,'from limit 16 chests'); has(err,'solar-panel 16 of 17')
-- A snapshot reports only observable native conditions and does not infer an idle cause.
local S=dofile('mod/agent-harness_0.1.0/silo.lua'){state=function() return {} end,status_name=function() return 'waiting_to_launch_rocket' end}
silo.rocket_silo_status=7; silo.prototype={rocket_parts_required=50}; silo.send_to_orbit_automatically=true
local matched={platform='Asterion',flag='matched',network_can_give=6,min_payload=6,line='matched: Asterion solar-panel, min payload 6; network can give 6'}
S.request_rows=function(e,f,ln,platform) eq(platform,'Asterion'); return {matched},0 end
local status=S.first_status(silo,'Asterion')
eq(status.auto_requests,true); eq(status.send_to_orbit_automatically,true); eq(status.requesting_for,nil)
eq(status.read_tick,123993692); eq(status.platform_requests[1].flag,'matched')
has(status.line,'ready to launch, not launched'); has(status.line,'target none'); has(status.line,'min payload 6')
has(status.cause,'does not expose a reason'); eq(silo.use_transitional_requests,true)
print('d37 batch457 first sources and native status: ok')
