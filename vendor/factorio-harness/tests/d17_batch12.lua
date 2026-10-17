-- d17 batch12 contracts.
_G.defines={inventory={turret_ammo=1}}

-- A3: stay_in_turret_coverage routes round an L of turrets, and refuses where coverage ends.
do
  local turrets={}
  local function turret(x,y)
    turrets[#turrets+1]={type='ammo-turret',position={x=x,y=y},prototype={attack_parameters={range=18}},
      get_inventory=function() return {is_empty=function() return false end} end}
  end
  -- a row along y=0 from x=0 to 100, then a column up x=100 to y=-100
  for x=0,100,20 do turret(x,0) end
  for y=-100,0,20 do turret(100,y) end
  local surface={find_entities_filtered=function() return turrets end}
  local p={surface=surface,force='player'}
  local T=dofile('mod/agent-harness_0.1.0/turretcover.lua'){}
  local via,line=T.route(p,{x=0,y=0},{x=100,y=-100})
  assert(#via>=1,'a turn needs a via point')
  -- every via point lies within a turret's reach
  for _,q in ipairs(via) do
    local inside=false
    for _,t in ipairs(turrets) do if ((q.x-t.position.x)^2+(q.y-t.position.y)^2)^0.5<=16 then inside=true end end
    assert(inside,'via point outside coverage '..q.x..','..q.y)
  end
  assert(line:find('via',1,true),line)
  -- a goal outside every reach: (50,-60) is over 40 tiles from every turret
  local ok,err=pcall(T.route,p,{x=0,y=0},{x=50,y=-60})
  assert(not ok and tostring(err):find('is not inside our turrets',1,true),tostring(err))
  -- two covered areas apart: refused with where the coverage ends
  turrets={}
  turret(0,0); turret(100,0)
  ok,err=pcall(T.route,p,{x=0,y=0},{x=100,y=0})
  assert(not ok and tostring(err):find('the coverage you are in ends nearest the goal at',1,true),tostring(err))
  -- an empty turret does not count
  turrets={}
  turret(0,0)
  turrets[1].get_inventory=function() return {is_empty=function() return true end} end
  ok,err=pcall(T.route,p,{x=0,y=0},{x=4,y=0})
  assert(not ok and tostring(err):find('0 of our turrets that would shoot now near the way (1 more',1,true),tostring(err))
  print('d17_batch12 A3 turret coverage: ok '..line)
end

-- A2: enemy units our force sees now near the way are discs (16-tile cells), named; unseen ones are not.
do
  local visible={['0,0']=true}
  _G.game={tick=100,forces={player={name='player',players={1},is_chunk_visible=function(_,c) return visible[c.x..','..c.y]==true end},
    enemy={name='enemy',players={}}}}
  local units={}
  local function unit(name,x,y) units[#units+1]={valid=true,type='unit',name=name,position={x=x,y=y}} end
  unit('big-biter',10,10); unit('big-biter',12,11); unit('big-spitter',14,12); unit('small-biter',40,40)
  local surface={name='nauvis',find_entities_filtered=function(f) assert(f.type=='unit'); return units end}
  local A=dofile('mod/agent-harness_0.1.0/avoid.lua'){state=function() return {} end}
  local discs=A.attack_discs(surface,A.mode(nil),{0,0,20,20})
  eq=function(a,b) assert(a==b,tostring(a)..' ~= '..tostring(b)) end
  eq(#discs,1)
  eq(discs[1].name,'3 enemy units (1 big-spitter, 2 big-biter)')
  eq(discs[1].units,true); eq(discs[1].r,24+4)
  -- no box: none (the plan reads them with the chunks along the way)
  eq(#A.attack_discs(surface,A.mode(nil)),0)
  -- avoid_enemies false: none
  eq(A.mode(false),nil)
  print('d17_batch12 A2 units seen now: ok')
end
