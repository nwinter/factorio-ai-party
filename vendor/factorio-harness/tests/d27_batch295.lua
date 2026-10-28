-- d27 batch295. Run from the harness root: lua tests/d27_batch295.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path

-- HS (Astra #2646: Resolute's gun at (16,-52) starved twice; inspect left the hand size out with no override, and agents
-- read hand 1 from held 1 where research made a fast inserter's hand 3). On 2.0.77 (the iMac copy of world n, d27
-- 21:20): hand size = 1 + the prototype's inserter_stack_size_bonus (stack-inserter 4) + the force's
-- bulk_inserter_capacity_bonus (bulk-inserter, stack-inserter) or inserter_stack_size_bonus (the others), capped by an
-- override above 0; quality changes none of it; inserter_target_pickup_count reads the result.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x,m) assert(tostring(s):find(x,1,true),(m or '')..' '..tostring(s)..' lacks '..x) end
local function lacks(s,x,m) assert(not tostring(s):find(x,1,true),(m or '')..' '..tostring(s)..' has '..x) end
local ROT={['burner-inserter']=0.013,inserter=0.014,['long-handed-inserter']=0.02,['fast-inserter']=0.04,['bulk-inserter']=0.04,['stack-inserter']=0.04}
local QROT={normal=1,legendary=2.5}
local function proto(name)
  return {name=name,inserter_stack_size_bonus=name=='stack-inserter' and 4 or 0,bulk=name=='bulk-inserter' or name=='stack-inserter',
    uses_inserter_stack_size_bonus=true,get_inserter_rotation_speed=function(q) return ROT[name]*QROT[q] end}
end
local researched={inserter_stack_size_bonus=2,bulk_inserter_capacity_bonus=11}
local none={inserter_stack_size_bonus=0,bulk_inserter_capacity_bonus=0}
-- a built inserter as the engine reads it: inserter_target_pickup_count = the most, capped by an override above 0
local function ins(name,force,o)
  o=o or {}
  local p=proto(name)
  local kind=p.bulk and 'bulk_inserter_capacity_bonus' or 'inserter_stack_size_bonus'
  local most=1+p.inserter_stack_size_bonus+force[kind]
  local ov=o.override or 0
  local e={valid=true,type='inserter',name=name,prototype=p,force=force,position={x=16.5,y=-53.5},quality={name=o.quality or 'normal'},
    inserter_stack_size_override=ov,inserter_target_pickup_count=ov>0 and math.min(ov,most) or most,
    held_stack={valid_for_read=(o.held or 0)>0,count=o.held or 0,name='firearm-magazine'}}
  e.get_control_behavior=function() return o.circuit and {circuit_set_stack_size=true} or nil end
  return e
end
local D=dofile('mod/agent-harness_0.1.0/details.lua'){}

-- each type, without and with the research, and the override
do
  local want={['burner-inserter']={1,3},inserter={1,3},['long-handed-inserter']={1,3},['fast-inserter']={1,3},['bulk-inserter']={1,12},['stack-inserter']={5,16}}
  for name,w in pairs(want) do
    local a,b=D.hand(ins(name,none)),D.hand(ins(name,researched))
    eq(a.effective_hand_size,w[1],name..' without research'); eq(a.hand_size_max,w[1]); eq(a.hand_size_override,0)
    eq(b.effective_hand_size,w[2],name..' with research'); eq(b.hand_size_max,w[2])
    eq(b.capacity_bonus.name,(name=='bulk-inserter' or name=='stack-inserter') and 'bulk_inserter_capacity_bonus' or 'inserter_stack_size_bonus')
    eq(b.capacity_bonus.force,(name=='bulk-inserter' or name=='stack-inserter') and 11 or 2)
    eq(b.capacity_bonus.prototype,name=='stack-inserter' and 4 or 0)
    eq(b.wait_for_full_hand,name=='stack-inserter',name..' waits')
    local c=D.hand(ins(name,researched,{override=1}))
    eq(c.effective_hand_size,1,name..' override 1'); eq(c.hand_size_override,1); eq(c.hand_size_max,w[2])
  end
  -- Astra's two fast inserters at (16,-52): no override reads 3 (before: no hand size at all), override 1 reads 1
  local f=D.hand(ins('fast-inserter',researched))
  eq(f.hand_line,"hand size 3 (its most, 3: 1 + the force's inserter_stack_size_bonus 2; no override: hand_size_override 0); holds 0; from a chest or machine swings with what it took; from a belt waits for a full hand; 144 arm turns a minute (a swing each), at most 432 items a minute at this hand")
  eq(f.short,'hand size 3 (no override; most 3)')
  eq(f.swings_per_min,144); eq(f.items_per_min_most,432)
  local o=D.hand(ins('fast-inserter',researched,{override=1,held=1}))
  has(o.hand_line,"hand size 1 (hand_size_override 1; its most without it 3: 1 + the force's inserter_stack_size_bonus 2); holds 1")
  eq(o.short,'hand size 1 (override 1; most 3)'); eq(o.held_count,1,'held apart from the hand size'); eq(o.items_per_min_most,144)
  -- held 1 of a hand of 3: the two stay apart
  local h=D.hand(ins('fast-inserter',researched,{held=1}))
  eq(h.held_count,1); eq(h.effective_hand_size,3)
  -- an override above its most: kept as set, the most applies
  local over=D.hand(ins('fast-inserter',researched,{override=5}))
  eq(over.effective_hand_size,3); eq(over.hand_size_override,5)
  has(over.hand_line,"hand size 3 (its most, 3: 1 + the force's inserter_stack_size_bonus 2; hand_size_override 5, above it)")
  -- the stack inserter: its prototype's 4, and it waits for a full hand
  local s=D.hand(ins('stack-inserter',researched))
  has(s.hand_line,"hand size 16 (its most, 16: 1 + its prototype's 4 + the force's bulk_inserter_capacity_bonus 11; no override")
  has(s.hand_line,'; waits for a full hand'); eq(s.short,'hand size 16 (no override; most 16), waits for a full hand')
  -- a circuit's set stack size writes the override
  local c=D.hand(ins('bulk-inserter',researched,{override=7,circuit=true}))
  eq(c.effective_hand_size,7); eq(c.hand_size_by_circuit,true)
  has(c.hand_line,"hand_size_override 7, written by its circuit's set stack size (1 with no signal)")
  -- quality: the same hand, faster arm turns
  local l=D.hand(ins('fast-inserter',researched,{quality='legendary'}))
  eq(l.effective_hand_size,3); eq(l.swings_per_min,360); eq(l.items_per_min_most,1080)
  print('d27_batch295 HS hand size per type, research, override, circuit and quality: ok')
end

-- a ghost: computed from its prototype and the force (no engine count), no held count
do
  local p=proto('fast-inserter')
  local g={valid=true,type='entity-ghost',ghost_type='inserter',ghost_name='fast-inserter',ghost_prototype=p,force=researched,
    position={x=1.5,y=2.5},quality={name='normal'},inserter_stack_size_override=2}
  local h=D.hand(g)
  eq(h.effective_hand_size,2); eq(h.hand_size_max,3); eq(h.held_count,nil)
  lacks(h.hand_line,'holds')
  local g0={valid=true,type='entity-ghost',ghost_type='inserter',ghost_name='fast-inserter',ghost_prototype=p,force=researched,position={x=1.5,y=2.5},quality={name='normal'},inserter_stack_size_override=0}
  eq(D.hand(g0).effective_hand_size,3)
  eq(D.hand({valid=true,type='container',name='steel-chest'}),nil,'not an inserter')
  eq(D.hand({valid=true,type='entity-ghost',ghost_type='container',ghost_name='steel-chest'}),nil,'a chest ghost')
  print('d27_batch295 HS ghosts: ok')
end

-- platform_defense's feed (ammofeed.lua): each feeder's hand size and the most it moves beside the turret's use
do
  defines={inventory={turret_ammo=1,hub_main=2,chest=3},entity_status={disabled_by_control_behavior=99}}
  prototypes={item={['firearm-magazine']={type='ammo',ammo_category='bullet'}}}
  local function contents(t) local out={} for name,c in pairs(t) do out[#out+1]={name=name,count=c} end return out end
  local function inv(t) return {get_contents=function() return contents(t) end} end
  local turret={valid=true,unit_number=100,type='ammo-turret',name='gun-turret',position={x=16,y=-52},prototype={attack_parameters={ammo_categories={'bullet'}}}}
  turret.get_inventory=function() return inv({['firearm-magazine']=2}) end
  local hub={valid=true,unit_number=200,type='space-platform-hub',name='space-platform-hub',position={x=0,y=0}}
  hub.get_inventory=function() return inv({['firearm-magazine']=300}) end
  local a=ins('fast-inserter',researched); a.unit_number=301; a.position={x=15.5,y=-53.5}; a.drop_target=turret; a.pickup_target=hub; a.inserter_stack_size_override=1; a.inserter_target_pickup_count=1
  local b=ins('fast-inserter',researched); b.unit_number=302; b.position={x=16.5,y=-53.5}; b.drop_target=turret; b.pickup_target=hub
  local surface={find_entities_filtered=function(f)
    local t=type(f.type)=='table' and f.type[1] or f.type
    if t=='inserter' then return {a,b} end
    if t=='ammo-turret' then return {turret} end
    return {}
  end}
  local pl={surface=surface,force=researched,hub=hub}
  local F=dofile('mod/agent-harness_0.1.0/ammofeed.lua'){hand=function(e) return D.hand(e) end}
  local tr=F.trace(pl)
  local row=tr.rows[1]
  eq(#row.feeders,2)
  eq(row.feeders[1].effective_hand_size,1); eq(row.feeders[1].hand_size_override,1); eq(row.feeders[1].hand_size_max,3); eq(row.feeders[1].items_per_min_most,144)
  eq(row.feeders[2].effective_hand_size,3); eq(row.feeders[2].hand_size_override,0); eq(row.feeders[2].items_per_min_most,432)
  eq(row.feeders[2].wait_for_full_hand,false); eq(row.feeders[2].held_count,0)
  has(row.ways[1],'fast-inserter (15.5,-53.5) hand size 1 (override 1; most 3), at most 144/min from the hub')
  row.uses_per_min=150; row.uses_ammo='firearm-magazine'
  local lines=F.lines(tr,true)
  local line
  for _,l in ipairs(lines) do if l:find('^gun%-turret %(16,%-52%)') then line=l end end
  has(line,'gun-turret (16,-52): holds 2 (uses 150 firearm-magazine/min at full fire, its feeders move at most 576/min); 302 reach it')
  -- without the helper (an older api): the ways and lines as before
  local F0=dofile('mod/agent-harness_0.1.0/ammofeed.lua'){}
  local tr0=F0.trace(pl)
  eq(tr0.rows[1].feeders,nil)
  has(tr0.rows[1].ways[1],'fast-inserter (15.5,-53.5) from the hub')
  for _,l in ipairs(F0.lines(tr0,true)) do lacks(l,'hand size') end
  defines,prototypes=nil,nil
  print('d27_batch295 HS platform_defense feed: ok')
end
