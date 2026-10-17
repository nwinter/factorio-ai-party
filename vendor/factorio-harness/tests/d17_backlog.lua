-- d17 backlog contracts.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end

-- #569 (Astra): a turret built from a configured ghost that reads other targeting is set to the ghost's, said once.
do
  game={tick=100,surfaces={}}
  local ents={}
  local surface={index=5,name='platform-1',platform={name='Kestrel'},find_entities_filtered=function(f)
    local out={}
    for _,e in ipairs(ents) do
      if e.valid and e.position.x==f.position[1] and e.position.y==f.position[2] and ((f.name and e.name==f.name) or (f.ghost_name and e.ghost_name==f.ghost_name)) then out[#out+1]=e end
    end
    return out end}
  game.surfaces[5]=surface
  local function targets(e) return {list=e.list or {},ignore=e.ignore or false,line='priority targets: '..(#(e.list or {})>0 and table.concat(e.list,', ') or 'none')..'; ignore unprioritised targets: '..((e.ignore and 'on') or 'off')} end
  local st={}
  local W=dofile('mod/agent-harness_0.1.0/turretwatch.lua'){state=function() return st end,targets=targets,
    configure=function(e,a) e.list=a.priority_targets; e.ignore=a.ignore_unprioritised end}
  local ghost={valid=true,type='entity-ghost',ghost_name='rocket-turret',name='entity-ghost',position={x=3.5,y=-6.5},surface=surface,
    list={'big-metallic-asteroid','big-carbonic-asteroid'},ignore=true}
  ents[1]=ghost
  W.watch(ghost,7)
  W.tick(); eq(W.lines({index=7},{}),nil,'a ghost still: nothing yet')
  -- the hub builds it, and the engine loses the targeting
  ghost.valid=false
  local built={valid=true,type='ammo-turret',name='rocket-turret',position={x=3.5,y=-6.5},surface=surface,list={},ignore=false}
  ents[2]=built
  W.tick()
  eq(built.list[2],'big-carbonic-asteroid'); eq(built.ignore,true)
  local l=W.lines({index=7},{})
  assert(l and l[1]:find('rocket-turret built at (3.5,-6.5) on platform Kestrel read priority targets: none; ignore unprioritised targets: off; set to the ghost',1,true),l and l[1])
  eq(W.lines({index=7},{}),nil,'once')
  eq(next(st.turret_watch.list),nil,'forgotten once built')
  game=nil
  print('d17_backlog #569 turret ghost targeting kept: ok')
end

-- #653 (Sol): fuel by item request into a burner's fuel slots (partial stacks of it first, then empty ones), filled by robots;
-- an ingredient is refused, naming what brings it.
do
  _G.defines={inventory={turret_ammo=7,fuel=1}}
  _G.prototypes={item={['solid-fuel']={type='item',fuel_value=12e6,stack_size=50},['iron-plate']={type='item',stack_size=100}}}
  local made
  local slots={{valid_for_read=true,name='solid-fuel',count=45},{valid_for_read=false}}
  local inv={index=1}
  for i,s in ipairs(slots) do inv[i]=s end
  local e={valid=true,name='heating-tower',type='reactor',position={x=-57.5,y=98.5},force='player',
    get_fuel_inventory=function() return inv end,get_inventory=function() return nil end,
    surface={create_entity=function(a) made=a; return {valid=true} end}}
  local D=dofile('mod/agent-harness_0.1.0/deliver.lua'){carrier=function() return 'construction robots of logistic network 63 bring them' end}
  local row=D.deliver_one({},e,{['solid-fuel']=20,['iron-plate']=5})
  eq(row.requested,'solid-fuel*20')
  local rows=made.modules[1].items.in_inventory
  eq(rows[1].stack,0); eq(rows[1].count,5,'the partial stack first'); eq(rows[2].stack,1); eq(rows[2].count,15)
  assert(row.refused and row.refused[1]:find('iron-plate is neither fuel nor ammunition',1,true),row.refused and row.refused[1])
  defines=nil; prototypes=nil
  print('d17_backlog #653 deliver by item request: ok')
end

-- #818 (Sol 105h16): a recipe that gives back some of an ingredient (crushing returns a chunk 1 time in 5) needs it net.
do
  _G.prototypes={recipe={carbon={name='carbon',energy=2,ingredients={{name='carbonic-asteroid-chunk',amount=1}},
    products={{name='carbon',amount=10},{name='carbonic-asteroid-chunk',amount=1,probability=0.2}}}},item={},entity={}}
  local R=dofile('mod/agent-harness_0.1.0/ratechain.lua'){}
  local plan=R.plan({},'carbon',100,{recipes={}},function() return 0 end)
  local chunk
  for _,st in ipairs(plan.steps) do if st.item=='carbonic-asteroid-chunk' then chunk=st end end
  eq(chunk.need_per_min,8,'10 crafts a minute, each net 0.8 chunk')
  prototypes=nil
  print('d17_backlog #818 returned ingredients net: ok')
end
