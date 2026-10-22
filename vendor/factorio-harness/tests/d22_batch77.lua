-- Run from the harness root: lua tests/d22_batch77.lua
-- d22 batch77: AM1 (Sol #1805) assembler_batch at the recipe's quality; AM2 (Astra #1769) fluid_count counts fusion
-- reactors and generators.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,part) assert(type(s)=='string' and s:find(part,1,true),tostring(s)..'\n  lacks: '..part) end

-- AM1: a rare recipe stages, waits for and counts rare items; normal ones held in the requester are said, not counted.
do
  defines={inventory={assembling_machine_input=2,assembling_machine_output=3}}
  prototypes={quality={normal={},uncommon={},rare={},epic={},legendary={},['quality-unknown']={}}}
  local function key(n) if type(n)=='table' then return n.name..'/'..(n.quality or 'normal') end return n..'/normal' end
  local recipe={name='pipe',products={{type='item',name='pipe',amount=1}},ingredients={{type='item',name='iron-plate',amount=1},{type='fluid',name='water',amount=10}}}
  local held={['iron-plate/normal']=30,['iron-plate/rare']=5}
  local made={['pipe/rare']=2,['pipe/epic']=1}
  local m={valid=true,unit_number=1,name='assembling-machine-2',type='assembling-machine',position={x=17.5,y=230.5},
    bounding_box={left_top={x=16,y=229},right_bottom={x=19,y=232}},get_recipe=function() return recipe,{name='rare'} end,
    get_inventory=function(i) if i==3 then return {get_item_count=function(n) return made[key(n)] or 0 end} end end}
  local req={valid=true,unit_number=2,name='requester-chest',position={x=17.5,y=233.5},prototype={logistic_mode='requester'},
    get_item_count=function(n) return held[key(n)] or 0 end,get_requester_point=function() return {trash_not_requested=false} end}
  local input={valid=true,unit_number=3,type='inserter',position={x=17.5,y=232.5},pickup_target=req,drop_target=m}
  local output={valid=true,unit_number=4,type='inserter',position={x=19.5,y=230.5},pickup_target=m}
  m.surface={find_entities_filtered=function() return {input,output} end}
  local B=dofile('mod/agent-harness_0.1.0/batch.lua'){position=function(q) return q end,integer=function(v) return v end,
    entity=function() return m end,submit=function() end}
  local r=B.run({},{position={x=17.5,y=230.5},count=100,dry_run=true})
  eq(r.quality,'rare')
  local by={}
  for _,st in ipairs(r.steps) do by[st.label]=st end
  local set=by.stage.args.set
  eq(#set,1,'water is a fluid: not staged'); eq(set[1].item,'iron-plate'); eq(set[1].quality,'rare'); eq(set[1].min,100,'95 to come, 5 rare held')
  eq(by['staged iron-plate (rare)'].args.quality,'rare'); eq(by['staged iron-plate (rare)'].args.at_least,100)
  eq(by.made.args.quality,'rare'); eq(by.made.args.at_least,102,'the 2 rare pipes held, not the epic one')
  eq(r.other_quality[1],'30 normal iron-plate')
  has(table.concat(r.plan,'\n'),'iron-plate (rare): 100 for 100 crafts, the machine holds 0, the requester 5: 95 to come')
  has(table.concat(r.plan,'\n'),'the requester (17.5,233.5) also holds 30 normal iron-plate: the machine takes only rare quality')
  -- quality modules: the products come out at rare or above, so the made wait counts every quality
  m.effects={quality=2.5}
  r=B.run({},{position={x=17.5,y=230.5},count=100,dry_run=true})
  for _,st in ipairs(r.steps) do by[st.label]=st end
  eq(by.made.args.quality,'any'); eq(by.made.args.at_least,103)
  eq(by.stage.args.set[1].quality,'rare')
  -- a normal recipe: no quality argument anywhere, as before
  m.effects=nil
  m.get_recipe=function() return recipe,{name='normal'} end
  r=B.run({},{position={x=17.5,y=230.5},count=40,dry_run=true})
  by={}
  for _,st in ipairs(r.steps) do by[st.label]=st end
  eq(by.stage.args.set[1].quality,nil); eq(by.stage.args.set[1].min,40,'10 to come, 30 normal held')
  eq(by['staged iron-plate'].args.quality,nil); eq(by.made.args.quality,nil); eq(by.made.args.at_least,40)
  eq(r.other_quality[1],'5 rare iron-plate')
  defines,prototypes=nil,nil
end
print('d22_batch77 AM1 assembler_batch at the recipe quality: ok')

-- AM2: fluid_count on a platform counts the fusion reactors' and generators' fluidboxes, each kind said; the type filter
-- names them.
do
  defines={inventory={hub_main=1}}
  prototypes={fluid={['fluoroketone-cold']={},['fusion-plasma']={}}}
  game={tick=0}
  local function e(t,n) return {type=t,valid=true,get_fluid_count=function(f) return n[f] or 0 end} end
  local ents={e('pipe',{['fluoroketone-cold']=150}),e('fusion-reactor',{['fluoroketone-cold']=1000,['fusion-plasma']=10}),
    e('fusion-reactor',{['fluoroketone-cold']=1000,['fusion-plasma']=10}),e('fusion-generator',{['fusion-plasma']=10})}
  local types
  local pl={valid=true,name='Asterion',surface={find_entities_filtered=function(f) types=f.type; return ents end}}
  local p={force={platforms={pl}}}
  local C=dofile('mod/agent-harness_0.1.0/conditions.lua'){}
  local cond={['until']='fluid_count',platform='Asterion',fluid='fluoroketone-cold',at_least=2100}
  C.validate(cond)
  local met,saw=C.check(p,cond)
  eq(met,true); eq(saw,'fluoroketone-cold 2150 on Asterion: pipes 150 (1), fusion reactors and generators 2000 (2)')
  local want={}
  for _,t in ipairs(types) do want[t]=true end
  assert(want['fusion-reactor'] and want['fusion-generator'] and want.boiler and want.generator,'the type filter')
  met,saw=C.check(p,{['until']='fluid_count',platform='Asterion',fluid='fusion-plasma',at_least=30})
  eq(met,true); eq(saw,'fusion-plasma 30 on Asterion: fusion reactors and generators 30 (3)')
  defines,prototypes,game=nil,nil,nil
end
print('d22_batch77 AM2 fluid_count counts fusion reactors and generators: ok')
