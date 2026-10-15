-- Run from repository root: lua tests/packaudit.lua
-- Luna, 16:50: one pack's freight across planets and platforms in one read (she combined science on Gleba with
-- supply on Nauvis by hand). Fake engine.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
local AG='agricultural-science-pack'
defines={inventory={chest=1,cargo_landing_pad_main=2,rocket_silo_rocket=3,lab_input=4,hub_main=5,hub_trash=6},flow_precision_index={ten_minutes=3}}
prototypes={item={[AG]={weight=1000},['iron-plate']={}}}
game={tick=100000}
-- An inventory of stacks; each stack spoils at its tick.
local function inv(stacks)
  local t={}
  for i,s in ipairs(stacks or {}) do t[i]={valid_for_read=true,name=s[1],count=s[2],spoil_tick=s[3],spoil_percent=s[4] or 0} end
  t.get_item_count=function(name) local n=0; for _,s in ipairs(t) do if s.name==name then n=n+s.count end end; return n end
  return setmetatable(t,{__len=function() return #stacks end})
end
local force={name='player',current_research={research_unit_ingredients={{name=AG,amount=1}}}}
local function find(list) return function(f) local out={} for _,e in ipairs(list) do if e.type==f.type then out[#out+1]=e end end return out end end
-- Gleba: a network holding 300 (one provider chest, 200 of it spoiling in 2 min), a requester short 40, 2 labs (one
-- empty), a silo with 50 in its rocket.
local provider={valid=true,type='logistic-container',name='passive-provider-chest',position={x=10,y=10}}
local pchest=inv({{AG,200,game.tick+7200,0.6},{AG,100,game.tick+20000,0.2}})
provider.get_inventory=function() return pchest end
local requester={valid=true,type='logistic-container',name='requester-chest',position={x=20,y=10},get_item_count=function() return 10 end}
local net={get_item_count=function(n) return n==AG and 300 or 0 end,provider_points={{owner=provider}},storage_points={},
  requester_points={{owner=requester,filters={{name=AG,count=100}},targeted_items_deliver={{name=AG,count=50}}}}}
local labs={{valid=true,type='lab',get_inventory=function() return inv({{AG,20,game.tick+50000}}) end},{valid=true,type='lab',get_inventory=function() return inv({}) end}}
local silo={valid=true,type='rocket-silo',position={x=65.5,y=14.5}}
local cargo=inv({{AG,50,game.tick+30000,0.1}})
silo.get_inventory=function() return cargo end
local gleba={name='gleba',find_entities_filtered=find({labs[1],labs[2],silo})}
-- Nauvis: a landing pad with 80; no network; 1 lab holding none.
local pad={valid=true,type='cargo-landing-pad',position={x=0,y=0}}
local padinv=inv({{AG,80,game.tick+3600,0.9}})
pad.get_inventory=function() return padinv end
local nauvis={name='nauvis',find_entities_filtered=find({pad,{valid=true,type='lab',get_inventory=function() return inv({}) end}})}
-- Vulcanus: nothing of it.
local vulcanus={name='vulcanus',find_entities_filtered=find({})}
-- Sunward: flying to nauvis with 400 in its hub, 200 spoiling before the arrival; its hub asks 0..2000 from gleba.
local hubmain=inv({{AG,200,game.tick+600,0.95},{AG,200,game.tick+40000,0.3}})
local hub={valid=true,get_inventory=function(id) return id==5 and hubmain or inv({}) end,
  get_logistic_sections=function() return {sections_count=1,get_section=function() return {active=true,filters={{value={name=AG},min=500,max=2000,import_from={name='gleba'}}}} end} end}
local sunward={valid=true,name='Sunward',hub=hub}
local platsurf={name='platform-1',platform=sunward}
force.platforms={sunward,{valid=true,name='Empty',hub={valid=true,get_inventory=function() return inv({}) end,get_logistic_sections=function() return {sections_count=0} end}}}
force.logistic_networks={gleba={net}}
local made={gleba={input=600,output=300},nauvis={input=0,output=900}}
force.get_item_production_statistics=function(s) return {get_flow_count=function(f) return (made[s.name] or {})[f.category] or 0 end} end
game.surfaces={nauvis,gleba,vulcanus,platsurf}
local spoil=dofile('mod/agent-harness_0.1.0/spoil.lua'){state=function() return {} end}
local cache={}
local A=dofile('mod/agent-harness_0.1.0/packaudit.lua'){spoil=spoil,
  reuse=function(key,fn) cache[key]=cache[key] or fn(); return cache[key] end,
  where=function(pl) return {text='flying gleba->nauvis 50%',leg={to='nauvis',eta_ticks=3000}} end,
  rocket_room=function(s,item) return 950 end}
local r=A.read({force=force},{item=AG})
eq(r.total,300+50+20+80+400); eq(r.research_needs_it,true)
eq(#r.planets,2,'vulcanus holds none of it')
eq(r.lines[1],'gleba: made 60/min, used 30/min; logistic networks 300; their requesters lack 40 (1 requester); rocket-silo (65.5,14.5): 50 in its rocket, room for 950 more by weight; labs 2 hold 20, 1 of them none (the research needs it); the first spoils in 2m00s (60% spoiled) at passive-provider-chest (10,10)')
eq(r.lines[2],'nauvis: made 0/min, used 90/min; logistic networks 0; landing pads 80; labs 1 hold 0, 1 of them none (the research needs it); the first spoils in 1m00s (90% spoiled) at cargo-landing-pad (0,0)')
eq(r.lines[3],'platform Sunward (flying gleba->nauvis 50%): hub 400; the first spoils in 10s (95% spoiled) at its hub; arrives at nauvis in 50s: 200 spoil before it; requests 500..2000 from gleba, 100 short')
eq(#r.platforms,1,'a platform with none and no request is left out')
eq(r.planets[1].unmet,40); eq(r.planets[1].labs_without,1); eq(r.platforms[1].spoil_before_arrival,200)
fails(function() A.read({force=force},{item='nope'}) end,'item must be an item name')
print('packaudit: ok')
