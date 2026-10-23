-- Run from repository root: lua tests/d22_batch122b.lua
-- d22 batch122 CE2 (viewer Aurora 10:13: "Could you verify live nutrient accounting for fuel, spoilage, time windows
-- and stock scope? Gleba's positive production balance and falling stocks need reconciling"). Measured on a private
-- 2.0.77 copy of world n: spoiling counts on neither side of the production statistics, fuel burned counts as used, a
-- productivity bonus's extra products count as made; on Gleba over 5 game minutes nutrients were made 20,120 and used
-- 17,445 while every place held 3,758 then 3,770, so 2,663 spoiled uncounted. Before: supply, stock, fuel_budget and
-- dependency gave made above used with no word of spoiling, supply's stock left out biochambers' fuel slots (195 of
-- 3,792), dependency read nutrients "sustained" and counted the egg recipe's ingredient use at 1.5x (the +50% bonus).
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(text,part) assert(text and tostring(text):find(part,1,true),tostring(text)..' lacks '..part) end
local function lacks(text,part) assert(not (text and tostring(text):find(part,1,true)),tostring(text)..' has '..part) end
local storage_={}
game={tick=1000}
prototypes={item={nutrients={name='nutrients',type='item',fuel_value=2000000,get_spoil_ticks=function() return 18000 end},
  ['pentapod-egg']={name='pentapod-egg',type='item',fuel_value=5000000,get_spoil_ticks=function() return 54000 end},
  ['iron-plate']={name='iron-plate',type='item',fuel_value=0,get_spoil_ticks=function() return 0 end}},fluid={},recipe={},entity={}}
defines={flow_precision_index={ten_minutes=3},inventory={chest=1,crafter_input=2,crafter_output=3,fuel=4,robot_cargo=5}}
-- The production statistics: running totals per item, and a ten-minute flow.
local totals={nutrients={made=17087324,used=14028301}}
local flow10={nutrients={input=40650,output=34705},['pentapod-egg']={input=1491,output=1485}}
local stats={get_input_count=function(n) return (totals[n] or {}).made or 0 end,get_output_count=function(n) return (totals[n] or {}).used or 0 end,
  get_flow_count=function(f) return (flow10[f.name] or {})[f.category] or 0 end}
local force={name='player',get_item_production_statistics=function() return stats end,recipes={},logistic_networks={},platforms={}}
local gleba={name='gleba',index=4}
local SF=require('spoilflow'){state=function() return storage_ end,secs=function(t) return math.floor(t/60)..'s' end}

-- spoilflow: a whole-surface count kept, the next one 1 to 60 min later measured against it.
do
  eq(SF.sample(force,gleba,'iron-plate',100),nil,'an item that does not spoil')
  eq(SF.sample(force,gleba,'nutrients',3758).line,nil,'the first count: nothing to measure against')
  game.tick=1000+1800; totals.nutrients={made=17087324+10000,used=14028301+9000}
  local early=SF.sample(force,gleba,'nutrients',3800)
  eq(early.line,nil,'under a minute: no measure, the first count kept')
  eq(early.note,'the whole-surface count kept 30s ago is under a minute old: the next read from 30s on is measured against it')
  game.tick=1000+18000; totals.nutrients={made=17087324+20120,used=14028301+17445}
  local m=SF.sample(force,gleba,'nutrients',3770)
  eq(m.uncounted,2663); eq(m.uncounted_per_min,532.6); eq(m.minutes,5)
  eq(m.line,'over the last 5 min (whole-surface counts at tick 1000 and now): made 20120, used 17445; held 3758 then, 3770 now; 2663 left uncounted (532.6 a minute): spoiled, or carried off the surface')
  has(SF.text(force,gleba,'nutrients'),'532.6 a minute left uncounted (spoiled, or carried off the surface), measured by supply over 5 min to 0s ago')
  has(SF.text(force,gleba,'nutrients'),'the production statistics leave spoiling out: made counts crafts (a productivity bonus\'s extra among them), used counts ingredients and fuel burned')
  eq(SF.text(force,gleba,'iron-plate'),nil)
  -- quoted for 30 min, then the note alone
  game.tick=game.tick+108001
  has(SF.text(force,gleba,'nutrients'),'supply {item, surface} measures what left uncounted between two of its reads 1 to 60 min apart')
  -- a count over 60 min after the kept one starts again
  game.tick=game.tick+216000
  eq(SF.sample(force,gleba,'nutrients',3000).line,nil,'the kept count is over 60 min old')
end
print('d22_batch122b CE2 spoilflow: what left uncounted between two whole-surface counts: ok')

-- dependency: an ingredient that spoils is read against what left uncounted; the crafts run count the makers' bonus.
do
  game.tick=500000
  totals.nutrients={made=0,used=0}
  SF.sample(force,gleba,'nutrients',1800)
  game.tick=game.tick+36000
  totals.nutrients={made=40000,used=35000}
  SF.sample(force,gleba,'nutrients',800)
  flow10.nutrients={input=40000,output=35000}
  -- as 2.0.77 gives it: the egg put in comes back, counted by neither side
  local EGG={name='pentapod-egg',products={{type='item',name='pentapod-egg',amount=2,ignored_by_stats=1,ignored_by_productivity=1,probability=1}},
    ingredients={{type='item',name='nutrients',amount=30},{type='item',name='pentapod-egg',amount=1,ignored_by_stats=1},{type='fluid',name='water',amount=60}}}
  force.recipes['pentapod-egg']={name='pentapod-egg',enabled=true,products=EGG.products,ingredients=EGG.ingredients}
  local function chamber(bonus) return {valid=true,productivity_bonus=bonus,get_recipe=function() return EGG end} end
  local D=require('dependency'){spoilflow=SF,census_crafters=function() return {chamber(0.5),chamber(0.5),{valid=true,get_recipe=function() return nil end}} end,
    total=function(f,s,item) return item=='nutrients' and 800 or 27 end}
  local r=D.read({surface=gleba,force=force},{item='pentapod-egg'})
  local nut=r.ingredients[1]
  eq(nut.item,'nutrients'); eq(nut.uncounted_per_min,600); eq(nut.net_per_min,-100); eq(nut.minutes_left,8); eq(nut.state,'short')
  eq(r.sustained,false,'made above used, the stock falling by spoiling')
  -- 149.1 eggs a minute counted at +50%: 1.5 a craft, 99.4 crafts, 2982 nutrients a minute (Gleba measured 99.7 crafts
  -- and 2,992 nutrients a minute from the biochambers' finished crafts; before: 74.6 crafts and 2,236.5)
  eq(nut.for_this_per_min,2982)
  has(r.lines[1],'recipe pentapod-egg: 2 per craft (+50% productivity on its 2 makers there; the statistics count 1.5 a craft); 99.4 crafts a minute')
  has(r.lines[2],'nutrients: made 4000/min, used 3500/min, 600/min left uncounted (spoiled, or carried off the surface; supply measured it), stock 800 (8 min at the net use)')
  -- the egg itself spoils too, with no measure: said
  has(r.lines[#r.lines],'spoiling not counted for pentapod-egg (the statistics leave it out; no supply measure in the last 30 min)')
end
print('d22_batch122b CE2 dependency: spoiling and the productivity bonus counted: ok')

-- supply: a fuel's stock counts fuel slots (a biochamber's), and a whole-surface read measures what left uncounted.
do
  storage_.spoilflow=nil
  game.tick=900000
  defines.inventory={chest=1,crafter_input=2,crafter_output=3,fuel=4,robot_cargo=5,lab_input=6}
  defines.logistic_mode={active_provider=1,storage=2,requester=3,passive_provider=4,buffer=5}
  local function inv(items) items=items or {}
    return {get_item_count=function(name) return items[name] or 0 end,is_empty=function() return next(items)==nil end,
      get_contents=function() local o={} for k,v in pairs(items) do o[#o+1]={name=k,count=v,quality='normal'} end return o end} end
  local NFS={name='nutrients-from-spoilage',products={{type='item',name='nutrients',amount=1}},ingredients={{type='item',name='spoilage',amount=10}}}
  local ents={}
  local function chamber(x,fuel,out)
    local e={valid=true,name='biochamber',type='assembling-machine',position={x=x,y=0},unit_number=#ents+1,status='working',force=force}
    local f,o,i=inv({nutrients=fuel}),inv({nutrients=out}),inv({})
    e.get_recipe=function() return NFS end
    e.get_inventory=function(id) return id==defines.inventory.crafter_input and i or id==defines.inventory.crafter_output and o or nil end
    e.get_output_inventory=function() return o end
    e.get_fuel_inventory=function() return f end
    ents[#ents+1]=e
    return e
  end
  chamber(0,40,10); chamber(4,30,0)
  local surf={name='gleba',index=4,valid=true,find_entities_filtered=function(f) local o={} for _,e in ipairs(ents) do for _,t in ipairs(f.type or {}) do if e.type==t then o[#o+1]=e end end end return o end,
    count_entities_filtered=function() return 0 end}
  surf.planet={name='gleba'}
  local S=require('supply'){status_name=function(e) return e.status end,position=function(v) return v end,integer=function(v,d) return v or d end,
    timed=function(_,fn,...) return fn(...) end,spoilflow=SF,ground_index=function() return {count=5,stacks=1,cells={},as_of=game.tick-600} end}
  totals.nutrients={made=1000,used=800}
  local r=S.supply_fresh(surf,force,'nutrients')
  has(r.where,'85: machine outputs 10, fuel slots 70, on the ground 5 (the ground watch\'s pass 10s ago)')
  has(r.flow,'; the production statistics leave spoiling out')
  has(r.uncounted,'no whole-surface supply read of it 1 to 60 min before this one')
  game.tick=game.tick+7200; totals.nutrients={made=1400,used=1150}
  S.forget()
  r=S.supply_fresh(surf,force,'nutrients')
  eq(r.uncounted,'over the last 2 min (whole-surface counts at tick 900000 and now): made 400, used 350; held 85 then, 85 now; 50 left uncounted (25 a minute): spoiled, or carried off the surface')
  -- an area read is no whole-surface count: no measure
  r=S.supply_fresh(surf,force,'nutrients',{position={x=0,y=0},radius=10})
  eq(r.uncounted,nil)
  lacks(r.where,'on the ground')
end
print('d22_batch122b CE2 supply: fuel slots in the stock, what left uncounted measured: ok')
