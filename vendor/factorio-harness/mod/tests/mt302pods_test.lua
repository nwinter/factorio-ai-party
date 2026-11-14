-- mt302 (private): a cargo pod that comes down on the ground (no landing pad took it) is told to its own team's agents
-- only: one line, where and what it holds; a cap a team per window, the rest counted into the next line.
-- Run from the harness root: lua mod/tests/mt302pods_test.lua
local checks=0
local function eq(a,b,m) checks=checks+1;assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function ok(v,m) checks=checks+1;assert(v,m) end

defines={events={on_cargo_pod_started_ascending=1,on_cargo_pod_finished_ascending=2,on_cargo_pod_finished_descending=3,
  on_cargo_pod_delivered_cargo=4},cargo_destination={invalid=0,station=1,space_platform=2,surface=3,orbit=5},
  inventory={cargo_unit=7},space_platform_state={waiting_at_station=7}}
local told={}
local s={}
local M=dofile('mod/agent-harness_0.1.0/podlog.lua'){state=function() return s end,
  ground_landed=function(force,text) told[#told+1]={force=force,text=text} end}
game={tick=0}

local nauvis={name='nauvis',valid=true,boxes={}}
nauvis.find_entities_filtered=function(f)
  local out={}
  for _,b in ipairs(nauvis.boxes) do if math.abs(b.position.x-f.position.x)<=f.radius and math.abs(b.position.y-f.position.y)<=f.radius then out[#out+1]=b end end
  return out
end
local function platform(name) return {valid=true,name=name,space_location={name='nauvis'}} end
local function hub(pl) return {valid=true,type='space-platform-hub',surface={platform=pl}} end
local unit=100
local function pod(force,pl,items,dest)
  unit=unit+1
  local list={};for name,n in pairs(items) do list[#list+1]={name=name,count=n,quality='normal'} end
  local p={valid=true,unit_number=unit,force={name=force},position={x=0,y=0},surface={platform=pl},
    cargo_pod_origin=hub(pl),cargo_pod_destination=dest or {type=3,surface=nauvis}}
  p.get_inventory=function() return {get_contents=function() return list end} end
  return p
end
-- a pod's whole way down: sent, landed at (x,y), delivered; the reads the tick after
local function fly(p,x,y,t,box)
  M.on_event{name=1,cargo_pod=p,tick=t}
  p.surface=nauvis;p.position={x=x,y=y}
  M.on_event{name=3,cargo_pod=p,tick=t+600}
  if box then nauvis.boxes[#nauvis.boxes+1]={name='cargo-pod-container',position={x=x+0.5,y=y}} end
  game.tick=t+680;M.on_event{name=4,cargo_pod=p,tick=t+680}
  M.tick(t+681)
end

-- 1. A red pod on the ground: red is told once, with the place and the contents; nobody else.
fly(pod('red',platform('red-drop'),{['iron-plate']=50,['copper-plate']=20}),640,650,1000,true)
eq(#told,1);eq(told[1].force,'red','the pod\'s own force')
eq(told[1].text,'Cargo pod from red-drop landed on the ground on Nauvis at (640.5,650), no landing pad took it: 50 iron-plate, 20 copper-plate. It stays there as a cargo-pod-container until emptied.')
-- 2. A blue pod: blue only; red's line names nothing of blue's and blue's nothing of red's.
fly(pod('blue',platform('blue-1'),{coal=10}),-300,20,2000,false)
eq(#told,2);eq(told[2].force,'blue');ok(not told[2].text:find('red',1,true));ok(not told[1].text:find('blue',1,true))
ok(not told[2].text:find('cargo-pod-container',1,true),'no container found: not claimed')
-- 3. A pod that lands on its pad, and a rocket's pod: nothing told.
local pad={valid=true,type='cargo-landing-pad',position={x=10,y=10},surface=nauvis}
pad.get_inventory=function() return {count_empty_stacks=function() return 80 end,get_item_count=function() return 0 end} end
fly(pod('red',platform('red-drop'),{['iron-plate']=50},{type=1,station=pad}),10,10,3000,false)
eq(#told,2,'a pad took it')
local up=pod('red',nil,{['iron-plate']=5});up.cargo_pod_origin={valid=true,type='rocket-silo',unit_number=7,position={x=0,y=0},surface=nauvis}
up.cargo_pod_destination={type=1,station=hub(platform('red-drop'))}
fly(up,0,0,4000,false);eq(#told,2,'a rocket going up: nothing')
-- 4. Many kinds: the four largest and a count of the rest; quality named.
eq(M.summary{a=5,b=9,c=1,d=7,e=3,['f@rare']=8},'9 b, 8 f (rare), 7 d, 5 a, 2 more kinds')
eq(M.summary{},'empty')
-- 5. The cap: TELL_MAX lines a team a window; the rest counted into the first line of the next window.
told={}
for i=1,M.TELL_MAX+3 do fly(pod('green',platform('g'),{stone=i}),i,0,10000+i*10,false) end
eq(#told,M.TELL_MAX-0,'capped')
for _,t in ipairs(told) do eq(t.force,'green') end
fly(pod('green',platform('g'),{stone=1}),0,0,10000+M.TELL_WINDOW+500,false)
eq(#told,M.TELL_MAX+1);ok(told[#told].text:find('(3 more pods landed on the ground before this',1,true),told[#told].text)
-- red's window is its own
fly(pod('red',platform('red-drop'),{stone=1}),0,0,10000+M.TELL_WINDOW+600,false);eq(told[#told].force,'red')
ok(not told[#told].text:find('more pod',1,true),'red owes nothing held')

defines,game=nil,nil
print('mt302 ground pods: ok ('..checks..' checks)')
