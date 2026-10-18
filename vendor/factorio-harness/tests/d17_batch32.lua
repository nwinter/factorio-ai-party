-- d17 batch32. Run from the harness root: lua tests/d17_batch32.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,msg) assert(a==b,(msg or '')..' '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end

-- A1 (Grok: 241 agricultural science packs went to rocket_silo_trash): what aboard no platform above asks for.
do
  game={tick=1000}
  defines={inventory={hub_main=1,rocket_silo_rocket=14,rocket_silo_trash=15}}
  prototypes={item={['agricultural-science-pack']={weight=1000,stack_size=200},['bioflux']={weight=1000,stack_size=100}},utility_constants={rocket_lift_weight=1000000}}
  local S=dofile('mod/agent-harness_0.1.0/silo.lua'){state=function() return {} end}
  local aboard={{name='agricultural-science-pack',count=241,quality='normal'}}
  local rocket={get_contents=function() return aboard end}
  local e={surface={name='gleba',planet={name='gleba'}},position={x=0,y=0},get_inventory=function(i) return i==14 and rocket or nil end}
  local asks={}
  local main={count_empty_stacks=function() return 20 end}
  local hub={valid=true,get_inventory=function() return main end,get_item_count=function() return 0 end,get_logistic_sections=function() return {sections_count=1,get_section=function() return {active=true,filters=asks} end} end}
  local force={platforms={{valid=true,name='Swift',space_location={name='gleba'},hub=hub}},logistic_networks={}}
  local r=S.trash_risk(e,force)
  eq(r.lost,'agricultural-science-pack*241'); eq(r.lost_count,241); eq(r.asked,nil)
  eq(r.line,'the rocket holds agricultural-science-pack*241 that no platform stopped above asks this planet for: with automatic requests on the game moves it into the silo\'s trash slots, which never launch')
  -- a platform above asks for it: nothing lost
  asks[1]={value={name='agricultural-science-pack'},min=500,import_from='gleba'}
  r=S.trash_risk(e,force)
  eq(r.lost,nil); eq(r.asked,'agricultural-science-pack*241'); has(r.line,'that a platform above asks for')
  aboard={{name='bioflux',count=40},{name='agricultural-science-pack',count=10}}
  r=S.trash_risk(e,force)
  eq(r.lost,'bioflux*40'); eq(r.asked,'agricultural-science-pack*10')
  aboard={}
  eq(S.trash_risk(e,force),nil)
  game,defines,prototypes=nil,nil,nil
end
print('d17_batch32 A1 silo trash risk: ok')
