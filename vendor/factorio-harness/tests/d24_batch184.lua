-- d24 batch184 QAA1 (operator 18:03: delivery_watch {} took 24.6 ms on world n with 6 watches, each line several hundred
-- characters; on a copy of world n's 18:11 save the list of 3 took 5-6 ms, half of it the reply's JSON, 15 KB of whole
-- rows). The list gives each watch in brief (the facts to tell them apart and see how each stands, and a short line);
-- delivery_watch {id} gives the whole row, {full: true} every whole row. The setup is d24 batch139's.
-- Run from the harness root: lua tests/d24_batch184.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
local function lacks(s,x) assert(not tostring(s):find(x,1,true),tostring(s)..' has '..x) end
game={tick=1000}
defines={inventory={hub_main=1,cargo_unit=3,cargo_landing_pad_main=4,chest=5}}
prototypes={item={calcite={stack_size=50}}}
local function stack(name,count) return {valid_for_read=true,name=name,count=count,quality={name='normal'}} end
local function inv(list) local t={} for i,x in ipairs(list) do t[i]=x end
  t.get_item_count=function(n) local c=0 for _,x in ipairs(list) do if x.name==n then c=c+x.count end end return c end
  t.can_insert=function() return true end return t end
local nauvis={name='nauvis'}
nauvis.find_logistic_network_by_position=function() return {network_id=1} end
-- the pad's request (min) and what it holds
local pad_min,pad_held=2000,0
local function sections(list)
  return {sections_count=#list,get_section=function(i) return list[i] end}
end
local pad={valid=true,name='cargo-landing-pad',type='cargo-landing-pad',position={x=-12,y=40},surface=nauvis,unit_number=77,
  get_inventory=function() return inv({}) end,get_item_count=function() return pad_held end,
  get_logistic_sections=function() return sections(pad_min>0 and {{active=true,filters={{value={name='calcite'},min=pad_min}}}} or {}) end}
nauvis.find_entities_filtered=function(f) if f.position and f.position.x==-12 then return {pad} end return {} end
local force={name='player',is_chunk_charted=function() return true end}
-- the hub's sections: {name, min, max, from}
local hub_secs={}
local function hub_sections()
  local list={}
  for _,f in ipairs(hub_secs) do list[#list+1]={active=true,filters={{value={name=f[1]},min=f[2],max=f[3],import_from=f[4]}}} end
  return sections(list)
end
local function platform(name,index,n,paused,at)
  return {valid=true,name=name,index=index,surface={name='platform-'..index},paused=paused,space_location={name=at},
    schedule={current=1,records={{station='nauvis'},{station='gleba'}}},
    hub={valid=true,type='space-platform-hub',get_inventory=function() return inv({stack('calcite',n)}) end,get_logistic_sections=hub_sections}}
end
local petrel=platform('Petrel',5,1980,true,'nauvis')
force.platforms={petrel}
game.forces={player=force}; game.planets={nauvis={surface=nauvis},gleba={surface={name='gleba'}}}
local F=dofile('mod/agent-harness_0.1.0/freight.lua'){state=function() return {} end}
local st={}
local W=dofile('mod/agent-harness_0.1.0/delivwatch.lua'){state=function() return st end,who=function(p) return p.name end,census_typed=function() return {pad} end,
  freight={where=function() return {} end,receipts_since=function() return {} end,followed=function() return {down={},up={}} end,spoils=function() return false end,
    hub_keeps_at=F.hub_keeps_at,hub_gives=F.hub_gives,keep_text=F.keep_text}}
local sol={name='sol',index=1,force=force,surface=nauvis}
local function read(id) game.tick=game.tick+60; W.tick(game.tick-game.tick%60); return W.call(sol,{id=id}).watches[1] end
local function blocked(row) return table.concat(row.blockers or {},' | ') end

local a=W.call(sol,{item='calcite',count=5000,to={position={x=-12,y=40},surface='nauvis'},deadline_min=60,from='Petrel'}).watch.id
local b=W.call(sol,{item='calcite',count=10,quality='rare',to={position={x=-12,y=40},surface='nauvis'},deadline_min=30}).watch.id
local whole=read(a)
local list=W.call(sol,{})
eq(#list.watches,2); eq(#list.lines,2)
local r=list.watches[1]
eq(r.id,a); eq(r.item,'calcite'); eq(r.quality,nil); eq(r.counts,'every quality (no quality given)'); eq(r.count,5000); eq(r.from,'Petrel')
eq(r.to.name,'cargo-landing-pad'); eq(r.to.where,'nauvis'); eq(r.state,whole.state); eq(r.received,0); eq(r.deadline_tick,whole.deadline_tick)
eq(r.last_confirmed,whole.last_confirmed); eq(r.held,whole.held); eq(r.at_start,whole.at_start)
eq(r.stages,nil,'no stage texts in the list'); eq(r.arrivals,nil); eq(r.stock,nil)
has(list.lines[1],'delivery watch #'..a..': 5000 calcite to cargo-landing-pad (-12,40) on nauvis, '..whole.state..'; deadline in ')
has(list.lines[1],'received 0 of 5000;'); has(list.lines[1],'every quality (no quality given); delivery_watch {id: '..a..'} gives the whole row')
has(list.lines[2],'10 calcite@rare to cargo-landing-pad (-12,40) on nauvis'); has(list.lines[2],'rare quality only')
has(list.note,'delivery_watch {id: N} gives its whole row')
assert(#list.lines[1] < #whole.line,'the list line is the shorter')
-- every fact stays reachable: {id} and {full: true} give the whole rows, as the list did before
local full=W.call(sol,{full=true})
eq(#full.watches,2); assert(full.watches[1].stages and full.watches[1].stock and full.watches[1].received,'a whole row')
has(full.watches[1].line,'; stages: '); eq(W.call(sol,{id=a}).watches[1].line,full.watches[1].line)
eq(full.note,nil)
eq(W.call(sol,{id=b}).watches[1].quality,'rare')
local ok,err=pcall(W.call,sol,{full='yes'})
assert(not ok and tostring(err):find('full: true gives every watch',1,true),tostring(err))
print('d24_batch184 QAA1 delivery_watch list in brief: ok')
