-- Run from repository root: lua tests/d28_batch320.lua
-- (d28 batch320 LP, Sol #2711: "ledger lacks automatic/manual provenance") Lark's request (min 3500, max 4500, minimum
-- payload 1000) got rockets of 1000, 1000 and 683. On a copy (2.0.77) a hub lacking L = min - (holds + on the way) gets
-- max(L, payload), cut into rockets of up to a rocket's lift; the last carries the rest. The game's launch event names a
-- player only for a player's own launch, so the ledger now records who ordered each launch (this harness's launch marks
-- the silo; else a player; else automatic, which a script's launch_rocket looks the same as) and, per cargo item, the
-- request then: min, max, payload, holds, on the way (podlog: rockets sent and not landed), this rocket's count. On main
-- the ledger has no ordered and no request, and podlog no on_the_way.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
game={tick=78348594,get_player=function(i) return i==3 and {name='nick'} or nil end}
defines={inventory={cargo_unit=1},cargo_destination={station=1,space_platform=2,orbit=3}}
local st={}
-- podlog: Lark has one rocket of 1000 sent and not landed, and one landed
local P=dofile('mod/agent-harness_0.1.0/podlog.lua'){state=function() return st end}
st.podlog={seq=2,open={[101]={planet='vulcanus',id=1,tick=78347924},[102]={planet='vulcanus',id=2,tick=78345309}},
  by={vulcanus={{id=2,up=true,platform='Lark',items={['metallurgic-science-pack']=1000},landed=78347300},
               {id=1,up=true,platform='Lark',items={['metallurgic-science-pack']=1000}}}}}
-- (find walks newest first by id: the list is in id order)
table.sort(st.podlog.by.vulcanus,function(x,y) return x.id<y.id end)
local n,k=P.on_the_way('Lark','metallurgic-science-pack')
eq(n,1000); eq(k,1)
eq((P.on_the_way('Lark','calcite')),0); eq((P.on_the_way('Anvil','metallurgic-science-pack')),0)
eq((P.on_the_way('Lark')),1000,'every item')

local L=dofile('mod/agent-harness_0.1.0/ledger.lua'){state=function() return st end,on_the_way=function(pl,item) return P.on_the_way(pl,item) end}
local held=1812
local hub={get_item_count=function() return held end,get_logistic_sections=function() return {sections_count=1,get_section=function()
  return {active=true,filters={{value={name='metallurgic-science-pack'},min=3500,max=4500,minimum_delivery_count=1000,import_from={name='vulcanus'}}}} end} end}
local lark={valid=true,name='Lark',hub=hub}
local function launch(silo_unit,count,player)
  local silo={valid=true,unit_number=silo_unit,position={x=-28.5,y=221.5},surface={name='vulcanus'}}
  local pod={get_inventory=function() return {get_contents=function() return {{name='metallurgic-science-pack',count=count}} end} end,
    cargo_pod_destination={station={valid=true,surface={platform=lark}}}}
  L.on_launch({rocket_silo=silo,rocket={attached_cargo_pod=pod},player_index=player})
end
-- the silo's own launch of the last 688: held 1812 + 1000 on the way + 688 = 3500, the min
launch(21643437,688)
local lines,launches=L.read('vulcanus',{})
local r=launches[#launches]
eq(r.ordered,'automatic (or a script: the game names no player)')
eq(r.cargo,'metallurgic-science-pack*688')
local q=r.request[1]
eq(q.item,'metallurgic-science-pack'); eq(q.min,3500); eq(q.max,4500); eq(q.payload,1000); eq(q.holds,1812)
eq(q.on_the_way,1000); eq(q.rockets,1); eq(q.this,688)
eq(q.holds+q.on_the_way+q.this,q.min,'the rest of the delivery brings it to the min')
has(lines[#lines],'Lark asked metallurgic-science-pack 3500 (holds 1812), max 4500, minimum payload 1000; 1000 on the way in 1 rocket; with this rocket\'s 688: 3500')
has(lines[#lines],'(ordered: automatic (or a script: the game names no player))')
-- this harness's launch marks the silo and tick: the ledger names the agent
game.tick=game.tick+100
st.launch_mark={tick=game.tick,unit=21655668,by='sol'}
launch(21655668,1000)
lines,launches=L.read('vulcanus',{})
eq(launches[#launches].ordered,'harness launch by sol')
has(lines[#lines],'(ordered: harness launch by sol)')
eq(st.launch_mark,nil,'the mark is used once')
-- a mark of another silo or tick is not this launch
game.tick=game.tick+100
st.launch_mark={tick=game.tick-1,unit=38930,by='sol'}
launch(38930,1000)
eq(select(2,L.read('vulcanus',{}))[3].ordered,'automatic (or a script: the game names no player)')
-- a player's own launch names the player
game.tick=game.tick+100
launch(10611101,50,3)
eq(select(2,L.read('vulcanus',{}))[4].ordered,'player nick')
print('d28_batch320 ok')
