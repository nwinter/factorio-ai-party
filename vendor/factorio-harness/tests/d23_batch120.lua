-- d23 batch120. Run from the harness root: lua tests/d23_batch120.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,msg) assert(a==b,(msg or '')..' '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end

-- CC3 (Astra #2019: a floor check named 12 of 25 tiles never built) every unbuilt tile, as runs down a column, and the
-- groups they form with why: a channel x=5 between foundation at x=4 and x=6, its ends open, is never filled (each
-- tile would part the empty space north of it from the empty space south of it).
do
  game={tick=1000,surfaces={}}
  local found={}
  for y=-5,15 do found['4,'..y]=true; found['6,'..y]=true end
  found['20,20']=true
  local surface={index=7,get_tile=function(x,y) return {name=found[x..','..y] and 'space-platform-foundation' or 'empty-space'} end,
    count_tiles_filtered=function() local n=0 for _ in pairs(found) do n=n+1 end return n end}
  game.surfaces[7]=surface
  local st={}
  local F=dofile('mod/agent-harness_0.1.0/floorcheck.lua'){state=function() return st end}
  local cells={}
  for y=0,9 do cells[#cells+1]={5,y} end
  cells[#cells+1]={21,21}  -- by a corner of the lone tile at (20,20): built
  cells[#cells+1]={40,40}  -- far from any foundation
  local id=F.start(surface,cells,nil,{},'channel')
  for _=1,10 do F.tick() end
  local r=F.read(id)
  eq(r.state,'done'); eq(r.would_build,1); eq(r.never_built,11)
  eq(#r.unbuilt_tiles,2); eq(r.unbuilt_tiles[1],'(5.5,0.5..9.5)'); eq(r.unbuilt_tiles[2],'(40.5,40.5)')
  eq(#r.groups,2)
  has(r.groups[1],'10 tiles in (5.5,0.5)-(5.5,9.5): 10 building it would split the empty space beside it; the empty space on their sides is one region now and the hub never parts it in two')
  has(r.groups[2],'1 tile in (40.5,40.5)-(40.5,40.5): 1 no foundation among the 8 tiles round it')
  eq(st.floorcheck.jobs[id].all,nil,'the list goes when done')
  game=nil
end
print('d23_batch120 CC3 floor check lists every unbuilt tile: ok')
