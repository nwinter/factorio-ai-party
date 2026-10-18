-- d17 batch33. Run from the harness root: lua tests/d17_batch33.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,msg) assert(a==b,(msg or '')..' '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end

-- A1 (Sol: Wayfarer's 3318 tile ghosts; the one-tick check stopped at 4096 steps and the dry run read the rest as 107
-- unbuildable): the play stops undecided, never unbuilt; a check across ticks finishes it.
do
  game={tick=1000,surfaces={}}
  local found={}
  for x=0,9 do found[x..','..0]=true end
  local surface={index=7,get_tile=function(x,y) return {name=found[x..','..y] and 'space-platform-foundation' or 'empty-space'} end}
  game.surfaces[7]=surface
  local TC=dofile('mod/agent-harness_0.1.0/tilecheck.lua')()
  local tiles={}
  for y=1,20 do for x=0,9 do tiles[#tiles+1]={x,y,'space-platform-foundation'} end end
  tiles[#tiles+1]={40,40,'space-platform-foundation'}  -- far from any foundation
  -- in one go: every fill tile built, the far one not
  local play=TC.play(surface,tiles,nil,{},{},100000)
  local n=0 for _ in pairs(play.built) do n=n+1 end
  eq(n,200); eq(play.left,0); eq(play.rule({40,40}),'no foundation among the 8 tiles round it')
  -- each tile once on the work list: checks stay near the tile count
  assert(play.steps<=2*#tiles,play.steps)
  -- stopped early: the rest is unchecked, not unbuilt
  play=TC.play(surface,tiles,nil,{},{},50)
  assert(play.left>0); local u=0 for _ in pairs(play.unchecked) do u=u+1 end; eq(u,play.left)
  -- across ticks
  local st={}
  local F=dofile('mod/agent-harness_0.1.0/floorcheck.lua'){state=function() return st end}
  local cells={}
  for i,t in ipairs(tiles) do cells[i]={t[1],t[2]} end
  local id=F.start(surface,cells,nil,{},'test fill')
  local r=F.read(id)
  eq(r.state,'running'); has(r.line,'floor check #1 (test fill): 201 tiles, running: 0 rule checks so far (150 a tick), 201 tiles still queued')
  for _=1,20 do F.tick() end
  r=F.read(id)
  eq(r.state,'done'); eq(r.built,200); eq(r.unbuilt_count,1)
  eq(r.unbuilt[1],'(40.5,40.5): no foundation among the 8 tiles round it')
  has(r.line,'201 tiles checked by the hub\'s rules'); has(r.line,'200 built in turn, 1 never built (1 no foundation among the 8 tiles round it)')
  eq(st.floorcheck.jobs[id].ghosts,nil,'the large tables go when done')
  fails(function() F.read(99) end,'no floor check #99 (kept: 1)')
  game=nil
end
print('d17_batch33 A1 floor check across ticks: ok')
