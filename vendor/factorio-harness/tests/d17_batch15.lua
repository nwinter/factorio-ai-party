-- d17 batch15 contracts.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end

-- A2 (Grok ~6x): the items that spoil into an item are found from the prototypes.
do
  _G.prototypes={item={['copper-bacteria']={spoil_result={name='copper-ore'}},['iron-bacteria']={spoil_result={name='iron-ore'}},['copper-ore']={},['bioflux']={spoil_result={name='spoilage'}}}}
  local S=dofile('mod/agent-harness_0.1.0/supply.lua'){}
  local src=S.spoil_sources('copper-ore')
  eq(#src,1); eq(src[1],'copper-bacteria')
  eq(#S.spoil_sources('steel-plate'),0)
  prototypes=nil
  print('d17_batch15 A2 spoil sources: ok')
end
