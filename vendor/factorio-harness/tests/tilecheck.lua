-- Run from repository root: lua tests/tilecheck.lua
-- A platform's foundation tiles that wait (tilecheck.lua), by the rules the game showed on a copy of world n
-- (platformtiles2; Astra, shift14 21:55: a marked tile at (-2,8) on Sunward stayed, three ghosts in a hole beside it
-- were never built): removals and builds played out one tile at a time, each by its 8 neighbours; and the check's
-- cost (shift03: the stream's platforms read every 15 s stalled the game ~0.5 s).
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,part) assert(type(s)=='string' and s:find(part,1,true),tostring(s)..' lacks '..part) end
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
defines={inventory={hub_main=1}}
local tiles=require('tilecheck')()
-- A fake platform: solid(x,y) the foundation, ghosts {x,y} tile ghosts, marks {x,y} marked tiles, ents entities
-- standing (each {x,y,name}), room what the hub takes.
local function platform(solid,ghosts,opts)
  opts=opts or {}
  local gets=0
  local function tile(x,y)
    gets=gets+1
    return {name=solid(x,y) and 'space-platform-foundation' or 'empty-space',
      prototype={mineable_properties={products={{name='space-platform-foundation'}}}}}
  end
  local s={get_tile=tile,
    find_entities_filtered=function(f)
      local out={}
      if f.type=='tile-ghost' then
        for i=1,math.min(f.limit or #ghosts,#ghosts) do out[i]={position={x=ghosts[i][1]+0.5,y=ghosts[i][2]+0.5},ghost_name='space-platform-foundation'} end
      elseif f.type=='deconstructible-tile-proxy' then
        for _,m in ipairs(opts.marks or {}) do
          local x,y=m[1]+0.5,m[2]+0.5
          if not f.area or (x>=f.area[1][1] and x<=f.area[2][1] and y>=f.area[1][2] and y<=f.area[2][2]) then out[#out+1]={position={x=x,y=y}} end
          if f.limit and #out>=f.limit then break end
        end
      elseif f.type=='thruster' then
      elseif f.area then
        for _,e in ipairs(opts.ents or {}) do
          if e[1]+0.5>=f.area[1][1] and e[1]+0.5<=f.area[2][1] and e[2]+0.5>=f.area[1][2] and e[2]+0.5<=f.area[2][2] then
            out[#out+1]={valid=true,name=e[3],type='inserter',position={x=e[1]+0.5,y=e[2]+0.5}}
          end
        end
      end
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
  local hub={valid=true,position={x=0,y=0},get_inventory=function() return {get_insertable_count=function() return opts.room or 1000 end} end}
  return {surface=s,hub=hub},function() return gets end
end
-- A block of foundation x -10..10, y -10..10 with holes (a set of "x,y").
local function block(holes)
  return function(x,y) return x>=-10 and x<=10 and y>=-10 and y<=10 and not holes[x..','..y] end
end
local function set(list) local t={} for _,c in ipairs(list) do t[c[1]..','..c[2]]=true end return t end
local function plan(holes,marks,opts)
  opts=opts or {}; opts.marks=marks
  local pl=platform(block(holes),{},opts)
  return tiles.plan_removals(pl.surface,marks,pl.hub,{}),pl
end

-- 1. Removals. An interior tile (its four sides foundation) waits; an edge tile goes.
local p=plan({},{{0,0}})
eq(#p.go,0); eq(#p.waiting,1)
eq(p.waiting[1][3],'none of its four side neighbours (north, east, south, west) is empty space: the hub removes a foundation tile only beside empty space')
p=plan({},{{10,0}})
eq(#p.go,1); eq(#p.waiting,0)
-- A chain from the edge in: each goes once the one before it has (on the copy: (-4,10) to (-2,8) in about 2 s).
p=plan({},{{8,0},{9,0},{7,0},{10,0}})
eq(#p.go,4); eq(p.go[1][1],10); eq(p.go[4][1],7)
local lines=tiles.removal_lines(p,'marked','on the platform')
eq(lines.go,'4 marked tiles on the platform go, one at a time, each once a side neighbour is empty space, in this order: (10.5,0.5), (9.5,0.5), (8.5,0.5), (7.5,0.5)')
-- The same chain without its edge tile: all wait, the inner ones naming the marked tile beside them.
p=plan({},{{8,0},{9,0},{7,0}})
eq(#p.go,0); eq(#p.waiting,3)
has(p.waiting[1][3],'; the marked tile beside it at (9.5,0.5) waits too')
-- A corner only (diagonal) is not enough.
p=plan(set({{1,1}}),{{0,0}})
eq(#p.go,0); has(p.waiting[1][3],'none of its four side neighbours')
-- Between two holes that do not meet round it: it would join them, and waits.
p=plan(set({{-1,0},{1,0}}),{{0,0}})
eq(#p.go,0); eq(p.waiting[1][3],'its empty side neighbours (1.5,0.5) and (-0.5,0.5) do not meet through the tiles round it: removing it would join separate empty space, which the hub does not do')
-- An L: north and east empty with the corner between them foundation waits; with the corner empty it goes.
p=plan(set({{0,-1},{1,0}}),{{0,0}}); eq(#p.go,0)
p=plan(set({{0,-1},{1,0},{1,-1}}),{{0,0}}); eq(#p.go,1)
-- A C-shaped hole whose ends are its east and west neighbours: they meet far round, not round it: waits (the copy's
-- (26,-7)).
local c=set({{-1,0},{-2,0},{-2,-1},{-2,-2},{-1,-2},{0,-2},{1,-2},{2,-2},{2,-1},{2,0},{1,0}})
p=plan(c,{{0,0}}); eq(#p.go,0); has(p.waiting[1][3],'do not meet through the tiles round it')
-- Whether the foundation stays joined is not looked at: the tile holding a peninsula on goes (the copy's (-4,15)).
p=plan(set({{9,1},{9,-1}}),{{9,0}}); eq(#p.go,0)
p=plan(set({{9,1}}),{{9,0}}); eq(#p.go,1)
-- Two in a row between two holes: one goes, then the other would join them.
p=plan(set({{-2,0},{1,0}}),{{-1,0},{0,0}})
eq(#p.go,1); eq(#p.waiting,1); has(p.waiting[1][3],'would join separate empty space')
-- The hub's room: what it takes, in turn; the rest wait for room.
p=plan({},{{10,0},{10,1}},{room=1})
eq(#p.go,1); eq(p.waiting[1][3],'the hub has no room for space-platform-foundation')
-- Something standing on it.
p=plan({},{{10,0}},{ents={{10,0,'fast-inserter'}}})
eq(#p.go,0); eq(p.waiting[1][3],'fast-inserter (10.5,0.5) stands on it')
-- The platform read: marked, go, waiting.
local pl=platform(block({}),{},{marks={{0,0},{10,0}}})
local r=tiles.removals(pl)
eq(r.marked,'2'); has(r.go,'1 marked tile goes, one at a time'); has(r.waiting[1],'(0.5,0.5): none of its four side neighbours')
-- inspect's note for a marked tile.
eq(tiles.note(pl,{type='deconstructible-tile-proxy',position={x=10.5,y=0.5}}),'marked for removal: nothing holds it; the hub removes it next')
has(tiles.note(pl,{type='deconstructible-tile-proxy',position={x=0.5,y=0.5}}),'marked for removal: waits: none of its four side neighbours')

-- 2. Builds. Astra's pocket: a ghost column x=-3, y 12..14 in a hole with (-3,10), (-3,11), (-4,11) bare above it,
-- open to space at (-2,14): each ghost splits the empty space round it, and the bare tiles are named.
local function pocket(x,y)
  if x==-3 and y>=10 and y<=14 then return false end
  if x==-4 and y==11 then return false end
  if x>=-2 and x<=1 and y>=14 then return false end
  return x>=-10 and x<=6 and y>=0 and y<=20
end
local g={{-3,12},{-3,13},{-3,14}}
pl=platform(pocket,g)
local out=tiles.stalled(pl)
eq(#out,3)
eq(out[2],'tile ghost (-2.5,13.5) space-platform-foundation: building it would split the empty space beside it: (-2.5,12.5) and (-2.5,14.5) meet only through it (the hub builds no foundation that splits empty space, even when each side stays open); on one side a hole of 3 empty tiles with no ghost: (-2.5,11.5), (-3.5,11.5), (-2.5,10.5)')
-- The whole pocket ghosted: built from the far end in, none stays (on the copy: all six within about 8 s).
pl=platform(pocket,{{-3,12},{-3,13},{-3,14},{-3,10},{-3,11},{-4,11}})
eq(tiles.stalled(pl),nil)
-- A channel open to space at both ends: a ghost in its middle splits it, though both sides stay open (the copy's
-- (30,-7)).
local function channel(x,y) return x>=-10 and x<=10 and y>=-10 and y<=10 and not (x==0) end
pl=platform(channel,{{0,0}})
out=tiles.stalled(pl)
eq(out[1],'tile ghost (0.5,0.5) space-platform-foundation: building it would split the empty space beside it: (0.5,-0.5) and (0.5,1.5) meet only through it (the hub builds no foundation that splits empty space, even when each side stays open)')
-- An enclosed one-tile hole fills; a ghost with foundation only at a corner is built.
pl=platform(block(set({{0,0}})),{{0,0}}); eq(tiles.stalled(pl),nil)
pl=platform(function(x,y) return x<=0 and y<=0 end,{{1,1}}); eq(tiles.stalled(pl),nil)
-- With no foundation round it, nor a ghost: named.
pl=platform(block({}),{{30,30}})
eq(tiles.stalled(pl)[1],'tile ghost (30.5,30.5) space-platform-foundation: no foundation among the 8 tiles round it')
eq(tiles.note(pl,{type='tile-ghost',position={x=30.5,y=30.5}}),'waits: tile ghost (30.5,30.5) space-platform-foundation: no foundation among the 8 tiles round it')

-- 3. The check's cost. 64 ghosts in a row along the east edge of a 61x201 platform: nothing held back, few tiles read.
local ghosts={}
for y=-32,31 do ghosts[#ghosts+1]={31,y} end
local gets
pl,gets=platform(function(x,y) return x>=-30 and x<=30 and y>=-100 and y<=100 end,ghosts)
eq(tiles.stalled(pl),nil)
assert(gets()<400,'edge ghosts read '..gets()..' tiles')
-- Gaps in a one-tile wall of foundation open to space on both sides: each gap splits space; its sides are followed
-- (512 tiles each) until the budget ends; the rest are counted, not checked.
ghosts={}
for k=-32,31 do ghosts[#ghosts+1]={0,2*k} end
pl,gets=platform(function(x,y) return x==0 and y>=-80 and y<=80 and y%2~=0 end,ghosts)
out=tiles.stalled(pl)
local n=tonumber(out[#out]:match('^(%d+) more tile ghosts not checked'))
assert(n and n>=56 and n<64,out[#out])
has(out[1],'building it would split the empty space beside it')
assert(gets()<6000,'wall gaps read '..gets()..' tiles')
-- A channel's mouth (one empty run in, one out) is followed and named, with the channel as a hole.
local ch={}
for x=-8,-2 do ch[x]=true end
local function chan(x,y) return x>=-8 and x<=3 and y>=0 and y<=12 and not (y==8 and ch[x]) end
pl=platform(chan,{{-8,8}})
out=tiles.stalled(pl)
has(out[1],'tile ghost (-7.5,8.5) space-platform-foundation: building it would split the empty space beside it')
has(out[1],'on one side a hole of 6 empty tiles with no ghost: (-6.5,8.5), (-5.5,8.5), (-4.5,8.5), (-3.5,8.5), ...')
-- Astra's Starling (shift12 12:41: 624 tile ghosts): the channel's tiles have ghosts too, read after the first 64
-- (64 ghosts elsewhere come first). It waits for them, not named.
ghosts={{-8,8}}
for k=1,63 do ghosts[#ghosts+1]={20+k,40} end
for x=-7,-2 do ghosts[#ghosts+1]={x,8} end
local function chan2(x,y) return chan(x,y) or y==40 end
pl=platform(chan2,ghosts)
out=tiles.stalled(pl)
assert(not (out and out[1]:find('-7.5,8.5',1,true)),out and out[1])
-- And one tile of them without a ghost: that one is named.
table.remove(ghosts)
pl=platform(chan2,ghosts)
out=tiles.stalled(pl)
has(out[1],'tile ghost (-7.5,8.5) space-platform-foundation: building it would split the empty space beside it')
has(out[1],'on one side a hole of 1 empty tile with no ghost: (-1.5,8.5)')
-- batch24 B3 (Astra: tiles deconstruct only beside empty space, learned by trial): platform_tiles at exact tiles.
do
  local q=platform(block(set({{3,3}})),{{12,0}},{marks={{10,0},{0,0}},ents={{5,5,'inserter'}}})
  q.name='Kestrel II'
  local r=tiles.query(q,{{0,0},{10,0},{5,5},{3,4},{12,0},{30,30},{11,0}})
  eq(r.lines[1],'(0.5,0.5): space-platform-foundation; marked for removal; not removable now: none of its four side neighbours (north, east, south, west) is empty space: the hub removes a foundation tile only beside empty space')
  eq(r.tiles[1].remove.now,false); eq(r.tiles[1].marked,true)
  eq(r.lines[2],'(10.5,0.5): space-platform-foundation; marked for removal; removable now'); eq(r.tiles[2].remove.now,true)
  eq(r.lines[3],'(5.5,5.5): space-platform-foundation; under inserter (5.5,5.5); not removable now: inserter (5.5,5.5) stands on it')
  -- next to the hole at (3,3): its one empty side neighbour
  eq(r.tiles[4].remove.now,true)
  eq(r.lines[5],'(12.5,0.5): empty space; ghost of space-platform-foundation; foundation not built here now: no foundation among the 8 tiles round it')
  eq(r.tiles[6].build.now,false)
  eq(r.lines[7],'(11.5,0.5): empty space; foundation can be built here now'); eq(r.tiles[7].build.now,true)
  -- the hole at (3,3): foundation builds there (an enclosed one-tile hole fills)
  eq(tiles.query(q,{{3,3}}).tiles[1].build.now,true)
  -- the hub full: not removable
  local full=platform(block({}),{},{room=0}); full.name='x'
  eq(tiles.query(full,{{10,0}}).tiles[1].remove.why,'the hub has no room for space-platform-foundation')
end
print('tilecheck: ok')
