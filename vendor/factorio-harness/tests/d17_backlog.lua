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
