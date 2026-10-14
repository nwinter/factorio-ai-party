-- Run from repository root: lua tests/turrets.lua
-- The turrets read (Opus, 10:50): every turret's ammo (a flamer's oil with its buffer) and health, and what feeds it on
-- its own (an inserter and what it takes from, robots, a pipe, power; nothing: hand-fed), grouped by front, the hand-fed
-- and low ones first.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
defines={inventory={turret_ammo=1,artillery_turret_ammo=2}}
local storage={}
local force={name='player'}
local world={}
local unit=0
local function add(e) unit=unit+1; e.valid=true; e.unit_number=unit; world[#world+1]=e; return e end
local function gun(x,y,count,health)
  local inv={get_item_count=function() return count end,get_contents=function() return count>0 and {{name='firearm-magazine',count=count}} or {} end}
  return add{name='gun-turret',type='ammo-turret',position={x=x,y=y},health=health or 400,max_health=400,get_inventory=function() return inv end}
end
local function inserter(x,y,from,to) return add{name='fast-inserter',type='inserter',position={x=x,y=y},pickup_target=from,drop_target=to} end
-- West front: 3 gun turrets; one fed by an inserter from a requester chest, one by robots, one hand-fed and low.
local req=add{name='requester-chest',type='logistic-container',position={x=-100.5,y=2.5}}
local w1=gun(-100,0,40); inserter(-100.5,1.5,req,w1)
local w2=gun(-104,0,30); w2.item_request_proxy={valid=true,item_requests={{name='firearm-magazine',count=10}}}
local w3=gun(-108,0,3)
-- East front, far off: a gun fed from a belt, damaged; a flamer on a pipe; a laser on power.
local belt=add{name='transport-belt',type='transport-belt',position={x=200.5,y=2.5}}
local e1=gun(200,0,50,100); inserter(200.5,1.5,belt,e1)
local fl=add{name='flamethrower-turret',type='fluid-turret',position={x=204,y=0},health=1400,max_health=1400,
  fluidbox={[1]={name='light-oil',amount=50},get_capacity=function() return 100 end,get_connections=function() return {{}} end},
  prototype={fluidbox_prototypes={{volume=100}}}}
local la=add{name='laser-turret',type='electric-turret',position={x=208,y=0},health=1000,max_health=1000,energy=100,electric_buffer_size=200,electric_network_id=7}
local finds=0
local surface={index=1,name='nauvis',find_entities_filtered=function(f)
  finds=finds+1
  local types={}
  for _,t in ipairs(type(f.type)=='table' and f.type or {f.type}) do types[t]=true end
  local out,a={},f.area
  for _,e in ipairs(world) do
    local p=e.position
    if e.valid and types[e.type] and (not a or (p.x>=a[1][1] and p.x<=a[2][1] and p.y>=a[1][2] and p.y<=a[2][2])) then out[#out+1]=e end
  end
  if f.limit then assert(f.limit<=1024,'bounded') end
  return out
end}
game={tick=100,get_surface=function(name) return name=='nauvis' and surface or nil end}
local p={index=1,force=force,surface=surface}
local D=dofile('mod/agent-harness_0.1.0/defense.lua'){state=function() return storage end}
local r=D.handlers.turrets(p,{})
eq(r.count,6); eq(r.hand_fed,1); eq(r.low,2)
eq(#r.fronts,2)
-- The west front first (a hand-fed and a low turret); in it the hand-fed low one first.
local w=r.fronts[1]
eq(w.line,'front (-108,0)-(-100,0): 3 turrets (3 gun-turret), 1 hand-fed, 1 low')
eq(w.turret_lines[1],'gun-turret (-108,0) firearm-magazine 3, health 100%: nothing feeds it (hand-fed)')
eq(w.turret_lines[2],'gun-turret (-104,0) firearm-magazine 30, health 100%: robots bringing 10 firearm-magazine')
eq(w.turret_lines[3],'gun-turret (-100,0) firearm-magazine 40, health 100%: fast-inserter (-100.5,1.5) from requester-chest (-100.5,2.5)')
local e=r.fronts[2]
eq(e.line,'front (200,0)-(208,0): 3 turrets (1 flamethrower-turret, 1 gun-turret, 1 laser-turret), 0 hand-fed, 1 low')
eq(e.turret_lines[1],'gun-turret (200,0) firearm-magazine 50, health 25%: fast-inserter (200.5,1.5) from transport-belt (200.5,2.5)')
eq(e.turret_lines[2],'flamethrower-turret (204,0) light-oil 50/100 with its buffer, health 100%: pipe')
eq(e.turret_lines[3],'laser-turret (208,0) energy 50%, health 100%: electric network #7')
-- An area: the west front only; a surface by name; cached 10 s.
local n=finds
local ra=D.handlers.turrets(p,{area={left_top={x=-120,y=-10},right_bottom={x=-90,y=10}}})
eq(ra.count,3); eq(#ra.fronts,1)
eq(D.handlers.turrets(p,{surface='nauvis'}).count,6)
local again=D.handlers.turrets(p,{})
eq(again.as_of,nil,'the same tick'); game.tick=game.tick+300
assert(D.handlers.turrets(p,{}).as_of==100,'cached within 10 s')
assert(not pcall(D.handlers.turrets,p,{surface='mars'}),'no surface named mars')
eq(D.handlers.turrets(p,{area={left_top={x=0,y=0},right_bottom={x=1,y=1}}}).note,'no turret of ours there')
print('turrets: ok')
