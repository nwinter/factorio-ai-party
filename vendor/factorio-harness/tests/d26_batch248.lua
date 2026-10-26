-- Run from repository root: lua tests/d26_batch248.lua
-- d26 batch248: R1-R3 (and R7, R8) of the second whole-harness review (batch227).
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
-- A game object as 2.0.77 hands it to Lua: userdata, its fields read through the metatable.
local function ud(fields) local u=io.tmpfile(); debug.setmetatable(u,{__index=fields}); return u end

-- R3: an idle furnace's previous_recipe is {name=LuaRecipePrototype, quality=LuaQualityPrototype}; on a copy of world n
-- (2.0.77) type(previous_recipe.name) is 'userdata' (three furnaces and three recyclers read). The steel furnace at
-- (-65,83) on Nauvis, idle (no_ingredients) on copper-plate: uptime read "none: 20013 completions", inspect no rate.
do
  defines={inventory={furnace_source=2,assembling_machine_input=2,furnace_result=3},flow_precision_index={one_minute=1,ten_minutes=2,one_hour=3}}
  local copper={name='copper-plate',energy=3.2,prototype={maximum_productivity=3},
    ingredients={{type='item',name='copper-ore',amount=1}},products={{type='item',name='copper-plate',amount=1}}}
  prototypes={recipe={['copper-plate']=ud(copper)},item={['copper-plate']={stack_size=100}},entity={}}
  -- force.recipes is keyed by name: a prototype as the key finds nothing
  local recipes={['copper-plate']=copper}
  local force={recipes=setmetatable({},{__index=function(_,k) if type(k)=='string' then return recipes[k] end end})}
  local function furnace(x,y)
    return {valid=true,name='steel-furnace',type='furnace',position={x=x,y=y},quality=ud({name='normal'}),prototype={name='steel-furnace'},
      force=force,crafting_speed=2,status=2,products_finished=20013,get_recipe=function() return nil end,
      previous_recipe={name=ud({name='copper-plate',energy=3.2,products=copper.products,ingredients=copper.ingredients}),quality=ud({name='normal'})},
      get_inventory=function() return {get_item_count=function() return 0 end,get_contents=function() return {} end} end,
      get_output_inventory=function() return {1} end,
      surface={find_logistic_network_by_position=function() return nil end,find_entities_filtered=function() return {} end}}
  end
  local f=furnace(-65,83)
  -- inspect's rate
  local CR=dofile('mod/agent-harness_0.1.0/craftrate.lua'){}
  local r=CR.machine(f)
  assert(r,'an idle furnace has its last recipe\'s rate')
  eq(r.recipe,'copper-plate'); eq(r.crafts_per_min,37.5)
  -- uptime's baseline and rows
  game={tick=1000}
  local st={}
  local U=dofile('mod/agent-harness_0.1.0/uptime.lua'){state=function() return st end,remote_entity=function() return f end,
    status_name=function() return 'no_ingredients' end,craftrate=function(e) return CR.machine(e) end}
  local start=U.handler({index=1},{position={x=-65,y=83},seconds=10})
  has(start.baseline[1],'steel-furnace (-65,83) copper-plate: 20013 completions so far')
  -- platform_production's makers: an idle furnace on a platform making the item counts
  local status={[2]='no_ingredients'}
  local pl={name='Asterion',surface={find_entities_filtered=function() return {f} end}}
  local function stats() return {input_counts={},output_counts={},get_input_count=function() return 0 end,get_output_count=function() return 0 end,
    get_flow_count=function() return 0 end} end
  local p={force={get_item_production_statistics=stats,get_fluid_production_statistics=stats}}
  local B=dofile('mod/agent-harness_0.1.0/platbom.lua'){platform=function() return pl end,cargo={},
    craftrate=function(e) return CR.machine(e) end,status_name=function(e) return status[e.status] end}
  local out=B.production(p,{platform='Asterion',item='copper-plate'})
  eq(#out.makers,1); eq(out.makers[1].recipe,'copper-plate'); eq(out.makers[1].per_min,37.5); eq(out.makers[1].status,'no_ingredients')
  -- configure {bar}'s refusal on it: what it holds at most of its last recipe's product
  defines.inventory.chest=1
  local IB=dofile('mod/agent-harness_0.1.0/invbar.lua'){integer=function(v) return v end}
  local ok,err=pcall(IB.set,f,1)
  assert(not ok)
  has(err,'copper-plate: at most 100, a stack')
  print('d26_batch248 R3 idle furnace last recipe (userdata name): ok')
end

-- R1 (Luna, shift70 22:19:03Z at (-241,495) on Nauvis): observe {scope: labs} read "stalled: no lab is working" and
-- "0 in 0 groups" from the labs within 96 tiles of her, while 4 biolabs worked elsewhere on Nauvis (her research {} 8 s
-- later: 95.2 -> 95.4%). Every lab of ours researches the current technology: the research line counts them all, on
-- every surface, from the census pass's lists; the groups stay the area's and say so.
do
  defines={inventory={lab_input=2}}
  local names={[1]='working',[2]='no_power'}
  local n=0
  local function lab(name,x,y,status,speed)
    n=n+1
    return {valid=true,unit_number=n,name=name,type='lab',position={x=x,y=y},status=status,prototype={researching_speed=speed},
      get_inventory=function() return {get_item_count=function() return 1 end} end}
  end
  local nauvis_labs={lab('biolab',30.5,-150.5,1,2),lab('biolab',35.5,-150.5,1,2),lab('biolab',40.5,-150.5,1,2),lab('biolab',45.5,-150.5,1,2),lab('lab',60.5,-150.5,2,1)}
  local gleba_labs={lab('lab',0.5,0.5,1,1)}
  local finds={}
  local function surface(name,list)
    return {name=name,index=#finds+1,find_entities_filtered=function(f)
      finds[#finds+1]=name..(f.position and ' near' or ' all')
      if f.position then
        local out={}
        for _,e in ipairs(list) do if math.abs(e.position.x-f.position.x)<=f.radius and math.abs(e.position.y-f.position.y)<=f.radius then out[#out+1]=e end end
        return out
      end
      return list
    end}
  end
  local nauvis,gleba=surface('nauvis',nauvis_labs),surface('gleba',gleba_labs)
  game={tick=1,surfaces={nauvis=nauvis,gleba=gleba}}
  local tech={name='mining-productivity-3',research_unit_ingredients={{name='automation-science-pack',amount=1}},research_unit_count=1000,research_unit_energy=3600}
  local force={name='player',current_research=tech,research_progress=0.5,laboratory_speed_modifier=0}
  local census={nauvis=nauvis_labs,gleba=gleba_labs}
  local L=dofile('mod/agent-harness_0.1.0/labs.lua'){integer=function(v,d) return v or d end,center=function(p) return p.position end,
    status_name=function(e) return names[e.status] end,census_typed=function(f,s,t) eq(t,'lab'); return census[s.name] end}
  local r=L.view({position={x=-241,y=495},surface=nauvis,force=force},{})
  -- 500 units left x 60 s at speed 2+2+2+2 (Nauvis) + 1 (Gleba) = 9: 3333.3 s
  eq(r.research,'mining-productivity-3 50% needs automation, eta 55m34s at 5 working labs')
  eq(r.research_labs,'5 of 6 labs of ours working, every surface (nauvis 4 of 5, gleba 1 of 1): research counts them all; the groups below are the labs within 96 tiles of (-241,495) on nauvis')
  eq(r.labs,'0 in 0 groups within 96 tiles of (-241,495)')
  -- the census lists: no whole-surface find (the area's own find only)
  eq(#finds,1); eq(finds[1],'nauvis near')
  -- a surface the census pass has not walked: found there
  census.gleba=nil
  r=L.view({position={x=-241,y=495},surface=nauvis,force=force},{})
  eq(finds[#finds],'gleba all')
  -- no lab working anywhere: stalled
  for _,e in ipairs(nauvis_labs) do e.status=2 end; gleba_labs[1].status=2
  has(L.view({position={x=-241,y=495},surface=nauvis,force=force},{}).research,', stalled: no lab is working')
  print('d26_batch248 R1 labs research line from every lab of ours: ok')
end

-- R2 (shift80): Weaver stopped at Nauvis, left at tick 66207060, and its hub sent pod 46081032 at 66207128 (68 ticks
-- later); it landed 1,000 agricultural science packs in pad (52,54). pods.lua read only the platforms at a space
-- location, so freight (which takes a stop's pods for 600 ticks after it ends, POD_AFTER) and delivery_watch never saw
-- it. A platform is now read for 660 ticks after it was last seen at a stop.
do
  defines={inventory={cargo_unit=2}}
  local st={}
  local nauvis={name='nauvis',valid=true}
  local pad={valid=true,surface=nauvis,position={x=52,y=54}}
  local on_platform={}
  local reads=0
  local plsurf={name='platform-12',valid=true,find_entities_filtered=function(f) eq(f.type,'cargo-pod'); reads=reads+1; return on_platform end}
  local weaver={valid=true,index=12,name='Weaver',space_location={name='nauvis'},surface=plsurf}
  local force={name='player',index=1,platforms={weaver}}
  game={tick=66207000,forces={player=force},get_surface=function(n) return n=='nauvis' and nauvis or nil end}
  local P=dofile('mod/agent-harness_0.1.0/pods.lua'){state=function() return st end}
  P.tick(66207000); eq(reads,1)
  -- it leaves at 66207060; the next sample (66207060) sees it gone from the stop
  weaver.space_location=nil
  P.tick(66207060); eq(reads,2,'read after it left')
  -- the pod, sent at 66207128, rising on the platform's surface at the next sample
  local cargo={get_contents=function() return {{name='agricultural-science-pack',quality='normal',count=1000}} end}
  local pod={valid=true,unit_number=46081032,surface=plsurf,position={x=0,y=-20},cargo_pod_destination={station=pad},
    get_inventory=function(i) eq(i,2); return cargo end}
  on_platform={pod}
  P.tick(66207180)
  local from=P.from('player','Weaver')
  eq(#from,1,'the pod sent 68 ticks after the stop is followed'); eq(from[1],pod)
  has(P.line('player','nauvis','Weaver'),'1 cargo pod from Weaver still in the air: agricultural-science-pack*1000 (to the landing pad at (52,54)')
  -- 660 ticks after the stop was last seen: no longer read
  on_platform={}
  local n=reads
  P.tick(66207660); eq(reads,n+1)
  P.tick(66207720); eq(reads,n+1,'not read 720 ticks after')
  -- a platform never seen at a stop since the read began (in flight at a deploy): not read
  local kestrel={valid=true,index=13,name='Kestrel II',surface={name='platform-13',valid=true,find_entities_filtered=function() error('read') end}}
  force.platforms={weaver,kestrel}
  P.tick(66207780)
  print('d26_batch248 R2 pods sent just after a stop followed: ok')
end

-- R7 (Sol shift79 11:04Z: "Old sleep science10working was stale versus live labs"): the science line is built over
-- about 5 min and pushed at most every 5 min; it says when its facts were read.
do
  local st={science_line={player={tick=100000,start=84400,text='science on nauvis: research foo 10%; labs 10 of 26 working',key='k'}}}
  game={tick=101800,surfaces={},forces={}}
  local S=dofile('mod/agent-harness_0.1.0/scienceline.lua'){state=function() return st end,supply={},networks={},walk={every=function() return 4 end}}
  st.science_jobs={player={}}   -- a job already running: none started here
  eq(S.lines({force={name='player'}},{}),'science on nauvis (read 4m50s to 30s ago): research foo 10%; labs 10 of 26 working')
  -- built within a second: one age
  st.science_line.player.start=100000
  eq(S.lines({force={name='player'}},{}),'science on nauvis (read 30s ago): research foo 10%; labs 10 of 26 working')
  print('d26_batch248 R7 science line age: ok')
end

-- R8 (six reads in shifts 69-80): flight_watch {id} after the watch was dropped read a bare "no flight watch #N"; the
-- dropped records (the last 4 a platform) say where it was, when it began and ended, and when and why it was dropped.
do
  game={tick=4600}
  local st={flightwatch={seq=12,list={},events={},eseq=0,dropped={Asterion={{id=9,force='player',set=400,began=500,ended=900,why='cleared by sol',tick=1000}}}}}
  local F=dofile('mod/agent-harness_0.1.0/flightwatch.lua'){state=function() return st end,who=function(q) return q.name end}
  local p={name='luna',force={name='player'},index=2}
  local ok,err=pcall(F.call,p,{id=9})
  assert(not ok)
  eq(err,'no flight watch #9: #9 on Asterion (began at tick 500, ended at tick 900) is no longer kept: dropped at tick 1000 (1m00s ago), cleared by sol')
  ok,err=pcall(F.call,p,{id=40}); eq(err,'no flight watch #40: none set with that number (the last set is #12)')
  ok,err=pcall(F.call,p,{id=3}); eq(err,'no flight watch #3: set and since dropped, before the last 4 dropped on its platform kept')
  -- another force's dropped watch is not named
  ok,err=pcall(F.call,{name='x',force={name='enemy'},index=9},{id=9}); eq(err,'no flight watch #9: set and since dropped, before the last 4 dropped on its platform kept')
  print('d26_batch248 R8 flight_watch dropped id named: ok')
end
