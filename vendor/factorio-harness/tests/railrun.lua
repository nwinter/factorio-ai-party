-- Run from repository root: lua tests/railrun.lua
-- Elevated rails the game keeps (d20 batch69 AE1 and AE2, Sol #1642) against a fake track shaped like Sol's line on
-- Fulgora: elevated straight rails from x=265 to 289 at y=191 (each 2 tiles, ends at the even x), a rail support on the
-- joint at 278 (reach 11) and a rail ramp whose elevated end is the joint at 290 (reach 9). Read on 2.0.77 with that
-- layout rebuilt on a private copy: 271 to 279 and 265 were kept (265 by a support further west, left out here), 267,
-- 269 and 281 to 289 went; after 281 and 279 were mined, 277 went only once 269, 271, 273 and 275 had gone.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(text,part) assert(text and tostring(text):find(part,1,true),tostring(text)..' lacks '..part) end
defines={rail_direction={front=0,back=1}}
local entities,surface={},{}
local function dist(a,b) return math.sqrt((a.x-b.x)^2+(a.y-b.y)^2) end
local function new(t)
  t.valid=true; t.marked=false; t.surface=surface; t.minable_flag=true
  t.to_be_deconstructed=function() return t.marked end
  entities[#entities+1]=t
  return t
end
local rails={}
for x=265,289,2 do
  local r=new{name='elevated-straight-rail',type='elevated-straight-rail',position={x=x,y=191},unit_number=x}
  r.get_rail_end=function(d) return {location={position={x=x+(d==0 and 1 or -1),y=191}}} end
  rails[x]=r
end
local support=new{name='rail-support',type='rail-support',position={x=278,y=191},unit_number=1,prototype={support_range=11},
  bounding_box={left_top={x=276.6,y=189.6},right_bottom={x=279.4,y=192.4}}}
local ramp=new{name='rail-ramp',type='rail-ramp',position={x=298,y=191},unit_number=2,prototype={support_range=9}}
ramp.get_rail_end=function(d) return {location={position={x=d==0 and 306 or 290,y=191}}} end
local T={['elevated-straight-rail']=true,['elevated-half-diagonal-rail']=true,['elevated-curved-rail-a']=true,['elevated-curved-rail-b']=true,['rail-support']=true,['rail-ramp']=true}
function surface.find_entities_filtered(f)
  local want={}
  for _,t in ipairs(type(f.type)=='table' and f.type or {f.type}) do want[t]=true end
  local out={}
  for _,e in ipairs(entities) do
    if e.valid and want[e.type] and dist(e.position,f.position)<=f.radius then out[#out+1]=e end
  end
  return out
end
local R=dofile('mod/agent-harness_0.1.0/railrun.lua'){}
-- the game's flags as the copy read them (265 aside: a support further west keeps it)
local function settle(kept)
  for x,r in pairs(rails) do r.minable=not kept[x] end
end
settle({[271]=true,[273]=true,[275]=true,[277]=true,[279]=true})
-- the model: what is held up only through each rail
local function deps(e) local d=R.dependents(e) local xs={} for _,r in ipairs(d) do xs[#xs+1]=r.position.x end table.sort(xs) return table.concat(xs,',') end
eq(deps(rails[277]),'269,271,273,275','held up only through 277')
eq(deps(rails[279]),'281','281 is held up by the support through 279 only (the ramp reaches 283 to 289)')
eq(deps(rails[281]),'','281 can go')
eq(deps(rails[269]),'','269 can go')
eq(deps(rails[267]),'','267 can go: no support reaches it')
local w=R.why(rails[277])
has(w,'held up by rail-support (278,191)')
has(w,'held up only through it: 4 rails, elevated-straight-rail (275,191), elevated-straight-rail (273,191), elevated-straight-rail (271,191), elevated-straight-rail (269,191)')
has(w,'of those, these can go now: elevated-straight-rail (269,191)')
eq(R.why(rails[281]),nil)
-- Sol's 281 and 279 mined: 277 still kept for the same four
rails[281].valid=false; rails[279].valid=false
eq(deps(rails[277]),'269,271,273,275')
-- outermost first: 269, 271, 273, 275, then 277 has none
for _,x in ipairs({269,271,273,275}) do
  eq(deps(rails[x]),'','the outermost goes: '..x)
  rails[x].valid=false
end
eq(deps(rails[277]),'')
-- the support: kept while a rail is held up only by it
rails[281].valid=true; rails[279].valid=true; rails[269].valid=true; rails[271].valid=true; rails[273].valid=true; rails[275].valid=true
support.minable=false
has(R.why(support),'the game keeps a rail support while another rail is held up only by it')
eq(#R.carried(support),10,'the support holds up 269 to 287')
-- its flag off: said
has(R.why({valid=true,name='stone-furnace',type='furnace',position={x=4,y=4},minable=false,minable_flag=false}),'its minable flag is off')
print('railrun ok')
