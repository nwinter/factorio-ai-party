-- #2895: 16 production counter names, item/fluid kinds, and saved mixed watches.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b) assert(a==b,tostring(a)..' ~= '..tostring(b)) end
local function fails(fn,part) local ok,e=pcall(fn); assert(not ok and tostring(e):find(part,1,true),tostring(e)) end
local function copy(v)
  if type(v)~='table' then assert(type(v)~='function' and type(v)~='userdata'); return v end
  local t={}; for k,x in pairs(v) do t[k]=copy(x) end; return t
end
prototypes={item={shared={},coal={}},fluid={shared={},['molten-iron']={}},quality={normal={},uncommon={},rare={},epic={},legendary={}}}
local names={}; for i=1,16 do names[i]='item-'..i; prototypes.item[names[i]]={} end
defines={flow_precision_index={ten_minutes=1}}
local reads=0
local made,used={item={},fluid={}},{item={},fluid={}}
local function stats(kind)
  local function key(id)
    eq(type(id),kind=='fluid' and 'string' or 'table')
    return kind=='fluid' and id or id.name..'@'..id.quality
  end
  return {get_input_count=function(id) reads=reads+1; return made[kind][key(id)] or 0 end,
    get_output_count=function(id) reads=reads+1; return used[kind][key(id)] or 0 end,
    get_flow_count=function(a) key(a.name); reads=reads+1; return 0 end}
end
local item,fluid=stats('item'),stats('fluid')
local surface={name='nauvis'}
local force={name='player',get_item_production_statistics=function(s) eq(s,surface); return item end,
  get_fluid_production_statistics=function(s) eq(s,surface); return fluid end}
game={tick=1000,surfaces={nauvis=surface},forces={player=force}}
local st={}; local api={state=function() return st end}
local function module() return dofile('mod/agent-harness_0.1.0/uptime.lua')(api) end
local U=module(); local p={index=1,force=force,surface=surface}
eq(U.MAX,64)
U.check_items(names); eq(#U.flows_start(force,surface,names).rows,80)
names[17]='coal'; fails(function() U.check_items(names) end,'1..16'); names[17]=nil
fails(function() U.check_items({}) end,'1..16')
fails(function() U.check_items({'shared'}) end,'is both an item and a fluid; give {name="shared", kind="item"|"fluid"}')
fails(function() U.check_items({{name='coal',kind='fluid'}}) end,'not a fluid prototype')
fails(function() U.check_items({{name='coal',kind='other'}}) end,'.kind: expected item or fluid')
fails(function() U.check_items({{name='molten-iron',quality='normal'}}) end,'fluids have no quality')
made.fluid['molten-iron']=100.5; used.fluid['molten-iron']=50.25
U.handler(p,{items={'coal','molten-iron',{name='shared',kind='item',quality='rare'},{name='shared',kind='fluid'}},seconds=10})
eq(#st.uptime[1].flows.rows,8)
local before=reads
for t=1001,1300 do game.tick=t; U.tick(t) end
eq(reads,before) -- the per-sample path never reads these counters
st=copy(st); U=module() -- reload the module with only persisted values, mid-watch
made.item['coal@uncommon']=12; made.item['shared@rare']=3
made.fluid['molten-iron']=225.75; used.fluid['molten-iron']=75.75
used.fluid.shared=4.5
for t=1301,1600 do game.tick=t; U.tick(t) end
local r=U.handler(p,{}).flows
eq(r.start_tick,1000); eq(r.end_tick,1600); eq(#r.rows,4)
eq(r.rows[1].kind,'item'); eq(r.rows[1].quality,'uncommon'); eq(r.rows[1].produced,12)
local f=r.rows[2]; eq(f.kind,'fluid'); eq(f.quality,nil); eq(f.produced,125.25); eq(f.consumed,25.5); eq(f.net,99.75)
eq(f.produced_per_min,751.5); eq(f.consumed_per_min,153)
eq(r.rows[3].name,'shared'); eq(r.rows[3].kind,'item'); eq(r.rows[3].produced,3)
eq(r.rows[4].name,'shared'); eq(r.rows[4].kind,'fluid'); eq(r.rows[4].consumed,4.5)
assert(r.line:find('all rows share ticks 1000-1600',1,true))
st=copy(st); U=module(); game.tick=9000; made.fluid['molten-iron']=999
local saved=U.handler(p,{read=true}).flows
eq(saved.end_tick,1600); eq(saved.rows[2].produced,125.25)
-- Existing saves have item rows without kind; retain their quality and baseline.
local old={start=1000,flows={force='player',surface='nauvis',rows={{name='coal',quality='uncommon',produced0=2,consumed0=0}}}}
eq(U.flows_result(old,10).rows[1].produced,10)
print('d36_batch422: bounds, kinds, mixed fluid deltas, common ticks, unchanged samples and reload: ok')
