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
