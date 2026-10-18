-- d17 batch22 (operator 18:30: the agents' 18:20 poll). Run from the harness root: lua tests/d17_batch22.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,msg) assert(a==b,(msg or '')..' '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end

-- A1: tilecheck's play and connect: a far tile, and the chain joining it to the floor.
do
  local floor={}
  for x=-2,2 do for y=-2,2 do floor[x..','..y]=true end end
  local s={get_tile=function(x,y) return {name=floor[x..','..y] and 'space-platform-foundation' or 'empty-space'} end}
  local TC=dofile('mod/agent-harness_0.1.0/tilecheck.lua')()
  local c={}
  local play=TC.play(s,{{3,0,'f'},{8,0,'f'}},nil,{},c)
  eq(play.built[TC.key(3,0)],true); eq(play.built[TC.key(8,0)],nil)
  eq(play.rule({8,0}),'no foundation among the 8 tiles round it')
  local chain=TC.connect(s,{{8,0}},c)
  eq(#chain,4); eq(chain[1][1],7); eq(chain[4][1],4)
end
print('d17_batch22 A1 play and connect: ok')

-- A4: a hub's room for a cargo: part stacks topped up first, chunk slots named.
do
  prototypes={item={['iron-plate']={stack_size=100},['metallic-asteroid-chunk']={stack_size=1},['gun-turret']={stack_size=50}}}
  defines={inventory={hub_main=1}}
  local slots={{name='iron-plate',count=60},{name='metallic-asteroid-chunk',count=1},{name='metallic-asteroid-chunk',count=1},{}}
  local inv=setmetatable({},{__len=function() return #slots end,__index=function(_,i)
    local st=slots[i]; return {valid_for_read=st.name~=nil,name=st.name,count=st.count,quality='normal'} end})
  local hub={valid=true,get_inventory=function() return inv end}
  local R=dofile('mod/agent-harness_0.1.0/rocketload.lua'){}
  local r=R.hub_room(hub,{{name='iron-plate',count=40},{name='gun-turret',count=10}})
  eq(r.need,1); eq(r.free,1); eq(r.fits,true); eq(r.chunks,2)
  r=R.hub_room(hub,{{name='iron-plate',count=140},{name='gun-turret',count=10}})
  eq(r.fits,false); eq(r.line,'the cargo takes 2 hub slots; the hub has 1 of 4 free (asteroid chunks take 2): it does not fit')
  prototypes,defines=nil,nil
end
print('d17_batch22 A4 hub room: ok')

-- B1 (Luna): danger near egg sites: each site's first hatch and the turrets covering it, in one read.
do
  game={tick=1000}
  defines={inventory={turret_ammo=1}}
  local function turret(name,typ,x,range,loaded) return {valid=true,name=name,type=typ,position={x=x,y=0},prototype={attack_parameters={range=range}},
    get_inventory=function() return {is_empty=function() return not loaded end} end,energy=loaded and 100 or 0} end
  local turrets={turret('gun-turret','ammo-turret',10,18,true),turret('gun-turret','ammo-turret',12,18,false),turret('laser-turret','electric-turret',30,24,true)}
  local surface={name='gleba',find_entities_filtered=function(f)
    if f.type and type(f.type)=='table' and f.type[1]=='ammo-turret' then return turrets end
    return {} end}
  local D=dofile('mod/agent-harness_0.1.0/danger.lua'){position=function(v) return v end,state=function() return {} end,
    avoid={structures=function() return {list={},uncharted=0,unread=0} end,reach=function() return 0 end,chunks_near=function() return {} end,seg_dist=function() return 99 end},
    eggs=function() return {{position={x=0,y=0},tick=1600,text='12 pentapod-egg in requester-chest at (0,0): the first hatches in 10s'}} end}
  local cov=D.coverage(surface,{name='player'},{x=0,y=0})
  eq(cov.ready,1); eq(cov.idle,1); eq(cov.line,'in range of 1 turret ready (1 gun-turret), 1 more in range without ammunition, power or fluid')
  local r=D.read({surface=surface,force={name='player'},character=nil},{position={x=0,y=0},radius=32})
  eq(r.eggs[1],'12 pentapod-egg in requester-chest at (0,0): the first hatches in 10s; in range of 1 turret ready (1 gun-turret), 1 more in range without ammunition, power or fluid')
  has(r.line,'eggs: 1 site within 32 tiles')
  defines=nil
end
print('d17_batch22 B1 eggs and turrets near a point: ok')
