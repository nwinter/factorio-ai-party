-- Run from repository root: lua tests/d28_batch313.lua
-- (d28 batch313 HB, viewer Aurora site:5364) rates rows are full-speed figures (the Rate Calculator's): on Fulgora at
-- tick 77275952 `rates {surface: fulgora, item: copper-plate}` read a row copper-plate produced 1027 consumed 450 (10
-- recyclers set to recipes making it) beside the game's statistics made 0/min, used 110.1/min; Haiku and then Astra took
-- the row for what was made. Each reply now says what the rows are (rows_are), each row how many of its machines work
-- now (working), and rates {item} sets the full-speed figure beside the statistics in one line. On main: no rows_are, no
-- working, no line.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
defines={entity_status={working=1,no_power=4,no_ingredients=7},inventory={assembling_machine_input=2,furnace_source=3}}
prototypes={item={coal={name='coal',fuel_value=4e6},['iron-plate']={name='iron-plate'}},fluid={}}
local force={name='player',recipes={},inserter_stack_size_bonus=0,bulk_inserter_capacity_bonus=0,belt_stack_size_bonus=0}
local function none() return nil end
local function fluidbox() return setmetatable({get_filter=none},{__len=function() return 0 end}) end
local plate_recipe={name='iron-plate',energy=3.2,productivity_bonus=0,prototype={maximum_productivity=3},
  ingredients={{type='item',name='iron-ore',amount=1}},products={{type='item',name='iron-plate',amount=1}}}
local function furnace(x,status)
  return {valid=true,name='stone-furnace',type='furnace',position={x=x,y=0},unit_number=10+x,crafting_speed=2,
    productivity_bonus=0,consumption_bonus=0,speed_bonus=0,status=status,fluidbox=fluidbox(),
    prototype={burner_prototype={effectivity=1},get_max_energy_usage=function() return 90000/60 end},
    burner={currently_burning={name=prototypes.item.coal,quality={name='normal'}}},
    get_recipe=function() return plate_recipe,{name='normal'} end}
end
-- three furnaces set to iron plates: one working, two out of ore
local world={furnace(0,1),furnace(3,7),furnace(6,7)}
local surface={find_entities_filtered=function(f)
  local types={}
  for _,t in ipairs(type(f.type)=='table' and f.type or {f.type}) do types[t]=true end
  local out={}
  for _,e in ipairs(world) do if types[e.type] then out[#out+1]=e end end
  return out
end}
local p={force=force,surface=surface}
local R=dofile('mod/agent-harness_0.1.0/rates.lua'){position=function(v) return v end,status_name=function() return 'working' end}
local r=R.rates(p,{area={left_top={x=-10,y=-10},right_bottom={x=20,y=10}}})
local rows={}
for _,row in ipairs(r.rows) do rows[row.item]=row end
-- the figures are as before: 3.2 s at speed 2, three furnaces, 112.5 plates a minute at full speed (113 as rounded)
eq(rows['iron-plate'].produced,113); eq(rows['iron-ore'].consumed,113)
eq(rows['iron-plate'].working,'1 of 3 making it work now'); eq(rows['iron-plate'].basis,'full speed')
eq(rows['iron-ore'].working,'1 of 3 using it work now')
eq(rows.coal.working,'1 of 3 using it work now')
has(r.rows_are,'what these machines would make and use at full speed'); has(r.rows_are,'not what they made')
eq(rows['iron-plate'].max_made,nil,'the kept figures are not replied'); eq(rows['iron-plate'].raw_net,nil)
-- rates {item}: the line, from the row before it is stripped
local c=R.compute(p,world,'minute')
local mine
for _,row in ipairs(c.rows) do if row.item=='iron-plate' then mine={max_made=row.max_made,makers=row.makers,makers_on=row.makers_on} end end
eq(R.item_line('iron-plate','nauvis',mine,37.5,20,'minute'),
  'iron-plate on nauvis: the 3 machines set to recipes making it would make 113/min at full speed (1 of them working now); the game\'s statistics over 10 min: made 37.5/min, used 20/min')
-- Fulgora's case: ten idle makers, made 0
eq(R.item_line('copper-plate','fulgora',{max_made=1027,makers=10,makers_on=0},0,110.1,'minute'),
  'copper-plate on fulgora: the 10 machines set to recipes making it would make 1027/min at full speed (0 of them working now); the game\'s statistics over 10 min: made 0/min, used 110.1/min')
eq(R.item_line('copper-plate','fulgora',nil,0,110.1,'minute'),nil,'no maker: no line')
-- a status not read (an older engine mock): no working field
defines.entity_status.working=nil
eq(R.rates(p,{area={left_top={x=-10,y=-10},right_bottom={x=20,y=10}}}).rows[1].working,nil)
print('d28_batch313 ok')

-- shipment {ledger}: pods_line names the span of the rows shown and their order (Haiku summed pods of two visits, 54 game
-- minutes apart, as one cycle: page 1 of the reply held the oldest rows, and pods_line came after the table)
storage={podlog={seq=4,open={},open_n=0,by={nauvis={
  {id=1,unit=1,up=true,platform='Kestrel IVb',stop='nauvis',sent=76912682,landed=76914711,dest='hub',items={['copper-plate@normal']=500},kind='rocket'},
  {id=2,unit=2,up=true,platform='Kestrel IVb',stop='nauvis',sent=76918966,landed=76920987,dest='hub',items={['copper-plate@normal']=500},kind='rocket'},
  {id=3,unit=3,up=true,platform='Kestrel IVb',stop='nauvis',sent=77101959,landed=77103979,dest='hub',items={['copper-plate@normal']=548},kind='rocket'},
  {id=4,unit=4,up=true,platform='Kestrel IVb',stop='nauvis',sent=77113700,landed=77115718,dest='hub',items={['copper-plate@normal']=500},kind='rocket'}}}}}
game={tick=77145302,surfaces={nauvis={}}}
prototypes.item['copper-plate']={}
local P=dofile('mod/agent-harness_0.1.0/podlog.lua'){state=function() return storage end}
local S=dofile('mod/agent-harness_0.1.0/shipment.lua'){integer=function(v) return v end,podlog=function(f) return P.read(f) end}
local out=S.read({surface={name='nauvis'}},{ledger=true,platform='Kestrel IVb',surface='nauvis',limit=3})
eq(out.pods_line,'4 pod journeys to and from nauvis recorded with Kestrel IVb; the newest 3 here (limit); these sent from tick 76918966 (62m52s ago) to tick 77113700 (8m46s ago), oldest first')
-- an empty delivery_watch list says where pods sent before a watch are kept (Haiku read it as no record of a receipt)
local src=io.open('mod/agent-harness_0.1.0/delivwatch.lua'):read('*a')
assert(src:find('pods sent before it are in shipment {ledger: true, platform, surface}',1,true),'the empty note names the ledger')
print('d28_batch313 ledger span: ok')
