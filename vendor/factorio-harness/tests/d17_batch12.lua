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

-- A0 (Sol: the managed platform_bom section erased min_payload every 10 s): the slot's custom minimum payload and max
-- are kept through the rewrite; request takes a min_payload map; a slot already as wanted is not written again.
do
  game={tick=0,forces={}}
  defines={inventory={hub_main=1}}
  prototypes={space_location={fulgora={}},item={['transport-belt']={},['steel-plate']={}}}
  local ghosts={}
  local belt={name='transport-belt',items_to_place_this={{name='transport-belt',count=1}}}
  for i=1,5 do ghosts[i]={type='entity-ghost',ghost_name='transport-belt',ghost_prototype=belt} end
  local sections,writes={},0
  local function section(group)
    local sec={group=group,slots={},is_manual=true}
    sec.filters_count=0
    sec.set_slot=function(i,f) writes=writes+1; sec.slots[i]=f; sec.filters_count=math.max(sec.filters_count,i) end
    sec.get_slot=function(i) return sec.slots[i] end
    sec.clear_slot=function(i) sec.slots[i]=nil end
    return sec
  end
  local secs={sections_count=0}
  secs.get_section=function(i) return sections[i] end
  secs.add_section=function(g) sections[#sections+1]=section(g); secs.sections_count=#sections; return sections[#sections] end
  secs.remove_section=function(i) table.remove(sections,i); secs.sections_count=#sections end
  local hub={valid=true,get_logistic_sections=function() return secs end,get_inventory=function() return {get_item_count=function() return 0 end} end}
  local pl={valid=true,index=5,name='Meridian',hub=hub,space_location={name='fulgora'},surface={find_entities_filtered=function() return ghosts end}}
  local force={name='player',platforms={pl}}
  pl.force=force; game.forces={player=force}
  local st={}
  local B=dofile('mod/agent-harness_0.1.0/platbom.lua'){platform=function() return pl end,state=function() return st end}
  B.read({force=force},{platform='Meridian',request=true})
  -- min_payload sets the slot's custom minimum payload (as minpayload.lua does)
  sections[1].slots[1].minimum_delivery_count=6; sections[1].slots[1].max=40
  local before=writes
  B.tick(600)
  assert(sections[1].slots[1].minimum_delivery_count==6,'min_payload kept through the rewrite')
  assert(writes==before,'a slot already as wanted is not written again')
  table.remove(ghosts)
  B.tick(1200)
  assert(sections[1].slots[1].min==4 and sections[1].slots[1].minimum_delivery_count==6 and sections[1].slots[1].max==40,'lowered, min_payload and max kept')
  -- the request's own map wins, and is kept for later rewrites
  local r=B.read({force=force},{platform='Meridian',request=true,min_payload={['transport-belt']=2}})
  assert(sections[1].slots[1].minimum_delivery_count==2)
  assert(r.lines[1]:find('custom minimum payload 2',1,true),r.lines[1])
  B.tick(1800)
  assert(sections[1].slots[1].minimum_delivery_count==2)
  defines,prototypes=nil,nil
  print('d17_batch12 A0 min_payload kept in the platform_bom section: ok')
end
