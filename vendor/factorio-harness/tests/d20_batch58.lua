-- Run from repository root: lua tests/d20_batch58.lua
-- d20 batch58: uptime and quality. T1 (Sol #1453): a recipe's item ingredients counted at its quality.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end

-- An inventory as 2.0.77 counts it: by name, normal quality only; {name, quality} that quality.
local function inventory(stacks)
  return {get_item_count=function(id)
    local name,q=id,'normal'
    if type(id)=='table' then name,q=id.name,id.quality or 'normal' end
    local n=0
    for _,st in ipairs(stacks) do if st.name==name and st.quality==q then n=n+st.count end end
    return n
  end,get_contents=function() return stacks end}
end

-- T1: Sol's EM plant (28,166) on rare quality-module-3, holding rare advanced circuits 12, processing units 10,
-- superconductors 4 and rare quality-module-2 3 of the 4 a craft: only the module is short, named rare.
do
  game={tick=1000}
  defines={inventory={assembling_machine_input=2,furnace_source=2,assembling_machine_output=3,furnace_result=3}}
  local recipe={name='quality-module-3',ingredients={{type='item',name='advanced-circuit',amount=5},{type='item',name='processing-unit',amount=5},
    {type='item',name='superconductor',amount=1},{type='item',name='quality-module-2',amount=4}}}
  local held={{name='advanced-circuit',quality='rare',count=12},{name='processing-unit',quality='rare',count=10},{name='superconductor',quality='rare',count=4},
    {name='quality-module-2',quality='rare',count=3}}
  local m={valid=true,name='electromagnetic-plant',type='assembling-machine',position={x=28,y=166},products_finished=50,status='item_ingredient_shortage',
    get_recipe=function() return recipe,{name='rare'} end,get_inventory=function(i) return inventory(i==2 and held or {}) end}
  local st={}
  local U=dofile('mod/agent-harness_0.1.0/uptime.lua'){state=function() return st end,remote_entity=function() return m end,
    status_name=function(e) return e.status end,craftrate=function() return {crafts_per_min=1.5,productivity=0.5} end}
  local start=U.handler({index=1},{position={x=28,y=166},seconds=10})
  eq(start.baseline[1],'electromagnetic-plant (28,166) quality-module-3 (rare): 50 completions so far (the game\'s count, productivity\'s included)')
  for t=1001,1600 do game.tick=t; U.tick(t) end
  local row=U.handler({index=1},{}).machines[1]
  eq(row.recipe,'quality-module-3'); eq(row.recipe_quality,'rare')
  eq(#row.short,1); eq(row.short[1],'quality-module-2 (rare) short in 11 samples (least 3 of 4 a craft)')
  assert(row.line:find('electromagnetic-plant (28,166) quality-module-3 (rare): ',1,true),row.line)
  -- a normal recipe reads as before, its quality normal, and a fluid ingredient has no quality
  recipe.ingredients[#recipe.ingredients+1]={type='fluid',name='electrolyte',amount=10}
  m.get_fluid_count=function() return 4 end
  held={{name='advanced-circuit',quality='normal',count=12}}
  m.get_recipe=function() return recipe end
  U.handler({index=1},{position={x=28,y=166},seconds=10})
  for t=1601,2200 do game.tick=t; U.tick(t) end
  row=U.handler({index=1},{}).machines[1]
  eq(row.recipe_quality,'normal'); assert(row.line:find('electromagnetic-plant (28,166) quality-module-3: ',1,true),row.line)
  local shorts=table.concat(row.short,'; ')
  assert(not shorts:find('advanced-circuit',1,true),shorts)
  assert(shorts:find('electrolyte short in 11 samples (least 4 of 10 a craft)',1,true) and shorts:find('processing-unit short',1,true),shorts)
  -- the recipe's quality changing during the watch reads as a recipe change
  U.handler({index=1},{position={x=28,y=166},seconds=10})
  for t=2201,2800 do game.tick=t; if t==2500 then m.get_recipe=function() return recipe,{name='epic'} end end; U.tick(t) end
  eq(U.handler({index=1},{}).machines[1].recipe_changed,'quality-module-3 -> quality-module-3 (epic)')
  defines=nil
end
print('d20_batch58 T1 ingredient shortages at the recipe\'s quality: ok')

-- T2 (Astra #1461: a 20-furnace bank took two windows of 16): up to 64 machines, or an area with a recipe, and totals
-- by recipe beside the rows. 20 steel furnaces on iron plates and 2 on copper in the area; 5 of the iron ones short of
-- ore half the time.
do
  game={tick=3000}
  defines={inventory={assembling_machine_input=2,furnace_source=2,assembling_machine_output=3,furnace_result=3}}
  local iron,copper={name='iron-plate',ingredients={{type='item',name='iron-ore',amount=1}},products={{type='item',name='iron-plate',amount=1}}},
    {name='copper-plate',ingredients={{type='item',name='copper-ore',amount=1}},products={{type='item',name='copper-plate',amount=1}}}
  local list,by={},{}
  for i=1,22 do
    local f={valid=true,name='steel-furnace',type='furnace',position={x=10+2*i,y=5},unit_number=i,products_finished=0,status='working',
      get_recipe=function() return i<=20 and iron or copper end,get_inventory=function(k) return inventory(k==3 and {} or {{name='iron-ore',quality='normal',count=5}}) end}
    list[#list+1]=f; by[i]=f
  end
  local area_seen
  local p={index=1,force='player',surface={name='nauvis',find_entities_filtered=function(a) area_seen=a; local out={} for i=1,math.min(#list,a.limit) do out[#out+1]=list[i] end return out end}}
  local st={}
  local U=dofile('mod/agent-harness_0.1.0/uptime.lua'){state=function() return st end,remote_entity=function(_,a) return by[a.unit_number] end,
    status_name=function(e) return e.status end,craftrate=function(e) return {crafts_per_min=e.unit_number<=20 and 37.5 or 37.5,productivity=0} end}
  local start=U.handler(p,{area={left_top={x=0,y=0},right_bottom={x=60,y=10}},recipe='iron-plate',seconds=60})
  eq(start.machines,20); eq(area_seen.limit,256); eq(area_seen.force,'player')
  for t=3001,3000+3600 do
    game.tick=t
    for i=1,20 do
      local f=by[i]
      f.status=(i>15 and (t//600)%2==1) and 'item_ingredient_shortage' or 'working'
      if f.status=='working' and t%96==0 then f.products_finished=f.products_finished+1 end
    end
    U.tick(t)
  end
  local out=U.handler(p,{})
  -- above 16 machines the rows are left out (their numbers are what the reply's encoding pays for); lines has each one
  eq(out.machines,nil); eq(out.machine_rows,'left out above 16 machines (each one is in lines); a watch of 16 or fewer gives them'); eq(#out.lines,21); eq(#out.groups,1)
  local g=out.groups[1]
  local total=0
  for i=1,20 do total=total+by[i].products_finished end
  eq(g.recipe,'iron-plate'); eq(g.machines,20); eq(g.completions,total); eq(g.crafts,total); eq(g.full_speed_per_min,750)
  eq(g.completions_per_min,math.floor(total/60*600+0.5)/10)
  eq(g.status_shares.working+g.status_shares.item_ingredient_shortage,100)
  assert(out.group_lines[1]:find('iron-plate on 20 machines: '..total..' completions in 60s (',1,true) and out.group_lines[1]:find('against 750/min at full speed), '..total..' crafts',1,true),out.group_lines[1])
  eq(out.lines[1],out.group_lines[1],'the totals first')
  -- the limits
  fails(function() U.handler(p,{area={left_top={x=0,y=0},right_bottom={x=300,y=10}}}) end,'at most 200 tiles a side')
  for i=23,70 do list[#list+1]=by[1] end
  fails(function() U.handler(p,{area={left_top={x=0,y=0},right_bottom={x=60,y=10}}}) end,'70 crafting machines in that area: at most 64')
  local many={}
  for i=1,65 do many[i]={x=i,y=0} end
  fails(function() U.handler(p,{positions=many}) end,'positions: 1..64')
  fails(function() U.handler(p,{area={left_top={x=0,y=0},right_bottom={x=60,y=10}},recipe='gears'}) end,'no crafting machine of ours on gears in that area')
  defines=nil
end
print('d20_batch58 T2 64 machines, an area with a recipe, totals by recipe: ok')

-- T3 (Sol #1460): produced and consumed by quality. The production statistics keep counts by quality (2.0.77; the
-- name alone is normal): a statistics-only watch of gears at every quality and uncommon plates. And a machine's
-- outputs by quality from its output slot, an interval with products taken out unknown.
do
  game={tick=10000,surfaces={nauvis={name='nauvis'}}}
  defines={inventory={assembling_machine_input=2,furnace_source=2,assembling_machine_output=3,furnace_result=3},
    flow_precision_index={ten_minutes=1}}
  prototypes={item={['iron-gear-wheel']={},['iron-plate']={}},quality={normal={},uncommon={},rare={},epic={},legendary={},['quality-unknown']={hidden=true}}}
  local counts={input={},output={}}
  local function key(id) if type(id)=='string' then return id..'@normal' end return id.name..'@'..(id.quality or 'normal') end
  local stats={get_input_count=function(id) return counts.input[key(id)] or 0 end,get_output_count=function(id) return counts.output[key(id)] or 0 end,
    get_flow_count=function(a) return a.category=='input' and a.name.name=='iron-gear-wheel' and a.name.quality=='normal' and 120 or 0 end}
  local force={name='player',get_item_production_statistics=function() return stats end}
  game.forces={player=force}
  counts.input['iron-gear-wheel@normal']=5000; counts.output['iron-plate@uncommon']=100
  local st={}
  local p={index=1,force=force,surface=game.surfaces.nauvis}
  local U=dofile('mod/agent-harness_0.1.0/uptime.lua'){state=function() return st end,remote_entity=function() error('no machine') end}
  local start=U.handler(p,{items={'iron-gear-wheel',{name='iron-plate',quality='uncommon'}},seconds=10})
  eq(start.machines,0)
  eq(start.items_recent,'the production statistics on nauvis, the last 10 minutes: iron-gear-wheel: produced 120, consumed 0; iron-plate (uncommon): produced 0, consumed 0')
  for t=10001,10600 do
    game.tick=t
    if t==10300 then counts.input['iron-gear-wheel@uncommon']=9; counts.output['iron-plate@uncommon']=120; counts.input['iron-gear-wheel@normal']=5054 end
    U.tick(t)
  end
  local out=U.handler(p,{})
  local rows={}
  for _,r in ipairs(out.flows.rows) do rows[r.name..'@'..r.quality]=r end
  eq(rows['iron-gear-wheel@uncommon'].produced,9); eq(rows['iron-gear-wheel@normal'].produced,54); eq(rows['iron-gear-wheel@rare'],nil,'a quality with nothing is left out')
  eq(rows['iron-plate@uncommon'].consumed,20); eq(rows['iron-plate@uncommon'].produced,0)
  eq(out.flows.line,'production statistics on nauvis in 10s (every machine and hand there): iron-gear-wheel produced 54 (324/min), consumed 0 (0/min); iron-gear-wheel (uncommon) produced 9 (54/min), consumed 0 (0/min); iron-plate (uncommon) produced 0 (0/min), consumed 20 (120/min)')
  eq(out.lines[#out.lines],out.flows.line)
  fails(function() U.handler(p,{items={'nope'}}) end,'nope is not an item')
  fails(function() U.handler(p,{items={{name='iron-plate',quality='shiny'}}}) end,'quality shiny is not a quality')

  -- outputs by quality: an assembler on gears with quality modules, every 4th completion uncommon; an inserter takes
  -- everything out once, at 30 s
  local gear={name='iron-gear-wheel',ingredients={{type='item',name='iron-plate',amount=2}},products={{type='item',name='iron-gear-wheel',amount=1}}}
  local slot={}
  local m={valid=true,name='assembling-machine-3',type='assembling-machine',position={x=0.5,y=0.5},products_finished=0,status='working',
    get_recipe=function() return gear end,get_inventory=function(k) if k==3 then return inventory(slot) end return inventory({{name='iron-plate',quality='normal',count=50}}) end}
  local function add(q) for _,s in ipairs(slot) do if s.quality==q then s.count=s.count+1; return end end slot[#slot+1]={name='iron-gear-wheel',quality=q,count=1} end
  local U2=dofile('mod/agent-harness_0.1.0/uptime.lua'){state=function() return st end,remote_entity=function() return m end,status_name=function(e) return e.status end,
    craftrate=function() return {crafts_per_min=75,productivity=0} end}
  U2.handler({index=2},{position={x=0.5,y=0.5},seconds=60})
  local made,last_sample,taken={normal=0,uncommon=0},game.tick,nil
  local start_tick=game.tick
  local samples={}
  for k=0,60 do samples[start_tick+math.min(60*k+(7*k)%60,3600)]=true end
  local in_interval={normal=0,uncommon=0}
  for t=start_tick+1,start_tick+3600 do
    game.tick=t
    if t%48==0 then m.products_finished=m.products_finished+1; local q=m.products_finished%4==0 and 'uncommon' or 'normal'; add(q); made[q]=made[q]+1; in_interval[q]=in_interval[q]+1 end
    if t==start_tick+1800 then slot={}; taken=true end
    U2.tick(t)
    if samples[t] then
      if taken==true then taken={normal=in_interval.normal,uncommon=in_interval.uncommon} end
      if type(taken)=='table' and not taken.done then taken.done=true; made.lost_n,made.lost_u=taken.normal,taken.uncommon end
      in_interval={normal=0,uncommon=0}
    end
  end
  local row=U2.handler({index=2},{}).machines[1]
  assert(made.lost_n+made.lost_u>0,'the taken-out interval had completions')
  eq(row.outputs_unknown_intervals,1)
  eq(row.outputs_by_quality['iron-gear-wheel'].normal,made.normal-made.lost_n); eq(row.outputs_by_quality['iron-gear-wheel'].uncommon,made.uncommon-made.lost_u)
  assert(row.line:find('outputs by quality in its output slot: iron-gear-wheel normal '..(made.normal-made.lost_n)..', uncommon '..(made.uncommon-made.lost_u)
    ..' (1 of '..row.outputs_intervals..' intervals with completions unknown: products taken out or spoiled between samples)',1,true),row.line)
  -- a product by chance: no outputs read
  gear.products[1].probability=0.5
  U2.handler({index=2},{position={x=0.5,y=0.5},seconds=10})
  for t=game.tick+1,game.tick+600 do game.tick=t; if t%48==0 then m.products_finished=m.products_finished+1 end; U2.tick(t) end
  row=U2.handler({index=2},{}).machines[1]
  eq(row.outputs_by_quality,nil); assert(not row.line:find('outputs by quality',1,true))
  defines,prototypes=nil,nil
end
print('d20_batch58 T3 produced and consumed by quality: ok')

-- uptime's samples read productivity without a table (craftrate.productivity_now): the same total as
-- craftrate.productivity, the research in, capped.
do
  local CR=dofile('mod/agent-harness_0.1.0/craftrate.lua'){}
  local force={recipes={crush={productivity_bonus=0.4}}}
  local recipe={name='crush',prototype={maximum_productivity=3}}
  local e={productivity_bonus=0.2,force=force,prototype={}}
  eq(CR.productivity_now(e,recipe),CR.productivity(e,recipe).total); eq(math.floor(CR.productivity_now(e,recipe)*100+0.5),60)
  force.recipes.crush.productivity_bonus=3.5
  eq(CR.productivity_now(e,recipe),3); eq(CR.productivity(e,recipe).total,3)
end
print('d20_batch58 productivity_now: ok')
