-- #2917: default detour remains stable; explicit direct recovery follows either oriented leg.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b) assert(a==b,tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
local function fails(fn,x) local ok,e=pcall(fn); assert(not ok); has(e,x) end
game={tick=122071200}
defines={inventory={hub_main=1},flow_precision_index={one_minute=1,ten_minutes=2}}
prototypes={item={rocket={type='ammo'}},fluid={},quality={normal={level=0}},space_location={
  aquilo={},['solar-system-edge']={},['shattered-planet']={}},
  space_connection={{from={name='aquilo'},to={name='solar-system-edge'},length=100000}}}
local stock=1000
local stats={input_counts={},output_counts={rocket=10000},
  get_flow_count=function(a)
    if type(a.name)=='table' or a.category=='input' then return 0 end
    return a.precision_index==2 and 100 or 10
  end,
  get_input_count=function() return 0 end,get_output_count=function() return 10000 end}
local force={get_item_production_statistics=function() return stats end}
local surface={find_entities_filtered=function() return {} end,count_entities_filtered=function() return 0 end}
local hub={get_contents=function() return {{name='rocket',count=stock}} end,count_empty_stacks=function() return 0 end}
local pl={valid=true,index=1,name='Asterion',force=force,surface=surface,speed=1/3,
  hub={get_inventory=function() return hub end},space_connection={name='aquilo-edge'}}
force.platforms={pl}
local player={force=force}
local leg
local E=require('endurance'){platform=function() return pl end,leg=function() return leg end}
local T=require('turnaround')
local reads=0
local C=require('conditions'){leg=function() return leg end,return_budget=function(p,name,ta)
  reads=reads+1; return E.read(p,{platform=name,turnaround=ta}).return_budget
end}
local function read(ta) return E.read(player,{platform=pl.name,turnaround=ta}) end
for _,back in ipairs{false,true} do
  leg={from=back and 'solar-system-edge' or 'aquilo',to=back and 'aquilo' or 'solar-system-edge',
    back=back,length=100000,left_km=63207,flown=.36793}
  for _,destination in ipairs{false,true} do
    local target=destination and leg.to or leg.from
    local default=read{km=10000,back_to=target,margin=0}
    local explicit=read{km=10000,back_to=target,margin=0,direct=false}
    local direct=read{km=10000,back_to=target,margin=0,direct=true}
    local b,d=default.return_budget,direct.return_budget
    eq(b.back_km,destination and 146793 or 46793)
    eq(b.back_km,explicit.return_budget.back_km)
    eq(b.items[1].out_km_max,explicit.return_budget.items[1].out_km_max)
    eq(b.from,leg.from); eq(b.to,leg.to); eq(b.direction,back and 'back' or 'forward')
    eq(b.remaining_km,63207); eq(b.reverse_km,46793); eq(b.via_origin_km,destination and 100000 or 0)
    eq(b.total_km,b.out_km+b.back_km); eq(default.total_km,b.total_km)
    eq(d.mode,'direct'); eq(d.back_km,destination and 53207 or 46793)
    eq(d.total_km,destination and 63207 or 56793)
    eq(d.reverse_km,destination and 0 or 46793); eq(d.via_origin_km,0)
    eq(d.items[1].left_at_return,math.floor(stock-10*d.total_km/1200+.5))
    if destination then
      eq(b.direct_remaining_km,53207)
      has(b.warning,'back_to is the current destination')
      has(b.line,'direct remaining distance 53207 km')
      eq(#direct.legs,2); eq(direct.legs[2].turn,'direct'); eq(direct.legs[2].to,leg.to)
      eq(d.items[1].out_km_max,66793); eq(d.items[1].spare_km,56793)
      has(d.line,'66793 km advance budget after reserving direct recovery')
      eq(b.items[1].out_km_max,-8396); eq(b.items[1].left_at_return,-307)
      eq(read{fraction=.46793,back_to=target,direct=true,margin=0}.return_budget.back_km,53207)
      eq(read{km=0,back_to=target,direct=true}.return_budget.back_km,63207)
      eq(read{km=63207,back_to=target,direct=true}.return_budget.back_km,0)
    else
      eq(b.warning,nil); eq(d.warning,nil)
      eq(d.items[1].out_km_max,b.items[1].out_km_max)
      eq(d.items[1].left_at_return,b.items[1].left_at_return)
      eq(d.items[1].spare_km,b.items[1].spare_km)
      eq(read{km=10000,direct=true,margin=0}.return_budget.back_km,46793)
    end
    -- Same condition object, same tick: switching direct invalidates cache; evidence is detached.
    local c={['until']='budget_below',platform=pl.name,km=5000,turnaround={km=10000,back_to=target,margin=0}}
    C.validate(c)
    local before=reads
    local met,saw=C.check(player,c)
    eq(met,destination); eq(reads,before+1)
    local evidence=c.evidence
    if destination then
      eq(evidence.return_budget.back_km,146793); has(saw,b.warning)
      eq(evidence.return_budget.direction,b.direction)
    end
    C.check(player,c); eq(reads,before+1)
    c.turnaround.direct=true; C.validate(c)
    eq(C.check(player,c),false); eq(reads,before+2); eq(c.evidence,nil)
    c.km=100000
    eq(C.check(player,c),true); eq(reads,before+2)
    eq(c.evidence.return_budget.back_km,d.back_km)
    if evidence then eq(evidence.return_budget.mode,'turnaround') end
  end
end
-- Independent arithmetic, including a deficit, margin/reserve, zero recovery and maker/unselected behavior.
local item={name='rocket',stock=1000,made=0,used=10,made10=0,used10=10}
local o={v=1200,flown_km=36793,back_km=0,out_km=10000,direct_remaining_km=53207,margin=.5,reserve=100}
local r=E.return_budget({item},o)[1]
eq(r.out_km_max,18793); eq(r.spare_km,8793); eq(r.left_at_return,473)
o.reserve=500; r=E.return_budget({item},o)[1]; assert(r.spare_km<0)
o.direct_remaining_km=0; eq(E.return_budget({item},o)[1].out_km_max,40000)
o.selected={}; eq(select(2,E.return_budget({item},o)),nil)
item.made=10; item.made10=10; eq(E.return_budget({item},o)[1].not_used,true)
-- Window budgets use the same geometry and guard evidence retains all distance components.
stock=100
local c={['until']='budget_below',platform=pl.name,km=5000,windows={60},missing='pending',
  turnaround={km=10000,back_to=leg.to,direct=true,margin=0}}
local segment={kind='leg',from=leg.from,to=leg.to,back=leg.back,start=game.tick-10000}
local EW=require('endurance'){platform=function() return pl end,leg=function() return leg end,
  segments=function() return {segment} end}
local CW=require('conditions'){leg=function() return leg end,segments=function() return {segment} end,
  return_budget=function(p,name,ta) return EW.read(p,{platform=name,turnaround=ta}).return_budget end}
CW.validate(c); eq(CW.check(player,c),true)
eq(c.evidence.return_budget.back_km,53207); eq(c.evidence.window_check.met,true)
eq(c.evidence.return_budget.window_budgets.budgets[1].items[1].out_km_max,-41207)
fails(function() T.check{km=0,direct='true'} end,'direct is true or false')
fails(function() T.check{km=0,direct=true,return_allowance={}} end,'cannot use return_allowance')
fails(function() read{km=0,back_to='shattered-planet',direct=true} end,'origin or destination')
fails(function() read{km=63208,back_to=leg.to,direct=true} end,'is past')
fails(function() read{fraction=.3,back_to=leg.to,direct=true} end,'behind the ship')
print('d37_batch438: both directions/endpoints, Astra numbers, legacy/default/direct, budgets, cache, evidence, windows and validation: ok')
