-- Run from repository root: lua tests/space.lua
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
defines={space_platform_state={waiting_for_starter_pack=0,waiting_at_station=6,paused=7},
  rocket_silo_status={building_rocket=5,rocket_ready=9},inventory={hub_main=1,rocket_silo_rocket=2},
  cargo_destination={orbit=1,surface=4}}
prototypes={item={['iron-plate']={},coal={},['space-platform-starter-pack']={}},space_location={nauvis={},vulcanus={}}}
-- A manual logistic section with slots like the engine's (gaps allowed).
local function section(manual,group)
  local slots={}
  local sec={index=1,is_manual=manual,group=group or '',active=true}
  sec.filters_count=0
  local function recount() local n=0; for i in pairs(slots) do n=math.max(n,i) end; sec.filters_count=n end
  sec.get_slot=function(i) return slots[i] or {} end
  sec.set_slot=function(i,f) slots[i]=f; recount() end
  sec.clear_slot=function(i) slots[i]=nil; recount() end
  setmetatable(sec,{__index=function(_,k) if k=='filters' then local out={}; for i=1,sec.filters_count do out[i]=slots[i] or {} end; return out end end,
    __newindex=function(t,k,v) if k=='filters' then slots={}; recount() else rawset(t,k,v) end end})
  return sec
end
local function sections(list)
  return setmetatable({get_section=function(i) return list[i] end,
    add_section=function() local s=section(true); s.index=#list+1; list[#list+1]=s; return s end},
    {__index=function(_,k) if k=='sections_count' then return #list end end})
end
local char_sections=sections({})
local hub_sections=sections({section(false),section(true)})
hub_sections.get_section(2).index=2
local hub_inv={get_contents=function() return {{name='iron-plate',count=5}} end}
local platform={valid=true,name='alpha',index=1,state=7,paused=true,space_location={name='nauvis'},weight=60000,
  surface={name='platform-1'},hub={valid=true,position={x=0,y=0},get_logistic_sections=function() return hub_sections end,
    get_inventory=function() return hub_inv end},can_leave_current_location=function() return true end}
local silo_cargo={get_contents=function() return {} end}
local launched
local silo={valid=true,type='rocket-silo',position={x=20.5,y=20.5},rocket_silo_status=5,rocket_parts=10,prototype={rocket_parts_required=50},
  get_inventory=function() return silo_cargo end,launch_rocket=function(d) launched=d; return true end}
local p={index=1,force={platforms={platform},recipes={}},character={get_logistic_sections=function() return char_sections end},
  surface={planet={name='nauvis'},find_entities_filtered=function() return {silo} end}}
local space=dofile('mod/agent-harness_0.1.0/space.lua'){
  position=function(v) return v end,
  integer=function(v,d,lo,hi,name) v=v==nil and d or v; assert(type(v)=='number' and v>=lo and v<=hi,name..' out of range'); return v end,
  remote_entity=function(_,a) assert(a.position.x==20.5,'no entity of ours at that position'); return silo end,
  real=function(q) return q end,stop=function(q) q.stopped=(q.stopped or 0)+1 end}
-- Character requests: a manual section is created, slots are reused per item.
local r=space.requests(p,{set={{item='iron-plate',min=100},{item='coal',min=5,max=10}}})
eq(r.target,'character'); eq(r.sections[1].requests[1],'iron-plate 100..inf'); eq(r.sections[1].requests[2],'coal 5..10')
r=space.requests(p,{set={{item='iron-plate',min=50,max=50}}})
eq(#r.sections[1].requests,2); eq(r.sections[1].requests[1],'iron-plate=50')
r=space.requests(p,{clear={'iron-plate'}})
eq(#r.sections[1].requests,1); eq(r.sections[1].requests[1],'coal 5..10')
r=space.requests(p,{set={{item='iron-plate',min=1}}}) -- the freed slot is reused
eq(r.sections[1].requests[1],'iron-plate 1..inf')
eq(#space.requests(p,{clear_all=true}).sections[1].requests,0)
fails(function() space.requests(p,{set={{item='nope',min=1}}}) end,'unknown item: nope')
fails(function() space.requests(p,{set={{item='coal',min=5,max=2}}}) end,'max must be at least min')
-- Platform hub requests skip the game-controlled section and name the planet.
r=space.requests(p,{platform='alpha',set={{item='iron-plate',min=100,from='nauvis'}}})
eq(r.target,'platform alpha'); eq(r.sections[2].requests[1],'iron-plate 100..inf from nauvis'); eq(r.sections[1].controlled,true)
fails(function() space.requests(p,{platform='beta'}) end,'no platform named beta; platforms: alpha')
fails(function() space.requests(p,{section=1,platform='alpha',set={{item='coal',min=1}}}) end,'controlled by the game')
-- Platform view and schedule.
local view=space.platforms(p,{})
eq(view.platforms[1].state,'paused'); eq(view.platforms[1].at,'nauvis'); eq(view.platforms[1].hub_items,'iron-plate*5')
eq(view.platforms[1].requests[1],'iron-plate 100..inf from nauvis'); eq(view.silos[1].parts,'10/50'); eq(view.silos[1].status,'building_rocket')
local sch=space.platform_schedule(p,{platform='alpha',stops={{station='vulcanus',wait={{type='time',ticks=600}}},{station='nauvis',wait={{type='all_requests_satisfied'}}}},paused=false})
eq(sch.schedule,'>vulcanus (time 10s) | nauvis (all_requests_satisfied)'); eq(platform.paused,false)
eq(platform.schedule.records[1].wait_conditions[1].ticks,600)
fails(function() space.platform_schedule(p,{platform='alpha',stops={{station='moon'}}}) end,'station must be a planet')
-- Launch: only a ready rocket, to a platform in orbit here or explicitly to orbit.
fails(function() space.launch(p,{position={x=20.5,y=20.5},platform='alpha'}) end,'rocket is not ready: building_rocket')
silo.rocket_silo_status=9
fails(function() space.launch(p,{position={x=20.5,y=20.5}}) end,'orbit=true')
local l=space.launch(p,{position={x=20.5,y=20.5},platform='alpha'})
eq(l.to,'platform alpha'); eq(launched.type,4); eq(launched.surface,platform.surface); eq(l.cargo,'empty')
platform.space_location={name='vulcanus'}
fails(function() space.launch(p,{position={x=20.5,y=20.5},platform='alpha'}) end,'not in orbit of nauvis')
eq(space.launch(p,{position={x=20.5,y=20.5},auto_requests=true}).auto_requests,true)
-- Riding needs the silo in reach and a platform; the character goes along.
platform.space_location={name='nauvis'}
p.can_reach_entity=function() return false end
fails(function() space.launch(p,{position={x=20.5,y=20.5},platform='alpha',ride=true}) end,'within reach of the silo')
p.can_reach_entity=function() return true end
fails(function() space.launch(p,{position={x=20.5,y=20.5},ride=true}) end,'ride needs platform')
local rode=space.launch(p,{position={x=20.5,y=20.5},platform='alpha',ride=true})
assert(rode.riding); eq(p.stopped,1)
-- Landing: only from our platform stopped at a planet.
fails(function() space.land(p,{}) end,'not on a space platform')
p.surface.platform=platform; platform.force=p.force
platform.space_location={name='nauvis',type='planet'}
p.land_on_planet=function() return true end
eq(space.land(p,{}).landing,'nauvis'); eq(p.stopped,2)
platform.space_location=nil; platform.space_connection={from={name='nauvis'},to={name='vulcanus'}}; platform.distance=0.25
fails(function() space.land(p,{}) end,'not stopped at a planet (at nauvis->vulcanus 25%)')
p.surface.platform=nil
-- Creating a platform goes through the force like the platform GUI.
p.force.create_space_platform=function(args) return {name=args.name,state=0,planet=args.planet} end
local made=space.platform_create(p,{name='beta'})
eq(made.state,'waiting_for_starter_pack'); eq(made.planet,'nauvis')
p.force.recipes['space-platform-starter-pack']={enabled=false}
fails(function() space.platform_create(p,{}) end,'not unlocked yet')
print('space: ok')
