-- Run from repository root: lua tests/d24_batch144.lua
-- d24 batch144 PP1 (Luna #2137: staging ghosts placed with place_ghosts outside construction coverage could not be
-- taken back; deconstruct {dry_run} read would_mark 0): remove_ghosts takes one's own entity ghosts (tile ghosts with
-- tiles: true) in an area or at positions, by the harness's placement record (ghostlog.lua), never a built entity.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
game={tick=5000}
local S={}
local G=dofile('mod/agent-harness_0.1.0/ghostlog.lua'){state=function() return S end,via=function() return {action='place_ghosts'} end}
local surface={name='nauvis'}
local entities={}
local unit=100
local function ghost(name,x,y,tile,lu)
  unit=unit+1
  local g={valid=true,type=tile and 'tile-ghost' or 'entity-ghost',name=tile and 'tile-ghost' or 'entity-ghost',ghost_name=name,
    position={x=x,y=y},surface=surface,unit_number=unit,last_user=lu and {name=lu} or nil}
  g.destroy=function(o) assert(o and o.raise_destroy==true,'raise_destroy'); g.valid=false; return true end
  entities[#entities+1]=g
  return g
end
local finds=0
function surface.find_entities_filtered(f)
  finds=finds+1
  local types={}
  for _,t in ipairs(type(f.type)=='table' and f.type or {f.type}) do types[t]=true end
  local names
  if f.ghost_name then names={}; for _,n in ipairs(f.ghost_name) do names[n]=true end end
  local out={}
  for _,e in ipairs(entities) do
    local q=e.position
    local inside
    if f.area then inside=q.x>=f.area[1][1] and q.x<=f.area[2][1] and q.y>=f.area[1][2] and q.y<=f.area[2][2]
    else inside=((q.x-f.position.x)^2+(q.y-f.position.y)^2)^0.5<=f.radius end
    if e.valid and types[e.type] and inside and (not names or names[e.ghost_name]) then out[#out+1]=e end
    if f.limit and #out>=f.limit then break end
  end
  return out
end
-- Luna's staging ghosts, Sol's, one the record does not know, a built belt (no ghost), a tile ghost, one off the chart
local mine={}
for i=1,4 do mine[i]=ghost('transport-belt',i+0.5,0.5); G.placed('Luna',mine[i]) end
local inserter=ghost('inserter',5.5,1.5); G.placed('Luna',inserter)
local sols=ghost('transport-belt',6.5,0.5); G.placed('Sol',sols)
local unknown=ghost('transport-belt',7.5,0.5)
local player_ghost=ghost('small-electric-pole',8.5,1.5,false,'Luna')
entities[#entities+1]={valid=true,type='transport-belt',name='transport-belt',position={x=9.5,y=0.5},surface=surface}
local tile=ghost('landfill',3.5,2.5,true); G.placed('Luna',tile)
local far=ghost('transport-belt',100.5,0.5); G.placed('Luna',far)
-- the tile ghost's record is in the tile ring
eq(G.owner(tile),'Luna'); eq(select(2,G.owner(tile)),'record'); eq(S.ghost_log.tmap['nauvis|landfill|3.5,2.5'].a,'Luna')
eq(G.owner(player_ghost),'Luna'); eq(select(2,G.owner(player_ghost)),'last_user'); eq(G.owner(unknown),nil)
local R=dofile('mod/agent-harness_0.1.0/removeghosts.lua'){position=function(v) return {x=v.x or v[1],y=v.y or v[2]} end,
  charted=function(p,pos) return pos.x<64 or pos.y>=20 end,who=function(p) return p.name end,owner_at=G.owner_at,placed_by=G.short,forget=G.forget}
local luna={name='Luna',surface=surface,force='player'}
-- a record from before the position index (no s, n): read into it on the first lookup
local legacy=ghost('pipe',11.5,3.5)
S.ghost_log.map['nauvis|pipe|11.5,3.5']={a='Luna',t=1,i=8000}
eq(S.ghost_log.pidx,nil,'no index before the first lookup')
-- the index matches the records: each position's count is the records there
local function consistent()
  local want={}
  local function k(sn,n) return sn..'/'..string.format('%.0f',n) end
  for _,map in ipairs({S.ghost_log.map,S.ghost_log.tmap}) do for _,r in pairs(map) do if r.n then want[k(r.s,r.n)]=(want[k(r.s,r.n)] or 0)+1 end end end
  for sn,t in pairs(S.ghost_log.pidx) do for nk,c in pairs(t) do eq(c,want[k(sn,nk)],'index count at '..k(sn,nk)); want[k(sn,nk)]=nil end end
  assert(next(want)==nil,'a record missing from the index')
end
-- refusals
fails(function() R.handler(luna,{}) end,'remove_ghosts takes area or positions (one of them)')
fails(function() R.handler(luna,{area={{0,0},{10,10}},positions={{1,1}}}) end,'one of them')
fails(function() R.handler(luna,{area={{0,0},{300,10}}}) end,'at most 256 tiles a side')
fails(function() R.handler(luna,{area={{0,0},{10,10}},dry_run='yes'}) end,'dry_run must be true or false')
fails(function() R.handler(luna,{area={{0,0},{10,10}},owner=''}) end,'owner: "any"')
fails(function() R.handler(luna,{area={{0,0},{10,10}},names={}}) end,'names: 1..32')
-- dry run: Luna's own entity ghosts, the rest left with why; nothing removed
local r=R.handler(luna,{area={{0,0},{200,10}},dry_run=true})
eq(r.would_remove,7); eq(r.removed,nil); eq(r.dry_run,true); eq(r.found,10); eq(r.left,3)
assert(S.ghost_log.pidx and S.ghost_log.map['nauvis|pipe|11.5,3.5'].n,'the legacy record read into the index'); consistent()
eq(r.left_others.Sol,1); eq(r.left_unknown,1); eq(r.left_uncharted,1)
eq(r.by_name,'4 transport-belt, 1 inserter, 1 pipe, 1 small-electric-pole'); eq(#r.ghosts,7); eq(r.ghosts[1].owner,'Luna')
has(r.ghosts[1].placed,'ghost by Luna'); for _,row in ipairs(r.ghosts) do if row.name=='small-electric-pole' then eq(row.placed,nil,'a last user is not a record'); eq(row.owner,'Luna') end end
has(r.line,'would remove 7 entity ghosts of yours in the area (0,0)-(200,10) on nauvis: 4 transport-belt, 1 inserter, 1 pipe, 1 small-electric-pole; left 3:')
has(r.line,'1 placed by others (1 Sol; owner: "any" or the agent\'s name takes them)'); has(r.line,'1 with no placement record'); has(r.line,'1 in chunks our force has not charted')
for _,g in ipairs(entities) do assert(g.valid,'a dry run removes nothing') end
-- names and positions: the inserter alone
r=R.handler(luna,{positions={{5.5,1.5},{x=1.5,y=0.5}},names='inserter',dry_run=true})
eq(r.would_remove,1); eq(r.by_name,'1 inserter'); has(r.line,'at 2 positions on nauvis')
-- live: Luna's taken, records forgotten, the built belt and the tile ghost stay
r=R.handler(luna,{area={{0,0},{20,10}}})
eq(r.removed,7); eq(r.left,2); assert(not mine[1].valid and not inserter.valid and not player_ghost.valid and not legacy.valid); consistent()
assert(sols.valid and unknown.valid and tile.valid,'others, unknown and tiles stay'); assert(entities[9].valid,'built belt stays')
eq(S.ghost_log.map['nauvis|transport-belt|1.5,0.5'],nil,'its record forgotten')
has(r.line,'removed 7 entity ghosts of yours')
-- tiles: true takes her tile ghost
r=R.handler(luna,{area={{0,0},{20,10}},tiles=true})
eq(r.removed,1); eq(r.ghosts[1].tile,true); assert(not tile.valid); has(r.line,'removed 1 ghost of yours')
-- another agent's by name, then any: listed by owner
r=R.handler(luna,{area={{0,0},{20,10}},owner='Sol',dry_run=true}); eq(r.would_remove,1); eq(r.left_unknown,1); has(r.line,'placed by Sol')
r=R.handler(luna,{area={{0,0},{20,10}},owner='any'}); eq(r.removed,2); eq(r.by_owner,'1 Sol, 1 unknown'); assert(not sols.valid and not unknown.valid)
-- the cap: 256 a call, the rest left over_cap
for i=1,300 do G.placed('Luna',ghost('stone-wall',i%200+0.5,20.5+math.floor(i/200))) end
r=R.handler(luna,{area={{0,20},{256,23}},names={'stone-wall'}})
eq(r.found,300); eq(r.removed,256); eq(r.left_over_cap,44); eq(#r.ghosts,64); eq(r.more,192); has(r.line,'past the 256 a call takes (call it again)')
consistent()
-- the ring: past 8192 placements the oldest records go, from the index too
for i=1,8300 do G.placed('Luna',ghost('stone-wall',i%250+0.5,40.5+math.floor(i/250))) end
consistent()
local n=0 for _ in pairs(S.ghost_log.map) do n=n+1 end
eq(n,8192,'the ring keeps 8192')
print('d24_batch144: ok')
