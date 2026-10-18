-- The boilers read (fuelhours.lua) names a low boiler's feeding inserter and, for a belt it takes from, that belt line's
-- head and gaps (batch29 B1, Haiku about hourly: a shortage read apart from a broken link).
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function has(s,x) assert(type(s)=='string' and s:find(x,1,true),tostring(s)..' lacks '..x) end
game={tick=1000}
defines={inventory={fuel=1}}
prototypes={item={coal={fuel_value=4000000}}}
local belt={valid=true,unit_number=11,name='transport-belt',type='transport-belt',position={x=3.5,y=0.5},belt_neighbours={inputs={},outputs={}},
  get_max_transport_line_index=function() return 2 end,get_transport_line=function() return {get_item_count=function() return 0 end} end}
local fuelinv={get_item_count=function() return 2 end,get_contents=function() return {{name='coal',count=2}} end}
local boiler={valid=true,unit_number=1,name='boiler',type='boiler',position={x=1.5,y=3},bounding_box={left_top={x=0,y=2},right_bottom={x=3,y=4}},
  burner={},get_fuel_inventory=function() return fuelinv end,prototype={burner_prototype={effectivity=1},max_energy_usage=30000}}
local ins={valid=true,unit_number=2,name='burner-inserter',type='inserter',position={x=3.5,y=1.5},drop_target=boiler,pickup_target=belt,
  burner={remaining_burning_fuel=0},get_fuel_inventory=function() return {get_item_count=function() return 3 end} end}
boiler.surface={}
local surface={name='nauvis',index=1,find_entities_filtered=function(f)
  if f.type=='boiler' then return {boiler} end
  if f.type=='inserter' then return {ins} end
  return {}
end}
boiler.surface=surface
local walked
local H=dofile('mod/agent-harness_0.1.0/fuelhours.lua'){status_name=function() return 'working' end,
  belt_line=function(p,e) walked=e; return {tiles=12,head='(3.5,-8.5): no belt of ours behind it in its direction within 16 tiles',
    gaps={{line='2 tiles missing between (3.5,-4.5) and (3.5,-1.5): (3.5,-3.5) empty; (3.5,-2.5) empty'}}} end}
local out=H.read({force={name='player'}},{},surface)
assert(walked==belt,'the belt the inserter takes from was walked')
local text=table.concat(out.lines or {},'\n')
has(text,'burner-inserter (4,2) (burner with 3 fuel) from transport-belt (4,1); its belt line: 12 tiles, head (3.5,-8.5): no belt of ours behind it in its direction within 16 tiles, 1 gap (2 tiles missing between (3.5,-4.5) and (3.5,-1.5)')
print('boilerfeed: ok')
