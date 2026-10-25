-- Run from the harness root: lua tests/d24_batch174.lua
-- d24 batch174 QQ1 (Luna #2242): danger counted the unseen chunks and map/scan listed charted entities, so a remote read
-- could not say which chunks of a defended wall were out of sight nor which radar would cover them. sight {surface,
-- position+radius | area} gives each chunk visible now, charted (not visible) or uncharted, the source of each visible
-- chunk (a working radar's continuous scan, else a roboport, cargo landing pad or spidertron, else a radar without
-- power), and for each other chunk the nearest radar and how far outside its scan; at most 256 chunks a call.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(s and tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
defines={entity_status={working=1,no_power=54}}
local proto={get_max_distance_of_nearby_sector_revealed=function() return 3 end}
local function radar(id,x,y,st) return {valid=true,name='radar',unit_number=id,position={x=x,y=y},status=st,quality={name='normal'},prototype=proto} end
local function thing(id,name,x,y) return {valid=true,name=name,unit_number=id,position={x=x,y=y}} end
-- radar #1 working at chunk (0,0): its scan x,y -3..3; radar #2 without power at chunk (10,0); a roboport at chunk (6,0)
local list={radar={radar(1,16,16,1),radar(2,336,16,54)},roboport={thing(3,'roboport',208,16)},['cargo-landing-pad']={},['spider-vehicle']={}}
local VIS,CH={},{}
local function key(c) return c.x..','..c.y end
for x=-3,3 do for y=-3,3 do VIS[x..','..y]=true end end
for x=4,8 do for y=-2,2 do VIS[x..','..y]=true end end         -- the roboport's 5x5
VIS['9,0']=true; VIS['-5,0']=true                              -- 9,0 lit by radar #2 before it stopped; -5,0 by none
for x=-6,14 do for y=-6,6 do CH[x..','..y]=true end end
local force={name='player',is_chunk_visible=function(s,c) return VIS[key(c)]==true end,is_chunk_charted=function(s,c) return CH[key(c)]==true end}
local nauvis={name='nauvis',find_entities_filtered=function() error('the census lists are used') end}
local gleba={name='gleba'}
local S=dofile('mod/agent-harness_0.1.0/sight.lua'){position=function(q) return {x=q.x or q[1],y=q.y or q[2]} end,
  surface=function(p,n) return n=='gleba' and gleba or nauvis end,census_typed=function(f,s,t) return list[t] end}
local luna={force=force,surface=nauvis,character={valid=true,surface=gleba,position={x=0,y=0}}}

-- a row through all of them: chunks x -5..14, y 0 (tiles -160..480, 0..32)
do
  local r=S.read(luna,{surface='nauvis',area={{-160,0},{480,32}}})
  eq(r.chunks,20); eq(r.cap,256); eq(r.chunk_area.left,-5); eq(r.chunk_area.right,14); eq(r.chunk_area.top,0); eq(r.chunk_area.bottom,0)
  eq(r.counts.visible,7+5+2); eq(r.counts.charted,6); eq(r.counts.uncharted,0)
  local by={}
  for _,g in ipairs(r.visible) do by[g.by or 0]=g end
  local s1,s3,s2
  for i,s in ipairs(r.sources) do if s.unit_number==1 then s1=i elseif s.unit_number==3 then s3=i elseif s.unit_number==2 then s2=i end end
  eq(r.sources[s1].kind,'radar'); eq(r.sources[s1].status,'working'); eq(r.sources[s1].position,'16,16'); eq(r.sources[s1].chunk,'0,0'); eq(r.sources[s1].range,3)
  eq(by[s1].chunks,'-3,0 -2,0 -1,0 0,0 1,0 2,0 3,0','radar #1 gives its scan'); eq(by[s1].n,7)
  eq(r.sources[s3].kind,'roboport'); eq(r.sources[s3].range,2); eq(by[s3].chunks,'4,0 5,0 6,0 7,0 8,0','the roboport outside the radar\'s scan')
  eq(r.sources[s2].status,'no_power'); eq(by[s2].chunks,'9,0','in radar #2\'s scan with no power: that radar')
  eq(by[0].chunks,'-5,0','no source of ours covers -5,0')
  -- not visible: the nearest radar and how far outside its scan (radar #2's scan, no power: 0)
  local ch={}
  for _,g in ipairs(r.charted) do ch[#ch+1]=r.sources[g.radar].unit_number..'/'..g.outside..':'..g.chunks end
  table.sort(ch)
  eq(table.concat(ch,' | '),'1/1:-4,0 | 2/0:10,0 11,0 12,0 13,0 | 2/1:14,0','charted chunks by nearest radar')
  has(r.rows[1],'row y=0: visible -5 (no source of ours covers it now); charted -4 (radar #1, 1 outside its scan); visible -3..3 (radar #1); visible 4..8 (roboport #3); visible 9 (radar #2); charted 10..14 (radar #2, 0-1 outside its scan)')
  has(r.lines[1],'nauvis: chunks x -5..14, y 0..0 (tiles -160,0 to 480,32), 20 chunks (cap 256): 14 visible now, 6 charted (not visible), 0 uncharted')
  has(table.concat(r.lines,'\n'),'radar #1 radar at (16,16), chunk (0,0), working: continuous scan 3 chunks either axis; gives sight to 7 chunks here')
  has(table.concat(r.lines,'\n'),'1 visible chunks no source of ours covers now')
end
print('d24_batch174 QQ1 sight: visible by radar, roboport, radar without power, none; charted by nearest radar: ok')

-- uncharted, and a position with radius
do
  CH['14,0']=nil
  local r=S.read(luna,{surface='nauvis',position={x=464,y=16},radius=16})
  eq(r.chunks,1,'tiles 448..480, 0..32: chunk 14,0 alone'); eq(r.counts.uncharted,1)
  eq(r.uncharted[1].chunks,'14,0'); eq(r.sources[r.uncharted[1].radar].unit_number,2); eq(r.uncharted[1].outside,1)
  eq(r.position.x,464); eq(r.radius,16)
end
print('d24_batch174 QQ1 sight: uncharted, position and radius: ok')

-- bounds: the cap, the radius, the arguments; remote needs a position there
do
  local ok,err=pcall(S.read,luna,{surface='nauvis',area={{0,0},{544,544}}})
  assert(not ok); has(err,'that area touches 289 chunks (17x17), over the cap of 256 a call')
  ok,err=pcall(S.read,luna,{surface='nauvis',position={x=0,y=0},radius=241}); assert(not ok); has(err,'radius is 16..240 tiles')
  local r=S.read(luna,{surface='nauvis',position={x=5,y=5},radius=240}); assert(r.chunks<=256)
  ok,err=pcall(S.read,luna,{surface='nauvis'}); assert(not ok); has(err,'sight with surface needs position or area there')
  ok,err=pcall(S.read,luna,{surface='nauvis',area={{0,0},{32,32}},radius=20}); assert(not ok); has(err,'not both')
  has(S.schema.sight.returns,'at most 256 chunks a call')
end
print('d24_batch174 QQ1 sight: cap and arguments: ok')

-- a surface with no radar of ours: a spidertron at chunk (-5,5) lights x -7..-3 of row 5
do
  for x=-7,-3 do VIS[x..',5']=true end
  local L2={radar={},roboport={},['cargo-landing-pad']={},['spider-vehicle']={thing(9,'spidertron',-144,176)}}
  local S2=dofile('mod/agent-harness_0.1.0/sight.lua'){position=function(q) return {x=q.x or q[1],y=q.y or q[2]} end,surface=function() return gleba end,census_typed=function(f,s,t) return L2[t] end}
  local r=S2.read(luna,{surface='gleba',area={{-288,160},{-32,192}}})
  eq(r.chunks,8)
  eq(r.sources[1].kind,'spidertron'); eq(r.sources[1].range,2); eq(r.visible[1].chunks,'-7,5 -6,5 -5,5 -4,5 -3,5')
  has(table.concat(r.lines,'\n'),'no radar of ours on gleba')
  eq(r.rows[1],'row y=5: uncharted -9..-8 (no radar of ours on this surface); visible -7..-3 (spidertron #9); charted -2 (no radar of ours on this surface)')
end
print('d24_batch174 QQ1 sight: spidertron sight, no radar: ok')
defines=nil
