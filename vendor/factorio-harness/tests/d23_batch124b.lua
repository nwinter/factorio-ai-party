-- Run from repository root: lua tests/d23_batch124b.lua
-- d23 batch124b (Sol #2042: Asterion has 97 ammo turrets and 23 railguns; platform_defense feed:true returned 64 turret
-- rows and 64 feed.turrets, and nothing to read the rest): the turrets and feed.turrets rows come 64 a page (page), of
-- the turrets that names or positions pick; turrets_page says which, feed.turrets_total how many the pick holds; the
-- lines read every turret.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
defines={inventory={turret_ammo=1}}
local function turret(name,x,y,range)
  return {valid=true,type='ammo-turret',name=name,position={x=x,y=y},bounding_box={left_top={x=x-1,y=y-1},right_bottom={x=x+1,y=y+1}},
    get_inventory=function() return {get_contents=function() return {{name='firearm-magazine',count=20}} end} end,
    prototype={attack_parameters={range=range,min_range=0}},ignore_unprioritised_targets=false,get_priority_target=function() return nil end}
end
local list={}
for k=1,97 do list[#list+1]=turret('gun-turret',k*2,0,18) end
for k=1,23 do list[#list+1]=turret('railgun-turret',k*2,-30,40) end
local s={find_entities_filtered=function(f) if f.type=='asteroid-collector' or f.type=='inserter' then return {} end return list end,
  find_tiles_filtered=function() return {} end}
-- the ammunition trace: a row per turret (ammofeed.lua), in its own order (rails first here)
local tr={rows={},reaches=0,stranded=0}
for k=#list,1,-1 do local t=list[k]; tr.rows[#tr.rows+1]={position=t.position,own=5,reaches=5,stops={},gated={}} end
local feed={get=function() return tr end,lines=function(t) for _,row in ipairs(t.rows) do row.replenished='hub' end return {} end}
local D=dofile('mod/agent-harness_0.1.0/platdefense.lua'){platform=function() return {name='Asterion',surface=s,force='f'} end,
  position=function(q) return {x=q.x or q[1],y=q.y or q[2]} end,ammofeed=feed}
local r=D.read({},{platform='Asterion',feed=true,ammo_use=false})
eq(#r.turrets,64); eq(r.turrets[1].position.x,2)
local pg=r.turrets_page
eq(pg.page,1); eq(pg.pages,2); eq(pg.total,120); eq(pg.turrets,120); eq(pg.from,1); eq(pg.to,64); eq(pg.next,2); eq(pg.filter,nil)
eq(#r.feed.turrets,64); eq(r.feed.turrets_total,120); eq(r.feed.turrets[1].replenished,'hub')
-- the feed rows on this page are the turrets on this page (by position), in the trace's order
local on={}
for _,t in ipairs(r.turrets) do on[t.position.x..','..t.position.y]=true end
for _,row in ipairs(r.feed.turrets) do assert(on[row.position.x..','..row.position.y],'a feed row off the page') end
has(r.lines[#r.lines] and table.concat(r.lines,'\n'),'120 turrets: 120 armed now')  -- the lines read every turret
-- page 2: the other 56, and nothing after
r=D.read({},{platform='Asterion',feed=true,ammo_use=false,page=2})
eq(#r.turrets,56); eq(r.turrets_page.from,65); eq(r.turrets_page.to,120); eq(r.turrets_page.next,nil); eq(#r.feed.turrets,56)
fails(function() D.read({},{platform='Asterion',page=3}) end,'page 3: the 120 turrets picked make 2 pages of 64')
fails(function() D.read({},{platform='Asterion',page=0}) end,'page is 1, 2, ...')
-- the railguns alone (Sol's remaining 8 rails among them): one page of 23, the feed rows theirs
r=D.read({},{platform='Asterion',feed=true,ammo_use=false,names='railgun-turret'})
eq(#r.turrets,23); eq(r.turrets_page.total,23); eq(r.turrets_page.filter,'names railgun-turret'); eq(r.feed.turrets_total,23)
for _,t in ipairs(r.turrets) do eq(t.name,'railgun-turret') end
-- positions: within a tile of each; with names, either
r=D.read({},{platform='Asterion',ammo_use=false,positions={{x=4,y=0.5},{x=10,y=-30}}})
eq(#r.turrets,2); eq(r.turrets[1].position.x,4); eq(r.turrets[2].name,'railgun-turret'); eq(r.turrets_page.filter,'2 positions')
r=D.read({},{platform='Asterion',ammo_use=false,names={'railgun-turret'},positions={{x=4,y=0}}})
eq(#r.turrets,24); eq(r.turrets_page.filter,'names railgun-turret or 1 position')
fails(function() D.read({},{platform='Asterion',names={}}) end,'names: 1..16')
defines=nil
print('d23 batch124b: ok (platform_defense rows paged and picked; the feed rows follow the page)')
