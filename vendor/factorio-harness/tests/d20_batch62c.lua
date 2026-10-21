-- d20 batch62 X3 (Astra #1540). Run from the harness root: lua tests/d20_batch62c.lua
-- produced with surface: our machines on another planet by remote view, in charted chunks, from products_finished;
-- a machine gone or a recipe changed fails the wait. ammo_below, fuel_below and fluid_count take surface the same way.
-- The remote lane takes those waits, and circuit_set (and the other remote-view writes) with surface.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,part) assert(type(s)=='string' and s:find(part,1,true),tostring(s)..' lacks '..part) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end

defines={inventory={turret_ammo=7}}
prototypes={item={['iron-gear-wheel']={},['firearm-magazine']={},coal={}},fluid={water={},['sulfuric-acid']={}},quality={normal={}},
  recipe={['iron-gear-wheel']={products={{name='iron-gear-wheel',amount=1}}},['copper-cable']={products={{name='copper-cable',amount=2}}}}}
local function inside(e,f)
  if f.type then
    local ok=false
    for _,t in ipairs(type(f.type)=='table' and f.type or {f.type}) do if t==e.type then ok=true end end
    if not ok then return false end
  end
  local x,y=e.position.x,e.position.y
  if f.area then
    local a,b=f.area[1] or f.area.left_top,f.area[2] or f.area.right_bottom
    return x>=(a.x or a[1]) and x<=(b.x or b[1]) and y>=(a.y or a[2]) and y<=(b.y or b[2])
  end
  if f.position then return (x-f.position.x)^2+(y-f.position.y)^2<=((f.radius or 0)+1.5)^2 end
  return true
end
local function world(name,index)
  local s={name=name,index=index,list={}}
  s.find_entities_filtered=function(f) local out={} for _,e in ipairs(s.list) do if e.valid and inside(e,f) then out[#out+1]=e end end return out end
  return s
end
local nauvis,aquilo=world('nauvis',1),world('aquilo',4)
local deck={name='platform-1',index=9,platform={name='Kestrel'},list={},find_entities_filtered=function() return {} end}
local charted={}
game={tick=1000,get_surface=function(n) return ({nauvis=nauvis,aquilo=aquilo,['platform-1']=deck})[n] end}
local force={name='player',platforms={},is_chunk_charted=function(s,c) return charted[s.name..':'..c[1]..','..c[2]] or charted[s.name] or false end}
local astra={position={x=0,y=0},surface=aquilo,force=force,index=2}
local units=0
local function machine(s,x,y,recipe,pf)
  units=units+1
  local e={valid=true,name='assembling-machine-2',type='assembling-machine',position={x=x,y=y},unit_number=units,products_finished=pf or 0,recipe=recipe}
  e.get_recipe=function() return e.recipe and {name=e.recipe} or nil end
  s.list[#s.list+1]=e
  return e
end
local C=dofile('mod/agent-harness_0.1.0/conditions.lua'){position=function(v) return {x=v.x or v[1],y=v.y or v[2]} end,known=function() return true end}
local function check(c,record) C.validate(c); return C.check(astra,c,nil,record) end

-- produced on Nauvis from Aquilo (Astra's call at tick 40886995 was refused)
local gears=machine(nauvis,-65.5,72.5,'iron-gear-wheel',100)
local gears2=machine(nauvis,-61.5,72.5,'iron-gear-wheel',40)
local wait={['until']='produced',surface='nauvis',positions={{x=-65.5,y=72.5},{x=-61.5,y=72.5}},item='iron-gear-wheel',at_least=10}
fails(function() check(wait,{}) end,'(-65.5,72.5) on nauvis is not charted: no remote view of a machine there')
charted.nauvis=true
local record={}
local met,saw=check(wait,record)
eq(met,false); eq(saw,'made 0 iron-gear-wheel (0 crafts) in 2 machines on nauvis since the wait began (at least 10)')
gears.products_finished=106; gears2.products_finished=44
met,saw=check(wait,record)
eq(met,true); eq(saw,'made 10 iron-gear-wheel (10 crafts) in 2 machines on nauvis since the wait began (at least 10)')
-- one machine named at two tiles counts once
met,saw=check({['until']='produced',surface='nauvis',positions={{x=-65.5,y=72.5},{x=-65,y=72}},at_least=1},{})
has(saw,'in 1 machine on nauvis')
-- a recipe change fails the wait with the reason
gears2.recipe='copper-cable'
fails(function() check(wait,record) end,'the assembling-machine-2 at (-61.5,72.5) on nauvis changed recipe since the wait began (iron-gear-wheel, now copper-cable)')
gears2.recipe='iron-gear-wheel'
-- a machine mined (or replaced) fails it too
gears.valid=false
fails(function() check(wait,record) end,'the assembling-machine-2 at (-65.5,72.5) on nauvis is gone since the wait began (mined, destroyed or replaced)')
gears.valid=true
-- a machine with no recipe at the start counts from the recipe it gets
local idle=machine(nauvis,-57.5,72.5,nil,0)
local r2={}
check({['until']='produced',surface='nauvis',position={x=-57.5,y=72.5},item='iron-gear-wheel',at_least=3},r2)
idle.recipe='iron-gear-wheel'; idle.products_finished=3
met,saw=check({['until']='produced',surface='nauvis',position={x=-57.5,y=72.5},item='iron-gear-wheel',at_least=3},r2)
eq(met,true)
-- the character's own surface: no surface, as before; the same failures
local here=machine(aquilo,3.5,3.5,'iron-gear-wheel',5)
local r3={}
eq((check({['until']='produced',position={x=3.5,y=3.5},at_least=1},r3)),false)
here.recipe='copper-cable'
fails(function() check({['until']='produced',position={x=3.5,y=3.5},at_least=1},r3) end,'the assembling-machine-2 at (3.5,3.5) changed recipe')
-- refusals: a place there is needed; a platform goes by platform=; an unknown name
fails(function() C.validate({['until']='produced',surface='nauvis',at_least=1}) end,'produced with surface needs position or positions (the machines there)')
fails(function() C.validate({['until']='produced',surface='platform-1',position={x=0,y=0},at_least=1}) end,'produced surface is a planet; a platform goes by platform=NAME')
fails(function() C.validate({['until']='produced',surface='mars',position={x=0,y=0},at_least=1}) end,'produced surface must be a surface name')
fails(function() C.validate({['until']='produced',surface='nauvis',platform='Kestrel',item='iron-gear-wheel',at_least=1}) end,'surface or platform, not both')
print('d20_batch62c produced with surface: ok')

-- ammo_below, fuel_below and fluid_count on a planet by remote view
local function gun(x,y,n)
  local e={valid=true,name='gun-turret',type='ammo-turret',position={x=x,y=y}}
  e.get_inventory=function() return {get_item_count=function() return n end,get_contents=function() return n>0 and {{name='firearm-magazine',count=n}} or {} end} end
  nauvis.list[#nauvis.list+1]=e
  return e
end
gun(100,100,40); gun(104,100,2)
met,saw=check({['until']='ammo_below',surface='nauvis',positions={{x=100,y=100},{x=104,y=100}},count=5})
eq(met,true); eq(saw,'1 turrets below 5 (of 2 on nauvis; lowest gun-turret (104,100): 2 firearm-magazine)')
met,saw=check({['until']='ammo_below',surface='nauvis',position={x=100,y=100},radius=10,count=5})
eq(met,true); has(saw,'(of 2 on nauvis; lowest gun-turret (104,100)')
fails(function() check({['until']='ammo_below',surface='nauvis',positions={{x=90,y=90}},count=5}) end,'no ammo turret of ours at (90,90) on nauvis')
fails(function() C.validate({['until']='ammo_below',surface='nauvis',count=5}) end,'ammo_below with surface needs position (with radius), positions or area there')
local furnace={valid=true,name='stone-furnace',type='furnace',position={x=200,y=200},burner={}}
furnace.get_fuel_inventory=function() return {get_item_count=function() return 1 end} end
nauvis.list[#nauvis.list+1]=furnace
met,saw=check({['until']='fuel_below',surface='nauvis',area={left_top={x=190,y=190},right_bottom={x=210,y=210}},count=5})
eq(met,true); eq(saw,'1 burners below 5 fuel on nauvis (nearest stone-furnace at 200,200)')
-- an uncharted chunk there: not read
charted.nauvis=nil; charted['nauvis:3,3']=true
met,saw=check({['until']='fuel_below',surface='nauvis',area={left_top={x=190,y=190},right_bottom={x=210,y=210}},count=5})
eq(met,false); eq(saw,'0 burners below 5 fuel on nauvis')
charted.nauvis=true
local tank={valid=true,name='storage-tank',type='storage-tank',position={x=300,y=300},unit_number=900}
tank.get_fluid_count=function(f) return f=='sulfuric-acid' and 12000 or 0 end
nauvis.list[#nauvis.list+1]=tank
met,saw=check({['until']='fluid_count',surface='nauvis',positions={{x=300,y=300}},fluid='sulfuric-acid',below=5000})
eq(met,false); eq(saw,'sulfuric-acid 12000 on nauvis: tanks 12000 (1)')
met,saw=check({['until']='fluid_count',surface='nauvis',area={left_top={x=290,y=290},right_bottom={x=310,y=310}},fluid='water',at_least=1})
eq(met,false); eq(saw,'water 0 on nauvis: none in our 1 tanks, pipes and machines in the area')
fails(function() check({['until']='fluid_count',surface='nauvis',positions={{x=1,y=1}},fluid='water',at_least=1}) end,'no tank, pipe or machine of ours at (1,1) on nauvis')
fails(function() C.validate({['until']='fluid_count',surface='nauvis',fluid='water',at_least=1}) end,'fluid_count with surface needs positions or area there')
fails(function() C.validate({['until']='fluid_count',fluid='water',at_least=1}) end,'fluid_count requires platform (a platform name), or surface (a planet) with positions or area')
fails(function() C.validate({['until']='fluid_count',platform='Kestrel',positions={{x=1,y=1}},fluid='water',at_least=1}) end,'no positions or area (those go with surface)')
-- still refused: conditions that read no machine or chest there
fails(function() C.validate({['until']='turrets_idle',surface='nauvis',position={x=0,y=0}}) end,'turrets_idle reads no other surface')
print('d20_batch62c ammo_below, fuel_below, fluid_count with surface: ok')

-- the remote lane: those waits, and circuit_set with surface as its direct call takes it
local lanes=dofile('mod/agent-harness_0.1.0/queue_lanes.lua')
local checked
local function factory(api) checked=api.check_step; return {handlers={},schema={queue_submit={}}} end
pcall(lanes,{scheduler={handlers={},schema={queue_submit={}}},base={player=function() end,busy=function() end},factory=factory,is_read=function() return false end})
assert(checked,'queue_lanes gave no step check')
checked('wait_until',wait)
checked('wait_until',{['until']='fuel_below',surface='nauvis',position={x=0,y=0},count=1})
checked('wait_until',{['until']='fluid_count',surface='nauvis',positions={{x=0,y=0}},fluid='water',at_least=1})
checked('wait_until',{['until']='all',conditions={wait,{['until']='ammo_below',surface='nauvis',positions={{x=0,y=0}},count=1}}})
fails(function() checked('wait_until',{['until']='produced',position={x=0,y=0},at_least=1}) end,'produced, ammo_below, fuel_below or fluid_count with surface')
checked('circuit_set',{surface='fulgora',position={x=23.5,y=184.5},enable='quality-module > 999999'})
checked('circuit',{surface='fulgora',position={x=23.5,y=184.5}})
checked('wire',{surface='fulgora',from={x=0,y=0},to={x=1,y=0}})
checked('circuit_set',{platform='Kestrel',position={x=0,y=0}})
fails(function() checked('circuit_set',{position={x=0,y=0}}) end,'remote lane circuit_set requires platform or surface (by remote view, as the direct call takes them)')
fails(function() checked('drop',{surface='nauvis'}) end,'remote lane drop requires platform')
fails(function() checked('flush',{surface='nauvis'}) end,'remote lane flush requires platform')
print('d20_batch62c remote lane: ok')
defines,prototypes,game=nil,nil,nil
print('d20_batch62c: ok')
