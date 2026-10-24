-- d24 batch171 QN1 (Sol 15:09): Asterion's three explosives chemical plants read 39/min each in inspect, 117 in all,
-- and platform_production read 290 made a minute. World n 15:20: a fourth maker, a cryogenic plant at (-14.5,56.5) with
-- 8 productivity module 3s (+80%) and two beacons of speed module 3s (speed 3.84), made the rest; the statistics were
-- all normal quality and equal to input_counts. Both reads were right: platform_production {item} now lists the
-- machines on the platform that make it, each at full speed as inspect gives it, and their sum; inspect's rate line
-- says it is the one machine. Run from the harness root: lua tests/d24_batch171.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,msg) assert(a==b,(msg or '')..' '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end

defines={flow_precision_index={one_minute=1,ten_minutes=2,one_hour=3}}
prototypes={}
local explosives={name='explosives',energy=4,prototype={maximum_productivity=3},
  ingredients={{type='item',name='sulfur',amount=2},{type='item',name='coal',amount=1},{type='fluid',name='water',amount=10}},
  products={{type='item',name='explosives',amount=2}}}
local casting={name='casting-iron',energy=3.2,prototype={maximum_productivity=3},
  ingredients={{type='fluid',name='molten-iron',amount=20}},products={{type='item',name='iron-plate',amount=2}}}
local force={recipes={explosives={productivity_bonus=0},['casting-iron']={productivity_bonus=0}}}
local function machine(name,x,y,speed,prod,recipe,status,crafts)
  return {valid=true,name=name,position={x=x,y=y},quality={name='normal'},prototype={name=name},force=force,
    crafting_speed=speed,productivity_bonus=prod,status=status,products_finished=crafts,get_recipe=function() return recipe end}
end
local found={machine('chemical-plant',-5.5,48.5,1.3,0,explosives,1,34784),machine('chemical-plant',-5.5,56.5,1.3,0,explosives,1,40658),
  machine('chemical-plant',-5.5,64.5,1.3,0,explosives,1,47087),machine('foundry',20.5,80.5,4,0.5,casting,1,9000),
  machine('cryogenic-plant',-14.5,56.5,3.84,0.8,explosives,1,17474)}
local finds=0
local surface={find_entities_filtered=function(f)
  finds=finds+1; eq(f.type[1],'assembling-machine'); eq(f.type[2],'furnace'); return found end}
local pl={name='Asterion',surface=surface}
-- the statistics: explosives 224 made in the last minute, 2722.85 in ten, 305950 in all, all normal
local function stats(made)
  return {input_counts=made and {explosives=305950} or {},output_counts=made and {explosives=300000} or {},
    get_input_count=function(n) return made and n=='explosives' and 305950 or 0 end,
    get_output_count=function(n) return made and n=='explosives' and 300000 or 0 end,
    get_flow_count=function(a)
      if not made or a.name~='explosives' then return 0 end
      local m={[1]=224,[2]=2722.85,[3]=16000}
      return a.category=='input' and m[a.precision_index] or m[a.precision_index]-10
    end}
end
local p={force={get_item_production_statistics=function() return stats(true) end,get_fluid_production_statistics=function() return stats(false) end}}
local CR=dofile('mod/agent-harness_0.1.0/craftrate.lua'){}
local status={[1]='working'}
local B=dofile('mod/agent-harness_0.1.0/platbom.lua'){platform=function() return pl end,cargo={},
  craftrate=function(e) return CR.machine(e) end,status_name=function(e) return status[e.status] end}

-- inspect's rate: the one machine
local r=CR.machine(found[5])
eq(r.products[1].per_min,207.4)
has(r.line,'(this machine alone, at full speed all the time; status, input and output decide what it makes)')

-- platform_production {item}: the four makers, the most first, and their sum against what was made
local out=B.production(p,{platform='Asterion',item='explosives'})
eq(finds,1)
eq(out.items[1].made_per_min_1m,224); eq(out.items[1].made_per_min_10m,272.3)
assert(out.makers,'no makers')
eq(#out.makers,4)
eq(out.makers[1].entity,'cryogenic-plant'); eq(out.makers[1].per_min,207.4); eq(out.makers[1].speed,3.84)
eq(out.makers[1].productivity,0.8); eq(out.makers[1].status,'working'); eq(out.makers[1].crafts,17474)
eq(out.makers[2].entity,'chemical-plant'); eq(out.makers[2].per_min,39); eq(out.makers[2].position.y,48.5)
eq(out.makers[4].position.y,64.5); eq(out.makers[4].recipe,'explosives')
eq(out.makers_full_per_min,324.4)
eq(out.lines[#out.lines],'makers: 4 crafting machines on Asterion with a recipe that makes explosives, 324.4/min together at full '
  ..'speed (made 224 in the last minute): cryogenic-plant (-14.5,56.5) explosives 207.4/min (speed 3.84, productivity +80%, '
  ..'working); chemical-plant (-5.5,48.5) explosives 39/min (speed 1.3, productivity +0%, working); chemical-plant (-5.5,56.5) '
  ..'explosives 39/min (speed 1.3, productivity +0%, working); chemical-plant (-5.5,64.5) explosives 39/min (speed 1.3, '
  ..'productivity +0%, working)')
has(out.note,'made counts what every machine on it made, productivity included')
has(out.note,'inspect\'s rate is one machine alone')

-- an item no machine there makes; and without item no machine is read
out=B.production(p,{platform='Asterion',item='rocket-fuel'})
eq(#out.makers,0); eq(out.makers_full_per_min,0)
eq(out.lines[#out.lines],'makers: no crafting machine on Asterion has a recipe that makes rocket-fuel')
finds=0
out=B.production(p,{platform='Asterion'})
eq(finds,0); eq(out.makers,nil); eq(#out.items,1)
print('d24_batch171 QN1 platform_production makers, inspect says one machine: ok')
