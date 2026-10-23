-- d22 batch110 (BT1, the harness's garbage). Run from the harness root: lua tests/d22_batch110.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end

-- fluid_count on a platform: its holders found once and kept while their count holds and each is valid (no find, and
-- no closure an entity, at each check), found again when one is gone or another came; the amounts read live each check.
do
  defines={wire_connector_id={circuit_red=1,circuit_green=2},inventory={hub_main=1}}
  prototypes={item={},fluid={['thruster-fuel']={},['thruster-oxidizer']={}},virtual_signal={}}
  game={tick=0}
  local fuel={}
  local function holder(kind,amount)
    local e={valid=true,type=kind}
    fuel[e]=amount
    e.get_fluid_count=function(f) assert(e.valid,'read on an invalid entity'); return f=='thruster-fuel' and fuel[e] or 0 end
    return e
  end
  local ents={holder('pipe',100),holder('pipe',50),holder('storage-tank',20000),holder('thruster',300)}
  local finds,counts=0,0
  local surface={index=7}
  surface.count_entities_filtered=function(f)
    counts=counts+1; assert(type(f.type)=='table' and f.limit==4096)
    local n=0 for _,e in ipairs(ents) do if e.valid then n=n+1 end end
    return n
  end
  surface.find_entities_filtered=function(f)
    finds=finds+1; assert(type(f.type)=='table' and f.limit==4096)
    local out={} for _,e in ipairs(ents) do if e.valid then out[#out+1]=e end end
    return out
  end
  local pl={valid=true,name='Asterion',surface=surface}
  local p={force={index=1,platforms={pl}}}
  local C=dofile('mod/agent-harness_0.1.0/conditions.lua'){}
  local c={['until']='fluid_count',platform='Asterion',fluid='thruster-fuel',below=15000}
  C.validate(c)
  local met,saw=C.check(p,c)
  eq(met,false); eq(saw,'thruster-fuel 20450 on Asterion: tanks 20000 (1), pipes 150 (2), thrusters 300 (1)'); eq(finds,1)
  -- the same holders: no find; the amounts as they are now
  fuel[ents[3]]=10000
  met,saw=C.check(p,c)
  eq(met,true); eq(saw,'thruster-fuel 10450 on Asterion: tanks 10000 (1), pipes 150 (2), thrusters 300 (1)'); eq(finds,1); eq(counts,2)
  -- the other fluid shares the list
  met,saw=C.check(p,{['until']='fluid_count',platform='Asterion',fluid='thruster-oxidizer',below=1})
  eq(saw,'thruster-oxidizer 0 on Asterion: none in its tanks, pipes, thrusters, machines, fusion reactors or generators'); eq(finds,1)
  -- a pipe gone: found again
  ents[2].valid=false
  met,saw=C.check(p,c)
  eq(saw,'thruster-fuel 10400 on Asterion: tanks 10000 (1), pipes 100 (1), thrusters 300 (1)'); eq(finds,2)
  -- one gone and one new in the same ticks (the count the same): the gone one is seen, found again
  ents[1].valid=false
  ents[#ents+1]=holder('pump',7)
  met,saw=C.check(p,c)
  eq(saw,'thruster-fuel 10307 on Asterion: tanks 10000 (1), pipes 7 (1), thrusters 300 (1)'); eq(finds,3)
  -- a new tank: the count differs, found again
  ents[#ents+1]=holder('storage-tank',5)
  met,saw=C.check(p,c)
  eq(saw,'thruster-fuel 10312 on Asterion: tanks 10005 (2), pipes 7 (1), thrusters 300 (1)'); eq(finds,4)
  met,saw=C.check(p,c); eq(finds,4)
end
print('d22_batch110 BT1 fluid_count holders kept: ok')
