-- Run from repository root: lua tests/pipegaps.lua
-- pipe_gaps (pipegaps.lua; Muse, shift17 10:50: 15 minutes to find a cut crude line by hand): along a tile line, the
-- segments of joined fluid entities with their fluid, the cuts (neighbours that do not join; the line stopping at a
-- tile with nothing), empty runs, a pipe-to-ground pair covering the tiles between, ghosts, and unseen tiles.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
game={tick=500}
local at={}
local function pipe(x,y,name,typ,seg,fluid)
  local e={valid=true,name=name or 'pipe',type=typ or 'pipe',position={x=x+0.5,y=y+0.5},conns={},
    bounding_box={left_top={x=x+0.1,y=y+0.1},right_bottom={x=x+0.9,y=y+0.9}},
    fluidbox=setmetatable({get_fluid_segment_id=function() return seg end,get_fluid_segment_contents=function() return fluid and {[fluid]=1000} or {} end},
      {__len=function() return 1 end})}
  at[x..','..y]=e
  return e
end
local function join(a,b,kind) a.conns[#a.conns+1]={kind=kind or 'normal',target=b}; b.conns[#b.conns+1]={kind=kind or 'normal',target=a} end
-- x 0..3: crude pipes joined (segment 7); x 4 a pipe not joined to x 3 (the cut), x 4..5 segment 9; x 6..8 nothing;
-- x 9 pipe-to-ground paired with x 12 (10,11 under ground) and on to x 13; x 14 a ghost; x 15..16 unseen.
local p0,p1,p2,p3=pipe(0,0,nil,nil,7,'crude-oil'),pipe(1,0,nil,nil,7,'crude-oil'),pipe(2,0,nil,nil,7,'crude-oil'),pipe(3,0,nil,nil,7,'crude-oil')
join(p0,p1); join(p1,p2); join(p2,p3)
local p4,p5=pipe(4,0,nil,nil,9,'crude-oil'),pipe(5,0,nil,nil,9,'crude-oil'); join(p4,p5)
local u9,u12=pipe(9,0,'pipe-to-ground','pipe-to-ground',11,'water'),pipe(12,0,'pipe-to-ground','pipe-to-ground',11,'water')
join(u9,u12,'underground')
local p13=pipe(13,0,nil,nil,11,'water'); join(u12,p13)
local g14={valid=true,type='entity-ghost',ghost_name='pipe',position={x=14.5,y=0.5},ghost_prototype={fluidbox_prototypes={{}}},
  bounding_box={left_top={x=14.1,y=0.1},right_bottom={x=14.9,y=0.9}}}
-- an unseen pipe at x 15 (its chunk is not visible): never used
pipe(15,0,nil,nil,13,'water')
local queries=0
local surface={name='nauvis',find_entities_filtered=function(f)
  queries=queries+1
  local out={g14}
  for _,e in pairs(at) do
    local b=e.bounding_box
    if b.left_top.x>=f.area[1][1]-1 and b.right_bottom.x<=f.area[2][1]+1 and b.left_top.y>=f.area[1][2]-1 and b.right_bottom.y<=f.area[2][2]+1 then out[#out+1]=e end
  end
  return out end}
local p={force={name='player'},surface=surface}
local G=dofile('mod/agent-harness_0.1.0/pipegaps.lua'){position=function(v) return {x=v.x,y=v.y} end,
  connections=function(e) return e.conns end,segment_box=function(e) return e.fluidbox.get_fluid_segment_id()==7 and {0,0,3,0} or nil end,
  visible=function(_,pos) return pos.x<15 end}
local r=G.read(p,{from={x=0.5,y=0.5},to={x=16.5,y=0.5}})
eq(r.tiles,17); eq(#r.segments,3); eq(queries,1,'one area query for the straight leg')
eq(r.segments[1].from,'(0.5,0.5)'); eq(r.segments[1].to,'(3.5,0.5)'); eq(r.segments[1].fluid,'crude-oil'); eq(r.segments[1].segment_id,7); eq(r.segments[1].extent,'(0,0)-(3,0)')
eq(r.segments[2].from,'(4.5,0.5)'); eq(r.segments[2].to,'(5.5,0.5)'); eq(r.segments[2].segment_id,9)
eq(r.segments[3].from,'(9.5,0.5)'); eq(r.segments[3].to,'(13.5,0.5)'); eq(r.segments[3].underground,2); eq(r.segments[3].fluid,'water')
eq(#r.cuts,3)
eq(r.cuts[1].line,'pipe (3.5,0.5) and pipe (4.5,0.5) do not join'); eq(r.cuts[1].between[2],'(4.5,0.5)')
eq(r.cuts[2].line,'pipe (5.5,0.5): nothing of ours with a fluidbox at (6.5,0.5)')
eq(r.cuts[3].line,'pipe (13.5,0.5): a ghost of pipe at (14.5,0.5), not built yet')
eq(#r.empty,1); eq(r.empty[1].from,'(6.5,0.5)'); eq(r.empty[1].to,'(8.5,0.5)'); eq(r.empty[1].tiles,3)
eq(#r.ghosts,1); eq(r.ghosts[1].position,'(14.5,0.5)')
eq(#r.unknown,1); eq(r.unknown[1].from,'(15.5,0.5)'); eq(r.unknown[1].tiles,2)
eq(r.line,'17 tiles: 3 segments ((0.5,0.5)..(3.5,0.5) crude-oil 1000; (4.5,0.5)..(5.5,0.5) crude-oil 1000; (9.5,0.5)..(13.5,0.5) water 1000); 3 cuts; 1 empty run; 1 ghost; 1 unknown run')
-- (d18 batch39 D1, finished in d19 batch41 D3) with pipe_fluid, each cut names each side's fluid
do
  local G2=dofile('mod/agent-harness_0.1.0/pipegaps.lua'){position=function(v) return {x=v.x,y=v.y} end,
    connections=function(e) return e.conns end,segment_box=function(e) return e.fluidbox.get_fluid_segment_id()==7 and {0,0,3,0} or nil end,
    visible=function(_,pos) return pos.x<15 end,pipe_fluid=function(e) return e.position.x<4 and 'crude-oil' or 'heavy-oil' end}
  local r2=G2.read(p,{from={x=0.5,y=0.5},to={x=16.5,y=0.5}})
  eq(r2.cuts[1].line,'pipe (3.5,0.5) (crude-oil) and pipe (4.5,0.5) (heavy-oil) do not join'); eq(r2.cuts[1].fluids[2],'heavy-oil')
  eq(r2.cuts[2].line,'pipe (5.5,0.5) (heavy-oil): nothing of ours with a fluidbox at (6.5,0.5)')
end
fails(function() G.read(p,{from={x=0,y=0},to={x=3,y=3}}) end,'horizontal or vertical')
fails(function() G.read(p,{from={x=0,y=0},to={x=600,y=0}}) end,'512 tiles')
print('pipegaps: ok')
