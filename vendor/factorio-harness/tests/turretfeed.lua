-- turret_feeds (batch24 C4, Opus ~8 times by script that reported success when the chest did not fit): per hand-fed
-- turret a free side checked as a hand build checks it, a requester chest asking for its ammo and an inserter, built
-- by build from the inventory; skipped (fed, no side) and short (the items ran out) named.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b) assert(a==b,tostring(a)..' ~= '..tostring(b)) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
defines={inventory={turret_ammo=1},build_check_type={manual=1}}
prototypes={entity={['requester-chest']={name='requester-chest',type='logistic-container'},inserter={name='inserter',type='inserter'},
  ['iron-chest']={name='iron-chest',type='container'}},item={['firearm-magazine']={type='ammo'},['iron-plate']={type='item'}}}
local function k(x,y) return math.floor(x)..','..math.floor(y) end
local taken={}
local function turret(x,y,ammo)
  local inv={get_contents=function() return ammo and {{name=ammo,count=5}} or {} end}
  local t={valid=true,name='gun-turret',type='ammo-turret',position={x=x,y=y},force='us',bounding_box={left_top={x=x-1,y=y-1},right_bottom={x=x+1,y=y+1}}}
  t.get_inventory=function() return inv end
  for dx=-1,0 do for dy=-1,0 do taken[k(x+dx,y+dy)]=true end end
  return t
end
local A,B,C,D=turret(0,0,'firearm-magazine'),turret(10,0,'firearm-magazine'),turret(20,0,'firearm-magazine'),turret(30,0,'firearm-magazine')
local E=turret(40,0,nil)
local feeder={valid=true,name='inserter',position={x=10.5,y=-1.5}}
feeder.drop_target=B
-- C: every tile round it taken
for x=18,21 do for y=-2,1 do taken[k(x+0.5,y+0.5)]=true end end
local surface={find_entities_filtered=function(f)
    if f.type=='ammo-turret' then return {A,B,C,D,E} end
    if f.type=='inserter' then return f.area[1][1]<12 and f.area[2][1]>8 and {feeder} or {} end
    return {}
  end,
  can_place_entity=function(a) return not taken[k(a.position.x,a.position.y)] end}
-- an inserter facing d: 0 drops north, 4 east, 8 south, 12 west (pickup behind)
local V={[0]={0,-1},[4]={1,0},[8]={0,1},[12]={-1,0}}
local held={['requester-chest']=1,inserter=5}
local p={surface=surface,force='us',get_main_inventory=function() return {get_item_count=function(n) return held[n] or 0 end} end}
local built,fail_first={},false
local F=require('turretfeed'){points=function(_,q,d) local v=V[d]; return {x=q.x-v[1],y=q.y-v[2]},{x=q.x+v[1],y=q.y+v[2]} end,
  entity=function() error('not used') end,position=function(v) return v end,compass=function(d) return ({[0]='north',[4]='east',[8]='south',[12]='west'})[d] end,
  build=function(_,a) built=a.builds; eq(a.all,true); return {built=#a.builds,failed=fail_first and {{index=1,error='placement blocked by stone'}} or nil} end}
local r=F.handler(p,{area={left_top={x=-10,y=-10},right_bottom={x=50,y=10}},dry_run=true})
eq(r.turrets,5); eq(r.planned,1); eq(r.skipped,3); eq(r.short,1)
eq(r.lines[1],'gun-turret (0,0): requester-chest (-0.5,-2.5) asking 50 firearm-magazine, inserter (-0.5,-1.5) facing south')
eq(r.lines[2],'gun-turret (10,0): skipped: fed by inserter (10.5,-1.5) already')
eq(r.lines[3],'gun-turret (20,0): skipped: no inserter fits on a side (each side tile is taken)')
eq(r.lines[4],'gun-turret (30,0): short: you hold 1 requester-chest and 5 inserter: none left for it')
eq(r.lines[5],'gun-turret (40,0): skipped: empty, and no ammo named: ammo names what the chest asks for')
eq(r.note,'nothing built (dry_run)'); eq(#built,0)
-- built: the entries go to build in one batch with all, the chest's request as an entry setting
held['requester-chest']=2
r=F.handler(p,{area={left_top={x=-10,y=-10},right_bottom={x=50,y=10}},count=100})
eq(r.planned,2); eq(#built,4)
eq(built[1].item,'requester-chest'); eq(built[1].requests.set[1].item,'firearm-magazine'); eq(built[1].requests.set[1].min,100)
eq(built[2].item,'inserter'); eq(built[2].direction,8)
eq(r.rows[4].inserter.x,29.5)
-- a refused entry is the turret's not_built
fail_first=true
r=F.handler(p,{area={left_top={x=-10,y=-10},right_bottom={x=50,y=10}}})
eq(r.rows[1].not_built,'chest: placement blocked by stone')
fails(function() F.handler(p,{area={left_top={x=0,y=0},right_bottom={x=10,y=10}},chest='iron-chest'}) end,'chest: a logistic chest')
fails(function() F.handler(p,{area={left_top={x=0,y=0},right_bottom={x=10,y=10}},ammo='iron-plate'}) end,'ammo: an ammunition name')
print('turretfeed: ok')
