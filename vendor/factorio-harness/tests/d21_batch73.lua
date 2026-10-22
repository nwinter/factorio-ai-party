-- Run from repository root: lua tests/d21_batch73.lua
-- d21 batch73 AI (census.step 7.2 ms a tick on world n): numtext's text is the text .. gives; the census's sighting
-- (readmemory.observe_seen) writes the fog and belt memory as observe() does, with no summary in the ring, a chunk out
-- of sight skipped and asked once a step; a belt seen again as it was keeps its row, brought up to date; the census pass
-- is paced by work (WORK entities read a tick, a band's find charged), its bands one chunk each.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local DIR='mod/agent-harness_0.1.0'
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function same(a,b,path)
  path=path or 'value'
  if type(a)~='table' or type(b)~='table' then eq(a,b,path) return end
  for k,v in pairs(a) do same(v,b[k],path..'.'..tostring(k)) end
  for k in pairs(b) do assert(a[k]~=nil,path..'.'..tostring(k)..' missing') end
end

-- numtext: integers and halves by string.format, the rest (0.25, -0) as before
local nt=dofile(DIR..'/numtext.lua')
for _,x in ipairs({0,1,-1,31,-32,1000000,-999999,10.5,-10.5,0.5,-0.5,123456.5,0.25,-3/256}) do
  eq(nt.num(x),x..'','num '..tostring(x))
end
eq(nt.pair(-10.5,3),'-10.5,3'); eq(nt.pair(7,-0.5),'7,-0.5')
print('d21_batch73 AI numtext: ok')

-- The fog and belt memory: observe() into one store, observe_seen() into another; the same rows.
game={tick=500}
local reads={}
local force={name='player'}
local surface={name='nauvis',index=1}
local asked=0
force.is_chunk_visible=function(s,c) asked=asked+1 return not (c.x==3 and c.y==3) end
local function entity(fields)
  return setmetatable({},{__index=function(_,k)
    reads[k]=(reads[k] or 0)+1
    if k=='position' then return {x=fields.x,y=fields.y} end
    if k=='bounding_box' then return {left_top={x=fields.x-0.5,y=fields.y-0.5},right_bottom={x=fields.x+0.5,y=fields.y+0.5}} end
    if k=='force' then return force end
    if k=='surface' then return surface end
    if k=='valid' then return true end
    if k=='supports_direction' then return fields.direction~=nil end
    if k=='get_item_count' then return function() return fields.items or 0 end end
    if k=='last_user' then return fields.user and {name=fields.user} or nil end
    return fields[k]
  end})
end
local status={[1]='working',[2]='no_power'}
local function memory(store)
  local state=function() return store end
  local fm=dofile(DIR..'/fogmem.lua'){state=state}
  local bg=dofile(DIR..'/beltgaps.lua'){state=state,position=function(p) return p end}
  local rm=dofile(DIR..'/readmemory.lua'){state=state,position=function(p) return p end,status_name=function(e) return status[e.status] end,
    visible=function(p,pos) return p.force.is_chunk_visible(p.surface,{x=math.floor(pos.x/32),y=math.floor(pos.y/32)}) end,
    fog_note=function(e,pos,st) return fm.note(e,pos,st) end,belt_observe=function(e,p) return bg.observe(e,p) end,
    fog_note_seen=function(e,t,pos,cx,cy,st,ctx) return fm.note_seen(e,t,pos,cx,cy,st,ctx) end,
    belt_observe_seen=function(e,t,pos,cx,cy,ctx) return bg.observe_seen(e,t,pos,cx,cy,ctx) end}
  return rm,fm,bg
end
local function ctx() return {p={force=force,surface=surface},force=force,surface=surface,force_name='player',surface_name='nauvis',
  fog_prefix='player|nauvis|',vis={},fog={},belt={}} end
local list={
  {type='assembling-machine',name='assembling-machine-2',x=10.5,y=12.5,unit_number=7,direction=4,status=1},
  {type='inserter',name='inserter',x=11.5,y=-0.5,unit_number=10,direction=8,status=2},
  {type='transport-belt',name='transport-belt',x=40.5,y=3.5,unit_number=8,direction=2,status=1,items=3,user='Sol'},
  {type='container',name='iron-chest',x=100.5,y=100.5,unit_number=9},
  {type='character',name='character',x=1.5,y=1.5},
}
local old,new={},{}
local rm1=memory(old)
local rm2=memory(new)
for _,f in ipairs(list) do rm1.observe(entity(f)) end
asked=0
local c=ctx()
for _,f in ipairs(list) do local e=entity(f); rm2.observe_seen(e,f.type,{x=f.x,y=f.y},c) end
same(new.fog_memory,old.fog_memory,'fog memory')
same(new.belt_memory,old.belt_memory,'belt memory')
eq(next(new.read_memory and new.read_memory.entries or {}),nil,'no summary in the ring')
assert(next(old.read_memory.entries),'observe() keeps summaries')
eq(new.fog_memory.chunks['player|nauvis|3,3'],nil,'the chest out of sight is not noted')
eq(asked,4,'a chunk asked once a step (chunks 0,0 0,-1 1,0 3,3)')
print('d21_batch73 AI census sighting as observe(): ok')

-- A belt seen again as it was: the same row, its tick and items brought up to date; turned, a new row.
local row=new.belt_memory.chunks['player|nauvis|1,0'].tiles['40,3']
game.tick=900
local belt={type='transport-belt',name='transport-belt',x=40.5,y=3.5,unit_number=8,direction=2,status=1,items=0,user='Astra'}
reads={}
rm2.observe_seen(entity(belt),'transport-belt',{x=40.5,y=3.5},ctx())
local now=new.belt_memory.chunks['player|nauvis|1,0'].tiles['40,3']
assert(now==row,'the same row')
eq(now.tick,900); eq(now.items,0); eq(now.carried_tick,500,'carried when last seen with items'); eq(now.by,'Astra')
eq(reads.bounding_box,nil,'no bounding box read'); eq(reads.position,nil,'no position read')
belt.direction=4
rm2.observe_seen(entity(belt),'transport-belt',{x=40.5,y=3.5},ctx())
local turned=new.belt_memory.chunks['player|nauvis|1,0'].tiles['40,3']
assert(turned~=row,'a turned belt gets a new row'); eq(turned.direction,4)
print('d21_batch73 AI belt seen again: ok')

-- The pass paced by work: WORK entities read a tick at most, a band's find charged by what it found.
local localstate={}
local seen=0
local band={}
for i=1,100 do band[i]={valid=true,type='wall',name='stone-wall',position={x=i+0.5,y=0.5},direction=0} end
local bands=1
local opts
local C=dofile(DIR..'/census.lua'){state=function() return localstate end,observe_seen=function() seen=seen+1 end,
  walk={start=function(_,_,o) opts=o return {} end,band=function() if bands>0 then bands=bands-1 return band end end}}
game.surfaces={surface}; game.get_surface=function(i) return surface end; game.forces={player=force}
prototypes={entity={['stone-wall']={tile_width=1,tile_height=1}}}
defines={entity_status={low_power=1,no_power=2}}
local t=1000
C.tick(t)  -- the job
t=t+1; C.tick(t)  -- the band: 100 found, 20 units charged
eq(seen,0); assert(localstate.census.job.credit<0,'the find charged')
local per={}
for i=1,40 do local s0=seen; t=t+1; C.tick(t); per[#per+1]=seen-s0 end
for _,n in ipairs(per) do assert(n<=8,'at most WORK a tick: '..n) end
eq(seen,100,'the band read over the ticks')
eq(per[1],0,'the find paid first (21 units: 1 a band, 0.2 an entity found; 8 a tick)'); eq(per[2],3)
eq(opts.max_chunks,1,'one chunk a band')
print('d21_batch73 AI census paced by work: ok')
