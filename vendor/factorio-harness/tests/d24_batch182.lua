-- Run from repository root: lua tests/d24_batch182.lua
-- d24 batch182 QY1 (Astra #2044: "Gleba six breeders uptime ~104 base craft/min, 156 completions/min while supply made
-- ~149/min. Physical recipe 2 out plus 0.5 bonus, 1 seed returned => 260 gross/156 net. Does native production
-- statistics or supply made already subtract ignored seed? Team almost double-subtracted x0.6"; "recipe-only supply
-- consumers missed egg disposal burners ... Please expose these sinks"). Measured on a private copy of world n's shift70
-- save, Gleba over 66 s: six breeders at +50% made 109 crafts and 54 productivity completions, 272 eggs out, 109 back in;
-- the statistics counted 163 made (the net) and 166 used = 138 agricultural science crafts + 28 eggs a heating tower
-- burned. A heating tower burns max_energy_usage / effectivity: 266,667 J a tick, 192 eggs a minute at full power.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(text,part) assert(text and tostring(text):find(part,1,true),tostring(text)..' lacks '..part) end
local function lacks(text,part) assert(not (text and tostring(text):find(part,1,true)),tostring(text)..' has '..part) end

local EGG={name='pentapod-egg',energy=15,products={{type='item',name='pentapod-egg',amount=2,ignored_by_stats=1,ignored_by_productivity=1}},
  ingredients={{type='item',name='nutrients',amount=30},{type='item',name='pentapod-egg',amount=1,ignored_by_stats=1},{type='fluid',name='water',amount=60}},maximum_productivity=3}
local AG={name='agricultural-science-pack',energy=4,products={{type='item',name='agricultural-science-pack',amount=1}},
  ingredients={{type='item',name='bioflux',amount=1},{type='item',name='pentapod-egg',amount=1}}}
local KOVAREX={name='kovarex-enrichment-process',products={{type='item',name='uranium-235',amount=41,ignored_by_stats=40,ignored_by_productivity=40},
  {type='item',name='uranium-238',amount=2,ignored_by_stats=2,ignored_by_productivity=2}},
  ingredients={{type='item',name='uranium-235',amount=40,ignored_by_stats=40},{type='item',name='uranium-238',amount=5,ignored_by_stats=2}}}
local RECYCLE={name='iron-plate-recycling',products={{type='item',name='iron-plate',amount=1,probability=0.25,ignored_by_stats=1,ignored_by_productivity=1}},
  ingredients={{type='item',name='iron-plate',amount=1,ignored_by_stats=1}}}
local CRYO={name='cryogenic-science-pack',products={{type='item',name='cryogenic-science-pack',amount=1},{type='fluid',name='fluoroketone-hot',amount=3,ignored_by_stats=3,ignored_by_productivity=3}},
  ingredients={{type='item',name='ice',amount=3},{type='fluid',name='fluoroketone-cold',amount=6,ignored_by_stats=3}}}
local GEAR={name='iron-gear-wheel',products={{type='item',name='iron-gear-wheel',amount=1}},ingredients={{type='item',name='iron-plate',amount=2}}}
prototypes={recipe={['pentapod-egg']=EGG,['agricultural-science-pack']=AG,['kovarex-enrichment-process']=KOVAREX,['iron-plate-recycling']=RECYCLE,
  ['cryogenic-science-pack']=CRYO,['iron-gear-wheel']=GEAR},
  item={['pentapod-egg']={name='pentapod-egg',type='item',fuel_value=5000000,get_spoil_ticks=function() return 54000 end},
    nutrients={name='nutrients',type='item',fuel_value=2000000,get_spoil_ticks=function() return 18000 end},
    ['firearm-magazine']={name='firearm-magazine',type='ammo',fuel_value=0,get_spoil_ticks=function() return 0 end},
    ['iron-plate']={name='iron-plate',type='item',fuel_value=0,get_spoil_ticks=function() return 0 end}},fluid={},entity={},quality={normal={name='normal'}}}
game={tick=1000}

-- uptime: what the crafts put out, took in, gave back, net, and what the statistics count of each ignored_by_stats item
do
  local U=dofile('mod/agent-harness_0.1.0/uptime.lua'){state=function() return {} end}
  -- the shift70 window: 109 crafts and 54 productivity completions on six breeders
  local r=U.returned('pentapod-egg',109,54)
  eq(#r,1); r=r[1]
  eq(r.item,'pentapod-egg'); eq(r.out,272); eq(r['in'],109); eq(r.returned,109); eq(r.net,163); eq(r.statistics_made,163); eq(r.statistics_used,0)
  eq(r.line,'pentapod-egg: 272 out (2 a craft, 1 a productivity completion) and 109 in (1 a craft), 109 of them returned (the 1 a craft it takes back in), net 163; '
    ..'the production statistics count 163 made and 0 used of it for these crafts (ignored_by_stats: the returned 1 a craft on neither side, so made is the net)')
  -- no productivity: no productivity clause
  has(U.returned('pentapod-egg',10,0)[1].line,'pentapod-egg: 20 out (2 a craft) and 10 in (1 a craft), 10 of them returned')
  -- kovarex: uranium-235 returned 40 a craft (net +1, counted made); uranium-238 2 returned of 5 in, 3 counted used
  local k=U.returned('kovarex-enrichment-process',10,0)
  eq(k[1].item,'uranium-235'); eq(k[1].out,410); eq(k[1].returned,400); eq(k[1].net,10); eq(k[1].statistics_made,10); eq(k[1].statistics_used,0)
  eq(k[2].item,'uranium-238'); eq(k[2].out,20); eq(k[2]['in'],50); eq(k[2].returned,20); eq(k[2].net,-30); eq(k[2].statistics_made,0); eq(k[2].statistics_used,30)
  has(k[2].line,'(ignored_by_stats: the returned 2 a craft on neither side)'); lacks(k[2].line,'so made is the net')
  -- an item recycled into itself: a quarter back on average, neither side counted
  local rc=U.returned('iron-plate-recycling',100,0)[1]
  eq(rc.out,25); eq(rc['in'],100); eq(rc.returned,25); eq(rc.net,-75); eq(rc.statistics_made,0); eq(rc.statistics_used,0)
  -- one side only: a product or an ingredient with ignored_by_stats (different fluids)
  local c=U.returned('cryogenic-science-pack',100,0)
  eq(#c,2); eq(c[1].item,'fluoroketone-hot'); eq(c[1].statistics_made,0); eq(c[1].returned,nil)
  has(c[1].line,'fluoroketone-hot: 300 out (3 a craft), net 300; the production statistics count 0 made and 0 used of it for these crafts (ignored_by_stats: 3 a craft out not counted made)')
  eq(c[2].item,'fluoroketone-cold'); eq(c[2].statistics_used,300)
  has(c[2].line,'fluoroketone-cold: 600 in (6 a craft), net -600; the production statistics count 0 made and 300 used of it for these crafts (ignored_by_stats: 3 a craft in not counted used)')
  -- a recipe with none: nothing (and the answer kept)
  eq(U.returned('iron-gear-wheel',10,0),nil); eq(U.returned('iron-gear-wheel',10,0),nil); eq(U.returned('pentapod-egg',nil,0),nil)
end
print('d24_batch182 QY1 uptime returned: out, in, returned, net and what the statistics count: ok')

-- uptime's watch: the breeders' rows and their group carry it, the lines too
do
  defines={inventory={assembling_machine_input=2,furnace_source=2,crafter_input=2}}
  local st={}
  local ms={}
  local function breeder(x)
    local m={valid=true,name='biochamber',type='assembling-machine',position={x=x,y=10},force={recipes={}},prototype={},productivity_bonus=0.5,crafting_speed=4.4,
      products_finished=1000,bonus_progress=0,crafting_progress=0,status='working',get_recipe=function() return EGG end,
      get_inventory=function() return {get_item_count=function() return 0 end,get_contents=function() return {} end} end}
    ms[#ms+1]=m
    return m
  end
  breeder(7.5); breeder(19.5)
  local U=dofile('mod/agent-harness_0.1.0/uptime.lua'){state=function() return st end,remote_entity=function(_,q) for _,m in ipairs(ms) do if m.position.x==q.position.x then return m end end end,
    status_name=function(e) return e.status end,craftrate=function(e) return {crafts_per_min=17.6,productivity=0.5,productivity_machine=0.5,productivity_research=0} end}
  U.handler({index=1},{positions={{x=7.5,y=10},{x=19.5,y=10}},seconds=60})
  for t=game.tick+1,game.tick+3600 do
    game.tick=t
    for _,m in ipairs(ms) do
      local step=m.crafting_speed/EGG.energy/60
      m.crafting_progress=m.crafting_progress+step; m.bonus_progress=m.bonus_progress+0.5*step
      if m.crafting_progress>=1 then m.crafting_progress=m.crafting_progress-1; m.products_finished=m.products_finished+1 end
      while m.bonus_progress>=1 do m.bonus_progress=m.bonus_progress-1; m.products_finished=m.products_finished+1 end
    end
    U.tick(t)
  end
  local res=U.handler({index=1},{})
  local row=res.machines[1]
  eq(row.crafts,17); eq(row.bonus_completions,8); eq(row.completions,25)
  eq(row.returned[1].out,42); eq(row.returned[1].returned,17); eq(row.returned[1].net,25); eq(row.returned[1].statistics_made,25)
  has(row.line,'25 completions, 25/min against 26.4/min at full speed; pentapod-egg: 42 out (2 a craft, 1 a productivity completion) and 17 in (1 a craft), 17 of them returned')
  local g=res.groups[1]
  eq(g.crafts,34); eq(g.completions,50); eq(g.returned[1].out,84); eq(g.returned[1].returned,34); eq(g.returned[1].net,50); eq(g.returned[1].statistics_made,50)
  has(res.group_lines[1],'34 crafts (34/min against 35.2/min); samples working 100%; pentapod-egg: 84 out (2 a craft, 1 a productivity completion) and 34 in (1 a craft), 34 of them returned (the 1 a craft it takes back in), net 50')
  has(res.left_out,'crafts finished, not items, each giving the recipe\'s products once (a productivity completion the amount past ignored_by_productivity: 1 pentapod-egg of 2)')
  defines=nil
end
print('d24_batch182 QY1 uptime rows and groups with returned: ok')

-- supply: the egg recipe's terms with rates from made, and the sinks besides recipes (a heating tower burning eggs)
do
  game.tick=900000
  defines={inventory={chest=1,crafter_input=2,crafter_output=3,fuel=4,robot_cargo=5,lab_input=6},flow_precision_index={ten_minutes=3},
    logistic_mode={active_provider=1,storage=2,requester=3,passive_provider=4,buffer=5}}
  local flow10={['pentapod-egg']={input=1515,output=1527}}
  local stats={get_input_count=function() return 0 end,get_output_count=function() return 0 end,get_flow_count=function(f) return (flow10[type(f.name)=='table' and f.name.name or f.name] or {})[f.category] or 0 end}
  local force={name='player',get_item_production_statistics=function() return stats end,recipes={['pentapod-egg']={productivity_bonus=0}},logistic_networks={},platforms={}}
  local function inv(items) items=items or {}
    return {get_item_count=function(name) return items[type(name)=='table' and name.name or name] or 0 end,is_empty=function() return next(items)==nil end,
      get_contents=function() local o={} for k,v in pairs(items) do o[#o+1]={name=k,count=v,quality='normal'} end return o end} end
  local ents={}
  local function crafter(x,recipe)
    local e={valid=true,name='biochamber',type='assembling-machine',position={x=x,y=0},unit_number=#ents+1,status='working',force=force,productivity_bonus=0.5}
    local f,o,i=inv({nutrients=10}),inv({}),inv({})
    e.get_recipe=function() return recipe end
    e.get_inventory=function(id) return id==defines.inventory.crafter_input and i or id==defines.inventory.crafter_output and o or nil end
    e.get_output_inventory=function() return o end
    e.get_fuel_inventory=function() return f end
    ents[#ents+1]=e
  end
  for x=1,6 do crafter(x*4,EGG) end
  for x=1,3 do crafter(40+x*4,AG) end
  local tower={valid=true,name='heating-tower',type='reactor',position={x=11.5,y=6.5},unit_number=99,status='working',force=force,
    burner={currently_burning={name={name='pentapod-egg'}}},
    prototype={get_max_energy_usage=function() return 666666.66666667 end,burner_prototype={effectivity=2.5}}}
  local tf=inv({['pentapod-egg']=2})
  tower.get_fuel_inventory=function() return tf end
  tower.get_output_inventory=function() return nil end
  ents[#ents+1]=tower
  local idle={valid=true,name='heating-tower',type='reactor',position={x=35.5,y=52.5},unit_number=100,status='working',force=force,
    burner={currently_burning={name={name='spoilage'}}},prototype=tower.prototype}
  local ef=inv({})
  idle.get_fuel_inventory=function() return ef end
  ents[#ents+1]=idle
  local surf={name='gleba',index=4,valid=true,find_entities_filtered=function(f) local o={} for _,e in ipairs(ents) do for _,t in ipairs(type(f.type)=='table' and f.type or {f.type}) do if e.type==t then o[#o+1]=e end end end return o end,
    count_entities_filtered=function() return 0 end}
  surf.planet={name='gleba'}
  local S=require('supply'){status_name=function(e) return e.status end,position=function(v) return v end,integer=function(v,d) return v or d end,
    timed=function(_,fn,...) return fn(...) end,spoil={spoils=function(n) return n=='pentapod-egg' end,hatch=function(n) return n=='pentapod-egg' and {entity='small-wriggler-pentapod'} or nil end,
      secs=function(t) return t..'s' end,per_text=function() return '1 each' end,inventory=function() end}}
  local r=S.supply_fresh(surf,force,'pentapod-egg')
  eq(#r.returned,1)
  eq(r.returned[1],'the recipe pentapod-egg on 6 machines (productivity +50%) gives 2 pentapod-egg a craft and 1 a productivity completion, and takes 1 back in a craft; '
    ..'the production statistics count 1 a craft and 1 a productivity completion as made and 0 a craft as used: the 1 it gives back is ignored_by_stats, on neither side, so made counts the net. '
    ..'From made 1515 in the last 10 min: about 101 crafts/min, 252.5/min out, 101/min back in, net 151.5/min')
  eq(r.used_by[1],'recipes (used counts each craft\'s ingredient past ignored_by_stats): pentapod-egg x6 (1 a craft, 0 of it counted: 1 ignored_by_stats), agricultural-science-pack x3 (1 a craft)')
  eq(r.used_by[2],'burned as fuel (counted in used; the game keeps no count per burner): heating-tower x1 (1 burning it now, 2 in fuel slots, up to 192/min at full power)')
  eq(r.used_by[3],'not counted in used: hatching into enemies (0 of those read within 5 min); what is carried off the surface (rockets, cargo pods, vehicles, characters)')
  has(r.where,'fuel slots 2')
  -- research productivity on the recipe adds to the machine's; mixed productivity: no rates from made
  force.recipes['pentapod-egg'].productivity_bonus=0.1
  ents[1].productivity_bonus=0.2
  S.forget()
  r=S.supply_fresh(surf,force,'pentapod-egg')
  has(r.returned[1],'the recipe pentapod-egg on 6 machines (productivity +30% to +60%)'); lacks(r.returned[1],'From made')
  -- nutrients: not returned by any recipe; burned in biochambers (their fuel slots hold 10 each, one burning them now)
  for _,e in ipairs(ents) do if e.name=='biochamber' then e.burner={currently_burning=e.position.x==4 and {name={name='nutrients'}} or nil} end end
  r=S.supply_fresh(surf,force,'nutrients')
  eq(r.returned,nil)
  eq(r.used_by[#r.used_by-1],'burned as fuel (counted in used; the game keeps no count per burner): biochamber x9 (1 burning it now, 90 in fuel slots)')
  -- no burner holds it
  for _,e in ipairs(ents) do if e.name=='biochamber' then e.get_fuel_inventory=function() return inv({}) end; e.burner=nil end end
  r=S.supply_fresh(surf,force,'nutrients')
  has(r.used_by[#r.used_by-1],'burned as fuel (counted in used; the game keeps no count per burner): no heating tower, boiler or burner generator here holds or burns it')
  -- ammo: turrets holding it
  local gun={valid=true,name='gun-turret',type='ammo-turret',position={x=0,y=9},unit_number=101,force=force,get_item_count=function(n) return (type(n)=='table' and (n.quality or 'normal')=='normal' and n.name or n)=='firearm-magazine' and 10 or 0 end}
  ents[#ents+1]=gun
  r=S.supply_fresh(surf,force,'firearm-magazine')
  has(table.concat(r.used_by,' | '),'fired as ammo (counted in used; the game keeps no count per turret): 1 of 1 turrets hold 10')
  has(r.used_by[#r.used_by],'not counted in used: what is carried off the surface')
  -- (d26 batch249 R10) a turret holding rare magazines: counted (every quality, as 2.0.77 counts {name} alone), named
  prototypes.quality={normal={level=0},rare={level=2}}; require('qflow').reset()
  ents[#ents+1]={valid=true,name='gun-turret',type='ammo-turret',position={x=2,y=9},unit_number=102,force=force,get_item_count=function(n)
    if type(n)=='table' and n.name=='firearm-magazine' and (n.quality==nil or n.quality=='rare') then return 4 end return 0 end}
  r=S.supply_fresh(surf,force,'firearm-magazine')
  has(table.concat(r.used_by,' | '),'fired as ammo (counted in used; the game keeps no count per turret): 2 of 2 turrets hold 14 (normal 10, rare 4)')
  prototypes.quality=nil; require('qflow').reset()
  defines=nil
end
print('d24_batch182 QY1 supply returned and used_by: the egg recipe from made, burners, turrets, what used leaves out: ok')
