-- Run with lua tests/oreout.lua: drills out of ore (Nick 12:35) in the alert digest, game_alerts and the shift
-- start's count (pushalerts.lua). A drill whose patch under it is used up reads no_minable_resources and has no
-- mining target; the ore it mined is remembered from an earlier read, else taken from the drills still mining
-- around it.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
defines={entity_status={working=0,no_power=1,low_power=2,no_fuel=3,no_minable_resources=9},inventory={turret_ammo=7},alert_type={}}
storage={board={items={}}}
local force={name='player',players={}}
local ents={nauvis={},vulcanus={}}
local function surface(name,index)
  return {name=name,index=index,find_entities_filtered=function(f)
    local types={}
    for _,t in ipairs(type(f.type)=='table' and f.type or {f.type}) do types[t]=true end
    local out={}
    for _,e in ipairs(ents[name]) do if e.valid and types[e.type] then out[#out+1]=e end end
    return out end}
end
local nauvis,vulcanus=surface('nauvis',1),surface('vulcanus',3)
-- As the engine's: iterated once, looked up by name too.
game={tick=100000,surfaces=setmetatable({nauvis,vulcanus},{__index=function(_,k) return ({nauvis=nauvis,vulcanus=vulcanus})[k] end})}
local unit=0
local function drill(s,name,x,y,ore,user)
  unit=unit+1
  local e={valid=true,name=name,type='mining-drill',position={x=x,y=y},status=0,electric_network_id=7,unit_number=unit,
    last_user=user and {name=user} or nil}
  e.mining_target=ore and {name=ore} or nil
  ents[s][#ents[s]+1]=e
  return e
end
-- Astra's iron field: 10 electric drills, all mining iron-ore at the first read.
local iron={}
for i=1,10 do iron[i]=drill('nauvis','electric-mining-drill',40+i*3,-60,'iron-ore','astra') end
-- A burner drill on stone, never seen mining (built on a used-up spot), beside 2 still mining stone.
local stone_out=drill('nauvis','burner-mining-drill',-100,20,nil,'sol')
stone_out.status=9
drill('nauvis','burner-mining-drill',-98,20,'stone','sol'); drill('nauvis','burner-mining-drill',-96,20,'stone','sol')
-- Vulcanus: 2 big drills on tungsten, one never seen mining with nothing mining near it.
local tung=drill('vulcanus','big-mining-drill',300,300,nil,'luna'); tung.status=9
-- The ores read's last survey of Nauvis: an iron patch with our drills on it, and two none of ours are on.
storage.ores={['player@1']={patches={
  {name='iron-ore',centre={x=60,y=-60},amount=20000,miners=10},
  {name='iron-ore',centre={x=180,y=-20},amount=1200000,miners=0},
  {name='iron-ore',centre={x=-400,y=400},amount=9000000,miners=0},
  {name='stone',centre={x=-120,y=60},amount=45000,miners=0}}}}
local places={[1]={key='nauvis',position={x=0,y=0}},[2]={key='nauvis',position={x=-90,y=20}},[3]={key='vulcanus',position={x=290,y=290}}}
local A=dofile('mod/agent-harness_0.1.0/pushalerts.lua'){
  state=function() return storage end,
  agents=function() return {{index=1,name='astra'},{index=2,name='sol'},{index=3,name='luna'}} end,
  who=function(p) return p.name end,
  place=function(index) return places[index] end}
local function agent(name,s) return {name=name,force=force,surface=s} end
local astra,sol,luna=agent('astra',nauvis),agent('sol',nauvis),agent('luna',vulcanus)
local ha,hs,hl={},{},{}

-- 1. The first read: everything mining; no line.
eq(#A.lines(astra,ha),0); eq(A.out_of_ore_line(force),'drills out of ore: 2 (nauvis 1, vulcanus 1)')
-- 2. The patch under 6 iron drills runs out: they lose their target and read no_minable_resources.
for i=1,6 do iron[i].mining_target=nil; iron[i].status=9 end
game.tick=game.tick+31*60
local l=A.lines(astra,ha)
eq(#l,1,table.concat(l,' | '))
eq(l[1],'6 electric-mining-drill out of ore near (51,-60): iron-ore; 4 still mining there; nearest untapped iron-ore (180,-20) 135 tiles, about 1.2M ore')
-- Sol's burner drill: the ore from the drills mining around it; the builder hears it.
l=A.lines(sol,hs)
eq(l[1],'1 burner-mining-drill out of ore near (-100,20): stone; 2 still mining there; nearest untapped stone (-120,60) 45 tiles, about 45k ore')
-- Luna's: no drill ever seen on it and none around: the ore not seen, no patch named.
l=A.lines(luna,hl)
eq(l[1],'1 big-mining-drill out of ore near (300,300): ore not seen; 0 still mining there')
-- 3. New or worse only: the same groups again say nothing; 2 more out: news, with what it was.
game.tick=game.tick+151*60
eq(#A.lines(astra,ha),0)
for i=7,8 do iron[i].mining_target=nil; iron[i].status=9 end
game.tick=game.tick+151*60
l=A.lines(astra,ha)
eq(l[1],'8 electric-mining-drill out of ore near (54,-60) (was 6): iron-ore; 2 still mining there; nearest untapped iron-ore (180,-20) 132 tiles, about 1.2M ore')
-- 4. game_alerts lists them by kind; the shift start counts them per surface.
local r=A.read(astra,{kind='out_of_ore'})
eq(#r.groups,3)
local g=r.groups[1]
eq(g.kind,'out_of_ore.iron-ore'); eq(g.count,8); eq(g.ore,'iron-ore'); eq(g.still_mining,2); eq(g.untapped.x,180); eq(g.untapped.amount,1200000)
eq(A.out_of_ore_line(force),'drills out of ore: 10 (nauvis 9, vulcanus 1)')
-- 5. Mining again elsewhere (moved): gone from the groups.
for i=1,8 do iron[i].valid=false end
stone_out.valid=false; tung.valid=false
game.tick=game.tick+31*60
eq(A.out_of_ore_line(force),nil)
print('oreout: ok')
