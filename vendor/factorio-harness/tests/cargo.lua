-- Run from repository root: lua tests/cargo.lua
-- Rocket cargo weighed before staging (cargo.lua): weights in grams as the
-- 2.0 prototypes give them (the shift world's 2.0.77: iron plate 1000,
-- processing unit 3333.33, foundation 20000, thruster 200000, cargo bay
-- 100000, starter pack 1000000; a rocket lifts 1000000 and has 20 slots).
local function eq(a, b, m) assert(a == b, (m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
package.path = 'mod/agent-harness_0.1.0/?.lua;'..package.path
defines = {inventory={rocket_silo_rocket=11}}
prototypes = {utility_constants={rocket_lift_weight=1000000}, item={
  ['iron-plate']={weight=1000, stack_size=100},
  ['processing-unit']={weight=3333.3333282471, stack_size=100},
  ['space-platform-foundation']={weight=20000, stack_size=100},
  thruster={weight=200000, stack_size=10},
  ['cargo-bay']={weight=100000, stack_size=10},
  ['space-platform-starter-pack']={weight=1000000, stack_size=1},
  ['heavy-thing']={weight=1500000, stack_size=1},
  ['repair-pack']={weight=10, stack_size=1},
}, entity={['rocket-silo']={get_inventory_size=function(i) eq(i, 11); return 20 end}}}
local cargo = dofile('mod/agent-harness_0.1.0/cargo.lua'){}
local lift, slots = cargo.limits(nil)
eq(lift, 1000000); eq(slots, 20)
eq(select(2, cargo.limits({get_inventory=function(i) eq(i, 11); return {1, 2, 3, 4, 5, 6, 7, 8} end})), 8, 'a silo\'s own rocket')

-- Sol's case: three kits that fit in two rockets.
local out = cargo.weigh({{name='thruster', count=2}, {name='cargo-bay', count=4}, {name='space-platform-foundation', count=30},
  {name='processing-unit', count=150}}, lift, slots)
eq(out.total_kg, 400+400+600+500); eq(out.fewest, 2); eq(out.rockets, 2)
eq(out.items[1].name, 'space-platform-foundation'); eq(out.items[1].kg, 600); eq(out.items[1].each_kg, 20); eq(out.items[1].per_rocket, 50)
eq(out.items[1].share, '60%')
local pu
for _, r in ipairs(out.items) do if r.name == 'processing-unit' then pu = r end end
eq(pu.per_rocket, 300); eq(pu.each_kg, 3.3); eq(pu.kg, 500)
for _, r in ipairs(out.split) do assert(r.kg <= 1000 and r.slots <= 20, r.items) end
eq(out.split[1].items, 'thruster*2 cargo-bay*4 space-platform-foundation*10', 'heaviest first, each into the first rocket with room')
eq(out.split[2].kg, 900); eq(out.lift, '1000 kg and 20 cargo slots a rocket'); eq(out.note, nil)

-- Slots bind before weight: 25 kinds of a light item each need a slot of their own.
local light = {}
for i = 1, 25 do
  prototypes.item['light-'..i] = {weight=100, stack_size=50}
  light[i] = {name='light-'..i, count=10}
end
local l = cargo.weigh(light, lift, slots)
eq(l.total_kg, 25); eq(l.stacks, 25); eq(l.fewest, 2, 'by stacks'); eq(l.rockets, 2); eq(l.split[1].slots, 20); eq(l.split[2].slots, 5)

-- Quality stacks are kinds of their own; a part stack's room is used before a new slot.
local q = cargo.weigh({{name='iron-plate', count=150}, {name='iron-plate', count=50, quality='rare'}, {name='iron-plate', count=50}}, lift, slots)
eq(#q.items, 2); eq(q.items[1].count, 200); eq(q.items[1].stacks, 2); eq(q.items[2].quality, 'rare'); eq(q.stacks, 3)

-- Exactly a rocket's lift fits; past it does not.
local one = cargo.weigh({{name='space-platform-starter-pack', count=3}}, lift, slots)
eq(one.rockets, 3); eq(one.items[1].per_rocket, 1); eq(one.fewest, 3)
local heavy = cargo.weigh({{name='heavy-thing', count=1}, {name='iron-plate', count=10}}, lift, slots)
eq(heavy.rockets, nil); eq(heavy.split, nil); assert(heavy.too_heavy[1]:find('heavy-thing weighs 1500 kg, over a rocket\'s 1000 kg', 1, true), heavy.too_heavy[1])

-- A split above the bound says so: 21 single-item stacks of a 1-per-stack item fit by weight but take two rockets of slots.
local packs = cargo.weigh({{name='repair-pack', count=21}}, lift, slots)
eq(packs.fewest, 2); eq(packs.rockets, 2)
local ok, err = pcall(cargo.weigh, {{name='nope', count=1}}, lift, slots)
assert(not ok and tostring(err):find('unknown item nope', 1, true), err)
-- Cargo pods from a platform hub (space.lua drop): slots alone, no weight
-- limit, the list's order kept (Astra's 10:12 Gleba kit, shift09: it went
-- down in three drops of 10 slots each).
local kitp = {['stone-brick']=100, ['assembling-machine-2']=50, ['steel-plate']=100, ['electric-engine-unit']=50, ['processing-unit']=100,
  pipe=100, ['low-density-structure']=50, ['rocket-fuel']=10}
for name, st in pairs(kitp) do prototypes.item[name] = prototypes.item[name] or {weight=1000, stack_size=st} end
local gleba = cargo.pods({{name='stone-brick', count=500}, {name='assembling-machine-2', count=1}, {name='steel-plate', count=1000},
  {name='electric-engine-unit', count=200}, {name='processing-unit', count=250}, {name='pipe', count=100}, {name='low-density-structure', count=50},
  {name='rocket-fuel', count=50}}, 10)
eq(gleba.stacks, 30); eq(gleba.fewest, 3); eq(#gleba.pods, 3)
eq(gleba.pods[1].text, 'stone-brick*500 assembling-machine-2*1 steel-plate*400'); eq(gleba.pods[1].slots, 10)
eq(gleba.pods[2].text, 'steel-plate*600 electric-engine-unit*200'); eq(gleba.pods[3].text, 'processing-unit*250 pipe*100 low-density-structure*50 rocket-fuel*50')
eq(gleba.pods[3].items[1].name, 'processing-unit'); eq(gleba.pods[3].items[1].quality, 'normal'); eq(gleba.pods[3].items[1].count, 250)
-- No weight limit: 3 starter packs (a rocket each) share a pod.
eq(#cargo.pods({{name='space-platform-starter-pack', count=3}}, 10).pods, 1)
-- A part stack is topped up before a new slot; qualities are kinds of their own.
local mixed = cargo.pods({{name='iron-plate', count=950}, {name='iron-plate', count=60, quality='rare'}, {name='iron-plate', count=40}}, 10)
eq(#mixed.pods, 2); eq(mixed.pods[1].text, 'iron-plate*990', 'the repeated entry joins its kind: 10 slots')
eq(mixed.pods[2].text, 'iron-plate@rare*60'); eq(mixed.pods[2].items[1].quality, 'rare')
-- 990 and then 5 more of the same: the part stack (90) takes them, no new slot.
eq(#cargo.pods({{name='iron-plate', count=995}}, 10).pods, 1)
print('cargo: ok')
