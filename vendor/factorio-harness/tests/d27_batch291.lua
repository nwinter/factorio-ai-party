-- d27 batch291 LS (Sol #2638): labs and inspect give each lab's research rate at full supply as the engine runs it.
-- Measured on the iMac copy (2.0.77, world n's 30 biolabs on low-density-structure-productivity, 60 s units of 5 packs,
-- the force's lab speed 2.5): one biolab cut off from its inserters and filled used 5.845 of each pack a minute with
-- modules and beacons at +0.67 (2 x 1.67 x 3.5 = 11.69 units, drain 50%), another 4.550 at +0.30 (2 x 1.3 x 3.5); the
-- entity's speed_bonus (their sum, 3.17) would give 4.17 and 3.8. Productivity (0.4) adds progress, not pack use.
-- Run from the harness root: lua tests/d27_batch291.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function near(a,b,m) assert(type(a)=='number' and math.abs(a-b)<0.005,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(text,part) assert(type(text)=='string' and text:find(part,1,true),tostring(text)..'\n  lacks: '..part) end
defines={inventory={lab_input=2}}
local QSPEED={normal=2,uncommon=2.6,rare=3.2,epic=3.8,legendary=5}
local biolab={researching_speed=2,science_pack_drain_rate_percent=50,get_researching_speed=function(q) return QSPEED[q] end}
local n=0
local function lab(x,y,speed,quality)
  n=n+1
  return {valid=true,unit_number=n,name='biolab',type='lab',position={x=x,y=y},status=1,prototype=biolab,quality={name=quality or 'normal'},
    effects={speed=speed,productivity=0.4},speed_bonus=speed+2.5,productivity_bonus=0.4,
    get_inventory=function() return {get_item_count=function() return 10 end} end}
end
local l1,l2,l3=lab(-237.5,-129.5,0.67000001668930054),lab(-235.5,-113.5,0.3),lab(-200.5,-100.5,0.3,'rare')
local labs={l1,l2,l3}
local surface={name='nauvis',find_entities_filtered=function(f) if f.type=='lab' then return labs end return {} end}
local packs={'automation-science-pack','logistic-science-pack','chemical-science-pack','production-science-pack','metallurgic-science-pack'}
local ing={}
for i,name in ipairs(packs) do ing[i]={name=name,amount=1} end
local tech={name='low-density-structure-productivity',research_unit_ingredients=ing,research_unit_count=129746,research_unit_energy=3600}
local force={current_research=tech,research_progress=0.5,laboratory_speed_modifier=2.5}
local p={position={x=-236,y=-120},surface=surface,force=force}
game={tick=0,surfaces={nauvis=surface}}
local L=dofile('mod/agent-harness_0.1.0/labs.lua'){integer=function(v,d) return v or d end,center=function(pl) return pl.position end,
  status_name=function() return 'working' end,research_rate=function() return 1,3600 end}

-- one lab: the two bonuses multiplied, as measured (not the entity's speed_bonus, their sum)
do
  local r=L.rate(l1,force,tech)
  near(r.speed,11.69); near(r.units_per_min,11.69); near(r.packs['metallurgic-science-pack'],5.845); eq(r.drain,50)
  near(r.unit_s,60/11.69); near(r.productivity,0.4)
  local r2=L.rate(l2,force,tech)
  near(r2.packs['automation-science-pack'],4.55)
  has(L.rate_text(l1,r),'biolab (-237.5,-129.5): speed 11.7 (researching speed 2 x (1 + modules and beacons 0.67) x (1 + the force\'s lab speed 2.5)); a unit in 5.13s, 11.7 units a minute; drain 50%: 5.85 of each pack a minute; productivity +40%')
  -- a rare biolab: researching speed 3.2
  near(L.rate(l3,force,tech).speed,3.2*1.3*3.5)
  -- productivity does not change pack use
  l1.productivity_bonus=0; near(L.rate(l1,force,tech).packs['automation-science-pack'],5.845); l1.productivity_bonus=0.4
  print('LS one lab: speed and packs a minute as measured: ok')
end

-- the labs read: a line a lab, the aggregate, and each group's figures
do
  local r=L.view(p,{})
  eq(#r.lab_rates,3); has(r.lab_rates[2],'biolab (-235.5,-113.5): speed 9.1'); has(r.lab_rates[2],'4.55 of each pack a minute')
  local f=r.full_speed
  eq(f.labs,3)
  near(f.units_per_min,math.floor((11.69+9.1+3.2*1.3*3.5)*100+0.5)/100)
  near(f.packs_per_min['production-science-pack'],math.floor((5.845+4.55+3.2*1.3*3.5/2)*100+0.5)/100)
  near(f.progress_per_min,math.floor((11.69+9.1+3.2*1.3*3.5)*1.4*100+0.5)/100)
  has(f.line,'the engine\'s figures at full supply: 3 labs research 35.4 units a minute (49.5 with productivity) of low-density-structure-productivity, using a minute automation 17.7, chemical 17.7, logistic 17.7, metallurgic 17.7, production 17.7; what they used: science {pack}')
  has(r.groups[1],'at full supply')
  has(r.groups[1],'(the engine\'s figures)')
  print('LS the labs read: per lab, the aggregate, the groups: ok')
end

-- no research: speed only, no units or packs, no aggregate
do
  force.current_research=nil
  local r=L.rate(l1,force,nil)
  near(r.speed,11.69); eq(r.units_per_min,nil)
  local v=L.view(p,{})
  eq(v.full_speed,nil); has(v.lab_rates[1],'speed 11.7'); assert(not v.lab_rates[1]:find('units a minute',1,true))
  force.current_research=tech
  print('LS no research: speed only: ok')
end
game=nil; defines=nil
print('d27_batch291 LS: ok')
