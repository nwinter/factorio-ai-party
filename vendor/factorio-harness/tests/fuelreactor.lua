-- Run from repository root: lua tests/fuelreactor.lua
-- fuel_budget's reactors one by one (d20 batch63 Y1, Astra #1512) against a fake engine. The numbers are 2.0.77's
-- (read on the private copy): a nuclear reactor uses 40 MW, effectivity 1, 10 MJ a degree, 1000 C at most, one fuel
-- and one burnt slot; a uranium fuel cell holds 8 GJ; heat exchangers work from 500 C. Astra's case on world n
-- (tick 40276554): the main reactor at 904 C burning the one cell its circuit lets in, the eastern one at 898 C off
-- by its circuit (a decider: T < 800 and fuel < 1 -> S=1; the inserter enabled by S > 0), requesters holding 11 each.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(text,part) assert(text and tostring(text):find(part,1,true),tostring(text)..' lacks '..part) end
defines={entity_status={disabled_by_control_behavior=7,working=1,no_fuel=2},inventory={chest=1}}
prototypes={item={['uranium-fuel-cell']={fuel_value=8e9,fuel_category='nuclear'},['coal']={fuel_value=4e6,fuel_category='chemical'}},
  entity={['heat-exchanger']={heat_energy_source_prototype={min_working_temperature=500}}}}
local R=dofile('mod/agent-harness_0.1.0/fuelreactor.lua'){status_name=function(e) return e.st end,
  condition_parts=function(ins) return ins.parts end,
  trace=function(ins) return {'red network 3: signal-S 0','  decider-combinator (191.5,-110) output side: signal-T < 800 and uranium-fuel-cell < 1 -> signal-S 1; puts out nothing'} end}

local function inv(t,size)
  local o={t=t or {},size=size or 1}
  function o.get_contents() local r={} for k,v in pairs(o.t) do r[#r+1]={name=k,count=v} end return r end
  function o.get_item_count(n) return o.t[n] or 0 end
  function o.can_insert() local n=0 for _,v in pairs(o.t) do n=n+v end return n<o.size end
  return setmetatable(o,{__len=function() return o.size end})
end
local network={network_id=7,n=0}
function network.get_item_count(item) return item=='uranium-fuel-cell' and network.n or 0 end
local exchangers=1
local surface={}
local REACTORS={}
function surface.find_entities_filtered(f)
  for _,r in ipairs(REACTORS) do
    local p=r.e.position
    if f.area.left_top.x<=p.x and f.area.right_bottom.x>=p.x and f.area.left_top.y<=p.y and f.area.right_bottom.y>=p.y then return r.list end
  end
  return {}
end
function surface.count_entities_filtered() return exchangers end
function surface.find_logistic_network_by_position() return network end
local PROTO={get_max_energy_usage=function() return 40e6/60 end,burner_prototype={effectivity=1,fuel_categories={nuclear=true}},
  heat_buffer_prototype={max_temperature=1000,specific_heat=10e6,min_working_temperature=15}}
local function reactor(t)
  local e={valid=true,name='nuclear-reactor',type='reactor',position=t.position,surface=surface,force={},prototype=PROTO,
    temperature=t.temperature,neighbour_bonus=t.bonus or 0,st=t.status,
    bounding_box={left_top={x=t.position.x-2.5,y=t.position.y-2.5},right_bottom={x=t.position.x+2.5,y=t.position.y+2.5}},
    burner={currently_burning=t.burning and {name='uranium-fuel-cell'} or nil,remaining_burning_fuel=t.burning and t.burning*8e9 or 0,
      inventory=inv(t.slot),burnt_result_inventory=inv(t.burnt)}}
  e.get_control_behavior=function() return {read_fuel=true,read_temperature=true,temperature_signal={type='virtual',name='signal-T'}} end
  local list={}
  for _,fd in ipairs(t.feeders or {}) do
    local chest={valid=true,name='requester-chest',position={x=t.position.x,y=t.position.y-4},logistic_network=network}
    chest.get_output_inventory=function() return inv({['uranium-fuel-cell']=fd.chest},48) end
    list[#list+1]={valid=true,name='fast-inserter',position={x=t.position.x,y=t.position.y-3},drop_target=e,pickup_target=chest,
      held_stack={valid_for_read=false},status=fd.off and 7 or 1,parts=fd.parts}
  end
  REACTORS[#REACTORS+1]={e=e,list=list}
  return e
end
local held='enabled when signal-S > 0 (on its wires: signal-S 0): false now; it is off by its condition'
local open='enabled when signal-S > 0 (on its wires: signal-S 1): true now; it is on'

-- Astra's two: the main one burning (0.4 of a cell left), the eastern one off by its circuit with heat; requesters 11.
network.n=40
local main=reactor{position={x=187.5,y=-104.5},temperature=904,burning=0.4,status='working',feeders={{chest=11,off=true,parts={held}}}}
local east=reactor{position={x=200.5,y=-104.5},temperature=898,status='no_fuel',feeders={{chest=11,off=true,parts={held}}}}
local g=R.group({main,east})
local a,b=g.reactors[1],g.reactors[2]
eq(a.temperature,904); eq(a.burning.item,'uranium-fuel-cell'); eq(a.burning.left,0.4); eq(a.fuel_slots.empty,true)
eq(a.state,'burning, its fuel slot empty')
-- heat above 500 C: 404 * 10 MJ at 40 MW = 1.7 min; the cell's 0.4: 3.2 GJ = 1.3 min; 11 in the requester: 36.7 min
eq(a.minutes.heat,1.7); eq(a.minutes.burning,1.3); eq(a.minutes.feed,36.7); eq(a.minutes_left,39.7)
has(a.minutes.heat_above,'500 C (the heat exchangers')
eq(a.feeders[1].holds_fuel_back,true); has(a.feeders[1].condition,'enabled when signal-S > 0'); has(a.feeders[1].takes_from,'holding 11 uranium-fuel-cell')
has(a.feeders[1].set_by[1],'decider-combinator (191.5,-110)')
has(a.circuit_reads,'its fuel and its temperature as signal-T')
eq(a.feed.in_reach,11); has(a.feed.network,'holds 40 uranium-fuel-cell')
eq(a.emergency,nil)
eq(b.state,'not burning: its feed is held back by its circuit; heat left'); eq(b.burning,nil)
eq(b.minutes.heat,1.7); eq(b.minutes_left,38.3); eq(b.emergency,nil)
has(b.line,'898 C; not burning: its feed is held back by its circuit; heat left')
eq(g.empty_slots,2); eq(g.burning,1); eq(g.held_back,2); eq(g.minutes_left,38.3); eq(g.emergencies,0)
eq(g.network_stock['uranium-fuel-cell'],40)
-- The neighbour bonus: heat goes at the full output with it (two neighbours: 3 times), fuel at its energy use.
local hot=reactor{position={x=300.5,y=0.5},temperature=900,bonus=2,status='no_fuel'}
local r=R.group({hot}).reactors[1]
eq(r.minutes.heat,0.6); eq(r.neighbour_bonus,2)
-- A cell in the slot (a reserve) counts as fuel; a full burnt slot stops it.
local res=reactor{position={x=320.5,y=0.5},temperature=600,slot={['uranium-fuel-cell']=1},burnt={['depleted-uranium-fuel-cell']=1},status='no_fuel'}
r=R.group({res}).reactors[1]
eq(r.state,'stopped: its burnt result slot is full'); eq(r.minutes.slots,3.3); eq(r.burnt.full,true)
-- Cold, slot empty, nothing in reach or the network: no heat and no fuel to be had, the emergency.
network.n=0
local cold=reactor{position={x=340.5,y=0.5},temperature=15,status='no_fuel',feeders={{chest=0,parts={open}}}}
g=R.group({cold})
eq(g.reactors[1].state,'no heat and no fuel to be had'); eq(g.reactors[1].emergency,true); eq(g.emergencies,1); eq(g.minutes_left,0)
-- Cold with cells in the network: fuel to be had, no emergency.
network.n=20
g=R.group({cold})
eq(g.reactors[1].state,'cold, slot empty; fuel to be had'); eq(g.emergencies,0)
-- Cold with no inserter feeding it: idle, no emergency.
network.n=0
g=R.group({reactor{position={x=380.5,y=0.5},temperature=15,status='no_fuel'}})
eq(g.reactors[1].state,'cold and idle: slot empty, no inserter feeds it'); eq(g.emergencies,0); eq(g.minutes_left,nil)
-- beside a fed one, the idle one leaves the group's fewest minutes to it
g=R.group({main,reactor{position={x=390.5,y=0.5},temperature=15,status='no_fuel'}})
eq(g.minutes_left,g.reactors[1].minutes_left)
network.n=20
-- With no heat exchanger near, heat counts above the reactor's own minimum (15 C).
exchangers=0
r=R.group({reactor{position={x=360.5,y=0.5},temperature=515,status='no_fuel'}}).reactors[1]
has(r.minutes.heat_above,'15 C (the reactor'); eq(r.minutes.heat,2.1)
print('fuelreactor ok')
