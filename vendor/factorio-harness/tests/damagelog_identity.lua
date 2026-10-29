-- DL356: historical identity, confirmed lifecycle events and current occupants are separate facts.
local function eq(a,b) assert(a==b, tostring(a)..' ~= '..tostring(b)) end
defines={events={on_entity_died=1,on_player_mined_entity=2,on_robot_mined_entity=3,script_raised_destroy=4}}
local units, visible, fail_find, fail_unit, scans = {}, true, false, false, 0
local force={name='player',is_chunk_visible=function(_,p) return visible and p.x<10 end}
local surface={name='nauvis'}
surface.find_entities_filtered=function(a)
  scans=scans+1
  assert(a.limit==17 and not a.name, 'bounded occupant lookup includes other prototypes')
  if fail_find then error('find failed') end
  local out={}
  for _,e in pairs(units) do
    if e.valid and e.surface==surface and e.position.x==a.position.x and e.position.y==a.position.y then
      out[#out+1]=e
      if #out==a.limit then break end
    end
  end
  return out
end
game={tick=600,surfaces={nauvis=surface},get_entity_by_unit_number=function(id) if fail_unit then error('lookup failed') end local e=units[id]; return e and e.name=='car' and e or nil end}
local st={}
local D=dofile('mod/agent-harness_0.1.0/damagelog.lua'){
  state=function() return st end,position=function(p) return p end,integer=function(v,d) return v or d end}
local p={surface=surface,force=force,position={x=0,y=0}}
local function make(id,name,x,y)
  local e={valid=true,unit_number=id,name=name,position={x=x or 0,y=y or 0},surface=surface,force=force}
  units[id]=e; return e
end
local function hit(e,tick)
  game.tick=tick or game.tick
  D.on_damaged{entity=e,tick=game.tick,final_damage_amount=5,damage_type={name='physical'}}
end
local function read(x,y) return D.read(p,{position={x=x or 0,y=y or 0},radius=1}).entities end
local function remove(e,ev)
  D.on_removed{entity=e,name=ev,tick=game.tick}
  e.valid=false; units[e.unit_number]=nil
end
local gun=make(1,'gun-turret')
hit(gun)
local r=read()[1]
eq(r.unit_number,1); eq(r.state,'alive'); eq(r.alive,true)
eq(r.hit_rows[1].unit_number,1); eq(r.hit_rows[1].name,'gun-turret'); eq(r.hit_rows[1].tick,600)
eq(r.hit_rows[1].position.x,0); eq(r.current_occupants.status,'complete')
eq(r.current_occupants.entities[1].unit_number,1); eq(r.current_occupants.entities[1].original,true)
-- Destruction, a replacement without history, then both histories at the same position.
remove(gun,1)
local rebuilt=make(2,'gun-turret')
r=read()[1]
eq(r.unit_number,1); eq(r.state,'destroyed'); eq(r.alive,false); eq(r.removal.tick,600)
eq(r.current_occupants.entities[1].unit_number,2); eq(r.current_occupants.entities[1].original,false)
eq(#read(),1)
hit(rebuilt,620)
r=read()
eq(#r,2); eq(r[1].unit_number,2); eq(r[1].state,'alive'); eq(r[2].unit_number,1); eq(r[2].state,'destroyed')
eq(r[1].hit_rows[1].tick,620); eq(r[2].hit_rows[1].tick,600)
-- Alive by ID after moving, including another surface. Hit positions are copied, never coalesced across moves.
local car=make(3,'car',10,0)
hit(car,630)
car.position.x=20
r=read(10)[1]
eq(r.position.x,10); eq(r.state,'alive'); eq(r.current_position.x,20); eq(#r.current_occupants.entities,0)
hit(car,640)
eq(#st.damage_log.by[3].rows,2); eq(read(10)[1].hit_rows[1].position.x,10); eq(read(20)[1].hit_rows[1].position.x,20)
hit(car,650)
r=read(20)[1]; eq(r.hit_rows[1].tick,640); eq(r.hit_rows[1].last_tick,650); eq(r.hit_rows[1].count,2)
car.surface={name='vulcanus'}
eq(read(20)[1].state,'alive'); eq(read(20)[1].current_surface,'vulcanus')
car.position.x=400
r=read(20)[1]; eq(r.state,'unknown'); eq(r.alive,nil); eq(r.current_position,nil)
-- A missing unit without an event is unknown, even with a different prototype standing there.
rebuilt.valid=false; units[2]=nil
local laser=make(4,'laser-turret')
r=read()[1]; eq(r.state,'unknown'); eq(r.alive,nil); eq(r.current_occupants.entities[1].unit_number,4)
hit(laser,660)
fail_unit=true; eq(read()[1].state,'alive') -- saved identity is sufficient even when the API fails
st.damage_log.by[4].entity=nil; fail_find=true; eq(read()[1].state,'unknown')
fail_find=false; eq(read()[1].state,'alive') -- legacy same-unit occupant fallback
fail_unit=false
-- No current facts or find queries outside sight; a confirmed death stays known.
visible=false; local old_scans=scans
r=read(); eq(r[1].state,'unknown'); eq(r[1].current_occupants.status,'unknown'); eq(scans,old_scans)
eq(r[3].state,'destroyed')
visible=true; fail_find=true; eq(read()[1].current_occupants.status,'unknown'); fail_find=false
-- All subscribed removal events; an unrelated removal creates no history.
for _,ev in ipairs{2,3,4} do
  local e=make(10+ev,'gun-turret',ev*10,10)
  hit(e,700+ev); remove(e,ev)
  r=read(ev*10,10)[1]; eq(r.state,'removed'); eq(r.alive,false); eq(r.removal.tick,700+ev)
end
D.on_removed{entity=make(99,'gun-turret',99,99),name=1,tick=800}
eq(st.damage_log.by[99],nil)
-- Legacy rows never claim an exact per-hit position.
local legacy=st.damage_log.by[1].rows[1]
legacy.position=nil; legacy.surface=nil; legacy.unit_number=nil; legacy.name=nil
r=read()[3]; eq(r.unit_number,1); eq(r.hit_rows[1].position,nil); eq(r.hit_rows[1].position_status,'unknown')
assert(r.position_basis:find('legacy'))
-- Bounded occupancy and history; reaching the find bound is incomplete.
for id=100,118 do make(id,'transport-belt',50,0) end
hit(units[100],800)
r=read(50)[1]; eq(r.current_occupants.status,'capped'); eq(#r.current_occupants.entities,16)
for i=1,12 do hit(units[100],800+i*61) end
eq(#st.damage_log.by[100].rows,8); eq(#read(50)[1].hit_rows,8)
print('damagelog identity: intact, replacement, both histories, moved vehicle, removals, unknown, fog and bounds: ok')
