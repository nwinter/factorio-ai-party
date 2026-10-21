-- d20 batch59 (operator 22:55). Run from the harness root: lua tests/d20_batch59.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,msg) assert(a==b,(msg or '')..' '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end

-- U1 (Astra #1480): the character GUI's switches and slot filters; a request counts the gun, ammo and armor slots, and
-- robots bring nothing no slot takes.
do
  defines={logistic_member_index={character_requester=1},inventory={character_guns=2,character_ammo=3,character_armor=5}}
  prototypes={item={wood={},['firearm-magazine']={},pipe={},['iron-plate']={}},quality={normal={},rare={}}}
  game={tick=100}
  -- An inventory of n slots: stacks {name, count}, filters by slot.
  local function inventory(n,stacks,only)
    local inv={filters={only and {name=only} or nil}}
    for i=1,n do
      local st=stacks[i]
      inv[i]=st and {valid_for_read=true,name=st[1],count=st[2],quality='normal'} or {valid_for_read=false}
    end
    setmetatable(inv,{__len=function() return n end})
    function inv.get_filter(i) return inv.filters[i] end
    function inv.set_filter(i,f) inv.filters[i]=f and {name=f.name,quality=f.quality} or nil; return true end
    function inv.get_item_count(q)
      local name=type(q)=='table' and q.name or q
      local c=0; for i=1,n do if inv[i].valid_for_read and inv[i].name==name then c=c+inv[i].count end end; return c
    end
    function inv.can_insert(q)
      for i=1,n do
        if inv[i].valid_for_read and inv[i].name==q.name and inv[i].count<100 then return true end
        if not inv[i].valid_for_read and (not inv.filters[i] or inv.filters[i].name==q.name) then return true end
      end
      return false
    end
    return inv
  end
  local main=inventory(4,{{'iron-plate',50},nil,{'wood',10},nil})
  local ammo=inventory(1,{{'firearm-magazine',100}},'firearm-magazine')
  local guns=inventory(1,{},'pistol')
  local armor=inventory(1,{},'light-armor')
  local net={valid=true,network_id=348,all_logistic_robots=190,available_logistic_robots=176,all_construction_robots=0,available_construction_robots=0,
    get_item_count=function() return 4000 end}
  local pt={enabled=true,logistic_network=net,targeted_items_deliver={},
    filters={{name='firearm-magazine',quality='normal',count=100},{name='pipe',quality='normal',count=5}}}
  local grid={inhibit_movement_bonus=false,equipment={{type='roboport-equipment',energy=50,max_energy=100},{type='movement-bonus-equipment',energy=0,max_energy=0}}}
  local c={valid=true,position={x=1,y=2},allow_dispatching_robots=true,grid=grid,force={},
    logistic_cell={construction_radius=15,logistic_network={valid=true,all_construction_robots=0,available_construction_robots=0}},
    get_logistic_point=function() return pt end,get_main_inventory=function() return main end,
    get_inventory=function(i) return ({[2]=guns,[3]=ammo,[5]=armor})[i] end,
    surface={find_logistic_networks_by_construction_area=function() return {} end,find_logistic_network_by_position=function() return net end}}
  local p={character=c,force={character_logistic_requests=true}}
  local P=dofile('mod/agent-harness_0.1.0/personal.lua'){}
  -- 100 magazines in the ammo slots fill a request for 100 (Astra read "hold 0 of 100" for 25 minutes).
  local rows=P.unfilled(p)
  eq(#rows,1,'magazines in the ammo slots count'); eq(rows[1].item,'pipe')
  has(rows[1].why,'network 348 holds 4000 and has 176 of 190 logistic robots free')
  pt.filters[1].count=150
  rows=P.unfilled(p)
  has(rows[1].line,'firearm-magazine: hold 100 of 150 (100 in ammo slots); network 348 holds 4000')
  -- No slot takes pipe: both free slots filtered to wood.
  main.filters[2]={name='wood'}; main.filters[4]={name='wood'}
  pt.filters[1].count=100
  rows=P.unfilled(p)
  eq(rows[1].item,'pipe')
  has(rows[1].why,'no slot of yours takes pipe')
  -- An invalid network object (the game's when personal logistics are off) reads as none.
  eq(P.network({valid=false}),nil); eq(P.network(net),net)
  main.filters={}

  local S=dofile('mod/agent-harness_0.1.0/charsettings.lua'){personal=function() return P end}
  local r=S.handle(p,{})
  eq(r.personal_logistics,'on'); eq(r.personal_roboport,'on'); eq(r.movement_bonus,'on')
  eq(r.filters_line,'no slot filtered; 2 of 4 slots free')
  has(r.networks.logistic,'logistic network #348: 190 logistic robots (176 idle); your requests are filled from it')
  has(r.networks.personal_roboport,'1 personal roboport, on: construction radius 15, 0 construction robots in your inventory, 0 out now; energy 50%')
  has(r.networks.not_dispatched[1],'no construction robot in your inventory')
  eq(r.changed,nil); eq(r.unchanged,nil,'a read is no edit')
  -- Writes: only what is named, read back.
  r=S.handle(p,{personal_roboport=false,movement_bonus=false,filters={{slot=1,item='iron-plate'},{slot=2,item='wood'}}})
  eq(c.allow_dispatching_robots,false); eq(grid.inhibit_movement_bonus,true); eq(pt.enabled,true,'personal logistics not named: kept')
  eq(r.changed[1],'personal roboport on -> off'); eq(r.changed[2],'movement bonus on -> off')
  eq(r.changed[3],'slot 1 filter none -> iron-plate'); eq(r.changed[4],'slot 2 filter none -> wood')
  eq(r.filters[1].holds,'iron-plate*50'); eq(r.filters[2].holds,'empty')
  has(r.networks.not_dispatched[1],'your personal roboport is switched off')
  -- A slot holding an item takes a filter for that item only; nothing changes when one argument is refused.
  fails(function() S.handle(p,{personal_logistics=false,filters={{slot=3,item='pipe'}}}) end,'slot 3 holds wood*10: a slot that holds an item takes a filter for that item only')
  eq(pt.enabled,true,'refused call changed nothing')
  fails(function() S.handle(p,{filters={{slot=5,item='pipe'}}}) end,'filters[1].slot must be 1..4')
  fails(function() S.handle(p,{filters={{slot=1,item='nothing'}}}) end,'no item named nothing')
  fails(function() S.handle(p,{personal_roboport='off'}) end,'personal_roboport must be true or false')
  -- Personal logistics off: the network by position, and the request line says so.
  r=S.handle(p,{personal_logistics=false})
  eq(r.personal_logistics,'off'); eq(r.changed[1],'personal logistics on -> off')
  has(r.networks.logistic,'your personal logistics are off, so no request of yours goes to it')
  r=S.handle(p,{personal_logistics=false})
  eq(r.unchanged,'each setting named was already so')
  -- Runs of empty slots with one filter read as one.
  main=inventory(6,{{'iron-plate',5}}); c.get_main_inventory=function() return main end
  S.handle(p,{filters={{slot=2,item='wood'},{slot=3,item='wood'},{slot=4,item='wood'},{slot=6,item='pipe'}}})
  r=S.read(p)
  eq(r.filters_line,'4 slots filtered: 2-4 wood (empty), 6 pipe (empty); 1 of 6 slots free (empty and unfiltered)')
  r=S.handle(p,{filters={{slot=2,item=false}}})
  eq(r.changed[1],'slot 2 filter wood -> none')
end
print('d20_batch59 U1 character settings: ok')

-- U3 (Astra #1502): the status line says the network's total and where one of its roboports stands, then the
-- roboports with the most waiting; logistics_audit {charging} ranks them; inspect reads a network's view once a tick.
do
  defines={inventory={roboport_material=7}}
  prototypes={item={}}
  game={tick=500}
  local function cell(x,y,charging,waiting)
    local o={valid=true,name='roboport',unit_number=x*1000+y,position={x=x,y=y},energy=50,electric_buffer_size=100,
      prototype={logistic_parameters={charging_station_count=4}},get_inventory=function() return {get_contents=function() return {} end} end}
    return {owner=o,charging_robot_count=charging,to_charge_robot_count=waiting,logistic_radius=25,construction_radius=55}
  end
  local cells={cell(37,38,0,0)}
  for i=1,40 do cells[#cells+1]=cell(i*10,-100,1,i%7) end
  cells[#cells+1]=cell(273,-194,4,15); cells[#cells+1]=cell(386,-244,3,15); cells[#cells+1]=cell(5,5,4,0)
  cells[#cells+1]={mobile=true,owner={valid=true,position={x=0,y=0}},charging_robot_count=0,to_charge_robot_count=30}
  local ln={network_id=243,valid=true,all_logistic_robots=500,available_logistic_robots=100,all_construction_robots=0,available_construction_robots=0,cells=cells,
    get_item_count=function() return 0 end}
  local st={}
  local N=dofile('mod/agent-harness_0.1.0/networks.lua'){state=function() return st end}
  local v=N.logistic_view(ln)
  eq(#v.hot,5)
  eq(N.hot_text(v.hot[1]),'(273,-194) 15 waiting, 4 charging'); eq(N.hot_text(v.hot[2]),'(386,-244) 15 waiting, 3 charging')
  eq(v.hot[3].waiting,6,'then the next most waiting'); eq(v.waiting,15+15+120+30,'the network total counts every cell')
  -- The status line from the kept view.
  st.networks={views={player={tick=500,surfaces={{name='nauvis',logistic={{id=243,view=v}}}}}}}
  local lines=N.robot_lines({name='player'})
  has(lines[1],'waiting to charge most: network #243 180 in all (a roboport of it at (37,38))')
  has(lines[1],'; roboports with the most: (273,-194) 15 waiting, 4 charging, (386,-244) 15 waiting, 3 charging, ')
  -- inspect of two roboports of one network in one tick: the view is read once.
  local reads=0
  local real=N.logistic_view
  N.logistic_view=function(x) reads=reads+1; return real(x) end
  local e1={type='roboport',position={x=273,y=-194},logistic_network=ln,logistic_cell=cells[42]}
  local e2={type='roboport',position={x=386,y=-244},logistic_network=ln,logistic_cell=cells[43]}
  N.of_entity(e1); N.of_entity(e2)
  eq(reads,1,'one view a network a tick')
  game.tick=501; N.of_entity(e1); eq(reads,2,'a new tick reads it again')
  has(N.of_entity(e1).port.line,'15 waiting to charge')
  N.logistic_view=real

  -- logistics_audit {charging}
  local L=dofile('mod/agent-harness_0.1.0/logaudit.lua'){state=function() return {} end}
  local surface={name='nauvis',find_logistic_network_by_position=function() return ln end}
  local p={position={x=0,y=0},surface=surface,force={}}
  local r=L.read(p,{charging=true})
  eq(r.network,243); eq(r.roboports,44,'personal roboports left out'); eq(r.waiting,150); eq(#r.rows,5)
  eq(r.rows[1].line,'roboport (273,-194): 15 waiting to charge, 4 charging of 4 charging slots; energy 50%')
  eq(r.rows[2].position.x,386)
  has(r.line,'network #243: 44 roboports; 51 robots charging, 150 waiting to charge in all, at 37 roboports; the 5 with the most: (273,-194) 15 waiting, 4 charging')
  eq(#L.read(p,{charging=true,limit=20}).rows,20)
  fails(function() L.read(p,{charging=true,limit=21}) end,'limit with charging is 1..20')
  fails(function() L.read(p,{charging='yes'}) end,'charging is true')
end
print('d20_batch59 U3 charging hotspots: ok')
