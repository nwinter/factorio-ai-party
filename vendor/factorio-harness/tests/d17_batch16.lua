-- Run from the harness root: lua tests/d17_batch16.lua
-- d17 batch16 module contracts (the runtime ones are in tests/d17_batch16_rt.lua).
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,part) assert(type(s)=='string' and s:find(part,1,true),tostring(s)..'\n  lacks: '..part) end
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path

-- A2 (Grok/Wren d17: rocket-turret "came aboard 0" while the hull went from 9 turrets to 14): turrets a rocket brings
-- that construction robots place from the hub within the second count as came aboard, and are said as built at once.
do
  defines={space_platform_state={on_the_path=3,waiting_at_station=6,no_schedule=5},inventory={hub_main=1,hub_trash=2,cargo_unit=4}}
  prototypes={item={['rocket-turret']={get_spoil_ticks=function() return 0 end,place_result={name='rocket-turret'}},
    ['space-platform-foundation']={get_spoil_ticks=function() return 0 end,place_as_tile_result={result={name='space-platform-foundation'}}},
    ['carbon-fiber']={get_spoil_ticks=function() return 0 end}},space_location={nauvis={}}}
  local main={}
  local function inv(t) return {get_contents=function() local out={}; for n,c in pairs(t) do out[#out+1]={name=n,count=c,quality='normal'} end; return out end} end
  local hub={valid=true,get_inventory=function(id) return id==1 and inv(main) or inv({}) end,
    get_logistic_sections=function() return {sections_count=0,get_section=function() end} end}
  local turrets,tiles,counted=9,700,0
  local surface={find_entities_filtered=function() return {} end,
    count_entities_filtered=function(f) counted=counted+1; eq(f.name,'rocket-turret'); return turrets end,
    count_tiles_filtered=function(f) eq(f.name,'space-platform-foundation'); return tiles end}
  local wren={valid=true,index=1,name='Wren',hub=hub,state=6,space_location={name='nauvis'},surface=surface,
    schedule={records={{station='nauvis'}},current=1}}
  local force={name='player',platforms={wren}}
  wren.force=force
  game={tick=0,forces={player=force},planets={nauvis={surface={find_entities_filtered=function() return {} end}}}}
  local st={}
  local F=dofile('mod/agent-harness_0.1.0/freight.lua'){state=function() return st end,spoil=dofile('mod/agent-harness_0.1.0/spoil.lua'){state=function() return st end}}
  local function second(n) for _=1,n or 1 do game.tick=game.tick+60; F.tick(game.tick) end end
  main={['carbon-fiber']=10}
  second()
  -- a rocket with 5 turrets, 103 carbon fiber and 20 foundation: robots place the turrets and the tiles at once
  F.on_launch({rocket={attached_cargo_pod={cargo_pod_destination={station={surface={platform=wren}}},
    get_inventory=function() return inv({['rocket-turret']=5,['carbon-fiber']=103,['space-platform-foundation']=20}) end}}})
  second(10)
  main['carbon-fiber']=113; turrets=14; tiles=720
  second(5)
  local fr=F.read(wren)
  local line=fr[1].line
  has(line,'rocket-turret: came aboard 5, built at once 5 (construction robots placed it from the hub: 9 -> 14 on the platform)')
  has(line,'space-platform-foundation: came aboard 20, built at once 20 (construction robots placed it from the hub: 700 -> 720 on the platform)')
  has(line,'carbon-fiber')
  local row
  for _,r in ipairs(fr[1].items) do if r.item=='rocket-turret' then row=r end end
  eq(row.came,5); eq(row.built,5); eq(row.left,0)
  -- the stop ends: the count at its end is kept, a later build is not this stop's
  wren.state=3; wren.space_location=nil; wren.space_connection={from={name='nauvis'},to={name='gleba'},length=15000}; wren.distance=0.1
  wren.schedule={records={{station='gleba'}},current=1}
  prototypes.space_location.gleba={}
  second(2)
  turrets=16
  local done
  for _,s in ipairs(F.read(wren)) do if s.kind=='stop' then done=s end end
  has(done.line,'rocket-turret: came aboard 5, built at once 5 (construction robots placed it from the hub: 9 -> 14 on the platform)')
end
print('d17_batch16 A2 freight built at once: ok')
