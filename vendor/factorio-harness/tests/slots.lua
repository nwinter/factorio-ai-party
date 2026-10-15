-- Run from repository root: lua tests/slots.lua
-- Sol, 22:08: requester (48.5,34.5) on Gleba had all 48 slots taken, 494 spoilage among them, so robots could not
-- deliver bioflux. An inventory that takes no more of an item, what fills it, and spoilage in a machine's input.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
defines={inventory={chest=1,assembling_machine_input=2,furnace_source=2,character_main=1}}
local S=dofile('mod/agent-harness_0.1.0/slots.lua')()
-- An inventory of stacks {name, count} (nil: an empty slot); room: whether can_insert takes the item.
local function inv(stacks,size,room)
  local t={}
  for i=1,size do local s=stacks[i]; t[i]=s and {valid_for_read=true,name=s[1],count=s[2]} or {valid_for_read=false} end
  local empty=0
  for i=1,size do if not stacks[i] then empty=empty+1 end end
  t.count_empty_stacks=function() return empty end
  t.can_insert=function(st) return room and room[st.name] or false end
  t.get_item_count=function(name) local n=0 for i=1,size do local s=stacks[i]; if s and s[1]==name then n=n+s[2] end end return n end
  return t
end
-- Every slot taken: what fills them, the most slots first.
local stacks={}
for i=1,10 do stacks[i]={'spoilage',i<10 and 50 or 44} end
for i=11,13 do stacks[i]={'nutrients',100} end
stacks[14]={'bioflux',20}
for i=15,48 do stacks[i]={'jelly',50} end
local full=inv(stacks,48)
local f=S.full(full,'bioflux')
eq(f.text,'all 48 slots taken (jelly 1700 in 34 slots, spoilage 494 in 10 slots, nutrients 300 in 3 slots, bioflux 20 in 1 slot)')
eq(f.spoilage,494); eq(f.spoilage_slots,10); eq(f.slots,48)
-- A partial stack of the item with room: not full for it. A free slot: not full.
eq(S.full(inv(stacks,48,{bioflux=true}),'bioflux'),nil)
stacks[48]=nil
eq(S.full(inv(stacks,48),'bioflux'),nil)
eq(S.full(nil,'x'),nil)
-- More than four kinds: the rest counted; spoilage named when it is not among the four shown.
local many={{'a',1},{'a',1},{'b',1},{'b',1},{'c',1},{'c',1},{'d',1},{'d',1},{'e',1},{'spoilage',7}}
eq(S.full(inv(many,10),nil).text,'all 10 slots taken (a 2 in 2 slots, b 2 in 2 slots, c 2 in 2 slots, d 2 in 2 slots, +2 more items); spoilage 7 in 1 slot among them')
-- The inventory an entity takes into, and full_of.
local chest={type='logistic-container',get_inventory=function(id) eq(id,1); return full end}
eq(S.full_of(chest,'bioflux').spoilage,494)
eq(S.inventory_of({type='pipe'}),nil)
-- A machine's input holding spoilage its recipe does not take.
local input=inv({{'spoilage',50},{'yumako-mash',3}},3)
local chamber={type='assembling-machine',get_inventory=function(id) eq(id,2); return input end,
  get_recipe=function() return {ingredients={{name='yumako-mash',amount=15},{name='jelly',amount=12}}} end}
eq(S.input_spoilage(chamber).text,'input holds spoilage 50 in 1 of its 3 slots (its recipe does not take spoilage)')
chamber.get_recipe=function() return {ingredients={{name='spoilage',amount=10}}} end
eq(S.input_spoilage(chamber),nil,'a recipe that takes spoilage')
eq(S.input_spoilage({type='container'}),nil)
print('slots: ok')
