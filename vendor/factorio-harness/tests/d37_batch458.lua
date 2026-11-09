-- #2939: native 2.0.77 shots scale both attack range and line length by turret range_multiplier.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b) assert(a==b,tostring(a)..' ~= '..tostring(b)) end
local function near(a,b) assert(math.abs(a-b)<1e-8,tostring(a)..' ~= '..tostring(b)) end
local function has(a,b) assert(a:find(b,1,true),a..' lacks '..b) end
local function box(x,y,h) return {left_top={x=x-h,y=y-h},right_bottom={x=x+h,y=y+h}} end
local names={'normal','uncommon','rare','epic','legendary'}
local mults={1,1.1,1.2,1.3,1.5}
prototypes={quality={},entity={
  ['railgun-turret']={type='ammo-turret',attack_parameters={range=40,min_range=3.5,turn_range=.2,projectile_creation_distance=3.6,ammo_categories={'railgun'}}},
  belt={type='transport-belt',collision_box=box(0,0,.25)}},
  get_item_filtered=function() return {['railgun-ammo']={get_ammo_type=function() return {category='railgun',action={{type='line',range=50,width=1}}} end}} end}
for i,q in ipairs(names) do prototypes.quality[q]={name=q,range_multiplier=mults[i]} end
local F=require('fireline'){}
defines={inventory={turret_ammo=1}}
local built,ghosts,targets={},{},{}
local find_area
local s={index=1,find_tiles_filtered=function() return {} end,
  find_entities_filtered=function(a)
    if a.name=='railgun-turret' or type(a.type)=='table' then return built end
    if a.ghost_name=='railgun-turret' then return ghosts end
    if a.area then find_area=a.area; return targets end
    return {}
  end}
local function gun(q,ghost)
  return {valid=true,name=ghost and 'entity-ghost' or 'railgun-turret',ghost_name=ghost and 'railgun-turret',
    type=ghost and 'entity-ghost' or 'ammo-turret',quality=prototypes.quality[q],position={x=0,y=0},direction=0,
    surface=s,force='ours',prototype=prototypes.entity['railgun-turret'],ignore_unprioritised_targets=false,
    get_priority_target=function() end,get_inventory=function() return {get_contents=function() return {} end} end}
end
local P=require('platdefense'){fireline=F,platform=function() return {name='test',surface=s,force='ours'} end}
local function prop(d) return {name='belt',position={x=0,y=-d}} end
local function target(d) return {name='belt',type='transport-belt',position={x=0,y=-d},bounding_box=box(0,-d,.25),is_entity_with_health=true} end
local function check(c,i)
  eq(c.quality,names[i]); near(c.range,40*mults[i]); eq(c.base_range,40); eq(c.min_range,3.5)
  near(c.line_length,50*mults[i]); eq(c.base_line_length,50); near(c.reach,3.6+50*mults[i])
  near(c.range_multiplier,mults[i]); eq(c.start,3.6); eq(c.width,1); eq(c.arc,.2)
end
for i,q in ipairs(names) do
  local reach=3.6+50*mults[i]
  -- A footprint past targeting range but inside the shot, and both sides of the expanded radial boundary.
  targets={target(reach-1),target(reach+.75),target(reach+.751)}
  for _,ghost in ipairs({false,true}) do
    local t=gun(q,ghost)
    built=ghost and {} or {t}; ghosts=ghost and {t} or {}
    local r=F.of(t)
    check(r.corridor,i); eq(r.hit,2)
    near(find_area[1][2],-reach-6) -- discovery grows to the quality shot reach too
    has(r.line,string.format('targets up to %g tiles',40*mults[i]))
    has(r.line,string.format('to %g tiles',reach))
    if i>1 then has(r.line,q..' railgun-turret') end
    local p=P.read({}, {platform='test',planned_entities={prop(reach-1),prop(reach+.75),prop(reach+.751)}})
    eq(p.railguns_checked,1); eq(p.complete,true); eq(p.railguns[1].ghost,ghost)
    check(p.railguns[1].corridor,i); check(p.corridor,1)
    eq(#p.entities[1].railguns,1); eq(#p.entities[2].railguns,1); eq(#p.entities[3].railguns,0)
    if not ghost then
      local full=P.read({}, {platform='test',ammo_use=false})
      check(full.lines_of_fire[1].corridor,i)
      near(full.lines_of_fire[1].corridor.range,full.turrets[1].range)
      eq(full.lines_of_fire[1].hit,2)
    end
  end
  -- Explicit quality for build/place_ghosts previews, and string/prototype lookup agree.
  check(F.hits(s,'ours','railgun-turret',{x=0,y=0},0,nil,q).corridor,i)
  check(F.arc('railgun-turret',prototypes.quality[q]),i)
end
-- Mixed-quality sources never reuse another source's cached range; normal stays at base afterward.
built={}; ghosts={gun('legendary',true)}
for i=1,4 do built[i]=gun(names[i]) end
local mixed=P.read({}, {platform='test',planned_entities={prop(56),prop(76)}})
eq(#mixed.entities[1].railguns,4); eq(#mixed.entities[2].railguns,1)
for i=1,4 do check(mixed.railguns[i].corridor,i+1) end
check(F.arc('railgun-turret'),1)
-- The angular boundary stays 36 degrees, including at upgraded distances.
local c=F.arc('railgun-turret','legendary')
for _,case in ipairs({{35,true},{37,false}}) do
  local a=case[1]*math.pi/180; local x,y=70*math.sin(a),-70*math.cos(a)
  eq(F.intersects(c,{x=0,y=0},0,'railgun-turret','belt',{x=x,y=y},box(x,y,.01)),case[2])
end
has(P.schema.platform_defense.line_page,'corridor')
has(P.schema.platform_defense.planned_entities,'line_length')
print('batch458: all five railgun qualities, built/ghost/proposed/live rows, previews, reach edges, arc and mixed cache ok')
