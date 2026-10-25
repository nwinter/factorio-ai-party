-- d25 batch201. Run from the harness root: lua tests/d25_batch201.lua
-- QN1 (Astra #2302: two Aquilo silos read 19 completions in 600 s while the surface's statistics counted 879 rocket
-- parts): a silo's completions are rocket parts, finished rockets x 50 plus rocket_parts, beside the statistics.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
game={tick=60652783}

do
  defines={inventory={assembling_machine_input=2,furnace_source=2,crafter_input=2}}
  local PART={name='rocket-part',energy=3,products={{type='item',name='rocket-part',amount=1}},ingredients={}}
  local produced=134157
  local stats={get_input_count=function(n) return (n=='rocket-part' or (type(n)=='table' and n.name=='rocket-part' and n.quality=='normal')) and produced or 0 end,
    get_output_count=function() return 0 end}
  local force={name='player',recipes={},get_item_production_statistics=function() return stats end}
  local surface={name='aquilo',valid=true}
  game.surfaces={aquilo=surface}; game.forces={player=force}
  local st={}
  local ms={}
  -- a silo as on the copy: a part when its craft ends, another when its productivity bar fills; at 50 parts the rocket
  -- is made (products_finished + 1 and rocket_parts 0 in the same tick); parts go on through the launch
  local function silo(x,fin,parts)
    local m={valid=true,name='rocket-silo',type='rocket-silo',position={x=x,y=17.5},force=force,surface=surface,prototype={rocket_parts_required=50},
      productivity_bonus=0.44,crafting_speed=0.77,products_finished=fin,rocket_parts=parts,bonus_progress=0,crafting_progress=0,status='working',
      get_recipe=function() return PART end,get_inventory=function() return {get_item_count=function() return 0 end,get_contents=function() return {} end} end}
    ms[#ms+1]=m
    return m
  end
  silo(-18.5,1110,7); silo(17.5,1572,49)
  local made={0,0}
  local function part(i,m)
    m.rocket_parts=m.rocket_parts+1; made[i]=made[i]+1; produced=produced+1
    if m.rocket_parts>=50 then m.products_finished=m.products_finished+1; m.rocket_parts=0 end
  end
  local U=dofile('mod/agent-harness_0.1.0/uptime.lua'){state=function() return st end,remote_entity=function(_,q) for _,m in ipairs(ms) do if m.position.x==q.position.x then return m end end end,
    status_name=function(e) return e.status end,craftrate=function() return {crafts_per_min=15.4,productivity=0.44,productivity_machine=0.24,productivity_research=0.2} end}
  local start=U.handler({index=1,force=force,surface=surface},{positions={{x=-18.5,y=17.5},{x=17.5,y=-13.5+31}},seconds=600})
  has(start.baseline[1],'rocket-silo (-18.5,17.5) rocket-part: 55507 rocket parts so far (finished rockets x the parts a rocket takes, plus those of the one building')
  for t=game.tick+1,game.tick+36000 do
    game.tick=t
    for i,m in ipairs(ms) do
      m.status=(t%3000<1500) and 'working' or 'launching_rocket'
      local step=m.crafting_speed/PART.energy/60
      m.crafting_progress=m.crafting_progress+step; m.bonus_progress=m.bonus_progress+0.44*step
      if m.crafting_progress>=1 then m.crafting_progress=m.crafting_progress-1; part(i,m) end
      while m.bonus_progress>=1 do m.bonus_progress=m.bonus_progress-1; part(i,m) end
    end
    U.tick(t)
  end
  local res=U.handler({index=1},{})
  local a,b=res.machines[1],res.machines[2]
  eq(a.completions,made[1]); eq(b.completions,made[2])
  assert(made[1]>200 and ms[1].products_finished-1110>=4,'rockets were made in the watch: '..made[1]..' parts')
  -- base crafts from the parts and the bar: parts / 1.44
  assert(math.abs(a.crafts-made[1]/1.44)<=1,a.crafts..' crafts of '..made[1])
  has(a.completions_are,'rocket parts: a silo\'s products_finished counts rockets')
  eq(res.silo_statistics.silos_made,made[1]+made[2]); eq(res.silo_statistics.statistics_produced,made[1]+made[2])
  has(res.silo_statistics.line,string.format('rocket-part: the 2 watched silos made %d in 600s; the production statistics on aquilo counted %d produced',made[1]+made[2],made[1]+made[2]))
  eq(res.groups[1].completions,made[1]+made[2])
  local found=false
  for _,l in ipairs(res.lines) do if l==res.silo_statistics.line then found=true end end
  assert(found,'the statistics line is in lines')
  -- a watch begun before parts were counted (no parts flag): the game's count, said to be rockets
  local job=st.uptime[1]
  for _,m in ipairs(job.machines) do m.parts=nil; m.finished0=1110; m.e=ms[1] end
  job.result=nil; job.silo_stats=nil
  local old=U.result(job,true)
  has(old.machines[1].completions_are,'rockets (the watch began before parts were counted')
  eq(old.silo_statistics,nil)
  defines=nil
end
print('d25_batch201 QN1 uptime silo completions are rocket parts: ok')
