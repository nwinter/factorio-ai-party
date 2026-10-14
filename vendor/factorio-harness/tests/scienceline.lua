-- Run from repository root: lua tests/scienceline.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path  -- (walk.lua)
-- One science line per agent in the team block (scienceline.lua; operator 03:22: Luna made about 47 reads in 10
-- minutes to watch copper, power and labs): labs working, the limiting pack and its chain's first short step, power
-- headroom and boilers; at most every 5 min per agent and only when its facts changed; built one step a tick.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(text,part) assert(text and text:find(part,1,true),'missing "'..part..'" in: '..tostring(text)) end
defines={inventory={lab_input=2,assembling_machine_input=4,chest=1},flow_precision_index={ten_minutes=3}}
local names={[1]='working',[2]='missing_science_packs',[6]='item_ingredient_shortage'}
local chem,adv,plastic,red='chemical-science-pack','advanced-circuit','plastic-bar','automation-science-pack'
local recipes={
  [chem]={name=chem,products={{name=chem,amount=2}},ingredients={{type='item',name='engine-unit',amount=2},{type='item',name=adv,amount=3}}},
  [adv]={name=adv,products={{name=adv,amount=1}},ingredients={{type='item',name='electronic-circuit',amount=2},{type='item',name=plastic,amount=2}}},
  [plastic]={name=plastic,products={{name=plastic,amount=2}},ingredients={{type='item',name='coal',amount=1}}}}
prototypes={recipe=recipes,item={[chem]={},[red]={}},fluid={}}
local n=0
local function lab(status,held)
  n=n+1
  return {valid=true,unit_number=n,type='lab',name='lab',position={x=n,y=0},status=status,
    get_inventory=function(i) eq(i,2); return {get_item_count=function(name) return held[name] or 0 end} end}
end
local function crafter(recipe,status,held)
  n=n+1
  return {valid=true,unit_number=n,type='assembling-machine',name='assembling-machine-2',position={x=n,y=90},status=status,
    get_recipe=function() return recipes[recipe] end,
    get_inventory=function(i) eq(i,4); return {get_item_count=function(name) return held[name] or 0 end} end}
end
-- Nauvis: 20 labs, 12 working, 8 with no chemical packs; 14 chemical makers (9 lack advanced circuits), 17
-- advanced circuit makers (12 lack plastic), 4 plastic makers working. Vulcanus: 2 labs. A platform: skipped.
local labs={}
for i=1,20 do labs[i]=lab(i<=12 and 1 or 2,{[red]=5,[chem]=i<=12 and 3 or 0}) end
local cs={}
for i=1,14 do cs[#cs+1]=crafter(chem,i<=9 and 6 or 1,{['engine-unit']=4}) end
for i=1,17 do cs[#cs+1]=crafter(adv,i<=12 and 6 or 1,{['electronic-circuit']=10}) end
for i=1,4 do cs[#cs+1]=crafter(plastic,1,{coal=5}) end
-- The fake find: by type (one or a list), inside the area when there is one (walk.lua's bands).
local finds,crafter_finds,wholes,finds_tick,last_tick=0,0,0,0,-1
local crafter_types={}
local function finder(lists)
  return function(f)
    assert(f.type,'by type')
    if game.tick~=last_tick then last_tick=game.tick; finds_tick=0 end
    finds=finds+1; finds_tick=finds_tick+1
    assert(finds_tick<=1,'one find a tick')
    if type(f.type)=='table' then crafter_finds=crafter_finds+1; for _,k in ipairs(f.type) do crafter_types[k]=true end end
    if not f.area then wholes=wholes+1 end
    local out,a={},f.area
    for _,t in ipairs(type(f.type)=='table' and f.type or {f.type}) do
      for _,e in ipairs(lists[t] or {}) do
        local q=e.position
        if not a or (q.x>=a[1][1] and q.x<=a[2][1] and q.y>=a[1][2] and q.y<=a[2][2]) then out[#out+1]=e end
      end
    end
    return out
  end
end
local nauvis={name='nauvis',index=1,find_entities_filtered=finder({lab=labs,['assembling-machine']=cs})}
local vulcanus={name='vulcanus',index=2,find_entities_filtered=finder({lab={lab(1,{}),lab(1,{})}})}
local plat={name='platform-1',index=3,platform={},find_entities_filtered=function() error('platforms are not read') end}
local flows={[chem]={input=120,output=300},[adv]={input=80,output=200},[plastic]={input=300,output=520}}
local tech={name='plastics-2',research_unit_ingredients={{name=red,amount=1},{name=chem,amount=1}}}
local force={name='player',current_research=tech,research_progress=0.41,
  get_item_production_statistics=function() return {get_flow_count=function(f) return (flows[f.name] or {})[f.category] or 0 end} end,
  get_fluid_production_statistics=function() return {get_flow_count=function() return 0 end} end}
game={tick=0,surfaces={nauvis,vulcanus,plat},forces={player=force},get_surface=function(name) for _,s in ipairs({nauvis,vulcanus,plat}) do if s.name==name then return s end end end}
storage={}
local supply=dofile('mod/agent-harness_0.1.0/supply.lua'){status_name=function(e) return names[e.status] end}
local power={id=7,capacity_kw=22100,draw_kw=18500,boilers=13,fed=11,low=2,low_min=2.4}
local asked
local S=dofile('mod/agent-harness_0.1.0/scienceline.lua'){state=function() return storage end,supply=supply,
  networks={power_row=function(f,surface) asked=surface; return power end},status_name=function(e) return names[e.status] end}
local p={force=force}
local h={}
local function run(t) for _=1,t do game.tick=game.tick+1; S.tick(game.tick) end end
-- Until the running job ends (its steps are spread over the 5 minutes).
local function finish() local n=0; while storage.science_jobs and n<18000 do run(1); n=n+1 end; assert(not storage.science_jobs,'the job ends'); return n end

-- 1. The first ask starts the job; at most one find a tick: each planet's labs (one whole-surface find each, no box
-- known yet), then the crafters, every type in one find, in bands of chunks around where the labs are.
eq(S.lines(p,h),nil,'nothing built yet')
local took=finish()
eq(wholes,2,'a whole-surface find per planet, the first time'); assert(crafter_finds>=1,'the crafters and miners in bands')
assert(took<=200,'the first job: a step every 4 ticks: '..took)
eq(asked,'nauvis','power on the surface with the most labs')
assert(crafter_types['mining-drill'] and crafter_types['offshore-pump'] and crafter_types['assembling-machine'],'the miners in the same finds (Grok 04:55)')
local line=S.lines(p,h)
eq(line,'science on nauvis: research plastics-2 41%; labs 12 of 20 working; limiting chemical-science-pack: 8 of 20 labs have none, '
  ..'made 12/min, used 30/min; first short step plastic-bar: 4 of 4 working, made 30/min, used 52/min '
  ..'(chemical-science-pack > advanced-circuit > plastic-bar); power electric #7: 18.5 MW of 22.1 MW, headroom 3.6 MW (16%); '
  ..'boilers 13: 11 with fuel at their feeders, 2 under 20 min of their own fuel and not refilled, lowest 2 min')
-- 2. At most every 5 min: not again at once, nor after 5 min while nothing changed.
eq(S.lines(p,h),nil)
run(18000); eq(S.lines(p,h),nil,'stale: a new job starts'); finish()
eq(S.lines(p,h),nil,'the same facts: not told again')
-- 3. Changed: 4 more labs work (still without chemical packs in their input). Told after the next build.
for i=13,16 do labs[i].status=1 end
run(18000); S.lines(p,h); finish()
has(S.lines(p,h),'labs 16 of 20 working; limiting chemical-science-pack: 8 of 20 labs have none')
-- Another agent hears it on its own clock.
has(S.lines(p,{}),'labs 16 of 20 working')
-- 4. Every lab holds every pack: no limiting pack; the crafters are still walked (the idle-colour check); the boilers
-- all fed.
for i=1,20 do labs[i].status=1; labs[i].get_inventory=function() return {get_item_count=function() return 5 end} end end
power.fed=13; power.low=0; power.low_min=nil
crafter_finds=0
run(18000); S.lines(p,h); finish()
assert(crafter_finds>0,'the crafters walked for the idle check')
eq(S.lines(p,h),'science on nauvis: research plastics-2 41%; labs 20 of 20 working; every lab holds every pack; '
  ..'power electric #7: 18.5 MW of 22.1 MW, headroom 3.6 MW (16%); boilers 13: 13 with fuel at their feeders')
-- 5. A failing step drops the job and keeps the last line; the error is recorded.
nauvis.find_entities_filtered=function() error('boom') end
run(18000); S.lines(p,h); finish()
eq(storage.science_jobs,nil); eq(storage.science_line_errors.count,1); eq(storage.science_line_errors.step,'labs')
has(storage.science_line.player.text,'labs 20 of 20 working')
-- 6. A job an older runtime left (main's shape: no start, every or n) when this one is deployed: dropped like a
-- failing step, the error recorded and the last line kept; never a tick error, and the next job runs.
nauvis.find_entities_filtered=finder({lab=labs,['assembling-machine']=cs})
storage.science_jobs={player={step='labs',force='player',tech='plastics-2',progress=0.41,packs={red,chem},surfaces={'nauvis','vulcanus'},
  si=1,labs={},crafters={},ti=1,idx=1,by_product={}}}
run(1)
eq(storage.science_jobs,nil,'the old job is dropped'); eq(storage.science_line_errors.count,2); eq(storage.science_line_errors.step,'labs')
has(storage.science_line.player.text,'labs 20 of 20 working')
run(18000); S.lines(p,h); finish()
eq(storage.science_line_errors.count,2,'the next job runs'); eq(storage.science_line.player.tick>game.tick-18000,true)
-- 7. A whole colour stopped (Opus, 07:55): every chemical pack maker stands still at a build and still at the next, 5
-- min on: a digest group naming the makers' states and the chain's first short step; none at the first build; gone
-- once one works again. Automation has no maker on this surface: never one.
eq(#S.alert_groups(force),0)
for i=1,14 do cs[i].status=6 end
run(18000); S.lines(p,h); finish()
eq(#S.alert_groups(force),0,'idle at one build only')
run(18000); S.lines(p,h); finish()
local ig=S.alert_groups(force)
eq(#ig,1); eq(ig[1].kind,'science_idle'); eq(ig[1].surface,'nauvis'); eq(ig[1].key,'science_idle|nauvis|chemical-science-pack|plastic-bar')
has(ig[1].line,'no chemical-science-pack maker working for ')
has(ig[1].line,'+ min (14 makers: 14 item_ingredient_shortage); first short step plastic-bar: 4 of 4 working, made 30/min, used 52/min (chemical-science-pack > advanced-circuit > plastic-bar)')
assert(ig[1].center and ig[1].center.y==90,'centred on its makers')
cs[1].status=1
run(18000); S.lines(p,h); finish()
eq(#S.alert_groups(force),0,'a maker works again')
print('scienceline: ok')
