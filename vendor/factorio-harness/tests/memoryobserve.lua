-- Run from repository root: lua tests/memoryobserve.lua [MODDIR]
-- What the census's observe hook stores (readmemory.observe, beltgaps.observe; d16 perf: each engine field read once,
-- observe's fresh tables stored without copies): the summary entry, the belt row and its tiles, as before the change
-- (MODDIR runs the same checks on another copy of the modules); no table stored in two places (a bounding box the
-- engine made for this read may be kept as it is: nothing else holds it); the ring of 2048 summaries.
local DIR=arg[1] or 'mod/agent-harness_0.1.0'
package.path=DIR..'/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function same(a,b,path)
  path=path or 'value'
  if type(a)~='table' or type(b)~='table' then eq(a,b,path) return end
  for k,v in pairs(a) do same(v,b[k],path..'.'..tostring(k)) end
  for k in pairs(b) do assert(a[k]~=nil,path..'.'..tostring(k)..' missing') end
end
storage={}
game={tick=500}
local reads={}
local function count(k) reads[k]=(reads[k] or 0)+1 end
local force={name='player'}
local surface={name='nauvis',index=1}
force.is_chunk_visible=function(s,c) return not (c.x==3 and c.y==3) end  -- the chest's chunk is out of sight
local function fresh(t) return t end
-- A fake LuaEntity: each field read counted; position and bounding_box are new tables at every read, as in the game.
local function entity(fields)
  return setmetatable({},{__index=function(_,k)
    count(k)
    if k=='position' then return fresh({x=fields.x,y=fields.y}) end
    if k=='bounding_box' then
      return fresh({left_top=fresh({x=fields.x-0.5,y=fields.y-0.5}),right_bottom=fresh({x=fields.x+0.5,y=fields.y+0.5})})
    end
    if k=='force' then return force end
    if k=='surface' then return surface end
    if k=='valid' then return true end
    if k=='get_item_count' then return function() return fields.items or 0 end end
    if k=='last_user' then return fields.user and {name=fields.user} or nil end
    return fields[k]
  end})
end
local state=function() return storage end
local bg=dofile(DIR..'/beltgaps.lua'){state=state,position=function(p) return p end}
local status={[1]='working',[2]='no_power'}
local rm=dofile(DIR..'/readmemory.lua'){state=state,position=function(p) return p end,status_name=function(e) return status[e.status] end,
  visible=function(p,pos) return p.force.is_chunk_visible(p.surface,{x=math.floor(pos.x/32),y=math.floor(pos.y/32)}) end,
  belt_observe=function(e,p) return bg.observe(e,p) end}

-- An assembler and a belt in sight, a chest out of sight, a character and ore (never stored).
rm.observe(entity{type='assembling-machine',name='assembling-machine-2',x=10.5,y=12.5,unit_number=7,direction=4,status=1})
rm.observe(entity{type='transport-belt',name='transport-belt',x=40.5,y=3.5,unit_number=8,direction=2,status=1,items=3,user='Sol'})
rm.observe(entity{type='container',name='iron-chest',x=100.5,y=100.5,unit_number=9,direction=0})
rm.observe(entity{type='character',name='character',x=1.5,y=1.5})
rm.observe(entity{type='resource',name='iron-ore',x=2.5,y=2.5})
local m=storage.read_memory
local entries={}
for k,v in pairs(m.entries) do entries[#entries+1]=k end
table.sort(entries)
same(entries,{'player|nauvis|10.5,12.5|summary','player|nauvis|40.5,3.5|summary'},'summary keys')
same(m.entries['player|nauvis|10.5,12.5|summary'],{force='player',surface='nauvis',position={x=10.5,y=12.5},kind='summary',
  value={name='assembling-machine-2',type='assembling-machine',position={x=10.5,y=12.5},unit_number=7,direction=4,
    status_name='working',detail='last observed entity summary'},
  box={left_top={x=10,y=12},right_bottom={x=11,y=13}},tick=500},'assembler summary')
same(m.entries['player|nauvis|40.5,3.5|summary'].value,{name='transport-belt',type='transport-belt',position={x=40.5,y=3.5},
  unit_number=8,direction=2,status_name='working',detail='last observed entity summary'},'belt summary')
same(m.slots,{'player|nauvis|10.5,12.5|summary','player|nauvis|40.5,3.5|summary'},'ring slots')
eq(m.next,3,'ring cursor')
-- The belt memory: its chunk, its row on its tile.
local b=storage.belt_memory
same(b.order,{'player|nauvis|1,0'},'belt chunks')
same(b.chunks['player|nauvis|1,0'],{force='player',surface='nauvis',x=1,y=0,tiles={['40,3']={name='transport-belt',
  position={x=40.5,y=3.5},direction=2,type='transport-belt',tick=500,by='Sol',carried_tick=500,items=3}}},'belt chunk')
-- No table is stored in two places.
local seen={}
local function walk(t,path)
  assert(not seen[t],path..' is stored twice'); seen[t]=true
  for k,v in pairs(t) do if type(v)=='table' then walk(v,path..'.'..tostring(k)) end end
end
walk(m.entries,'entries')
walk(b.chunks,'chunks')

-- The ring: 2048 summaries; the 2049th evicts the first.
for i=1,2048 do rm.observe(entity{type='inserter',name='inserter',x=(i%60)+0.25,y=math.floor(i/60)+0.25,unit_number=100+i,direction=0}) end
assert(m.entries['player|nauvis|10.5,12.5|summary']==nil and m.entries['player|nauvis|40.5,3.5|summary']==nil,'first two evicted')
local n=0 for _ in pairs(m.entries) do n=n+1 end
eq(n,2048,'ring size')
-- Engine reads: one position and one bounding box per summary (the new code); the old read them 3 and 2 times.
if not arg[1] then
  reads={}
  rm.observe(entity{type='assembling-machine',name='assembling-machine-2',x=11.5,y=12.5,unit_number=70,direction=4,status=1})
  eq(reads.position,1,'position reads'); eq(reads.bounding_box,1,'bounding box reads'); eq(reads.type,2,'type reads (readmemory, beltgaps.observe)')
  reads={}
  rm.observe(entity{type='transport-belt',name='transport-belt',x=41.5,y=3.5,unit_number=80,direction=2,status=1,items=0})
  eq(reads.position,3,'belt: one position each in readmemory, beltgaps.observe and remember')
  eq(reads.last_user,1,'last_user reads')
end
print('memory observe: ok')
