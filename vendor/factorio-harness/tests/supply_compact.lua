-- Run from the harness root: lua tests/supply_compact.lua
-- supply's compact read (d20 batch63 Y3, Astra #1543 and Luna: observe {scope: supply, item, consumers: "all",
-- compact: true} failed with "bad argument #1 of 2 to 'ipairs' (table expected, got number)": compact read chests,
-- a count in a consumers reply). Every consumers value with and without compact, through supply and its compact step
-- as runtime's handlers.supply runs them; makers, requesters and split keep their own lines too.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(list,text)
  for _,l in ipairs(list or {}) do if tostring(l):find(text,1,true) then return l end end
  error('no line with '..text..' in: '..table.concat(list or {},' / '))
end
game={tick=7200,get_surface=function() return nil end}
defines={logistic_member_index={logistic_container=1},logistic_mode={requester=1,buffer=2}}
prototypes={item={stone={},['stone-brick']={}},recipe={['stone-brick']={energy=3.2,ingredients={{name='stone',amount=2}}},['stone-recycling']={energy=0.04,ingredients={{name='stone',amount=1}}}}}
local function m(x,recipe,status) return {valid=true,type='furnace',name='electric-furnace',position={x=x,y=212.5},unit_number=x,crafting_speed=2,
  status=status,get_recipe=function() return {name=recipe} end} end
local list={m(40.5,'stone-brick','working'),m(44.5,'stone-brick','no_ingredients'),m(60.5,'iron-gear-wheel','working')}
local surf={index=2,name='fulgora',find_entities_filtered=function() return {} end}
local force={name='player',logistic_networks={fulgora={}}}
local p={force=force,surface=surf,position={x=0,y=0}}
local S=dofile('mod/agent-harness_0.1.0/supply.lua'){census_crafters=function() return list,0 end,status_name=function(e) return e.status end,
  makers_all=function(_,item,s,a) return {item=item,surface=s.name,makers=1,rows={{position={x=8.5,y=3.5}}},lines={'electric-furnace (8.5,3.5) stone-brick: working'},
    line='1 machines on fulgora make stone-brick (1 stone-brick): 1 working',from=1} end}
-- the requesters read the consumers reuse: one chest asking, at its position
S.requesters=function() return {lines={'stone on fulgora: 1 requester or buffer chest asks for it','requester-chest (49.5,212.5) #96: asks 1000, holds 1001; met'},
  requesters={{chest='requester-chest',position={x=49.5,y=212.5},network=96,asks=1000,holds=1001,use_per_min=960,
    line='requester-chest (49.5,212.5) #96: asks 1000, holds 1001; met'}}} end
S.split=function() return {lines={'stone on fulgora: used 10/min, made 0/min (last 10 min); 1 group of machines take 75/min at full speed:',
  'stone-brick near (39,211)-(46,214): 2 electric-furnace (1 working) take 75/min at full speed, 100% of the take; fed from belts'},groups={{recipe='stone-brick'}}} end
-- as runtime's handlers.supply: compact taken off the arguments, the read, then compact when true
local function supply(a)
  local args={}
  for k,v in pairs(a) do if k~='compact' then args[k]=v end end
  local out=S.supply(p,args)
  if a.compact then return S.compact(out) end
  return out
end
-- consumers "all": with compact, the lines with each machine's and chest's position; without, the rows as before
for _,c in ipairs({true,false,nil}) do
  local r=supply({item='stone',consumers='all',compact=c})
  has(r.lines,'stone on fulgora: 2 machines take it (2 stone-brick), 1 working')
  has(r.lines,'electric-furnace (40.5,212.5) stone-brick: working')
  has(r.lines,'electric-furnace (44.5,212.5) stone-brick: no ingredients')
  has(r.lines,'requester-chest (49.5,212.5) #96: asks 1000, holds 1001')
  if c then eq(r.compact,true); eq(r.rows,nil); eq(r.lines[1]:sub(1,16),'stone on fulgora')
  else eq(r.compact,nil); eq(#r.rows,3); eq(r.chests,1); eq(r.machines,2) end
end
-- paging is kept: from and next_from
do
  local saved=list
  list={}
  for i=1,30 do list[i]=m(i+0.5,'stone-brick','working') end
  local r=supply({item='stone',consumers='all',compact=true})
  eq(r.next_from,25); eq(#r.lines,25); has(r.lines,'1-24 of 31 shown')
  r=supply({item='stone',consumers='all',compact=true,from=25})
  eq(r.from,25); eq(r.next_from,nil); eq(#r.lines,8); has(r.lines,'electric-furnace (9.5,212.5) stone-brick')
  list=saved
end
-- any other consumers value is refused, with compact or not
for _,v in ipairs({true,'some',1}) do
  for _,c in ipairs({true,false}) do
    local ok,err=pcall(supply,{item='stone',consumers=v,compact=c})
    assert(not ok and tostring(err):find('consumers is "all"',1,true),tostring(err))
  end
end
-- makers, requesters and split with compact keep their lines (they came back with none); the makers head line first
local r=supply({item='stone-brick',makers='all',compact=true})
eq(r.lines[1],'1 machines on fulgora make stone-brick (1 stone-brick): 1 working'); has(r.lines,'electric-furnace (8.5,3.5) stone-brick')
r=supply({item='stone',requesters=true,compact=true}); has(r.lines,'requester-chest (49.5,212.5) #96'); eq(r.requesters,nil)
r=supply({item='stone',split=true,compact=true}); has(r.lines,'stone-brick near (39,211)-(46,214)'); eq(r.groups,nil)
-- the plain read (no consumers): flow, where, makers, the stopped ones, the chests and the surplus as before
r=S.compact({item='stone',surface='fulgora',flow='made 0, used 10 in the last 10 min on fulgora',where='1001: requester chests 1001',
  makers='makers: none',makers_worst={'a (1,1)','b (2,2)','c (3,3)','d (4,4)'},users_worst={'electric-furnace (44.5,212.5): no ingredients; more'},
  chests={'requester-chest (49.5,212.5) 1001'},surplus_chest={line='wooden-chest (1,1) 50; reserved 0'}})
eq(r.lines[1],'made 0, used 10 in the last 10 min on fulgora'); eq(r.lines[2],'where: 1001: requester chests 1001'); eq(r.lines[3],'makers: none')
eq(r.lines[4],'makers stopped: a (1,1) | b (2,2) | c (3,3)'); eq(r.lines[5],'users stopped: electric-furnace (44.5,212.5): no ingredients')
eq(r.lines[6],'chests: requester-chest (49.5,212.5) 1001'); eq(r.lines[7],'surplus: wooden-chest (1,1) 50')
-- a read with no flow and a count for chests (the shape that failed) does not fail
r=S.compact({item='stone',chests=3,machines=3}); eq(#r.lines,0)
print('supply_compact ok')
