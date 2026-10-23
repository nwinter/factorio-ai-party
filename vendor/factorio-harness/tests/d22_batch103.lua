-- d22 batch103 BM1 (Astra #1920): requests on a section the game controls. 2.0.77: LuaLogisticSection.type manual 0,
-- circuit_controlled 1, transitional_request_controlled 2 (a silo's automatic requests), request_missing_materials_controlled
-- 3 (a hub's construction requests); a script's set_slot on a non-manual section raises "trying to change logistic
-- section that is not manual". Game objects are userdata fakes (a file handle with its own metatable).
-- Run from the harness root: lua tests/d22_batch103.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)); return tostring(err) end
local function ud(fields) local u=io.tmpfile(); debug.setmetatable(u,{__index=fields,__newindex=fields}); return u end
game={tick=1000}
defines={space_platform_state={paused=7,waiting_at_station=6,on_the_path=2,no_schedule=4},rocket_silo_status={},inventory={hub_main=1,hub_trash=2},cargo_destination={},
  wire_connector_id={circuit_red=1,circuit_green=2},logistic_section_type={manual=0,circuit_controlled=1,transitional_request_controlled=2,request_missing_materials_controlled=3}}
prototypes={item={calcite={},['iron-plate']={}},space_location={nauvis={},fulgora={}},quality={normal={}},fluid={}}
local function section(index,manual,stype)
  local slots={}
  local f={index=index,is_manual=manual,type=stype,group='',active=true,filters_count=0,writes=0}
  f.get_slot=function(i) return slots[i] or {} end
  f.set_slot=function(i,v)
    if not f.is_manual then error('trying to change logistic section that is not manual') end
    slots[i]=v; f.filters_count=math.max(f.filters_count,i); f.writes=f.writes+1
  end
  f.clear_slot=function(i) if not f.is_manual then error('trying to change logistic section that is not manual') end slots[i]=nil end
  local s=ud(f)
  setmetatable(f,{__index=function(_,k) if k=='filters' then local o={} for i=1,f.filters_count do o[i]=slots[i] or {} end return o end end})
  return s,f
end
local s1,f1=section(1,false,3)       -- the hub's construction requests
local s2,f2=section(2,true,0)
local list={s1,s2}
local secs=ud{get_section=function(i) return list[i] end,add_section=function() local s,f=section(#list+1,true,0); list[#list+1]=s; return s end}
setmetatable(debug.getmetatable(secs).__index,{__index=function(_,k) if k=='sections_count' then return #list end end})
local main=ud{get_item_count=function() return 0 end,get_contents=function() return {} end}
local hub=ud{valid=true,unit_number=78,type='space-platform-hub',name='space-platform-hub',position={x=0,y=0},get_logistic_sections=function() return secs end,
  get_inventory=function() return main end,get_item_count=function() return 0 end,get_circuit_network=function() return nil end}
local pl=ud{valid=true,name='Kestrel II',index=4,state=6,space_location=ud{name='nauvis'},force='player',paused=false,hub=hub}
local p={index=12,name='astra',force=ud{platforms={pl}}}
local st={}
local space=dofile('mod/agent-harness_0.1.0/space.lua'){state=function() return st end,
  integer=function(v,d,lo,hi,name) v=v==nil and d or v; assert(type(v)=='number' and v>=lo and v<=hi,(name or 'value')..' out of range'); return v end,
  keep=function() return {set_construction=function(_,on) return on end,construction=function() return nil end} end,
  circuit_condition=function(c) return c end,
  freight={where=function() return {stopped=true,at='nauvis'} end,pads=function() return {},{} end,leg=function() return nil end}}

-- Astra's call: section 1, the hub's construction requests
local set={{item='calcite',min=300,max=400,from='nauvis',min_payload=100}}
local err=fails(function() space.requests(p,{platform='Kestrel II',section=1,set=set}) end,
  'section 1 is controlled by the game: the hub\'s construction requests (Request missing construction materials): the game writes what the platform\'s ghosts need')
has(err,'the game refuses a script\'s write to it and writes its own requests there, so a manual request there does not last')
has(err,'a new manual section keeps these requests: requests {')
has(err,'"add_section":true'); has(err,'"platform":"Kestrel II"'); has(err,'"item":"calcite"')
assert(not err:find('"section"',1,true),'the call it names has no section: '..err)
eq(f1.writes,0,'nothing written to section 1')
-- a clear there, and its removal, the same
fails(function() space.requests(p,{platform='Kestrel II',section=1,clear={'calcite'}}) end,'section 1 is controlled by the game')
has(fails(function() space.requests(p,{platform='Kestrel II',remove_section=1}) end,'section 1 is controlled by the game'),'only the game removes it')
-- the read: every row says controlled, and what controls it
local r=space.requests(p,{platform='Kestrel II'})
eq(r.sections[1].controlled,true); has(r.sections[1].controlled_by,'construction requests')
eq(r.sections[2].controlled,false); eq(r.sections[2].controlled_by,nil)
-- the kinds: a silo's automatic requests and a circuit-set section
f1.type=2; has(fails(function() space.requests(p,{platform='Kestrel II',section=1,set=set}) end,'controlled by the game'),'the silo\'s automatic requests')
f1.type=1; has(fails(function() space.requests(p,{platform='Kestrel II',section=1,set=set}) end,'controlled by the game'),'the circuit network (Set requests)')
f1.type=3
print('d22_batch103 BM1 controlled sections: ok')
