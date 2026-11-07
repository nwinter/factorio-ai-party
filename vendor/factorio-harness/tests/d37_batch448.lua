-- Factorio 2.0.77 fixtures from test_d37_batch448_private.py: each tile
-- removed in turn from a full pad, all 16 directions, then native revival.
package.path = 'mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b) assert(a==b,tostring(a)..' ~= '..tostring(b)) end
local function mask(...) local l={} for _,v in ipairs{...} do l[v]=true end return {layers=l} end
local proto={name='railgun-turret',type='ammo-turret',flags={['building-direction-8-way']=true},
  collision_box={left_top={x=-1.40625,y=-1.8984375},right_bottom={x=1.40625,y=2.09765625}},
  collision_mask=mask('object'),tile_width=3,tile_height=5}
prototypes={tile={['empty-space']={collision_mask=mask('empty_space','object')},
  ['space-platform-foundation']={name='space-platform-foundation',collision_mask=mask('ground_tile')}}}
prototypes.item={['space-platform-foundation']={name='space-platform-foundation',place_as_tile_result={
  result=prototypes.tile['space-platform-foundation'],condition=mask('empty_space'),invert=true}}}
local force={recipes={}}
local surface={get_tile=function() return {name='empty-space',prototype=prototypes.tile['empty-space']} end,
  find_entities_filtered=function() return {} end, count_entities_filtered=function() return 0 end}
local D=require('dryrun'){placewhy=require('placewhy'){}}
local G=require('ghostlist'){}
local R=require('rotatedbox')
local function key(x,y) return x..','..y end
local diag={[-2]={-1,0},[-1]={-2,-1,0,1},[0]={-2,-1,0,1,2},[1]={-1,0,1,2},[2]={0,1}}
for d=0,15 do
  local expected={}
  if d%4<2 then
    local w,h=1,2
    if math.floor(d/4)%2==1 then w,h=h,w end
    for x=-w,w do for y=-h,h do expected[key(x,y)]=true end end
  else
    for x,ys in pairs(diag) do for _,y in ipairs(ys) do
      expected[key((math.floor(d/4)%2==0) and -x or x,y)]=true
    end end
  end
  for _,p in ipairs{{x=.5,y=.5},{x=-41.5,y=149.5}} do
    local fixes=D.tile_fixes(surface,force,proto,p,d)
    eq(#fixes,d%4<2 and 15 or 17)
    local seen={}
    for _,f in ipairs(fixes) do
      local k=key(math.floor(f.x)-math.floor(p.x),math.floor(f.y)-math.floor(p.y))
      assert(expected[k],d..': extra '..k); seen[k]=true
      eq(f.item,'space-platform-foundation')
    end
    for k in pairs(expected) do assert(seen[k],d..': missing '..k) end
    local box=D.footprint(proto,p,d)
    local ghost={ghost_prototype=proto,position=p,direction=d,force=force,bounding_box=box}
    local floor=G.floor(surface,ghost)
    eq(floor.bare,#fixes); eq(floor.ghosted,0)
    surface.count_entities_filtered=function() return 1 end
    floor=G.floor(surface,ghost); eq(floor.bare,0); eq(floor.ghosted,#fixes)
    surface.count_entities_filtered=function() return 0 end
  end
end
-- Ordinary buildings keep the cardinal path; sixteen-way flags retain all
-- directions. Real railguns have the eight-way flag and round odd inputs down.
eq(R.direction(proto,15),14)
local ordinary={flags={},collision_box=proto.collision_box}
eq(R.shape(ordinary,{x=.5,y=.5},14),nil)
local sixteen={flags={['building-direction-16-way']=true},collision_box=proto.collision_box}
for d=0,15 do eq(R.direction(sixteen,d),d); eq(R.shape(sixteen,{x=.5,y=.5},d)~=nil,d%4~=0) end
print('batch448: all 16 engine tile fixtures, live floor and ghost diagnostics agree')
