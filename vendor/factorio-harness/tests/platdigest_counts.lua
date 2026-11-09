-- Whole-ship counts survive paging/filtering, caps, and failed reads. Exercise the actual defense producer.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b) assert(a==b,tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(s:find(x,1,true),s..' lacks '..x) end
local function not_clear(r)
  assert(not r.lines[1]:find('stopped or blocked: none',1,true),r.lines[1])
end
defines={inventory={turret_ammo=1}}
game={tick=100}
prototypes={item={},entity={}}
local list, fail, finds = {}, nil, 0
local s={find_tiles_filtered=function() return {} end}
function s.find_entities_filtered(f)
  if f.type=='asteroid-collector' or f.type=='inserter' then return {} end
  finds=finds+1
  if fail=='find' then error('turret find failed') end
  local out={}
  for i=1,math.min(#list,f.limit or #list) do out[i]=list[i] end
  return out
end
local pl={name='PD354',surface=s,force='player'}
local D=require('platdefense'){platform=function() return pl end,position=function(q) return q end}
local function setup(n,empty)
  list={}; finds=0; fail=nil
  for i=1,n do
    local t={valid=true,type='ammo-turret',name='gun-turret',position={x=i*3,y=0},
      bounding_box={left_top={x=i*3-1,y=-1},right_bottom={x=i*3+1,y=1}},
      prototype={attack_parameters={range=18}},ignore_unprioritised_targets=false}
    t.get_inventory=function()
      if fail=='inventory' and i==65 then error('inventory failed') end
      return {get_contents=function() return i==empty and {} or {{name='firearm-magazine',count=10}} end}
    end
    list[i]=t
  end
end
local reads={platforms=function() return {platforms={{}}} end,platform_supply=function() return {} end,
  platform_endurance=function() return {} end,platform_defense=D.read}
local G=require('platdigest'){platform=function() return pl end,reads=reads}
for _,n in ipairs{65,137} do
  setup(n,65)
  local first=D.read({},{platform=pl.name})
  eq(#first.turrets,64); eq(first.turret_counts.total,n); eq(first.turret_counts.empty,1)
  eq(first.turret_counts.status,'complete'); eq(first.turret_counts.armed,n-1)
  for _,t in ipairs(first.turrets) do assert(t.ammo~='no ammo') end
  local second=D.read({},{platform=pl.name,page=2})
  eq(second.turrets[1].ammo,'no ammo'); eq(second.turret_counts.empty,1); eq(second.turret_counts.total,n)
  local picked=D.read({},{platform=pl.name,positions={{x=3,y=0}}})
  eq(#picked.turrets,1); eq(picked.turret_counts.total,n); eq(picked.turret_counts.empty,1)
  local before=finds
  local r=G.read({},{platform=pl.name})
  eq(finds,before+1) -- no extra scans or serial page fetching
  eq(r.turret_counts.total,n); eq(r.turret_counts.empty,1); eq(r.check.status,'complete')
  has(r.turrets,n..' turrets, 1 empty'); not_clear(r)
end
-- Exactly at the bound is conservatively capped too; beyond it the sole empty is unseen.
for _,n in ipairs{256,257} do
  setup(n,257)
  local d=D.read({},{platform=pl.name})
  eq(d.turrets_page.capped,256); eq(d.turret_counts.capped,256); eq(d.turret_counts.read,256)
  eq(d.turret_counts.total,nil); eq(d.turret_counts.empty,0); eq(d.turret_counts.status,'capped')
  local r=G.read({},{platform=pl.name})
  eq(r.check.status,'capped'); not_clear(r); has(r.lines[1],'unknown'); has(r.turrets,'whole-ship counts capped at 256')
end
setup(0)
local r=G.read({},{platform=pl.name})
eq(r.turret_counts.total,0); eq(r.check.status,'complete'); has(r.lines[1],'stopped or blocked: none')
-- Engine failure and an unread inventory must never become an empty, clear ship.
setup(137)
fail='find'; r=G.read({},{platform=pl.name})
eq(r.turret_counts.status,'unknown'); eq(r.check.status,'unknown'); not_clear(r)
has(r.errors[1],'platform_defense: turret find failed'); has(r.turrets,'whole-ship turret counts unknown')
fail='inventory'; r=G.read({},{platform=pl.name})
eq(r.turret_counts.status,'unknown'); eq(r.turret_counts.unread,1); eq(r.turret_counts.empty,0)
eq(r.turret_counts.armed,136); eq(r.turret_counts.unarmed,0); not_clear(r)
fail=nil
-- Every constituent failure blocks the all-clear line, while preserving other facts.
for _,name in ipairs{'platforms','platform_supply','platform_endurance','platform_defense'} do
  local saved=reads[name]
  reads[name]=function() error('read failed') end
  r=G.read({},{platform=pl.name}); eq(r.check.status,'unknown'); not_clear(r); has(r.errors[1],name..': read failed')
  reads[name]=function() return nil end
  r=G.read({},{platform=pl.name}); eq(r.check.status,'unknown'); not_clear(r)
  reads[name]=saved
end
-- No row-count fallback for old or incomplete responses; feed/hull incompleteness is visible too.
for _,d in ipairs{
  {turrets={},turrets_page={turrets=137}},
  {turret_counts={status='complete',read=137,total=137,empty=0},sides_capped=40000},
  {turret_counts={status='complete',read=137,total=137,empty=0},feed={error='trace failed'}},
  {turret_counts={status='complete',read=137,total=137,empty=0},feed={pending='trace pending'}}
} do
  reads.platform_defense=function() return d end
  r=G.read({},{platform=pl.name}); not_clear(r); assert(r.check.status~='complete')
end
print('platdigest_counts: ok (65/137 page-2 empty; 256/257 cap; failed find/inventory/constituents; filters; no page fallback)')
