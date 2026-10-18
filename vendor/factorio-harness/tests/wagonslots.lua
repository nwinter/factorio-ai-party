-- A cargo wagon's slots (batch25 C2, Muse: a wagon full of one item blocked all other loading on the uranium route, an
-- hour to find): slots used per item with the count, free slots, slot filters, the red-X limit; full said plainly.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b) assert(a==b,tostring(a)..' ~= '..tostring(b)) end
defines={inventory={cargo_wagon=1}}
game={tick=0}
local T=dofile('mod/agent-harness_0.1.0/trains.lua'){}
local function wagon(slots,filters,bar)
  local inv={}
  for i=1,40 do
    local s=slots[i]
    inv[i]=s and {valid_for_read=true,name=s[1],count=s[2]} or {valid_for_read=false}
  end
  local meta={__len=function() return 40 end,__index=function(_,k)
    if k=='get_bar' then return function() return bar or 41 end end
    if k=='get_filter' then return function(i) return filters and filters[i] or nil end end
  end}
  setmetatable(inv,meta)
  return {name='cargo-wagon',position={x=10,y=4},get_inventory=function(i) eq(i,1); return inv end}
end
local full={}
for i=1,40 do full[i]={'uranium-ore',50} end
local r=T.wagon_slots(wagon(full))
eq(r.used,40); eq(r.free,0)
eq(r.line,'cargo-wagon (10,4): 40/40 slots used: uranium-ore 40 slots (2000); 0 free; no slot filters; full: nothing else loads into it')
local mixed={{'uranium-ore',50},{'uranium-ore',20},{'sulfuric-acid-barrel',10}}
r=T.wagon_slots(wagon(mixed,{[1]='uranium-ore',[2]={name='uranium-ore'}},11))
eq(r.limit,10); eq(r.free,7); eq(r.by_item['uranium-ore'],2)
eq(r.line,'cargo-wagon (10,4): 3/40 slots used (red-X limit: 10 usable): uranium-ore 2 slots (70), sulfuric-acid-barrel 1 slot (10); 7 free; slot filters: uranium-ore 2')
print('wagonslots: ok')
