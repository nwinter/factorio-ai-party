-- d18 batch36. Run from the harness root: lua tests/d18_batch36.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end

-- A1 (Luna and Grok, all of shift35: Gleba's science requester lacked 10 nutrients for about 36 minutes, "all 250
-- logistic bots occupied"): logistics_audit {backlog}: the oldest unfilled requests and what holds each now.
do
  game={tick=2000000}
  defines={inventory={chest=1,robot_cargo=2},robot_order_type={deliver=1,pickup=2}}
  local function chest(id,x,y,item,want,have,coming)
    local e={valid=true,name='requester-chest',type='logistic-container',unit_number=id,position={x=x,y=y},
      get_item_count=function() return have end,get_inventory=function() return {count_empty_stacks=function() return 10 end,get_contents=function() return have>0 and {{name=item,count=have}} or {} end,can_insert=function() return true end} end}
    return {owner=e,filters={{name=item,quality='normal',count=want}},targeted_items_deliver=coming or {}}
  end
  local provider={valid=true,name='passive-provider-chest',position={x=24.5,y=28.5},get_item_count=function() return 98 end}
  local pick={owner=provider,targeted_items_pickup={{name='nutrients',quality='normal',count=0}}}
  local function robot(cargo,orders)
    return {robot_order_queue=orders or {},get_inventory=function() return {[1]=cargo and {valid_for_read=true,name=cargo[1],count=cargo[2]} or {valid_for_read=false}} end}
  end
  local robots={}
  for i=1,3 do robots[#robots+1]=robot({'firearm-magazine',4}) end
  robots[#robots+1]=robot({'ice',10},{{type=1}})
  robots[#robots+1]=robot(nil,{{type=2}})
  local cellowner={valid=true,name='roboport',prototype={logistic_parameters={charging_station_count=4}}}
  local supply={nutrients=98,['advanced-circuit']=0}
  local ln={network_id=98,all_logistic_robots=5,available_logistic_robots=0,logistic_robots=robots,
    cells={{owner=cellowner,charging_robot_count=1,to_charge_robot_count=2},{owner=cellowner,charging_robot_count=0,to_charge_robot_count=0}},
    requester_points={chest(1,15.5,28.5,'nutrients',10,0),chest(2,20.5,59.5,'advanced-circuit',8,0),chest(3,8.5,40.5,'nutrients',5,5)},
    get_supply_counts=function(q) local n=supply[type(q)=='table' and q.name or q] or 0; return {['passive-provider']=n} end,
    select_pickup_point=function(t) if supply[t.name.name]>0 then return pick end end}
  -- the networks watch first saw the science chest short 36 minutes ago, the circuits 8 hours ago
  local st={networks={unfilled={['1|nutrients|normal']=2000000-36*3600,['2|advanced-circuit|normal']=2000000-480*3600}}}
  local L=dofile('mod/agent-harness_0.1.0/logaudit.lua'){state=function() return st end}
  local r=L.backlog({},{},{name='gleba'},ln)
  eq(r.requests_short,2); eq(r.robots.idle,0); eq(r.robots.cargo_no_order,3); eq(r.robots.charging_slots,8); eq(r.robots.free_charging_slots,7)
  eq(r.robots_line,'5 logistic robots: 0 idle, on orders deliver 1, pickup 1 (carrying ice 10), 3 holding cargo with no order (firearm-magazine 12); 1 charging, 2 queued to charge at its roboports, 8 charging slots (7 free)')
  -- oldest first: the circuits, none in the network
  eq(r.requests[1].item,'advanced-circuit'); eq(r.requests[1].held_by,'none of it in the network\'s providers or storage')
  local sci=r.requests[2]
  eq(sci.item,'nutrients'); eq(sci.short_s,36*60); eq(sci.provider.holds,98); eq(sci.provider.distance,9)
  eq(sci.held_by,'no idle logistic robot of 5: 3 hold cargo with no order to put it anywhere (firearm-magazine 12; logistics_audit {storage: true} reads where it could go); on orders deliver 1, pickup 1 (carrying ice 10); 2 queued to charge')
  eq(r.lines[2],'requester-chest (15.5,28.5): nutrients 10 short (has 0 of 10) for 36m00s; the provider the game picks: passive-provider-chest (24.5,28.5), 9 tiles, holds 98 (0 reserved); held by: '..sci.held_by)
  -- every unit at the provider reserved
  pick.targeted_items_pickup={{name='nutrients',quality='normal',count=98}}
  eq(L.backlog({},{},{name='gleba'},ln).requests[2].held_by,'the provider the game picks holds 98, all reserved by robots on the way')
  -- idle robots and an unreserved provider: not sent yet
  pick.targeted_items_pickup={}; ln.available_logistic_robots=2
  has(L.backlog({},{},{name='gleba'},ln).requests[2].held_by,'2 idle robots and 98 unreserved at the provider: not sent yet')
  -- a charging queue with every slot taken
  ln.cells[1].charging_robot_count=4; ln.cells[2].charging_robot_count=4
  eq(L.backlog({},{},{name='gleba'},ln).requests[2].held_by,'robots queued to charge: 2 waiting, every one of 8 charging slots taken')
  -- through read
  fails(function() L.read({force={logistic_networks={gleba={ln}}},surface={name='gleba'}},{network=98,backlog='yes'}) end,'backlog is true')
  defines,game=nil,nil
end
print('d18_batch36 A1 logistics_audit backlog: ok')
