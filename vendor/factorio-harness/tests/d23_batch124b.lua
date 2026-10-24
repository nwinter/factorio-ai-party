-- Run from repository root: lua tests/d23_batch124b.lua
-- d23 batch124b (Sol #2042: Asterion has 97 ammo turrets and 23 railguns; platform_defense feed:true returned 64 turret
-- rows and 64 feed.turrets, and nothing to read the rest): the turrets and feed.turrets rows come 64 a page (page), of
-- the turrets that names or positions pick; turrets_page says which, feed.turrets_total how many the pick holds; the
-- lines read every turret. (Sol #2071: 16 of the 23 railguns' lines of fire returned) the lines of fire come 16 a page
-- (line_page) of the picked turrets whose shots are a line; railguns_only picks those; lines_page says which.
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
-- (#2071) the railguns' lines of fire: the rail at x=10 hits two of ours, the one at x=20 reads a cut find, x=30 fails
local fired=0
local fire={arc=function(n) return n=='railgun-turret' and {arc=0.2} or nil end,
  of=function(e) fired=fired+1
    if e.position.x==30 then error('no surface') end
    local hit=e.position.x==10 and 2 or 0
    return {line=e.name..' at '..e.position.x..(hit>0 and ' hit 2 of ours' or ' none of ours'),hit=hit,cut=e.position.x==20 or nil,entities={}} end}
local D=dofile('mod/agent-harness_0.1.0/platdefense.lua'){platform=function() return {name='Asterion',surface=s,force='f'} end,
  position=function(q) return {x=q.x or q[1],y=q.y or q[2]} end,ammofeed=feed,fireline=fire}
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
-- (#2071) the lines of fire come 16 a page of the 23 railguns picked, every reply saying which of how many
fired=0
r=D.read({},{platform='Asterion',ammo_use=false})
local lp=r.lines_page
eq(lp.page,1); eq(lp.pages,2); eq(lp.total,23); eq(lp.returned,16); eq(lp.from,1); eq(lp.to,16); eq(lp.next,2); eq(#r.lines_of_fire,16); eq(fired,16)
eq(lp.clear,13); eq(lp.hitting,1); eq(lp.hit,2); eq(lp.cut,1); eq(lp.unread,1)
eq(r.turrets_page.returned,64)
local text=table.concat(r.lines,'\n')
has(text,'turret rows: page 1 of 2, turrets 1-64 of the 120 picked (120 turrets read); 56 more on page 2..2')
has(text,'lines of fire: line_page 1 of 2, turrets 1-16 of the 23 picked whose shots are a line: 13 hit none of ours (every entity near the arc read), 1 hit 2 of ours, 1 read only part of the entities near their arc (cut), 1 not read; 7 more on line_page 2..2')
has(text,'line of fire: railgun-turret (30,-30): not read')
eq(r.lines_of_fire[15].unread,true); eq(r.lines_of_fire[10].cut,true); eq(r.lines_of_fire[5].hit,2)
-- page 1's turret rows are guns: none carries a line
for _,t in ipairs(r.turrets) do eq(t.line_of_fire,nil); eq(t.line_page,nil) end
-- line_page 2: the other 7, and nothing after
fired=0
r=D.read({},{platform='Asterion',ammo_use=false,line_page=2})
eq(r.lines_page.from,17); eq(r.lines_page.to,23); eq(r.lines_page.returned,7); eq(r.lines_page.next,nil); eq(#r.lines_of_fire,7); eq(fired,7)
eq(r.lines_of_fire[1].position.x,34)
fails(function() D.read({},{platform='Asterion',line_page=3}) end,'line_page 3: the 23 turrets picked whose shots are a line make 2 pages of 16')
fails(function() D.read({},{platform='Asterion',line_page=1.5}) end,'line_page is 1, 2, ...')
-- railguns_only: the 23 rails' rows on one page; those whose line is on line_page 2 say so
r=D.read({},{platform='Asterion',ammo_use=false,railguns_only=true})
eq(#r.turrets,23); eq(r.turrets_page.total,23); eq(r.turrets_page.filter,'railguns only (shots a line)'); eq(r.lines_page.filter,'railguns only (shots a line)')
eq(r.turrets[1].line_of_fire,'railgun-turret at 2 none of ours'); eq(r.turrets[16].hits,0); eq(r.turrets[17].line_page,2); eq(r.turrets[17].line_of_fire,nil)
-- with names or positions: their pick, then the rails of it
r=D.read({},{platform='Asterion',ammo_use=false,railguns_only=true,positions={{x=4,y=0},{x=10,y=-30}}})
eq(#r.turrets,1); eq(r.turrets[1].position.x,10); eq(r.turrets_page.filter,'(2 positions) and railguns only (shots a line)'); eq(r.lines_page.total,1)
r=D.read({},{platform='Asterion',ammo_use=false,names='gun-turret'})
eq(r.lines_page.total,0); eq(r.lines_page.returned,0); eq(r.lines_page.from,0); eq(#r.lines_of_fire,0)
fails(function() D.read({},{platform='Asterion',railguns_only='yes'}) end,'railguns_only is true or false')
defines=nil
print('d23 batch124b: ok (platform_defense rows and lines of fire paged and picked; the feed rows follow the page)')
