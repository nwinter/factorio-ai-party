-- Run from repository root: lua tests/d26_batch233.lua
-- d26 batch233 VM (viewer Aurora site:5019: "Could vehicle maps start with Spidertrons? ... Show ID, position age,
-- controller and destination."): census part vehicles: our spidertrons the census pass kept, each where our force last
-- saw it (its position now while its chunk is visible to our force, else the last one seen and its tick), who rides
-- it, who drives it by remote view, who last sent it a route by remote view, its destination and route length; from the
-- kept entities, no find.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
local visible={}
local force={name='player',index=1,is_chunk_visible=function(s,c) return visible[s.name..':'..c[1]..','..c[2]]==true end}
game={tick=5000,forces={player=force},get_surface=function(i) return nil end}
prototypes={entity={},item={}}
local nauvis,gleba={name='nauvis',index=1},{name='gleba',index=4}
local finds=0
nauvis.find_entities_filtered=function() finds=finds+1; return {} end
local function spider(unit,surface,x,y)
  return {valid=true,unit_number=unit,name='spidertron',type='spider-vehicle',surface=surface,position={x=x,y=y},
    autopilot_destinations={},get_driver=function() return nil end}
end
local a=spider(23036938,nauvis,-148.43,-543.12)
local b=spider(23117830,gleba,74,20)
local c=spider(27069154,nauvis,-358.5,-540.7)
a.autopilot_destinations={{position={x=-60.25,y=-300.5}},{position={x=10,y=10}},{position={x=20,y=20}}}
local riding={valid=true,unit_number=777,type='character'}
b.get_driver=function() return riding end
local st={census={done={start=4000,tick=4900,walked={[1]=true,[4]=true},by_type={[1]={['spider-vehicle']={a,c}},[4]={['spider-vehicle']={b},car={}}}}},
  spiderroute={spiders={[23036938]={by='opus',tick=4400}}}}
local api={state=function() return st end,timed=function(_,f,...) return f(...) end,
  vehicle_people=function() return {by_character={[777]='astra'},remote={}} end}
local C=dofile('mod/agent-harness_0.1.0/census.lua')(api)
-- a and b in sight, c out of sight and never seen
visible['nauvis:-5,-17']=true; visible['gleba:2,0']=true
local r=C.read({part='vehicles'})
eq(r.ready,true); eq(r.part,'vehicles'); eq(r.tick,5000); eq(r.vehicles_total,3); eq(#r.vehicles,3)
local v1,v2,v3=r.vehicles[1],r.vehicles[2],r.vehicles[3]
eq(v1.unit_number,23036938); eq(v1.surface,'nauvis'); eq(v1.position.x,-148.4); eq(v1.position.y,-543.1)
eq(v1.age_s,0); eq(v1.seen_tick,5000); eq(v1.visible,true); eq(v1.driver,nil)
eq(v1.sent_by,'opus'); eq(v1.sent_tick,4400)
eq(v1.destination.x,-60.2); eq(v1.destination.y,-300.5); eq(v1.route_targets,3)
eq(v2.unit_number,23117830); eq(v2.surface,'gleba'); eq(v2.driver,'astra','its rider, by the character'); eq(v2.destination,nil)
eq(v3.unit_number,27069154); eq(v3.unseen,true); eq(v3.position,nil); eq(v3.visible,false)
eq(finds,0,'no find: the kept entities only')
-- later: a out of sight keeps the last position seen and its age; c comes into sight
game.tick=5000+600
a.position={x=-100,y=-400}
visible={['nauvis:-12,-17']=true}
r=C.read({part='vehicles'})
eq(r.vehicles[1].position.x,-148.4,'the last position seen'); eq(r.vehicles[1].age_s,10); eq(r.vehicles[1].visible,false)
eq(r.vehicles[3].position.x,-358.5); eq(r.vehicles[3].age_s,0); eq(r.vehicles[3].unseen,nil)
-- a human in the seat, a remote drive, and a vehicle gone
b.get_driver=function() return {valid=true,unit_number=999} end
api.vehicle_people=function() return {by_character={},remote={[23117830]={name='luna',target={x=5.04,y=6}}}} end
c.valid=false
r=C.read({part='vehicles'})
eq(#r.vehicles,2); eq(r.vehicles[2].driver,'a player'); eq(r.vehicles[2].remote,'luna'); eq(r.vehicles[2].remote_target.x,5)
-- before a pass: not ready; the part is named in the refusal
st.census.done=nil
eq(C.read({part='vehicles'}).ready,false)
fails(function() C.read({part='cars'}) end,'part must be extras, snapshot, machines, basemap, planets or vehicles')
eq(C.VEHICLE_TYPES[1],'spider-vehicle')
print('d26_batch233 VM census vehicles: ok')
