-- d22 batch91. BA1 (Sol #1881): silo and shipment read a request's quality. Meridian-V asked thruster@legendary 4 from
-- Vulcanus while 4 legendary sat in storage, and silo/shipment read "holds 0" and "the network can give 0": 2.0.77's
-- get_item_count(name) counts normal quality alone (on a copy of world n: Meridian-V's hub 2 solar-panel by name and 4
-- epic; network 22 0 accumulator by name and 12 epic). Fakes count that way.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end

do
  defines={inventory={hub_main=1,rocket_silo_rocket=11},logistic_member_index={}}
  prototypes={utility_constants={rocket_lift_weight=1000000},
    item={thruster={weight=200000,stack_size=10},accumulator={weight=20000,stack_size=50}},
    quality={normal={level=0},uncommon={level=1},rare={level=2},epic={level=3},legendary={level=5},['quality-unknown']={level=0}}}
  game={tick=1000}
  -- counts by name and quality; a plain name is normal, as 2.0.77 counts it
  local function counter(t)
    return function(id, member)
      local name, q = id, 'normal'
      if type(id) == 'table' then name, q = id.name, id.quality or 'normal' end
      local by = t[member or 'all'] or t
      return (by[name .. '@' .. q] or 0)
    end
  end
  local hub_items = {}
  local function hub(filters)
    return {valid=true,get_item_count=counter(hub_items),get_inventory=function() return {count_empty_stacks=function() return 30 end} end,
      get_logistic_sections=function() return {sections_count=1,get_section=function() return {active=true,filters=filters} end} end}
  end
  local filters = {{value={name='thruster',quality='legendary',comparator='='},min=4,import_from='vulcanus',minimum_delivery_count=1}}
  local force = {name='player'}
  local pl = {valid=true,name='Meridian-V',space_location={name='vulcanus'},hub=hub(filters),force=force}
  force.platforms = {pl}
  local stock = {all={['thruster@legendary']=4,['thruster@normal']=0,['thruster@rare']=2},storage={['thruster@legendary']=4,['thruster@rare']=2},providers={}}
  local net = {network_id=22,get_item_count=counter(stock)}
  local vulcanus = {name='vulcanus',planet={name='vulcanus'},find_logistic_network_by_position=function() return net end}
  force.logistic_networks = {vulcanus={net}}
  local silo = {valid=true,name='rocket-silo',surface=vulcanus,position={x=15,y=141},force=force}
  local S = dofile('mod/agent-harness_0.1.0/silo.lua'){state=function() return {} end}
  -- the legendary request: 0 held, 4 legendary in storage: matched (the old read: holds 0 by name, network 0)
  local rows = S.request_rows(silo, force)
  eq(#rows, 1); local r = rows[1]
  eq(r.quality, 'legendary'); eq(r.comparator, '='); eq(r.custom_minimum, 1); eq(r.holds, 0)
  eq(r.network_holds, 4); eq(r.storage, 4); eq(r.providers, 0); eq(r.flag, 'matched')
  has(r.line, 'matched: Meridian-V asks thruster (legendary) 4 (holds 0, lacks 4), min payload 1 (its custom minimum), the silo\'s network can give 4 now (provider chests 0, storage chests 4')
  -- the hub holds 4 legendary: delivered, no row; 4 normal ones do not count for it
  hub_items['thruster@normal'] = 4
  eq(#S.request_rows(silo, force), 1, 'normal thrusters do not meet a legendary request')
  hub_items['thruster@legendary'] = 4
  eq(#S.request_rows(silo, force), 0)
  hub_items['thruster@legendary'], hub_items['thruster@normal'] = nil, nil
  -- a comparator: ">= rare" takes rare and legendary (2 + 4), not normal
  filters[1].value = {name='thruster',quality='rare',comparator='≥'}
  r = S.request_rows(silo, force)[1]
  eq(r.comparator, '>='); eq(r.network_holds, 6)
  has(r.line, 'Meridian-V asks thruster (>= rare) 4 (holds 0, lacks 4)')
  -- a normal request reads as before
  filters[1].value = {name='thruster'}
  stock.all['thruster@normal'] = 9
  r = S.request_rows(silo, force)[1]
  eq(r.quality, 'normal'); eq(r.network_holds, 9)
  has(r.line, 'matched: Meridian-V asks thruster 4 (holds 0, lacks 4)')

  -- shipment: the up row by quality, its hub count, the silo the game picked
  filters[1].value = {name='thruster',quality='legendary',comparator='='}
  local rocket = {}
  silo.use_transitional_requests = true
  silo.get_inventory = function() return {get_contents=function() return rocket end} end
  silo.get_logistic_point = function() return {} end
  game.planets = {vulcanus={surface=vulcanus}}
  vulcanus.index = 3
  local st = {}
  local SH = dofile('mod/agent-harness_0.1.0/shipment.lua'){state=function() return st end,
    census_typed=function() return {silo} end,
    hub_counts=function(p, q) if q then return {['thruster@normal']=6} end return {thruster=6} end,
    where=function() return {stopped=true, at='vulcanus'} end,
    request_rows=function(e, f, only) return S.request_rows(e, f, nil, only) end}
  pl.schedule = {current=1, records={{station='vulcanus'}}}
  silo.type = 'rocket-silo'
  local lines, srows = SH.platform(pl, {}, nil, true)
  local up = srows[1]
  eq(up.item, 'thruster'); eq(up.quality, 'legendary'); eq(up.comparator, '='); eq(up.custom_minimum, 1)
  eq(up.hub, 0, 'the hub\'s 6 normal thrusters are not legendary')
  eq(up.state, 'waiting')
  has(up.line, 'thruster (legendary) 4 from vulcanus: waiting (the hub holds 0): matched at rocket-silo (15,141): Meridian-V asks thruster (legendary) 4')
  has(up.line, 'the game\'s pick: no silo on vulcanus is filling a rocket for Meridian-V now')
  -- the game takes Meridian-V up: that silo is named; legendary in its rocket: loading
  silo.transitional_request_target = {valid=true, name='Meridian-V'}
  rocket = {{name='thruster', quality='legendary', count=2}}
  lines, srows = SH.platform(pl, {}, nil, true)
  up = srows[1]
  eq(up.state, 'loading'); eq(up.picked_silo.position.x, 15)
  has(up.line, 'thruster (legendary) 4 from vulcanus: loading (rocket-silo at (15,141): 2 in its rocket, automatic requests for this platform; the hub holds 0)')
  -- normal ones in its rocket are not this request's
  rocket = {{name='thruster', quality='normal', count=2}}
  lines, srows = SH.platform(pl, {}, nil, true)
  eq(srows[1].state, 'waiting')
  has(srows[1].line, 'the game\'s pick: rocket-silo at (15,141) is filling a rocket for Meridian-V now')
  defines, prototypes, game = nil, nil, nil
end
print('d22_batch91 BA1 silo and shipment by quality: ok')
