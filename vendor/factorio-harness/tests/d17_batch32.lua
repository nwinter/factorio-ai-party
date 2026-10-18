-- d17 batch32. Run from the harness root: lua tests/d17_batch32.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,msg) assert(a==b,(msg or '')..' '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end

-- A1 (Grok: 241 agricultural science packs went to rocket_silo_trash): what aboard no platform above asks for.
do
  game={tick=1000}
  defines={inventory={hub_main=1,rocket_silo_rocket=14,rocket_silo_trash=15}}
  prototypes={item={['agricultural-science-pack']={weight=1000,stack_size=200},['bioflux']={weight=1000,stack_size=100}},utility_constants={rocket_lift_weight=1000000}}
  local S=dofile('mod/agent-harness_0.1.0/silo.lua'){state=function() return {} end}
  local aboard={{name='agricultural-science-pack',count=241,quality='normal'}}
  local rocket={get_contents=function() return aboard end}
  local e={surface={name='gleba',planet={name='gleba'}},position={x=0,y=0},get_inventory=function(i) return i==14 and rocket or nil end}
  local asks={}
  local main={count_empty_stacks=function() return 20 end}
  local hub={valid=true,get_inventory=function() return main end,get_item_count=function() return 0 end,get_logistic_sections=function() return {sections_count=1,get_section=function() return {active=true,filters=asks} end} end}
  local force={platforms={{valid=true,name='Swift',space_location={name='gleba'},hub=hub}},logistic_networks={}}
  local r=S.trash_risk(e,force)
  eq(r.lost,'agricultural-science-pack*241'); eq(r.lost_count,241); eq(r.asked,nil)
  eq(r.line,'the rocket holds agricultural-science-pack*241 that no platform stopped above asks this planet for: with automatic requests on the game moves it into the silo\'s trash slots, which never launch')
  -- a platform above asks for it: nothing lost
  asks[1]={value={name='agricultural-science-pack'},min=500,import_from='gleba'}
  r=S.trash_risk(e,force)
  eq(r.lost,nil); eq(r.asked,'agricultural-science-pack*241'); has(r.line,'that a platform above asks for')
  aboard={{name='bioflux',count=40},{name='agricultural-science-pack',count=10}}
  r=S.trash_risk(e,force)
  eq(r.lost,'bioflux*40'); eq(r.asked,'agricultural-science-pack*10')
  aboard={}
  eq(S.trash_risk(e,force),nil)
  game,defines,prototypes=nil,nil,nil
end
print('d17_batch32 A1 silo trash risk: ok')

-- A3 (Grok, twice: the pentapod egg and copper bacteria loops died between checks): a seed alert to the loop's builders
-- when a seed on a surface runs low or out, with the machines that need it.
do
  defines={inventory={assembling_machine_input=2,assembling_machine_output=3,chest=1}}
  prototypes={recipe={['copper-bacteria-cultivation']={name='copper-bacteria-cultivation',ingredients={{type='item',name='copper-bacteria',amount=1},{type='item',name='bioflux',amount=1}}},
    ['pentapod-egg']={name='pentapod-egg',ingredients={{type='item',name='pentapod-egg',amount=1},{type='item',name='nutrients',amount=30}}},
    ['bioflux']={name='bioflux',ingredients={{type='item',name='yumako-mash',amount=15}}}}}
  local function inv(stacks)
    local t={stacks=stacks}
    t.get_item_count=function(n) local k=0; for _,st in ipairs(t.stacks) do if st.name==n then k=k+st.count end end return k end
    return setmetatable(t,{__len=function() return #t.stacks end,__index=function(_,i) local st=t.stacks[i]; return st and {valid_for_read=true,name=st.name,count=st.count,spoil_tick=st.spoil} end})
  end
  local function chamber(x,recipe,input,output,user)
    return {valid=true,name='biochamber',type='assembling-machine',position={x=x,y=0},bounding_box={left_top={x=x-1.5,y=-1.5},right_bottom={x=x+1.5,y=1.5}},
      last_user={name=user},get_recipe=function() return {name=recipe} end,
      get_inventory=function(i) if i==2 then return input elseif i==3 then return output end end}
  end
  local in1,out1,in2=inv({{name='copper-bacteria',count=3,spoil=20000}}),inv({}),inv({})
  local c1,c2=chamber(0,'copper-bacteria-cultivation',in1,out1,'grok'),chamber(10,'copper-bacteria-cultivation',in2,inv({}),'grok')
  local other=chamber(20,'bioflux',inv({}),inv({}),'sol')
  local feeder={valid=true,type='inserter',position={x=0,y=2},drop_target=c1,last_user={name='luna'},held_stack={valid_for_read=false},pickup_target=nil}
  local surface={name='gleba',index=4,planet={name='gleba'},find_entities_filtered=function(f)
    local out={}
    for _,e in ipairs({feeder}) do if e.position.x>=f.area[1][1] and e.position.x<=f.area[2][1] and e.position.y>=f.area[1][2] and e.position.y<=f.area[2][2] then out[#out+1]=e end end
    return out end}
  local force={name='player',players={},logistic_networks={gleba={}}}
  game={tick=10000,surfaces={surface},forces={player=force}}
  local sent={}
  local st={}
  local S=dofile('mod/agent-harness_0.1.0/seeds.lua'){state=function() return st end,crafters=function() return {c1,c2,other} end,
    deliver=function(i,t) sent[#sent+1]={i=i,t=t} end,index_of=function(n) return ({grok=1,luna=2,sol=3})[n] end}
  local rows=S.read(force,surface)
  eq(rows['copper-bacteria'].count,3); eq(#rows['copper-bacteria'].machines,2); eq(rows['pentapod-egg'],nil)
  -- 3 for 2 machines (one craft each) and spoiling in 167 s: low, by the spoil
  game.tick=9641; S.tick(game.tick)
  eq(#sent,2,'grok (built) and luna (feeds it)')
  eq(sent[1].i,1); eq(sent[2].i,2); eq(sent[1].t.from,'seed alert'); eq(sent[1].t.wake,true)
  eq(sent[1].t.text,'seed alert: 3 copper-bacteria left on gleba for 2 machines that use it (biochamber (0,0) copper-bacteria-cultivation, biochamber (10,0) copper-bacteria-cultivation), and all of it spoils within 172s; with none left they cannot restart')
  -- the same state: told once
  game.tick=game.tick+600; S.tick(game.tick); eq(#sent,2)
  -- zero
  in1.stacks={}
  game.tick=game.tick+600; S.tick(game.tick)
  eq(#sent,4); has(sent[3].t.text,'seed alert: no copper-bacteria left on gleba in the 2 machines that use it'); has(sent[3].t.text,'they cannot restart without it')
  -- recovered, then low by count (under one craft each)
  in1.stacks={{name='copper-bacteria',count=50}}; in2.stacks={{name='copper-bacteria',count=50}}
  game.tick=game.tick+600; S.tick(game.tick); eq(#sent,4)
  in1.stacks={{name='copper-bacteria',count=1}}; in2.stacks={}
  game.tick=game.tick+600; S.tick(game.tick)
  eq(#sent,6); has(sent[5].t.text,'1 copper-bacteria left on gleba for 2 machines'); has(sent[5].t.text,'under one craft each (2)')
  game,defines,prototypes=nil,nil,nil
end
print('d17_batch32 A3 seed alerts: ok')
