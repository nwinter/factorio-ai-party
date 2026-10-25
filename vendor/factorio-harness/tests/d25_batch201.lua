-- d25 batch201. Run from the harness root: lua tests/d25_batch201.lua
-- QN1 (Astra #2302: two Aquilo silos read 19 completions in 600 s while the surface's statistics counted 879 rocket
-- parts): a silo's completions are rocket parts, finished rockets x 50 plus rocket_parts, beside the statistics.
-- QN2 (Astra #2315): inspect's output_stop says an assembling machine holding its crafts' worth of a product gets no
-- ingredient from inserters, naming those waiting (trace's side is in tests/trace.lua).
-- QN3 (Sol #2328): supply's residual is signed, each sign said, with the pod log's landed and sent-up counts.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
game={tick=60652783}

do
  defines={inventory={assembling_machine_input=2,furnace_source=2,crafter_input=2}}
  local PART={name='rocket-part',energy=3,products={{type='item',name='rocket-part',amount=1}},ingredients={}}
  local produced=134157
  local stats={get_input_count=function(n) return (n=='rocket-part' or (type(n)=='table' and n.name=='rocket-part' and n.quality=='normal')) and produced or 0 end,
    get_output_count=function() return 0 end}
  local force={name='player',recipes={},get_item_production_statistics=function() return stats end}
  local surface={name='aquilo',valid=true}
  game.surfaces={aquilo=surface}; game.forces={player=force}
  local st={}
  local ms={}
  -- a silo as on the copy: a part when its craft ends, another when its productivity bar fills; at 50 parts the rocket
  -- is made (products_finished + 1 and rocket_parts 0 in the same tick); parts go on through the launch
  local function silo(x,fin,parts)
    local m={valid=true,name='rocket-silo',type='rocket-silo',position={x=x,y=17.5},force=force,surface=surface,prototype={rocket_parts_required=50},
      productivity_bonus=0.44,crafting_speed=0.77,products_finished=fin,rocket_parts=parts,bonus_progress=0,crafting_progress=0,status='working',
      get_recipe=function() return PART end,get_inventory=function() return {get_item_count=function() return 0 end,get_contents=function() return {} end} end}
    ms[#ms+1]=m
    return m
  end
  silo(-18.5,1110,7); silo(17.5,1572,49)
  local made={0,0}
  local function part(i,m)
    m.rocket_parts=m.rocket_parts+1; made[i]=made[i]+1; produced=produced+1
    if m.rocket_parts>=50 then m.products_finished=m.products_finished+1; m.rocket_parts=0 end
  end
  local U=dofile('mod/agent-harness_0.1.0/uptime.lua'){state=function() return st end,remote_entity=function(_,q) for _,m in ipairs(ms) do if m.position.x==q.position.x then return m end end end,
    status_name=function(e) return e.status end,craftrate=function() return {crafts_per_min=15.4,productivity=0.44,productivity_machine=0.24,productivity_research=0.2} end}
  local start=U.handler({index=1,force=force,surface=surface},{positions={{x=-18.5,y=17.5},{x=17.5,y=-13.5+31}},seconds=600})
  has(start.baseline[1],'rocket-silo (-18.5,17.5) rocket-part: 55507 rocket parts so far (finished rockets x the parts a rocket takes, plus those of the one building')
  for t=game.tick+1,game.tick+36000 do
    game.tick=t
    for i,m in ipairs(ms) do
      m.status=(t%3000<1500) and 'working' or 'launching_rocket'
      local step=m.crafting_speed/PART.energy/60
      m.crafting_progress=m.crafting_progress+step; m.bonus_progress=m.bonus_progress+0.44*step
      if m.crafting_progress>=1 then m.crafting_progress=m.crafting_progress-1; part(i,m) end
      while m.bonus_progress>=1 do m.bonus_progress=m.bonus_progress-1; part(i,m) end
    end
    U.tick(t)
  end
  local res=U.handler({index=1},{})
  local a,b=res.machines[1],res.machines[2]
  eq(a.completions,made[1]); eq(b.completions,made[2])
  assert(made[1]>200 and ms[1].products_finished-1110>=4,'rockets were made in the watch: '..made[1]..' parts')
  -- base crafts from the parts and the bar: parts / 1.44
  assert(math.abs(a.crafts-made[1]/1.44)<=1,a.crafts..' crafts of '..made[1])
  has(a.completions_are,'rocket parts: a silo\'s products_finished counts rockets')
  eq(res.silo_statistics.silos_made,made[1]+made[2]); eq(res.silo_statistics.statistics_produced,made[1]+made[2])
  has(res.silo_statistics.line,string.format('rocket-part: the 2 watched silos made %d in 600s; the production statistics on aquilo counted %d produced',made[1]+made[2],made[1]+made[2]))
  eq(res.groups[1].completions,made[1]+made[2])
  local found=false
  for _,l in ipairs(res.lines) do if l==res.silo_statistics.line then found=true end end
  assert(found,'the statistics line is in lines')
  -- a watch begun before parts were counted (no parts flag): the game's count, said to be rockets
  local job=st.uptime[1]
  for _,m in ipairs(job.machines) do m.parts=nil; m.finished0=1110; m.e=ms[1] end
  job.result=nil; job.silo_stats=nil
  local old=U.result(job,true)
  has(old.machines[1].completions_are,'rockets (the watch began before parts were counted')
  eq(old.silo_statistics,nil)
  defines=nil
end
print('d25_batch201 QN1 uptime silo completions are rocket parts: ok')

do
  defines={inventory={assembling_machine_input=2},entity_status={waiting_for_space_in_destination=27,working=1}}
  prototypes={recipe={explosives={name='explosives',energy=4,products={{type='item',name='explosives',amount=2}},
    ingredients={{type='item',name='coal',amount=1},{type='item',name='sulfur',amount=1},{type='fluid',name='water',amount=10}}}},
    item={explosives={stack_size=50}}}
  local held={explosives=10}
  local ins={valid=true,name='fast-inserter',position={x=-7.5,y=48.5},status=27,held_stack={valid_for_read=true,count=1,name='coal'}}
  local idle={valid=true,name='fast-inserter',position={x=-3.5,y=48.5},status=1,held_stack={valid_for_read=false}}
  local e={valid=true,type='assembling-machine',name='chemical-plant',crafting_speed=1.3,force='player',bounding_box={left_top={x=-7,y=47},right_bottom={x=-4,y=50}},
    get_recipe=function() return {name='explosives'} end,get_output_inventory=function() return {get_item_count=function(n) return held[n] or 0 end} end,
    get_inventory=function() return {get_item_count=function(n) return n=='sulfur' and 1 or 0 end} end,get_fluid_contents=function() return {water=20} end}
  e.surface={find_entities_filtered=function(f) assert(f.type=='inserter' and f.area) return {ins,idle} end}
  ins.drop_target=e; idle.drop_target={}
  local O=dofile('mod/agent-harness_0.1.0/outputstop.lua'){}
  local r=O.read(e,'full_output')
  eq(r.line,"full_output, no output at its limit: it is not crafting (crafting_progress 0) and holds 2 crafts' worth or more (explosives 10); it lacks coal 0 (a craft takes 1), and inserters put no ingredient into it while it holds 2 crafts' worth of a product or more (explosives 10; below 4 they do); waiting for space in it: fast-inserter (-7.5,48.5) holding 1 coal")
  eq(r.refuses_ingredients.from,4); eq(r.refuses_ingredients.held,10); eq(r.refuses_ingredients.waiting[1],'fast-inserter (-7.5,48.5) holding 1 coal')
  has(r.idle_full_output,'and inserters put no ingredient into it while it holds that much')
  -- under its crafts' worth: none refused, the shortage as before
  held.explosives=2
  r=O.read(e,'item_ingredient_shortage')
  eq(r.refuses_ingredients,nil)
  defines,prototypes=nil,nil
end
print('d25_batch201 QN2 outputstop: an output at its crafts\' worth gets no ingredient from inserters: ok')

do
  game.tick=61506411
  prototypes={item={['agricultural-science-pack']={get_spoil_ticks=function() return 216000 end}},quality={normal={level=0}}}
  local st={}
  local made,used=500,1000
  local stats={get_input_count=function() return made end,get_output_count=function() return used end}
  local force={name='player',get_item_production_statistics=function() return stats end}
  local nauvis={name='nauvis',index=1}
  local P=dofile('mod/agent-harness_0.1.0/podlog.lua'){state=function() return st end}
  local SF=dofile('mod/agent-harness_0.1.0/spoilflow.lua'){state=function() return st end,pods=function(...) return P.counted(...) end}
  SF.sample(force,nauvis,'agricultural-science-pack',2801)
  -- over 2.6 min: 572 used, none made, 680 landed in 5 pods (a quality among them), 100 sent up in a rocket; one
  -- landed before the interval and one of another item are not counted
  st.podlog={seq=0,by={nauvis={}},open={}}
  local list=st.podlog.by.nauvis
  local function pod(t) st.podlog.seq=st.podlog.seq+1; t.id=st.podlog.seq; list[#list+1]=t end
  pod{sent=61500000,landed=61506000,items={['agricultural-science-pack']=999}}
  for i=1,5 do pod{sent=61506500+i*100,landed=61506900+i*100,items=i==5 and {['agricultural-science-pack']=80,['agricultural-science-pack@uncommon']=100} or {['agricultural-science-pack']=125}} end
  pod{sent=61507000,landed=61507400,items={['iron-plate']=50}}
  pod{up=true,sent=61508000,items={['agricultural-science-pack']=100}}
  game.tick=61515638; used=1572
  local m=SF.sample(force,nauvis,'agricultural-science-pack',2934)
  eq(m.uncounted,-705,'the statistics alone, signed'); eq(m.landed,680); eq(m.landed_pods,5); eq(m.sent_up,100); eq(m.sent_pods,1)
  eq(m.residual,-125); eq(m.pods_complete,true)
  eq(m.line,"over the last 2.6 min (whole-surface counts at tick 61506411 and now): made 0, used 572; held 2801 then, 2934 now; cargo pods (the pod log): 680 landed in 5 pods, 100 sent up in 1 rocket; residual -125 (-48.8 a minute; held then + made + landed - used - sent up - held now): more came into the stock than these count: what arrived uncounted (cargo pods the log missed, what characters or vehicles brought, items put in by script)")
  eq(m.line:find('spoiled',1,true),nil,'a negative residual is not spoiling')
  has(SF.text(force,nauvis,'agricultural-science-pack'),'residual -48.8 a minute (more came into the stock than these count')
  -- each sign
  has(SF.means(12),'more left the stock than these count: spoiling (no count of it in the game\'s statistics)')
  eq(SF.means(0),'the counts account for every change')
  -- a log that begins after the interval: said
  for i=1,P.KEEP do list[#list+1]={id=1000+i,sent=61515000,items={}} end
  while #list>P.KEEP do table.remove(list,1) end
  eq(P.counted('nauvis','agricultural-science-pack',61506411,61515638).complete,false)
  prototypes=nil
end
print('d25_batch201 QN3 supply residual: signed, each sign said, pods counted: ok')
