-- d27 batch292. Run from the harness root: lua tests/d27_batch292.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path

-- IP (Astra #2639: Resolute's bulk inserters at (+-6.5,320.5), disabled by S<0, read "no pickup target" and "picks from
-- nothing (the ground)" with a transport belt on their pickup tiles). On 2.0.77 (the iMac copy of world n, d27 18:50):
-- a belt or chest built again on a disabled inserter's pickup point (circuit or logistic condition) leaves pickup_target
-- nil until it runs; an underground belt or splitter there is its target as the entity itself. An unset engine target
-- with something it uses on the tile says both; the ground only when nothing is there.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x,m) assert(tostring(s):find(x,1,true),(m or '')..' '..tostring(s)..' lacks '..x) end
local function lacks(s,x,m) assert(not tostring(s):find(x,1,true),(m or '')..' '..tostring(s)..' has '..x) end
defines={entity_status={waiting_for_source_items=1,disabled_by_control_behavior=2,working=3}}
local ents={}
local surface={}
function surface.find_entities_filtered(f)
  local out={}
  for _,e in ipairs(ents) do
    local b=e.box
    if f.position and f.position.x>=b[1] and f.position.x<=b[3] and f.position.y>=b[2] and f.position.y<=b[4] then out[#out+1]=e end
  end
  return out
end
function surface.get_tile() return {name='space-platform-foundation'} end
local function ent(name,type,x,y,w,h)
  local e={name=name,type=type,position={x=x,y=y},valid=true,surface=surface,box={x-(w or 0.5),y-(h or 0.5),x+(w or 0.5),y+(h or 0.5)}}
  ents[#ents+1]=e; return e
end
local belt=ent('transport-belt','transport-belt',-7.5,320.5,0.4,0.4)
local reactor=ent('fusion-reactor','fusion-reactor',-3,320,3,3)
local chest=ent('steel-chest','container',10.5,0.5,0.35,0.35)
local under=ent('underground-belt','underground-belt',20.5,0.5,0.4,0.4)
local split=ent('splitter','splitter',30.5,1,0.4,0.9)
local function ins(x,y,pp,dp,pick,drop,status)
  return {name='bulk-inserter',type='inserter',valid=true,surface=surface,position={x=x,y=y},pickup_position=pp,drop_position=dp,
    pickup_target=pick,drop_target=drop,status=status or defines.entity_status.disabled_by_control_behavior,
    held_stack={valid_for_read=false}}
end
local T=dofile('mod/agent-harness_0.1.0/targets.lua'){}
local api={unset_target=function(e,side) return T.unset(e,side) end}

-- targets.lua: the unset target with a belt there, the ground with nothing, a set target
do
  local a=ins(-6.5,320.5,{x=-7.5,y=320.5},{x=-5.30078,y=320.5},nil,reactor)
  local text,note,x=T.unset(a,'pickup')
  eq(text,'transport-belt (-7.5,320.5) on its pickup tile'); eq(note,"the engine's pickup target is unset until the inserter runs"); eq(x,belt)
  eq(T.unset(a,'drop'),nil,'the drop target is set')
  eq(T.missing(a),'pickup target unset by the engine (transport-belt (-7.5,320.5) on its pickup tile)')
  local g=ins(0.5,5.5,{x=0.5,y=4.5},{x=0.5,y=6.5},nil,nil)
  eq(T.unset(g,'pickup'),nil,'nothing on the tile'); eq(T.missing(g),'no pickup target, no drop target')
  eq(T.unset(ins(-6.5,320.5,{x=-7.5,y=320.5},{x=-5.3,y=320.5},belt,reactor),'pickup'),nil,'a target set')
  -- a chest, an underground belt and a splitter tile (its second tile too)
  eq((T.unset(ins(10.5,1.5,{x=10.5,y=0.5},{x=10.5,y=2.7},nil,chest),'pickup')),'steel-chest (10.5,0.5) on its pickup tile')
  eq((T.unset(ins(20.5,1.5,{x=20.5,y=0.5},{x=20.5,y=2.7}),'pickup')),'underground-belt (20.5,0.5) on its pickup tile')
  eq((T.unset(ins(30.5,2.5,{x=30.5,y=1.5},{x=30.5,y=3.7}),'pickup')),'splitter (30.5,1) on its pickup tile')
  -- the drop side: the engine's drop target unset with the reactor on the tile
  local d=ins(-6.5,320.5,{x=-7.5,y=320.5},{x=-5.3,y=320.5},belt,nil)
  local dt,dn=T.unset(d,'drop')
  eq(dt,'fusion-reactor (-3,320) on its drop tile'); eq(dn,"the engine's drop target is unset")
  eq(T.missing(d),'drop target unset by the engine (fusion-reactor (-3,320) on its drop tile)')
  eq(T.unset({valid=true,type='container'},'pickup'),nil,'not an inserter')
  print('d27_batch292 IP targets: ok')
end

-- details.lua (inspect): pickup_unset and drop_unset; the drop tile only with nothing there; pickup_wait
do
  local D=dofile('mod/agent-harness_0.1.0/details.lua')(api)
  local a=ins(-6.5,320.5,{x=-7.5,y=320.5},{x=-5.3,y=320.5},nil,reactor)
  a.bounding_box={left_top={x=-7,y=320},right_bottom={x=-6,y=321}}
  local out={}
  D.inspect(a,out)
  eq(out.pickup_target,nil)
  eq(out.pickup_unset,"transport-belt (-7.5,320.5) on its pickup tile (the engine's pickup target is unset until the inserter runs)")
  eq(out.drop_unset,nil)
  local d=ins(-6.5,320.5,{x=-7.5,y=320.5},{x=-5.3,y=320.5},belt,nil)
  d.bounding_box=a.bounding_box
  out={}
  D.inspect(d,out)
  eq(out.drop_unset,"fusion-reactor (-3,320) on its drop tile (the engine's drop target is unset)")
  eq(out.drop_tile,nil,'no drop tile with the reactor there')
  -- an enabled idle one (the engine sets it within 3 s): pickup_wait names the belt, not the ground
  local w=ins(-6.5,320.5,{x=-7.5,y=320.5},{x=-5.3,y=320.5},nil,reactor,defines.entity_status.waiting_for_source_items)
  local pw=D.pickup_wait(w)
  has(pw,'transport-belt (-7.5,320.5) on its pickup tile'); lacks(pw,'ground')
  local g=ins(0.5,5.5,{x=0.5,y=4.5},{x=0.5,y=6.5},nil,chest,defines.entity_status.waiting_for_source_items)
  eq(D.pickup_wait(g),'picks from the ground: no item lies at its pickup point')
  -- without the helper (an older api): as before
  local D0=dofile('mod/agent-harness_0.1.0/details.lua'){}
  eq(D0.pickup_wait(w),'picks from the ground: no item lies at its pickup point')
  print('d27_batch292 IP inspect fields and pickup_wait: ok')
end

-- feeders.lua: what it takes from
do
  local F=dofile('mod/agent-harness_0.1.0/feeders.lua')(api)
  local f=F.read(ins(-6.5,320.5,{x=-7.5,y=320.5},{x=-5.3,y=320.5},nil,reactor),{'fusion-power-cell'})
  eq(f.takes_from,"transport-belt (-7.5,320.5) on its pickup tile (the engine's pickup target is unset until the inserter runs)")
  eq(F.read(ins(0.5,5.5,{x=0.5,y=4.5},{x=0.5,y=6.5},nil,chest),{'iron-plate'}).takes_from,'nothing (the ground)')
  print('d27_batch292 IP feeders: ok')
end
defines=nil
