-- Run from repository root: lua tests/tilecheck.lua
-- The tile ghost check's cost (tilecheck.lua) against a fake surface: an edge
-- of ghosts reaching into open space follows no region (shift03: the stream's
-- platforms read every 15 s stalled the game ~0.5 s), and a layout that would
-- need many regions stops at the step budget and says how many it left.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local tiles=require('tilecheck')()
local function platform(solid,ghosts)
  local gets=0
  local s={get_tile=function(x,y) gets=gets+1; return {name=solid(x,y) and 'space-platform-foundation' or 'empty-space'} end,
    find_entities_filtered=function(f)
      if f.type~='tile-ghost' then return {} end
      local out={}
      for i=1,math.min(f.limit,#ghosts) do out[i]={position={x=ghosts[i][1]+0.5,y=ghosts[i][2]+0.5},ghost_name='space-platform-foundation'} end
      return out
    end,
    -- (a tile ghost's position is its tile's centre)
    count_entities_filtered=function(f)
      if f.type~='tile-ghost' then return 0 end
      local n=0
      for _,g in ipairs(ghosts) do
        local x,y=g[1]+0.5,g[2]+0.5
        if x>=f.area[1][1] and x<=f.area[2][1] and y>=f.area[1][2] and y<=f.area[2][2] then n=n+1 end
      end
      return math.min(n,f.limit or n)
    end}
  return {surface=s,hub={valid=true,position={x=0,y=0}}},function() return gets end
end
-- 64 ghosts in a row along the east edge of a 61x201 platform: nothing held back, and few tiles read.
local ghosts={}
for y=-32,31 do ghosts[#ghosts+1]={31,y} end
local pl,gets=platform(function(x,y) return x>=-30 and x<=30 and y>=-100 and y<=100 end,ghosts)
eq(tiles.stalled(pl),nil)
assert(gets()<400,'edge ghosts read '..gets()..' tiles')
-- Gaps in a one-tile wall of foundation open to space on both sides: each
-- gap's filling might split space, so each is followed (512 tiles a side)
-- until the budget ends; the rest are named unchecked.
ghosts={}
for k=-32,31 do ghosts[#ghosts+1]={0,2*k} end
pl,gets=platform(function(x,y) return x==0 and y>=-80 and y<=80 and y%2~=0 end,ghosts)
local out=tiles.stalled(pl)
eq(#out,1)
local n=tonumber(out[1]:match('^(%d+) more tile ghosts not checked for holes'))
assert(n and n>=56 and n<64,out[1])
assert(gets()<6000,'wall gaps read '..gets()..' tiles')
-- A channel's mouth (one empty run in, one out) is still followed and named.
local channel={}
for x=-8,-2 do channel[x]=true end
pl=platform(function(x,y) return x>=-8 and x<=3 and y>=0 and y<=12 and not (y==8 and channel[x]) end,{{-8,8}})
out=tiles.stalled(pl)
assert(out and out[1]:find('tile ghost (-7.5,8.5) space-platform-foundation: building it would enclose 6 empty tiles',1,true),out and out[1])
-- Astra's Starling (shift12 12:41: 624 tile ghosts): the channel's tiles have ghosts too, read after the first 64
-- (64 ghosts elsewhere come first). No hole: those tiles are ghosted.
ghosts={{-8,8}}
for k=1,63 do ghosts[#ghosts+1]={20+k,40} end
for x=-7,-2 do ghosts[#ghosts+1]={x,8} end
pl=platform(function(x,y) return (x>=-8 and x<=3 and y>=0 and y<=12 and not (y==8 and channel[x])) or y==40 end,ghosts)
out=tiles.stalled(pl)
assert(not (out and out[1]:find('enclose',1,true)),out and out[1])
-- And one tile of them without a ghost: that one is named.
table.remove(ghosts)
pl=platform(function(x,y) return (x>=-8 and x<=3 and y>=0 and y<=12 and not (y==8 and channel[x])) or y==40 end,ghosts)
out=tiles.stalled(pl)
assert(out and out[1]:find('tile ghost (-7.5,8.5) space-platform-foundation: building it would enclose 1 empty tile with no ghost: (-1.5,8.5)',1,true),out and out[1])
print('tilecheck: ok')
