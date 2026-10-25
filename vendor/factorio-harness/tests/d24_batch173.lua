-- Run from repository root: lua tests/d24_batch173.lua
-- d24 batch173 QP1 (Astra #2241: Asterion's left and right rocket loops are not connected; platform_ammo_below summed
-- every belt aboard, so a full left reserve hid the right one running low). platform_ammo_below takes area (an area
-- aboard) or loop (the belts joined to the belt at a position, the inserters taking from them and the turrets those
-- fill): the same background pass counts the scope beside the whole platform, with its places, its age and the change
-- since the reading before. No scope: the whole platform, as before.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) if a~=b then error((m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b),2) end end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
defines={inventory={turret_ammo=1,hub_main=2,chest=3}}
prototypes={item={rocket={type='ammo'},['iron-plate']={type='item'}},quality={normal={}}}
local function inv(rows) return {get_contents=function() return rows end} end
local ents,units={},0
local function ent(t,x,y,extra)
  units=units+1
  local e={valid=true,type=t,name=t,position={x=x,y=y},unit_number=units}
  for k,v in pairs(extra or {}) do e[k]=v end
  ents[#ents+1]=e
  return e
end
local function belt(x,y,n)
  local rows={{name='rocket',quality='normal',count=n}}
  local e=ent('transport-belt',x,y,{belt_neighbours={inputs={},outputs={}}})
  e.get_max_transport_line_index=function() return 2 end
  e.get_transport_line=function(i) return inv(i==1 and rows or {}) end
  e.rows=rows
  return e
end
local function join(a,b) a.belt_neighbours.outputs[#a.belt_neighbours.outputs+1]=b; b.belt_neighbours.inputs[#b.belt_neighbours.inputs+1]=a end
-- the left loop, as Asterion's: a main ring (10, 5, then 31 empty belts), an inserter moving rockets from its second belt
-- onto a branch belt (4), and an inserter from the branch (1 in hand) into a turret (20)
local a,b,c=belt(1,1,10),belt(2,1,5),belt(3,1,0)
join(a,b); join(b,c)
-- the ring closes through 30 empty belts below (the walk takes several steps of LOOP_STEP belts)
local prev=c
for i=1,30 do local x=belt(3,1+i/100,0); join(prev,x); prev=x end
join(prev,a)
local g=belt(2,5,4)
ent('inserter',2,4,{pickup_target=b,drop_target=g,held_stack={valid_for_read=false}})
local tl=ent('ammo-turret',2,7,{get_inventory=function(i) eq(i,1); return inv({{name='rocket',quality='normal',count=20}}) end})
ent('inserter',2,6,{pickup_target=g,drop_target=tl,held_stack={valid_for_read=true,name='rocket',quality={name='normal'},count=1}})
-- the right loop: two belts (2 rockets, then none), an inserter from the second into a turret (3)
local d,e2=belt(40,1,2),belt(41,1,0)
join(d,e2)
local tr=ent('ammo-turret',41,3,{get_inventory=function() return inv({{name='rocket',quality='normal',count=3}}) end})
ent('inserter',41,2,{pickup_target=e2,drop_target=tr,held_stack={valid_for_read=false}})
local finds={band=0,at=0}
local surface={valid=true,index=9,name='platform-1',
  get_chunks=function() local cs={{x=0,y=0},{x=1,y=0}}; local i=0; return function() i=i+1; return cs[i] end end,
  find_entities_filtered=function(f)
    local out={}
    if f.position then
      finds.at=finds.at+1
      for _,x in ipairs(ents) do if x.position.x==f.position.x and x.position.y==f.position.y and x.type=='transport-belt' then out[#out+1]=x end end
      return out
    end
    finds.band=finds.band+1
    for _,x in ipairs(ents) do
      local p=x.position
      if x.valid and p.x>=f.area[1][1] and p.x<f.area[2][1] and p.y>=f.area[1][2] and p.y<f.area[2][2] then out[#out+1]=x end
    end
    return out
  end}
local hub={valid=true,position={x=0,y=0},get_inventory=function(i) eq(i,2); return inv({{name='rocket',quality='normal',count=40}}) end}
local force={name='player'}
local pl={valid=true,index=1,name='Asterion',surface=surface,hub=hub,force=force}
force.platforms={pl}
game={tick=1000,forces={player=force}}
local st={}
local A=dofile('mod/agent-harness_0.1.0/ammoreserve.lua'){state=function() return st end}
A.LOOP_STEP=4
local C=dofile('mod/agent-harness_0.1.0/conditions.lua'){ammo_reserve=function(p,f,c) return A.check(p,f,c) end,
  position=function(v) assert(type(v)=='table' and tonumber(v.x or v[1]) and tonumber(v.y or v[2]),'a position is {x,y}'); return {x=v.x or v[1],y=v.y or v[2]} end}
local p={force=force}
local function run(n) for _=1,n do game.tick=game.tick+1; A.tick(game.tick) end end
local function check(c) c['until']='platform_ammo_below'; c.platform='Asterion'; c.item='rocket'; C.validate(c); return C.check(p,c) end

-- the arguments
fails(function() check({count=5,area={{0,0},{5,5}},loop={1,1}}) end,'platform_ammo_below: area or loop, not both')
fails(function() check({count=5,area={{5,0},{0,5}}}) end,'platform_ammo_below area must be nonempty and at most 1024x1024')
fails(function() check({count=5,loop={1}}) end,'a position is {x,y}')
fails(function() check({count=5,position={1,1}}) end,'no position or radius')
fails(function() C.validate({['until']='item_count',item='rocket',count=5,loop={1,1}}) end,'loop applies to platform_ammo_below only')
-- the first checks: no reading of the scopes yet; the pass finds the loops' belts first, then reads the platform
local L,R,AR,HUB={count=30,loop={x=1,y=1}},{count=30,loop={41,1}},{count=30,area={left_top={30,0},right_bottom={50,10}}},{count=100,area={{-1,-1},{5,5}}}
local met,saw=check(L)
eq(met,false); assert(saw:find('^platform Asterion: no reading of its loop from %(1,1%) yet %(its first pass waits for its turn; 0s since its first check; met if none by max_age 2m00s%)'),saw)
check(R); check(AR); check(HUB); check({count=1000})
run(20)
eq(finds.at,2,'each loop found from the belt at its position')
met,saw=check(L)
assert(saw:find('a pass began 0s ago, finding the loop\'s belts'),saw)
run(60)
eq(st.ammo_reserve.active,nil,'the pass done')
-- the whole platform: belts 21, turrets 23, hand 1, hub 40
met,saw=check({count=1000})
assert(saw:find('^platform Asterion: 85 rocket aboard %(hub 40, turrets 23, belts 21, hands 1%)'),saw)
-- the left loop: the ring and the branch the inserter fills (19), the turret inserter's hand (1), its turret (20): 40,
-- not the platform's 85
met,saw=check(L)
eq(met,false)
assert(saw:find('^platform Asterion, loop from %(1,1%): 40 rocket %(turrets 20, belts 19, hands 1%) as read %ds ago %(ticks 1020%-10%d%d: 34 belts joined to transport%-belt %(1,1%), found %ds ago; 1 ammo turrets, 34 belts, 2 inserters, 0 machines, 0 chests in it%); met below 30$'),saw)
-- the right loop: 2 on its belts, 3 in its turret: 5, met below 30 while the left is full
met,saw=check(R)
eq(met,true)
assert(saw:find('^platform Asterion, loop from %(41,1%): 5 rocket %(turrets 3, belts 2%) .- 2 belts joined to transport%-belt %(41,1%)'),saw)
-- an area: what each place in it holds; the hub when it stands in it
met,saw=check(AR)
assert(saw:find('^platform Asterion, area %(30,0%)%-%(50,10%): 5 rocket %(turrets 3, belts 2%)'),saw)
assert(saw:find('1 ammo turrets, 2 belts, 1 inserters, 0 machines, 0 chests in it'),saw)
met,saw=check(HUB)
assert(saw:find('^platform Asterion, area %(%-1,%-1%)%-%(5,5%): 59 rocket %(hub 40, belts 19%)'),saw)
-- the next pass (30 s later): the right loop's belt emptied; the change since the reading before, a minute
d.rows[1].count=0
run(1800)
eq(st.ammo_reserve.active,nil)
met,saw=check(R)
assert(saw:find('^platform Asterion, loop from %(41,1%): 3 rocket %(turrets 3%)'),saw)
assert(saw:find('; %-2 since the reading before %(30s earlier%): %-4.0/min net %(made or brought in less what left%); met below 30$'),saw)
eq(finds.at,2,'the loops\' belts kept (found again after 5 min)')
-- no belt at a loop's position: none counted, said
local N={count=1,loop={9,9}}
check(N)
run(1800)
met,saw=check(N)
eq(met,true); assert(saw:find('loop from %(9,9%): 0 rocket %(none aboard%) .- no belt of ours at that position; 0 ammo turrets'),saw)
print('d24_batch173 QP1 platform_ammo_below area and loop: ok')
