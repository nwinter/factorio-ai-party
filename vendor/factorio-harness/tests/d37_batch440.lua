-- Nutrient accounting: exact sample windows, including dependency's ten-minute stock threshold.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
game={tick=100000}
defines={flow_precision_index={ten_minutes=3}}
prototypes={item={nutrients={get_spoil_ticks=function() return 18000 end},egg={get_spoil_ticks=function() return 0 end}},recipe={}}
local state={}
local made,used=1000,500
local stats={get_input_count=function(n) return n=='nutrients' and made or 0 end,
  get_output_count=function(n) return n=='nutrients' and used or 0 end,get_flow_count=function() return 0 end}
local recipe={name='egg',enabled=true,products={{name='egg',amount=1}},ingredients={{name='nutrients',amount=30}}}
local force={name='player',recipes={egg=recipe},get_item_production_statistics=function() return stats end}
local surface={name='gleba',index=4}
local SF=require('spoilflow'){state=function() return state end}
local D=require('dependency'){spoilflow=SF,total=function(_,_,item) return item=='nutrients' and 990 or 0 end}

SF.sample(force,surface,'nutrients',1090)
game.tick=103660; made=1200; used=750
local m=SF.sample(force,surface,'nutrients',990)
eq(m.minutes,1,'display duration is rounded')
eq(m.residual,50)
eq(m.residual_per_min,49.2,'residual uses the exact 61 seconds')
local r=D.read({force=force,surface=surface},{item='egg'})
eq(r.ingredients[1].net_per_min,-98.4,'dependency uses the same exact 61 seconds')
eq(r.ingredients[1].minutes_left,10.1)
eq(r.ingredients[1].state,'ok','rounding a duration must not turn over ten minutes of stock into short')
eq(r.sustained,false,'stock is still falling')

-- Eligibility edges use ticks: early reads preserve the baseline, the exact upper edge counts,
-- and the next tick begins a new baseline. Quoting expires independently after thirty minutes.
state.spoilflow=nil; game.tick=200000
SF.sample(force,surface,'nutrients',100)
game.tick=203599
eq(SF.sample(force,surface,'nutrients',95).line,nil)
game.tick=203600
m=SF.sample(force,surface,'nutrients',90)
eq(m.since_tick,200000); eq(m.uncounted,10); eq(m.minutes,1)
game.tick=m.tick+SF.QUOTE_TICKS
eq(SF.last(force,surface,'nutrients'),m)
game.tick=game.tick+1
eq(SF.last(force,surface,'nutrients'),nil)
game.tick=203600+SF.MAX_TICKS
m=SF.sample(force,surface,'nutrients',80)
eq(m.since_tick,203600); eq(m.minutes,60)
game.tick=game.tick+SF.MAX_TICKS+1
eq(SF.sample(force,surface,'nutrients',70).line,nil)
game.tick=game.tick+SF.MIN_TICKS
m=SF.sample(force,surface,'nutrients',60)
eq(m.stock_then,70); eq(m.uncounted,10)
print('d37_batch440: exact nutrient windows and dependency stock threshold: ok')

-- A biochamber consumes nutrients in two separate inventories: burner and recipe input.
-- The measured copy used 14,400 in egg crafts and 3,038 as fuel in 600s; the budget omitted egg inputs.
do
  defines.entity_status={working=1,low_power=3}
  defines.inventory={crafter_input=2}
  prototypes.item.nutrients.fuel_value=2000000
  local egg={name='egg',energy=15,ingredients={{name='nutrients',type='item',amount=30}}}
  local function inv(n) return {get_contents=function() return {{name='nutrients',count=n}} end} end
  local function chamber(status,fuel,input)
    return {valid=true,type='assembling-machine',name='biochamber',status=status,burner={},crafting_speed=1,
      prototype={max_energy_usage=500000/60,burner_prototype={effectivity=1}},get_recipe=function() return egg end,
      get_fuel_inventory=function() return inv(fuel) end,get_inventory=function() return inv(input) end}
  end
  local users={chamber(1,5,30),chamber(2,2,12)}
  local F=require('fuelbudget'){fuel_users=function() return users,game.tick end,
    status_name=function(e) return e.status==1 and 'working' or 'item_ingredient_shortage' end}
  local out=F.read({force=force,surface=surface},{})
  local by={}; for _,g in ipairs(out.groups) do by[g.group]=g end
  local input=by['recipe egg']
  assert(input,'a burner also has a recipe-input group')
  eq(out.read,2,'entities are counted once even when in two groups')
  eq(input.machines,2); eq(input.working,1)
  eq(input.fuel[1].held,42); eq(input.fuel[1].burn_per_min,120)
  eq(by['burner assemblers'].fuel[1].held,7)
  eq(by['burner assemblers'].fuel[1].burn_per_min,15)
  eq(out.items[1].groups_burn_per_min,135,'fuel and recipe use both contribute, each once')
end
print('d37_batch440: biochamber fuel and recipe inputs counted separately: ok')
