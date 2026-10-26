-- Run from repository root: lua tests/d22_batch117.lua
-- d22 batch117 BZ1 (Astra #1970: a full-edge abort must keep the return leg's ammunition; item_count with platform
-- reads the hub alone, ammo_below each turret alone). wait_until/guard platform_ammo_below {platform, item, count,
-- quality?, max_age?}: a platform's whole stock of one ammunition item (hub, turret slots, belts, inserter hands,
-- machine outputs, chests) from a background reading (ammoreserve.lua), with its age; a reading older than max_age, or
-- none by max_age after the first check, meets it.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) if a~=b then error((m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b),2) end end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
defines={inventory={turret_ammo=1,hub_main=2,chest=3}}
prototypes={item={rocket={type='ammo'},['firearm-magazine']={type='ammo'},['iron-plate']={type='item'}},quality={normal={},uncommon={}}}
local function inv(rows) return {get_contents=function() return rows end} end
local ents={}
local function ent(t,x,y,extra) local e={valid=true,type=t,position={x=x,y=y}}; for k,v in pairs(extra or {}) do e[k]=v end; ents[#ents+1]=e; return e end
local function line(rows,id) return {get_contents=function() return rows end,id=id,line_equals=function(o) return id~=nil and id==o.id end} end
local function belt(t,x,y,lines,extra)
  local e=ent(t,x,y,extra)
  e.get_max_transport_line_index=function() return #lines end
  e.get_transport_line=function(i) return lines[i] end
  return e
end
-- belts: 10 rockets on a belt, an underground pair whose buried lines (3, 4) are the same: once; 2 uncommon rockets
belt('transport-belt',1,1,{line({{name='rocket',quality='normal',count=6}}),line({{name='rocket',quality='normal',count=4},{name='iron-plate',quality='normal',count=9}})})
local buried={line({{name='rocket',quality='normal',count=3}},'b3'),line({},'b4')}
local inp=belt('underground-belt',2,1,{line({}),line({}),buried[1],buried[2]},{belt_to_ground_type='input'})
local out=belt('underground-belt',40,1,{line({}),line({{name='rocket',quality='uncommon',count=2}}),line({{name='rocket',quality='normal',count=3}},'b3'),line({},'b4')},{belt_to_ground_type='output',neighbours=inp})
-- a turret (5), an inserter's hand (1), an assembler's output (7), a chest (20 magazines)
ent('ammo-turret',3,3,{get_inventory=function(i) eq(i,1); return inv({{name='rocket',quality='normal',count=5}}) end})
ent('inserter',4,4,{held_stack={valid_for_read=true,name='rocket',quality={name='normal'},count=1}})
ent('inserter',5,4,{held_stack={valid_for_read=false}})
ent('assembling-machine',6,6,{get_output_inventory=function() return inv({{name='rocket',quality='normal',count=7}}) end})
ent('container',70,8,{get_inventory=function() return inv({{name='firearm-magazine',quality='normal',count=20}}) end})
local found=0
local surface={valid=true,index=9,name='platform-1',
  get_chunks=function() local cs={{x=0,y=0},{x=1,y=0},{x=2,y=0}}; local i=0; return function() i=i+1; return cs[i] end end,
  find_entities_filtered=function(f)
    local out={}
    for _,e in ipairs(ents) do
      local p=e.position
      if e.valid and p.x>=f.area[1][1] and p.x<f.area[2][1] and p.y>=f.area[1][2] and p.y<f.area[2][2] then out[#out+1]=e end
    end
    found=found+1
    return out
  end}
local hub={valid=true,get_inventory=function(i) eq(i,2); return inv({{name='rocket',quality='normal',count=40},{name='rocket',quality='uncommon',count=1}}) end}
local force={name='player'}
local pl={valid=true,index=1,name='Asterion',surface=surface,hub=hub,force=force}
force.platforms={pl}
game={tick=1000,forces={player=force}}
local st={}
local A=dofile('mod/agent-harness_0.1.0/ammoreserve.lua'){state=function() return st end}
local C=dofile('mod/agent-harness_0.1.0/conditions.lua'){ammo_reserve=function(p,f,c) return A.check(p,f,c) end}
local p={force=force}
local function run(n) for _=1,n do game.tick=game.tick+1; A.tick(game.tick) end end
local function check(c) c['until']='platform_ammo_below'; C.validate(c); return C.check(p,c) end

-- the arguments
fails(function() C.validate({['until']='platform_ammo_below',item='rocket',count=5}) end,'platform_ammo_below requires platform')
fails(function() C.validate({['until']='platform_ammo_below',platform='Asterion',item='iron-plate',count=5}) end,'an ammunition item')
fails(function() C.validate({['until']='platform_ammo_below',platform='Asterion',item='rocket',count=0}) end,'count: 1..1000000')
fails(function() C.validate({['until']='platform_ammo_below',platform='Asterion',item='rocket',count=5,max_age=10}) end,'max_age: 30..900 seconds')
fails(function() C.validate({['until']='platform_ammo_below',platform='Asterion',item='rocket',count=5,quality='shiny'}) end,'platform_ammo_below quality is a quality name')
-- the first check: no reading yet, not met; the pass begins at the next pick
local met,saw=check({platform='Asterion',item='rocket',count=100})
eq(met,false); assert(saw:find('^platform Asterion: no reading of its ammunition yet %(its first pass waits for its turn; 0s since its first check; met if none by max_age 2m00s%)'),saw)
run(20)
eq(st.ammo_reserve.active,1,'a pass begun (the pick at a tick of 60)')
met,saw=check({platform='Asterion',item='rocket',count=100})
assert(saw:find('a pass began 0s ago'),saw)
run(10)
eq(st.ammo_reserve.active,nil,'the pass done')
-- belts 10 + 3 (the buried lines once) = 13 normal; turret 5, hand 1, machine 7, hub 40: 66 normal
met,saw=check({platform='Asterion',item='rocket',count=100})
eq(met,true)
assert(saw:find('^platform Asterion: 66 rocket aboard %(hub 40, turrets 5, belts 13, hands 1, machines 7%) as read 0s ago %(ticks 1020%-102%d: hub, 1 ammo turrets, 3 belts, 2 inserters, 1 machines, 1 chests%); met below 100$'),saw)
met=check({platform='Asterion',item='rocket',count=66}); eq(met,false,'66 is not below 66')
-- quality: uncommon 3 (belt 2, hub 1); any 69
met,saw=check({platform='Asterion',item='rocket',count=4,quality='uncommon'})
eq(met,true); assert(saw:find('3 rocket %(uncommon%) aboard %(hub 1, belts 2%)'),saw)
met,saw=check({platform='Asterion',item='rocket',count=69,quality='any'})
eq(met,false); assert(saw:find('69 rocket %(any quality%) aboard'),saw)
met,saw=check({platform='Asterion',item='firearm-magazine',count=21}); eq(met,true); assert(saw:find('20 firearm%-magazine aboard %(chests 20%)'),saw)
-- read again EVERY ticks after the last began: a turret emptied shows in the next reading
ents[4].get_inventory=function() return inv({}) end
run(A.EVERY-20)
eq(select(2,check({platform='Asterion',item='rocket',count=100})):find('^platform Asterion: 66'),1,'not read again yet')
run(140)
met,saw=check({platform='Asterion',item='rocket',count=100})
assert(saw:find('^platform Asterion: 61 rocket'),saw)
-- stale: no pass for longer than max_age (the job held back here): met, said
local saved=A.tick
A.tick=function() end
game.tick=game.tick+121*60
met,saw=check({platform='Asterion',item='rocket',count=10})
eq(met,true); assert(saw:find('; older than max_age 2m00s: met %(stale reading%)$'),saw)
met,saw=check({platform='Asterion',item='rocket',count=10,max_age=300})
eq(met,false,'within its own max_age'); assert(saw:find('met below 10$'),saw)
A.tick=saved
-- no reading max_age after the first check: met
st.ammo_reserve.plats[1].done=nil; st.ammo_reserve.plats[1].first=game.tick-31*60
met,saw=check({platform='Asterion',item='rocket',count=10,max_age=30})
eq(met,true); assert(saw:find('no reading of its ammunition yet 31s after its first check %(its first pass waits for its turn%), past max_age 30s: met'),saw)
-- not asked about for KEEP ticks: the record dropped, and the job's storage with it
game.tick=game.tick+A.KEEP+60
run(60)
eq(st.ammo_reserve,nil,'dropped')
-- the remote and platform lanes take it as a wait and a guard with platform
local s={active={}}
local base={state=function() return s end,player=function() return p end,handlers={},busy=function() return false end,stop=function() end,stop_index=function() end,
  direct_action=function() return nil end,condition=function() return false,'' end,validate_condition=function(c) C.validate(c) end}
local make=require('scheduler')
local q=require('queue_lanes'){scheduler=make(base),factory=make,base=base,is_read=function() return false end}
local cond={['until']='platform_ammo_below',platform='Asterion',item='rocket',count=200}
local r=q.handlers.queue_submit(p,{lane='platform:Asterion',dry_run=true,steps={{action='wait_until',args=cond},{action='wait_ticks',args={ticks=60},label='home'}},guards={{when=cond,['goto']='home'}}})
eq(r.steps,2)
eq(q.handlers.queue_submit(p,{lane='remote',dry_run=true,steps={{action='wait_until',args=cond}}}).steps,1)
print('d22_batch117 BZ1 platform_ammo_below: ok')
