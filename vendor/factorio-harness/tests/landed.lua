-- Run from the harness root: lua tests/landed.lua
-- Landed cargo pods (landed.lua; d17 pods, Nick 15:45: "a bunch of landed cargo drop ships on Vulcanus and Aquilo have
-- just been sitting there. Do the agents see those?"): the sweep finds them slice by slice, pods reads them, status and
-- the team block say them, the team block once an hour.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,part) assert(type(s)=='string' and s:find(part,1,true),tostring(s)..'\n  lacks: '..part) end
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
defines={inventory={chest=1,cargo_landing_pad_main=2}}
local force={name='player'}
local function inv(items)
  local t={}
  t.get_contents=function() local out={} for n,c in pairs(items) do out[#out+1]={name=n,count=c} end table.sort(out,function(a,b) return a.name<b.name end) return out end
  t.count_empty_stacks=function() return 80 end
  return setmetatable(t,{__len=function() return 80 end})
end
local units=0
local function ent(name,x,y,items)
  units=units+1
  local i=inv(items or {})
  return {valid=true,name=name,unit_number=units,position={x=x,y=y},force=force,get_inventory=function() return i end}
end
local vul={ent('cargo-pod-container',3.5,5.5,{['iron-plate']=300,ice=34}),ent('cargo-pod-container',-16.5,-5.5,{['iron-plate']=2983,carbon=1721}),
  ent('cargo-pod-container',14.5,134.5,{['utility-science-pack']=500}),ent('cargo-landing-pad',12,176),
  ent('cargo-pod-container',3000,3000,{coal=5})}  -- past the sweep's 1024 tiles
local finds=0
local function surface(name,list,platform)
  return {name=name,valid=true,platform=platform,find_entities_filtered=function(f)
    finds=finds+1
    assert(f.area,'the sweep looks at squares only')
    local out={}
    for _,e in ipairs(list) do
      local want=false
      for _,n in ipairs(f.name) do if n==e.name then want=true end end
      if want and e.position.x>=f.area[1][1] and e.position.x<f.area[2][1] and e.position.y>=f.area[1][2] and e.position.y<f.area[2][2] then out[#out+1]=e end
    end
    return out
  end}
end
local V,N,P=surface('vulcanus',vul),surface('nauvis',{}),surface('platform-3',{},{name='Swift'})
game={tick=0,surfaces={vulcanus=V,nauvis=N,['platform-3']=P},forces={player=force},get_surface=function(n) return ({vulcanus=V,nauvis=N})[n] end}
local st={}
local L=dofile('mod/agent-harness_0.1.0/landed.lua'){state=function() return st end,position=function(q) return q end}
-- nothing found before the sweep has been there
local p={surface=V,position={x=0,y=0},force=force}
eq(L.read(p,{}).containers,0)
has(L.read(p,{}).coverage,'has not been over all of Vulcanus yet')
-- the sweep: one 128-square a STEP, the planets in turn (nauvis first, then vulcanus); the platform is no planet
for t=60,60*512,60 do game.tick=t; L.tick(t) end
eq(finds,512,'one find a step: 256 squares a planet, two planets')
local r=L.read(p,{})
eq(r.containers,3,'the one past 1024 tiles is not swept')
eq(r.total,300+34+2983+1721+500)
eq(r.line,'Vulcanus: 3 landed cargo pods hold 5,538 items (iron-plate 3283, carbon 1721, utility-science-pack 500, ice 34); nearest (3.5,5.5), 7 tiles; landing pad (12,176) 80 of 80 slots free')
has(r.coverage,'the sweep looks within 1024 tiles of (0,0), last over Vulcanus 0 min ago')
eq(r.nearest.distance,7)
-- an emptied (gone) container drops out
vul[1].valid=false
eq(L.read(p,{}).containers,2)
-- collect's list: nearest first, holding something
local list=L.containers(V,{x=10,y=130})
eq(list[1].position.y,134.5)
-- status: a line a planet; the team block once an hour
local q={surface=N,position={x=0,y=0},force=force}
local lines=L.status_lines(q)
eq(#lines,1); has(lines[1],'Vulcanus: 2 landed cargo pods hold')
local h={}
eq(#L.team_lines(q,h),1)
game.tick=game.tick+3600
eq(L.team_lines(q,h),nil,'not again within the hour')
game.tick=game.tick+216000
eq(#L.team_lines(q,h),1)
print('landed: ok')
