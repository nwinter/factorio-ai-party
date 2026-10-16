-- d15 batch3 (operator 18:30, shifts 18-19 requests). Run from the harness root: lua tests/d15_batch3.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,msg) assert(a==b,(msg or '')..' '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end

-- A mock inventory: slots {name,count} or false.
local function inventory(list)
  local inv={}
  local mt={__len=function() return #list end,__index=function(_,k)
    if type(k)=='number' then local s=list[k]; return s and {valid_for_read=true,name=s[1],count=s[2]} or {valid_for_read=false} end
    if k=='count_empty_stacks' then return function() local n=0; for _,s in ipairs(list) do if not s then n=n+1 end end; return n end end
    if k=='can_insert' then return function() for _,s in ipairs(list) do if not s then return true end end; return false end end
    if k=='get_item_count' then return function(name) local n=0; for _,s in ipairs(list) do if s and s[1]==name then n=n+s[2] end end; return n end end
  end}
  return setmetatable(inv,mt)
end

-- 1 (Astra, Luna): a chest with every slot used, what fills it, and the machines whose output waits on it. ---------
do
  defines={inventory={chest=1},entity_status={}}
  local status={}
  local force={name='player'}
  local by_type={}
  local surface={find_entities_filtered=function(f)
    local out={}
    local types=type(f.type)=='table' and f.type or {f.type}
    for _,t in ipairs(types) do for _,e in ipairs(by_type[t] or {}) do out[#out+1]=e end end
    return out
  end}
  local function entity(t)
    t.valid=true; t.surface=surface; t.force=force
    local x,y=t.position.x,t.position.y
    t.bounding_box={left_top={x=x-0.5,y=y-0.5},right_bottom={x=x+0.5,y=y+0.5}}
    by_type[t.type]=by_type[t.type] or {}; table.insert(by_type[t.type],t)
    return t
  end
  local slots={}
  for i=1,48 do slots[i]=i<=40 and {'spoilage',100} or {'nutrients',30} end
  local full_inv=inventory(slots)
  local chest=entity{type='logistic-container',name='passive-provider-chest',unit_number=10,position={x=10.5,y=4.5},get_inventory=function() return full_inv end}
  local spare_inv=inventory({{'nutrients',5},false,false})
  local spare=entity{type='container',name='steel-chest',unit_number=11,position={x=14.5,y=4.5},get_inventory=function() return spare_inv end}
  local bio=entity{type='assembling-machine',name='biochamber',unit_number=20,position={x=7.5,y=4.5}}
  local ins=entity{type='inserter',name='inserter',unit_number=30,position={x=9.5,y=4.5},drop_target=chest,pickup_target=bio}
  local other=entity{type='inserter',name='inserter',unit_number=31,position={x=11.5,y=4.5},drop_target=spare,pickup_target=chest}
  status[bio]='full_output'; status[ins]='waiting_for_space_in_destination'; status[other]='working'
  local F=require('fullchest'){status_name=function(e) return status[e] end}
  local r=F.read(chest)
  eq(r.line,'passive-provider-chest (10.5,4.5): 48/48 slots used (spoilage 4000 in 40 slots, nutrients 240 in 8 slots); output waits on it: biochamber (7.5,4.5) full_output (1 inserter waiting)')
  eq(F.read(spare),nil,'a chest with a free slot is not full')
  eq(F.free_note(spare),', 2/3 slots free'); eq(F.free_note(chest),', 0/48 slots free')
  eq(F.of_machine(bio).line,r.line,'a full_output machine finds the chest its inserter waits on')
  local near=F.nearest_free(chest)
  eq(near[1],'steel-chest (14.5,4.5) 2/3 slots free, 4 tiles')
  spare_inv=inventory({{'nutrients',5}})
  eq(F.nearest_free(chest)[1],'no chest of ours within 32 tiles has a free slot')

  -- supply: full_chests from the makers' takers, free slots on the listed providers.
  prototypes={item={nutrients={}},fluid={}}
  local S=require('supply'){state=function() return {} end,integer=function(v,d) return v or d end,status_name=function(e) return status[e] end}
  local t={item='nutrients',chests={{n=240,e=chest,kind='passive-provider'}},takers={n=1,states={},into={},chests={[10]=chest}},request_of={}}
  local lines=S.full_chests(t)
  eq(lines[1],r.line); eq(#lines,1,'the same chest once')
  eq(S.top_chests(t)[1],'(10.5,4.5) passive-provider-chest 240, 0/48 slots free')

  -- open for you: a full_output machine in a fresh claim whose output waits on a full chest.
  game={tick=100000,surfaces={gleba={index=4,find_entity=function(name,pos) if name=='biochamber' and pos.x==7.5 then return bio end end}}}
  local st={board={items={{id=700,kind='claim',owner='luna',status='doing',title='bioflux',surface='gleba',area={left_top={x=0,y=0},right_bottom={x=40,y=40}}}}},
    survey_cache={['player/4']={positions={biochamber={full_output={{x=7.5,y=4.5}}}}}}}
  local O=require('open'){state=function() return st end,claim_surface=function(i) return i.surface end,claim_stale=function() return false end,fullchest=F}
  has(O.line('luna',force),'1 full chest in your claims that output waits on (passive-provider-chest (10.5,4.5) 48/48 slots used (spoilage 4000 in 40 slots, nutrients 240 in 8 slots))')
end
print('d15_batch3 1 full chests: ok')
