-- Run from repository root: lua tests/spoil.lua
-- Spoilage in the reads and the egg watch (spoil.lua) against fakes shaped
-- like 2.0.77's (Sol, shift10 04:59: stored pentapod eggs hatched in his camp).
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(text,part) assert(text and tostring(text):find(part,1,true),tostring(text)..' lacks '..part) end
game={tick=1000,surfaces={},forces={}}
defines={inventory={chest=1,assembling_machine_input=2,assembling_machine_output=3,character_main=4,character_trash=5,hub_main=6,
  furnace_source=7,furnace_result=8,cargo_wagon=9,car_trunk=10,spider_trunk=11,cargo_landing_pad_main=12,rocket_silo_rocket=13}}
-- The real egg trigger's shape: create-entity as an enemy, with a fallback that creates the same.
local function trigger(entity,per)
  return {items_per_trigger=per,trigger={{action_delivery={{source_effects={{type='create-entity',entity_name=entity,as_enemy=true,
    non_colliding_fail_result={{action_delivery={{source_effects={{type='create-entity',entity_name=entity,as_enemy=true}},type='instant'}}}}}},type='instant'}},type='direct'}}}
end
local SPOIL={['pentapod-egg']=54000,['biter-egg']=108000,yumako=3600*60,['yumako-mash']=180*60,jelly=240*60,bioflux=7200*60,nutrients=300*60}
prototypes={item={}}
for name,ticks in pairs(SPOIL) do prototypes.item[name]={name=name,get_spoil_ticks=function() return ticks end} end
prototypes.item['iron-plate']={name='iron-plate',get_spoil_ticks=function() return 0 end}
prototypes.item['pentapod-egg'].spoil_to_trigger_result=trigger('big-wriggler-pentapod-premature',1)
prototypes.item['biter-egg'].spoil_to_trigger_result=trigger('big-biter',25)
local st={}
local S=dofile('mod/agent-harness_0.1.0/spoil.lua'){state=function() return st end,force=function() return game.forces.player end,
  characters=function() return {} end}

-- What hatches: an item whose spoil trigger creates an entity as an enemy.
eq(S.hatch('pentapod-egg').entity,'big-wriggler-pentapod-premature'); eq(S.hatch('pentapod-egg').per,1)
eq(S.hatch('biter-egg').per,25); eq(S.per_text(S.hatch('biter-egg')),'one per 25'); eq(S.per_text(S.hatch('pentapod-egg')),'one each')
eq(S.hatch('yumako'),false); eq(S.hatch('iron-plate'),false)
eq(#S.hatching(),2); eq(S.hatching()[1],'biter-egg')
eq(S.spoils('jelly'),true); eq(S.spoils('iron-plate'),false)

-- Stacks: per item the count, the first to spoil and how many within 5 min.
local function stack(name,count,left,pct) return {valid_for_read=true,name=name,count=count,quality={name='normal'},spoil_tick=left and game.tick+left or 0,spoil_percent=pct or 0} end
local function inv(list)
  local t={valid=true}
  for i,s in ipairs(list) do t[i]=s end
  t.get_item_count=function(name) local n=0; for i=1,#t do if t[i].valid_for_read and t[i].name==name then n=n+t[i].count end end; return n end
  return t
end
local chest=inv{stack('pentapod-egg',10,4*3600,0.73),stack('pentapod-egg',5,10*3600,0.33),stack('yumako',20,30*3600,0.5),stack('iron-plate',100)}
local acc=S.inventory(chest,{},'chest')
eq(#acc,2); eq(acc['pentapod-egg'].count,15); eq(acc['pentapod-egg'].soon,10); eq(acc.yumako.soon,0)
local lines=S.lines(acc,8,'chest: ')
eq(lines[1],'chest: pentapod-egg*15: the first hatches in 4m00s into big-wriggler-pentapod-premature (73% spoiled); 10 within 5 min')
eq(lines[2],'chest: yumako*20: the first spoils in 30m00s (50% spoiled)')
eq(S.warning(acc),'15 pentapod-egg hatch into enemies (big-wriggler-pentapod-premature, one each): the first in 4m00s, 10 within 5 min')
eq(S.warning(S.inventory(inv{stack('yumako',3,60,0.9)},{})),nil)
-- The spread (Sol, 22:25: a chest of 1846 agricultural packs showed the oldest at 91% while hundreds were at
-- 15-30%): least and most spoiled, the count-weighted share, the four shares, and how many spoil within 10/30/60 min.
do
  local packs=inv{stack('agricultural-science-pack',200,5*3600,0.91),stack('agricultural-science-pack',200,20*3600,0.6),
    stack('agricultural-science-pack',200,40*3600,0.3),stack('agricultural-science-pack',200,50*3600,0.15),stack('agricultural-science-pack',46,55*3600,0.15)}
  local a=S.inventory(packs,{},'chest')
  local r=a['agricultural-science-pack']
  eq(S.spread_text(r),'agricultural-science-pack*846: spoiled 15-91%, 47% by count; under 25% 246, 25-50% 200, 50-75% 200, 75%+ 200; '
    ..'spoil within 10 min 200, 30 min 400, 60 min 846')
  local s=S.spread(r); eq(s.mean,47); eq(s.buckets['75+'],200); eq(s.within['10min'],200)
  -- Merged over two places.
  local all={}
  S.merge(all,r); S.merge(all,S.inventory(inv{stack('agricultural-science-pack',100,59*3600,0.05)},{})['agricultural-science-pack'])
  eq(all[1].count,946); eq(S.spread(all[1]).min,5); eq(S.spread(all[1]).max,91); eq(all[1].buckets[1],346)
end
-- A belt's lanes carry stacks with their spoilage.
local belt={get_max_transport_line_index=function() return 2 end,get_transport_line=function(i)
  return {get_detailed_contents=function() return i==1 and {{stack=stack('jelly',1,600,0.95)},{stack=stack('jelly',1,1200,0.9)}} or {} end} end}
local b=S.belt(belt,{},'belt')
eq(b.jelly.count,2); eq(S.lines(b)[1],'jelly*2: the first spoils in 10s (95% spoiled); all within 5 min')

-- Recipe outputs: the count-weighted spoilage of the spoilable ingredients
-- (bioflux, read on a private copy: 15 mash at 80% and 12 jelly at 20% made bioflux at 53.5%).
local function recipe(name,ings,prods,flags)
  local r={name=name,ingredients={},products={},prototype=flags or {}}
  for _,i in ipairs(ings) do r.ingredients[#r.ingredients+1]={type='item',name=i[1],amount=i[2]} end
  for _,pname in ipairs(prods) do r.products[#r.products+1]={type='item',name=pname,amount=4} end
  return r
end
local bioflux=recipe('bioflux',{{'yumako-mash',15},{'jelly',12}},{'bioflux'},{result_is_always_fresh=false,reset_freshness_on_craft=false})
local input=inv{stack('yumako-mash',30,600,0.8),stack('jelly',24,600,0.2)}
eq(S.recipe_output(nil,bioflux,input),'bioflux start about 53% spoiled (recipe bioflux: the count-weighted spoilage of yumako-mash*15 at 80%, jelly*12 at 20%)')
-- Only some ingredients in the input: weighted over those, the rest named.
eq(S.recipe_output(nil,bioflux,inv{stack('jelly',24,600,0.2)}),'bioflux start about 20% spoiled (recipe bioflux: the count-weighted spoilage of jelly*12 at 20%; not in the input: yumako-mash)')
has(S.recipe_output(nil,bioflux,inv{}),'none in the input: yumako-mash, jelly')
-- A recipe that resets freshness (pentapod-egg: eggs bred from nutrients at 80% came out fresh).
local breed=recipe('pentapod-egg',{{'nutrients',30},{'pentapod-egg',1}},{'pentapod-egg'},{reset_freshness_on_craft=true})
eq(S.recipe_output(nil,breed,input),'pentapod-egg start fresh (recipe pentapod-egg resets freshness)')
eq(S.recipe_output(nil,recipe('iron-gear-wheel',{{'iron-plate',2}},{'iron-plate'}),input),nil)

-- The egg watch on Gleba: anchors where eggs are made or used, the cells
-- around them read a stage a tick, news once under 5 min and again under 1.
local force={name='player',platforms={}}
local stats={get_input_count=function(name) return name=='pentapod-egg' and 577 or 0 end,get_output_count=function() return 0 end}
force.get_item_production_statistics=function(s) return s.name=='gleba' and stats or {get_input_count=function() return 0 end,get_output_count=function() return 0 end} end
game.forces.player=force
local function entity(name,type_,pos,invs,extra)
  local e={valid=true,name=name,type=type_,position=pos,unit_number=#name*1000+math.floor(pos.x*10+pos.y),force=force}
  e.get_inventory=function(id) return invs and invs[id] or nil end
  e.get_recipe=function() return extra and extra.recipe end
  for k,v in pairs(extra or {}) do e[k]=v end
  return e
end
local gleba={name='gleba',index=5}
local nauvis={name='nauvis',index=1}
local egg_chest_inv=inv{stack('pentapod-egg',15,4*3600+600,0.7)}
local egg_chest=entity('wooden-chest','container',{x=46.5,y=48.5},{[1]=egg_chest_inv},{last_user={name='sol'}})
local bio=entity('biochamber','assembling-machine',{x=49.5,y=44.5},{[2]=inv{},[3]=inv{stack('pentapod-egg',3,6*3600,0.5)}},{recipe=breed})
local far=entity('wooden-chest','container',{x=400.5,y=400.5},{[1]=inv{stack('pentapod-egg',1,60,0.99)}})
for _,e in ipairs{egg_chest,bio,far} do e.surface=gleba end
local finds=0
gleba.find_entities_filtered=function(f)
  finds=finds+1
  local out={}
  for _,e in ipairs{egg_chest,bio,far} do
    local ok=true
    if f.area then local a=f.area; ok=e.position.x>=a[1][1] and e.position.x<a[2][1] and e.position.y>=a[1][2] and e.position.y<a[2][2] end
    if f.type then local hit=false; for _,t in ipairs(type(f.type)=='table' and f.type or {f.type}) do if t==e.type then hit=true end end; ok=ok and hit end
    if ok then out[#out+1]=e end
  end
  return out
end
nauvis.find_entities_filtered=function() error('nauvis has no egg flow: never searched') end
game.surfaces={nauvis=nauvis,gleba=gleba}
setmetatable(game.surfaces,{__pairs=function(t) return next,{nauvis=nauvis,gleba=gleba},nil end})
local function run(n) for _=1,n do game.tick=game.tick+1; S.tick(game.tick) end end
run(4) -- anchors, a job walked in bands (walk.lua): the biochamber that breeds eggs (cell 0,0 of gleba); nauvis never searched
eq(st.eggs.anchor_job,nil); eq(st.eggs.anchors['gleba|0,0'].x,0); eq(st.eggs.watched[1],'pentapod-egg'); eq(#st.eggs.watched,1)
run(10)
-- The chest and the biochamber share a cell: one place (the chest's eggs first), the far chest is not looked at.
eq(#st.eggs.places,1); local place=st.eggs.places[1]
eq(place.entity,'wooden-chest'); eq(place.count,15); eq(place.by,'sol')
-- Its first stack hatches in about 4 minutes: news, once.
local sol={index=2,name='sol',surface={name='gleba'}}
local luna={index=3,name='luna',surface={name='nauvis'}}
eq(st.eggs.seq,1); eq(place.news,1)
local hs,hl={},{}
local lines=S.alert_lines(sol,hs,'sol')
eq(#lines,1)
eq(lines[1],'eggs hatching: 15 pentapod-egg in wooden-chest at (46.5,48.5): the first hatch into big-wriggler-pentapod-premature in 4m10s (70% spoiled), all within 5 min')
eq(#S.alert_lines(sol,hs,'sol'),0) -- told once
eq(#S.alert_lines(luna,hl,'luna'),0) -- another surface, not built by luna
-- Built by the reader: heard on any surface.
local hb={}
eq(#S.alert_lines({index=4,name='sol',surface={name='nauvis'}},hb,'sol'),1)
-- A sleeper wakes on news after its sleep began.
eq(S.news(sol,0,'sol') ~= nil,true); eq(S.news(sol,1,'sol'),nil)
-- Under 1 minute: news again, and told again.
game.tick=game.tick+3*3600+900 -- about 55 s left
run(1+10)
place=st.eggs.places[1]
eq(st.eggs.seq,2); eq(place.news,2)
lines=S.alert_lines(sol,hs,'sol')
eq(#lines,1); has(lines[1],'the first hatch into big-wriggler-pentapod-premature in')
has(S.news(sol,1,'sol'),'eggs hatching: 15 pentapod-egg')
-- Hatched, while the biochamber's later eggs stay in the cell: a new batch, told again under 5 min.
egg_chest_inv[1]={valid_for_read=false}
game.tick=game.tick+1800
run(12)
place=st.eggs.places[1]
eq(place.entity,'biochamber'); eq(place.count,3); eq(place.news,3); eq(st.eggs.seq,3)
lines=S.alert_lines(sol,hs,'sol')
eq(#lines,1); has(lines[1],'3 pentapod-egg in biochamber at (49.5,44.5)')
-- All gone: nothing left to tell.
bio.get_inventory=function() return inv{} end
game.tick=game.tick+1800
run(12)
eq(#st.eggs.places,0); eq(#S.alert_lines(sol,{},'sol'),0)
print('spoil: ok')
